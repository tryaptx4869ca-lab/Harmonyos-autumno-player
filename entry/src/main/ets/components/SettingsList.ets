import { AppColor } from '../theme/AppColors';
import { AppCurves, Motion } from '../theme/Tokens';
import { MotionRuntime } from '../theme/MotionRuntime';

/**
 * 设置列表组件。
 *
 * 对应源码 `lib/bean/widget/split_list_row.dart` + `content_section.dart`
 * + `lib/bean/settings/settings_list.dart`：
 *   - 分组由若干行组成，行间 4，首行上圆角 24、末行下圆角 24，中间行圆角 4
 *   - 行底色 surfaceContainerLow，内边距 水平 16 / 垂直 12，最小高度 32
 *   - 前置图标 24、与文字间距 16，图标色 onSurfaceVariant
 *   - 标题 bodyLarge（16/w400）onSurface；说明 bodySmall（12/w400）+2 间距
 *   - 右侧值文字 bodyMedium（14/w400）onSurfaceVariant，与内容间距 12
 *   - 分组标题 titleSmall（14/w600）primary，左右 16、下 8
 *   - 分组整体外边距 左右 16、下 16
 *
 * **2026-09-19 新增两项鸿蒙化的行内元素**（用户：「想更有鸿蒙感」，见 MinePage 注释）：
 *   - `iconTone`：把左侧裸符号换成**圆角方块图标容器**（`SettingsIconTone`，
 *     32 方块 / 圆角 10 / 符号 20），底色按类目取 `xxxContainer`、符号取 `onXxxContainer`；
 *   - `showChevron`：行尾 `chevron_right`，给「点了会进二级页」的行补可供性。
 *     两者都**默认关闭**，因此各二级设置页的观感与改动前完全一致，按需逐行打开。
 */
export class SettingsMetrics {
  static readonly groupOuterRadius: number = 24;
  static readonly groupInnerRadius: number = 4;
  /**
   * 按压时的圆角。对应 `split_list_row.dart:8` 的
   * `splitListOuterRadius = tonalCardRadius`——按下一整行收成圆角卡片。
   */
  static readonly pressedRadius: number = 24;
  static readonly rowGap: number = 4;
  static readonly sectionSidePadding: number = 16;
  static readonly rowSidePadding: number = 16;
  static readonly rowVerticalPadding: number = 12;
  static readonly rowMinHeight: number = 32;
  static readonly iconSize: number = 24;
  static readonly iconGap: number = 16;
  /**
   * 图标容器（鸿蒙式圆角方块）：方块 32、圆角 10（≈边长 1/3）、符号 20。
   * 参考系统设置 / 应用市场里「彩色圆角图标 + 白色符号」的做法（观察值 H3），
   * 具体数值是本项目的 House Style，不是官方规定值。
   */
  static readonly iconTileSize: number = 32;
  static readonly iconTileRadius: number = 10;
  static readonly iconTileGlyphSize: number = 20;
  /**
   * 用图标容器时图标与文字的间距。
   *
   * 容器比裸符号宽 8（32 vs 24），若仍用 16 会让整组文字右移 8；
   * 收到 12 后「方块左边 → 文字左边」共 44，与裸符号的 40 只差 4，
   * 两种行型混排时标题列不会明显错位。
   */
  static readonly iconTileGap: number = 12;
  /** 行尾箭头（`chevron_right`）尺寸与左间距。 */
  static readonly chevronSize: number = 16;
  static readonly chevronGap: number = 8;
}

/** 分组标题。 */
@Component
export struct SectionHeader {
  /** 主题版本：由父组件下发，@Prop 变化会让本组件整体重跑 build。 */
  @Prop themeRev: number = 0;
  title: string = '';

  build() {
    Row() {
      Text(this.title)
        .fontSize(14)
        .lineHeight(20)
        .fontWeight(600)
        .letterSpacing(0.2)
        .fontColor(AppColor.primary)
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 })
  }
}

/** 行类型。 */
export enum SettingsRowKind {
  /** 只读/可点击行。 */
  plain = 0,
  /** 带开关的行。 */
  toggle = 1,
  /**
   * 纯信息行（例如「关于」组里的 `版本号 1.0.1`）。
   *
   * 与 `plain` 的区别只在交互：`info` **不给按压反馈、也不可点**——
   * 一行点下去会缩、结果什么都不发生的观感比不给反馈更差
   * （参照实现夏绊的 `InfoRow` 同样是静态行）。
   */
  info = 2
}

/**
 * 图标容器的配色档（2026-09-19 新增）。
 *
 * 取值对应 Material / 鸿蒙同族的 `xxxContainer` 表面：
 * 底色 `xxxContainer` + 符号 `onXxxContainer`，因此深浅色主题与任意
 * 主题色种子下都能自动保持对比度——不要在调用处写死十六进制色值。
 *
 * 用法约定（MinePage 已按此分组）：**同一分组的行用同一档**，
 * 组与组之间换档；`none` 表示不画容器（各二级设置页的开关行/滑杆行保持裸符号，
 * 否则一屏十几个色块会盖过内容本身）。
 */
export enum SettingsIconTone {
  /** 不画容器，维持裸符号（默认）。 */
  none = 0,
  /** 主色容器（主题主色）。 */
  primary = 1,
  /** 次色容器。 */
  secondary = 2,
  /** 第三色容器（色相与主色错开）。 */
  tertiary = 3,
  /** 中性容器（`surfaceContainerHighest` + `onSurfaceVariant`），用于弱化「关于」这类行。 */
  neutral = 4
}

/** `SettingsIconTone` → 实际颜色的映射，集中在这里，避免调用处各写一套色值。 */
export class SettingsIconToneColors {
  static background(tone: SettingsIconTone): string {
    switch (tone) {
      case SettingsIconTone.primary:
        return AppColor.primaryContainer;
      case SettingsIconTone.secondary:
        return AppColor.secondaryContainer;
      case SettingsIconTone.tertiary:
        return AppColor.tertiaryContainer;
      default:
        return AppColor.surfaceContainerHighest;
    }
  }

  static foreground(tone: SettingsIconTone): string {
    switch (tone) {
      case SettingsIconTone.primary:
        return AppColor.onPrimaryContainer;
      case SettingsIconTone.secondary:
        return AppColor.onSecondaryContainer;
      case SettingsIconTone.tertiary:
        return AppColor.onTertiaryContainer;
      default:
        return AppColor.onSurfaceVariant;
    }
  }
}

/**
 * 一行设置项。
 *
 * `topRadius` / `bottomRadius` 由调用方按行在分组中的位置给出，
 * 与源码 SplitListRow 的传参方式一致。
 *
 * ⚠️ 所有会变化的数据都必须标 `@Prop`。ArkUI 的**普通成员只在初始化时赋值**，
 * 父组件后续重渲染不会同步——不加 `@Prop` 的后果是这一行既不更新文字、
 * 也不会重绘底色（实测踩到：「自定义背景」已设置却仍显示"未设置"，
 * 且该行底色停留在旧主题）。
 */
@Component
export struct SettingsRow {
  /** 主题版本：由父组件下发，@Prop 变化会让本组件整体重跑 build。 */
  @Prop themeRev: number = 0;
  @Prop
  title: string = '';
  @Prop
  description: string = '';
  @Prop
  valueText: string = '';
  icon: Resource | undefined = undefined;
  /**
   * 图标容器配色档（2026-09-19）。
   *
   * 默认 `none` = 裸符号，各二级设置页行为不变；`MinePage` 的一级入口行传
   * `primary / secondary / tertiary / neutral`，渲染成鸿蒙那套圆角方块图标。
   */
  @Prop
  iconTone: SettingsIconTone = SettingsIconTone.none;
  /**
   * 行尾箭头（2026-09-19）。**只给「点了会进二级页面」的行打开**：
   * 箭头是「会跳到别处」的承诺，弹菜单 / 弹对话框 / 就地执行（恢复默认设置）
   * 的行开了就是误导，所以这里不按 `kind` 自动推断，由调用方逐行显式给。
   */
  @Prop
  showChevron: boolean = false;
  @Prop
  kind: SettingsRowKind = SettingsRowKind.plain;
  @Prop
  checked: boolean = false;
  @Prop
  topRadius: number = SettingsMetrics.groupInnerRadius;
  @Prop
  bottomRadius: number = SettingsMetrics.groupInnerRadius;
  onTap: () => void = () => {
  };
  onToggle: (value: boolean) => void = () => {
  };
  /**
   * 按下态。对应 `split_list_row.dart:39-75` 的 AnimatedContainer：
   * 按下时圆角从「分组内位置对应的值」变成整卡圆角 24，
   * 250ms + `Curves.easeInOutCubicEmphasized`（规格 §38.2 的 `split_list_row`）。
   */
  @State private pressed: boolean = false;

  /** 是否可点（不可点的行——例如只有开关的行——不给按压反馈）。 */
  private clickable(): boolean {
    return this.kind === SettingsRowKind.plain;
  }

  private setPressed(value: boolean): void {
    if (!this.clickable()) {
      return;
    }
    this.pressed = value;
  }

  build() {
    Row() {
      if (this.icon !== undefined) {
        if (this.iconTone === SettingsIconTone.none) {
          // 裸符号：二级设置页（开关行 / 滑杆行）与改动前完全一致。
          SymbolGlyph(this.icon)
            .fontSize(SettingsMetrics.iconSize)
            .fontColor([AppColor.onSurfaceVariant])
          Blank().width(SettingsMetrics.iconGap)
        } else {
          // 鸿蒙式图标容器：圆角方块铺 `xxxContainer`，符号取 `onXxxContainer`。
          Column() {
            SymbolGlyph(this.icon)
              .fontSize(SettingsMetrics.iconTileGlyphSize)
              .fontColor([SettingsIconToneColors.foreground(this.iconTone)])
          }
          .width(SettingsMetrics.iconTileSize)
          .height(SettingsMetrics.iconTileSize)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .borderRadius(SettingsMetrics.iconTileRadius)
          .backgroundColor(SettingsIconToneColors.background(this.iconTone))
          Blank().width(SettingsMetrics.iconTileGap)
        }
      }

      Column() {
        Text(this.title)
          .fontSize(16)
          .lineHeight(24)
          .fontWeight(400)
          .letterSpacing(0.2)
          .fontColor(AppColor.onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.description.length > 0) {
          Text(this.description)
            .fontSize(12)
            .lineHeight(17)
            .letterSpacing(0.2)
            .fontColor(AppColor.onSurfaceVariant)
            .maxLines(2)
          .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // 源码是 `ConstrainedBox(minHeight: 32)` 包住「标题 + 说明」这一列，
      // 不是包整行——包错一层会让只有标题的行矮 8vp（已与 Flutter 版逐像素比对过）。
      .constraintSize({ minHeight: SettingsMetrics.rowMinHeight })

      if (this.valueText.length > 0) {
        Text(this.valueText)
          .fontSize(14)
          .lineHeight(21)
          .letterSpacing(0.2)
          .fontColor(AppColor.onSurfaceVariant)
          .maxLines(1)
          .margin({ left: 12 })
      }

      if (this.kind === SettingsRowKind.toggle) {
        Toggle({ type: ToggleType.Switch, isOn: this.checked })
          .selectedColor(AppColor.primary)
          .switchPointColor(AppColor.onPrimary)
          .margin({ left: 12 })
          .onChange((isOn: boolean) => {
            this.onToggle(isOn);
          })
      }

      // 行尾箭头：放在最后（有 valueText 的行是「值 → ›」的顺序，与系统设置一致）。
      if (this.showChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(SettingsMetrics.chevronSize)
          .fontColor([AppColor.onSurfaceVariant])
          .margin({ left: SettingsMetrics.chevronGap })
      }
    }
    .width('100%')
    .padding({
      left: SettingsMetrics.rowSidePadding,
      right: SettingsMetrics.rowSidePadding,
      top: SettingsMetrics.rowVerticalPadding,
      bottom: SettingsMetrics.rowVerticalPadding
    })
    .borderRadius({
      topLeft: this.pressed ? SettingsMetrics.pressedRadius : this.topRadius,
      topRight: this.pressed ? SettingsMetrics.pressedRadius : this.topRadius,
      bottomLeft: this.pressed ? SettingsMetrics.pressedRadius : this.bottomRadius,
      bottomRight: this.pressed ? SettingsMetrics.pressedRadius : this.bottomRadius
    })
    .backgroundColor(AppColor.surfaceContainerLow)
    .animation({
      duration: MotionRuntime.ms(Motion.normal),
      curve: AppCurves.easeInOutCubicEmphasized()
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.setPressed(true);
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.setPressed(false);
      }
    })
    .onClick(() => {
      if (this.clickable()) {
        this.onTap();
      }
    })
  }
}
