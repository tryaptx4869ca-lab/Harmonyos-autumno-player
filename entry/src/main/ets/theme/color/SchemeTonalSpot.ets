import { DynamicScheme, Variant } from './DynamicScheme';
import { Hct } from './Hct';
import { MathUtils } from './MathUtils';
import { TonalPalette } from './TonalPalette';

/**
 * tonalSpot 变体：Android 12/13 的默认 Material You 主题，
 * 也是 Flutter `ColorScheme.fromSeed` 的默认变体。
 * 移植自 material_color_utilities/lib/scheme/scheme_tonal_spot.dart。
 */
export class SchemeTonalSpot extends DynamicScheme {
  constructor(sourceColorHct: Hct, isDark: boolean, contrastLevel: number) {
    super(
      sourceColorHct,
      Variant.tonalSpot,
      isDark,
      contrastLevel,
      TonalPalette.of(sourceColorHct.hue, 36.0),
      TonalPalette.of(sourceColorHct.hue, 16.0),
      TonalPalette.of(MathUtils.sanitizeDegreesDouble(sourceColorHct.hue + 60.0), 24.0),
      TonalPalette.of(sourceColorHct.hue, 6.0),
      TonalPalette.of(sourceColorHct.hue, 8.0),
      undefined
    );
  }
}
