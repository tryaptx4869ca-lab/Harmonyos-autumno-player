import { ColorUtils } from './ColorUtils';
import { MathUtils } from './MathUtils';

/**
 * 观察条件。
 * 移植自 material_color_utilities/lib/hct/viewing_conditions.dart 0.13.0。
 */
export class ViewingConditions {
  readonly whitePoint: number[];
  readonly adaptingLuminance: number;
  readonly backgroundLstar: number;
  readonly surround: number;
  readonly discountingIlluminant: boolean;
  readonly backgroundYTowhitePointY: number;
  readonly aw: number;
  readonly nbb: number;
  readonly ncb: number;
  readonly c: number;
  readonly nC: number;
  readonly drgbInverse: number[];
  readonly rgbD: number[];
  readonly fl: number;
  readonly fLRoot: number;
  readonly z: number;

  private constructor(
    whitePoint: number[], adaptingLuminance: number, backgroundLstar: number,
    surround: number, discountingIlluminant: boolean,
    backgroundYTowhitePointY: number, aw: number, nbb: number, ncb: number,
    c: number, nC: number, drgbInverse: number[], rgbD: number[],
    fl: number, fLRoot: number, z: number
  ) {
    this.whitePoint = whitePoint;
    this.adaptingLuminance = adaptingLuminance;
    this.backgroundLstar = backgroundLstar;
    this.surround = surround;
    this.discountingIlluminant = discountingIlluminant;
    this.backgroundYTowhitePointY = backgroundYTowhitePointY;
    this.aw = aw;
    this.nbb = nbb;
    this.ncb = ncb;
    this.c = c;
    this.nC = nC;
    this.drgbInverse = drgbInverse;
    this.rgbD = rgbD;
    this.fl = fl;
    this.fLRoot = fLRoot;
    this.z = z;
  }

  static readonly sRgb: ViewingConditions = ViewingConditions.make(
    ColorUtils.whitePointD65(), -1.0, 50.0, 2.0, false
  );

  static readonly standard: ViewingConditions = ViewingConditions.sRgb;

  static make(
    whitePoint: number[], adaptingLuminanceIn: number,
    backgroundLstarIn: number, surroundIn: number, discountingIlluminant: boolean
  ): ViewingConditions {
    const whitePointV: number[] =
      (whitePoint === null || whitePoint === undefined)
        ? ColorUtils.whitePointD65() : whitePoint;

    const adaptingLuminance: number = adaptingLuminanceIn > 0.0
      ? adaptingLuminanceIn
      : (200.0 / Math.PI * ColorUtils.yFromLstar(50.0) / 100.0);

    // 纯黑背景是非物理的，会导致无穷大
    const backgroundLstar: number = Math.max(0.1, backgroundLstarIn);
    const surround: number = surroundIn;

    const xyz: number[] = whitePointV;
    const rW: number = xyz[0] * 0.401288 + xyz[1] * 0.650173 + xyz[2] * -0.051461;
    const gW: number = xyz[0] * -0.250268 + xyz[1] * 1.204414 + xyz[2] * 0.045854;
    const bW: number = xyz[0] * -0.002079 + xyz[1] * 0.048952 + xyz[2] * 0.953127;

    const f: number = 0.8 + (surround / 10.0);
    const c: number = (f >= 0.9)
      ? MathUtils.lerp(0.59, 0.69, (f - 0.9) * 10.0)
      : MathUtils.lerp(0.525, 0.59, (f - 0.8) * 10.0);

    let d: number = discountingIlluminant
      ? 1.0
      : f * (1.0 - ((1.0 / 3.6) * Math.exp((-adaptingLuminance - 42.0) / 92.0)));
    d = (d > 1.0) ? 1.0 : ((d < 0.0) ? 0.0 : d);

    const nc: number = f;

    const rgbD: number[] = [
      d * (100.0 / rW) + 1.0 - d,
      d * (100.0 / gW) + 1.0 - d,
      d * (100.0 / bW) + 1.0 - d
    ];

    const k: number = 1.0 / (5.0 * adaptingLuminance + 1.0);
    const k4: number = k * k * k * k;
    const k4F: number = 1.0 - k4;

    const fl: number = (k4 * adaptingLuminance) +
      (0.1 * k4F * k4F * Math.pow(5.0 * adaptingLuminance, 1.0 / 3.0));

    const n: number = ColorUtils.yFromLstar(backgroundLstar) / whitePointV[1];
    const z: number = 1.48 + Math.sqrt(n);
    const nbb: number = 0.725 / Math.pow(n, 0.2);
    const ncb: number = nbb;

    const rgbAFactors: number[] = [
      Math.pow(fl * rgbD[0] * rW / 100.0, 0.42),
      Math.pow(fl * rgbD[1] * gW / 100.0, 0.42),
      Math.pow(fl * rgbD[2] * bW / 100.0, 0.42)
    ];
    const rgbA: number[] = [
      (400.0 * rgbAFactors[0]) / (rgbAFactors[0] + 27.13),
      (400.0 * rgbAFactors[1]) / (rgbAFactors[1] + 27.13),
      (400.0 * rgbAFactors[2]) / (rgbAFactors[2] + 27.13)
    ];
    const aw: number = (40.0 * rgbA[0] + 20.0 * rgbA[1] + rgbA[2]) / 20.0 * nbb;

    return new ViewingConditions(
      whitePointV, adaptingLuminance, backgroundLstar, surround,
      discountingIlluminant, n, aw, nbb, ncb, c, nc, [0.0, 0.0, 0.0],
      rgbD, fl, Math.pow(fl, 0.25), z
    );
  }
}
