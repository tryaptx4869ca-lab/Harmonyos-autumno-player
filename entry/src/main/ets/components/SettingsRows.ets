import { AppColor } from '../theme/AppColors';
import { SettingsMetrics } from './SettingsList';
import { HarmonySlider } from './HarmonySlider';

/**
 * 设置页的补充行组件。
 *
 * `SettingsList.ets` 里已有「普通行 / 开关行」（`SettingsRow`）；
 * 这里补上参照实现里另外三种行：
 *   - `SettingsSliderRow`：滑杆行（对应 `SettingsSliderTile`）
 *   - `SettingsChoiceRow`：下拉选择行（对应 `SettingsDropdownTile` / 单选对话框）
 *   - `SettingsNumberRow`：数字输入行（对应 `SettingsNumberTile`）
 *
 * 圆角规则与 `SettingsRow` 一致：分组首行上圆角 24、末行下圆角 24、中间 4，
 * 由调用方按行在分组中的位置传入（与 `SplitListRow` 的传参方式相同）。
 */

/** 分组内某一行应有的上圆角。 */
export function groupTopRadius(index: number): number {
  return index === 0 ? SettingsMetrics.groupOuterRadius : SettingsMetrics.groupInnerRadius;
}

/** 分组内某一行应有的下圆角。 */
export function groupBottomRadius(index: number, count: number): number {
  return index === count - 1
    ? SettingsMetrics.groupOuterRadius : SettingsMetrics.groupInnerRadius;
}

/** 滑杆行。 */
@Component
export struct SettingsSliderRow {
  @Prop themeRev: number = 0;
  @Prop title: string = '';
  @Prop description: string = '';
  /** 当前值的文本（例如「1.5x」「12s」）。 */
  @Prop valueText: string = '';
  @Prop value: number = 0;
  @Prop min: number = 0;
  @Prop max: number = 1;
  @Prop step: number = 1;
  @Prop topRadius: number = SettingsMetrics.groupInnerRadius;
  @Prop bottomRadius: number = SettingsMetrics.groupInnerRadius;
  /** 滑杆宽度（参照实现里滑杆在行内右侧）。 */
  sliderWidth: number = 140;
  onChange: (value: number) => void = () => {
  };

  build() {
    Column() {
      Row() {
        Column() {
          Text(this.title)
            .fontSize(16)
            .lineHeight(24)
            .fontColor(AppColor.onSurface)
            .width('100%')
          if (this.description.length > 0) {
            Text(this.description)
              .fontSize(12)
              .lineHeight(17)
              .fontColor(AppColor.onSurfaceVariant)
              .width('100%')
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .constraintSize({ minHeight: SettingsMetrics.rowMinHeight })

        Text(this.valueText)
          .fontSize(14)
          .fontColor(AppColor.onSurfaceVariant)
          .margin({ left: 12 })
      }
      .width('100%')

      // HarmonyOS 风格滑杆（§38.14 的 `_HarmonySliderPainter`）：
      // 高 40 的自绘控件，拖动中轨道 6→8、滑块 10→12。
      HarmonySlider({
        value: this.value,
        min: this.min,
        max: this.max,
        divisions: this.step > 0 ? Math.round((this.max - this.min) / this.step) : 0,
        onChanged: (value: number) => {
          this.onChange(value);
        }
      })
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .padding({
      left: SettingsMetrics.rowSidePadding,
      right: SettingsMetrics.rowSidePadding,
      top: SettingsMetrics.rowVerticalPadding,
      bottom: SettingsMetrics.rowVerticalPadding
    })
    .borderRadius({
      topLeft: this.topRadius,
      topRight: this.topRadius,
      bottomLeft: this.bottomRadius,
      bottomRight: this.bottomRadius
    })
    .backgroundColor(AppColor.surfaceContainerLow)
  }
}

/**
 * 选择行的**外观**（右值 + 下拉箭头），自身只负责把点击转成 `onTap`。
 *
 * 两种用法：
 *   1. **进入二级页**（硬件解码器 / 视频渲染器 / 超分辨率）：`onTap` 里 `RouteTable.push`；
 *   2. **就地选值**：用下面的 `SettingsMenuRow` 包一层——它把本组件放进内置
 *      `Column` 再挂 `bindMenu`，于是点击弹出 HarmonyOS 原生菜单。
 *      不要把 `bindMenu` 直接挂在本组件上：挂在自定义组件上不生效（实测）。
 */
@Component
export struct SettingsChoiceRow {
  @Prop themeRev: number = 0;
  @Prop title: string = '';
  @Prop description: string = '';
  /** 当前选项的显示文案。 */
  @Prop valueText: string = '';
  @Prop topRadius: number = SettingsMetrics.groupInnerRadius;
  @Prop bottomRadius: number = SettingsMetrics.groupInnerRadius;
  onTap: () => void = () => {
  };

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(16)
          .lineHeight(24)
          .fontColor(AppColor.onSurface)
          .width('100%')
        if (this.description.length > 0) {
          Text(this.description)
            .fontSize(12)
            .lineHeight(17)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .constraintSize({ minHeight: SettingsMetrics.rowMinHeight })

      Text(this.valueText)
        .fontSize(14)
        .fontColor(AppColor.onSurfaceVariant)
        .maxLines(1)
        .margin({ left: 12 })
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(16)
        .fontColor([AppColor.onSurfaceVariant])
        .margin({ left: 2 })
    }
    .width('100%')
    .padding({
      left: SettingsMetrics.rowSidePadding,
      right: SettingsMetrics.rowSidePadding,
      top: SettingsMetrics.rowVerticalPadding,
      bottom: SettingsMetrics.rowVerticalPadding
    })
    .borderRadius({
      topLeft: this.topRadius,
      topRight: this.topRadius,
      bottomLeft: this.bottomRadius,
      bottomRight: this.bottomRadius
    })
    .backgroundColor(AppColor.surfaceContainerLow)
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 数字输入行（点击弹出输入对话框，由页面提供）。 */
@Component
export struct SettingsNumberRow {
  @Prop themeRev: number = 0;
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop valueText: string = '';
  @Prop topRadius: number = SettingsMetrics.groupInnerRadius;
  @Prop bottomRadius: number = SettingsMetrics.groupInnerRadius;
  onTap: () => void = () => {
  };

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(16)
          .lineHeight(24)
          .fontColor(AppColor.onSurface)
          .width('100%')
        if (this.description.length > 0) {
          Text(this.description)
            .fontSize(12)
            .lineHeight(17)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .constraintSize({ minHeight: SettingsMetrics.rowMinHeight })

      Text(this.valueText)
        .fontSize(14)
        .fontColor(AppColor.onSurfaceVariant)
        .margin({ left: 12 })
    }
    .width('100%')
    .padding({
      left: SettingsMetrics.rowSidePadding,
      right: SettingsMetrics.rowSidePadding,
      top: SettingsMetrics.rowVerticalPadding,
      bottom: SettingsMetrics.rowVerticalPadding
    })
    .borderRadius({
      topLeft: this.topRadius,
      topRight: this.topRadius,
      bottomLeft: this.bottomRadius,
      bottomRight: this.bottomRadius
    })
    .backgroundColor(AppColor.surfaceContainerLow)
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 一个选择项。 */
export class SettingsOption {
  value: number = 0;
  label: string = '';

  constructor(value: number, label: string) {
    this.value = value;
    this.label = label;
  }
}

/**
 * 单选行（对应 `SettingsTile.radioTile`）。
 *
 * 左侧是选中态圆点：选中 `checkmark_circle_fill` + 主色，未选 `circle` + 次要色。
 */
@Component
export struct SettingsRadioRow {
  @Prop themeRev: number = 0;
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop selected: boolean = false;
  @Prop topRadius: number = SettingsMetrics.groupInnerRadius;
  @Prop bottomRadius: number = SettingsMetrics.groupInnerRadius;
  onTap: () => void = () => {
  };

  build() {
    Row() {
      SymbolGlyph(this.selected
        ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
        .fontSize(22)
        .fontColor([this.selected ? AppColor.primary : AppColor.onSurfaceVariant])
      Blank().width(16)
      Column() {
        Text(this.title)
          .fontSize(16)
          .lineHeight(24)
          .fontColor(AppColor.onSurface)
          .width('100%')
        if (this.description.length > 0) {
          Text(this.description)
            .fontSize(12)
            .lineHeight(17)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .constraintSize({ minHeight: SettingsMetrics.rowMinHeight })
    }
    .width('100%')
    .padding({
      left: SettingsMetrics.rowSidePadding,
      right: SettingsMetrics.rowSidePadding,
      top: SettingsMetrics.rowVerticalPadding,
      bottom: SettingsMetrics.rowVerticalPadding
    })
    .borderRadius({
      topLeft: this.topRadius,
      topRight: this.topRadius,
      bottomLeft: this.bottomRadius,
      bottomRight: this.bottomRadius
    })
    .backgroundColor(AppColor.surfaceContainerLow)
    .onClick(() => {
      this.onTap();
    })
  }
}

/**
 * 选择行（**HarmonyOS 原生菜单版**）。
 *
 * 取代旧写法「`SettingsChoiceRow` + 页面级 `SettingsChoiceOverlay` 遮罩浮层」：
 * 点行直接弹出 HarmonyOS 原生菜单（`Menu` + `MenuItem`），
 * 即播放页顶栏「收藏」菜单的同一套组件——毛玻璃底、圆角、投影、
 * 出现动画、点击外部关闭、按键与读屏语义都由系统给。
 *
 * 两条本工程实测出来的实现约束（踩过两次，别再踩）：
 *   1. `bindMenu` **必须挂在内置容器上**——挂在自定义组件
 *      （如 `SettingsChoiceRow`）上不生效，所以这里外面套一层 `Column`；
 *   2. `bindMenu` 所在节点**不能挂空 `onClick`**——点击会被空回调吃掉、
 *      菜单不弹，所以展开动作写在行自己的 `onTap` 里。
 */
@Component
export struct SettingsMenuRow {
  @Prop themeRev: number = 0;
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop valueText: string = '';
  @Prop current: number = 0;
  @Prop topRadius: number = SettingsMetrics.groupInnerRadius;
  @Prop bottomRadius: number = SettingsMetrics.groupInnerRadius;
  options: SettingsOption[] = [];
  onPick: (value: number) => void = () => {
  };
  @State private open: boolean = false;

  /** 菜单内容：标题做 `MenuItemGroup` 的 header，当前项打勾。 */
  @Builder
  menu() {
    Menu() {
      MenuItemGroup({ header: this.title }) {
        ForEach(this.options, (option: SettingsOption) => {
          if (option.value === this.current) {
            MenuItem({ content: option.label, endIcon: $r('sys.symbol.checkmark') })
              .onClick(() => {
                this.onPick(option.value);
              })
          } else {
            MenuItem({ content: option.label })
              .onClick(() => {
                this.onPick(option.value);
              })
          }
        }, (option: SettingsOption) => `settings-option-${option.value}`)
      }
    }
  }

  build() {
    Column() {
      SettingsChoiceRow({
        themeRev: this.themeRev,
        title: this.title,
        description: this.description,
        valueText: this.valueText,
        topRadius: this.topRadius,
        bottomRadius: this.bottomRadius,
        onTap: () => {
          this.open = true;
        }
      })
    }
    .width('100%')
    .bindMenu(this.open, this.menu, {
      onDisappear: () => {
        this.open = false;
      }
    })
  }
}
