import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { UrlParts } from '../request/core/UrlParts';
import { Logger } from './Logger';

const TAG: string = 'AutumnSocketHttp';

/** 一次原始 HTTP 响应。 */
export class SocketHttpResponse {
  status: number = 0;
  statusText: string = '';
  /** 小写键的响应头 */
  headers: Map<string, string> = new Map<string, string>();
  body: string = '';

  ok(): boolean {
    return this.status >= 200 && this.status < 300;
  }

  header(name: string): string {
    const value: string | undefined = this.headers.get(name.toLowerCase());
    return value === undefined ? '' : value;
  }
}

/**
 * 最小 HTTP/1.1 客户端（走 `@ohos.net.socket` 的 TCP / TLS 套接字）。
 *
 * ## 为什么不用 `@ohos.net.http`
 *
 * 后端的 `HttpRequestOptions.method` 是**严格枚举**（OPTIONS/GET/HEAD/POST/PUT/
 * DELETE/TRACE/CONNECT），而 WebDAV 与 DLNA 需要枚举里没有的方法：
 *   - WebDAV 建目录要 `MKCOL`、列目录要 `PROPFIND`
 *   - DLNA 的 SOAP 要 `POST`（这个有）+ 自定义 `SOAPACTION` 头（这个没问题）
 * 只能自己发原始请求。
 *
 * ## 实现取舍
 *
 * 一律带 `Connection: close`，靠**对端关闭连接**来判断响应结束——
 * 这样就不用实现 `Transfer-Encoding: chunked` 的解包。
 * 代价是不能复用连接（同步这种低频操作无所谓）。
 */
export class SocketHttp {
  static async request(url: string, method: string,
    headers: Record<string, string>, body: string,
    timeoutMs: number): Promise<SocketHttpResponse> {
    const parts: UrlParts | null = UrlParts.parse(url);
    if (parts === null) {
      throw new Error(`地址无法解析：${url}`);
    }
    const secure: boolean = parts.scheme === 'https';
    const target: HostPort = SocketHttp.splitHostPort(parts.host, secure ? 443 : 80);
    const path: string = `${parts.path.length === 0 ? '/' : parts.path}` +
      (parts.hasQuery ? `?${parts.query}` : '');

    const bodyBytes: number = SocketHttp.byteLength(body);
    let request: string = `${method} ${path} HTTP/1.1\r\n`;
    request += `Host: ${target.host}${target.explicitPort ? `:${target.port}` : ''}\r\n`;
    request += 'Connection: close\r\n';
    // 版本号与 `AppScope/app.json5` 的 versionName 保持一致（2.3.4）
    request += `User-Agent: AutumnO/2.3.4 (HarmonyOS)\r\n`;
    const headerKeys: string[] = Object.keys(headers);
    for (let i = 0; i < headerKeys.length; i++) {
      request += `${headerKeys[i]}: ${headers[headerKeys[i]]}\r\n`;
    }
    request += `Content-Length: ${bodyBytes}\r\n\r\n`;
    request += body;

    const raw: string = secure
      ? await SocketHttp.exchangeTls(target, request, timeoutMs)
      : await SocketHttp.exchangeTcp(target, request, timeoutMs);
    return SocketHttp.parse(raw);
  }

  // ---------------- 传输 ----------------

  private static async exchangeTcp(target: HostPort, request: string,
    timeoutMs: number): Promise<string> {
    const client: socket.TCPSocket = socket.constructTCPSocketInstance();
    try {
      await client.connect({
        address: { address: target.host, port: target.port },
        timeout: timeoutMs
      });
      return await SocketHttp.pump(request, timeoutMs,
        (chunk: string) => {
          // TCPSocket.send 收的是 TCPSendOptions
          client.send({ data: chunk });
        },
        (onData: (text: string) => void, onDone: () => void) => {
          client.on('message', (info: socket.SocketMessageInfo) => {
            onData(new util.TextDecoder().decodeToString(
              new Uint8Array(info.message)));
          });
          client.on('close', () => {
            onDone();
          });
        });
    } finally {
      try {
        await client.close();
      } catch (error) {
        // 已经断开就忽略
      }
    }
  }

  private static async exchangeTls(target: HostPort, request: string,
    timeoutMs: number): Promise<string> {
    const client: socket.TLSSocket = socket.constructTLSSocketInstance();
    try {
      await client.connect({
        address: { address: target.host, port: target.port },
        // TLSConnectOptions 里 secureOptions 是必填项；
        // 空对象表示用系统默认的 TLS 参数（校验证书、默认协议版本）。
        secureOptions: {},
        timeout: timeoutMs
      });
      return await SocketHttp.pump(request, timeoutMs,
        (chunk: string) => {
          // TLSSocket.send 直接收 string | ArrayBuffer
          client.send(chunk);
        },
        (onData: (text: string) => void, onDone: () => void) => {
          client.on('message', (info: socket.SocketMessageInfo) => {
            onData(new util.TextDecoder().decodeToString(
              new Uint8Array(info.message)));
          });
          client.on('close', () => {
            onDone();
          });
        });
    } finally {
      try {
        await client.close();
      } catch (error) {
        // 已经断开就忽略
      }
    }
  }

  /**
   * 发出去、收干净。
   *
   * 三个结束条件：对端关闭、拿到完整响应（`Content-Length` 满足）、超时。
   * 前两个都算成功——很多服务端会保持连接不关（即使我们请求了 close），
   * 只等 close 会一直挂到超时。
   */
  private static async pump(request: string, timeoutMs: number,
    send: (data: string) => void,
    listen: (onData: (text: string) => void, onDone: () => void) => void): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void,
      reject: (reason: Error) => void) => {
      let received: string = '';
      let settled: boolean = false;
      const finish = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        if (received.length === 0) {
          reject(new Error('连接已关闭但没有收到响应'));
          return;
        }
        resolve(received);
      };
      const timer = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        if (received.length === 0) {
          reject(new Error('请求超时'));
          return;
        }
        resolve(received);
      }, timeoutMs);

      listen((text: string) => {
        received += text;
        if (SocketHttp.isResponseComplete(received)) {
          finish();
        }
      }, () => {
        finish();
      });

      Promise.resolve().then(() => {
        send(request);
      }).catch((error: Error) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          reject(new Error(`发送失败：${error.message}`));
        }
      });
    });
  }

  // ---------------- 解析 ----------------

  /** 响应是否已经收全（有 Content-Length 且正文够了）。 */
  private static isResponseComplete(raw: string): boolean {
    const headEnd: number = raw.indexOf('\r\n\r\n');
    if (headEnd < 0) {
      return false;
    }
    const head: string = raw.substring(0, headEnd);
    const length: number = SocketHttp.contentLengthOf(head);
    if (length < 0) {
      return false;
    }
    return SocketHttp.byteLength(raw.substring(headEnd + 4)) >= length;
  }

  private static contentLengthOf(head: string): number {
    const lines: string[] = head.split('\r\n');
    for (let i = 1; i < lines.length; i++) {
      const lower: string = lines[i].toLowerCase();
      if (lower.startsWith('content-length:')) {
        const value: number = Number.parseInt(
          lines[i].substring('content-length:'.length).trim(), 10);
        return Number.isNaN(value) ? -1 : value;
      }
    }
    return -1;
  }

  private static parse(raw: string): SocketHttpResponse {
    const response = new SocketHttpResponse();
    const headEnd: number = raw.indexOf('\r\n\r\n');
    const head: string = headEnd < 0 ? raw : raw.substring(0, headEnd);
    response.body = headEnd < 0 ? '' : raw.substring(headEnd + 4);
    const lines: string[] = head.split('\r\n');
    if (lines.length === 0) {
      return response;
    }
    const statusLine: string = lines[0];
    const firstSpace: number = statusLine.indexOf(' ');
    if (firstSpace > 0) {
      const code: number = Number.parseInt(
        statusLine.substring(firstSpace + 1, firstSpace + 4), 10);
      response.status = Number.isNaN(code) ? 0 : code;
      response.statusText = statusLine.substring(firstSpace + 5);
    }
    for (let i = 1; i < lines.length; i++) {
      const colon: number = lines[i].indexOf(':');
      if (colon <= 0) {
        continue;
      }
      const key: string = lines[i].substring(0, colon).trim().toLowerCase();
      const value: string = lines[i].substring(colon + 1).trim();
      response.headers.set(key, value);
    }
    Logger.info(TAG, `${response.status} ${response.statusText}` +
      `（${response.body.length} 字节正文）`);
    return response;
  }

  // ---------------- 小工具 ----------------

  /** 拆 host 与端口（`UrlParts.host` 里可能带 `:port`）。 */
  private static splitHostPort(host: string, defaultPort: number): HostPort {
    const colon: number = host.lastIndexOf(':');
    if (colon < 0) {
      return new HostPort(host, defaultPort, false);
    }
    const port: number = Number.parseInt(host.substring(colon + 1), 10);
    if (Number.isNaN(port)) {
      return new HostPort(host, defaultPort, false);
    }
    return new HostPort(host.substring(0, colon), port, true);
  }

  /** UTF-8 字节长度（`Content-Length` 要按字节算，不能按字符数）。 */
  private static byteLength(text: string): number {
    if (text.length === 0) {
      return 0;
    }
    return new util.TextEncoder().encodeInto(text).length;
  }

  /** Basic 认证头（用户名或密码为空时不加）。 */
  static basicAuth(user: string, password: string): string {
    if (user.length === 0 && password.length === 0) {
      return '';
    }
    const raw: string = `${user}:${password}`;
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(raw);
    const base64: string = new util.Base64Helper().encodeToStringSync(bytes);
    return `Basic ${base64}`;
  }
}

/** host + port + 是否显式写了端口（拼 Host 头用）。 */
class HostPort {
  host: string = '';
  port: number = 80;
  explicitPort: boolean = false;

  constructor(host: string, port: number, explicitPort: boolean) {
    this.host = host;
    this.port = port;
    this.explicitPort = explicitPort;
  }
}
