import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { create, destroy, setProperty, command, attachSurface, hasSurface }
  from 'libmpv_bridge.so';
import { Hct } from '../theme/color/Hct';
import { ColorUtils } from '../theme/color/ColorUtils';
import { VideoSourceResolver, VideoSourceResult } from '../webview/VideoSourceResolver';
import { VideoSourceWebHost } from '../webview/VideoSourceWebHost';
import { Plugin } from '../plugins/Plugin';
import { PluginChainProbe } from '../services/plugin/PluginChainProbe';
import { Stage2SelfCheck } from '../services/plugin/Stage2SelfCheck';
import { HistorySelfCheck } from '../services/HistorySelfCheck';
import { PluginImportSelfCheck } from '../services/PluginImportSelfCheck';
import { DanmakuSelfCheck } from '../services/DanmakuSelfCheck';
import { DownloadSelfCheck } from '../services/DownloadSelfCheck';
import { CaptchaHostBridge } from '../webview/CaptchaWebHost';
import { PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';

/**
 * 阶段 2 验收用的真实播放页。
 *
 * 由 `tools/fetch-probe-url.mjs`（PC 侧跑「搜索 → 线路 → 剧集」，
 * 用的是工程里同一套 DOM / XPath 引擎代码）产出：
 *   搜索「葬送的芙莉莲」→ 第 1 条 /voddetail/26976.html
 *   → 线路 2 第 1 集 → https://www.7sefun.top/vodplay/26976-2-1.html
 *
 * App 内的同一条链路见 `services/plugin/PluginChainProbe.ets`（页面上的「抓取」按钮）。
 */
const PROBE_VODPLAY_URL: string = 'https://www.7sefun.top/vodplay/26976-2-1.html';

function hex8(argb: number): string {
  let s: string = (argb >>> 0).toString(16).toUpperCase();
  while (s.length < 8) {
    s = '0' + s;
  }
  return '#' + s;
}

/** Anime4K 完整档（质量优先）——顺序与参照实现一致。 */
const ANIME4K_QUALITY: string[] = [
  'Anime4K_Clamp_Highlights.glsl',
  'Anime4K_Restore_CNN_VL.glsl',
  'Anime4K_Upscale_CNN_x2_VL.glsl',
  'Anime4K_AutoDownscalePre_x2.glsl',
  'Anime4K_AutoDownscalePre_x4.glsl',
  'Anime4K_Upscale_CNN_x2_M.glsl'
];

/** Anime4K 精简档（效率优先）。 */
const ANIME4K_EFFICIENCY: string[] = [
  'Anime4K_Clamp_Highlights.glsl',
  'Anime4K_Restore_CNN_M.glsl',
  'Anime4K_Restore_CNN_S.glsl',
  'Anime4K_Upscale_CNN_x2_M.glsl',
  'Anime4K_AutoDownscalePre_x2.glsl',
  'Anime4K_AutoDownscalePre_x4.glsl',
  'Anime4K_Upscale_CNN_x2_S.glsl'
];

/**
 * 阶段 0 原型页
 *
 * 上半：mpv native 桥（XComponent surface + libmpv）
 * 下半：ArkWeb 文档开始注入（验证能否在页面脚本之前挂钩）
 *
 * 这一页只用于验证技术前提，验证通过后会被正式页面取代。
 */

/** javaScriptProxy 暴露给网页的对象。 */
class JsBridge {
  onLog: (msg: string) => void = () => {};
  onHit: (url: string, via: string) => void = () => {};

  // javaScriptProxy 要求方法可被反射调用，故用普通方法转发
  log(msg: string): void {
    this.onLog(msg);
  }

  hit(url: string, via: string): void {
    this.onHit(url, via);
  }
}

@Component
export struct ProtoPage {
  /** 二级页转场（规格 §12.4）。 */
  pageTransition() {
    PageTransitionEnter({
      type: RouteType.Push,
      duration: RouteTable.duration(),
      curve: PageTransitionSpec.enterCurve()
    })
      .opacity(0)
      .translate({ y: RouteTable.slideOffset() })
    PageTransitionExit({
      type: RouteType.Pop,
      duration: RouteTable.duration(),
      curve: PageTransitionSpec.exitCurve()
    })
      .opacity(0)
      // 退出：与参照实现同一条 Fade + Slide（`Offset(0, 0.02)`）——下滑 2% 的同时淡出
      .translate({ y: RouteTable.slideOffset() })
  }
  // ---- mpv ----
  private xController: XComponentController = new XComponentController();
  @State mpvHandle: number = 0;
  @State mpvState: string = '未创建';
  // 公开 HLS 测试流，用于验证 mpv 出画面
  @State mediaUrl: string = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

  // ---- ArkWeb ----
  private webController: webview.WebviewController = new webview.WebviewController();
  private bridge: JsBridge = new JsBridge();
  // hls.js 官方 demo：会在页面内用 XHR 拉取 m3u8，用于验证注入钩子是否生效
  @State targetUrl: string = 'https://hlsjs.video-dev.org/demo/';
  @State hits: string[] = [];
  @State logs: string[] = [];

  // ---- 阶段 2：视频源抓取（规则链路 → 无头宿主 → 三通道命中） ----
  /** 验收探针规则（7sefun 适配当前站点结构，见 PluginChainProbe）。 */
  private probePlugin: Plugin = PluginChainProbe.sevenFun();
  @State probeKeyword: string = PluginChainProbe.defaultKeyword;
  /** 交给宿主的播放页地址；变化即加载。 */
  @State captureUrl: string = PROBE_VODPLAY_URL;
  /** 同一个地址重抓用的令牌。 */
  @State reloadToken: number = 0;
  @State captureState: string = '未开始';
  @State capturedUrl: string = '';
  @State capturedChannel: string = '';
  @State capturedElapsed: number = 0;
  /** 阶段 2 自检的界面提示（明细在 hilog 的 AutumnSelf 标签里）。 */
  @State selfCheckState: string = '未运行';
  /** 反爬验证宿主的自检状态（宿主实现见 webview/CaptchaWebHost.ets）。 */
  @State captchaState: string = '未运行';
  private captchaBridge: CaptchaHostBridge = new CaptchaHostBridge();

  aboutToAppear(): void {
    this.runColorSelfTest();
    this.pushLog('阶段 2 探针就绪：规则链路 + 无头宿主已接线');
    this.bridge.onLog = (msg: string) => {
      this.pushLog(msg);
    };
    this.bridge.onHit = (url: string, via: string) => {
      this.hits = [`[${via}] ${url}`, ...this.hits];
      this.pushLog(`命中 #EXTM3U: ${url}`);
    };
  }

  aboutToDisappear(): void {
    if (this.mpvHandle > 0) {
      destroy(this.mpvHandle);
      this.mpvHandle = 0;
    }
  }

  private pushLog(msg: string): void {
    hilog.info(0x0000, 'AutumnProto', '%{public}s', msg);
    this.logs = [`${new Date().toTimeString().slice(0, 8)}  ${msg}`, ...this.logs].slice(0, 120);
  }

  /**
   * 步骤 2：用 7sefun 适配规则跑「搜索 → 线路 → 剧集」，
   * 拿到一条真实播放页地址后交给宿主抓取。
   */
  private async runChainProbe(): Promise<void> {
    if (this.captureState === '链路执行中…') {
      return;
    }
    this.captureState = '链路执行中…';
    try {
      const vodplayUrl: string = await PluginChainProbe.firstEpisodeUrl(
        this.probePlugin, this.probeKeyword,
        (message: string) => {
          this.pushLog(message);
        });
      this.pushLog(`[chain] 播放页地址：${vodplayUrl}`);
      this.captureUrl = vodplayUrl;
      await this.startCapture(vodplayUrl);
    } catch (error) {
      const err = error as Error;
      this.captureState = `链路失败：${err.message}`;
      this.pushLog(`[chain] 失败：${err.message}`);
    }
  }

  /** 步骤 3：武装解析器 → 加载播放页 → 等三通道命中。 */
  /**
   * 反爬宿主自检：加载一个真实站点，取回 HTML / UA / Cookie / 验证码图长度。
   *
   * 目的是把 `CaptchaWebviewHost` 的 ArkWeb 实现（webview/CaptchaWebHost.ets）
   * 真正跑起来——服务层已经用宿主桩验过编排，这里验的是宿主本身。
   */
  private async runCaptchaProbe(): Promise<void> {
    const url: string = 'https://www.7sefun.top/vodsearch/-------------.html?wd=%E8%91%AC%E9%80%81';
    this.captchaState = '加载中…';
    try {
      await this.captchaBridge.loadUrl(url);
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 3500);
      });
      const html: string = await this.captchaBridge.pageHtml();
      const ua: string = await this.captchaBridge.userAgent();
      const cookie: string = await this.captchaBridge.documentCookie();
      const image: string = await this.captchaBridge.captureImage("//img");
      this.captchaState = `HTML ${html.length} 字节 · UA ${ua.length} 字符 · `
        + `Cookie ${cookie.length} 字符 · 验证码图 ${image.length} 字节`;
      this.pushLog(`[captcha] ${this.captchaState}`);
      this.pushLog(`[captcha] UA=${ua}`);
      this.pushLog(`[captcha] Cookie=${cookie}`);
      await this.captchaBridge.unload();
    } catch (e) {
      const err = e as Error;
      this.captchaState = `失败：${err.message}`;
      this.pushLog(`[captcha] 失败：${err.message}`);
    }
  }

  private async startCapture(url: string): Promise<void> {
    if (url.length === 0) {
      this.pushLog('[capture] 播放页地址为空');
      return;
    }
    this.capturedUrl = '';
    this.capturedChannel = '';
    this.capturedElapsed = 0;
    this.captureState = '加载中，等待命中…';
    const startedAt: number = Date.now();
    // 先武装（置 pending + 起 25s 超时），再让宿主加载页面，
    // 保证文档开始注入的钩子注册时已经有接收方。
    const pending: Promise<VideoSourceResult | null> =
      VideoSourceResolver.resolve(url, 25000);
    this.captureUrl = url;
    this.reloadToken = this.reloadToken + 1;
    const result: VideoSourceResult | null = await pending;
    const elapsed: number = Date.now() - startedAt;
    if (result === null) {
      this.captureState = `未命中（${elapsed}ms）`;
      this.pushLog(`[capture] 未命中，耗时 ${elapsed}ms`);
      return;
    }
    this.capturedUrl = result.url;
    this.capturedChannel = result.channel;
    this.capturedElapsed = result.elapsedMs;
    this.captureState = `命中 ${result.channel}，耗时 ${result.elapsedMs}ms`;
    this.pushLog(`[capture] 命中 ${result.channel}：${result.url}`);
    this.pushLog(`[capture] 从 loadUrl 到命中：${result.elapsedMs}ms`);
  }

  /**
   * 色彩引擎自检。
   *
   * 用 Material 3 的已知基准验证移植正确性：
   *   种子 #6750A4 的 light 主题，primary 应当就是 #6750A4
   *   （即 HCT(hue, chroma, tone=40) 反解回 #6750A4）
   */
  private runColorSelfTest(): void {
    const seed: number = 0xFF6750A4;
    const hct: Hct = Hct.fromInt(seed);
    this.pushLog(
      `自检 seed ${hex8(seed)} → H${hct.hue.toFixed(2)} C${hct.chroma.toFixed(2)} T${hct.tone.toFixed(2)}`
    );
    const tone40: Hct = Hct.from(hct.hue, hct.chroma, 40);
    this.pushLog(`自检 tone40 ${hex8(tone40.toInt())}  (期望 #6750A4)`);
    const tone90: Hct = Hct.from(hct.hue, hct.chroma, 90);
    this.pushLog(`自检 tone90 ${hex8(tone90.toInt())}  (期望 #EADDFF)`);
    const tone10: Hct = Hct.from(hct.hue, hct.chroma, 10);
    this.pushLog(`自检 tone10 ${hex8(tone10.toInt())}  (期望 #21005D)`);
    const lstar: number = ColorUtils.lstarFromArgb(seed);
    this.pushLog(`自检 lstarFromArgb(#6750A4) = ${lstar.toFixed(2)} (期望约 32.9)`);

    // 关键验证 1：往返一致性。ARGB → HCT → ARGB 应当闭合。
    const samples: number[] = [
      0xFF6750A4, 0xFFC98A3C, 0xFFFF0000, 0xFF00FF00,
      0xFF0000FF, 0xFF808080, 0xFFFFFFFF, 0xFF000000
    ];
    for (let i = 0; i < samples.length; i++) {
      const s: number = samples[i];
      const h: Hct = Hct.fromInt(s);
      const back: number = Hct.from(h.hue, h.chroma, h.tone).toInt();
      const same: boolean = back === s;
      this.pushLog(
        `往返 ${hex8(s)} → H${h.hue.toFixed(2)} C${h.chroma.toFixed(2)} T${h.tone.toFixed(2)} → ${hex8(back)} ${same ? 'OK' : '差异'}`
      );
    }

    // 关键验证 2：用 chroma=36 复算 M3 规范基准色板
    const c36t90: number = Hct.from(hct.hue, 36, 90).toInt();
    const c36t40: number = Hct.from(hct.hue, 36, 40).toInt();
    const c36t10: number = Hct.from(hct.hue, 36, 10).toInt();
    this.pushLog(`自检 chroma36: t40=${hex8(c36t40)} t90=${hex8(c36t90)} t10=${hex8(c36t10)}`);
    this.pushLog(`  期望基准: t40=#6750A4 t90=#EADDFF t10=#21005D`);
  }

  /**
   * 把 rawfile 里的 glsl 复制到应用沙箱目录。
   * mpv 的 glsl-shaders 需要文件绝对路径，无法直接读 rawfile。
   * 与参照实现的 shader_asset_service 行为一致：已存在则跳过。
   */
  private deployShaders(): string {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const dir: string = `${ctx.filesDir}/anime_shaders`;
    try {
      fs.mkdirSync(dir);
    } catch (e) {
      // 目录已存在
    }
    const all: string[] = ANIME4K_QUALITY.concat(ANIME4K_EFFICIENCY);
    let copied: number = 0;
    for (const name of all) {
      const target: string = `${dir}/${name}`;
      if (fs.accessSync(target)) {
        continue;
      }
      const data: Uint8Array = ctx.resourceManager.getRawFileContentSync(`shaders/${name}`);
      const file = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      fs.writeSync(file.fd, data.buffer as ArrayBuffer);
      fs.closeSync(file);
      copied++;
    }
    this.pushLog(`shader 部署完成：新拷贝 ${copied} 个，目录 ${dir}`);
    return dir;
  }

  /** 应用 Anime4K：mode 为 quality / efficiency / off。 */
  private applyAnime4K(mode: string): void {
    if (this.mpvHandle <= 0) {
      this.pushLog('句柄为空，无法应用 Anime4K');
      return;
    }
    if (mode === 'off') {
      command(this.mpvHandle, ['change-list', 'glsl-shaders', 'clr', '']);
      this.pushLog('Anime4K 已关闭');
      return;
    }
    const dir: string = this.deployShaders();
    const names: string[] = mode === 'quality' ? ANIME4K_QUALITY : ANIME4K_EFFICIENCY;
    let paths: string = '';
    for (let i = 0; i < names.length; i++) {
      if (i > 0) {
        paths += ':';
      }
      paths += `${dir}/${names[i]}`;
    }
    setProperty(this.mpvHandle, 'glsl-shaders', paths);
    this.pushLog(`Anime4K ${mode} 已应用（${names.length} 个）`);
  }

  /** 与参照实现一致的注入脚本：包装 Response.text 与 XHR.open 捕获 #EXTM3U。 */
  private buildHookScript(): string {
    return `
(function () {
  try {
    var origText = window.Response && window.Response.prototype.text;
    if (origText) {
      window.Response.prototype.text = function () {
        var self = this;
        return new Promise(function (resolve, reject) {
          origText.call(self).then(function (text) {
            resolve(text);
            try {
              if (text && text.trim().indexOf('#EXTM3U') === 0) {
                window.AutumnBridge.hit(String(self.url), 'Response.text');
              }
            } catch (e) {}
          }).catch(reject);
        });
      };
    }
    var origOpen = window.XMLHttpRequest && window.XMLHttpRequest.prototype.open;
    if (origOpen) {
      window.XMLHttpRequest.prototype.open = function () {
        var args = arguments;
        this.addEventListener('load', function () {
          try {
            var c = null;
            try { c = this.responseText; } catch (e) {}
            if (!c && this.response && this.response instanceof ArrayBuffer) {
              try {
                c = new TextDecoder('utf-8').decode(new Uint8Array(this.response, 0, 64));
              } catch (e) {}
            }
            if (c && c.trim().indexOf('#EXTM3U') === 0) {
              window.AutumnBridge.hit(String(args[1]), 'XHR');
            }
          } catch (e) {}
        });
        return origOpen.apply(this, args);
      };
    }
    var origFetch = window.fetch;
    if (origFetch) {
      window.fetch = function () {
        var args = arguments;
        return origFetch.apply(this, args).then(function (resp) {
          try {
            var url = (args[0] && args[0].url) ? args[0].url : String(args[0]);
            if (url && url.indexOf('.m3u8') >= 0) {
              window.AutumnBridge.hit(url, 'fetch(url)');
            }
          } catch (e) {}
          return resp;
        });
      };
    }
    window.AutumnBridge.log('hooks installed @ ' + location.href);
  } catch (e) {
    try { window.AutumnBridge.log('hook failed: ' + e); } catch (_) {}
  }
})();
`;
  }

  /** 兜底脚本：监听 <video> 元素并轮询（对应参照实现的 onLoadStop + 轮询）。 */
  private buildVideoFallbackScript(): string {
    return `
(function () {
  try {
    var seen = false;
    function processVideo(video) {
      if (!video) { return; }
      var src = video.getAttribute('src');
      if (src && src.indexOf('blob:') !== 0 && src.indexOf('googleads') < 0) {
        seen = true;
        window.AutumnBridge.hit(String(src), 'video.src');
        return;
      }
      var sources = video.getElementsByTagName('source');
      for (var i = 0; i < sources.length; i++) {
        var s = sources[i].getAttribute('src');
        if (s && s.indexOf('blob:') !== 0 && s.indexOf('googleads') < 0) {
          seen = true;
          window.AutumnBridge.hit(String(s), 'video.source');
          return;
        }
      }
    }
    var observer = new MutationObserver(function (mutations) {
      for (var i = 0; i < mutations.length; i++) {
        var m = mutations[i];
        if (m.target && m.target.nodeName === 'VIDEO') { processVideo(m.target); }
        for (var j = 0; j < m.addedNodes.length; j++) {
          var node = m.addedNodes[j];
          if (node.nodeName === 'VIDEO') { processVideo(node); }
          if (node.querySelectorAll) {
            var videos = node.querySelectorAll('video');
            for (var k = 0; k < videos.length; k++) { processVideo(videos[k]); }
          }
        }
      }
    });
    observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
    setInterval(function () {
      if (seen) { return; }
      var videos = document.querySelectorAll('video');
      for (var i = 0; i < videos.length; i++) { processVideo(videos[i]); }
    }, 1000);
    window.AutumnBridge.log('video fallback installed');

    // 自检：在页面上下文里主动取一次 m3u8，验证 XHR 钩子确实能捕获 HLS 清单
    setTimeout(function () {
      try {
        var x = new XMLHttpRequest();
        x.open('GET', 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8');
        x.send();
        window.AutumnBridge.log('self-test: XHR dispatched');
      } catch (e) {
        window.AutumnBridge.log('self-test: XHR failed ' + e);
      }
    }, 1200);
  } catch (e) {
    try { window.AutumnBridge.log('video fallback failed: ' + e); } catch (_) {}
  }
})();
`;
  }

  build() {
    Scroll() {
        Column() {
        // ================= mpv 原型 =================
        Text('mpv 原型').fontSize(16).fontWeight(700).width('100%')
          .padding({ left: 16, top: 12, bottom: 6 })

        Stack() {
          XComponent({
            id: 'mpvSurface',
            type: XComponentType.SURFACE,
            libraryname: 'mpv_bridge',
            controller: this.xController
          })
            .width('100%')
            .height('100%')
            .onLoad(() => {
              this.mpvHandle = create();
              this.mpvState = `句柄 ${this.mpvHandle}`;
              this.pushLog(`mpv 创建，句柄=${this.mpvHandle}`);
              // surface 可能晚于播放器就绪，这里延迟补一次绑定
              setTimeout(() => {
                this.pushLog(`surface 就绪=${hasSurface()}`);
                const surfaceId: string = this.xController.getXComponentSurfaceId();
                this.pushLog(`surfaceId=${surfaceId}`);
                attachSurface(this.mpvHandle, surfaceId, 'gpu-next', 'auto');
                this.pushLog('attachSurface(gpu-next, auto) 已调用');
                // 自动加载测试流，验证是否真的出画面
                if (this.mediaUrl.length > 0) {
                  command(this.mpvHandle, ['loadfile', this.mediaUrl, 'replace']);
                  this.pushLog(`自动加载 ${this.mediaUrl}`);
                }
              }, 800);
            })
            .onDestroy(() => {
              this.pushLog('XComponent surface 销毁');
            })
        }
        .width('100%')
        .height(220)
        .backgroundColor(Color.Black)

        Row({ space: 8 }) {
          Button('加载测试流').onClick(() => {
            if (this.mpvHandle <= 0 || this.mediaUrl.length === 0) {
              this.pushLog('句柄或地址为空');
              return;
            }
            command(this.mpvHandle, ['loadfile', this.mediaUrl, 'replace']);
            this.pushLog(`loadfile ${this.mediaUrl}`);
          }).layoutWeight(1).fontSize(13)
          Button('暂停/继续').onClick(() => {
            if (this.mpvHandle <= 0) { return; }
            command(this.mpvHandle, ['cycle', 'pause']);
            this.pushLog('cycle pause');
          }).layoutWeight(1).fontSize(13)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8 })

        Row({ space: 8 }) {
          Button('质量档').onClick(() => { this.applyAnime4K('quality'); })
            .layoutWeight(1).fontSize(13)
          Button('效率档').onClick(() => { this.applyAnime4K('efficiency'); })
            .layoutWeight(1).fontSize(13)
          Button('关闭').onClick(() => { this.applyAnime4K('off'); })
            .layoutWeight(1).fontSize(13)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8 })

        Row() {
          TextInput({ text: this.mediaUrl, placeholder: '输入 m3u8 地址' })
            .onChange((v: string) => { this.mediaUrl = v; })
            .layoutWeight(1)
            .fontSize(13)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6 })

        Text(`状态：${this.mpvState}   surface=${hasSurface()}`)
          .fontSize(12).width('100%')
          .padding({ left: 12, top: 6 })

        Divider().margin({ top: 10 })

        // ================= ArkWeb 原型 =================
        Text('ArkWeb 注入原型').fontSize(16).fontWeight(700).width('100%')
          .padding({ left: 16, top: 10, bottom: 6 })

        Row({ space: 8 }) {
          TextInput({ text: this.targetUrl, placeholder: '要解析的播放页地址' })
            .onChange((v: string) => { this.targetUrl = v; })
            .layoutWeight(1)
            .fontSize(13)
          Button('加载').onClick(() => {
            this.webController.loadUrl(this.targetUrl);
            this.pushLog(`加载 ${this.targetUrl}`);
          }).fontSize(13)
        }
        .width('100%')
        .padding({ left: 12, right: 12 })

        Web({ src: this.targetUrl, controller: this.webController })
          .javaScriptProxy({
            object: this.bridge,
            name: 'AutumnBridge',
            methodList: ['log', 'hit'],
            controller: this.webController
          })
          .runJavaScriptOnDocumentStart([
            { script: this.buildHookScript(), scriptRules: ['*'] }
          ])
          .runJavaScriptOnDocumentEnd([
            { script: this.buildVideoFallbackScript(), scriptRules: ['*'] }
          ])
          .domStorageAccess(true)
          .mixedMode(MixedMode.Compatible)
          .onPageBegin(() => {
            this.pushLog('onPageBegin');
          })
          .onPageEnd(() => {
            this.pushLog('onPageEnd');
          })
          .width('100%')
          .height(300)
          .margin({ top: 6 })

        // ================= 阶段 2：视频源抓取 =================
        Divider().margin({ top: 10 })

        Text('阶段 2 · 视频源抓取').fontSize(16).fontWeight(700).width('100%')
          .padding({ left: 16, top: 10, bottom: 6 })

      Row({ space: 8 }) {
        TextInput({ text: this.probeKeyword, placeholder: '搜索关键词' })
          .onChange((v: string) => { this.probeKeyword = v; })
          .layoutWeight(1)
          .fontSize(13)
        Button('抓取').onClick(() => { this.runChainProbe(); }).fontSize(13)
      }
      .width('100%')
      .padding({ left: 12, right: 12 })

      Row({ space: 8 }) {
        TextInput({ text: this.captureUrl, placeholder: '播放页（vodplay）地址' })
          .onChange((v: string) => { this.captureUrl = v; })
          .layoutWeight(1)
          .fontSize(13)
        Button('加载并抓取').onClick(() => { this.startCapture(this.captureUrl); }).fontSize(13)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6 })

      Row({ space: 8 }) {
        Button('阶段2 自检（目录/更新/搜索/Cookie/反爬）')
          .onClick(() => {
            this.selfCheckState = '运行中…（明细见 hilog: AutumnSelf）';
            Stage2SelfCheck.run();
          })
          .labelStyle({ maxLines: 1 })
          .layoutWeight(1)
          .fontSize(12)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4 })

      Row({ space: 8 }) {
        Button('下载链路自检（m3u8/去广告/命名）')
          .onClick(() => {
            this.selfCheckState = '下载链路自检运行中…（hilog: AutumnSelf）';
            DownloadSelfCheck.run();
            this.selfCheckState = '下载链路自检完成（hilog: AutumnSelf）';
          })
          .labelStyle({ maxLines: 1 })
          .layoutWeight(1)
          .fontSize(12)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4 })

      Row({ space: 8 }) {
        Button('弹幕自检（解析/去重/屏蔽）')
          .onClick(() => {
            this.selfCheckState = '弹幕自检运行中…（hilog: AutumnSelf）';
            DanmakuSelfCheck.run();
            this.selfCheckState = '弹幕自检完成（hilog: AutumnSelf）';
          })
          .labelStyle({ maxLines: 1 })
          .layoutWeight(1)
          .fontSize(12)
        Button('取弹幕（网络）')
          .onClick(() => {
            this.selfCheckState = '正在取弹幕…（hilog: AutumnSelf）';
            DanmakuSelfCheck.runNetworkProbe().then(() => {
              this.selfCheckState = '取弹幕完成（hilog: AutumnSelf）';
            });
          })
          .labelStyle({ maxLines: 1 })
          .layoutWeight(1)
          .fontSize(12)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4 })

      Row({ space: 8 }) {
        Button('B站弹幕自检（解压/解析）')
          .onClick(() => {
            this.selfCheckState = 'B站弹幕自检运行中…（hilog: AutumnSelf）';
            DanmakuSelfCheck.runBilibiliOffline();
            this.selfCheckState = 'B站弹幕自检完成（hilog: AutumnSelf）';
          })
          .labelStyle({ maxLines: 1 })
          .layoutWeight(1)
          .fontSize(12)
        Button('B站弹幕（网络·柯南1217）')
          .onClick(() => {
            this.selfCheckState = '正在取 B 站弹幕…（hilog: AutumnSelf）';
            DanmakuSelfCheck.runBilibiliProbe().then(() => {
              this.selfCheckState = 'B站弹幕取好了（hilog: AutumnSelf）';
            });
          })
          .labelStyle({ maxLines: 1 })
          .layoutWeight(1)
          .fontSize(12)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4 })

      Row({ space: 8 }) {
        Button('规则导入自检（JSON/去重/api级别/链接）')
          .onClick(() => {
            this.selfCheckState = '规则导入自检运行中…（hilog: AutumnSelf）';
            PluginImportSelfCheck.run();
            this.selfCheckState = '规则导入自检完成（hilog: AutumnSelf）';
          })
          .labelStyle({ maxLines: 1 })
          .layoutWeight(1)
          .fontSize(12)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4 })

      // ---- 阶段 5：播放历史自检 / 演示数据（模拟器无 mpv，靠它取证） ----
      Row({ space: 8 }) {
        Button('历史自检（去重/归零/持久化）')
          .onClick(() => {
            this.selfCheckState = '历史自检运行中…（hilog: AutumnSelf）';
            HistorySelfCheck.run();
            this.selfCheckState = '历史自检完成（明细见 hilog: AutumnSelf）';
          })
          .labelStyle({ maxLines: 1 })
          .layoutWeight(1)
          .fontSize(12)
        Button('写入演示历史')
          .onClick(() => {
            this.selfCheckState = '演示历史写入中…';
            HistorySelfCheck.seedDemo().then(() => {
              this.selfCheckState = '演示历史已写入（我的 → 历史记录）';
            });
          })
          .labelStyle({ maxLines: 1 })
          .layoutWeight(1)
          .fontSize(12)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4 })

      Text(`自检：${this.selfCheckState}`).fontSize(12).width('100%')
        .padding({ left: 12, right: 12, top: 2 })

      // ---- 反爬宿主自检：加载真实站点，取 HTML / UA / Cookie / 验证码图 ----
      Row({ space: 8 }) {
        Button('反爬宿主自检（加载 7sefun）')
          .onClick(() => {
            this.runCaptchaProbe();
          })
          .layoutWeight(1)
          .fontSize(12)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6 })

      Text(`宿主：${this.captchaState}`).fontSize(12).width('100%')
        .padding({ left: 12, right: 12, top: 2 })

      // 宿主必须有挂到组件树上的 Web 才能加载页面（与 VideoSourceWebHost 同理）
      Web({ src: 'about:blank', controller: this.captchaBridge.controller })
        .width('100%')
        .height(160)
        .margin({ top: 6 })

        Text(`状态：${this.captureState}`).fontSize(12).width('100%')
          .padding({ left: 12, right: 12, top: 6 })

        if (this.capturedUrl.length > 0) {
          Text(`命中通道：${this.capturedChannel}   耗时：${this.capturedElapsed}ms`)
            .fontSize(12).fontColor('#0A7').width('100%')
            .padding({ left: 12, right: 12, top: 2 })
          Text(`m3u8：${this.capturedUrl}`).fontSize(11).fontColor('#0A7').width('100%')
            .padding({ left: 12, right: 12, top: 2 })
            .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        // 无头宿主：ArkUI 的 Web 必须先挂到组件树上才能加载页面，
        // 这里 1×1、透明、不参与命中测试（与参照实现同款做法）。
        VideoSourceWebHost({
          targetUrl: this.captureUrl,
          reloadToken: this.reloadToken,
          onFinished: (result: VideoSourceResult | null) => {
            if (result === null) {
              this.pushLog('[capture] 宿主收敛：未命中或加载失败');
            }
          },
          onLog: (message: string) => {
            this.pushLog(message);
          }
        })

        // ================= 日志 =================
        if (this.hits.length > 0) {
          Text(`命中记录（${this.hits.length}）`).fontSize(13).fontWeight(700)
            .width('100%').padding({ left: 12, top: 8 })
          ForEach(this.hits.slice(0, 5), (item: string) => {
            Text(item).fontSize(11).fontColor('#0A7').width('100%')
              .padding({ left: 12, right: 12 })
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }, (item: string, index: number) => `${index}-${item}`)
        }

        Text('日志').fontSize(13).fontWeight(700).width('100%')
          .padding({ left: 12, top: 8 })

        List() {
          ForEach(this.logs, (item: string) => {
            ListItem() {
              Text(item).fontSize(11).width('100%')
            }
          }, (item: string, index: number) => `${index}-${item}`)
        }
        .height(240)
        .width('100%')
        .padding({ left: 12, right: 12 })
        .scrollBar(BarState.Auto)
        }
        .width('100%')
        .padding({ top: 39, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
  }
}
