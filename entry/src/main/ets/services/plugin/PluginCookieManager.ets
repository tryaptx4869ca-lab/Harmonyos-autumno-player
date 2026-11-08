import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { JsonUtils } from '../../model/JsonUtils';
import { Logger } from '../Logger';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnCookie';
/** 落盘文件名（应用私有目录，跟其它数据放一起）。 */
const STORE_FILE: string = 'plugin_cookies.json';

/** 落盘结构里的一条 Cookie。 */
interface StoredCookie {
  name: string;
  value: string;
  domain: string;
  path: string;
}

/** 落盘结构里的一个插件。 */
interface StoredPlugin {
  key: string;
  ua: string;
  cookies: StoredCookie[];
}

/** 一条 Cookie。 */
class PluginCookie {
  readonly name: string;
  readonly value: string;
  readonly domain: string;
  readonly path: string;

  constructor(name: string, value: string, domain: string, path: string) {
    this.name = name;
    this.value = value;
    this.domain = domain;
    this.path = path;
  }
}

/**
 * 每插件的 Cookie 隔离。
 * 逐字段移植自参照实现 `lib/services/plugin/plugin_cookie_manager.dart`。
 *
 * 关键行为：
 *   - **每个插件一套独立存储**，不同规则站点的登录态互不污染
 *   - 验证 Cookie 与 User-Agent 绑定，因此同时记录 WebView 的 UA，
 *     后续请求要对齐同一 UA（否则会被重新判定为验证页）
 *   - Cookie **只在本次 App 会话内有效**（源码注释明确：重启后需重新验证）
 */
export class PluginCookieManager {
  private static jars: Map<string, PluginCookie[]> = new Map<string, PluginCookie[]>();
  private static userAgents: Map<string, string> = new Map<string, string>();
  private static filePath: string = '';
  private static loaded: boolean = false;

  /**
   * 启动时调用：把上一次验证得到的 Cookie / UA 读回来。
   *
   * 为什么必须落盘（用户 2026-09-19：「giriGiriLove 我已经过了验证、看了一次，
   * 退出再打开别的，又要验证一遍」）：验证态是「站点发的一张 Cookie + 当时那个
   * UA」的组合，内存态一退出就没了，用户每次冷启动都得重新过一次验证码。
   * 参照实现同样是内存态（Hive box 只在本进程里），这里按照用户的明确要求
   * 做成持久化——**只存私有目录**，与「不可用规则名单」同款做法。
   */
  static init(context: common.UIAbilityContext): void {
    PluginCookieManager.filePath = `${context.filesDir}/${STORE_FILE}`;
    PluginCookieManager.load();
  }

  /**
   * 统一用「规范化插件名」做键（对应 `pluginNameKey`）。
   *
   * 参照实现 `plugin_cookie_manager.dart` 直接用原始 `pluginName` 做键——
   * 它在全流程里传的都是 `plugin.name`，所以天然一致；而本工程的状态表
   * （`PluginSearchService`）用的是小写键，验证入口拿到的就是小写名。
   * 真机踩过：验证时存成 `girigirilove`、重搜时按 `giriGiriLove` 取，
   * 结果**重搜一个 Cookie 都没带**，站点自然又判需验证。
   * 在存/取两侧都归一化，这类大小写错配就再也发生不了。
   */
  private static keyOf(pluginName: string): string {
    return pluginName.toLowerCase();
  }

  /** 保存 WebView 抓到的 `document.cookie` 字符串与当时的 UA。 */
  static saveFromWebView(pluginName: string, pageUrl: string, cookieString: string,
    userAgent: string): void {
    const key: string = PluginCookieManager.keyOf(pluginName);
    const ua: string = userAgent.trim();
    if (ua.length > 0) {
      PluginCookieManager.userAgents.set(key, ua);
    }
    const raw: string = cookieString.trim();
    if (raw.length === 0) {
      return;
    }
    const host: string = PluginCookieManager.hostOf(pageUrl);
    if (host.length === 0) {
      return;
    }
    const jar: PluginCookie[] =
      PluginCookieManager.jars.get(key) ?? [];
    const parsed: PluginCookie[] = PluginCookieManager.parse(raw, host);
    if (parsed.length === 0) {
      return;
    }
    for (let i = 0; i < parsed.length; i++) {
      PluginCookieManager.upsert(jar, parsed[i]);
    }
    PluginCookieManager.jars.set(key, jar);
    PluginCookieManager.persist();
    hilog.info(DOMAIN, TAG, '为 %{public}s 保存了 %{public}d 个 Cookie',
      pluginName, parsed.length);
    /**
     * 同时写进**应用日志文件**（`我的 → 日志` 可读）。
     *
     * 以前这句只走 hilog：用户报「验证通过后又要求验证」时，我在真机上把
     * 日志文件拉下来却一条 Cookie 记录都没有（hilog 缓冲早已滚动掉），
     * 只能靠猜。这条链路是「验证→重搜」最需要取证的地方，必须落盘。
     */
    Logger.info('AutumnCaptcha',
      `保存 Cookie：${pluginName} 共 ${parsed.length} 个` +
        `（host=${host}，UA=${ua.length > 0 ? '已记录' : '空'}）`);
  }

  /** 组装请求用 Cookie 头；没有则返回空串。 */
  static cookieHeaderFor(pluginName: string, url: string): string {
    const jar: PluginCookie[] | undefined =
      PluginCookieManager.jars.get(PluginCookieManager.keyOf(pluginName));
    if (jar === undefined || jar.length === 0) {
      return '';
    }
    const host: string = PluginCookieManager.hostOf(url);
    const path: string = PluginCookieManager.pathOf(url);
    const parts: string[] = [];
    for (let i = 0; i < jar.length; i++) {
      const cookie: PluginCookie = jar[i];
      if (!PluginCookieManager.domainMatches(host, cookie.domain)) {
        continue;
      }
      if (!path.startsWith(cookie.path)) {
        continue;
      }
      parts.push(`${cookie.name}=${cookie.value}`);
    }
    return parts.join('; ');
  }

  /** 验证时 WebView 使用的 UA；未验证过的插件返回空串。 */
  static userAgentFor(pluginName: string): string {
    const ua: string | undefined =
      PluginCookieManager.userAgents.get(PluginCookieManager.keyOf(pluginName));
    return ua === undefined ? '' : ua;
  }

  static clear(pluginName: string): void {
    PluginCookieManager.jars.delete(pluginName);
    PluginCookieManager.userAgents.delete(pluginName);
    PluginCookieManager.persist();
  }

  private static upsert(jar: PluginCookie[], cookie: PluginCookie): void {
    for (let i = 0; i < jar.length; i++) {
      if (jar[i].name === cookie.name && jar[i].domain === cookie.domain &&
        jar[i].path === cookie.path) {
        jar[i] = cookie;
        return;
      }
    }
    jar.push(cookie);
  }

  private static parse(raw: string, host: string): PluginCookie[] {
    const out: PluginCookie[] = [];
    const parts: string[] = raw.split(';');
    for (let i = 0; i < parts.length; i++) {
      const trimmed: string = parts[i].trim();
      if (trimmed.length === 0) {
        continue;
      }
      const eq: number = trimmed.indexOf('=');
      // 源码要求 eqIndex > 0：形如 `=value` 的片段直接跳过
      if (eq <= 0) {
        continue;
      }
      const name: string = trimmed.substring(0, eq).trim();
      const value: string = trimmed.substring(eq + 1).trim();
      out.push(new PluginCookie(name, value, host, '/'));
    }
    return out;
  }

  private static domainMatches(host: string, domain: string): boolean {
    if (host === domain) {
      return true;
    }
    return host.endsWith(`.${domain}`);
  }

  // ---------------------------------------------------------------- 落盘

  /**
   * 读回落盘的 Cookie / UA。
   *
   * 只做「能读多少读多少」：文件不存在、JSON 坏了、字段类型不对，一律当空表，
   * 绝不让启动过程抛异常（与 `UnavailablePlugins.load` 同款纪律）。
   */
  private static load(): void {
    PluginCookieManager.loaded = true;
    const path: string = PluginCookieManager.filePath;
    if (path.length === 0 || !fileIo.accessSync(path)) {
      return;
    }
    try {
      const stat = fileIo.statSync(path);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const read: number = fileIo.readSync(file.fd, buffer);
        text = new util.TextDecoder().decodeToString(new Uint8Array(buffer, 0, read));
      } finally {
        fileIo.closeSync(file);
      }
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const list: Object[] = JsonUtils.arr(root, 'plugins');
      for (let i = 0; i < list.length; i++) {
        const record: Record<string, Object> | null = JsonUtils.asObj(list[i]);
        if (record === null) {
          continue;
        }
        const key: string = JsonUtils.str(record, 'key').toLowerCase();
        if (key.length === 0) {
          continue;
        }
        const ua: string = JsonUtils.str(record, 'ua').trim();
        if (ua.length > 0) {
          PluginCookieManager.userAgents.set(key, ua);
        }
        const rawCookies: Object[] = JsonUtils.arr(record, 'cookies');
        const jar: PluginCookie[] = [];
        for (let c = 0; c < rawCookies.length; c++) {
          const item: Record<string, Object> | null = JsonUtils.asObj(rawCookies[c]);
          if (item === null) {
            continue;
          }
          const name: string = JsonUtils.str(item, 'name');
          if (name.length === 0) {
            continue;
          }
          jar.push(new PluginCookie(name, JsonUtils.str(item, 'value'),
            JsonUtils.str(item, 'domain'), JsonUtils.str(item, 'path', '/')));
        }
        if (jar.length > 0) {
          PluginCookieManager.jars.set(key, jar);
        }
      }
      Logger.info('AutumnCookie',
        `Cookie 载入：${PluginCookieManager.jars.size} 个插件（UA ${PluginCookieManager.userAgents.size} 条）`);
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, 'Cookie 读取失败（按空处理）：%{public}s', err.message);
    }
  }

  /** 把当前表写回磁盘（`filePath` 为空时静默跳过，便于自检里直接调）。 */
  private static persist(): void {
    const path: string = PluginCookieManager.filePath;
    if (path.length === 0) {
      return;
    }
    const plugins: StoredPlugin[] = [];
    PluginCookieManager.jars.forEach((jar: PluginCookie[], key: string) => {
      const cookies: StoredCookie[] = [];
      for (let i = 0; i < jar.length; i++) {
        const cookie: PluginCookie = jar[i];
        cookies.push({
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain,
          path: cookie.path
        });
      }
      plugins.push({
        key: key,
        ua: PluginCookieManager.userAgents.get(key) ?? '',
        cookies: cookies
      });
    });
    // 只有 UA、没有 Cookie 的插件（验证过但站点没发 Cookie）也要存 UA
    PluginCookieManager.userAgents.forEach((ua: string, key: string) => {
      if (PluginCookieManager.jars.has(key)) {
        return;
      }
      plugins.push({ key: key, ua: ua, cookies: [] });
    });
    const root: Record<string, Object> = {};
    root['plugins'] = plugins;
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(root));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, 'Cookie 写入失败：%{public}s', err.message);
    }
  }

  private static hostOf(url: string): string {
    const schemeEnd: number = url.indexOf('://');
    if (schemeEnd <= 0) {
      return '';
    }
    const rest: string = url.substring(schemeEnd + 3);
    let cut: number = rest.length;
    const slash: number = rest.indexOf('/');
    if (slash >= 0 && slash < cut) {
      cut = slash;
    }
    const question: number = rest.indexOf('?');
    if (question >= 0 && question < cut) {
      cut = question;
    }
    return rest.substring(0, cut).toLowerCase();
  }

  private static pathOf(url: string): string {
    const schemeEnd: number = url.indexOf('://');
    if (schemeEnd <= 0) {
      return '/';
    }
    const rest: string = url.substring(schemeEnd + 3);
    const slash: number = rest.indexOf('/');
    if (slash < 0) {
      return '/';
    }
    const tail: string = rest.substring(slash);
    const question: number = tail.indexOf('?');
    return question < 0 ? tail : tail.substring(0, question);
  }
}
