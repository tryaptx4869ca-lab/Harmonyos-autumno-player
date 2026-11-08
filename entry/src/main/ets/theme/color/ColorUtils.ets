import { MathUtils } from './MathUtils';

/**
 * 颜色空间转换工具。
 * 移植自 material_color_utilities/lib/utils/color_utils.dart 0.13.0。
 *
 * 注意量纲约定（与上游一致，容易搞错）：
 *   - linearized：输入 0-255，输出 **0-100**
 *   - delinearized：输入 **0-100**，输出 0-255（已 clamp 并四舍五入）
 */
export class ColorUtils {
  static readonly srgbToXyz: number[][] = [
    [0.41233895, 0.35762064, 0.18051042],
    [0.2126, 0.7152, 0.0722],
    [0.01932141, 0.11916382, 0.95034478]
  ];

  static readonly xyzToSrgb: number[][] = [
    [3.2413774792388685, -1.5376652402851851, -0.49885366846268053],
    [-0.9691452513005321, 1.8758853451067872, 0.04156585616912061],
    [0.05562093689691305, -0.20395524564742123, 1.0571799111220335]
  ];

  static readonly whitePointD65V: number[] = [95.047, 100.0, 108.883];

  static whitePointD65(): number[] {
    return ColorUtils.whitePointD65V;
  }

  static argbFromRgb(red: number, green: number, blue: number): number {
    return ((255 << 24) | ((red & 255) << 16) | ((green & 255) << 8) | (blue & 255)) >>> 0;
  }

  static argbFromLinrgb(linrgb: number[]): number {
    const r: number = ColorUtils.delinearized(linrgb[0]);
    const g: number = ColorUtils.delinearized(linrgb[1]);
    const b: number = ColorUtils.delinearized(linrgb[2]);
    return ColorUtils.argbFromRgb(r, g, b);
  }

  static alphaFromArgb(argb: number): number {
    return (argb >> 24) & 255;
  }

  static redFromArgb(argb: number): number {
    return (argb >> 16) & 255;
  }

  static greenFromArgb(argb: number): number {
    return (argb >> 8) & 255;
  }

  static blueFromArgb(argb: number): number {
    return argb & 255;
  }

  static argbFromXyz(x: number, y: number, z: number): number {
    const m: number[][] = ColorUtils.xyzToSrgb;
    const linearR: number = m[0][0] * x + m[0][1] * y + m[0][2] * z;
    const linearG: number = m[1][0] * x + m[1][1] * y + m[1][2] * z;
    const linearB: number = m[2][0] * x + m[2][1] * y + m[2][2] * z;
    return ColorUtils.argbFromRgb(
      ColorUtils.delinearized(linearR),
      ColorUtils.delinearized(linearG),
      ColorUtils.delinearized(linearB)
    );
  }

  static xyzFromArgb(argb: number): number[] {
    const r: number = ColorUtils.linearized(ColorUtils.redFromArgb(argb));
    const g: number = ColorUtils.linearized(ColorUtils.greenFromArgb(argb));
    const b: number = ColorUtils.linearized(ColorUtils.blueFromArgb(argb));
    return MathUtils.matrixMultiply([r, g, b], ColorUtils.srgbToXyz);
  }

  /** L* → 灰阶 ARGB */
  static argbFromLstar(lstar: number): number {
    const y: number = ColorUtils.yFromLstar(lstar);
    const component: number = ColorUtils.delinearized(y);
    return ColorUtils.argbFromRgb(component, component, component);
  }

  static lstarFromArgb(argb: number): number {
    const y: number = ColorUtils.xyzFromArgb(argb)[1];
    return 116.0 * ColorUtils.labF(y / 100.0) - 16.0;
  }

  static yFromLstar(lstar: number): number {
    return 100.0 * ColorUtils.labInvf((lstar + 16.0) / 116.0);
  }

  static lstarFromY(y: number): number {
    return ColorUtils.labF(y / 100.0) * 116.0 - 16.0;
  }

  /** 0-255 → **0-100** 线性分量 */
  static linearized(rgbComponent: number): number {
    const normalized: number = rgbComponent / 255.0;
    if (normalized <= 0.040449936) {
      return normalized / 12.92 * 100.0;
    }
    return Math.pow((normalized + 0.055) / 1.055, 2.4) * 100.0;
  }

  /** **0-100** 线性分量 → 0-255（clamp + round） */
  static delinearized(rgbComponent: number): number {
    const normalized: number = rgbComponent / 100.0;
    let delinearized: number = 0.0;
    if (normalized <= 0.0031308) {
      delinearized = normalized * 12.92;
    } else {
      delinearized = 1.055 * Math.pow(normalized, 1.0 / 2.4) - 0.055;
    }
    return MathUtils.clampInt(0, 255, Math.round(delinearized * 255.0));
  }

  static labF(t: number): number {
    const e: number = 216.0 / 24389.0;
    const kappa: number = 24389.0 / 27.0;
    if (t > e) {
      return Math.pow(t, 1.0 / 3.0);
    }
    return (kappa * t + 16) / 116;
  }

  static labInvf(ft: number): number {
    const e: number = 216.0 / 24389.0;
    const kappa: number = 24389.0 / 27.0;
    const ft3: number = ft * ft * ft;
    if (ft3 > e) {
      return ft3;
    }
    return (116.0 * ft - 16.0) / kappa;
  }
}
