/** 数学工具。移植自 material_color_utilities/lib/utils/math_utils.dart。 */
export class MathUtils {
  /** 符号函数：正数 1，负数 -1，零 0。 */
  static signum(num: number): number {
    if (num < 0) {
      return -1;
    } else if (num === 0) {
      return 0;
    }
    return 1;
  }

  static lerp(start: number, stop: number, amount: number): number {
    return (1.0 - amount) * start + amount * stop;
  }

  static clampInt(min: number, max: number, input: number): number {
    if (input < min) {
      return min;
    } else if (input > max) {
      return max;
    }
    return input;
  }

  static clampDouble(min: number, max: number, input: number): number {
    if (input < min) {
      return min;
    } else if (input > max) {
      return max;
    }
    return input;
  }

  /** 把角度规整到 [0, 360)。 */
  static sanitizeDegreesDouble(degrees: number): number {
    let d: number = degrees % 360.0;
    if (d < 0) {
      d = d + 360.0;
    }
    return d;
  }

  /** 1x3 行向量乘 3x3 矩阵。 */
  static matrixMultiply(row: number[], matrix: number[][]): number[] {
    const a: number =
      row[0] * matrix[0][0] + row[1] * matrix[0][1] + row[2] * matrix[0][2];
    const b: number =
      row[0] * matrix[1][0] + row[1] * matrix[1][1] + row[2] * matrix[1][2];
    const c: number =
      row[0] * matrix[2][0] + row[1] * matrix[2][1] + row[2] * matrix[2][2];
    return [a, b, c];
  }
}
