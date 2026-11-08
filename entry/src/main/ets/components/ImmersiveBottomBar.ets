import { AppColor, AppAlpha } from '../theme/AppColors';
import { Dimens, Motion, AppCurves } from '../theme/Tokens';
import { AppMaterial } from '../theme/Material';

export class NavItemModel {
  outlineIcon: Resource;
  filledIcon: Resource;
  label: string;

  constructor(outlineIcon: Resource, filledIcon: Resource, label: string) {
    this.outlineIcon = outlineIcon;
    this.filledIcon = filledIcon;
    this.label = label;
  }
}

/**
 * 对应参照实现 lib/pages/menu/immersive_bottom_bar.dart 的 ImmersiveBottomBar。
 *
 * 规格（源码常量 + 实测）：
 *   高 52 / 左右内缩 18 / 距系统底 8 / 内边距 5 / 圆角 26
 *   浅色玻璃底 白 92%，描边 黑 5%，阴影 黑 10% blur 28 offset(0,10)
 *   选中胶囊 primary 13%，圆角 21，切换 220ms easeOutCubic
 *   图标 23，文字 11，选中 w600 / 未选中 w500
 */
@Component
export struct ImmersiveBottomBar {
  @Prop selectedIndex: number;
  /**
   * 主题版本。
   *
   * ArkUI 的更新是**按属性粒度**的：只重绘「build 里读到过」的那部分。
   * 颜色来自 `AppColor.*` 普通取值、不会被追踪，所以必须由父组件把
   * 主题版本作为 @Prop 传进来——@Prop 变化会让本组件整体重跑 build，
   * 从而取到全部新配色。
   */
  @Prop themeRev: number = 0;
  items: NavItemModel[] = [];
  onSelected: (index: number) => void = () => {};

  build() {
    Row() {
      ForEach(this.items, (item: NavItemModel, index: number) => {
        Column() {
          SymbolGlyph(index === this.selectedIndex ? item.filledIcon : item.outlineIcon)
            .fontSize(23)
            .fontColor([index === this.selectedIndex ? AppColor.primary : AppColor.onSurfaceVariant])
          Text(item.label)
            .fontSize(11)
            .lineHeight(11)
            .fontWeight(index === this.selectedIndex ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(index === this.selectedIndex ? AppColor.primary : AppColor.onSurfaceVariant)
            .margin({ top: 2 })
            .maxLines(1)
        }
        .layoutWeight(1)
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .borderRadius(Dimens.navPillRadius)
        .backgroundColor(index === this.selectedIndex ? AppAlpha.navPillLight : Color.Transparent)
        .animation({
          duration: Motion.medium,
          curve: AppCurves.easeOutCubic()
        })
        .onClick(() => {
          this.onSelected(index);
        })
      }, (item: NavItemModel) => item.label)
    }
    .height(Dimens.navHeight)
    .padding(Dimens.navPadding)
    .borderRadius(Dimens.navHeight / 2)
    // 系统材质：底栏是全应用最需要「沉浸光感」的地方——列表从下方穿过，
    // 材质负责真模糊，`navGlassLight` 只提供染色。
    .backgroundBlurStyle(AppMaterial.bar, AppMaterial.options())
    .backgroundColor(AppColor.navGlassLight)
    .border({ width: 1, color: AppColor.navBorderLight })
    .shadow({ radius: 28, color: '#1A000000', offsetX: 0, offsetY: 10 })
    .clip(true)
  }
}
