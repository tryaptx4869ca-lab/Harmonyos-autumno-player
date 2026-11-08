import { AppColor } from '../theme/AppColors';

/**
 * 播放 / 暂停图标 —— **HarmonyOS 符号替换动效**
 * （`SymbolGlyph` + `ReplaceSymbolEffect`）。
 *
 * 旧实现是 Canvas 自绘：把「两条竖条」和「三角形」拆成左右两个四边形，
 * 顶点一一对应后按 300ms 逐点插值（对应 Flutter 的
 * `AnimatedIcons.play_pause`）。那是**为 Flutter 的路径变形做的手工复刻**。
 *
 * 2026-09-17 换成系统符号替换：
 *
 * | 维度 | 旧（Canvas 插值） | 现（系统替换） |
 * | --- | --- | --- |
 * | 观感 | 两条竖条「长成」三角形 | 两个 HarmonyOS 符号交叉淡入淡出 |
 * | 实现 | 手写顶点插值 + 每帧重绘自己的定时器 | 一个属性 `.symbolEffect(...)` |
 * | 语义 | 纯装饰 | 符号本身带系统语义（播放 / 暂停各有字形） |
 *
 * `ReplaceEffectType.CROSS_FADE` 是官方少数几个替换类型里
 * 「旧符号淡出与新符号淡入同时进行、更快更顺」的那一个；
 * `EffectScope.WHOLE` 表示整体替换（`LAYER` 是分层动效，用在双色符号上）。
 *
 * ⚠️ 图标方向别写反：`playing === true` 时要显示的是**暂停**图标
 * （提示「点一下会暂停」），旧实现里踩过这个坑（真机上出现
 * 「正在播放却显示播放三角、暂停了反而显示两条竖条」）。
 */
@Component
export struct PlayPauseIcon {
  /** 是否处于播放态。true = 显示暂停图标。 */
  @Prop @Watch('onPlayingChanged') playing: boolean = false;
  /** 图标边长（vp），源码默认 25。 */
  sizeVp: number = 25;
  /** 颜色，默认白色（播放页控制条）。 */
  colorHex: string = '#FFFFFF';

  /**
   * 触发计数。
   *
   * `symbolEffect(effect, triggerValue)` 是在 **triggerValue 变化**时播放的，
   * 直接传布尔量不行（值不变就不会重放，来回切也只认第一次），
   * 所以每次状态翻转就 +1。
   */
  @State private trigger: number = 0;

  private onPlayingChanged(): void {
    this.trigger++;
  }

  build() {
    SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
      .fontSize(this.sizeVp)
      .fontColor([this.colorHex.length > 0 ? this.colorHex : AppColor.onPrimary])
      .symbolEffect(
        new ReplaceSymbolEffect(EffectScope.WHOLE, ReplaceEffectType.CROSS_FADE),
        this.trigger)
  }
}
