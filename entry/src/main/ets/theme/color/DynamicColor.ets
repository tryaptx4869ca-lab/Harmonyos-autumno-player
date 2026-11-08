import { Contrast } from './Contrast';
import { DynamicScheme, Variant } from './DynamicScheme';
import { Hct } from './Hct';
import { MathUtils } from './MathUtils';
import { TonalPalette } from './TonalPalette';

/** 对比度曲线：分别对应对比度等级 -1.0 / 0.0 / 0.5 / 1.0。 */
export class ContrastCurve {
  readonly low: number;
  readonly normal: number;
  readonly medium: number;
  readonly high: number;

  constructor(low: number, normal: number, medium: number, high: number) {
    this.low = low;
    this.normal = normal;
    this.medium = medium;
    this.high = high;
  }

  get(contrastLevel: number): number {
    if (contrastLevel <= -1.0) {
      return this.low;
    } else if (contrastLevel < 0.0) {
      return MathUtils.lerp(this.low, this.normal, (contrastLevel - (-1)) / 1);
    } else if (contrastLevel < 0.5) {
      return MathUtils.lerp(this.normal, this.medium, (contrastLevel - 0) / 0.5);
    } else if (contrastLevel < 1.0) {
      return MathUtils.lerp(this.medium, this.high, (contrastLevel - 0.5) / 0.5);
    }
    return this.high;
  }
}

/** 两个角色之间的色调距离极性。 */
export enum TonePolarity {
  darker,
  lighter,
  nearer,
  farther
}

/**
 * 两个动态颜色之间的色调距离约束。
 * 上游：material_color_utilities/lib/dynamiccolor/src/tone_delta_pair.dart。
 */
export class ToneDeltaPair {
  readonly roleA: DynamicColor;
  readonly roleB: DynamicColor;
  readonly delta: number;
  readonly polarity: TonePolarity;
  readonly stayTogether: boolean;

  constructor(roleA: DynamicColor, roleB: DynamicColor, delta: number,
    polarity: TonePolarity, stayTogether: boolean) {
    this.roleA = roleA;
    this.roleB = roleB;
    this.delta = delta;
    this.polarity = polarity;
    this.stayTogether = stayTogether;
  }
}

export type PaletteFn = (scheme: DynamicScheme) => TonalPalette;
export type ToneFn = (scheme: DynamicScheme) => number;
export type ColorFn = (scheme: DynamicScheme) => DynamicColor;
export type ToneDeltaPairFn = (scheme: DynamicScheme) => ToneDeltaPair;

/** DynamicColor 的构造参数，除 palette / tone 外均可省略。 */
export interface DynamicColorOptions {
  name?: string;
  palette: PaletteFn;
  tone: ToneFn;
  isBackground?: boolean;
  background?: ColorFn;
  secondBackground?: ColorFn;
  contrastCurve?: ContrastCurve;
  toneDeltaPair?: ToneDeltaPairFn;
}

/**
 * 动态颜色：由 DynamicScheme 决定最终 tone，
 * 必要时根据背景色与对比度曲线做微调。
 * 移植自 material_color_utilities/lib/dynamiccolor/dynamic_color.dart 0.13.0。
 */
export class DynamicColor {
  readonly name: string;
  readonly palette: PaletteFn;
  readonly tone: ToneFn;
  readonly isBackground: boolean;
  readonly background: ColorFn | undefined;
  readonly secondBackground: ColorFn | undefined;
  readonly contrastCurve: ContrastCurve | undefined;
  readonly toneDeltaPair: ToneDeltaPairFn | undefined;

  constructor(options: DynamicColorOptions) {
    this.name = options.name ?? '';
    this.palette = options.palette;
    this.tone = options.tone;
    this.isBackground = options.isBackground ?? false;
    this.background = options.background;
    this.secondBackground = options.secondBackground;
    this.contrastCurve = options.contrastCurve;
    this.toneDeltaPair = options.toneDeltaPair;
  }

  static fromPalette(options: DynamicColorOptions): DynamicColor {
    return new DynamicColor(options);
  }

  /** 该角色在此方案下的 ARGB。 */
  getArgb(scheme: DynamicScheme): number {
    return this.palette(scheme).get(this.getTone(scheme));
  }

  /** 该角色在此方案下的 HCT。 */
  getHct(scheme: DynamicScheme): Hct {
    return this.palette(scheme).getHct(this.getTone(scheme));
  }

  /** 该角色在此方案下解析出的 tone。 */
  getTone(scheme: DynamicScheme): number {
    const decreasingContrast: boolean = scheme.contrastLevel < 0;

    // 情况 1：成对角色，两者之间有最小色调距离约束。
    if (this.toneDeltaPair !== undefined && this.background !== undefined) {
      const pair: ToneDeltaPair = this.toneDeltaPair(scheme);
      const roleA: DynamicColor = pair.roleA;
      const roleB: DynamicColor = pair.roleB;
      const delta: number = pair.delta;
      const polarity: TonePolarity = pair.polarity;
      const stayTogether: boolean = pair.stayTogether;

      const bg: DynamicColor = this.background(scheme);
      const bgTone: number = bg.getTone(scheme);

      const aIsNearer: boolean = polarity === TonePolarity.nearer ||
        (polarity === TonePolarity.lighter && !scheme.isDark) ||
        (polarity === TonePolarity.darker && scheme.isDark);
      const nearer: DynamicColor = aIsNearer ? roleA : roleB;
      const farther: DynamicColor = aIsNearer ? roleB : roleA;
      const amNearer: boolean = this.name === nearer.name;
      const expansionDir: number = scheme.isDark ? 1 : -1;

      // 第一轮：各自先求满足对比度的最小移动量。
      const nContrast: number = DynamicColor.curveOf(nearer).get(scheme.contrastLevel);
      const fContrast: number = DynamicColor.curveOf(farther).get(scheme.contrastLevel);

      const nInitialTone: number = nearer.tone(scheme);
      let nTone: number = Contrast.ratioOfTones(bgTone, nInitialTone) >= nContrast
        ? nInitialTone : DynamicColor.foregroundTone(bgTone, nContrast);
      const fInitialTone: number = farther.tone(scheme);
      let fTone: number = Contrast.ratioOfTones(bgTone, fInitialTone) >= fContrast
        ? fInitialTone : DynamicColor.foregroundTone(bgTone, fContrast);

      if (decreasingContrast) {
        nTone = DynamicColor.foregroundTone(bgTone, nContrast);
        fTone = DynamicColor.foregroundTone(bgTone, fContrast);
      }

      if ((fTone - nTone) * expansionDir >= delta) {
        // 已经满足距离约束，不用动。
      } else {
        // 第二轮：把 farther 推开以凑够 delta。
        fTone = MathUtils.clampDouble(0, 100, nTone + delta * expansionDir);
        if ((fTone - nTone) * expansionDir >= delta) {
          // 满足，不用继续。
        } else {
          // 第三轮：把 nearer 收回来凑够 delta。
          nTone = MathUtils.clampDouble(0, 100, fTone - delta * expansionDir);
        }
      }

      // 避开 50-59 这个尴尬区间。
      if (50 <= nTone && nTone < 60) {
        if (expansionDir > 0) {
          nTone = 60;
          fTone = Math.max(fTone, nTone + delta * expansionDir);
        } else {
          nTone = 49;
          fTone = Math.min(fTone, nTone + delta * expansionDir);
        }
      } else if (50 <= fTone && fTone < 60) {
        if (stayTogether) {
          if (expansionDir > 0) {
            nTone = 60;
            fTone = Math.max(fTone, nTone + delta * expansionDir);
          } else {
            nTone = 49;
            fTone = Math.min(fTone, nTone + delta * expansionDir);
          }
        } else {
          if (expansionDir > 0) {
            fTone = 60;
          } else {
            fTone = 49;
          }
        }
      }

      return amNearer ? nTone : fTone;
    }

    // 情况 2：没有成对约束，只解自己。
    let answer: number = this.tone(scheme);

    if (this.background === undefined) {
      return answer; // 没有背景色的角色不做调整。
    }

    const bgTone: number = this.background(scheme).getTone(scheme);
    const desiredRatio: number = DynamicColor.curveOf(this).get(scheme.contrastLevel);

    if (Contrast.ratioOfTones(bgTone, answer) >= desiredRatio) {
      // 已经够对比度，不要「画蛇添足」。
    } else {
      answer = DynamicColor.foregroundTone(bgTone, desiredRatio);
    }

    if (decreasingContrast) {
      answer = DynamicColor.foregroundTone(bgTone, desiredRatio);
    }

    if (this.isBackground && 50 <= answer && answer < 60) {
      if (Contrast.ratioOfTones(49, bgTone) >= desiredRatio) {
        answer = 49;
      } else {
        answer = 60;
      }
    }

    if (this.secondBackground !== undefined) {
      // 情况 3：同时受两个背景约束。
      const bgTone1: number = this.background(scheme).getTone(scheme);
      const bgTone2: number = this.secondBackground(scheme).getTone(scheme);
      const upper: number = Math.max(bgTone1, bgTone2);
      const lower: number = Math.min(bgTone1, bgTone2);

      if (Contrast.ratioOfTones(upper, answer) >= desiredRatio &&
        Contrast.ratioOfTones(lower, answer) >= desiredRatio) {
        return answer;
      }

      const lightOption: number = Contrast.lighter(upper, desiredRatio);
      const darkOption: number = Contrast.darker(lower, desiredRatio);

      const availables: number[] = [];
      if (lightOption !== -1) {
        availables.push(lightOption);
      }
      if (darkOption !== -1) {
        availables.push(darkOption);
      }

      const prefersLight: boolean =
        DynamicColor.tonePrefersLightForeground(bgTone1) ||
        DynamicColor.tonePrefersLightForeground(bgTone2);
      if (prefersLight) {
        return lightOption < 0 ? 100 : lightOption;
      }
      if (availables.length === 1) {
        return availables[0];
      }
      return darkOption < 0 ? 0 : darkOption;
    }

    return answer;
  }

  /** 取角色的对比度曲线；上游此处直接断言非空。 */
  private static curveOf(color: DynamicColor): ContrastCurve {
    const curve: ContrastCurve | undefined = color.contrastCurve;
    if (curve === undefined) {
      throw new Error('missing contrastCurve for ' + color.name);
    }
    return curve;
  }

  /**
   * 已知背景 tone，求一个尽可能接近 ratio 的前景 tone。
   */
  static foregroundTone(bgTone: number, ratio: number): number {
    const lighterTone: number = Contrast.lighterUnsafe(bgTone, ratio);
    const darkerTone: number = Contrast.darkerUnsafe(bgTone, ratio);
    const lighterRatio: number = Contrast.ratioOfTones(lighterTone, bgTone);
    const darkerRatio: number = Contrast.ratioOfTones(darkerTone, bgTone);
    const preferLighter: boolean = DynamicColor.tonePrefersLightForeground(bgTone);

    if (preferLighter) {
      // 处理初始对比度已经很高（例如 13.0）而目标 ratio 同样高，
      // 导致变亮变暗都达不到目标的情形（例如 Tonal Spot 的
      // On Primary Container 在浅色模式高对比度下会闪黑）。
      const negligibleDifference: boolean =
        Math.abs(lighterRatio - darkerRatio) < 0.1 &&
        lighterRatio < ratio && darkerRatio < ratio;
      return lighterRatio >= ratio || lighterRatio >= darkerRatio || negligibleDifference
        ? lighterTone : darkerTone;
    }
    return darkerRatio >= ratio || darkerRatio >= lighterRatio ? darkerTone : lighterTone;
  }

  /** 若 tone 附近更适合浅色前景，则把 tone 压到 49。 */
  static enableLightForeground(tone: number): number {
    if (DynamicColor.tonePrefersLightForeground(tone) &&
      !DynamicColor.toneAllowsLightForeground(tone)) {
      return 49.0;
    }
    return tone;
  }

  /** tone 是否更偏好浅色前景。 */
  static tonePrefersLightForeground(tone: number): boolean {
    return Math.round(tone) < 60;
  }

  /** tone 能否与更浅的颜色形成 4.5 对比度。 */
  static toneAllowsLightForeground(tone: number): boolean {
    return Math.round(tone) <= 49;
  }
}

/** 上游的 `_isFidelity`。 */
export function isFidelity(scheme: DynamicScheme): boolean {
  return scheme.variant === Variant.fidelity || scheme.variant === Variant.content;
}

/** 上游的 `_isMonochrome`。 */
export function isMonochrome(scheme: DynamicScheme): boolean {
  return scheme.variant === Variant.monochrome;
}
