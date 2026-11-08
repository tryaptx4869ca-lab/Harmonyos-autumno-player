import { Cam16 } from './Cam16';
import { ColorUtils } from './ColorUtils';
import { HctSolver } from './HctSolver';
import { ViewingConditions } from './ViewingConditions';

/**
 * HCT：色相（Hue）、彩度（Chroma）、明度（Tone）。
 * 移植自 material_color_utilities/lib/hct/hct.dart 0.13.0。
 *
 * 注意：HCT 的 hue/chroma 与 sRGB 之间不是双射，
 * 由 argb 反算出的 hue/chroma 可能与构造时传入的不同（会被裁剪到色域内）。
 */
export class Hct {
  private _hue: number;
  private _chroma: number;
  private _tone: number;
  private _argb: number;

  private constructor(argb: number) {
    this._argb = argb;
    const cam16: Cam16 = Cam16.fromInt(argb);
    this._hue = cam16.hue;
    this._chroma = cam16.chroma;
    this._tone = ColorUtils.lstarFromArgb(argb);
  }

  /** 由 HCT 求 sRGB（超出色域时保留色相与明度、最大化彩度）。 */
  static from(hue: number, chroma: number, tone: number): Hct {
    const argb: number = HctSolver.solveToInt(hue, chroma, tone);
    return new Hct(argb);
  }

  static fromInt(argb: number): Hct {
    return new Hct(argb);
  }

  toInt(): number {
    return this._argb;
  }

  get hue(): number {
    return this._hue;
  }

  get chroma(): number {
    return this._chroma;
  }

  get tone(): number {
    return this._tone;
  }

  toString(): string {
    return `H${Math.round(this._hue)} C${Math.round(this._chroma)} T${Math.round(this._tone)}`;
  }
}
