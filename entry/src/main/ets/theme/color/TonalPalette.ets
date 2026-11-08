import { Hct } from './Hct';

/**
 * 色调色板：色相与彩度固定、只有明度（tone）变化的色带。
 * 移植自 material_color_utilities/lib/palettes/tonal_palette.dart 0.13.0。
 *
 * 与上游的差别只有一处（行为等价、仅为提速）：
 * 上游在构造时立刻算出 keyColor，而 keyColor 只在
 * `*PaletteKeyColor` 这几个角色里用到（本应用不使用），
 * 因此这里改为惰性求值，避免每个色板都做一次二分搜索。
 */
export class TonalPalette {
  /** 常用 tone 值。 */
  static readonly commonTones: number[] = [
    0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 99, 100
  ];

  readonly hue: number;
  readonly chroma: number;

  /** tone -> argb 缓存（上游 `_cache` 的等价物）。 */
  private cache: Map<number, number> = new Map<number, number>();
  private keyColorCache: Hct | null = null;

  private constructor(hue: number, chroma: number) {
    this.hue = hue;
    this.chroma = chroma;
  }

  /** 由色相与彩度构造。 */
  static of(hue: number, chroma: number): TonalPalette {
    return new TonalPalette(hue, chroma);
  }

  /** 由 HCT 的色相与彩度构造。 */
  static fromHct(hct: Hct): TonalPalette {
    return new TonalPalette(hct.hue, hct.chroma);
  }

  /** 指定 tone 的 ARGB。 */
  get(tone: number): number {
    const cached: number | undefined = this.cache.get(tone);
    if (cached !== undefined) {
      return cached;
    }
    const argb: number = Hct.from(this.hue, this.chroma, tone).toInt();
    this.cache.set(tone, argb);
    return argb;
  }

  /** 指定 tone 的 HCT。 */
  getHct(tone: number): Hct {
    const cached: number | undefined = this.cache.get(tone);
    if (cached !== undefined) {
      return Hct.fromInt(cached);
    }
    return Hct.from(this.hue, this.chroma, tone);
  }

  /** 该色板的代表色（key color）。 */
  keyColor(): Hct {
    if (this.keyColorCache === null) {
      this.keyColorCache = new KeyColor(this.hue, this.chroma).create();
    }
    return this.keyColorCache;
  }
}

/**
 * 代表色：从 T50 起向两侧寻找第一个能容纳请求彩度的 tone。
 * 移植自上游同文件的 KeyColor 类。
 */
export class KeyColor {
  private readonly hue: number;
  private readonly requestedChroma: number;
  /** (tone) -> 该 tone 下能达到的最大彩度。 */
  private readonly chromaCache: Map<number, number> = new Map<number, number>();
  private readonly maxChromaValue: number = 200.0;

  constructor(hue: number, requestedChroma: number) {
    this.hue = hue;
    this.requestedChroma = requestedChroma;
  }

  create(): Hct {
    const pivotTone: number = 50;
    const toneStepSize: number = 1;
    const epsilon: number = 0.01;

    let lowerTone: number = 0;
    let upperTone: number = 100;
    while (lowerTone < upperTone) {
      const midTone: number = Math.floor((lowerTone + upperTone) / 2);
      const isAscending: boolean =
        this.maxChroma(midTone) < this.maxChroma(midTone + toneStepSize);
      const sufficientChroma: boolean =
        this.maxChroma(midTone) >= this.requestedChroma - epsilon;

      if (sufficientChroma) {
        if (Math.abs(lowerTone - pivotTone) < Math.abs(upperTone - pivotTone)) {
          upperTone = midTone;
        } else {
          if (lowerTone === midTone) {
            return Hct.from(this.hue, this.requestedChroma, lowerTone);
          }
          lowerTone = midTone;
        }
      } else {
        if (isAscending) {
          lowerTone = midTone + toneStepSize;
        } else {
          upperTone = midTone;
        }
      }
    }
    return Hct.from(this.hue, this.requestedChroma, lowerTone);
  }

  private maxChroma(tone: number): number {
    const cached: number | undefined = this.chromaCache.get(tone);
    if (cached !== undefined) {
      return cached;
    }
    const value: number = Hct.from(this.hue, this.maxChromaValue, tone).chroma;
    this.chromaCache.set(tone, value);
    return value;
  }
}
