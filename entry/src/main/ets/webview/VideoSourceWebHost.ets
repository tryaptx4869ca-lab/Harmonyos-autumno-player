import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  VideoSourceBridge,
  VideoSourceHostLifecycle,
  VideoSourceResolver,
  VideoSourceResult
} from './VideoSourceResolver';
import { VideoSourceScripts } from './VideoSourceScripts';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnVideo';

/** 把普通组件回调包装成解析器可调用的生命周期对象。 */
class VideoSourceCaptureLifecycle implements VideoSourceHostLifecycle {
  private finish: () => void = () => {
  };

  constructor(finish: () => void) {
    this.finish = finish;
  }

  onCaptureFinished(): void {
    this.finish();
  }
}

/**
 * 视频源解析的无头宿主。
 *
 * 为什么必须有这个组件：ArkUI 的 `Web` 只能挂在组件树上才能加载页面，
 * 服务类（VideoSourceResolver）拿不到控制器。因此职责切成两半——
 *   本组件：持有 `Web` + 注入脚本 + 把 JS 回调转给服务
 *   服务：等待 / 超时 / 命中收敛 / 结果分发
 *
 * 尺寸 1×1、透明、不参与命中测试：与参照实现 OHOS 版
 * `Size(1, 1)` 的等价做法一致（见 §57.1）。
 */
@Component
export struct VideoSourceWebHost {
  controller: webview.WebviewController = new webview.WebviewController();
  private bridge: VideoSourceBridge = new VideoSourceBridge();
  /** 要解析的播放页地址；变化时自动加载。 */
  @Prop
  @Watch('onTargetUrlChanged')
  targetUrl: string = '';
  /**
   * 重复抓同一个地址时父组件递增它即可强制重载
   * （@Prop 值不变不会触发 @Watch）。
   */
  @Prop
  @Watch('onReloadTokenChanged')
  reloadToken: number = 0;
  /** 注入脚本开关（测试时可关掉，排除脚本影响）。 */
  @Prop
  injectScripts: boolean = true;
  /** 解析结束回调（含超时的 null）。 */
  onFinished: (result: VideoSourceResult | null) => void = () => {
  };
  /** JS 侧日志透传（`[web] ...`），便于把注入时机显示在页面上。 */
  onLog: (message: string) => void = () => {
  };

  aboutToAppear(): void {
    this.lifecycle = new VideoSourceCaptureLifecycle(() => {
      this.finishCapture();
    });
    VideoSourceResolver.attachHost(this.lifecycle);
    this.bridge.onLog = (message: string) => {
      this.onLog(message);
    };
    // `src` 只在首帧用一次：直接以目标地址创建 Web。
    //
    // 踩过的坑：如果固定用 `about:blank` 再 `controller.loadUrl(目标)`，
    // 模拟器上实测导航会被组件重绘时重新下发的 `src` 顶掉——
    // 日志表现为 `loadUrl` 打出目标地址，紧接着 `onPageBegin url=about:blank`，
    // Web 永远停在空白页、注入脚本自然也就留在空白页上。
    this.componentSrc = this.targetUrl.length > 0 ? this.targetUrl : 'about:blank';
  }

  aboutToDisappear(): void {
    VideoSourceResolver.detachHost(this.lifecycle);
    this.finishCapture();
    this.controllerAttached = false;
  }

  /** Web 组件的 `src`（只在首帧确定，后续换页一律走 loadUrl）。 */
  @State private componentSrc: string = 'about:blank';
  private lifecycle: VideoSourceCaptureLifecycle =
    new VideoSourceCaptureLifecycle(() => {
    });

  private onTargetUrlChanged(): void {
    // 控制器必须先与 `Web` 组件关联才能 loadUrl
    // （未关联时抛 `Init error. The WebviewController must be associated
    //   with a Web component`，真机/模拟器都会直接崩）。
    if (!this.controllerAttached) {
      this.pendingLoad = true;
      return;
    }
    this.loadUrl(this.targetUrl);
  }

  private onReloadTokenChanged(): void {
    if (!this.controllerAttached) {
      this.pendingLoad = true;
      return;
    }
    this.loadUrl(this.targetUrl);
  }

  /**
   * `Web` 与控制器关联完成。
   *
   * 宿主组件常与承载它的页面在同一个 build 里创建，此时 `@Prop` 是**初值**、
   * `@Watch` 不会触发；如果把加载写在 `aboutToAppear` 里又会因为控制器尚未
   * 关联而崩溃。因此「首次加载」与「后续重载」都收敛到这一个时机。
   */
  private onControllerAttached(): void {
    this.controllerAttached = true;
    // 必须早于任何页面加载；这里也覆盖首次以 componentSrc 加载的路径。
    this.muteCapturePage();
    if (this.targetUrl.length > 0 || this.pendingLoad) {
      this.pendingLoad = false;
      this.loadUrl(this.targetUrl);
    }
  }

  /** 控制器是否已与 `Web` 关联（决定能否 loadUrl）。 */
  private controllerAttached: boolean = false;
  /** 关联前收到的加载请求。 */
  private pendingLoad: boolean = false;

  /** 交给外部的加载入口：由页面在需要时调用。 */
  loadUrl(url: string): void {
    if (url.length === 0) {
      return;
    }
    this.muteCapturePage();
    hilog.info(DOMAIN, TAG, '[web] loadUrl @ %{public}d %{public}s', Date.now(), url);
    try {
      this.controller.loadUrl(url);
    } catch (e) {
      const error = e as Error;
      hilog.warn(DOMAIN, TAG, '[web] loadUrl 失败: %{public}s', error.message);
    }
  }

  /** 取流页只负责解析，绝不允许声音进入系统媒体通道。 */
  private muteCapturePage(): void {
    if (!this.controllerAttached) {
      return;
    }
    try {
      this.controller.setAudioMuted(true);
    } catch (e) {
      const error = e as Error;
      hilog.warn(DOMAIN, TAG, '[web] 静音取流页失败: %{public}s', error.message);
    }
  }

  /**
   * 解析成功 / 超时 / 被下一次解析取代 / 页面退出时统一收尾。
   *
   * `opacity(0)` 只影响绘制，不会停掉网页里的媒体。必须显式静音并导航到
   * `about:blank`，才能真正释放音频通道和播放器资源。
   */
  private finishCapture(): void {
    this.muteCapturePage();
    if (!this.controllerAttached) {
      return;
    }
    const url: string = this.currentUrl();
    if (url.length === 0 || url === 'about:blank') {
      return;
    }
    try {
      this.controller.loadUrl('about:blank');
      hilog.info(DOMAIN, TAG, '[web] 解析结束，已卸载取流页: %{public}s', url);
    } catch (e) {
      const error = e as Error;
      hilog.warn(DOMAIN, TAG, '[web] 卸载取流页失败: %{public}s', error.message);
    }
  }

  /** 当前页面 URL（取不到时返回空串，不抛异常）。 */
  private currentUrl(): string {
    try {
      return this.controller.getUrl();
    } catch (e) {
      return '';
    }
  }

  build() {
    Stack() {
      Web({ src: this.componentSrc, controller: this.controller })
        // 取流页同样要开 DOM 存储：站点脚本读 `localStorage` 时若拿到 null 会抛错，
        // 把后续初始化（包括播放器初始化、验证流程初始化）整段带走。
        // 验证码宿主上就是这么被坑的（真机日志：`handlers=(none)`），这里一并补上。
        .domStorageAccess(true)
        // 默认值虽为 true，但显式写出，避免后续 API/配置变化放开自动播放。
        .mediaPlayGestureAccess(true)
        .javaScriptProxy({
          object: this.bridge,
          name: 'AutumnBridge',
          methodList: ['hit', 'log'],
          controller: this.controller
        })
        .runJavaScriptOnDocumentStart(
          this.injectScripts ? VideoSourceResolver.documentStartScripts() : [])
        .runJavaScriptOnDocumentEnd(
          this.injectScripts ? VideoSourceResolver.documentEndScripts() : [])
        .onPageEnd(() => {
          // 带上实际 URL：排查「注入脚本跑到 about:blank 上」这类问题时，
          // 这一行是唯一能证明「Web 到底停在哪一页」的证据。
          hilog.info(DOMAIN, TAG, '[web] onPageEnd @ %{public}d url=%{public}s',
            Date.now(), this.currentUrl());
          this.controllerAttached = true;
          this.muteCapturePage();
          const url: string = this.currentUrl();
          if (url.length === 0 || url === 'about:blank') {
            return;
          }
          // 页面自身脚本已经跑完，兜底通道此时已注入；
          // 若页面是 SPA，这里再补一次结束注入脚本（幂等）。
          if (this.injectScripts) {
            this.controller.runJavaScript(VideoSourceScripts.videoTagParserScript());
          }
        })
        .onControllerAttached(() => {
          this.onControllerAttached();
        })
        .onPageBegin(() => {
          // 与阶段 0 的「注入距 onPageBegin 19ms」同一基准点
          this.muteCapturePage();
          hilog.info(DOMAIN, TAG, '[web] onPageBegin @ %{public}d url=%{public}s',
            Date.now(), this.currentUrl());
        })
        .onAudioStateChanged((event: OnAudioStateChangedEvent) => {
          if (event.playing) {
            this.muteCapturePage();
            hilog.warn(DOMAIN, TAG, '[web] 取流页尝试播放音频，已强制静音');
          }
        })
        .onErrorReceive(() => {
          // 注意：子资源失败（图片 / 广告 / iframe 里的请求）也会回调到这里，
          // 所以**不能**把它当成「解析结束」——否则页面明明正常也会报未命中。
          // 真正的加载失败由 VideoSourceResolver 的超时收敛（默认 20s）。
          hilog.warn(DOMAIN, TAG, '[web] onErrorReceive @ %{public}d（忽略，等超时收敛）',
            Date.now());
        })
        .width(1)
        .height(1)
        .opacity(0)
        .hitTestBehavior(HitTestMode.None)
    }
    .width(1)
    .height(1)
  }
}
