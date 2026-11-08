import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { SettingsKeys } from '../../services/storage/SettingsKeys';
import { SettingsStore } from '../../services/storage/SettingsStore';
import { HttpHeaders } from './HttpHeaders';
import { BangumiMirrorInterceptor } from './MirrorInterceptors';
import { NetworkConfig } from './NetworkConfig';
import { NetworkErrorMapper, NetworkException } from './NetworkException';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnHttp';

/** 一次请求的结果。失败时 `error` 非空，`body` 为空串。 */
export class ApiResponse {
  readonly ok: boolean;
  readonly statusCode: number;
  readonly body: string;
  readonly error: NetworkException | null;
  /** 实际请求地址（已经过仓库候选切换）。 */
  readonly requestUrl: string;

  constructor(ok: boolean, statusCode: number, body: string,
    error: NetworkException | null, requestUrl: string = '') {
    this.ok = ok;
    this.statusCode = statusCode;
    this.body = body;
    this.error = error;
    this.requestUrl = requestUrl;
  }
}

/**
 * 一次**原始字节**请求的结果。
 *
 * 与 `ApiResponse` 并列存在的原因：有些接口返回的是压缩体
 * （哔哩哔哩弹幕 `x/v1/dm/list.so` 就是 `Content-Encoding: deflate` +
 * 裸 DEFLATE），
 * 让 `@ohos.net.http` 按 STRING 解码只会得到乱码，必须拿到字节自己解压。
 */
export class ApiBytesResponse {
  readonly ok: boolean;
  readonly statusCode: number;
  readonly bytes: Uint8Array;
  readonly error: NetworkException | null;

  constructor(ok: boolean, statusCode: number, bytes: Uint8Array,
    error: NetworkException | null) {
    this.ok = ok;
    this.statusCode = statusCode;
    this.bytes = bytes;
    this.error = error;
  }
}

/** 客户端角色，决定挂哪个镜像拦截器。 */
enum ClientRole {
  api = 0,
  rulesRepo = 1,
  plugin = 2,
  download = 3,
  /**
   * 与 `api` 同一套请求头 / 超时，但**不做 Bangumi 镜像改写**。
   *
   * 用途：镜像链路整体不可用时的**官方直连兜底**（2026-09-19：`api.bgmapi.com`
   * 整站 502，而搜索走的是「无凭据 → 兼容镜像」这条唯一的路，于是搜索直接空结果；
   * 见 `BangumiApi.retryWithCompatibleMirror`）。
   */
  apiDirect = 4
}

/**
 * HTTP 客户端。
 *
 * 对应参照实现 `lib/request/core/dio_factory.dart`：
 * 四个按用途分离的懒加载单例，各自的默认请求头与拦截器不同：
 *
 * | 实例 | 默认头 | 拦截器 | 超时 |
 * | apiDio | referer 空 + 随机 UA | Bangumi 镜像 | 默认 12s |
 * | rulesRepoDio | 随机 UA | 规则仓库镜像 | 默认 12s |
 * | pluginDio | 随机 UA + 随机 accept-language | 无 | 默认 12s |
 * | downloadDio | 随机 UA | 无 | **15s / 30s** |
 *
 * 与 Dio 的差别：Dio 复用连接池，鸿蒙 NetworkKit 这里每次请求建一个
 * HttpRequest 对象（用完 destroy），语义等价、行为更可控；
 * 并发较高时（下载分片）会另做连接数控制。
 */
export class ApiClient {
  // 字段名不能与下面的静态工厂方法同名（ArkTS 不允许同名的静态成员与方法）
  private static apiInstance: ApiClient | null = null;
  private static apiDirectInstance: ApiClient | null = null;
  private static rulesRepoInstance: ApiClient | null = null;
  private static pluginInstance: ApiClient | null = null;
  private static downloadInstance: ApiClient | null = null;

  private readonly config: NetworkConfig;
  private readonly defaultHeaders: Record<string, string>;
  private readonly role: ClientRole;

  private constructor(config: NetworkConfig, defaultHeaders: Record<string, string>,
    role: ClientRole) {
    this.config = config;
    this.defaultHeaders = defaultHeaders;
    this.role = role;
  }

  static apiDio(): ApiClient {
    if (ApiClient.apiInstance === null) {
      const headers: Record<string, string> = {};
      headers['referer'] = '';
      headers['user-agent'] = HttpHeaders.randomUserAgent();
      ApiClient.apiInstance =
        new ApiClient(NetworkConfig.fromSettings(), headers, ClientRole.api);
    }
    return ApiClient.apiInstance;
  }

  /**
   * 官方直连客户端（**不套镜像**）：供 `BangumiApi` 在镜像全挂时兜底。
   *
   * 与 `apiDio()` 的区别只有一条：`applyMirror` 不改写地址。
   */
  static apiDirectDio(): ApiClient {
    if (ApiClient.apiDirectInstance === null) {
      const headers: Record<string, string> = {};
      headers['referer'] = '';
      headers['user-agent'] = HttpHeaders.randomUserAgent();
      ApiClient.apiDirectInstance =
        new ApiClient(NetworkConfig.fromSettings(), headers, ClientRole.apiDirect);
    }
    return ApiClient.apiDirectInstance;
  }

  static rulesRepoDio(): ApiClient {
    if (ApiClient.rulesRepoInstance === null) {
      const headers: Record<string, string> = {};
      headers['user-agent'] = HttpHeaders.randomUserAgent();
      ApiClient.rulesRepoInstance =
        new ApiClient(NetworkConfig.fromSettings(6000, 8000, 0), headers,
          ClientRole.rulesRepo);
    }
    return ApiClient.rulesRepoInstance;
  }

  static pluginDio(): ApiClient {
    if (ApiClient.pluginInstance === null) {
      const headers: Record<string, string> = {};
      headers['user-agent'] = HttpHeaders.randomUserAgent();
      headers['accept-language'] = HttpHeaders.randomAcceptedLanguage();
      ApiClient.pluginInstance =
        new ApiClient(NetworkConfig.fromSettings(), headers, ClientRole.plugin);
    }
    return ApiClient.pluginInstance;
  }

  /** 下载专用：连接 15s / 接收 30s（与源码一致）。 */
  static downloadDio(): ApiClient {
    if (ApiClient.downloadInstance === null) {
      const headers: Record<string, string> = {};
      headers['user-agent'] = HttpHeaders.randomUserAgent();
      ApiClient.downloadInstance = new ApiClient(
        NetworkConfig.fromSettings(15000, 30000, 0), headers, ClientRole.download);
    }
    return ApiClient.downloadInstance;
  }

  /** 按自定义配置建一个客户端（源码 `createForConfig`）。 */
  static createForConfig(config: NetworkConfig): ApiClient {
    const headers: Record<string, string> = {};
    headers['user-agent'] = HttpHeaders.randomUserAgent();
    return new ApiClient(config, headers, ClientRole.plugin);
  }

  /** 设置变化后清空单例（源码 `reset`）。代理、镜像开关变更时必须调用。 */
  static reset(): void {
    ApiClient.apiInstance = null;
    ApiClient.apiDirectInstance = null;
    ApiClient.rulesRepoInstance = null;
    ApiClient.pluginInstance = null;
    ApiClient.downloadInstance = null;
  }

  async get(url: string): Promise<ApiResponse> {
    return await this.request(url, http.RequestMethod.GET, undefined);
  }

  async post(url: string, body: string): Promise<ApiResponse> {
    return await this.request(url, http.RequestMethod.POST, body);
  }

  /**
   * 带额外请求头的请求。
   * 规则站点要用自己的 referer / cookie / user-agent，且这些头要能覆盖默认头。
   */
  async requestWith(url: string, method: http.RequestMethod, body: string | undefined,
    extraHeaders: Record<string, string>): Promise<ApiResponse> {
    return await this.request(url, method, body, extraHeaders);
  }

  /**
   * GET 的**字节版**：不把响应体解成字符串。
   *
   * 用途只有一个：拿压缩过的响应体（哔哩哔哩弹幕 XML）。
   * 其余行为（镜像改写、代理、超时、默认请求头、日志）与 `request()` 一致。
   */
  async getBytes(url: string,
    extraHeaders?: Record<string, string>): Promise<ApiBytesResponse> {
    const finalUrl: string = this.applyMirror(url, 'GET');
    const startedAt: number = Date.now();
    const client: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions =
        this.buildOptions(http.RequestMethod.GET, undefined, extraHeaders);
      options.expectDataType = http.HttpDataType.ARRAY_BUFFER;
      const response: http.HttpResponse = await client.request(finalUrl, options);
      const bytes: Uint8Array = ApiClient.bytesOf(response.result);
      if (this.config.enableLog) {
        hilog.info(DOMAIN, TAG,
          'GET %{public}s -> %{public}d (%{public}d 字节, %{public}dms)',
          finalUrl, response.responseCode, bytes.length,
          Date.now() - startedAt);
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        return new ApiBytesResponse(false, response.responseCode,
          new Uint8Array(0),
          NetworkErrorMapper.badResponse(response.responseCode, ''));
      }
      return new ApiBytesResponse(true, response.responseCode, bytes, null);
    } catch (err) {
      const e = err as BusinessErrorLike;
      const code: number = e.code === undefined ? 0 : e.code;
      const message: string = e.message === undefined ? `${err}` : e.message;
      hilog.error(DOMAIN, TAG, '请求失败 %{public}s : %{public}s',
        finalUrl, `${code} ${message}`);
      return new ApiBytesResponse(false, 0, new Uint8Array(0),
        NetworkErrorMapper.map(code, message));
    } finally {
      client.destroy();
    }
  }

  /**
   * 发请求。
   *
   * 镜像改写发生在发请求之前——与 Dio 拦截器的 `onRequest` 时机一致。
   */
  async request(url: string, method: http.RequestMethod,
    body: string | undefined,
    extraHeaders?: Record<string, string>): Promise<ApiResponse> {
    const finalUrl: string = this.applyMirror(url, ApiClient.methodName(method));
    const startedAt: number = Date.now();
    const client: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions =
        this.buildOptions(method, body, extraHeaders);
      const response: http.HttpResponse = await client.request(finalUrl, options);
      const text: string = ApiClient.bodyOf(response.result);
      if (this.config.enableLog) {
        hilog.info(DOMAIN, TAG, '%{public}s %{public}s -> %{public}d (%{public}dms)',
          ApiClient.methodName(method), finalUrl, response.responseCode,
          Date.now() - startedAt);
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        return new ApiResponse(false, response.responseCode, '',
          NetworkErrorMapper.badResponse(response.responseCode, text), finalUrl);
      }
      return new ApiResponse(true, response.responseCode, text, null, finalUrl);
    } catch (err) {
      const e = err as BusinessErrorLike;
      const code: number = e.code === undefined ? 0 : e.code;
      const message: string = e.message === undefined ? `${err}` : e.message;
      hilog.error(DOMAIN, TAG, '请求失败 %{public}s : %{public}s',
        finalUrl, `${code} ${message}`);
      return new ApiResponse(false, 0, '',
        NetworkErrorMapper.map(code, message), finalUrl);
    } finally {
      client.destroy();
    }
  }

  private buildOptions(method: http.RequestMethod,
    body: string | undefined,
    extraHeaders?: Record<string, string>): http.HttpRequestOptions {
    const headers: Record<string, string> = {};
    const keys: string[] = Object.keys(this.defaultHeaders);
    for (let i = 0; i < keys.length; i++) {
      headers[keys[i]] = this.defaultHeaders[keys[i]];
    }
    if (extraHeaders !== undefined) {
      const extraKeys: string[] = Object.keys(extraHeaders);
      for (let i = 0; i < extraKeys.length; i++) {
        headers[extraKeys[i]] = extraHeaders[extraKeys[i]];
      }
    }
    headers['accept'] = 'application/json';
    if (body !== undefined) {
      headers['content-type'] = 'application/json';
    }
    const options: http.HttpRequestOptions = {
      method: method,
      header: headers,
      connectTimeout: this.config.connectTimeoutMs,
      readTimeout: this.config.receiveTimeoutMs,
      expectDataType: http.HttpDataType.STRING,
      // Gitee raw 会 302 到 raw.giteeusercontent.com。默认不跟随时，
      // 规则仓库和 bilibili.json 会被误判成 HTTP 302 失败。
      maxRedirects: 5
    };
    if (body !== undefined) {
      options.extraData = body;
    }
    if (this.config.hasProxy) {
      const proxy: http.HttpProxy = {
        host: this.config.proxyHost,
        port: this.config.proxyPort,
        // 走代理时不排除任何地址（对应源码 `findProxy` 的全局 PROXY 语义）
        exclusionList: []
      };
      options.usingProxy = proxy;
    }
    return options;
  }

  /** 按客户端角色套用镜像拦截器。 */
  private applyMirror(url: string, method: string): string {
    if (this.role === ClientRole.api) {
      const enableBangumiProxy: boolean =
        SettingsStore.getBool(SettingsKeys.enableBangumiProxy);
      return BangumiMirrorInterceptor.rewrite(url, method, enableBangumiProxy);
    }
    if (this.role === ClientRole.rulesRepo) {
      // 规则仓库的镜像候选由 PluginCatalogApi 逐跳尝试；这里保留传入地址，
      // 否则第一跳失败后会被拦截器再次改写，永远回不到备用镜像。
      return url;
    }
    return url;
  }

  private static methodName(method: http.RequestMethod): string {
    return method === http.RequestMethod.POST ? 'POST' : 'GET';
  }

  /** 响应体统一成字符串（expectDataType 已要求 STRING，这里兜底）。 */
  private static bodyOf(result: string | Object | ArrayBuffer): string {
    if (typeof result === 'string') {
      return result as string;
    }
    if (result === undefined || result === null) {
      return '';
    }
    return JSON.stringify(result);
  }

  /**
   * 响应体统一成字节。
   *
   * `expectDataType: ARRAY_BUFFER` 时是 `ArrayBuffer`；个别实现会回字符串
   * （例如代理改写过），这里一并兜住，保证调用方拿到的一定是 `Uint8Array`。
   */
  private static bytesOf(result: string | Object | ArrayBuffer): Uint8Array {
    if (result === undefined || result === null) {
      return new Uint8Array(0);
    }
    if (typeof result === 'string') {
      return new util.TextEncoder().encodeInto(result as string);
    }
    if (result instanceof ArrayBuffer) {
      return new Uint8Array(result as ArrayBuffer);
    }
    return new util.TextEncoder().encodeInto(JSON.stringify(result));
  }
}

/** BusinessError 的最小形状（避免在业务层 import 整个基础服务包）。 */
interface BusinessErrorLike {
  code?: number;
  message?: string;
}
