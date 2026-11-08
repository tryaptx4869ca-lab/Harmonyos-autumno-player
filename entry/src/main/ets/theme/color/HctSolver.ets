import { Cam16 } from './Cam16';
import { ColorUtils } from './ColorUtils';
import { MathUtils } from './MathUtils';
import { ViewingConditions } from './ViewingConditions';
import { HctSolverTables } from './HctSolverTables';

/**
 * HCT 方程求解器。
 * 移植自 material_color_utilities/lib/hct/src/hct_solver.dart 0.13.0。
 *
 * 思路：先在 Y 平面上用二分法找到目标色相所在的线段，
 * 再沿 8-bit 灰阶的关键平面继续二分逼近；若能直接解出则走 Newton 迭代。
 */
export class HctSolver {
  private static sanitizeRadians(angle: number): number {
    return (angle + Math.PI * 8) % (Math.PI * 2);
  }

  /** 线性 R/G/B 分量（0-100）→ 常规 RGB 分量（0-255，浮点）。 */
  private static trueDelinearized(rgbComponent: number): number {
    const normalized: number = rgbComponent / 100.0;
    let delinearized: number = 0.0;
    if (normalized <= 0.0031308) {
      delinearized = normalized * 12.92;
    } else {
      delinearized = 1.055 * Math.pow(normalized, 1.0 / 2.4) - 0.055;
    }
    return delinearized * 255.0;
  }

  private static chromaticAdaptation(component: number): number {
    const af: number = Math.pow(Math.abs(component), 0.42);
    return MathUtils.signum(component) * 400.0 * af / (af + 27.13);
  }

  /** 线性 RGB 的 CAM16 色相（弧度）。 */
  private static hueOf(linrgb: number[]): number {
    const scaledDiscount: number[] =
      MathUtils.matrixMultiply(linrgb, HctSolverTables.scaledDiscountFromLinrgb);
    const rA: number = HctSolver.chromaticAdaptation(scaledDiscount[0]);
    const gA: number = HctSolver.chromaticAdaptation(scaledDiscount[1]);
    const bA: number = HctSolver.chromaticAdaptation(scaledDiscount[2]);
    const a: number = (11.0 * rA + -12.0 * gA + bA) / 11.0;
    const b: number = (rA + gA - 2.0 * bA) / 9.0;
    return Math.atan2(b, a);
  }

  private static areInCyclicOrder(a: number, b: number, c: number): boolean {
    const deltaAB: number = HctSolver.sanitizeRadians(b - a);
    const deltaAC: number = HctSolver.sanitizeRadians(c - a);
    return deltaAB < deltaAC;
  }

  /** 解 lerp 方程：返回 t 使 lerp(source, target, t) = mid。 */
  private static intercept(source: number, mid: number, target: number): number {
    return (mid - source) / (target - source);
  }

  private static lerpPoint(source: number[], t: number, target: number[]): number[] {
    return [
      source[0] + (target[0] - source[0]) * t,
      source[1] + (target[1] - source[1]) * t,
      source[2] + (target[2] - source[2]) * t
    ];
  }

  /** 把线段与某个坐标平面求交。 */
  private static setCoordinate(
    source: number[], coordinate: number, target: number[], axis: number
  ): number[] {
    const t: number = HctSolver.intercept(source[axis], coordinate, target[axis]);
    return HctSolver.lerpPoint(source, t, target);
  }

  private static isBounded(x: number): boolean {
    return 0.0 <= x && x <= 100.0;
  }

  /** 平面 Y=y 与 RGB 立方体相交多边形的第 n 个顶点（0..11）。 */
  private static nthVertex(y: number, n: number): number[] {
    const kR: number = HctSolverTables.yFromLinrgb[0];
    const kG: number = HctSolverTables.yFromLinrgb[1];
    const kB: number = HctSolverTables.yFromLinrgb[2];
    const coordA: number = n % 4 <= 1 ? 0.0 : 100.0;
    const coordB: number = n % 2 === 0 ? 0.0 : 100.0;
    if (n < 4) {
      const g: number = coordA;
      const b: number = coordB;
      const r: number = (y - g * kG - b * kB) / kR;
      return HctSolver.isBounded(r) ? [r, g, b] : [-1.0, -1.0, -1.0];
    } else if (n < 8) {
      const b: number = coordA;
      const r: number = coordB;
      const g: number = (y - r * kR - b * kB) / kG;
      return HctSolver.isBounded(g) ? [r, g, b] : [-1.0, -1.0, -1.0];
    } else {
      const r: number = coordA;
      const g: number = coordB;
      const b: number = (y - r * kR - g * kG) / kB;
      return HctSolver.isBounded(b) ? [r, g, b] : [-1.0, -1.0, -1.0];
    }
  }

  /** 找到包含目标色相的线段。 */
  private static bisectToSegment(y: number, targetHue: number): number[][] {
    let left: number[] = [-1.0, -1.0, -1.0];
    let right: number[] = left;
    let leftHue: number = 0.0;
    let rightHue: number = 0.0;
    let initialized: boolean = false;
    let uncut: boolean = true;
    for (let n = 0; n < 12; n++) {
      const mid: number[] = HctSolver.nthVertex(y, n);
      if (mid[0] < 0) {
        continue;
      }
      const midHue: number = HctSolver.hueOf(mid);
      if (!initialized) {
        left = mid;
        right = mid;
        leftHue = midHue;
        rightHue = midHue;
        initialized = true;
        continue;
      }
      if (uncut || HctSolver.areInCyclicOrder(leftHue, midHue, rightHue)) {
        uncut = false;
        if (HctSolver.areInCyclicOrder(leftHue, targetHue, midHue)) {
          right = mid;
          rightHue = midHue;
        } else {
          left = mid;
          leftHue = midHue;
        }
      }
    }
    return [left, right];
  }

  private static midpoint(a: number[], b: number[]): number[] {
    return [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2];
  }

  private static criticalPlaneBelow(x: number): number {
    return Math.floor(x - 0.5);
  }

  private static criticalPlaneAbove(x: number): number {
    return Math.ceil(x - 0.5);
  }

  /** 在立方体边界上找给定 Y 与色相的线性 RGB。 */
  private static bisectToLimit(y: number, targetHue: number): number[] {
    const segment: number[][] = HctSolver.bisectToSegment(y, targetHue);
    let left: number[] = segment[0];
    let leftHue: number = HctSolver.hueOf(left);
    let right: number[] = segment[1];
    for (let axis = 0; axis < 3; axis++) {
      if (left[axis] !== right[axis]) {
        let lPlane: number = -1;
        let rPlane: number = 255;
        if (left[axis] < right[axis]) {
          lPlane = HctSolver.criticalPlaneBelow(HctSolver.trueDelinearized(left[axis]));
          rPlane = HctSolver.criticalPlaneAbove(HctSolver.trueDelinearized(right[axis]));
        } else {
          lPlane = HctSolver.criticalPlaneAbove(HctSolver.trueDelinearized(left[axis]));
          rPlane = HctSolver.criticalPlaneBelow(HctSolver.trueDelinearized(right[axis]));
        }
        for (let i = 0; i < 8; i++) {
          if (Math.abs(rPlane - lPlane) <= 1) {
            break;
          }
          const mPlane: number = Math.floor((lPlane + rPlane) / 2.0);
          const midPlaneCoordinate: number = HctSolverTables.criticalPlanes[mPlane];
          const mid: number[] = HctSolver.setCoordinate(left, midPlaneCoordinate, right, axis);
          const midHue: number = HctSolver.hueOf(mid);
          if (HctSolver.areInCyclicOrder(leftHue, targetHue, midHue)) {
            right = mid;
            rPlane = mPlane;
          } else {
            left = mid;
            leftHue = midHue;
            lPlane = mPlane;
          }
        }
      }
    }
    return HctSolver.midpoint(left, right);
  }

  private static inverseChromaticAdaptation(adapted: number): number {
    const adaptedAbs: number = Math.abs(adapted);
    const base: number = Math.max(0, 27.13 * adaptedAbs / (400.0 - adaptedAbs));
    return MathUtils.signum(adapted) * Math.pow(base, 1.0 / 0.42);
  }

  /** 给定色相、彩度、Y，用 Newton 迭代求解；失败返回 0。 */
  private static findResultByJ(hueRadians: number, chroma: number, y: number): number {
    let j: number = Math.sqrt(y) * 11.0;
    const viewingConditions: ViewingConditions = ViewingConditions.standard;
    const tInnerCoeff: number = 1 / Math.pow(
      1.64 - Math.pow(0.29, viewingConditions.backgroundYTowhitePointY), 0.73
    );
    const eHue: number = 0.25 * (Math.cos(hueRadians + 2.0) + 3.8);
    const p1: number = eHue * (50000.0 / 13.0) * viewingConditions.nC * viewingConditions.ncb;
    const hSin: number = Math.sin(hueRadians);
    const hCos: number = Math.cos(hueRadians);
    for (let iterationRound = 0; iterationRound < 5; iterationRound++) {
      const jNormalized: number = j / 100.0;
      const alpha: number = (chroma === 0.0 || j === 0.0) ? 0.0 : chroma / Math.sqrt(jNormalized);
      const t: number = Math.pow(alpha * tInnerCoeff, 1.0 / 0.9);
      const ac: number = viewingConditions.aw * Math.pow(
        jNormalized, 1.0 / viewingConditions.c / viewingConditions.z
      );
      const p2: number = ac / viewingConditions.nbb;
      const gamma: number = 23.0 * (p2 + 0.305) * t /
        (23.0 * p1 + 11 * t * hCos + 108.0 * t * hSin);
      const a: number = gamma * hCos;
      const b: number = gamma * hSin;
      const rA: number = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0;
      const gA: number = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0;
      const bA: number = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0;
      const rCScaled: number = HctSolver.inverseChromaticAdaptation(rA);
      const gCScaled: number = HctSolver.inverseChromaticAdaptation(gA);
      const bCScaled: number = HctSolver.inverseChromaticAdaptation(bA);
      const linrgb: number[] = MathUtils.matrixMultiply(
        [rCScaled, gCScaled, bCScaled], HctSolverTables.linrgbFromScaledDiscount
      );
      if (linrgb[0] < 0 || linrgb[1] < 0 || linrgb[2] < 0) {
        return 0;
      }
      const kR: number = HctSolverTables.yFromLinrgb[0];
      const kG: number = HctSolverTables.yFromLinrgb[1];
      const kB: number = HctSolverTables.yFromLinrgb[2];
      const fnj: number = kR * linrgb[0] + kG * linrgb[1] + kB * linrgb[2];
      if (fnj <= 0) {
        return 0;
      }
      if (iterationRound === 4 || Math.abs(fnj - y) < 0.002) {
        if (linrgb[0] > 100.01 || linrgb[1] > 100.01 || linrgb[2] > 100.01) {
          return 0;
        }
        return ColorUtils.argbFromLinrgb(linrgb);
      }
      // Newton 迭代，用 2 * fn(j) / j 近似 fn'(j)
      j = j - (fnj - y) * j / (2 * fnj);
    }
    return 0;
  }

  /** 求 sRGB：尽可能满足给定色相、彩度、明度。 */
  static solveToInt(hueDegrees: number, chroma: number, lstar: number): number {
    if (chroma < 0.0001 || lstar < 0.0001 || lstar > 99.9999) {
      return ColorUtils.argbFromLstar(lstar);
    }
    const hueDegreesSafe: number = MathUtils.sanitizeDegreesDouble(hueDegrees);
    const hueRadians: number = hueDegreesSafe / 180 * Math.PI;
    const y: number = ColorUtils.yFromLstar(lstar);
    const exactAnswer: number = HctSolver.findResultByJ(hueRadians, chroma, y);
    if (exactAnswer !== 0) {
      return exactAnswer;
    }
    const linrgb: number[] = HctSolver.bisectToLimit(y, hueRadians);
    return ColorUtils.argbFromLinrgb(linrgb);
  }

  static solveToCam(hueDegrees: number, chroma: number, lstar: number): Cam16 {
    return Cam16.fromInt(HctSolver.solveToInt(hueDegrees, chroma, lstar));
  }
}
