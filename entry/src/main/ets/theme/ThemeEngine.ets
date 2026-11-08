import { AppColorScheme, hexToArgb } from './ColorScheme';
import { Hct } from './color/Hct';
import { SchemeTonalSpot } from './color/SchemeTonalSpot';

/** 一个预设主题色。对应源码 `lib/bean/settings/color_type.dart`。 */
export interface ThemePreset {
  readonly argb: number;
  readonly label: string;
  /** 是否为「默认」项（源码里 index == 0 走 resetTheme）。 */
  readonly isDefault: boolean;
  /** 对应的设置值（themeColor 落盘值）。 */
  readonly storageValue: string;
}

/**
 * 主题引擎。
 *
 * 与 Flutter 侧的关系：
 *   `ThemeData(colorSchemeSeed: seed)` → `ColorScheme.fromSeed(seedColor: seed, brightness: b)`
 *   → `DynamicSchemeVariant.tonalSpot` → `SchemeTonalSpot` → `MaterialDynamicColors`
 *
 * 这条链路已经逐值验证（9 个预设 × 明暗两套 × 55 个角色，
 * 与官方 material-color-utilities 完全一致），见 docs/02-工作计划.md。
 */
export class ThemeEngine {
  /** 源码 `lib/utils/constants.dart: defaultThemeSeedColor`。 */
  static readonly defaultSeedArgb: number = 0xFFC98A3C;

  /**
   * 9 个预设。顺序、颜色、文案与源码 `colorThemeTypes` 完全一致。
   * 其中「青色 / 蓝色 / …」来自 Flutter `Colors.*` 的 MaterialColor 基准值。
   */
  static readonly presets: ThemePreset[] = [
    { argb: 0xFFC98A3C, label: '默认', isDefault: true, storageValue: 'default' },
    { argb: 0xFF009688, label: '青色', isDefault: false, storageValue: 'ff009688' },
    { argb: 0xFF2196F3, label: '蓝色', isDefault: false, storageValue: 'ff2196f3' },
    { argb: 0xFF3F51B5, label: '靛蓝色', isDefault: false, storageValue: 'ff3f51b5' },
    { argb: 0xFF6750A4, label: '紫罗兰色', isDefault: false, storageValue: 'ff6750a4' },
    { argb: 0xFFE91E63, label: '粉红色', isDefault: false, storageValue: 'ffe91e63' },
    { argb: 0xFFFFEB3B, label: '黄色', isDefault: false, storageValue: 'ffffeb3b' },
    { argb: 0xFFFF9800, label: '橙色', isDefault: false, storageValue: 'ffff9800' },
    { argb: 0xFFFF5722, label: '深橙色', isDefault: false, storageValue: 'ffff5722' }
  ];

  /** 种子色 → 浅色方案。 */
  static lightOf(seedArgb: number): AppColorScheme {
    return AppColorScheme.fromDynamicScheme(
      new SchemeTonalSpot(Hct.fromInt(seedArgb >>> 0), false, 0.0), false);
  }

  /** 种子色 → 深色方案。 */
  static darkOf(seedArgb: number): AppColorScheme {
    return AppColorScheme.fromDynamicScheme(
      new SchemeTonalSpot(Hct.fromInt(seedArgb >>> 0), true, 0.0), true);
  }

  /**
   * 解析设置里的 `themeColor` 字符串。
   * 源码里存的是 `Color.toARGB32().toRadixString(16)`（无 `#` 前缀的小写十六进制），
   * 默认项存 `'default'`。
   */
  static seedFromSetting(value: string): number {
    const v: string = value.trim();
    if (v.length === 0 || v === 'default') {
      return ThemeEngine.defaultSeedArgb;
    }
    return hexToArgb(v);
  }

  /** 设置值 → 预设项（找不到时返回 undefined）。 */
  static presetOf(storageValue: string): ThemePreset | undefined {
    for (let i = 0; i < ThemeEngine.presets.length; i++) {
      if (ThemeEngine.presets[i].storageValue === storageValue) {
        return ThemeEngine.presets[i];
      }
    }
    return undefined;
  }

  /** 设置值 → 种子色。 */
  static seedOfSetting(value: string): number {
    const preset: ThemePreset | undefined = ThemeEngine.presetOf(value.trim());
    if (preset !== undefined) {
      return preset.argb;
    }
    return ThemeEngine.seedFromSetting(value);
  }
}

/** 原始 RGBA 位图（每像素 4 字节，顺序 R,G,B,A）。 */
export class RgbaImage {
  readonly pixels: Uint8Array;
  readonly width: number;
  readonly height: number;

  constructor(pixels: Uint8Array, width: number, height: number) {
    this.pixels = pixels;
    this.width = width;
    this.height = height;
  }
}

/**
 * 背景图取色。
 *
 * 逐行对应源码 `theme_settings_page.dart: _extractBackgroundSeed`：
 *
 * 1. `img.decodeImage(bytes)`
 * 2. `img.copyResize(decoded, width: 24)` —— image 4.9.2 的 `copyResize`
 *    默认插值是 **nearest**（见 copy_resize.dart 第 23 行），
 *    采样坐标 `x * srcW ~/ 24`、`y * srcH ~/ newH`；缩放高度为
 *    `(24 * srcH / srcW).round()`；
 *    另外 `copyResize` 会先 `bakeOrientation`，所以 EXIF 方向必须先烘焙。
 * 3. 遍历 24 宽的小图，跳过亮度 <28 或 >226 的像素，
 *    对剩下的像素求 R/G/B 均值（整数除法），并强制 alpha=255。
 *
 * 之所以要 1:1 复刻这三步，是因为种子色决定了整套 ColorScheme，
 * 任何一处偏差都会让主色与 Flutter 版对不上。
 */
export class BackgroundSeedExtractor {
  /** 与源码一致的分辨率阈值。 */
  private static readonly TARGET_WIDTH: number = 24;
  private static readonly MIN_LUMINANCE: number = 28;
  private static readonly MAX_LUMINANCE: number = 226;

  /**
   * @param image 已解码的整幅 RGBA 位图
   * @param orientation EXIF 方向（1-8，1 或不传表示无需处理）
   * @returns ARGB；无有效像素时返回 0（与源码一致）
   */
  static extract(image: RgbaImage, orientation: number): number {
    const baked: RgbaImage = BackgroundSeedExtractor.bakeOrientation(image, orientation);
    const small: RgbaImage = BackgroundSeedExtractor.resizeNearest(baked,
      BackgroundSeedExtractor.TARGET_WIDTH);

    let r: number = 0;
    let g: number = 0;
    let b: number = 0;
    let count: number = 0;
    const px: Uint8Array = small.pixels;
    const total: number = small.width * small.height;
    for (let i = 0; i < total; i++) {
      const o: number = i * 4;
      const pr: number = px[o];
      const pg: number = px[o + 1];
      const pb: number = px[o + 2];
      const luminance: number = 0.2126 * pr + 0.7152 * pg + 0.0722 * pb;
      if (luminance < BackgroundSeedExtractor.MIN_LUMINANCE ||
        luminance > BackgroundSeedExtractor.MAX_LUMINANCE) {
        continue;
      }
      r += pr;
      g += pg;
      b += pb;
      count++;
    }
    if (count === 0) {
      return 0;
    }
    return ((0xFF << 24) | ((Math.floor(r / count) & 255) << 16) |
      ((Math.floor(g / count) & 255) << 8) | (Math.floor(b / count) & 255)) >>> 0;
  }

  /**
   * 复刻 image 包的 `bakeOrientation` + `copyResize(width: 24)`。
   * 目标高度用 round（远离零方向），与 Dart 的 `num.round()` 一致。
   */
  private static resizeNearest(src: RgbaImage, targetWidth: number): RgbaImage {
    const w: number = targetWidth;
    const h: number = Math.round(targetWidth * (src.height / src.width));
    const out: Uint8Array = new Uint8Array(w * h * 4);
    const scaleX: Int32Array = new Int32Array(w);
    const scaleY: Int32Array = new Int32Array(h);
    for (let x = 0; x < w; x++) {
      scaleX[x] = Math.floor((x * src.width) / w);
    }
    for (let y = 0; y < h; y++) {
      scaleY[y] = Math.floor((y * src.height) / h);
    }
    for (let y = 0; y < h; y++) {
      const sy: number = scaleY[y];
      for (let x = 0; x < w; x++) {
        const so: number = (sy * src.width + scaleX[x]) * 4;
        const dst: number = (y * w + x) * 4;
        out[dst] = src.pixels[so];
        out[dst + 1] = src.pixels[so + 1];
        out[dst + 2] = src.pixels[so + 2];
        out[dst + 3] = src.pixels[so + 3];
      }
    }
    return new RgbaImage(out, w, h);
  }

  /**
   * 复刻 image 包的 `bakeOrientation`。
   * 2 水平镜像 / 3 旋转 180 / 4 垂直镜像 / 5 转置 /
   * 6 顺时针 90 / 7 副对角线 / 8 逆时针 90。
   */
  private static bakeOrientation(src: RgbaImage, orientation: number): RgbaImage {
    if (orientation <= 1 || orientation > 8) {
      return src;
    }
    const w: number = src.width;
    const h: number = src.height;
    if (orientation === 2) {
      return BackgroundSeedExtractor.flipHorizontal(src);
    }
    if (orientation === 3) {
      return BackgroundSeedExtractor.flipHorizontal(BackgroundSeedExtractor.flipVertical(src));
    }
    if (orientation === 4) {
      return BackgroundSeedExtractor.flipVertical(src);
    }
    if (orientation === 5) {
      // flipHorizontal(rotate90)
      return BackgroundSeedExtractor.flipHorizontal(BackgroundSeedExtractor.rotate90(src));
    }
    if (orientation === 6) {
      return BackgroundSeedExtractor.rotate90(src);
    }
    if (orientation === 7) {
      // flipHorizontal(rotate270)
      return BackgroundSeedExtractor.flipHorizontal(BackgroundSeedExtractor.rotate270(src));
    }
    return BackgroundSeedExtractor.rotate270(src);
  }

  /** dst(x,y) = src(w-1-x, y) */
  private static flipHorizontal(src: RgbaImage): RgbaImage {
    const w: number = src.width;
    const h: number = src.height;
    const out: Uint8Array = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const so: number = (y * w + (w - 1 - x)) * 4;
        const dst: number = (y * w + x) * 4;
        out[dst] = src.pixels[so];
        out[dst + 1] = src.pixels[so + 1];
        out[dst + 2] = src.pixels[so + 2];
        out[dst + 3] = src.pixels[so + 3];
      }
    }
    return new RgbaImage(out, w, h);
  }

  /** dst(x,y) = src(x, h-1-y) */
  private static flipVertical(src: RgbaImage): RgbaImage {
    const w: number = src.width;
    const h: number = src.height;
    const out: Uint8Array = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const so: number = ((h - 1 - y) * w + x) * 4;
        const dst: number = (y * w + x) * 4;
        out[dst] = src.pixels[so];
        out[dst + 1] = src.pixels[so + 1];
        out[dst + 2] = src.pixels[so + 2];
        out[dst + 3] = src.pixels[so + 3];
      }
    }
    return new RgbaImage(out, w, h);
  }

  /** image 包 `_rotate90`：dst(x,y) = src(y, h-1-x)，尺寸变为 h×w。 */
  private static rotate90(src: RgbaImage): RgbaImage {
    const w: number = src.width;
    const h: number = src.height;
    const out: Uint8Array = new Uint8Array(w * h * 4);
    for (let y = 0; y < w; y++) {
      for (let x = 0; x < h; x++) {
        const so: number = ((h - 1 - x) * w + y) * 4;
        const dst: number = (y * h + x) * 4;
        out[dst] = src.pixels[so];
        out[dst + 1] = src.pixels[so + 1];
        out[dst + 2] = src.pixels[so + 2];
        out[dst + 3] = src.pixels[so + 3];
      }
    }
    return new RgbaImage(out, h, w);
  }

  /** image 包 `_rotate270`：dst(x,y) = src(w-1-y, x)，尺寸变为 h×w。 */
  private static rotate270(src: RgbaImage): RgbaImage {
    const w: number = src.width;
    const h: number = src.height;
    const out: Uint8Array = new Uint8Array(w * h * 4);
    for (let y = 0; y < w; y++) {
      for (let x = 0; x < h; x++) {
        const so: number = (x * w + (w - 1 - y)) * 4;
        const dst: number = (y * h + x) * 4;
        out[dst] = src.pixels[so];
        out[dst + 1] = src.pixels[so + 1];
        out[dst + 2] = src.pixels[so + 2];
        out[dst + 3] = src.pixels[so + 3];
      }
    }
    return new RgbaImage(out, h, w);
  }
}
