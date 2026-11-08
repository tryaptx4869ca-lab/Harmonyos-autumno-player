import { AppColor } from '../theme/AppColors';
import { CoverImage } from './CoverImage';

/**
 * 详情页的模糊海报背景（整页底图）。
 *
 * 从 `InfoPage.poster()` 抽出来做成组件，参数（sourceSize、blur、scale、
 * 两层遮罩与五段渐变）照抄原实现；详情页整页的淡入淡出由页面根节点的
 * opacity/translate 负责（见 `InfoPage.enterOpacity`），这一层不单独动。
 */
@Component
export struct DetailBackdrop {
  /** 封面 URL：两端必须同址（见 `HeroFlight` 的注释），空白时退化成主题底色。 */
  @Prop cover: string = '';
  /**
   * 整层透明度（1 = 详情页静止态的样子）。
   *
   * ⚠️ 不能叫 `opacity`：那会与 `CustomComponent` 自带的同名属性冲突，
   * ArkTS 直接报 “Property 'opacity' … is not assignable to the same property
   * in base type 'CustomComponent'”。
   */
  @Prop layerOpacity: number = 1;
  /**
   * 纵向偏移（占自身高度的比例）。
   *
   * 对照参照实现的页面转场：`PageTransitionEnter/Exit` 都是
   * `Fade + Slide(Offset(0, 0.02))`——进场从下方 2% 淡入、退场向下 2% 淡出。
   * 用户 2026-10-08：「背景层的转场参考 flutter 的感觉」，所以这一层除了
   * 透明度，还要跟着位移；内容层（含共享元素封面）不动，免得飞行的目标点跑偏。
   */
  @Prop slideRatio: number = 0;

  build() {
    Stack() {
      if (this.cover.length > 0) {
        CoverImage({
          src: this.cover,
          fit: ImageFit.Cover,
          sourceWidth: 200,
          sourceHeight: 360
        })
          .width('100%')
          .height('100%')
          /**
           * 模糊半径：32 → **46**（用户 2026-10-08 追加要求「增加一下背景的模糊度」）。
           *
           * 参照实现是 `ImageFilter.blur(sigmaX: 10, sigmaY: 10)`
           * （`info_page.dart:516`）。这层直接垫在 Tab 条 / 正文的**白字**下面，
           * 糊得不够就压不住海报细节，字会花——所以这里宁可更糊一点。
           * 再要调就只改这一个数。
           */
          .blur(46)
          .scale({ x: 1.08, y: 1.08 })
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(AppColor.isDark ? '#38000000' : '#29FFFFFF')
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [
              ['#99000000', 0.0],
              ['#4D000000', 0.30],
              ['#00000000', 0.58],
              ['#00000000', 0.86],
              ['#00000000', 1.0]
            ]
          })
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(AppColor.surface)
      }
    }
    .width('100%')
    .height('100%')
    .opacity(this.layerOpacity)
    .translate({ y: `${this.slideRatio * 100}%` })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
