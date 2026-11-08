/**
 * HarmonyOS 系统材质（沉浸光感）。
 *
 * 背景：界面上那些「玻璃」原来是**手调透明度 + 左上白高光**模拟出来的，
 * 背后有内容时并不会真的模糊——观感是「半透明色块」，不是 HarmonyOS 的材质。
 * ArkUI 的系统材质入口是通用属性 `backgroundBlurStyle(style, options)`：
 * 由渲染框架取**组件背后**的画面做模糊，再叠系统给的色调，
 * 这才是系统应用（设置、负一屏、应用市场）里那种「沉浸光感」底栏。
 *
 * 三档对应关系（沿用本项目已有的三档语义，不新增概念）：
 *
 * | 档位 | 用在哪 | 材质 |
 * | --- | --- | --- |
 * | `bar` | 底部导航胶囊、宽屏侧边导航栏 | `COMPONENT_ULTRA_THICK` |
 * | `capsule` | 悬浮胶囊（二级页返回圆钮、时间表头部两个胶囊、回到顶部、我的页设置胶囊） | `COMPONENT_THICK` |
 * | `card` | 时间表日期条（悬浮层） | `COMPONENT_REGULAR` |
 *
 * **加材质的判据（重要）**：`backgroundBlurStyle` 模糊的是**组件背后**，
 * 所以只有「**背后压着别的内容**」的控件才该用它：
 *
 *   - 悬浮在滚动列表之上的导航条 / 悬浮胶囊 / 日期条 → 用；
 *   - 列表里的卡片（番剧卡、收藏卡、今日一句、设置卡…）→ **不用**。
 *     页面底色是不透明平面，卡片背后没有任何东西，模糊结果与纯色底完全一样，
 *     却要每帧重算——纯属白付代价（2026-09-17 用户反馈发现页卡顿后按此收敛）。
 *     若日后做了「背景氛围色模糊大图」或用户设了自定义背景图，
 *     这些卡片想重新开材质的话，在原处补一行 `.backgroundBlurStyle(...)` 即可。
 *
 * `options` 的两项都是刻意的：
 *   - `colorMode: SYSTEM` —— 跟随系统深浅色，而不是跟随应用主题，
 *     否则深色系统 + 浅色应用时材质会「发灰」；
 *   - `scale: 1` —— 保持圆角处的模糊采样比例与系统一致。
 *
 * ⚠️ **不要开 `adaptiveColor: AVERAGE`**（踩过）：
 * 它要求系统逐帧**回读背后画面的平均色**来调制材质。静态背景上确实更「有光感」，
 * 但本项目的材质全都压在**滚动内容**之上——每滚一帧就要重算一次回读，
 * 实测表现是发现页滚动发涩、点进详情页的共享元素转场明显掉帧。
 * 关掉之后材质仍然模糊，只是不再随背景取色；这点观感差异换回满帧，值得。
 * （2026-09-17 用户反馈「发现页有点卡顿、进详情页动画也很卡顿」后关闭）
 *
 * 注意：`backgroundBlurStyle` 模糊的是**组件背后**。卡片若处在不透明页面底色
 * 之上、背后没有任何内容，材质不会带来视觉变化（但也不会有副作用）；
 * 真正见效的是**悬浮在滚动内容或自定义背景图之上的控件**。
 */
export class AppMaterial {
  /** 底栏 / 导航栏档。 */
  static readonly bar: BlurStyle = BlurStyle.COMPONENT_ULTRA_THICK;
  /** 悬浮胶囊档。 */
  static readonly capsule: BlurStyle = BlurStyle.COMPONENT_THICK;
  /** 卡片档。 */
  static readonly card: BlurStyle = BlurStyle.COMPONENT_REGULAR;
  /**
   * 需要看清文字的卡片档（详情页概览卡那种浮在图片上的正文卡）。
   * 比 `card` 厚一档，把背后的海报杂色压得更平，正文对比度才够。
   */
  static readonly cardStrong: BlurStyle = BlurStyle.COMPONENT_THICK;

  /** 材质选项（三档共用）。 */
  static options(): BackgroundBlurStyleOptions {
    return {
      colorMode: ThemeColorMode.SYSTEM,
      scale: 1.0
    };
  }
}
