import { ContrastCurve, DynamicColor, isFidelity, isMonochrome, ToneDeltaPair, TonePolarity } from './DynamicColor';
import { DynamicScheme } from './DynamicScheme';
import { Hct } from './Hct';
import { TonalPalette } from './TonalPalette';

/**
 * Material Design 的角色表：把 DynamicScheme 解析成命名颜色。
 * 逐行移植自 material_color_utilities/lib/dynamiccolor/material_dynamic_colors.dart 0.13.0。
 *
 * 上游用 Dart 的可选命名参数 + 函数取值的写法，这里等价地展开为
 * 「对象字面量 + 箭头函数」。数值与判定顺序均与上游一一对应，
 * 不做任何化简——这样后续与官方实现逐值比对时才能定位到具体角色。
 */
export class MaterialDynamicColors {
  static readonly contentAccentToneDelta: number = 15.0;

  /** 该方案下最高的表面色（深色取 surfaceBright，浅色取 surfaceDim）。 */
  static highestSurface(s: DynamicScheme): DynamicColor {
    return s.isDark ? MaterialDynamicColors.surfaceBright : MaterialDynamicColors.surfaceDim;
  }

  static readonly primaryPaletteKeyColor: DynamicColor = DynamicColor.fromPalette({
    name: 'primary_palette_key_color',
    palette: (s: DynamicScheme): TonalPalette => s.primaryPalette,
    tone: (s: DynamicScheme): number => s.primaryPalette.keyColor().tone
  });

  static readonly secondaryPaletteKeyColor: DynamicColor = DynamicColor.fromPalette({
    name: 'secondary_palette_key_color',
    palette: (s: DynamicScheme): TonalPalette => s.secondaryPalette,
    tone: (s: DynamicScheme): number => s.secondaryPalette.keyColor().tone
  });

  static readonly tertiaryPaletteKeyColor: DynamicColor = DynamicColor.fromPalette({
    name: 'tertiary_palette_key_color',
    palette: (s: DynamicScheme): TonalPalette => s.tertiaryPalette,
    tone: (s: DynamicScheme): number => s.tertiaryPalette.keyColor().tone
  });

  static readonly neutralPaletteKeyColor: DynamicColor = DynamicColor.fromPalette({
    name: 'neutral_palette_key_color',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number => s.neutralPalette.keyColor().tone
  });

  static readonly neutralVariantPaletteKeyColor: DynamicColor = DynamicColor.fromPalette({
    name: 'neutral_variant_palette_key_color',
    palette: (s: DynamicScheme): TonalPalette => s.neutralVariantPalette,
    tone: (s: DynamicScheme): number => s.neutralVariantPalette.keyColor().tone
  });

  static readonly background: DynamicColor = DynamicColor.fromPalette({
    name: 'background',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 6 : 98,
    isBackground: true
  });

  static readonly onBackground: DynamicColor = DynamicColor.fromPalette({
    name: 'on_background',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 90 : 10,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.background,
    contrastCurve: new ContrastCurve(3, 3, 4.5, 7)
  });

  static readonly surface: DynamicColor = DynamicColor.fromPalette({
    name: 'surface',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 6 : 98,
    isBackground: true
  });

  static readonly surfaceDim: DynamicColor = DynamicColor.fromPalette({
    name: 'surface_dim',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number =>
      s.isDark ? 6 : new ContrastCurve(87, 87, 80, 75).get(s.contrastLevel),
    isBackground: true
  });

  static readonly surfaceBright: DynamicColor = DynamicColor.fromPalette({
    name: 'surface_bright',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number =>
      s.isDark ? new ContrastCurve(24, 24, 29, 34).get(s.contrastLevel) : 98,
    isBackground: true
  });

  static readonly surfaceContainerLowest: DynamicColor = DynamicColor.fromPalette({
    name: 'surface_container_lowest',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number =>
      s.isDark ? new ContrastCurve(4, 4, 2, 0).get(s.contrastLevel) : 100,
    isBackground: true
  });

  static readonly surfaceContainerLow: DynamicColor = DynamicColor.fromPalette({
    name: 'surface_container_low',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number => s.isDark
      ? new ContrastCurve(10, 10, 11, 12).get(s.contrastLevel)
      : new ContrastCurve(96, 96, 96, 95).get(s.contrastLevel),
    isBackground: true
  });

  static readonly surfaceContainer: DynamicColor = DynamicColor.fromPalette({
    name: 'surface_container',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number => s.isDark
      ? new ContrastCurve(12, 12, 16, 20).get(s.contrastLevel)
      : new ContrastCurve(94, 94, 92, 90).get(s.contrastLevel),
    isBackground: true
  });

  static readonly surfaceContainerHigh: DynamicColor = DynamicColor.fromPalette({
    name: 'surface_container_high',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number => s.isDark
      ? new ContrastCurve(17, 17, 21, 25).get(s.contrastLevel)
      : new ContrastCurve(92, 92, 88, 85).get(s.contrastLevel),
    isBackground: true
  });

  static readonly surfaceContainerHighest: DynamicColor = DynamicColor.fromPalette({
    name: 'surface_container_highest',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number => s.isDark
      ? new ContrastCurve(22, 22, 26, 30).get(s.contrastLevel)
      : new ContrastCurve(90, 90, 84, 80).get(s.contrastLevel),
    isBackground: true
  });

  static readonly onSurface: DynamicColor = DynamicColor.fromPalette({
    name: 'on_surface',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 90 : 10,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21)
  });

  static readonly surfaceVariant: DynamicColor = DynamicColor.fromPalette({
    name: 'surface_variant',
    palette: (s: DynamicScheme): TonalPalette => s.neutralVariantPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 30 : 90,
    isBackground: true
  });

  static readonly onSurfaceVariant: DynamicColor = DynamicColor.fromPalette({
    name: 'on_surface_variant',
    palette: (s: DynamicScheme): TonalPalette => s.neutralVariantPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 80 : 30,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11)
  });

  static readonly inverseSurface: DynamicColor = DynamicColor.fromPalette({
    name: 'inverse_surface',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 90 : 20
  });

  static readonly inverseOnSurface: DynamicColor = DynamicColor.fromPalette({
    name: 'inverse_on_surface',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 20 : 95,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.inverseSurface,
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21)
  });

  static readonly outline: DynamicColor = DynamicColor.fromPalette({
    name: 'outline',
    palette: (s: DynamicScheme): TonalPalette => s.neutralVariantPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 60 : 50,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(1.5, 3, 4.5, 7)
  });

  static readonly outlineVariant: DynamicColor = DynamicColor.fromPalette({
    name: 'outline_variant',
    palette: (s: DynamicScheme): TonalPalette => s.neutralVariantPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 30 : 80,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5)
  });

  static readonly shadow: DynamicColor = DynamicColor.fromPalette({
    name: 'shadow',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number => 0
  });

  static readonly scrim: DynamicColor = DynamicColor.fromPalette({
    name: 'scrim',
    palette: (s: DynamicScheme): TonalPalette => s.neutralPalette,
    tone: (s: DynamicScheme): number => 0
  });

  static readonly surfaceTint: DynamicColor = DynamicColor.fromPalette({
    name: 'surface_tint',
    palette: (s: DynamicScheme): TonalPalette => s.primaryPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 80 : 40,
    isBackground: true
  });

  static readonly primary: DynamicColor = DynamicColor.fromPalette({
    name: 'primary',
    palette: (s: DynamicScheme): TonalPalette => s.primaryPalette,
    tone: (s: DynamicScheme): number => {
      if (isMonochrome(s)) {
        return s.isDark ? 100 : 0;
      }
      return s.isDark ? 80 : 40;
    },
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(3, 4.5, 7, 7),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.primaryContainer,
      MaterialDynamicColors.primary,
      10,
      TonePolarity.nearer,
      false
    )
  });

  static readonly onPrimary: DynamicColor = DynamicColor.fromPalette({
    name: 'on_primary',
    palette: (s: DynamicScheme): TonalPalette => s.primaryPalette,
    tone: (s: DynamicScheme): number => {
      if (isMonochrome(s)) {
        return s.isDark ? 10 : 90;
      }
      return s.isDark ? 20 : 100;
    },
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.primary,
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21)
  });

  static readonly primaryContainer: DynamicColor = DynamicColor.fromPalette({
    name: 'primary_container',
    palette: (s: DynamicScheme): TonalPalette => s.primaryPalette,
    tone: (s: DynamicScheme): number => {
      if (isFidelity(s)) {
        return s.sourceColorHct.tone;
      }
      if (isMonochrome(s)) {
        return s.isDark ? 85 : 25;
      }
      return s.isDark ? 30 : 90;
    },
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.primaryContainer,
      MaterialDynamicColors.primary,
      10,
      TonePolarity.nearer,
      false
    )
  });

  static readonly onPrimaryContainer: DynamicColor = DynamicColor.fromPalette({
    name: 'on_primary_container',
    palette: (s: DynamicScheme): TonalPalette => s.primaryPalette,
    tone: (s: DynamicScheme): number => {
      if (isFidelity(s)) {
        return DynamicColor.foregroundTone(
          MaterialDynamicColors.primaryContainer.getTone(s), 4.5);
      }
      if (isMonochrome(s)) {
        return s.isDark ? 0 : 100;
      }
      return s.isDark ? 90 : 30;
    },
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.primaryContainer,
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11)
  });

  static readonly inversePrimary: DynamicColor = DynamicColor.fromPalette({
    name: 'inverse_primary',
    palette: (s: DynamicScheme): TonalPalette => s.primaryPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 40 : 80,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.inverseSurface,
    contrastCurve: new ContrastCurve(3, 4.5, 7, 7)
  });

  static readonly secondary: DynamicColor = DynamicColor.fromPalette({
    name: 'secondary',
    palette: (s: DynamicScheme): TonalPalette => s.secondaryPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 80 : 40,
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(3, 4.5, 7, 7),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.secondaryContainer,
      MaterialDynamicColors.secondary,
      10,
      TonePolarity.nearer,
      false
    )
  });

  static readonly onSecondary: DynamicColor = DynamicColor.fromPalette({
    name: 'on_secondary',
    palette: (s: DynamicScheme): TonalPalette => s.secondaryPalette,
    tone: (s: DynamicScheme): number => {
      if (isMonochrome(s)) {
        return s.isDark ? 10 : 100;
      }
      return s.isDark ? 20 : 100;
    },
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.secondary,
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21)
  });

  static readonly secondaryContainer: DynamicColor = DynamicColor.fromPalette({
    name: 'secondary_container',
    palette: (s: DynamicScheme): TonalPalette => s.secondaryPalette,
    tone: (s: DynamicScheme): number => {
      const initialTone: number = s.isDark ? 30.0 : 90.0;
      if (isMonochrome(s)) {
        return s.isDark ? 30 : 85;
      }
      if (!isFidelity(s)) {
        return initialTone;
      }
      return MaterialDynamicColors.findDesiredChromaByTone(
        s.secondaryPalette.hue,
        s.secondaryPalette.chroma,
        initialTone,
        !s.isDark
      );
    },
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.secondaryContainer,
      MaterialDynamicColors.secondary,
      10,
      TonePolarity.nearer,
      false
    )
  });

  static readonly onSecondaryContainer: DynamicColor = DynamicColor.fromPalette({
    name: 'on_secondary_container',
    palette: (s: DynamicScheme): TonalPalette => s.secondaryPalette,
    tone: (s: DynamicScheme): number => {
      if (isMonochrome(s)) {
        return s.isDark ? 90 : 10;
      }
      if (!isFidelity(s)) {
        return s.isDark ? 90 : 30;
      }
      return DynamicColor.foregroundTone(
        MaterialDynamicColors.secondaryContainer.getTone(s), 4.5);
    },
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.secondaryContainer,
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11)
  });

  static readonly tertiary: DynamicColor = DynamicColor.fromPalette({
    name: 'tertiary',
    palette: (s: DynamicScheme): TonalPalette => s.tertiaryPalette,
    tone: (s: DynamicScheme): number => {
      if (isMonochrome(s)) {
        return s.isDark ? 90 : 25;
      }
      return s.isDark ? 80 : 40;
    },
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(3, 4.5, 7, 7),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.tertiaryContainer,
      MaterialDynamicColors.tertiary,
      10,
      TonePolarity.nearer,
      false
    )
  });

  static readonly onTertiary: DynamicColor = DynamicColor.fromPalette({
    name: 'on_tertiary',
    palette: (s: DynamicScheme): TonalPalette => s.tertiaryPalette,
    tone: (s: DynamicScheme): number => {
      if (isMonochrome(s)) {
        return s.isDark ? 10 : 90;
      }
      return s.isDark ? 20 : 100;
    },
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.tertiary,
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21)
  });

  static readonly tertiaryContainer: DynamicColor = DynamicColor.fromPalette({
    name: 'tertiary_container',
    palette: (s: DynamicScheme): TonalPalette => s.tertiaryPalette,
    tone: (s: DynamicScheme): number => {
      if (isMonochrome(s)) {
        return s.isDark ? 60 : 49;
      }
      if (!isFidelity(s)) {
        return s.isDark ? 30 : 90;
      }
      const proposedHct: Hct = s.tertiaryPalette.getHct(s.sourceColorHct.tone);
      return proposedHct.tone;
    },
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.tertiaryContainer,
      MaterialDynamicColors.tertiary,
      10,
      TonePolarity.nearer,
      false
    )
  });

  static readonly onTertiaryContainer: DynamicColor = DynamicColor.fromPalette({
    name: 'on_tertiary_container',
    palette: (s: DynamicScheme): TonalPalette => s.tertiaryPalette,
    tone: (s: DynamicScheme): number => {
      if (isMonochrome(s)) {
        return s.isDark ? 0 : 100;
      }
      if (!isFidelity(s)) {
        return s.isDark ? 90 : 30;
      }
      return DynamicColor.foregroundTone(
        MaterialDynamicColors.tertiaryContainer.getTone(s), 4.5);
    },
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.tertiaryContainer,
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11)
  });

  static readonly error: DynamicColor = DynamicColor.fromPalette({
    name: 'error',
    palette: (s: DynamicScheme): TonalPalette => s.errorPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 80 : 40,
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(3, 4.5, 7, 7),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.errorContainer,
      MaterialDynamicColors.error,
      10,
      TonePolarity.nearer,
      false
    )
  });

  static readonly onError: DynamicColor = DynamicColor.fromPalette({
    name: 'on_error',
    palette: (s: DynamicScheme): TonalPalette => s.errorPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 20 : 100,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.error,
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21)
  });

  static readonly errorContainer: DynamicColor = DynamicColor.fromPalette({
    name: 'error_container',
    palette: (s: DynamicScheme): TonalPalette => s.errorPalette,
    tone: (s: DynamicScheme): number => s.isDark ? 30 : 90,
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.errorContainer,
      MaterialDynamicColors.error,
      10,
      TonePolarity.nearer,
      false
    )
  });

  static readonly onErrorContainer: DynamicColor = DynamicColor.fromPalette({
    name: 'on_error_container',
    palette: (s: DynamicScheme): TonalPalette => s.errorPalette,
    tone: (s: DynamicScheme): number => {
      if (isMonochrome(s)) {
        return s.isDark ? 90 : 10;
      }
      return s.isDark ? 90 : 30;
    },
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.errorContainer,
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11)
  });

  static readonly primaryFixed: DynamicColor = DynamicColor.fromPalette({
    name: 'primary_fixed',
    palette: (s: DynamicScheme): TonalPalette => s.primaryPalette,
    tone: (s: DynamicScheme): number => isMonochrome(s) ? 40.0 : 90.0,
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.primaryFixed,
      MaterialDynamicColors.primaryFixedDim,
      10,
      TonePolarity.lighter,
      true
    )
  });

  static readonly primaryFixedDim: DynamicColor = DynamicColor.fromPalette({
    name: 'primary_fixed_dim',
    palette: (s: DynamicScheme): TonalPalette => s.primaryPalette,
    tone: (s: DynamicScheme): number => isMonochrome(s) ? 30.0 : 80.0,
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.primaryFixed,
      MaterialDynamicColors.primaryFixedDim,
      10,
      TonePolarity.lighter,
      true
    )
  });

  static readonly onPrimaryFixed: DynamicColor = DynamicColor.fromPalette({
    name: 'on_primary_fixed',
    palette: (s: DynamicScheme): TonalPalette => s.primaryPalette,
    tone: (s: DynamicScheme): number => isMonochrome(s) ? 100.0 : 10.0,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.primaryFixedDim,
    secondBackground: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.primaryFixed,
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21)
  });

  static readonly onPrimaryFixedVariant: DynamicColor = DynamicColor.fromPalette({
    name: 'on_primary_fixed_variant',
    palette: (s: DynamicScheme): TonalPalette => s.primaryPalette,
    tone: (s: DynamicScheme): number => isMonochrome(s) ? 90.0 : 30.0,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.primaryFixedDim,
    secondBackground: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.primaryFixed,
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11)
  });

  static readonly secondaryFixed: DynamicColor = DynamicColor.fromPalette({
    name: 'secondary_fixed',
    palette: (s: DynamicScheme): TonalPalette => s.secondaryPalette,
    tone: (s: DynamicScheme): number => isMonochrome(s) ? 80.0 : 90.0,
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.secondaryFixed,
      MaterialDynamicColors.secondaryFixedDim,
      10,
      TonePolarity.lighter,
      true
    )
  });

  static readonly secondaryFixedDim: DynamicColor = DynamicColor.fromPalette({
    name: 'secondary_fixed_dim',
    palette: (s: DynamicScheme): TonalPalette => s.secondaryPalette,
    tone: (s: DynamicScheme): number => isMonochrome(s) ? 70.0 : 80.0,
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.secondaryFixed,
      MaterialDynamicColors.secondaryFixedDim,
      10,
      TonePolarity.lighter,
      true
    )
  });

  static readonly onSecondaryFixed: DynamicColor = DynamicColor.fromPalette({
    name: 'on_secondary_fixed',
    palette: (s: DynamicScheme): TonalPalette => s.secondaryPalette,
    tone: (s: DynamicScheme): number => 10.0,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.secondaryFixedDim,
    secondBackground: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.secondaryFixed,
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21)
  });

  static readonly onSecondaryFixedVariant: DynamicColor = DynamicColor.fromPalette({
    name: 'on_secondary_fixed_variant',
    palette: (s: DynamicScheme): TonalPalette => s.secondaryPalette,
    tone: (s: DynamicScheme): number => isMonochrome(s) ? 25.0 : 30.0,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.secondaryFixedDim,
    secondBackground: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.secondaryFixed,
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11)
  });

  static readonly tertiaryFixed: DynamicColor = DynamicColor.fromPalette({
    name: 'tertiary_fixed',
    palette: (s: DynamicScheme): TonalPalette => s.tertiaryPalette,
    tone: (s: DynamicScheme): number => isMonochrome(s) ? 40.0 : 90.0,
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.tertiaryFixed,
      MaterialDynamicColors.tertiaryFixedDim,
      10,
      TonePolarity.lighter,
      true
    )
  });

  static readonly tertiaryFixedDim: DynamicColor = DynamicColor.fromPalette({
    name: 'tertiary_fixed_dim',
    palette: (s: DynamicScheme): TonalPalette => s.tertiaryPalette,
    tone: (s: DynamicScheme): number => isMonochrome(s) ? 30.0 : 80.0,
    isBackground: true,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.highestSurface(s),
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: (s: DynamicScheme): ToneDeltaPair => new ToneDeltaPair(
      MaterialDynamicColors.tertiaryFixed,
      MaterialDynamicColors.tertiaryFixedDim,
      10,
      TonePolarity.lighter,
      true
    )
  });

  static readonly onTertiaryFixed: DynamicColor = DynamicColor.fromPalette({
    name: 'on_tertiary_fixed',
    palette: (s: DynamicScheme): TonalPalette => s.tertiaryPalette,
    tone: (s: DynamicScheme): number => isMonochrome(s) ? 100.0 : 10.0,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.tertiaryFixedDim,
    secondBackground: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.tertiaryFixed,
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21)
  });

  static readonly onTertiaryFixedVariant: DynamicColor = DynamicColor.fromPalette({
    name: 'on_tertiary_fixed_variant',
    palette: (s: DynamicScheme): TonalPalette => s.tertiaryPalette,
    tone: (s: DynamicScheme): number => isMonochrome(s) ? 90.0 : 30.0,
    background: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.tertiaryFixedDim,
    secondBackground: (s: DynamicScheme): DynamicColor => MaterialDynamicColors.tertiaryFixed,
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11)
  });

  /**
   * 在给定色相下，寻找彩度最接近目标值、且尽量靠近初始 tone 的位置。
   * 上游同名私有函数，仅供 fidelity / content 变体的 secondaryContainer 使用。
   */
  private static findDesiredChromaByTone(hue: number, chroma: number,
    tone: number, byDecreasingTone: boolean): number {
    let answer: number = tone;

    let closestToChroma: Hct = Hct.from(hue, chroma, tone);
    if (closestToChroma.chroma < chroma) {
      let chromaPeak: number = closestToChroma.chroma;
      while (closestToChroma.chroma < chroma) {
        answer += byDecreasingTone ? -1.0 : 1.0;
        const potentialSolution: Hct = Hct.from(hue, chroma, answer);
        if (chromaPeak > potentialSolution.chroma) {
          break;
        }
        if (Math.abs(potentialSolution.chroma - chroma) < 0.4) {
          break;
        }
        const potentialDelta: number = Math.abs(potentialSolution.chroma - chroma);
        const currentDelta: number = Math.abs(closestToChroma.chroma - chroma);
        if (potentialDelta < currentDelta) {
          closestToChroma = potentialSolution;
        }
        chromaPeak = Math.max(chromaPeak, potentialSolution.chroma);
      }
    }

    return answer;
  }
}
