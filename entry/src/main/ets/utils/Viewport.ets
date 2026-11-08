import { display } from '@kit.ArkUI';

/**
 * 视口宽度与断点。
 *
 * 为什么要用「实测宽度」而不是 `display.getDefaultDisplaySync()`：
 * 横屏 / 平板 / PC 上，四个 Tab 的内容区左侧还有 88vp 的导航栏，
 * 用整屏宽算列数会让卡片超出可用宽度（实测：宽屏分支下第三列被裁掉）。
 * 因此各页统一在根容器上 `onAreaChange` 取实测宽，取不到再退回整屏。
 *
 * 断点沿用 Material 3 的窗口尺寸类别（§4.6 的 compact / medium / expanded）。
 */
export class Viewport {
  /** compact 上限（< 600 走 3 列）。 */
  static readonly compactMax: number = 600;
  /** medium 上限（600~840 走 5 列）。 */
  static readonly mediumMax: number = 840;

  /** 实测宽优先；未测量时用整屏宽兜底。 */
  static widthVp(measured: number): number {
    if (measured > 0) {
      return measured;
    }
    try {
      const info = display.getDefaultDisplaySync();
      return info.width / info.densityPixels;
    } catch (e) {
      return 360;
    }
  }

  static heightVp(): number {
    try {
      const info = display.getDefaultDisplaySync();
      return info.height / info.densityPixels;
    } catch (e) {
      return 780;
    }
  }

  static isCompact(width: number): boolean {
    return width < Viewport.compactMax;
  }

  static isMedium(width: number): boolean {
    return width >= Viewport.compactMax && width < Viewport.mediumMax;
  }

  static isExpanded(width: number): boolean {
    return width >= Viewport.mediumMax;
  }

  /** 网格列数（规格 §4.6）：compact 3 / medium 5 / expanded 6。 */
  static gridColumns(width: number): number {
    if (Viewport.isExpanded(width)) {
      return 6;
    }
    if (Viewport.isMedium(width)) {
      return 5;
    }
    return 3;
  }
}
