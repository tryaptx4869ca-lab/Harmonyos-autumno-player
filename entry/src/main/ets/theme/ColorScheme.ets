import { DynamicScheme } from './color/DynamicScheme';
import { MaterialDynamicColors } from './color/MaterialDynamicColors';

/**
 * 角色值集合。字段与 AppColorScheme 一一对应。
 * 单独抽一个接口，是为了让「解析角色 → 构造对象」保持显式、
 * 可被编译器检查，而不是用动态属性名拼接。
 */
export interface SchemeValues {
  primary: number;
  onPrimary: number;
  primaryContainer: number;
  onPrimaryContainer: number;
  inversePrimary: number;
  primaryFixed: number;
  primaryFixedDim: number;
  onPrimaryFixed: number;
  onPrimaryFixedVariant: number;
  secondary: number;
  onSecondary: number;
  secondaryContainer: number;
  onSecondaryContainer: number;
  secondaryFixed: number;
  secondaryFixedDim: number;
  onSecondaryFixed: number;
  onSecondaryFixedVariant: number;
  tertiary: number;
  onTertiary: number;
  tertiaryContainer: number;
  onTertiaryContainer: number;
  tertiaryFixed: number;
  tertiaryFixedDim: number;
  onTertiaryFixed: number;
  onTertiaryFixedVariant: number;
  error: number;
  onError: number;
  errorContainer: number;
  onErrorContainer: number;
  surface: number;
  onSurface: number;
  surfaceDim: number;
  surfaceBright: number;
  surfaceContainerLowest: number;
  surfaceContainerLow: number;
  surfaceContainer: number;
  surfaceContainerHigh: number;
  surfaceContainerHighest: number;
  surfaceVariant: number;
  onSurfaceVariant: number;
  surfaceTint: number;
  inverseSurface: number;
  onInverseSurface: number;
  outline: number;
  outlineVariant: number;
  shadow: number;
  scrim: number;
  background: number;
  onBackground: number;
}

/**
 * 与 Flutter `ColorScheme` 对齐的角色容器。
 *
 * 角色名与 `ColorScheme.fromSeed` 的字段一一对应（含 M3 的 surface 阶梯
 * 与 fixed 系列），取值全部来自 MaterialDynamicColors 角色表，
 * 不做任何二次加工。数值是 ARGB 整数（0xAARRGGBB）。
 */
export class AppColorScheme {
  readonly isDark: boolean;

  // ---- primary ----
  readonly primary: number;
  readonly onPrimary: number;
  readonly primaryContainer: number;
  readonly onPrimaryContainer: number;
  readonly inversePrimary: number;
  readonly primaryFixed: number;
  readonly primaryFixedDim: number;
  readonly onPrimaryFixed: number;
  readonly onPrimaryFixedVariant: number;

  // ---- secondary ----
  readonly secondary: number;
  readonly onSecondary: number;
  readonly secondaryContainer: number;
  readonly onSecondaryContainer: number;
  readonly secondaryFixed: number;
  readonly secondaryFixedDim: number;
  readonly onSecondaryFixed: number;
  readonly onSecondaryFixedVariant: number;

  // ---- tertiary ----
  readonly tertiary: number;
  readonly onTertiary: number;
  readonly tertiaryContainer: number;
  readonly onTertiaryContainer: number;
  readonly tertiaryFixed: number;
  readonly tertiaryFixedDim: number;
  readonly onTertiaryFixed: number;
  readonly onTertiaryFixedVariant: number;

  // ---- error ----
  readonly error: number;
  readonly onError: number;
  readonly errorContainer: number;
  readonly onErrorContainer: number;

  // ---- surface ----
  readonly surface: number;
  readonly onSurface: number;
  readonly surfaceDim: number;
  readonly surfaceBright: number;
  readonly surfaceContainerLowest: number;
  readonly surfaceContainerLow: number;
  readonly surfaceContainer: number;
  readonly surfaceContainerHigh: number;
  readonly surfaceContainerHighest: number;
  readonly surfaceVariant: number;
  readonly onSurfaceVariant: number;
  readonly surfaceTint: number;

  // ---- 反色 / 其它 ----
  readonly inverseSurface: number;
  readonly onInverseSurface: number;
  readonly outline: number;
  readonly outlineVariant: number;
  readonly shadow: number;
  readonly scrim: number;
  readonly background: number;
  readonly onBackground: number;

  constructor(isDark: boolean, v: SchemeValues) {
    this.isDark = isDark;
    this.primary = v.primary;
    this.onPrimary = v.onPrimary;
    this.primaryContainer = v.primaryContainer;
    this.onPrimaryContainer = v.onPrimaryContainer;
    this.inversePrimary = v.inversePrimary;
    this.primaryFixed = v.primaryFixed;
    this.primaryFixedDim = v.primaryFixedDim;
    this.onPrimaryFixed = v.onPrimaryFixed;
    this.onPrimaryFixedVariant = v.onPrimaryFixedVariant;
    this.secondary = v.secondary;
    this.onSecondary = v.onSecondary;
    this.secondaryContainer = v.secondaryContainer;
    this.onSecondaryContainer = v.onSecondaryContainer;
    this.secondaryFixed = v.secondaryFixed;
    this.secondaryFixedDim = v.secondaryFixedDim;
    this.onSecondaryFixed = v.onSecondaryFixed;
    this.onSecondaryFixedVariant = v.onSecondaryFixedVariant;
    this.tertiary = v.tertiary;
    this.onTertiary = v.onTertiary;
    this.tertiaryContainer = v.tertiaryContainer;
    this.onTertiaryContainer = v.onTertiaryContainer;
    this.tertiaryFixed = v.tertiaryFixed;
    this.tertiaryFixedDim = v.tertiaryFixedDim;
    this.onTertiaryFixed = v.onTertiaryFixed;
    this.onTertiaryFixedVariant = v.onTertiaryFixedVariant;
    this.error = v.error;
    this.onError = v.onError;
    this.errorContainer = v.errorContainer;
    this.onErrorContainer = v.onErrorContainer;
    this.surface = v.surface;
    this.onSurface = v.onSurface;
    this.surfaceDim = v.surfaceDim;
    this.surfaceBright = v.surfaceBright;
    this.surfaceContainerLowest = v.surfaceContainerLowest;
    this.surfaceContainerLow = v.surfaceContainerLow;
    this.surfaceContainer = v.surfaceContainer;
    this.surfaceContainerHigh = v.surfaceContainerHigh;
    this.surfaceContainerHighest = v.surfaceContainerHighest;
    this.surfaceVariant = v.surfaceVariant;
    this.onSurfaceVariant = v.onSurfaceVariant;
    this.surfaceTint = v.surfaceTint;
    this.inverseSurface = v.inverseSurface;
    this.onInverseSurface = v.onInverseSurface;
    this.outline = v.outline;
    this.outlineVariant = v.outlineVariant;
    this.shadow = v.shadow;
    this.scrim = v.scrim;
    this.background = v.background;
    this.onBackground = v.onBackground;
  }

  /**
   * 由 DynamicScheme 解析出全部角色。
   * 等价于 Flutter `ColorScheme.fromSeed(seedColor:, brightness:)`。
   */
  static fromDynamicScheme(scheme: DynamicScheme, isDark: boolean): AppColorScheme {
    const values: SchemeValues = {
      primary: MaterialDynamicColors.primary.getArgb(scheme),
      onPrimary: MaterialDynamicColors.onPrimary.getArgb(scheme),
      primaryContainer: MaterialDynamicColors.primaryContainer.getArgb(scheme),
      onPrimaryContainer: MaterialDynamicColors.onPrimaryContainer.getArgb(scheme),
      inversePrimary: MaterialDynamicColors.inversePrimary.getArgb(scheme),
      primaryFixed: MaterialDynamicColors.primaryFixed.getArgb(scheme),
      primaryFixedDim: MaterialDynamicColors.primaryFixedDim.getArgb(scheme),
      onPrimaryFixed: MaterialDynamicColors.onPrimaryFixed.getArgb(scheme),
      onPrimaryFixedVariant: MaterialDynamicColors.onPrimaryFixedVariant.getArgb(scheme),
      secondary: MaterialDynamicColors.secondary.getArgb(scheme),
      onSecondary: MaterialDynamicColors.onSecondary.getArgb(scheme),
      secondaryContainer: MaterialDynamicColors.secondaryContainer.getArgb(scheme),
      onSecondaryContainer: MaterialDynamicColors.onSecondaryContainer.getArgb(scheme),
      secondaryFixed: MaterialDynamicColors.secondaryFixed.getArgb(scheme),
      secondaryFixedDim: MaterialDynamicColors.secondaryFixedDim.getArgb(scheme),
      onSecondaryFixed: MaterialDynamicColors.onSecondaryFixed.getArgb(scheme),
      onSecondaryFixedVariant: MaterialDynamicColors.onSecondaryFixedVariant.getArgb(scheme),
      tertiary: MaterialDynamicColors.tertiary.getArgb(scheme),
      onTertiary: MaterialDynamicColors.onTertiary.getArgb(scheme),
      tertiaryContainer: MaterialDynamicColors.tertiaryContainer.getArgb(scheme),
      onTertiaryContainer: MaterialDynamicColors.onTertiaryContainer.getArgb(scheme),
      tertiaryFixed: MaterialDynamicColors.tertiaryFixed.getArgb(scheme),
      tertiaryFixedDim: MaterialDynamicColors.tertiaryFixedDim.getArgb(scheme),
      onTertiaryFixed: MaterialDynamicColors.onTertiaryFixed.getArgb(scheme),
      onTertiaryFixedVariant: MaterialDynamicColors.onTertiaryFixedVariant.getArgb(scheme),
      error: MaterialDynamicColors.error.getArgb(scheme),
      onError: MaterialDynamicColors.onError.getArgb(scheme),
      errorContainer: MaterialDynamicColors.errorContainer.getArgb(scheme),
      onErrorContainer: MaterialDynamicColors.onErrorContainer.getArgb(scheme),
      surface: MaterialDynamicColors.surface.getArgb(scheme),
      onSurface: MaterialDynamicColors.onSurface.getArgb(scheme),
      surfaceDim: MaterialDynamicColors.surfaceDim.getArgb(scheme),
      surfaceBright: MaterialDynamicColors.surfaceBright.getArgb(scheme),
      surfaceContainerLowest: MaterialDynamicColors.surfaceContainerLowest.getArgb(scheme),
      surfaceContainerLow: MaterialDynamicColors.surfaceContainerLow.getArgb(scheme),
      surfaceContainer: MaterialDynamicColors.surfaceContainer.getArgb(scheme),
      surfaceContainerHigh: MaterialDynamicColors.surfaceContainerHigh.getArgb(scheme),
      surfaceContainerHighest: MaterialDynamicColors.surfaceContainerHighest.getArgb(scheme),
      surfaceVariant: MaterialDynamicColors.surfaceVariant.getArgb(scheme),
      onSurfaceVariant: MaterialDynamicColors.onSurfaceVariant.getArgb(scheme),
      surfaceTint: MaterialDynamicColors.surfaceTint.getArgb(scheme),
      inverseSurface: MaterialDynamicColors.inverseSurface.getArgb(scheme),
      onInverseSurface: MaterialDynamicColors.inverseOnSurface.getArgb(scheme),
      outline: MaterialDynamicColors.outline.getArgb(scheme),
      outlineVariant: MaterialDynamicColors.outlineVariant.getArgb(scheme),
      shadow: MaterialDynamicColors.shadow.getArgb(scheme),
      scrim: MaterialDynamicColors.scrim.getArgb(scheme),
      background: MaterialDynamicColors.background.getArgb(scheme),
      onBackground: MaterialDynamicColors.onBackground.getArgb(scheme)
    };
    return new AppColorScheme(isDark, values);
  }

  /** 取出全部角色值（用于复制）。 */
  toValues(): SchemeValues {
    return {
      primary: this.primary,
      onPrimary: this.onPrimary,
      primaryContainer: this.primaryContainer,
      onPrimaryContainer: this.onPrimaryContainer,
      inversePrimary: this.inversePrimary,
      primaryFixed: this.primaryFixed,
      primaryFixedDim: this.primaryFixedDim,
      onPrimaryFixed: this.onPrimaryFixed,
      onPrimaryFixedVariant: this.onPrimaryFixedVariant,
      secondary: this.secondary,
      onSecondary: this.onSecondary,
      secondaryContainer: this.secondaryContainer,
      onSecondaryContainer: this.onSecondaryContainer,
      secondaryFixed: this.secondaryFixed,
      secondaryFixedDim: this.secondaryFixedDim,
      onSecondaryFixed: this.onSecondaryFixed,
      onSecondaryFixedVariant: this.onSecondaryFixedVariant,
      tertiary: this.tertiary,
      onTertiary: this.onTertiary,
      tertiaryContainer: this.tertiaryContainer,
      onTertiaryContainer: this.onTertiaryContainer,
      tertiaryFixed: this.tertiaryFixed,
      tertiaryFixedDim: this.tertiaryFixedDim,
      onTertiaryFixed: this.onTertiaryFixed,
      onTertiaryFixedVariant: this.onTertiaryFixedVariant,
      error: this.error,
      onError: this.onError,
      errorContainer: this.errorContainer,
      onErrorContainer: this.onErrorContainer,
      surface: this.surface,
      onSurface: this.onSurface,
      surfaceDim: this.surfaceDim,
      surfaceBright: this.surfaceBright,
      surfaceContainerLowest: this.surfaceContainerLowest,
      surfaceContainerLow: this.surfaceContainerLow,
      surfaceContainer: this.surfaceContainer,
      surfaceContainerHigh: this.surfaceContainerHigh,
      surfaceContainerHighest: this.surfaceContainerHighest,
      surfaceVariant: this.surfaceVariant,
      onSurfaceVariant: this.onSurfaceVariant,
      surfaceTint: this.surfaceTint,
      inverseSurface: this.inverseSurface,
      onInverseSurface: this.onInverseSurface,
      outline: this.outline,
      outlineVariant: this.outlineVariant,
      shadow: this.shadow,
      scrim: this.scrim,
      background: this.background,
      onBackground: this.onBackground
    };
  }

  /**
   * OLED 优化：对应源码 `oledDarkTheme`——深色模式下改用纯黑背景，
   * onPrimary / onSecondary 转为黑色，onSurface 转为白色，其余角色不动。
   */
  toOledDark(): AppColorScheme {
    const v: SchemeValues = this.toValues();
    v.onPrimary = 0xFF000000;
    v.onSecondary = 0xFF000000;
    v.surface = 0xFF000000;
    v.onSurface = 0xFFFFFFFF;
    return new AppColorScheme(this.isDark, v);
  }
}

/** ARGB 整数 → `#AARRGGBB`。 */
export function argbToHex(argb: number): string {
  return '#' + (argb >>> 0).toString(16).toUpperCase().padStart(8, '0');
}

/** 丢弃 alpha，返回 `#RRGGBB`。 */
export function argbToRgbHex(argb: number): string {
  return '#' + ((argb >>> 0) & 0xFFFFFF).toString(16).toUpperCase().padStart(6, '0');
}

/** `#RRGGBB` / `#AARRGGBB` / `RRGGBB` → ARGB 整数。 */
export function hexToArgb(hex: string): number {
  let s: string = hex.trim();
  if (s.startsWith('#')) {
    s = s.substring(1);
  }
  if (s.length === 6) {
    return (0xFF000000 | parseInt(s, 16)) >>> 0;
  }
  if (s.length === 8) {
    return parseInt(s, 16) >>> 0;
  }
  return 0;
}
