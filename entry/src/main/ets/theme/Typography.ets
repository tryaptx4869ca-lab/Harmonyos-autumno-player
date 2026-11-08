/**
 * 文字令牌。
 *
 * 取自参照实现 lib/bean/theme/harmony_tokens.dart 的 `harmonyTextTheme`，
 * 是项目自定义的字号阶梯（不是 Material 默认值）：
 *
 *   displaySmall    30 / w600 / 1.25
 *   headlineMedium  24 / w600 / 1.30
 *   headlineSmall   20 / w600 / 1.35
 *   titleLarge      20 / w600 / 1.35
 *   titleMedium     16 / w600 / 1.40
 *   titleSmall      14 / w600 / 1.40
 *   bodyLarge       16 / w400 / 1.50
 *   bodyMedium      14 / w400 / 1.50
 *   bodySmall       12 / w400 / 1.40
 *   labelLarge      14 / w600 / 1.30
 *   labelMedium     12 / w500 / 1.30
 *   labelSmall      10 / w500 / 1.30
 *
 * 全部 letterSpacing 0.2。ArkUI 的 lineHeight 是绝对长度，故按 字号 × 行高 预计算。
 */
export class TS {
  // ---- displaySmall ----
  static readonly displaySmallSize: number = 30;
  static readonly displaySmallLine: number = 38;

  // ---- headlineMedium ----
  static readonly headlineMediumSize: number = 24;
  static readonly headlineMediumLine: number = 31;

  // ---- headlineSmall ----
  static readonly headlineSmallSize: number = 20;
  static readonly headlineSmallLine: number = 27;

  // ---- titleLarge ----
  static readonly titleLargeSize: number = 20;
  static readonly titleLargeLine: number = 27;

  // ---- titleMedium ----
  static readonly titleMediumSize: number = 16;
  static readonly titleMediumLine: number = 22;

  // ---- titleSmall ----
  static readonly titleSmallSize: number = 14;
  static readonly titleSmallLine: number = 20;

  // ---- bodyLarge ----
  static readonly bodyLargeSize: number = 16;
  static readonly bodyLargeLine: number = 24;

  // ---- bodyMedium ----
  static readonly bodyMediumSize: number = 14;
  static readonly bodyMediumLine: number = 21;

  // ---- bodySmall ----
  static readonly bodySmallSize: number = 12;
  static readonly bodySmallLine: number = 17;

  // ---- labelLarge ----
  static readonly labelLargeSize: number = 14;
  static readonly labelLargeLine: number = 18;

  // ---- labelMedium ----
  static readonly labelMediumSize: number = 12;
  static readonly labelMediumLine: number = 16;

  // ---- labelSmall ----
  static readonly labelSmallSize: number = 10;
  static readonly labelSmallLine: number = 13;

  /** 全局 letterSpacing */
  static readonly ls: number = 0.2;

  // ---- 字重（ArkTS 用数值） ----
  static readonly w400: number = 400;
  static readonly w500: number = 500;
  static readonly w600: number = 600;
  static readonly w700: number = 700;
}
