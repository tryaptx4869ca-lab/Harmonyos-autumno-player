import { AppColorScheme } from './ColorScheme';
import { ThemeManager } from './ThemeManager';

/**
 * 配色令牌（动态版）。
 *
 * 与已废弃的 `AppTheme.ets` 相比，这里的每个值都不是常量，而是
 * 实时从 `ThemeManager` 的当前方案里取——种子色、明暗、OLED 增强一变，
 * 取值立刻跟着变。
 *
 * 用法约定：视图里通过 `@StorageProp('themeRevision')` 订阅版本号，
 * 版本号变化会触发重绘，重绘时读到的就是新颜色。
 */

/** 取当前方案。 */
function scheme(): AppColorScheme {
  return ThemeManager.instance().current();
}

/** ARGB → `#RRGGBB`。 */
function rgb(argb: number): string {
  return '#' + ((argb >>> 0) & 0xFFFFFF).toString(16).toUpperCase().padStart(6, '0');
}

/** ARGB → `#AARRGGBB`（用给定 alpha 覆盖）。 */
function alphaOf(argb: number, alpha: number): string {
  const a: number = Math.round(alpha * 255) & 255;
  const rgbPart: number = (argb >>> 0) & 0xFFFFFF;
  return '#' + ((a << 24 | rgbPart) >>> 0).toString(16).toUpperCase().padStart(8, '0');
}

/** 把 fg 以 alpha 叠在 bg 上，返回 `#RRGGBB`。 */
function blend(bg: number, fg: number, alpha: number): string {
  const b: number = bg & 0xFF;
  const g: number = (bg >>> 8) & 0xFF;
  const r: number = (bg >>> 16) & 0xFF;
  const bf: number = fg & 0xFF;
  const gf: number = (fg >>> 8) & 0xFF;
  const rf: number = (fg >>> 16) & 0xFF;
  const br: number = Math.round(r + (rf - r) * alpha);
  const bg2: number = Math.round(g + (gf - g) * alpha);
  const bb: number = Math.round(b + (bf - b) * alpha);
  return '#' + ((br << 16 | bg2 << 8 | bb) >>> 0).toString(16).toUpperCase().padStart(6, '0');
}

/**
 * 把 fg 以 alpha 叠在 bg 上，返回 **ARGB 数值**。
 *
 * 与 `blend` 的区别：`blend` 直接产出 `#RRGGBB` 字符串，没法再套一层透明度；
 * 需要「先提亮、再指定整体透明度」时用这个（例如玻璃卡的左上高光）。
 */
function blendArgb(bg: number, fg: number, alpha: number): number {
  const b: number = Math.round((bg & 0xFF) + ((fg & 0xFF) - (bg & 0xFF)) * alpha);
  const g: number = Math.round(((bg >>> 8) & 0xFF) +
    (((fg >>> 8) & 0xFF) - ((bg >>> 8) & 0xFF)) * alpha);
  const r: number = Math.round(((bg >>> 16) & 0xFF) +
    (((fg >>> 16) & 0xFF) - ((bg >>> 16) & 0xFF)) * alpha);
  return ((0xFF << 24) | (r << 16) | (g << 8) | b) >>> 0;
}

/** 角色色彩令牌。字段名与旧 `AppColor` 保持一致，便于平滑替换。 */
export class AppColor {
  // ---- 主色族 ----
  static get primary(): string {
    return rgb(scheme().primary);
  }

  static get onPrimary(): string {
    return rgb(scheme().onPrimary);
  }

  static get primaryContainer(): string {
    return rgb(scheme().primaryContainer);
  }

  static get onPrimaryContainer(): string {
    return rgb(scheme().onPrimaryContainer);
  }

  // ---- 次级 / 三级容器 ----
  /** 次级色（进度 HUD 图标胶囊底）。 */
  static get secondary(): string {
    return rgb(scheme().secondary);
  }

  static get onSecondary(): string {
    return rgb(scheme().onSecondary);
  }

  static get secondaryContainer(): string {
    return rgb(scheme().secondaryContainer);
  }

  static get onSecondaryContainer(): string {
    return rgb(scheme().onSecondaryContainer);
  }

  static get tertiaryContainer(): string {
    return rgb(scheme().tertiaryContainer);
  }

  /** 三级容器上的前景色（我的页「离线下载」卡等使用）。 */
  static get onTertiaryContainer(): string {
    return rgb(scheme().onTertiaryContainer);
  }

  /** 三级色（亮度 HUD 图标胶囊底与轨道已填充段）。 */
  static get tertiary(): string {
    return rgb(scheme().tertiary);
  }

  static get onTertiary(): string {
    return rgb(scheme().onTertiary);
  }

  static get error(): string {
    return rgb(scheme().error);
  }

  /** 错误容器底色（§51.2 的滑动删除背景、危险按钮）。 */
  static get errorContainer(): string {
    return rgb(scheme().errorContainer);
  }

  /** 错误容器上的前景色。 */
  static get onErrorContainer(): string {
    return rgb(scheme().onErrorContainer);
  }

  /** 错误色上的前景色（实心危险按钮的文字）。 */
  static get onError(): string {
    return rgb(scheme().onError);
  }

  // ---- 表面族（M3 surfaceContainer 阶梯） ----
  static get surface(): string {
    return rgb(scheme().surface);
  }

  static get surfaceDim(): string {
    return rgb(scheme().surfaceDim);
  }

  static get surfaceContainerLowest(): string {
    return rgb(scheme().surfaceContainerLowest);
  }

  static get surfaceContainerLow(): string {
    return rgb(scheme().surfaceContainerLow);
  }

  static get surfaceContainer(): string {
    return rgb(scheme().surfaceContainer);
  }

  static get surfaceContainerHigh(): string {
    return rgb(scheme().surfaceContainerHigh);
  }

  static get surfaceContainerHighest(): string {
    return rgb(scheme().surfaceContainerHighest);
  }

  static get inverseSurface(): string {
    return rgb(scheme().inverseSurface);
  }

  static get onInverseSurface(): string {
    return rgb(scheme().onInverseSurface);
  }

  // ---- 文字 ----
  static get onSurface(): string {
    return rgb(scheme().onSurface);
  }

  static get onSurfaceVariant(): string {
    return rgb(scheme().onSurfaceVariant);
  }

  static get outline(): string {
    return rgb(scheme().outline);
  }

  static get outlineVariant(): string {
    return rgb(scheme().outlineVariant);
  }

  static get isDark(): boolean {
    return scheme().isDark;
  }

  // ---- 状态层（对应 harmony_tokens.dart 的 HS.pressedLayer / hoverLayer / focusLayer） ----
  /**
   * 按压叠加层：`onSurface` @ 10%（§38.12）。
   *
   * 参照实现刻意**不用 Material 水波纹**——HarmonyOS 的手感是
   * 「表面按下即响应、松手带一点回弹」，叠加层只负责染色，
   * 缩放与圆角由 `HarmonyPressable` / `SplitListRow` 负责。
   */
  static get pressedLayer(): string {
    return alphaOf(scheme().onSurface, 0.10);
  }

  /** 悬停叠加层：`onSurface` @ 8%。 */
  static get hoverLayer(): string {
    return alphaOf(scheme().onSurface, 0.08);
  }

  /** 聚焦叠加层：`onSurface` @ 12%。 */
  static get focusLayer(): string {
    return alphaOf(scheme().onSurface, 0.12);
  }

  /**
   * 把 `#RRGGBB` / `#AARRGGBB` 字符串按给定 alpha 重写。
   *
   * 用途：按压缩放层的颜色是**控件自己的前景色** @ 10%
   * （`my_space_view.dart` 的 `overlayColor`），不是统一的 onSurface，
   * 调用方手上只有颜色字符串，故这里给一个字符串入口。
   */
  static withAlpha(color: string, alpha: number): string {
    const hex: string = color.startsWith('#') ? color.slice(1) : color;
    if (hex.length === 6) {
      return alphaOf(Number.parseInt(hex, 16) | 0xFF000000, alpha);
    }
    if (hex.length === 8) {
      return alphaOf(Number.parseInt(hex, 16) >>> 0, alpha);
    }
    return color;
  }

  /**
   * 把 `fg` 以 `alpha` 混到 `bg` 上（两个颜色都是 `#RRGGBB` / `#AARRGGBB`）。
   *
   * 用途：按压叠加层。参照实现是在卡片上盖一层「前景色 10%」的
   * `InkWell` overlay；底色不透明时与直接把两者混色是同一个结果，
   * 混色只改底色、不新增节点、也不影响子节点。
   */
  static blendWith(bg: string, fg: string, alpha: number): string {
    const bgHex: string = bg.startsWith('#') ? bg.slice(1) : bg;
    const fgHex: string = fg.startsWith('#') ? fg.slice(1) : fg;
    if (bgHex.length < 6 || fgHex.length < 6) {
      return bg;
    }
    const bgArgb: number = (Number.parseInt(bgHex.slice(-6), 16) | 0xFF000000) >>> 0;
    const fgArgb: number = (Number.parseInt(fgHex.slice(-6), 16) | 0xFF000000) >>> 0;
    return blend(bgArgb, fgArgb, alpha);
  }

  // ---- 玻璃层（harmony_controls / 底部导航） ----
  /**
   * 底部导航的**材质染色**。
   *
   * 源码 `immersive_bottom_bar.dart` 是「深色 `0xE62A2A2E` / 浅色 `white @ 0.92`」
   * ——那是不透明底，因为 Flutter 侧也没有真模糊。
   * 2026-09-17 起底栏改用 HarmonyOS 系统材质（`AppMaterial.bar`，
   * 见 `theme/Material.ets`），**模糊由系统做**，这里只留一层染色，
   * 所以透明度必须降下来（92% → 72%），否则材质被盖死、等于没加。
   *
   * 无自定义背景、背后是纯页面底色时观感与 92% 基本一致；
   * 列表内容从底栏下方经过时才会看出差别——那正是「沉浸光感」。
   */
  static get navGlassLight(): string {
    return scheme().isDark ? '#B32A2A2E' : '#B8FFFFFF';
  }

  /** 底部导航描边：深色白 10%，浅色黑 5%。 */
  static get navBorderLight(): string {
    return scheme().isDark ? '#1AFFFFFF' : '#0D000000';
  }

  /** 底部导航投影：黑 28% / 10%，blur 28，offset (0,10)。 */
  static get navShadow(): string {
    return scheme().isDark ? '#47000000' : '#1A000000';
  }

  /**
   * 沉浸光感的「点光源」颜色（HDS `HdsTabsFloatingStyle.lightColor`）。
   *
   * 光源要**亮**才有光感，直接用主题主色（深琥珀 `#8A550F`）会发闷，
   * 所以取主色向白色提亮 45% 再给 90% 透明度。跟着主题走，
   * 9 个预设色与自定义取色都会自动得到同族的暖光。
   */
  static get navLightSource(): string {
    const s: AppColorScheme = scheme();
    const lifted: number = blendArgb(s.primary, 0xFFFFFFFF, 0.45);
    return alphaOf(lifted, 0.90);
  }

  // ---- GlassSurface 规格（bean/widget/glass_surface.dart） ----
  // 2026-09-17：三档填充同步下调透明度，给系统材质（`backgroundBlurStyle`）让位。
  // 原值 66% / 84% / 76% 是「没有真模糊、靠自己调色」时的补偿值，
  // 叠加系统材质后会糊成一块不透明色，所以按下表重校：
  //   card 66% → 52% / nav 84% → 68% / capsule 76% → 62%
  /** card 档填充（材质上的染色）：surface @ 52%（浅）/ 46%（深）。 */
  static get glassCardFill(): string {
    const s: AppColorScheme = scheme();
    return alphaOf(s.surface, s.isDark ? 0.46 : 0.52);
  }

  /**
   * **需要看清文字**的玻璃卡填充：surface @ 82%（浅）/ 76%（深）。
   *
   * 为什么单独一档（用户 2026-09-17 反馈详情页「玻璃太透明、字看不清」）：
   * `glassCardFill` 是按「背景是安静的页面底色」校准的（52%），
   * 但详情页背后是**高斯模糊的海报**——颜色深浅不一、还有云纹，
   * 52% 之下正文的对比度完全不够。
   * 这一档给「浮在图片上、且装正文」的卡片用（详情页概览卡等），
   * 再配 `AppMaterial.cardStrong`（更厚的材质）把背后的杂色压住。
   */
  static get glassCardStrongFill(): string {
    const s: AppColorScheme = scheme();
    return alphaOf(s.surface, s.isDark ? 0.76 : 0.82);
  }

  /**
   * card 档渐变底色（页面底色即 surface）。
   *
   * 原来是**不透明**的 `surface`——渐变末端一不透明，背后再模糊也看不见，
   * 所以这里与 `glassCardFill` 取同一透明度，让整条渐变都能透出材质。
   */
  static get glassCardBase(): string {
    const s: AppColorScheme = scheme();
    return alphaOf(s.surface, s.isDark ? 0.46 : 0.52);
  }

  /** card 档左上高光（白 16% / 6% over 底色，透明度同底色）。 */
  static get glassCardHighlight(): string {
    const s: AppColorScheme = scheme();
    const lifted: number =
      blendArgb(s.surface, 0xFFFFFFFF, s.isDark ? 0.06 : 0.16);
    return alphaOf(lifted, s.isDark ? 0.46 : 0.52);
  }

  /** 描边：onSurface @ 6%（浅）/ 12%（深）。 */
  static get glassBorder(): string {
    const s: AppColorScheme = scheme();
    return alphaOf(s.onSurface, s.isDark ? 0.12 : 0.06);
  }

  /** 左上角白色高光 @ 16%（浅）/ 6%（深）。 */
  static get glassHighlight(): string {
    const s: AppColorScheme = scheme();
    return alphaOf(0xFFFFFFFF, s.isDark ? 0.06 : 0.16);
  }

  /**
   * 播放页强调色：**主题主色向白色提亮后的版本**，专门给压在视频画面上的控件用。
   *
   * 用户 2026-09-18：「进度条包括音量条的颜色可以接那个可以调节的主题色嘛？」
   * 直接用 `primary` 不行：浅色主题下它是深琥珀（#8A550F 那一档），压在底栏黑遮罩
   * 上几乎看不出颜色。这里把主色按主题明暗提亮一档，既跟着 9 个预设主题 /
   * 自定义取色走，又保证在深色画面上可读。
   */
  static get playerAccent(): string {
    const s: AppColorScheme = scheme();
    return rgb(blendArgb(s.primary, 0xFFFFFFFF, s.isDark ? 0.35 : 0.55));
  }

  /** nav 档填充（材质上的染色）：surface @ 68%（浅）/ 60%（深）。 */
  static get glassNavFill(): string {
    const s: AppColorScheme = scheme();
    return alphaOf(s.surface, s.isDark ? 0.60 : 0.68);
  }

  /** capsule 档填充（材质上的染色）：surface @ 62%（浅）/ 54%（深）。 */
  static get glassCapsuleFill(): string {
    const s: AppColorScheme = scheme();
    return alphaOf(s.surface, s.isDark ? 0.54 : 0.62);
  }

  // ---- 胶囊滑杆（设置页 / 设置弹窗里的调节条） ----
  /**
   * 胶囊滑杆的**未选段底色**：`onSurface` @ 40%。
   *
   * 取值对齐参照实现夏绊 `F:\app\...\pages\SettingsView.ets` 的 `trackColor`
   * ——那边用的是 `app.color.text_tertiary`（`#66182431`，即 onSurface 的 40%），
   * 配 32vp 的厚槽：浅色下是一根中灰胶囊、深色下是同一档灰，两端都成立。
   *
   * 用户 2026-09-18：「所有设置页包括弹窗里涉及进度条调整（例如弹幕设置
   * 以及下载设置这种）的可以做成类似夏绊那种调节的胶囊进度条嘛？」
   */
  static get sliderTrack(): string {
    return alphaOf(scheme().onSurface, 0.40);
  }

  /**
   * 胶囊滑杆的滑块：纯白小圆（夏绊 `blockColor('#FFFFFF')`，18vp）。
   *
   * 白块压在灰槽上对比度本就不高，因此绘制时会在它下面垫一圈极淡的投影
   * （见 `HarmonySlider.draw`），否则浅色主题下几乎看不出块停在哪。
   */
  static get sliderBlock(): string {
    return '#FFFFFF';
  }
}

/** 带透明度的主色，用于底部导航选中胶囊。 */
export class AppAlpha {
  /** primary @ 13%（浅）/ 30%（深）。 */
  static get navPillLight(): string {
    const s: AppColorScheme = scheme();
    return alphaOf(s.primary, s.isDark ? 0.30 : 0.13);
  }

  /** 弹窗遮罩：黑 32%。 */
  static get scrim(): string {
    return '#52000000';
  }
}
