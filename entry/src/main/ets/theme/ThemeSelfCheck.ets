import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppColorScheme } from './ColorScheme';
import { ThemeEngine } from './ThemeEngine';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnTheme';

/**
 * 主题引擎自检。
 *
 * 用途：把本机算出的全部角色打出来，与本机用官方
 * `material-color-utilities`（Node）算出的期望值逐行比对。
 * 这是阶段 1 的验收手段之一——「设置页能切主题」只证明链路通，
 * 逐值一致才证明配色算得对。
 *
 * 比对脚本：`tools/verify-theme.mjs`（读本日志的期望值来源是同一个官方实现）。
 *
 * ⚠️ **默认关闭**：它会同步算完整套色板（明暗各 49 个角色），
 * 放在启动流程里会把主线程顶到 6 秒以上，实测触发
 * `THREAD_BLOCK_6S` 的 appfreeze（应用被系统杀掉）。
 * 需要复验时再临时置 true，验完立刻关。
 */
export class ThemeSelfCheck {
  /** 是否在启动时输出自检日志。 */
  private static readonly enabled: boolean = false;

  /** 与官方实现比对用的角色顺序（浅色 / 深色各打一遍）。 */
  private static readonly roles: string[] = [
    'primary', 'onPrimary', 'primaryContainer', 'onPrimaryContainer',
    'inversePrimary', 'secondary', 'onSecondary', 'secondaryContainer',
    'onSecondaryContainer', 'tertiary', 'onTertiary', 'tertiaryContainer',
    'onTertiaryContainer', 'error', 'onError', 'errorContainer',
    'onErrorContainer', 'surface', 'onSurface', 'surfaceDim', 'surfaceBright',
    'surfaceContainerLowest', 'surfaceContainerLow', 'surfaceContainer',
    'surfaceContainerHigh', 'surfaceContainerHighest', 'surfaceVariant',
    'onSurfaceVariant', 'outline', 'outlineVariant', 'shadow', 'scrim',
    'inverseSurface', 'onInverseSurface', 'surfaceTint', 'primaryFixed',
    'primaryFixedDim', 'onPrimaryFixed', 'onPrimaryFixedVariant',
    'secondaryFixed', 'secondaryFixedDim', 'onSecondaryFixed',
    'onSecondaryFixedVariant', 'tertiaryFixed', 'tertiaryFixedDim',
    'onTertiaryFixed', 'onTertiaryFixedVariant', 'background', 'onBackground'
  ];

  static log(seedArgb: number): void {
    if (!ThemeSelfCheck.enabled) {
      return;
    }
    const hex: string = (seedArgb >>> 0).toString(16).toUpperCase().padStart(8, '0');
    ThemeSelfCheck.dumpLight(seedArgb, hex);
    ThemeSelfCheck.dumpDark(seedArgb, hex);
  }

  private static dumpLight(seedArgb: number, hex: string): void {
    const s: AppColorScheme = ThemeEngine.lightOf(seedArgb);
    hilog.info(DOMAIN, TAG, 'TSCHK %{public}s light', `#${hex}`);
    ThemeSelfCheck.dump(ThemeSelfCheck.values(s));
  }

  private static dumpDark(seedArgb: number, hex: string): void {
    const s: AppColorScheme = ThemeEngine.darkOf(seedArgb);
    hilog.info(DOMAIN, TAG, 'TSCHK %{public}s dark', `#${hex}`);
    ThemeSelfCheck.dump(ThemeSelfCheck.values(s));
  }

  private static dump(values: number[]): void {
    for (let i = 0; i < ThemeSelfCheck.roles.length; i++) {
      hilog.info(DOMAIN, TAG, 'TSCHK   %{public}s = %{public}s',
        ThemeSelfCheck.roles[i], ThemeSelfCheck.hex(values[i]));
    }
  }

  private static hex(argb: number): string {
    return '#' + (argb >>> 0).toString(16).toUpperCase().padStart(8, '0');
  }

  private static values(s: AppColorScheme): number[] {
    return [
      s.primary, s.onPrimary, s.primaryContainer, s.onPrimaryContainer,
      s.inversePrimary, s.secondary, s.onSecondary, s.secondaryContainer,
      s.onSecondaryContainer, s.tertiary, s.onTertiary, s.tertiaryContainer,
      s.onTertiaryContainer, s.error, s.onError, s.errorContainer,
      s.onErrorContainer, s.surface, s.onSurface, s.surfaceDim, s.surfaceBright,
      s.surfaceContainerLowest, s.surfaceContainerLow, s.surfaceContainer,
      s.surfaceContainerHigh, s.surfaceContainerHighest, s.surfaceVariant,
      s.onSurfaceVariant, s.outline, s.outlineVariant, s.shadow, s.scrim,
      s.inverseSurface, s.onInverseSurface, s.surfaceTint, s.primaryFixed,
      s.primaryFixedDim, s.onPrimaryFixed, s.onPrimaryFixedVariant,
      s.secondaryFixed, s.secondaryFixedDim, s.onSecondaryFixed,
      s.onSecondaryFixedVariant, s.tertiaryFixed, s.tertiaryFixedDim,
      s.onTertiaryFixed, s.onTertiaryFixedVariant, s.background, s.onBackground
    ];
  }
}
