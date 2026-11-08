import { AppColor } from '../theme/AppColors';

/**
 * 全局加载指示器 —— **HarmonyOS 系统加载符号**（ArkUI `LoadingProgress`）。
 *
 * 为什么换成它（用户 2026-09-17 要求「加载符号换成华为独特的」）：
 *
 * | 维度 | 旧实现（M3 七形状变形，见 `MaterialMorphLoader.ets`） | 现实现 |
 * | --- | --- | --- |
 * | 观感 | Material 3 的 `material_new_shapes` 形状变形 | HarmonyOS 系统转圈，与系统应用/设置/应用市场同款 |
 * | 实现 | Canvas 自绘 + 180 点轮廓插值 + 16ms 定时器 | 一个系统组件，零自绘 |
 * | 开销 | 每帧 180 次插值 + 全画布重绘，页面里多个实例各带一个定时器 | 由渲染框架统一驱动，无 JS 定时器 |
 * | 无障碍 | 手工挂 `accessibilityText` | 组件自带进度语义，`accessibilityText` 只作补充 |
 * | 主题 | 手工取 `AppColor.primary` | 支持自定义色，默认仍跟随主题主色 |
 *
 * 这不是「美化」而是**换成平台自己的符号**：HarmonyOS 的加载语义由
 * `LoadingProgress` 承载，系统在动效、色板、无障碍与省电策略上统一处理，
 * 自定义画法无法与之保持一致（同屏出现两种转圈会立刻露馅）。
 *
 * 接口与旧实现**完全一致**（`sizeVp` / `colorHex` / `label`），
 * 全部调用点无需改动。若日后想切回 M3 变形动画，
 * 把调用点的 `LoadingIndicator` 换成 `MaterialMorphLoader` 即可。
 *
 * 用法：
 *   `LoadingIndicator({ sizeVp: 40 })`
 *   `LoadingIndicator({ sizeVp: 32, colorHex: AppColor.tertiaryContainer })`（深色底上）
 */
@Component
export struct LoadingIndicator {
  /**
   * 指示器边长（vp）。默认 48。
   *
   * 名字不能叫 `size`：ArkUI 的 `CustomComponent` 基类上已经有 `size` 属性，
   * 同名会报「not assignable to the same property in base type」。
   */
  sizeVp: number = 48;
  /** 颜色，缺省用主题主色。深色 / 视频底传 `'#FFFFFF'` 之类的实色。 */
  colorHex: string = '';
  /** 无障碍文案（默认「加载中」）。`LoadingProgress` 自带加载语义，这里只作补充。 */
  label: string = '加载中';

  build() {
    LoadingProgress()
      .width(this.sizeVp)
      .height(this.sizeVp)
      .color(this.colorHex.length > 0 ? this.colorHex : AppColor.primary)
      // 组件出现即开始转；置 false 会停在当前角度（本工程没有「暂停加载」的场景）
      .enableLoading(true)
      .accessibilityText(this.label)
  }
}
