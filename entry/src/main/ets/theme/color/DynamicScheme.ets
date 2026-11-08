import { Hct } from './Hct';
import { TonalPalette } from './TonalPalette';

/**
 * 主题变体。移植自 material_color_utilities/lib/dynamiccolor/variant.dart。
 *
 * 本应用只使用 tonalSpot（Flutter `ColorScheme.fromSeed` 的默认值），
 * 其余枚举值保留以便日后需要时按同一套角色表复用。
 */
export enum Variant {
  monochrome,
  neutral,
  tonalSpot,
  vibrant,
  expressive,
  fidelity,
  content,
  rainbow,
  fruitSalad
}

/**
 * 动态配色方案：由「种子色 + 明暗 + 对比度等级」决定一组色板，
 * 再由角色表（MaterialDynamicColors）解析成具体颜色。
 *
 * 对应 material_color_utilities/lib/dynamiccolor/dynamic_scheme.dart。
 * 与上游的差别：上游把「角色 → 颜色」的 getter 挂在本类上，
 * 这里拆到 MaterialDynamicColors + ColorScheme，避免循环依赖。
 */
export class DynamicScheme {
  /** 种子色的 ARGB。 */
  readonly sourceColorArgb: number;
  /** 种子色的 HCT。 */
  readonly sourceColorHct: Hct;
  readonly variant: Variant;
  readonly isDark: boolean;
  /**
   * -1 最低对比度、0 标准（设计稿）、1 最高对比度。
   * Flutter `ColorScheme.fromSeed` 默认 0。
   */
  readonly contrastLevel: number;

  readonly primaryPalette: TonalPalette;
  readonly secondaryPalette: TonalPalette;
  readonly tertiaryPalette: TonalPalette;
  readonly neutralPalette: TonalPalette;
  readonly neutralVariantPalette: TonalPalette;
  /** 错误色色板，固定色相 25 / 彩度 84。 */
  readonly errorPalette: TonalPalette;

  constructor(sourceColorHct: Hct, variant: Variant, isDark: boolean,
    contrastLevel: number, primaryPalette: TonalPalette,
    secondaryPalette: TonalPalette, tertiaryPalette: TonalPalette,
    neutralPalette: TonalPalette, neutralVariantPalette: TonalPalette,
    errorPalette: TonalPalette | undefined) {
    this.sourceColorHct = sourceColorHct;
    this.sourceColorArgb = sourceColorHct.toInt();
    this.variant = variant;
    this.isDark = isDark;
    this.contrastLevel = contrastLevel;
    this.primaryPalette = primaryPalette;
    this.secondaryPalette = secondaryPalette;
    this.tertiaryPalette = tertiaryPalette;
    this.neutralPalette = neutralPalette;
    this.neutralVariantPalette = neutralVariantPalette;
    this.errorPalette = errorPalette ?? TonalPalette.of(25.0, 84.0);
  }
}
