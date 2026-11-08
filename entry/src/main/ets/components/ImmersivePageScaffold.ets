import { AppColor } from '../theme/AppColors';
import { AppBackground } from './AppBackground';
import { AppMaterial } from '../theme/Material';

/**
 * 沉浸式页面外壳。
 *
 * 对应源码 `lib/bean/widget/immersive_page_scaffold.dart`：
 *   - 内容铺满整窗（含状态栏区域），标题栏是浮在上层的胶囊
 *   - 返回键：圆形玻璃胶囊，内边距 12、图标 20
 *   - 标题：headlineSmall（20/w600）再提到 w800、letterSpacing 0.3
 *   - 标题栏位置：statusTop + 10，左右各 16，返回键与标题间距 12
 *   - 内容区需要自己让位：`ImmersiveMetrics.contentTopPadding` =
 *     statusTop + topOffset(66) + 8
 */
export class ImmersiveMetrics {
  /** 源码 `ImmersivePageScaffold.topOffset` 默认值。 */
  static readonly topOffset: number = 66;
  /** SettingsList 自己的上内边距。 */
  static readonly listTopPadding: number = 8;
  /** SettingsList 自己的下内边距。 */
  static readonly listBottomPadding: number = 24;

  /** 内容区需要预留的顶部高度（vp）。 */
  static contentTop(statusTop: number): number {
    return statusTop + ImmersiveMetrics.topOffset + ImmersiveMetrics.listTopPadding;
  }
}

/**
 * 沉浸式**悬浮标题层**（只有标题，不含内容外壳）。
 *
 * 与 `ImmersivePageScaffold` 是同一套外观：玻璃返回圆钮（44 圆、图标 20）+ 标题
 * （20/w800、letterSpacing 0.3）+ 顶部渐隐遮罩，位置同样是 `topInset + 10`。
 *
 * 为什么单独做成一层：设置页原来的结构是 `Column { 标题行(56); Scroll }`。
 * 若改用 `ImmersivePageScaffold` 包裹，内容整体要多缩进一层，十几个页面的 diff
 * 会变成几百行「只改空白」——既难审也容易改错。这一层让改造只剩两处：
 *   1. 把原来的标题行换成 `ImmersiveTitleLayer(...)`；
 *   2. 给内容容器加 `ImmersiveMetrics.contentTop(topInset)` 的顶部让位。
 *
 * 用法：作为页面根 `Column` 的**第一个子节点**。它自己 `position(0,0)` + `zIndex(1)`，
 * 不占布局高度，所以下面的 `Scroll` 铺满整页、内容从标题下面滚过去。
 *
 * 需要标题栏右侧带按钮的页面（例如屏蔽规则的「添加规则」），把按钮作为子节点传进来
 * 即可，会排在标题右边。
 */
@Component
export struct ImmersiveTitleLayer {
  @Prop themeRev: number = 0;
  title: string = '';
  onBack: () => void = () => {
  };
  @StorageProp('topInset') topInset: number = 39;
  @Builder
  emptyAction() {
  }
  /** 标题右侧的额外操作（可选）。 */
  @BuilderParam action: () => void = this.emptyAction;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 顶部渐隐：内容从标题下面滑过时淡出，标题始终清晰
      Column()
        .width('100%')
        .height(this.topInset + ImmersiveMetrics.topOffset)
        .linearGradient({
          angle: 180,
          colors: [
            [AppColor.withAlpha(AppColor.surface, 0.94), 0.0],
            [AppColor.withAlpha(AppColor.surface, 0.0), 1.0]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      Row() {
        Stack() {
          SymbolGlyph($r('sys.symbol.arrow_left'))
            .fontSize(20)
            .fontColor([AppColor.onSurface])
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        // 返回圆钮浮在滚动内容之上，材质在这里是真的能看到模糊的
        .backgroundBlurStyle(AppMaterial.capsule, AppMaterial.options())
        .backgroundColor(AppColor.glassCapsuleFill)
        .border({ width: 1, color: AppColor.glassBorder })
        .shadow({ radius: 24, color: AppColor.navShadow, offsetX: 0, offsetY: 8 })
        .onClick(() => {
          this.onBack();
        })

        Text(this.title)
          .fontSize(20)
          .lineHeight(27)
          .fontWeight(800)
          .letterSpacing(0.3)
          .fontColor(AppColor.onSurface)
          .maxLines(1)
          .layoutWeight(1)
          .margin({ left: 12 })

        this.action()
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .margin({ top: this.topInset + 10 })
    }
    .width('100%')
    .height(this.topInset + ImmersiveMetrics.topOffset)
    // 不占布局高度：内容铺满整页，标题只是浮在上面
    .position({ x: 0, y: 0 })
    .zIndex(1)
    // 自身不吃触摸（只有里面的返回钮 / 操作按钮响应），否则会挡住内容滚动
    .hitTestBehavior(HitTestMode.Transparent)
  }
}

@Component
export struct ImmersivePageScaffold {
  /** 主题版本：由父组件下发，@Prop 变化会让本组件整体重跑 build。 */
  @Prop themeRev: number = 0;
  @BuilderParam content: () => void;
  title: string = '';
  onBack: () => void = () => {
  };
  @StorageProp('topInset') topInset: number = 39;

  build() {
    Column() {
      AppBackground() {
        Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.content()
      }
      .width('100%')
      .height('100%')

      Row() {
        Stack() {
          SymbolGlyph($r('sys.symbol.arrow_left'))
            .fontSize(20)
            .fontColor([AppColor.onSurface])
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        // 返回圆钮浮在滚动内容之上，材质在这里是真的能看到模糊的
        .backgroundBlurStyle(AppMaterial.capsule, AppMaterial.options())
        .backgroundColor(AppColor.glassCapsuleFill)
        .border({ width: 1, color: AppColor.glassBorder })
        .shadow({ radius: 24, color: AppColor.navShadow, offsetX: 0, offsetY: 8 })
        .onClick(() => {
          this.onBack();
        })

        Text(this.title)
          .fontSize(20)
          .lineHeight(27)
          .fontWeight(800)
          .letterSpacing(0.3)
          .fontColor(AppColor.onSurface)
          .maxLines(1)
          .margin({ left: 12 })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .margin({ top: this.topInset + 10 })
    }
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
    }
    .width('100%')
    .height('100%')
  }
}
