import { AppColor } from '../theme/AppColors';

/**
 * 调节滑杆。**胶囊样式**（2026-09-18 起）。
 *
 * 用户 2026-09-18：「所有设置页包括弹窗里涉及进度条调整（例如弹幕设置以及
 * 下载设置这种）的可以做成类似夏绊那种调节的胶囊进度条嘛？」
 * ——夏绊（`F:\app`）的设置页用的是 `SliderStyle.InSet` + `trackThickness(32)`
 * + 18vp 白色小滑块，也就是「一根厚胶囊槽 + 里面一颗白点」。
 *
 * 因此本控件从「细轨道 + 主色小圆」（规格 §38.14 的 `_HarmonySliderPainter`）
 * 改成同一套胶囊参数：
 *
 * | 元素 | 参数 |
 * | --- | --- |
 * | 轨道 | 高 **32**、两端全圆角，**整宽铺满控件**（滑块永远嵌在槽里面） |
 * | 未选段 | `AppColor.sliderTrack`（`onSurface` @ 40%） |
 * | 已选段 | `AppColor.primary`，从轨道左端铺到「滑块中心 + 半个槽高」，圆头套住滑块 |
 * | 滑块 | 半径 **9**（拖动中 11）；`AppColor.sliderBlock` 纯白 + 一圈极淡投影 |
 * | 取值 | `t = (x − r) / (宽 − 2r)`，r = 当前滑块半径；有 `divisions` 时按步长取整 |
 *
 * 自绘而不是换成内置 `Slider` 的理由没有变：弹层把滑杆放在纵向 `Scroll` 里，
 * 这里用 `priorityGesture` + 横向限定，才能「拖动改值」与「上下滚列表」不打架。
 * 拖动只改滑块半径、**没有过渡动画**，与夏绊的即时重绘一致。
 */
@Component
export struct HarmonySlider {
  /**
   * 外部传入的值（初始值 / 编程式改值）。
   *
   * ⚠️ 拖动时**不要**指望这个值会跟着更新：调用方多半是带值参数的 `@Builder`，
   * ArkUI 的那类 builder 不随状态刷新，@Prop 就一直停在旧值——用户看到的
   * 就是「滑块拖不动」。所以控件自己维护 `localValue`，拖动期间以它为准
   * （用户 2026-09-18：「弹幕设置卡片里不能即时拖动修改条」）。
   */
  @Prop @Watch('onValuePropChanged') value: number = 0;
  min: number = 0;
  max: number = 1;
  /** 0 = 连续取值（对应源码 `divisions == null`）。 */
  divisions: number = 0;
  onChanged: (value: number) => void = () => {
  };

  @State private dragging: boolean = false;
  /** 控件自己那本账：绘制一律读它，保证手指到哪滑块到哪。 */
  private localValue: number = 0;
  /** 胶囊轨道高：对齐夏绊的 `trackThickness(32)`。 */
  private static readonly trackHeight: number = 32;
  /** 滑块半径：夏绊 `blockSize` 18 → 半径 9（拖动中 11，轻微"捏起"反馈）。 */
  private static readonly blockRadius: number = 9;
  private static readonly blockRadiusDragging: number = 11;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  aboutToAppear(): void {
    this.localValue = this.value;
  }

  /** 外部改值（例如「恢复同步」清零）时同步下来；拖动中不打断手势。 */
  onValuePropChanged(): void {
    if (this.dragging) {
      return;
    }
    this.localValue = this.value;
    this.draw();
  }

  private progress(): number {
    const span: number = this.max - this.min;
    if (span <= 0) {
      return 0;
    }
    return Math.max(0, Math.min(1, (this.localValue - this.min) / span));
  }

  /**
   * 滑块中心能贴到两端的距离 = **当前滑块半径**。
   *
   * 这就是「槽要包住滑块」的关键：轨道整宽铺满控件，而滑块中心只走到半径处，
   * 于是任何取值下滑块都完整落在槽里——贴到最左 / 最右时它正好嵌进槽的圆头
   * （用户 2026-09-19：「胶囊进度条中的进度条没有包裹住滑块」）。
   * 拖动中半径会涨到 11，行程同步收 2vp，位置与手感一致。
   */
  private travel(): number {
    return this.dragging
      ? HarmonySlider.blockRadiusDragging : HarmonySlider.blockRadius;
  }

  /** `_update`：把本地 x 换算成取值（含 `divisions` 取整）。 */
  private updateFromLocalX(localX: number): void {
    const width: number = this.ctx.width;
    // 与绘制同源：轨道整宽，滑块中心行程 [半径, 宽 − 半径]。
    const inset: number = this.travel();
    const usable: number = Math.max(1, width - inset * 2);
    const t: number = Math.max(0, Math.min(1, (localX - inset) / usable));
    let next: number = this.min + t * (this.max - this.min);
    if (this.divisions > 0) {
      const step: number = (this.max - this.min) / this.divisions;
      next = this.min + Math.round((next - this.min) / step) * step;
    }
    if (Math.abs(next - this.localValue) > 1e-6) {
      this.localValue = next;
      this.onChanged(next);
    }
  }

  private static fingerX(event: GestureEvent): number {
    const list: FingerInfo[] = event.fingerList;
    if (list !== undefined && list.length > 0) {
      return list[0].localX;
    }
    return 0;
  }

  /**
   * 构造一根两端全圆的胶囊路径（调用方决定 `fill()` 还是 `clip()`）。
   *
   * `x1 − x0` 小于轨道高时圆角按可用宽度收敛：取值贴到最右端时已选段很窄，
   * 不收敛会画出一个鼓出槽外的形状。
   */
  private capsule(x0: number, x1: number, centerY: number, height: number): void {
    const half: number = height / 2;
    const radius: number = Math.max(1, Math.min(half, (x1 - x0) / 2));
    this.ctx.beginPath();
    this.ctx.moveTo(x0 + radius, centerY - half);
    this.ctx.lineTo(x1 - radius, centerY - half);
    this.ctx.arcTo(x1, centerY - half, x1, centerY - half + radius, radius);
    this.ctx.lineTo(x1, centerY + half - radius);
    this.ctx.arcTo(x1, centerY + half, x1 - radius, centerY + half, radius);
    this.ctx.lineTo(x0 + radius, centerY + half);
    this.ctx.arcTo(x0, centerY + half, x0, centerY + half - radius, radius);
    this.ctx.lineTo(x0, centerY - half + radius);
    this.ctx.arcTo(x0, centerY - half, x0 + radius, centerY - half, radius);
    this.ctx.closePath();
  }

  private draw(): void {
    const width: number = this.ctx.width;
    const height: number = this.ctx.height;
    this.ctx.clearRect(0, 0, width, height);
    if (width <= 0 || height <= 0) {
      return;
    }
    const centerY: number = height / 2;
    const trackHeight: number = HarmonySlider.trackHeight;
    const thumbRadius: number = this.travel();
    /**
     * 槽**整宽**铺满控件（`left = 0`，不再是原来的 9 / 宽−9）。
     *
     * 滑块中心行程改成 `[半径, 宽 − 半径]`：两者一起看，滑块无论停在哪里都完整
     * 落在槽里（原来的写法把轨道两端各内缩了 9，滑块中心又跑到那两条边上，
     * 结果滑块有一半悬在槽外）。
     */
    const left: number = 0;
    // 首帧还没量到宽度时保底 1vp，避免路径退化成一个点
    const right: number = Math.max(1, width);
    const travelSpan: number = Math.max(1, right - left - thumbRadius * 2);
    const thumbX: number = thumbRadius + travelSpan * this.progress();

    // 未选段：整根胶囊槽
    this.capsule(left, right, centerY, trackHeight);
    this.ctx.fillStyle = AppColor.sliderTrack;
    this.ctx.fill();

    /**
     * 已选段：一根两端全圆的胶囊，**圆头的圆心落在滑块中心上**，于是滑块被
     * 包在这段填充里（用户 2026-09-19：「已经走过的进度条还是没有包裹住滑块」）。
     *
     * 所以右端画到 `滑块中心 + 半个槽高`（= 轨道圆角半径）而不是滑块中心：
     * 圆角半径给 16 时，圆头的圆心正好退回到 `thumbX`，半径 16 的圆完整罩住
     * 半径 9 的滑块——这就是夏绊 `SliderStyle.InSet` 那种「白点嵌在填充段里」的观感。
     * 多画出去的一段由上面这次裁切压在槽内，贴到最右端就是整条槽填满。
     */
    this.ctx.save();
    this.capsule(left, right, centerY, trackHeight);
    this.ctx.clip();
    this.capsule(left, thumbX + trackHeight / 2, centerY, trackHeight);
    this.ctx.fillStyle = AppColor.primary;
    this.ctx.fill();

    /**
     * 滑块阴影也**裁在槽内**画：源码用 `MaskFilter.blur(4)`，ArkUI 的 Canvas
     * 没有 blur，用一圈半透明同心圆近似。放进这次裁切里是因为滑块贴到两端时
     * 光晕会比槽多出 2vp——不裁的话槽外会留一小片灰。
     */
    this.ctx.fillStyle = AppColor.isDark ? '#59000000' : '#1F000000';
    this.ctx.beginPath();
    this.ctx.arc(thumbX, centerY, thumbRadius + 2, 0, Math.PI * 2);
    this.ctx.fill();
    this.ctx.restore();

    // 滑块：纯白小圆（夏绊 blockColor）
    this.ctx.fillStyle = AppColor.sliderBlock;
    this.ctx.beginPath();
    this.ctx.arc(thumbX, centerY, thumbRadius, 0, Math.PI * 2);
    this.ctx.fill();
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height(40)
      .onReady(() => {
        this.draw();
      })
      .onAreaChange((oldValue: Area, newValue: Area) => {
        this.draw();
      })
      /**
       * 拖动。
       *
       * 这里必须是 **`priorityGesture` + 限定横向**：弹幕设置弹层把滑杆放在
       * 一个纵向 `Scroll` 里，用普通 `gesture` 时外层 Scroll 会在手势竞争里
       * 抢走这一次拖动（用户 2026-09-18：「弹幕的弹窗无法拖动设置」）。
       * `priorityGesture` 让子节点的拖动优先于父容器，横向限定则保证
       * 纵向滑动仍然交给 Scroll 滚列表。
       */
      .priorityGesture(
        PanGesture({ direction: PanDirection.Horizontal })
          .onActionStart((event: GestureEvent) => {
            this.dragging = true;
            this.updateFromLocalX(HarmonySlider.fingerX(event));
            this.draw();
          })
          .onActionUpdate((event: GestureEvent) => {
            this.updateFromLocalX(HarmonySlider.fingerX(event));
            this.draw();
          })
          .onActionEnd(() => {
            this.dragging = false;
            this.draw();
          })
          .onActionCancel(() => {
            this.dragging = false;
            this.draw();
          })
      )
      .gesture(
        TapGesture()
          .onAction((event: GestureEvent) => {
            this.updateFromLocalX(HarmonySlider.fingerX(event));
            this.draw();
          })
      )
  }
}
