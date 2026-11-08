import { http, socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';

const TAG: string = 'AutumnDlna';

/** 一个可投屏的设备。 */
export class DlnaDevice {
  /** 设备描述里的 friendlyName */
  name: string = '';
  /** 设备描述地址（LOCATION） */
  location: string = '';
  /** AVTransport 控制地址（SOAP 发到这里） */
  controlUrl: string = '';
  /** 设备实际声明的 AVTransport 服务类型（可能是 v1 / v2 / v3） */
  serviceType: string = '';

  key(): string {
    return `${this.name}-${this.location}`;
  }
}

/** 设备描述里解析出的 AVTransport 服务端点。 */
class DlnaServiceEndpoint {
  serviceType: string = '';
  controlUrl: string = '';
}

/** 投屏结果。 */
export class DlnaCastResult {
  ok: boolean = false;
  message: string = '';
}

/**
 * DLNA 投屏。对应参照实现 `lib/services/player/remote.dart` 的 `RemotePlay`。
 *
 * 两条链路：
 *   1. **发现**：UDP 组播发 M-SEARCH（`239.255.255.250:1900`），
 *      收设备回包 → 取 `LOCATION` → GET 设备描述 XML → 解析 friendlyName 与
 *      `AVTransport` 的 controlURL；
 *   2. **投屏**：向 controlURL POST 一段 SOAP，先 `SetAVTransportURI`
 *      （带上当前播放地址与 DIDL-Lite 元数据），再 `Play`。
 *
 * 为什么用 socket 而不是 `@ohos.net.http`：
 *   - SSDP 是 UDP 组播，http 模块只管 HTTP；
 *   - SOAP 的 `SOAPACTION` 头与 `text/xml` 体虽然 http 模块能做，
 *     但为了与发现/描述共用一套取址与超时逻辑，统一走 `SocketHttp`。
 *
 * 与源码的差异：源码用 `dlna_dart` 包（内含完整的 UPnP 协议栈），
 * 这里只实现「发现 + 投一个地址 + 播放」这三步——够用且不引入整包移植。
 * 音量、进度回传、停止投屏等控制项留在后续（`SetVolume` / `Seek` 同属一个 SOAP 服务）。
 */
export class DlnaCaster {
  private static readonly ssdpAddress: string = '239.255.255.250';
  private static readonly ssdpPort: number = 1900;
  /**
   * 兼容不同年代的电视/盒子：
   *   - 只搜 MediaRenderer:1 时，只声明 v2 / v3 的设备不会回应；
   *   - ssdp:all 用来捞只回应 rootdevice 的少量 renderer。
   * 真正是否是投屏设备，最终仍由设备描述里的 MediaRenderer + AVTransport 判定。
   */
  private static readonly searchTargets: string[] = [
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'urn:schemas-upnp-org:device:MediaRenderer:2',
    'urn:schemas-upnp-org:device:MediaRenderer:3',
    'ssdp:all'
  ];

  /**
   * 搜索局域网里的可投屏设备。
   *
   * @param timeoutMs 收包窗口（默认 3 秒，足够覆盖大多数设备的响应延迟）
   */
  static async discover(timeoutMs: number): Promise<DlnaDevice[]> {
    const devices: DlnaDevice[] = [];
    const locations: string[] = [];
    const udp: socket.MulticastSocket = socket.constructMulticastSocketInstance();
    try {
      await udp.bind({ address: '0.0.0.0', port: 0 });
      udp.on('message', (info: socket.SocketMessageInfo) => {
        const text: string = new util.TextDecoder().decodeToString(
          new Uint8Array(info.message));
        const location: string = DlnaCaster.headerOf(text, 'location');
        if (location.length > 0 && locations.indexOf(location) < 0 &&
          locations.length < 32) {
          locations.push(location);
        }
      });
      udp.on('error', (error) => {
        Logger.warn(TAG, `SSDP socket 错误：${error.message}`);
      });
      await udp.setMulticastTTL(2);

      /**
       * 连续两轮：第一轮发多版本 MediaRenderer，第二轮补 ssdp:all。
       * 同时发一份受限广播，避免部分路由器拦截 239.255.255.250 组播。
       */
      const destinations: string[] = [DlnaCaster.ssdpAddress, '255.255.255.255'];
      for (let pass = 0; pass < DlnaCaster.searchTargets.length; pass++) {
        const search: string = 'M-SEARCH * HTTP/1.1\r\n'
          + `HOST: ${DlnaCaster.ssdpAddress}:${DlnaCaster.ssdpPort}\r\n`
          + 'MAN: "ssdp:discover"\r\n'
          + 'MX: 2\r\n'
          + `ST: ${DlnaCaster.searchTargets[pass]}\r\n\r\n`;
        for (let i = 0; i < destinations.length; i++) {
          try {
            await udp.send({
              data: search,
              address: {
                address: destinations[i],
                port: DlnaCaster.ssdpPort
              }
            });
          } catch (error) {
            const err = error as Error;
            Logger.warn(TAG,
              `SSDP 发送失败（${destinations[i]}）：${err.message}`);
          }
        }
        if (pass === 0) {
          await DlnaCaster.sleep(120);
        }
      }
      Logger.info(TAG, '已发出 SSDP 搜索（MediaRenderer 1/2/3 + ssdp:all）');
      await DlnaCaster.sleep(timeoutMs);
    } catch (error) {
      const err = error as Error;
      Logger.error(TAG, `SSDP 搜索失败：${err.message}`);
      return devices;
    } finally {
      try {
        await udp.close();
      } catch (error) {
        // 关闭失败忽略
      }
    }
    for (let i = 0; i < locations.length; i++) {
      const device: DlnaDevice | null =
        await DlnaCaster.describe(locations[i]);
      if (device !== null && device.controlUrl.length > 0) {
        devices.push(device);
      }
    }
    Logger.info(TAG, `发现 ${devices.length} 个可投屏设备`);
    return devices;
  }

  /**
   * 不依赖 SSDP，直接从用户输入的设备地址建立投屏端点。
   *
   * 手机热点和不少访客网络会拦截 239.255.255.250 组播，但普通 TCP 仍然可达。
   * 用户可以只输入设备 IP；这里会再尝试 Kodi 的常见描述端口，避免把
   * `1116` 和完整 UPnP URL 暴露成普通用户的必填知识。
   */
  static async fromDescriptionUrl(address: string): Promise<DlnaDevice | null> {
    const candidates: string[] = DlnaCaster.descriptionCandidates(address);
    for (let i = 0; i < candidates.length; i++) {
      const device: DlnaDevice | null =
        await DlnaCaster.describe(candidates[i], 2500);
      if (device !== null) {
        return device;
      }
    }
    return null;
  }

  /** 取设备描述 XML，解析名字与 AVTransport 控制地址。 */
  private static async describe(location: string,
    timeoutMs: number = 5000): Promise<DlnaDevice | null> {
    const client = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(location, {
        method: http.RequestMethod.GET,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        return null;
      }
      const xml: string = `${response.result}`;
      const device = new DlnaDevice();
      device.location = location;
      if (!DlnaCaster.isMediaRenderer(xml)) {
        return null;
      }
      device.name = DlnaCaster.tagText(xml, 'friendlyName');
      if (device.name.length === 0) {
        device.name = 'DLNA 设备';
      }
      const endpoint: DlnaServiceEndpoint | null =
        DlnaCaster.avTransportOf(xml, location);
      if (endpoint === null) {
        return null;
      }
      device.controlUrl = endpoint.controlUrl;
      device.serviceType = endpoint.serviceType;
      return device;
    } catch (error) {
      const err = error as Error;
      Logger.warn(TAG, `读取设备描述失败：${err.message}`);
      return null;
    } finally {
      client.destroy();
    }
  }

  /**
   * 投屏：先 SetAVTransportURI 再 Play。
   *
   * 成功后**本机播放应该暂停**（源码里是「先暂停本机，投屏完成后若原先在播放则恢复」），
   * 这一步由调用方决定——播放页在发起投屏前会自己暂停。
   */
  static async cast(device: DlnaDevice, videoUrl: string,
    title: string): Promise<DlnaCastResult> {
    const result = new DlnaCastResult();
    if (device.controlUrl.length === 0) {
      result.message = '设备不支持播放控制';
      return result;
    }
    if (!videoUrl.startsWith('http://') && !videoUrl.startsWith('https://')) {
      result.message = '当前是本地地址，DLNA 电视无法直接访问';
      return result;
    }
    if (DlnaCaster.urlPath(videoUrl).endsWith('.m4s')) {
      result.message = '当前是 DASH 分离视频流，电视通常无法直接播放';
      return result;
    }
    try {
      const setUri: http.HttpResponse = await DlnaCaster.soap(device,
        'SetAVTransportURI',
        '<InstanceID>0</InstanceID>'
          + `<CurrentURI>${DlnaCaster.escapeXml(videoUrl)}</CurrentURI>`
          + `<CurrentURIMetaData>${DlnaCaster.metadata(title, videoUrl)}</CurrentURIMetaData>`);
      if (setUri.responseCode < 200 || setUri.responseCode >= 300) {
        result.message = DlnaCaster.soapFailure('设备拒绝投屏',
          setUri.responseCode, `${setUri.result}`);
        return result;
      }
      const play: http.HttpResponse = await DlnaCaster.soap(device, 'Play',
        '<InstanceID>0</InstanceID><Speed>1</Speed>');
      if (play.responseCode < 200 || play.responseCode >= 300) {
        result.message = DlnaCaster.soapFailure('设备拒绝播放',
          play.responseCode, `${play.result}`);
        return result;
      }
      result.ok = true;
      result.message = `已发送播放指令到「${device.name}」`;
      Logger.info(TAG, result.message);
      return result;
    } catch (error) {
      const err = error as Error;
      result.message = `投屏失败：${err.message}`;
      Logger.error(TAG, result.message);
      return result;
    }
  }

  /** 发一段 SOAP 动作。 */
  private static async soap(device: DlnaDevice, action: string,
    args: string): Promise<http.HttpResponse> {
    const serviceType: string = device.serviceType.length > 0
      ? device.serviceType
      : 'urn:schemas-upnp-org:service:AVTransport:1';
    const body: string = '<?xml version="1.0" encoding="utf-8"?>'
      + '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
      + ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      + '<s:Body>'
      + `<u:${action} xmlns:u="${serviceType}">`
      + args
      + `</u:${action}>`
      + '</s:Body></s:Envelope>';
    const headers: Record<string, string> = {};
    headers['Content-Type'] = 'text/xml; charset="utf-8"';
    headers['SOAPACTION'] = `"${serviceType}#${action}"`;
    const client: http.HttpRequest = http.createHttp();
    try {
      return await client.request(device.controlUrl, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 5000,
        readTimeout: 15000
      });
    } finally {
      client.destroy();
    }
  }

  /** DIDL-Lite 元数据（多数设备不填也能播，但填了兼容性更好）。 */
  private static metadata(title: string, url: string): string {
    const mime: string = DlnaCaster.mimeOf(url);
    const didl: string = '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"'
      + ' xmlns:dc="http://purl.org/dc/elements/1.1/"'
      + ' xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      + '<item id="0" parentID="-1" restricted="1">'
      + `<dc:title>${DlnaCaster.escapeXml(title)}</dc:title>`
      + '<upnp:class>object.item.videoItem</upnp:class>'
      + `<res protocolInfo="http-get:*:${mime}:*">${DlnaCaster.escapeXml(url)}</res>`
      + '</item></DIDL-Lite>';
    return DlnaCaster.escapeXml(didl);
  }

  // ---------------- 小工具 ----------------

  /** 从 SSDP 回包/HTTP 头里取某个头的值（大小写不敏感）。 */
  private static headerOf(text: string, name: string): string {
    const lines: string[] = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const colon: number = lines[i].indexOf(':');
      if (colon <= 0) {
        continue;
      }
      if (lines[i].substring(0, colon).trim().toLowerCase() === name) {
        return lines[i].substring(colon + 1).trim();
      }
    }
    return '';
  }

  /** 取 XML 里某个简单标签的文本。 */
  private static tagText(xml: string, tag: string): string {
    const pattern = new RegExp(
      `<(?:(?:[\\w.-]+):)?${tag}(?:\\s[^>]*)?>([\\s\\S]*?)` +
      `</(?:(?:[\\w.-]+):)?${tag}\\s*>`, 'i');
    const match: RegExpExecArray | null = pattern.exec(xml);
    return match === null ? '' : DlnaCaster.decodeXml(match[1].trim());
  }

  /**
   * 从设备描述里找 AVTransport 服务及其 controlURL。
   *
   * 描述里的 URL 可能是相对路径，要按 LOCATION 的目录补全。
   */
  private static avTransportOf(xml: string,
    location: string): DlnaServiceEndpoint | null {
    const pattern = /<service(?:\s[^>]*)?>([\s\S]*?)<\/service>/gi;
    let match: RegExpExecArray | null = pattern.exec(xml);
    while (match !== null) {
      const block: string = match[1];
      const serviceType: string = DlnaCaster.tagText(block, 'serviceType');
      if (serviceType.indexOf('service:AVTransport:') >= 0) {
        const raw: string = DlnaCaster.tagText(block, 'controlURL');
        if (raw.length > 0) {
          const endpoint = new DlnaServiceEndpoint();
          endpoint.serviceType = serviceType;
          endpoint.controlUrl = DlnaCaster.absoluteUrl(raw, location);
          return endpoint;
        }
      }
      match = pattern.exec(xml);
    }
    return null;
  }

  /** 设备描述是否真的是 MediaRenderer，而不是局域网里的 MediaServer。 */
  private static isMediaRenderer(xml: string): boolean {
    const deviceType: string = DlnaCaster.tagText(xml, 'deviceType');
    return deviceType.indexOf(':device:MediaRenderer:') >= 0;
  }

  /** 按 UPnP LOCATION 的目录补全 controlURL。 */
  private static absoluteUrl(raw: string, location: string): string {
    const value: string = raw.trim();
    const schemeEnd: number = location.indexOf('://');
    if (schemeEnd <= 0) {
      return value;
    }
    const scheme: string = location.substring(0, schemeEnd);
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.startsWith('//')) {
      return `${scheme}:${value}`;
    }
    const rest: string = location.substring(schemeEnd + 3);
    const slash: number = rest.indexOf('/');
    const origin: string = slash < 0
      ? location : location.substring(0, schemeEnd + 3 + slash);
    if (value.startsWith('/')) {
      return `${origin}${value}`;
    }
    const locationPath: string = slash < 0 ? '/' : rest.substring(slash);
    const baseEnd: number = locationPath.lastIndexOf('/');
    const base: string = baseEnd < 0 ? '/' : locationPath.substring(0, baseEnd + 1);
    return DlnaCaster.normalizeUrl(`${origin}${base}${value}`);
  }

  /**
   * 直连候选。
   *
   * 完整 URL：只试用户给的那一个；
   * `IP:端口`：补 `/`；
   * 纯 IP：先试标准 HTTP，再试 Kodi 默认的 UPnP 描述端口 1116。
   */
  private static descriptionCandidates(address: string): string[] {
    let value: string = address.trim();
    if (value.length === 0) {
      return [];
    }
    const hasScheme: boolean = /^https?:\/\//i.test(value);
    if (hasScheme) {
      return value.indexOf('/', value.indexOf('://') + 3) < 0
        ? [`${value}/`] : [value];
    }
    if (value.indexOf('/') >= 0) {
      return [`http://${value}`];
    }
    const candidates: string[] = [`http://${value}/`];
    if (value.indexOf(':') < 0) {
      candidates.push(`http://${value}:1116/`);
    }
    return candidates;
  }

  /** 去掉相对路径里的 `./` 与 `../`。 */
  private static normalizeUrl(url: string): string {
    const queryAt: number = url.indexOf('?');
    const suffix: string = queryAt < 0 ? '' : url.substring(queryAt);
    const plain: string = queryAt < 0 ? url : url.substring(0, queryAt);
    const schemeEnd: number = plain.indexOf('://');
    if (schemeEnd <= 0) {
      return url;
    }
    const rest: string = plain.substring(schemeEnd + 3);
    const slash: number = rest.indexOf('/');
    if (slash < 0) {
      return `${plain}${suffix}`;
    }
    const origin: string = plain.substring(0, schemeEnd + 3 + slash);
    const parts: string[] = rest.substring(slash + 1).split('/');
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const part: string = parts[i];
      if (part.length === 0 || part === '.') {
        continue;
      }
      if (part === '..') {
        if (out.length > 0) {
          out.pop();
        }
        continue;
      }
      out.push(part);
    }
    return `${origin}/${out.join('/')}${suffix}`;
  }

  /** DIDL-Lite 的 protocolInfo 使用具体 MIME，比 `video/*` 兼容面更广。 */
  private static mimeOf(url: string): string {
    const path: string = DlnaCaster.urlPath(url).toLowerCase();
    if (path.endsWith('.m3u8')) {
      return 'application/vnd.apple.mpegurl';
    }
    if (path.endsWith('.mp4') || path.endsWith('.m4v')) {
      return 'video/mp4';
    }
    if (path.endsWith('.ts')) {
      return 'video/mp2t';
    }
    if (path.endsWith('.webm')) {
      return 'video/webm';
    }
    if (path.endsWith('.mkv')) {
      return 'video/x-matroska';
    }
    return 'video/mp4';
  }

  /** 去掉 query / fragment 的路径，仅用于扩展名判断。 */
  private static urlPath(url: string): string {
    const queryAt: number = url.indexOf('?');
    const withoutQuery: string = queryAt < 0 ? url : url.substring(0, queryAt);
    const hashAt: number = withoutQuery.indexOf('#');
    return hashAt < 0 ? withoutQuery : withoutQuery.substring(0, hashAt);
  }

  private static soapFailure(prefix: string, status: number, body: string): string {
    const description: string = DlnaCaster.tagText(body, 'errorDescription');
    const fault: string = description.length > 0
      ? description : DlnaCaster.tagText(body, 'faultstring');
    const detail: string = fault.length > 0 ? `：${fault}` : '';
    Logger.warn(TAG, `${prefix}（HTTP ${status}）${body.substring(0, 300)}`);
    return `${prefix}（HTTP ${status}${detail}）`;
  }

  private static decodeXml(text: string): string {
    return text.split('&lt;').join('<')
      .split('&gt;').join('>')
      .split('&quot;').join('"')
      .split('&apos;').join('\'')
      .split('&amp;').join('&');
  }

  private static escapeXml(text: string): string {
    return text.split('&').join('&amp;')
      .split('<').join('&lt;')
      .split('>').join('&gt;')
      .split('"').join('&quot;');
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }
}
