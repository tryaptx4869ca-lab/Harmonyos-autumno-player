import { hilog } from '@kit.PerformanceAnalysisKit';
import { attachSurface, command, create, destroy, getProperty, hasSurface,
  setProperty, setSurfaceSize } from 'libmpv_bridge.so';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnPlayer';

/** 画面比例（§15.2，storageValue 与源码一致）。 */
export enum AspectRatioMode {
  automatic = 1,
  crop = 2,
  stretch = 3,
  ratio4x3 = 4
}

/** 一次播放的参数（等价于源码 `PlaybackInitParams` 的原生子集）。 */
export class PlaybackParams {
  url: string = '';
  /** DASH 纯画面流的独立音轨；空串表示媒体 URL 已包含音频。 */
  audioUrl: string = '';
  /** 起播位置（秒），对应 `playResume` 的续播偏移。 */
  offset: number = 0;
  /** 透传给 mpv 的请求头（user-agent / referer 等）。 */
  headers: Record<string, string> = {};
}

/**
 * mpv 播放内核。
 *
 * 直接封装 `libmpv_bridge.so`（阶段 0 已在真机上验证过链路）：
 *   create → attachSurface(vo=null → 属性 → vo=gpu-next) → loadfile
 *
 * 与 Flutter 版的差异与理由：
 *   1. **状态靠轮询**。桥目前只暴露 `getProperty`，没有 `observe_property` 回调，
 *      因此位置 / 时长 / 暂停态用 500ms 定时器拉取（进度条与时间文本够用）。
 *   2. **画面比例用 mpv 属性**。Flutter 侧是 widget 层的 BoxFit，原生侧没有
 *      等价的缩放层，改用 `panscan`（裁切填充）与 `video-aspect-override`
 *      （拉伸 / 4:3）表达同一组语义。
 */
export class PlayerEngine {
  private handle: number = 0;
  private surfaceId: string = '';
  private attached: boolean = false;
  private disposed: boolean = false;
  private playRevision: number = 0;
  /** 模拟器上没有 libmpv（桩实现 create() 返回 0）。 */
  private readonly unavailable: boolean;

  constructor() {
    this.handle = create();
    this.unavailable = this.handle <= 0;
    hilog.info(DOMAIN, TAG, 'mpv create → handle=%{public}d（%{public}s）',
      this.handle, this.unavailable ? '桩实现/失败' : '可播放');
  }

  get isAvailable(): boolean {
    return !this.unavailable;
  }

  get surfaceAttached(): boolean {
    return this.attached;
  }

  /** XComponent 的 surface 就绪后调用。 */
  attach(surfaceId: string, hardwareDecode: boolean): void {
    if (this.unavailable) {
      return;
    }
    this.surfaceId = surfaceId;
    attachSurface(this.handle, surfaceId, 'gpu-next', hardwareDecode ? 'auto' : 'no');
    this.attached = true;
    hilog.info(DOMAIN, TAG, 'surface 已绑定，hasSurface=%{public}s',
      `${hasSurface()}`);
  }

  /** surface 尺寸变化（横竖屏切换时用）。 */
  resize(width: number, height: number): void {
    if (this.unavailable || width <= 0 || height <= 0) {
      return;
    }
    setSurfaceSize(this.handle, Math.round(width), Math.round(height));
  }

  /**
   * 起播。
   * 属性必须在 `loadfile` **之前**设置，否则 mpv 已经按默认值起流了。
   */
  play(params: PlaybackParams): void {
    if (this.unavailable || this.disposed) {
      return;
    }
    const revision: number = ++this.playRevision;
    // 请求头：mpv 的 http-header-fields 是「Key: Value」逗号分隔
    const headerKeys: string[] = Object.keys(params.headers);
    const fields: string[] = [];
    for (let i = 0; i < headerKeys.length; i++) {
      const key: string = headerKeys[i];
      const value: string = params.headers[key];
      if (value.length === 0) {
        continue;
      }
      if (key === 'user-agent') {
        setProperty(this.handle, 'user-agent', value);
      } else if (key === 'referer') {
        setProperty(this.handle, 'referrer', value);
      } else {
        fields.push(`${key}: ${value}`);
      }
    }
    setProperty(this.handle, 'http-header-fields', fields.join(','));
    // 起播前固定住基础行为（与 media_kit 的 OHOS 控制器一致）
    setProperty(this.handle, 'keep-open', 'yes');
    setProperty(this.handle, 'force-window', 'yes');
    setProperty(this.handle, 'sub-use-margins', 'no');
    setProperty(this.handle, 'sub-scale-with-window', 'no');
    setProperty(this.handle, 'osd-font', 'HarmonyOS Sans SC');
    setProperty(this.handle, 'af', 'scaletempo2=max-speed=8');
    setProperty(this.handle, 'volume-max', '100');
    /**
     * DASH 的 audio 是独立 m4s 音轨。用 `audio-add` 在主文件仍 loading 时
     * 追加，命令虽返回 0，但实际可能在 loadfile 完成后丢失，表现为无声。
     * `audio-file` 是 mpv 的文件级外部音轨选项，必须在 loadfile 前设置，
     * 这样音频会随主文件一起建立时间轴并自动选中。
     */
    if (params.audioUrl.length > 0) {
      setProperty(this.handle, 'audio-file', params.audioUrl);
      /**
       * `audio-file` 应随主文件一起加载。网络较慢时如果它仍未挂上，
       * 在主文件加载完成后再补一次 `audio-add`；延迟检查避免与 loadfile
       * 竞争，也避免在已有音轨时重复添加。
       */
      setTimeout(() => {
        if (this.disposed || revision !== this.playRevision) {
          return;
        }
        const aid: string = getProperty(this.handle, 'aid').trim();
        if (aid.length === 0 || aid === 'no' || aid === 'false' || aid === '0') {
          const rc: number =
            command(this.handle, ['audio-add', params.audioUrl, 'select']);
          hilog.warn(DOMAIN, TAG,
            'audio-file 未挂上，补 audio-add → rc=%{public}d', rc);
        }
      }, 1200);
    } else {
      setProperty(this.handle, 'audio-file', '');
    }

    if (params.offset > 0) {
      // ⚠️ mpv 的命令签名是 `loadfile <url> [<flags> [<index> [<options>]]]`：
      // 要带 options 就**必须先把 <index> 占位填上**。之前写成
      // `['loadfile', url, 'replace', 'start=+135.176708']`，mpv 会把第 4 个参数
      // 当成 index 去解析整数，直接报
      // 「The loadfile option must be an integer: start=+135.176708」，
      // 整条 loadfile 返回 -4 → 续播时**根本不出画面**（一直 00:00 / 00:00）。
      // 真机日志（2026-09-16）即为此证。
      command(this.handle, ['loadfile', params.url, 'replace', '-1',
        `start=${params.offset.toFixed(3)}`]);
    } else {
      command(this.handle, ['loadfile', params.url, 'replace']);
    }
    // offset 是浮点秒，用 %d 打会踩格式化（hilog 对 %d + double 是未定义行为）
    hilog.info(DOMAIN, TAG,
      'loadfile %{public}s（offset=%{public}s，audio-file=%{public}s）',
      params.url, params.offset.toFixed(3),
      params.audioUrl.length > 0 ? 'yes' : 'no');
  }

  /** 切换画面比例（§15.2）。 */
  applyAspectRatio(mode: AspectRatioMode, surfaceWidth: number,
    surfaceHeight: number): void {
    if (this.unavailable) {
      return;
    }
    if (mode === AspectRatioMode.crop) {
      setProperty(this.handle, 'panscan', '1.0');
      setProperty(this.handle, 'video-aspect-override', 'no');
      return;
    }
    setProperty(this.handle, 'panscan', '0');
    if (mode === AspectRatioMode.stretch && surfaceWidth > 0 && surfaceHeight > 0) {
      setProperty(this.handle, 'video-aspect-override',
        `${surfaceWidth.toFixed(3)}:${surfaceHeight.toFixed(3)}`);
      return;
    }
    if (mode === AspectRatioMode.ratio4x3) {
      setProperty(this.handle, 'video-aspect-override', '4:3');
      return;
    }
    setProperty(this.handle, 'video-aspect-override', 'no');
  }

  resume(): void {
    if (this.unavailable) {
      return;
    }
    setProperty(this.handle, 'pause', 'no');
  }

  pause(): void {
    if (this.unavailable) {
      return;
    }
    setProperty(this.handle, 'pause', 'yes');
  }

  /**
   * 停播并**卸载当前文件**（换集、解析新地址之前调用）。
   *
   * ## 为什么不能只 `pause()`
   *
   * mpv 的 `pause` 是**全局属性**，`loadfile` 不会替你清掉它：换集时若只 pause，
   * 新的一集会带着暂停起播，表现就是「切集后不出画面、得手动点播放」。
   * 所以这里「先解除暂停、再 stop」：
   *   - `stop` 会卸载当前文件 → 音频与画面立刻停住（正是用户 2026-09-19 要的：
   *     切集快的时候，上一集的声音不会在新一集解析期间透出来）；
   *   - 停在 idle 状态，下一次 `loadfile` 从零开始正常起播。
   *
   * 参照实现每次换集都**重建播放器**（`player_controller.init` 里先
   * `_releasePlaybackResources()` → `playback.stop()` 再建新的），
   * 本工程复用同一个 mpv 实例，等价动作就是这一句 stop。
   */
  stop(): void {
    if (this.unavailable) {
      return;
    }
    setProperty(this.handle, 'pause', 'no');
    command(this.handle, ['stop']);
    hilog.info(DOMAIN, TAG, 'stop：卸载当前文件（换集/解析新地址前）');
  }

  seekTo(seconds: number): void {
    if (this.unavailable) {
      return;
    }
    command(this.handle, ['seek', `${seconds}`, 'absolute']);
  }

  /**
   * 暂停时 surface 尺寸变化后强制重绘当前帧。
   *
   * mpv 在 paused 状态收到 `ohos-surface-size` 后不一定主动提交新帧，
   * 全屏/退出全屏时就会继续把旧尺寸的画面交给合成器。对当前位置做一次
   * `absolute+exact` seek 会重新解码并提交当前帧，同时保持 paused 状态。
   */
  refreshPausedFrame(seconds: number): void {
    if (this.unavailable || seconds < 0) {
      return;
    }
    const rc: number = command(this.handle,
      ['seek', seconds.toFixed(3), 'absolute+exact']);
    hilog.info(DOMAIN, TAG, '暂停帧重绘 seek %{public}s → rc=%{public}d',
      seconds.toFixed(3), rc);
  }

  /** 相对快进 / 快退（跳 OP 用）。 */
  seekBy(seconds: number): void {
    if (this.unavailable) {
      return;
    }
    command(this.handle, ['seek', `${seconds}`, 'relative']);
  }

  setSpeed(speed: number): void {
    if (this.unavailable) {
      return;
    }
    setProperty(this.handle, 'speed', `${speed}`);
  }

  /** 音量 0–100（mpv 的 `volume`）。 */
  setVolume(volume: number): void {
    if (this.unavailable) {
      return;
    }
    setProperty(this.handle, 'volume', `${volume}`);
  }

  /** 播放器自身亮度（-100–100）。 */
  setBrightness(brightness: number): void {
    if (this.unavailable) {
      return;
    }
    setProperty(this.handle, 'brightness', `${brightness}`);
  }

  /** 超分辨率：Anime4K 档位由 `glsl-shaders` 决定（§15.3）。 */
  setShaders(shaderPaths: string[]): void {
    if (this.unavailable) {
      return;
    }
    setProperty(this.handle, 'glsl-shaders', shaderPaths.join(':'));
  }

  /**
   * 截图到文件（§31）。
   *
   * 用 mpv 自己的 `screenshot-to-file`：拿的是**解码后的画面**，
   * 与 ArkUI 层再截屏相比不受控制层 / 字幕遮挡影响，
   * 也与参照实现 `player_screenshot_service` 的输出语义一致。
   */
  screenshotToFile(path: string): number {
    if (this.unavailable) {
      return -1;
    }
    const rc: number = command(this.handle, ['screenshot-to-file', path, 'video']);
    hilog.info(DOMAIN, TAG, '截图命令 → %{public}s，mpv rc=%{public}d', path, rc);
    return rc;
  }

  /** 当前播放位置（秒）；取不到返回 -1（还在起流）。 */
  position(): number {
    return this.numberProperty('time-pos');
  }

  /** 总时长（秒）；未知返回 0。 */
  duration(): number {
    const value: number = this.numberProperty('duration');
    return value > 0 ? value : 0;
  }

  paused(): boolean {
    if (this.unavailable) {
      return true;
    }
    return getProperty(this.handle, 'pause') === 'yes';
  }

  /** 是否播完（`eof-reached`）。 */
  ended(): boolean {
    if (this.unavailable) {
      return false;
    }
    return getProperty(this.handle, 'eof-reached') === 'yes';
  }

  /** 是否已出画面（`video-params/w` 有值即解码链路已通）。 */
  hasVideo(): boolean {
    if (this.unavailable) {
      return false;
    }
    return this.numberProperty('video-params/w') > 0;
  }

  /** 读任意 mpv 属性的字符串值（视频详情弹层用，§40.2）。 */
  property(name: string): string {
    if (this.unavailable) {
      return '';
    }
    return getProperty(this.handle, name);
  }

  /** 「宽 × 高」，取不到返回空串。 */
  videoSize(): string {
    const width: number = this.numberProperty('video-params/w');
    const height: number = this.numberProperty('video-params/h');
    if (width <= 0 || height <= 0) {
      return '';
    }
    return `${Math.round(width)} × ${Math.round(height)}`;
  }

  /**
   * 画面**自身**的宽高比（0 = 还没起播 / 读不到）。
   *
   * 用途见 `VideoPage.videoBox`：让 XComponent 的盒子保持画面比例
   * （等价源码 `player_item_surface.dart` 里 `Video(fit: ...)` 的 `BoxFit.contain`），
   * 这样容器长宽比怎么变都只影响留黑，不会把画面拉扁。
   *
   * 优先用 `video-params/aspect`：它已经把像素长宽比（anamorphic）算进去了，
   * 比直接拿 w/h 相除准；读不到再退回 w/h。
   */
  videoAspectRatio(): number {
    const aspect: number = this.numberProperty('video-params/aspect');
    if (aspect > 0) {
      return aspect;
    }
    const width: number = this.numberProperty('video-params/w');
    const height: number = this.numberProperty('video-params/h');
    if (width > 0 && height > 0) {
      return width / height;
    }
    return 0;
  }

  private numberProperty(name: string): number {
    if (this.unavailable) {
      return -1;
    }
    const raw: string = getProperty(this.handle, name);
    if (raw.length === 0) {
      return -1;
    }
    const value: number = Number.parseFloat(raw);
    return Number.isNaN(value) ? -1 : value;
  }

  dispose(): void {
    if (this.unavailable) {
      return;
    }
    this.disposed = true;
    this.playRevision += 1;
    if (this.handle > 0) {
      destroy(this.handle);
      this.handle = 0;
    }
    this.attached = false;
    hilog.info(DOMAIN, TAG, 'mpv 已销毁');
  }
}
