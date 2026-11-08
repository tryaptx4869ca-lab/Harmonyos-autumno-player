import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VideoSourceScripts } from './VideoSourceScripts';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnVideo';

/** 一次解析的结果。 */
export class VideoSourceResult {
  readonly url: string;
  readonly channel: string;
  readonly elapsedMs: number;

  constructor(url: string, channel: string, elapsedMs: number) {
    this.url = url;
    this.channel = channel;
    this.elapsedMs = elapsedMs;
  }
}

/**
 * 取流宿主需要参与解析生命周期收尾。
 *
 * giriGiriLove 的播放页会自行播放页面里的 MP4。若解析命中后只把地址交给
 * mpv、却继续把该网页挂在 1×1 Web 里，网页音频会和 mpv 同时输出；暂停
 * mpv 时网页那一路还会继续响。因此解析结束必须由宿主同步静音并卸载页面。
 */
export interface VideoSourceHostLifecycle {
  onCaptureFinished(): void;
}

/**
 * 视频源解析器（服务侧）。
 *
 * 与 UI 的分工：真正的 `Web` 组件由 `pages` 里的宿主组件持有
 * （ArkUI 的 Web 必须先挂到组件树上才能加载页面），
 * 本类只负责：注入脚本、等待、超时、去重、回调收敛。
 *
 * 三条通道（对应 §57.2，OHOS 版）：
 *   1 Response.text 包装（页面用 fetch 取清单）
 *   2 XHR.open 包装（页面用 XHR 取清单）
 *   3 <video> MutationObserver + 轮询（兜底）
 * 前两条在文档开始时注入，第三条在文档结束时注入。
 */
export class VideoSourceResolver {
  private static pending: ((result: VideoSourceResult | null) => void) | null = null;
  private static startedAt: number = 0;
  private static hitUrl: string = '';
  private static hitChannel: string = '';
  private static timeoutMs: number = 20000;
  private static host: VideoSourceHostLifecycle | null = null;

  /** 绑定当前无头宿主；每次页面进入时调用。 */
  static attachHost(host: VideoSourceHostLifecycle): void {
    VideoSourceResolver.host = host;
  }

  /** 页面退出时解绑，防止静态回调持有已销毁的 Web 控制器。 */
  static detachHost(host: VideoSourceHostLifecycle): void {
    if (VideoSourceResolver.host === host) {
      VideoSourceResolver.host = null;
    }
  }

  /**
   * 文档开始注入的通道：
   *   1 静音媒体：防止取流页自动播放时先出声
   *   2 blobParser：捕获 fetch / XHR 的 HLS 清单
   * 早期 video 观察由文档结束注入负责。
   */
  static documentStartScripts(): ScriptItem[] {
    const items: ScriptItem[] = [];
    const mute: ScriptItem = {
      script: VideoSourceScripts.muteMediaScript(),
      scriptRules: ['*']
    };
    const blob: ScriptItem = {
      script: VideoSourceScripts.blobParserScript(),
      scriptRules: ['*']
    };
    items.push(mute);
    items.push(blob);
    return items;
  }

  /** 文档结束注入的兜底通道。 */
  static documentEndScripts(): ScriptItem[] {
    const items: ScriptItem[] = [];
    const fallback: ScriptItem = {
      script: VideoSourceScripts.videoTagParserScript(),
      scriptRules: ['*']
    };
    items.push(fallback);
    return items;
  }

  /**
   * 第几次解析（每次 `resolve` +1）。
   *
   * 超时定时器必须知道自己属于哪一次：否则「上一集那个 20s 定时器」到点时
   * 会把**当前**这一次的 Promise 收敛成 null —— 用户连着切集时，屏幕上就是
   * 「刚点下一集就报解析超时」（2026-09-18）。同理，只有当前这一次的命中
   * 才允许收敛，避免上一页残留的回调把地址写进新的一次。
   */
  private static generation: number = 0;

  /** 开始一次解析：返回 Promise，命中或超时后 resolve。 */
  static resolve(url: string, timeoutMs: number = 20000): Promise<VideoSourceResult | null> {
    // 上一次未结束的先收掉，避免回调泄漏。这里不主动卸载页面：调用方
    // 紧接着就会 loadUrl 新地址，连续导航可能让 about:blank 反过来覆盖新页。
    VideoSourceResolver.finish(null, false);
    VideoSourceResolver.generation += 1;
    const generation: number = VideoSourceResolver.generation;
    VideoSourceResolver.startedAt = Date.now();
    VideoSourceResolver.hitUrl = '';
    VideoSourceResolver.hitChannel = '';
    VideoSourceResolver.timeoutMs = timeoutMs;
    hilog.info(DOMAIN, TAG, '开始解析视频源: %{public}s', url);
    return new Promise<VideoSourceResult | null>((resolve: (r: VideoSourceResult | null) => void) => {
      VideoSourceResolver.pending = resolve;
      setTimeout(() => {
        // 已经被后续的 resolve 取代：这一次的超时定时器直接失效
        if (generation !== VideoSourceResolver.generation) {
          return;
        }
        VideoSourceResolver.finish(null);
      }, timeoutMs);
    });
  }

  /**
   * JS 侧命中回调（由 javaScriptProxy 转发）。
   * 只会用**第一条**命中的地址收敛——后面的都是同一次播放的重复上报。
   */
  static onHit(url: string, channel: string): void {
    if (VideoSourceResolver.pending === null) {
      return;
    }
    if (url.length === 0 || url.startsWith('blob:') || url.indexOf('googleads') >= 0) {
      return;
    }
    hilog.info(DOMAIN, TAG, '命中播放源 (%{public}s): %{public}s', channel, url);
    VideoSourceResolver.hitUrl = url;
    VideoSourceResolver.hitChannel = channel;
    VideoSourceResolver.finish(new VideoSourceResult(url, channel,
      Date.now() - VideoSourceResolver.startedAt));
  }

  /** JS 侧日志（透传到 hilog，便于真机定位）。 */
  static onLog(message: string): void {
    hilog.info(DOMAIN, TAG, '[web] %{public}s', message);
  }

  private static finish(result: VideoSourceResult | null,
    unloadHost: boolean = true): void {
    const resolve = VideoSourceResolver.pending;
    VideoSourceResolver.pending = null;
    // 先让 Web 静音并卸载，再把地址交给 mpv。顺序反过来的话，网页可能
    // 在 mpv 起播前继续出声，用户仍会听到一次短促的重音。
    const host = VideoSourceResolver.host;
    if (unloadHost && host !== null) {
      host.onCaptureFinished();
    }
    if (resolve !== null) {
      resolve(result);
    }
  }

  static get isResolving(): boolean {
    return VideoSourceResolver.pending !== null;
  }
}

/**
 * `javaScriptProxy` 的宿主对象。
 * ArkUI 要求暴露给网页的方法必须是可反射调用的普通方法，
 * 因此这里做一层转发（与阶段 0 验证页同款写法）。
 */
export class VideoSourceBridge {
  /** 透传 JS 日志：宿主可挂上来，把 `[web] ...` 同时显示在界面上。 */
  onLog: (message: string) => void = () => {
  };

  hit(url: string, channel: string): void {
    VideoSourceResolver.onHit(url, channel);
  }

  log(message: string): void {
    VideoSourceResolver.onLog(message);
    this.onLog(message);
  }
}
