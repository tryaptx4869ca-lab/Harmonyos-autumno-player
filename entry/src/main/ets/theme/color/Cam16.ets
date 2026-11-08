import { ColorUtils } from './ColorUtils';
import { MathUtils } from './MathUtils';
import { ViewingConditions } from './ViewingConditions';

/**
 * CAM16 色彩外观模型。
 * 移植自 material_color_utilities/lib/hct/cam16.dart 0.13.0。
 */
export class Cam16 {
  readonly hue: number;
  readonly chroma: number;
  readonly j: number;
  readonly q: number;
  readonly m: number;
  readonly s: number;
  readonly jstar: number;
  readonly astar: number;
  readonly bstar: number;

  private constructor(
    hue: number, chroma: number, j: number, q: number, m: number,
    s: number, jstar: number, astar: number, bstar: number
  ) {
    this.hue = hue;
    this.chroma = chroma;
    this.j = j;
    this.q = q;
    this.m = m;
    this.s = s;
    this.jstar = jstar;
    this.astar = astar;
    this.bstar = bstar;
  }

  /** 用默认观察条件把 ARGB 转成 CAM16。 */
  static fromInt(argb: number): Cam16 {
    return Cam16.fromIntInViewingConditions(argb, ViewingConditions.sRgb);
  }

  static fromIntInViewingConditions(argb: number, vc: ViewingConditions): Cam16 {
    const xyz: number[] = ColorUtils.xyzFromArgb(argb);
    return Cam16.fromXyzInViewingConditions(xyz[0], xyz[1], xyz[2], vc);
  }

  static fromXyzInViewingConditions(
    x: number, y: number, z: number, viewingConditions: ViewingConditions
  ): Cam16 {
    const rC: number = 0.401288 * x + 0.650173 * y - 0.051461 * z;
    const gC: number = -0.250268 * x + 1.204414 * y + 0.045854 * z;
    const bC: number = -0.002079 * x + 0.048952 * y + 0.953127 * z;

    const rD: number = viewingConditions.rgbD[0] * rC;
    const gD: number = viewingConditions.rgbD[1] * gC;
    const bD: number = viewingConditions.rgbD[2] * bC;

    const rAF: number = Math.pow(viewingConditions.fl * Math.abs(rD) / 100.0, 0.42);
    const gAF: number = Math.pow(viewingConditions.fl * Math.abs(gD) / 100.0, 0.42);
    const bAF: number = Math.pow(viewingConditions.fl * Math.abs(bD) / 100.0, 0.42);
    const rA: number = MathUtils.signum(rD) * 400.0 * rAF / (rAF + 27.13);
    const gA: number = MathUtils.signum(gD) * 400.0 * gAF / (gAF + 27.13);
    const bA: number = MathUtils.signum(bD) * 400.0 * bAF / (bAF + 27.13);

    const a: number = (11.0 * rA + -12.0 * gA + bA) / 11.0;
    const b: number = (rA + gA - 2.0 * bA) / 9.0;
    const u: number = (20.0 * rA + 20.0 * gA + 21.0 * bA) / 20.0;
    const p2: number = (40.0 * rA + 20.0 * gA + bA) / 20.0;

    const atan2: number = Math.atan2(b, a);
    const atanDegrees: number = atan2 * 180.0 / Math.PI;
    const hue: number = atanDegrees < 0
      ? atanDegrees + 360.0
      : (atanDegrees >= 360 ? atanDegrees - 360 : atanDegrees);
    const hueRadians: number = hue * Math.PI / 180.0;

    const ac: number = p2 * viewingConditions.nbb;

    const jBig: number = 100.0 * Math.pow(
      ac / viewingConditions.aw,
      viewingConditions.c * viewingConditions.z
    );
    const q: number = (4.0 / viewingConditions.c) * Math.sqrt(jBig / 100.0) *
      (viewingConditions.aw + 4.0) * viewingConditions.fLRoot;

    const huePrime: number = (hue < 20.14) ? hue + 360 : hue;
    const eHue: number = (1.0 / 4.0) * (Math.cos(huePrime * Math.PI / 180.0 + 2.0) + 3.8);
    const p1: number = 50000.0 / 13.0 * eHue * viewingConditions.nC * viewingConditions.ncb;
    const t: number = p1 * Math.sqrt(a * a + b * b) / (u + 0.305);
    const alpha: number = Math.pow(t, 0.9) *
      Math.pow(1.64 - Math.pow(0.29, viewingConditions.backgroundYTowhitePointY), 0.73);

    const cBig: number = alpha * Math.sqrt(jBig / 100.0);
    const m: number = cBig * viewingConditions.fLRoot;
    const s: number = 50.0 * Math.sqrt(
      (alpha * viewingConditions.c) / (viewingConditions.aw + 4.0)
    );

    const jstar: number = (1.0 + 100.0 * 0.007) * jBig / (1.0 + 0.007 * jBig);
    const mstar: number = Math.log(1.0 + 0.0228 * m) / 0.0228;
    const astar: number = mstar * Math.cos(hueRadians);
    const bstar: number = mstar * Math.sin(hueRadians);
    return new Cam16(hue, cBig, jBig, q, m, s, jstar, astar, bstar);
  }

  static fromJch(j: number, c: number, h: number): Cam16 {
    return Cam16.fromJchInViewingConditions(j, c, h, ViewingConditions.sRgb);
  }

  static fromJchInViewingConditions(
    jBig: number, cBig: number, h: number, viewingConditions: ViewingConditions
  ): Cam16 {
    const q: number = (4.0 / viewingConditions.c) * Math.sqrt(jBig / 100.0) *
      (viewingConditions.aw + 4.0) * viewingConditions.fLRoot;
    const m: number = cBig * viewingConditions.fLRoot;
    const alpha: number = cBig / Math.sqrt(jBig / 100.0);
    const s: number = 50.0 * Math.sqrt(
      (alpha * viewingConditions.c) / (viewingConditions.aw + 4.0)
    );

    const hueRadians: number = h * Math.PI / 180.0;
    const jstar: number = (1.0 + 100.0 * 0.007) * jBig / (1.0 + 0.007 * jBig);
    const mstar: number = 1.0 / 0.0228 * Math.log(1.0 + 0.0228 * m);
    const astar: number = mstar * Math.cos(hueRadians);
    const bstar: number = mstar * Math.sin(hueRadians);
    return new Cam16(h, cBig, jBig, q, m, s, jstar, astar, bstar);
  }

  /** ARGB 表示（默认观察条件）。 */
  toInt(): number {
    return this.viewed(ViewingConditions.sRgb);
  }

  viewed(viewingConditions: ViewingConditions): number {
    const xyz: number[] = this.xyzInViewingConditions(viewingConditions);
    return ColorUtils.argbFromXyz(xyz[0], xyz[1], xyz[2]);
  }

  xyzInViewingConditions(viewingConditions: ViewingConditions): number[] {
    const alpha: number = (this.chroma === 0.0 || this.j === 0.0)
      ? 0.0
      : this.chroma / Math.sqrt(this.j / 100.0);

    const t: number = Math.pow(
      alpha / Math.pow(
        1.64 - Math.pow(0.29, viewingConditions.backgroundYTowhitePointY), 0.73
      ),
      1.0 / 0.9
    );
    const hRad: number = this.hue * Math.PI / 180.0;

    const eHue: number = 0.25 * (Math.cos(hRad + 2.0) + 3.8);
    const ac: number = viewingConditions.aw *
      Math.pow(this.j / 100.0, 1.0 / viewingConditions.c / viewingConditions.z);
    const p1: number = eHue * (50000.0 / 13.0) * viewingConditions.nC * viewingConditions.ncb;
    const p2: number = ac / viewingConditions.nbb;

    const hSin: number = Math.sin(hRad);
    const hCos: number = Math.cos(hRad);

    const gamma: number = 23.0 * (p2 + 0.305) * t /
      (23.0 * p1 + 11 * t * hCos + 108.0 * t * hSin);
    const a: number = gamma * hCos;
    const b: number = gamma * hSin;
    const rA: number = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0;
    const gA: number = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0;
    const bA: number = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0;

    const rCBase: number = Math.max(0, (27.13 * Math.abs(rA)) / (400.0 - Math.abs(rA)));
    const rC: number = MathUtils.signum(rA) * (100.0 / viewingConditions.fl) *
      Math.pow(rCBase, 1.0 / 0.42);
    const gCBase: number = Math.max(0, (27.13 * Math.abs(gA)) / (400.0 - Math.abs(gA)));
    const gC: number = MathUtils.signum(gA) * (100.0 / viewingConditions.fl) *
      Math.pow(gCBase, 1.0 / 0.42);
    const bCBase: number = Math.max(0, (27.13 * Math.abs(bA)) / (400.0 - Math.abs(bA)));
    const bC: number = MathUtils.signum(bA) * (100.0 / viewingConditions.fl) *
      Math.pow(bCBase, 1.0 / 0.42);
    const rF: number = rC / viewingConditions.rgbD[0];
    const gF: number = gC / viewingConditions.rgbD[1];
    const bF: number = bC / viewingConditions.rgbD[2];

    const x: number = 1.86206786 * rF - 1.01125463 * gF + 0.14918677 * bF;
    const y: number = 0.38752654 * rF + 0.62144744 * gF - 0.00897398 * bF;
    const z: number = -0.01584150 * rF - 0.03412294 * gF + 1.04996444 * bF;
    return [x, y, z];
  }
}
