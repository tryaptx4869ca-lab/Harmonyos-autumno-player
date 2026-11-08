import { CustomColors, CustomTheme, ThemeControl } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppColor } from './AppColors';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnArkUI';

/**
 * 是否把本应用的主题色注入 ArkUI 系统组件。
 *
 * **2026-09-17 决策：关闭**（用户选择「统一到系统的灰白」）。
 *
 * 背景：注入一开后，**系统绘制**的弹窗（`Menu` + `MenuItem` 那类菜单、开关、
 * 滑块）会明显偏品牌色（琥珀）；而**自绘**的弹层与对话框用的是 M3 的
 * `surfaceContainer*`——那是「近白 + 极淡主题色调」的中性色，看起来是灰白。
 * 结果就是「一半琥珀、一半灰白」，怎么调都难对齐。
 *
 * 选择统一到灰白之后：系统菜单回到系统默认观感，与自绘弹层基本一致。
 * 副作用：菜单里的勾选 / 强调色也会回到**系统蓝**，不再是本应用的琥珀——
 * 这是这套方案的一部分，不是漏配。
 *
 * 想切回「弹窗跟随主题」：把这里改成 `true` 即可（其余代码都还在）。
 */
const ENABLED: boolean = false;

/**
 * 把本应用的主题色注入 **ArkUI 系统组件**。
 *
 * 背景（用户 2026-09-17 提问「弹窗的颜色能改吗？我们主题色是定了的」）：
 * 原生菜单、对话框、半模态弹层、开关、滑块、`LoadingProgress` 这些是**系统绘制**的，
 * 它们不读 `AppColor`，而是读 ArkUI 的全局主题。默认跟随系统，
 * 所以我们的琥珀金主题里弹出来的是系统蓝。
 *
 * 官方入口是 `ThemeControl.setDefaultTheme(theme)`（`@ohos.arkui.theme`，API 12+），
 * `CustomColors` 一共 51 个令牌。这里全部按当前配方算出来——
 * **不能只填 `brand`**：那些 `compEmphasizeSecondary`(品牌 20%)、
 * `compEmphasizeTertiary`(品牌 10%)、`interactivePressed` 之类的派生档
 * 如果留系统默认，就会出现「按钮是主题色、按下态却是系统蓝」这种不协调。
 *
 * 调用时机：`EntryAbility.onCreate`（首帧之前）+ `ThemeManager.recompute()`
 * （换预设 / 换明暗 / 跟随壁纸都要重算）。
 */
export class ArkUITheme {
  /** 按当前方案生成并注入 ArkUI 主题。 */
  static apply(): void {
    if (!ENABLED) {
      return;
    }
    try {
      ThemeControl.setDefaultTheme(ArkUITheme.build());
    } catch (error) {
      // 主题注入失败不该影响启动：忽略即可，界面回落到系统默认配色
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '注入 ArkUI 主题失败: %{public}s', err.message);
    }
  }

  private static build(): CustomTheme {
    const colors: CustomColors = {
      // ---- 品牌与语义色 ----
      brand: AppColor.primary,
      warning: AppColor.error,
      alert: AppColor.error,
      confirm: AppColor.primary,

      // ---- 文字 ----
      fontPrimary: AppColor.onSurface,
      fontSecondary: AppColor.onSurfaceVariant,
      fontTertiary: AppColor.onSurfaceVariant,
      fontFourth: AppColor.outline,
      fontEmphasize: AppColor.primary,
      fontOnPrimary: AppColor.onPrimary,
      fontOnSecondary: AppColor.onSecondaryContainer,
      fontOnTertiary: AppColor.onSecondaryContainer,
      fontOnFourth: AppColor.onSurfaceVariant,

      // ---- 图标 ----
      iconPrimary: AppColor.onSurface,
      iconSecondary: AppColor.onSurfaceVariant,
      iconTertiary: AppColor.onSurfaceVariant,
      iconFourth: AppColor.outline,
      iconEmphasize: AppColor.primary,
      iconSubEmphasize: AppColor.primary,
      iconOnPrimary: AppColor.onPrimary,
      iconOnSecondary: AppColor.onSecondaryContainer,
      iconOnTertiary: AppColor.onSecondaryContainer,
      iconOnFourth: AppColor.onSurfaceVariant,

      // ---- 页面底色 ----
      backgroundPrimary: AppColor.surface,
      backgroundSecondary: AppColor.surfaceContainerLow,
      backgroundTertiary: AppColor.surfaceContainer,
      backgroundFourth: AppColor.surfaceContainerHigh,
      backgroundEmphasize: AppColor.primaryContainer,

      // ---- 组件（菜单 / 对话框 / 弹层的底与前景） ----
      compForegroundPrimary: AppColor.onSurface,
      compBackgroundPrimary: AppColor.surfaceContainerLow,
      compBackgroundPrimaryTran: AppColor.withAlpha(AppColor.surfaceContainer, 0.70),
      compBackgroundPrimaryContrary: AppColor.onSurface,
      compBackgroundGray: AppColor.surfaceContainerHigh,
      compBackgroundSecondary: AppColor.surfaceContainer,
      compBackgroundTertiary: AppColor.surfaceContainerHighest,
      compBackgroundEmphasize: AppColor.primary,
      compBackgroundNeutral: AppColor.surfaceContainerHigh,
      compEmphasizeSecondary: AppColor.withAlpha(AppColor.primary, 0.20),
      compEmphasizeTertiary: AppColor.withAlpha(AppColor.primary, 0.10),
      compDivider: AppColor.outlineVariant,
      compCommonContrary: AppColor.onSurface,
      compBackgroundFocus: AppColor.surfaceContainerHigh,
      compFocusedPrimary: AppColor.primary,
      compFocusedSecondary: AppColor.onSurfaceVariant,
      compFocusedTertiary: AppColor.outline,

      // ---- 交互态（按下 / 悬停 / 焦点 / 选中） ----
      interactiveHover: AppColor.withAlpha(AppColor.onSurface, 0.08),
      interactivePressed: AppColor.withAlpha(AppColor.onSurface, 0.10),
      interactiveFocus: AppColor.withAlpha(AppColor.onSurface, 0.12),
      interactiveActive: AppColor.withAlpha(AppColor.primary, 0.12),
      interactiveSelect: AppColor.withAlpha(AppColor.primary, 0.20),
      interactiveClick: AppColor.withAlpha(AppColor.onSurface, 0.10)
    };
    const theme: CustomTheme = { colors: colors };
    return theme;
  }
}
