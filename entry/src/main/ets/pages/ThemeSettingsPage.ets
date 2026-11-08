import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppColor } from '../theme/AppColors';
import { PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { ImmersiveMetrics, ImmersivePageScaffold } from '../components/ImmersivePageScaffold';
import { SectionHeader, SettingsMetrics, SettingsRow, SettingsRowKind } from '../components/SettingsList';
import { PaletteCard } from '../components/PaletteCard';
import { BackgroundLevels, ThemeManager, ThemeModeValue } from '../theme/ThemeManager';
import { ThemeEngine, ThemePreset } from '../theme/ThemeEngine';
import { BackgroundService, BackgroundApplyResult } from '../services/BackgroundService';

/**
 * 外观设置。
 * 对应源码 `lib/pages/settings/theme_settings_page.dart`。
 *
 * 已对齐的部分：
 *   深色模式（跟随系统 / 浅色 / 深色，下拉菜单，选中项用主色）
 *   配色方案（9 个预设，重置走 `resetTheme` 语义）
 *   OLED 优化（深色模式纯黑背景，开关带说明）
 *   分组与行样式（SplitListGroup 的圆角 / 间距 / 内边距逐值一致）
 *
 * 尚未接入：自定义背景（相册选择 + 背景取色 + 分级模糊），
 * 详见本文件 `backgroundDialog` 的说明。
 */
@Component
export struct ThemeSettingsPage {
  @StorageProp('themeRevision') themeRevision: number = 0;
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('bottomInset') bottomInset: number = 28;
  /** 深色模式下拉菜单是否展开（源码里的 MenuController.open/close）。 */
  @State private modeMenuOpen: boolean = false;

  /** 二级页转场（规格 §12.4）。 */
  pageTransition() {
    PageTransitionEnter({
      type: RouteType.Push,
      duration: RouteTable.duration(),
      curve: PageTransitionSpec.enterCurve()
    })
      .opacity(0)
      .translate({ y: RouteTable.slideOffset() })
    PageTransitionExit({
      type: RouteType.Pop,
      duration: RouteTable.duration(),
      curve: PageTransitionSpec.exitCurve()
    })
      .opacity(0)
      // 退出：与参照实现同一条 Fade + Slide（`Offset(0, 0.02)`）——下滑 2% 的同时淡出
      .translate({ y: RouteTable.slideOffset() })
  }

  private paletteDialog: CustomDialogController = new CustomDialogController({
    builder: PaletteDialog(),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    backgroundColor: AppColor.surfaceContainerHigh,
    cornerRadius: 24
  });

  private backgroundDialog: CustomDialogController = new CustomDialogController({
    builder: BackgroundDialog({
      onPick: () => {
        this.pickBackground();
      },
      onClear: () => {
        this.clearBackground();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    backgroundColor: AppColor.surfaceContainerHigh,
    cornerRadius: 24
  });

  private intensityDialog: CustomDialogController = new CustomDialogController({
    builder: IntensityDialog(),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    backgroundColor: AppColor.surfaceContainerHigh,
    cornerRadius: 24
  });

  build() {
    Column() {
      // 主题一切换就用 ForEach 的 key 变化整体重建本页。
      // 原因同 Index：ArkUI V1 按属性更新，`AppColor.*` 不会被追踪，
      // 不重建的话，已经建好的设置行会停在旧配色（实测踩过）。
      ForEach([this.themeRevision], (revision: number) => {
        ImmersivePageScaffold({
          themeRev: this.themeRevision,
          title: '外观设置',
          onBack: () => {
            RouteTable.back();
          }
        }) {
          List() {
            ListItem() {
              this.appearanceSection()
            }
            ListItem() {
              this.displaySection()
            }
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          // 与源码 SettingsList 的 padding 一致：
          //   上 = topInset + 8（topInset 已含 topOffset 66）
          //   下 = 24 + 系统底部安全区
          // TODO(平板适配): 源码还有 Center + ConstrainedBox(maxWidth 1000)，
          //   等进入平板适配阶段再加。
          .padding({
            top: ImmersiveMetrics.contentTop(this.topInset),
            bottom: ImmersiveMetrics.listBottomPadding + this.bottomInset,
            left: 16,
            right: 16
          })
        }
      }, (revision: number) => `settings-${revision}`)
    }
    .width('100%')
    .height('100%')
  }

  /** 深色模式当前值文案（源码 `_ThemeSettingsPageState.build` 的 value）。 */
  private themeModeLabel(): string {
    // 先读一次版本号：ArkUI 只会重绘「build 过程中真正读到的状态」，
    // 不读这一下，主题变化后本页文案与配色都不会刷新（已实测踩过）。
    const revision: number = this.themeRevision;
    if (revision < 0) {
      return '';
    }
    const mode: string = ThemeManager.instance().themeModeValue;
    if (mode === ThemeModeValue.light) {
      return '浅色';
    }
    if (mode === ThemeModeValue.dark) {
      return '深色';
    }
    return '跟随系统';
  }

  /** 自定义背景当前值文案，同时建立对主题版本的依赖。 */
  private backgroundLabel(): string {
    const revision: number = this.themeRevision;
    if (revision < 0) {
      return '';
    }
    return ThemeManager.instance().hasCustomBackground ? '已设置' : '未设置';
  }

  /** 是否已设置背景（影响「背景强度」行是否出现）。 */
  private hasBackground(): boolean {
    const revision: number = this.themeRevision;
    if (revision < 0) {
      return false;
    }
    return ThemeManager.instance().hasCustomBackground;
  }

  /** 背景强度文案。 */
  private intensityLabel(): string {
    const revision: number = this.themeRevision;
    if (revision < 0) {
      return '';
    }
    return BackgroundLevels.label(ThemeManager.instance().backgroundIntensity);
  }

  /** OLED 开关状态。 */
  private oledChecked(): boolean {
    const revision: number = this.themeRevision;
    if (revision < 0) {
      return false;
    }
    return ThemeManager.instance().oled;
  }

  /** 相册选图 → 拷贝 → 取色 → 落盘 → 刷新主题（源码 `_pickCustomBackground`）。 */
  private async pickBackground(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const result: BackgroundApplyResult = await BackgroundService.pickAndApply(context);
    if (!result.ok) {
      this.showToast(result.message);
      return;
    }
    const seedHex: string = (result.seedArgb >>> 0).toString(16).toUpperCase().padStart(6, '0');
    this.showToast(result.seedArgb === 0
      ? '已设置背景（未能取色，继续使用主题色）'
      : `已设置背景 · 取色 #${seedHex}`);
  }

  private async clearBackground(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    await BackgroundService.clear(context);
  }

  private showToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  @Builder
  appearanceSection() {
    Column() {
      SectionHeader({ title: '外观', themeRev: this.themeRevision })

      // 源码把整行包在 MenuAnchor 里（点行任意位置都能展开菜单），
      // ArkUI 侧对应「内置容器 + bindMenu」——bindMenu 挂在自定义组件上不生效。
      Column() {
        SettingsRow({
          themeRev: this.themeRevision,
          title: '深色模式',
          valueText: this.themeModeLabel(),
          icon: $r('sys.symbol.moon'),
          topRadius: SettingsMetrics.groupOuterRadius,
          bottomRadius: SettingsMetrics.groupInnerRadius,
          // 行的内层 Row 自己会消费点击，所以展开动作必须挂在行上；
          // 菜单本身仍然绑在外层容器（bindMenu 挂在自定义组件上不生效）。
          onTap: () => {
            this.modeMenuOpen = true;
          }
        })
      }
      .width('100%')
      .bindMenu(this.modeMenuOpen, this.modeMenu, {
        /**
         * 对齐「深色模式」这一行（用户 2026-10-09 反馈：平板上这个选择菜单
         * 弹出来的位置没对齐）。不指定 placement 时用的是框架默认方向，
         * 平板上会和行错开；这里显式锚到行的**右下**——菜单顶边贴着行底、
         * 右边和行右缘对齐。
         */
        placement: Placement.BottomRight,
        onDisappear: () => {
          this.modeMenuOpen = false;
        }
      })

      Blank().height(SettingsMetrics.rowGap)

      SettingsRow({
        themeRev: this.themeRevision,
        title: '配色方案',
        icon: $r('sys.symbol.paintpalette'),
        topRadius: SettingsMetrics.groupInnerRadius,
        bottomRadius: SettingsMetrics.groupInnerRadius,
        onTap: () => {
          this.paletteDialog.open();
        }
      })

      Blank().height(SettingsMetrics.rowGap)

      SettingsRow({
        themeRev: this.themeRevision,
        title: '自定义背景',
        valueText: this.backgroundLabel(),
        icon: $r('sys.symbol.picture'),
        topRadius: SettingsMetrics.groupInnerRadius,
        bottomRadius: this.hasBackground()
          ? SettingsMetrics.groupInnerRadius : SettingsMetrics.groupOuterRadius,
        onTap: () => {
          this.backgroundDialog.open();
        }
      })

      if (this.hasBackground()) {
        Blank().height(SettingsMetrics.rowGap)
        SettingsRow({
          themeRev: this.themeRevision,
          title: '背景强度',
          valueText: this.intensityLabel(),
          icon: $r('sys.symbol.color_fill'),
          topRadius: SettingsMetrics.groupInnerRadius,
          bottomRadius: SettingsMetrics.groupOuterRadius,
          onTap: () => {
            this.intensityDialog.open();
          }
        })
      }
    }
    .width('100%')
    .padding({ bottom: 16 })
  }

  @Builder
  displaySection() {
    Column() {
      SectionHeader({ title: '显示', themeRev: this.themeRevision })

      SettingsRow({
        themeRev: this.themeRevision,
        title: 'OLED优化',
        description: '深色模式下使用纯黑背景',
        icon: $r('sys.symbol.contrast'),
        kind: SettingsRowKind.toggle,
        checked: this.oledChecked(),
        topRadius: SettingsMetrics.groupOuterRadius,
        bottomRadius: SettingsMetrics.groupOuterRadius,
        onToggle: (value: boolean) => {
          ThemeManager.instance().setOledEnhance(value);
        }
      })
    }
    .width('100%')
    .padding({ bottom: 16 })
  }

  /**
   * 深色模式下拉菜单。
   *
   * 源码是 `MenuAnchor` + 3 个 `MenuItemButton`：每项高 48、最小宽 112、
   * 图标与文字间距 8，选中项图标与文字都用主色。
   * ArkUI 的 `MenuItem` 只能控制「是否选中」，无法逐项改色，
   * 因此这里用自定义 Menu 内容逐行复刻同样的排版与配色。
   */
  @Builder
  modeMenu() {
    Column() {
      this.modeMenuItem('跟随系统', ThemeModeValue.system, $r('sys.symbol.brightness'))
      this.modeMenuItem('浅色', ThemeModeValue.light, $r('sys.symbol.sun_max'))
      this.modeMenuItem('深色', ThemeModeValue.dark, $r('sys.symbol.moon'))
    }
    .width(180)
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  modeMenuItem(label: string, mode: string, icon: Resource) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([ThemeManager.instance().themeModeValue === mode
          ? AppColor.primary : AppColor.onSurfaceVariant])
      Text(label)
        .fontSize(16)
        .lineHeight(22)
        .fontColor(ThemeManager.instance().themeModeValue === mode
          ? AppColor.primary : AppColor.onSurface)
        .margin({ left: 8 })
    }
    .height(48)
    .constraintSize({ minWidth: 112 })
    .padding({ left: 12, right: 12 })
    .onClick(() => {
      ThemeManager.instance().setThemeMode(mode);
    })
  }
}

/**
 * 配色方案弹窗。
 * 源码：AlertDialog(title: '配色方案') 内放 Wrap(spacing 8)，
 * 每项为 PaletteCard + 文案，点非默认项走 `setTheme`、默认项走 `resetTheme`。
 */
@CustomDialog
struct PaletteDialog {
  controller: CustomDialogController = new CustomDialogController({ builder: PaletteDialog() });

  build() {
    Column() {
      Text('配色方案')
        .fontSize(18)
        .fontWeight(600)
        .fontColor(AppColor.onSurface)
        .margin({ bottom: 16 })

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(ThemeEngine.presets, (preset: ThemePreset) => {
          Column() {
            PaletteCard({
              colorArgb: preset.argb,
              selected: ThemeManager.instance().themeColor === preset.storageValue,
              onPick: () => {
                ThemeManager.instance().setThemePreset(preset);
                this.controller.close();
              }
            })
            Text(preset.label)
              .fontSize(12)
              .fontColor(AppColor.onSurfaceVariant)
              .margin({ top: 4 })
          }
          .width(88)
          .alignItems(HorizontalAlign.Center)
        }, (preset: ThemePreset) => preset.storageValue)
      }
      .width('100%')
    }
    .width(320)
    .padding(24)
  }
}

/**
 * 自定义背景弹窗。
 *
 * 源码支持「从相册选择 / 清除背景」。
 * 相册选择与背景取色（含 EXIF 方向烘焙、24 宽 nearest 缩放、亮度过滤取均值）
 * 的算法已在 `theme/ThemeEngine.ets: BackgroundSeedExtractor` 里 1:1 实现，
 * 缺的是鸿蒙侧的图片解码 + 相册选图接线，留到下一批完成。
 */
@CustomDialog
struct BackgroundDialog {
  controller: CustomDialogController = new CustomDialogController({ builder: BackgroundDialog() });
  /** 选图（由页面负责调用相册与取色）。 */
  onPick: () => void = () => {
  };
  /** 清除背景。 */
  onClear: () => void = () => {
  };

  build() {
    Column() {
      Text('自定义背景')
        .fontSize(18)
        .fontWeight(600)
        .fontColor(AppColor.onSurface)
        .margin({ bottom: 8 })

      Row() {
        SymbolGlyph($r('sys.symbol.picture'))
          .fontSize(24)
          .fontColor([AppColor.onSurfaceVariant])
        Text('从相册选择')
          .fontSize(16)
          .fontColor(AppColor.onSurface)
          .margin({ left: 16 })
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .onClick(() => {
        this.controller.close();
        this.onPick();
      })

      if (ThemeManager.instance().hasCustomBackground) {
        Row() {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(24)
            .fontColor([AppColor.error])
          Text('清除背景')
            .fontSize(16)
            .fontColor(AppColor.error)
            .margin({ left: 16 })
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.controller.close();
          this.onClear();
        })
      }

      Row() {
        Text('取消')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(AppColor.primary)
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ top: 12 })
      .onClick(() => {
        this.controller.close();
      })
    }
    .width(320)
    .padding(24)
  }
}

/** 背景强度弹窗（源码 SimpleDialog + 4 个档位）。 */
@CustomDialog
struct IntensityDialog {
  controller: CustomDialogController = new CustomDialogController({ builder: IntensityDialog() });

  build() {
    Column() {
      Text('背景强度')
        .fontSize(18)
        .fontWeight(600)
        .fontColor(AppColor.onSurface)
        .margin({ bottom: 8 })

      ForEach(BackgroundLevels.levels, (level: number) => {
        Row() {
          Text(BackgroundLevels.levelName(level))
            .fontSize(16)
            .fontColor(AppColor.onSurface)
          Blank()
          if (BackgroundLevels.snap(ThemeManager.instance().backgroundIntensity) === level) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(20)
              .fontColor([AppColor.onSurfaceVariant])
          }
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          ThemeManager.instance().setBackgroundIntensity(level);
          this.controller.close();
        })
      }, (level: number) => `${level}`)
    }
    .width(320)
    .padding(24)
  }
}
