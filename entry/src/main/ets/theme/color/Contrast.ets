import { ColorUtils } from './ColorUtils';
import { MathUtils } from './MathUtils';

/**
 * 对比度计算。
 * 移植自 material_color_utilities/lib/contrast/contrast.dart 0.13.0。
 *
 * 对比度基于 XYZ 的 Y，线性化之后 Y 就是 HCT 的 tone / Lab 的 L*，
 * 因此这里所有「亮度」参数都以 tone（0-100）表达。
 */
export class Contrast {
  /** 两个 tone 之间的对比度，范围 1-21。 */
  static ratioOfTones(toneA: number, toneB: number): number {
    const a: number = MathUtils.clampDouble(0.0, 100.0, toneA);
    const b: number = MathUtils.clampDouble(0.0, 100.0, toneB);
    return Contrast.ratioOfYs(ColorUtils.yFromLstar(a), ColorUtils.yFromLstar(b));
  }

  private static ratioOfYs(y1: number, y2: number): number {
    const lighter: number = y1 > y2 ? y1 : y2;
    const darker: number = lighter === y2 ? y1 : y2;
    return (lighter + 5.0) / (darker + 5.0);
  }

  /** 返回 >= tone 且满足 ratio 的 tone，无法满足时返回 -1。 */
  static lighter(tone: number, ratio: number): number {
    if (tone < 0.0 || tone > 100.0) {
      return -1.0;
    }
    const darkY: number = ColorUtils.yFromLstar(tone);
    const lightY: number = ratio * (darkY + 5.0) - 5.0;
    const realContrast: number = Contrast.ratioOfYs(lightY, darkY);
    const delta: number = Math.abs(realContrast - ratio);
    if (realContrast < ratio && delta > 0.04) {
      return -1;
    }
    const returnValue: number = ColorUtils.lstarFromY(lightY) + 0.4;
    if (returnValue < 0 || returnValue > 100) {
      return -1;
    }
    return returnValue;
  }

  /** 返回 <= tone 且满足 ratio 的 tone，无法满足时返回 -1。 */
  static darker(tone: number, ratio: number): number {
    if (tone < 0.0 || tone > 100.0) {
      return -1.0;
    }
    const lightY: number = ColorUtils.yFromLstar(tone);
    const darkY: number = ((lightY + 5.0) / ratio) - 5.0;
    const realContrast: number = Contrast.ratioOfYs(lightY, darkY);
    const delta: number = Math.abs(realContrast - ratio);
    if (realContrast < ratio && delta > 0.04) {
      return -1;
    }
    const returnValue: number = ColorUtils.lstarFromY(darkY) - 0.4;
    if (returnValue < 0 || returnValue > 100) {
      return -1;
    }
    return returnValue;
  }

  /** 同 lighter，但无法满足时返回 100（保证落在 [0,100]）。 */
  static lighterUnsafe(tone: number, ratio: number): number {
    const lighterSafe: number = Contrast.lighter(tone, ratio);
    return lighterSafe < 0.0 ? 100.0 : lighterSafe;
  }

  /** 同 darker，但无法满足时返回 0（保证落在 [0,100]）。 */
  static darkerUnsafe(tone: number, ratio: number): number {
    const darkerSafe: number = Contrast.darker(tone, ratio);
    return darkerSafe < 0.0 ? 0.0 : darkerSafe;
  }
}
