import { AppColor } from '../theme/AppColors';
import { ThemeManager } from '../theme/ThemeManager';

/**
 * 全局背景层。
 *
 * 逐行对应源码 `lib/bean/widget/app_background.dart`：
 *
 * 1. **没有自定义背景**时，只铺页面底色（`scaffoldBackgroundColor`）。
 *    源码注释说明原因：沉浸式页面自身是透明 Scaffold，被 push 的页面
 *    会盖住下面那层，不铺底色会渲染成黑色。
 * 2. 有自定义背景时叠三层：
 *    图片（`BoxFit.cover`，decode 宽度 1080）→ 半透明遮罩 → 内容。
 *    遮罩透明度按强度线性插值：
 *      深色 `0.28 + intensity/100 * 0.34`；浅色 `0.08 + intensity/100 * 0.22`。
 *
 * 与原实现的差异（待校准）：源码用的是**离线生成的模糊 PNG**，
 * 这里先用渲染期 `blur()` 替代，半径按源码的
 * `radius = intensity/100*24`（相对 720 宽）换算到 vp。
 */
@Component
export struct AppBackground {
  @BuilderParam content: () => void;
  /** 主题版本号：背景图/强度/明暗变化都要重绘。 */
  @StorageProp('themeRevision') themeRevision: number = 0;

  /** 遮罩透明度（源码 app_background.dart 的 scrimAlpha）。 */
  private scrimAlpha(): number {
    const revision: number = this.themeRevision;
    if (revision < 0) {
      return 0;
    }
    const intensity: number =
      Math.min(100, Math.max(0, ThemeManager.instance().backgroundIntensity));
    const isDark: boolean = ThemeManager.instance().current().isDark;
    return isDark
      ? 0.28 + intensity / 100 * 0.34
      : 0.08 + intensity / 100 * 0.22;
  }

  private hasBackground(): boolean {
    const revision: number = this.themeRevision;
    if (revision < 0) {
      return false;
    }
    return ThemeManager.instance().hasCustomBackground;
  }

  /**
   * 模糊半径（vp）。
   *
   * 源码在 720 宽的图上按 `intensity/100*24` 像素模糊，显示时以 cover 铺满屏，
   * 折算系数取 **1.2**（用户 2026-10-08 要求「增加一下背景的模糊度」；
   * 原来是 0.5、上一版 0.8，这一版再调大一档）。
   *
   * 为什么调大：07-08 那轮把背景从「240×480 降采样」改成「等比例 ≤1080 副本」
   * 之后，同一份模糊盖在**更清晰**的底图上，观感上明显变糊少了，深色壁纸下
   * 页面文字开始不好读（用户 2026-10-08：「背景模糊度参考 flutter，现在太不模糊」）。
   */
  private blurRadiusVp(): number {
    const intensity: number =
      Math.min(100, Math.max(0, ThemeManager.instance().backgroundIntensity));
    return intensity / 100 * 24 * 1.2;
  }

  private backgroundPath(): string {
    const manager: ThemeManager = ThemeManager.instance();
    const blurred: string = manager.backgroundBlurredPath;
    return blurred.length > 0 ? blurred : manager.backgroundPath;
  }

  private scrimColor(): string {
    const isDark: boolean = ThemeManager.instance().current().isDark;
    const alpha: number = Math.round(this.scrimAlpha() * 255);
    const rgb: number = isDark ? 0x000000 : 0xFFFFFF;
    return '#' + ((alpha << 24 | rgb) >>> 0).toString(16).toUpperCase().padStart(8, '0');
  }

  build() {
    Stack() {
      // 第一层：页面底色（没有自定义背景时这就是最终背景）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(AppColor.surface)

      if (this.hasBackground()) {
        /**
         * 背景图 + 蒙层包在一个容器里：这层铺满整屏、还带 `blur()`，
         * 包起来便于统一控制（**没有**开 `renderGroup`——实测那会让模糊观感
         * 变弱，用户 2026-10-08 反馈背景「太不模糊、文字不好读」）。
         */
        Column() {
          Image(`file://${this.backgroundPath()}`)
            .width('100%')
            .height('100%')
          /**
           * ⚠️ **不要**在这里设 `sourceSize`。
           *
           * `Image.sourceSize` 是「强制解码尺寸」：与原图比例不一致时会把位图
           * **拉伸**（用户 2026-10-07：自定义背景尺寸不对时被拉变形，「原图」
           * 那一档最明显）。省解码开销这件事已经挪到**选图时**做：
           * `BackgroundService.writeScaledCopy()` 会存一张宽 ≤1080 的
           * **等比例**副本当背景（等价参照实现的 `cacheWidth: 1080`），所以这里
           * 按需解码也不会碰上 4000×3000 那种大图。老版本存下来的原图没有缩略
           * 副本，这里同样不设解码尺寸——内存多花一点，但比例一定是对的。
           */
            .objectFit(ImageFit.Cover)
          /**
           * 轻微放大：这层必然要模糊，模糊会采样到画布之外，边缘像素被冲淡成
           * 透明，屏边会出现一圈发白的痕迹（详情页背景用的是同一招）。
           */
            .scale({ x: 1.06, y: 1.06 })
            .blur(this.blurRadiusVp())
            .interpolation(ImageInterpolation.High)

          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.scrimColor())
        }
        .width('100%')
        .height('100%')
      }

      this.content()
    }
    .width('100%')
    .height('100%')
  }
}
