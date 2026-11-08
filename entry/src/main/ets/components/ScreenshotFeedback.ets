import { AppCurves, Motion } from '../theme/Tokens';
import { MotionRuntime } from '../theme/MotionRuntime';

/**
 * 截图反馈动效（规格 §38.3 / §38.14 的
 * `player_screenshot_feedback_overlay.dart`，**420ms 线性**驱动）。
 *
 * 参照实现是一个自绘叠层，随控制器的线性进度 `value` 计算三件事
 * （源码 `:22-43`）：
 *
 * | 元素 | 公式 |
 * | --- | --- |
 * | 整屏压暗 | `0.12 × pulse(value, 0, 0.18, 0.62)` |
 * | 取景框透明度 | `0.90 × interval(value, 0, 0.14, easeOut) × (1 − interval(value, 0.58, 1.0, easeOutCubic))` |
 * | 取景框收拢进度 | `interval(value, 0, 0.68, easeOutCubic)` |
 *
 * 取景框本身（`_ScreenshotFramePainter`）是四个圆角拐角：
 * 内缩 `宽×0.055+0.025p`、`高×0.075+0.030p`，
 * 拐角长度 `clamp(短边×0.12, 22, 54)`，线宽 `clamp(1.4+0.8(1−p), 1.4, 2.2)`。
 *
 * ArkUI 侧用 Canvas 复刻（与加载指示器同一套「命令式重绘」写法）。
 * 触发方式是父组件把 `token` 自增一次。
 */
@Component
export struct ScreenshotFeedback {
  /** 每次截图把 token +1 即可播放一次。 */
  @Prop @Watch('onTokenChanged') token: number = 0;
  /** 单次动画时长（ms），源码是 420。 */
  durationMs: number = Motion.banner;

  @State private value: number = 0;
  private timerId: number = -1;
  private startMs: number = 0;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private onTokenChanged(): void {
    if (this.token <= 0) {
      return;
    }
    const duration: number = MotionRuntime.ms(this.durationMs);
    if (duration <= 0) {
      // 关闭动画时直接跳过（源码在 disableAnimations 下不走控制器）
      this.value = 0;
      return;
    }
    this.startMs = Date.now();
    this.value = 0.0001;
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
    }
    this.timerId = setInterval(() => {
      const t: number = Math.min(1, (Date.now() - this.startMs) / duration);
      this.value = t;
      this.draw();
      if (t >= 1) {
        clearInterval(this.timerId);
        this.timerId = -1;
        this.value = 0;
      }
    }, 16);
  }

  /** `_interval`：区间内过曲线，区间外取端点。 */
  private static interval(value: number, begin: number, end: number,
    curve: (t: number) => number): number {
    if (value <= begin) {
      return 0;
    }
    if (value >= end) {
      return 1;
    }
    return curve((value - begin) / (end - begin));
  }

  /** `_pulse`：0 → 峰值 → 0 的一条鼓包。 */
  private static pulse(value: number, begin: number, peak: number,
    end: number): number {
    if (value <= begin || value >= end) {
      return 0;
    }
    if (value <= peak) {
      return ScreenshotFeedback.interval(value, begin, peak, (t: number) => {
        return AppCurves.easeOutCubic().interpolate(t);
      });
    }
    return 1 - ScreenshotFeedback.interval(value, peak, end, (t: number) => {
      return AppCurves.easeOutCubic().interpolate(t);
    });
  }

  private draw(): void {
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    this.ctx.clearRect(0, 0, w, h);
    if (this.value <= 0 || w <= 0 || h <= 0) {
      return;
    }

    // 1) 整屏压暗
    const dim: number = 0.12 * ScreenshotFeedback.pulse(this.value, 0, 0.18, 0.62);
    if (dim > 0) {
      this.ctx.fillStyle = `rgba(0,0,0,${dim})`;
      this.ctx.fillRect(0, 0, w, h);
    }

    // 2) 取景框
    const fadeIn: number = ScreenshotFeedback.interval(this.value, 0, 0.14,
      (t: number) => AppCurves.easeOut().interpolate(t));
    const fadeOut: number = ScreenshotFeedback.interval(this.value, 0.58, 1.0,
      (t: number) => AppCurves.easeOutCubic().interpolate(t));
    const opacity: number = 0.90 * fadeIn * (1 - fadeOut);
    if (opacity <= 0) {
      return;
    }
    const progress: number = ScreenshotFeedback.interval(this.value, 0, 0.68,
      (t: number) => AppCurves.easeOutCubic().interpolate(t));

    const insetX: number = w * (0.055 + 0.025 * progress);
    const insetY: number = h * (0.075 + 0.030 * progress);
    const left: number = insetX;
    const top: number = insetY;
    const right: number = w - insetX;
    const bottom: number = h - insetY;
    const shortest: number = Math.min(right - left, bottom - top);
    const corner: number = Math.max(22, Math.min(54, shortest * 0.12));
    const strokeWidth: number = Math.max(1.4, Math.min(2.2, 1.4 + 0.8 * (1 - progress)));

    this.ctx.strokeStyle = `rgba(255,255,255,${opacity})`;
    this.ctx.lineWidth = strokeWidth;
    this.ctx.lineCap = 'round';
    this.ctx.beginPath();
    // 左上
    this.ctx.moveTo(left, top + corner);
    this.ctx.lineTo(left, top);
    this.ctx.lineTo(left + corner, top);
    // 右上
    this.ctx.moveTo(right - corner, top);
    this.ctx.lineTo(right, top);
    this.ctx.lineTo(right, top + corner);
    // 右下
    this.ctx.moveTo(right, bottom - corner);
    this.ctx.lineTo(right, bottom);
    this.ctx.lineTo(right - corner, bottom);
    // 左下
    this.ctx.moveTo(left + corner, bottom);
    this.ctx.lineTo(left, bottom);
    this.ctx.lineTo(left, bottom - corner);
    this.ctx.stroke();
  }

  build() {
    Column()
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
      .visibility(this.value > 0 ? Visibility.Visible : Visibility.Hidden)
      .onAreaChange((oldValue: Area, newValue: Area) => {
        this.draw();
      })
      .overlay(this.canvasLayer())
  }

  @Builder
  canvasLayer() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .onReady(() => {
        this.draw();
      })
  }
}
