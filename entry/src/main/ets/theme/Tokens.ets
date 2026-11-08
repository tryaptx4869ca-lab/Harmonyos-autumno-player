import { curves } from '@kit.ArkUI';

/**
 * 动效令牌。
 *
 * 数值全部取自 Flutter 源码统计（lib/**）：
 *   曲线用量  easeOutCubic 36 / easeOutBack 8 / easeInOutCubic 8 / easeInOut 7
 *             easeInOutCubicEmphasized 7 / easeInCubic 5 / easeOut 2
 *   时长分布  250ms 14 / 200ms 12 / 180ms 7 / 220ms 6 / 300ms 6 / 120ms 5 / 260ms 3
 *
 * Flutter 的 Curves.* 本质是三次贝塞尔，控制点为公开常量，
 * 因此这里用 cubicBezierCurve 逐参数复刻，可与 Flutter 完全一致。
 */
export class Motion {
  static readonly fast: number = 120;
  static readonly quick: number = 180;
  static readonly standard: number = 200;
  static readonly medium: number = 220;
  static readonly normal: number = 250;
  static readonly slow: number = 300;
  /** 底部导航隐藏 / 弹入 */
  static readonly nav: number = 260;

  // ---- §38.2 时长总表的其余档位（源码里出现过、上面没覆盖的） ----
  /** 关闭动画（`MediaQuery.disableAnimationsOf` 命中时的降级值）。 */
  static readonly off: number = 0;
  /** Tab 相互切换的淡入（`index_module` `_tabTransition`）。 */
  static readonly tab: number = 70;
  /** 骨架屏替换（`bangumi_info_card`）、`player_controller` 的 80ms。 */
  static readonly skeleton: number = 80;
  /** `harmony_tokens` 的 `HS.instant`。 */
  static readonly instant: number = 100;
  /** 播放页右侧面板滑入（`video_page` `_sideTabAnimationDuration`）。 */
  static readonly sidebar: number = 120;
  /** 时间表季下拉 / 排序浮层的**退出**时长（进入是 quick=180）。 */
  static readonly dropdownOut: number = 140;
  /** 推荐页某处路由的退出时长（进入是 standard=200）。 */
  static readonly routeOut: number = 150;
  /** 播放页 HUD 静音档。 */
  static readonly muteStep: number = 160;
  /** 剧集面板定位滚动。 */
  static readonly segment: number = 280;
  /** `harmony_tokens` 的 `HS.full`。 */
  static readonly full: number = 320;
  /** 播放页离线播放器初始化延时。 */
  static readonly offlineInit: number = 400;
  /**
   * 引导页翻页（`onboarding_page` `animateToPage`）。
   *
   * 2026-09-17：首次引导整条链路已按用户要求删除，本令牌目前**没有使用方**。
   * 保留只为「对照参照实现的时长总表」，以及便于从
   * `docs/drafts/ui-refactor-backup/OnboardingPage.ets.bak` 还原时直接可用。
   */
  static readonly onboarding: number = 400;
  /** 推荐页 Banner 换页 / 截图反馈。 */
  static readonly banner: number = 420;
  /** 下载控制器的 UI 刷新节流。 */
  static readonly throttle: number = 500;
  /** 信息页进入时的延时。 */
  static readonly infoDelay: number = 600;
  /** 播放器 HUD 自动隐藏。 */
  static readonly hudAutoHide: number = 650;
}

/**
 * Flutter `Curves.easeInOutCubicEmphasized` 的**精确**移植。
 *
 * Flutter 里它是 `ThreePointCubic`——**两段三次贝塞尔共用一个中点**
 * （`packages/flutter/lib/src/animation/curves.dart:453-524`），
 * ArkUI 的 `cubicBezierCurve` 只有单段，因此必须自己按公式求值。
 *
 * 控制点（`curves.dart:1781-1787`，已对着官方 stable 源码核对）：
 * ```
 * ThreePointCubic(
 *   Offset(0.05, 0),     Offset(0.133333, 0.06),  // 第一段的两个控制点
 *   Offset(0.166666, 0.4),                        // 中点（两段共用，曲线必过此点）
 *   Offset(0.208333, 0.82), Offset(0.25, 1),      // 第二段的两个控制点
 * )
 * ```
 * 端点固定为 (0,0) 与 (1,1)。求值方式与 Flutter 一致：先把两段各自归一化到
 * 单位方框，再用二分法从 x 反解出参数 t（`_cubicErrorBound = 0.001`）。
 */
class EmphasizedCurve {
  /** 第一段控制点。 */
  private static readonly a1x: number = 0.05;
  private static readonly a1y: number = 0.0;
  private static readonly b1x: number = 0.133333;
  private static readonly b1y: number = 0.06;
  /** 两段共用的中点。 */
  private static readonly mx: number = 0.166666;
  private static readonly my: number = 0.4;
  /** 第二段控制点。 */
  private static readonly a2x: number = 0.208333;
  private static readonly a2y: number = 0.82;
  private static readonly b2x: number = 0.25;
  private static readonly b2y: number = 1.0;
  /** 与 Flutter 相同的误差界。 */
  private static readonly errorBound: number = 0.001;

  /** `_evaluateCubic`：给定参数 m，求一维三次贝塞尔在该点的值。 */
  private static evaluate(a: number, b: number, m: number): number {
    return 3 * a * (1 - m) * (1 - m) * m + 3 * b * (1 - m) * m * m + m * m * m;
  }

  /** `Cubic.transform`：二分反解参数后再求 y。 */
  private static cubic(a: number, b: number, c: number, d: number, t: number): number {
    if (t <= 0) {
      return 0;
    }
    if (t >= 1) {
      return 1;
    }
    let start: number = 0;
    let end: number = 1;
    // Flutter 用 `while(true)`；这里封顶 40 次（误差界 0.001 只需约 10 次），
    // 避免浮点异常时死循环。
    for (let i = 0; i < 40; i++) {
      const mid: number = (start + end) / 2;
      const estimate: number = EmphasizedCurve.evaluate(a, c, mid);
      if (Math.abs(t - estimate) < EmphasizedCurve.errorBound) {
        return EmphasizedCurve.evaluate(b, d, mid);
      }
      if (estimate < t) {
        start = mid;
      } else {
        end = mid;
      }
    }
    return EmphasizedCurve.evaluate(b, d, (start + end) / 2);
  }

  /** `ThreePointCubic.transformInternal`。 */
  static transform(t: number): number {
    if (Number.isNaN(t) || t <= 0) {
      return 0;
    }
    if (t >= 1) {
      return 1;
    }
    const first: boolean = t < EmphasizedCurve.mx;
    const scaleX: number = first ? EmphasizedCurve.mx : 1.0 - EmphasizedCurve.mx;
    const scaleY: number = first ? EmphasizedCurve.my : 1.0 - EmphasizedCurve.my;
    const scaledT: number =
      (t - (first ? 0.0 : EmphasizedCurve.mx)) / scaleX;
    if (first) {
      return EmphasizedCurve.cubic(EmphasizedCurve.a1x / scaleX, EmphasizedCurve.a1y / scaleY,
        EmphasizedCurve.b1x / scaleX, EmphasizedCurve.b1y / scaleY, scaledT) * scaleY;
    }
    return EmphasizedCurve.cubic(
      (EmphasizedCurve.a2x - EmphasizedCurve.mx) / scaleX,
      (EmphasizedCurve.a2y - EmphasizedCurve.my) / scaleY,
      (EmphasizedCurve.b2x - EmphasizedCurve.mx) / scaleX,
      (EmphasizedCurve.b2y - EmphasizedCurve.my) / scaleY,
      scaledT) * scaleY + EmphasizedCurve.my;
  }
}

/** 求值函数本体，供自绘动画（加载指示器等）直接调用。 */
export function emphasizedTransform(t: number): number {
  return EmphasizedCurve.transform(t);
}

export class AppCurves {
  /** Curves.easeOutCubic —— 全应用最高频 */
  static easeOutCubic(): ICurve {
    return curves.cubicBezierCurve(0.215, 0.61, 0.355, 1.0);
  }

  /** Curves.easeOutBack */
  static easeOutBack(): ICurve {
    return curves.cubicBezierCurve(0.175, 0.885, 0.32, 1.275);
  }

  /** Curves.easeInOutCubic */
  static easeInOutCubic(): ICurve {
    return curves.cubicBezierCurve(0.645, 0.045, 0.355, 1.0);
  }

  /** Curves.easeInCubic */
  static easeInCubic(): ICurve {
    return curves.cubicBezierCurve(0.55, 0.055, 0.675, 0.19);
  }

  /** Curves.easeIn */
  static easeIn(): ICurve {
    return curves.cubicBezierCurve(0.42, 0.0, 1.0, 1.0);
  }

  /** Curves.easeOut */
  static easeOut(): ICurve {
    return curves.cubicBezierCurve(0.0, 0.0, 0.58, 1.0);
  }

  /** Curves.easeInOut */
  static easeInOut(): ICurve {
    return curves.cubicBezierCurve(0.42, 0.0, 0.58, 1.0);
  }

  /**
   * Curves.easeInOutCubicEmphasized。
   *
   * 用 `curves.customCurve` 包住 `EmphasizedCurve.transform`——
   * 与 Flutter 逐公式一致（两段三次贝塞尔 + 二分反解），
   * 不再是「单段近似」。全项目 7 处引用（§38.1 / §38.11）：
   * 追番筛选条、历史筛选条、引导页、编辑器表单、规则卡、加载指示器。
   */
  static easeInOutCubicEmphasized(): ICurve {
    return curves.customCurve((fraction: number): number => {
      return emphasizedTransform(fraction);
    });
  }

  /**
   * 弹层入场弹簧（§38.4 第 1 处）。
   *
   * 参照实现 `adaptive_bottom_sheet.dart:117-127`：
   * `SpringDescription.withDampingRatio(mass: 1, stiffness: 380, ratio: 0.8)`，
   * 0 → 1，`snapToEnd: false`（**保留过冲**）。
   *
   * ArkUI 的 `interpolatingSpring(velocity, mass, stiffness, damping)` 与 Flutter
   * 的 `SpringDescription(mass, stiffness, damping)` 是同一组参数，
   * 阻尼系数换算：`damping = ratio · 2√(mass · stiffness)`（= 31.19）。
   */
  static springSheet(): ICurve {
    return curves.interpolatingSpring(0, 1, 380, 0.8 * 2 * Math.sqrt(380));
  }

  /**
   * 剧集行按压弹簧（§38.4 第 2 处）。
   *
   * 参照实现 `episode_selection_panel.dart:993-1002`：
   * `SpringDescription.withDampingRatio(mass: 1, stiffness: 500, ratio: 0.8)`，
   * 从当前值弹到目标值并**带上当前速度**（= `velocity` 参数）。
   * 阻尼系数换算：`damping = 0.8 · 2√500`（= 35.78）。
   */
  static springPress(velocity: number): ICurve {
    return curves.interpolatingSpring(velocity, 1, 500, 0.8 * 2 * Math.sqrt(500));
  }
}

/** 尺寸令牌。多数来自 StyleString 与实测。 */
export class Dimens {
  /** StyleString.cardSpace */
  static readonly cardSpace: number = 8;
  /** 页面左右内容边距 */
  static readonly contentInset: number = 16;
  /** 底部导航胶囊高度（kImmersiveNavHeight） */
  static readonly navHeight: number = 52;
  /** 底部导航左右内缩（kImmersiveNavSideInset） */
  static readonly navSideInset: number = 18;
  /** 底部导航距系统底距（kImmersiveNavBottomGap） */
  static readonly navBottomGap: number = 8;
  /** 底部导航内边距 */
  static readonly navPadding: number = 5;
  /** 底部导航选中胶囊圆角 */
  static readonly navPillRadius: number = 21;
  /** 内容底部为导航预留的高度（Flutter 用 180） */
  static readonly contentBottomSpacer: number = 180;
}

/**
 * 语义令牌，对应源码 `bean/theme/harmony_tokens.dart` 的 `HS`。
 *
 * 与 `Motion` 的区别：`Motion` 是按实测频率归纳的"常用值"，
 * 这里是源码里真正被组件引用的一组语义常量——
 * 写新组件时应优先用 HS，只有源码里写明具体毫秒的地方才用 `Motion`。
 */
export class HS {
  // 间距：8vp 栅格 + 4vp 半步
  static readonly s4: number = 4;
  static readonly s8: number = 8;
  static readonly s12: number = 12;
  static readonly s16: number = 16;
  static readonly s24: number = 24;
  static readonly s32: number = 32;

  // 圆角
  static readonly r8: number = 8;
  static readonly r16: number = 16;
  static readonly r24: number = 24;
  static readonly rPill: number = 999;

  // 时长
  static readonly instant: number = 100;
  static readonly short: number = 180;
  static readonly local: number = 220;
  static readonly full: number = 320;

  // 语义曲线
  static standard(): ICurve {
    return AppCurves.easeInOutCubic();
  }

  static decelerate(): ICurve {
    return AppCurves.easeOutCubic();
  }

  static accelerate(): ICurve {
    return AppCurves.easeInCubic();
  }

  static settle(): ICurve {
    return AppCurves.easeOutBack();
  }

  // 状态层（HarmonyOS 用状态层替代 Material 水波纹）
  static readonly pressedLayer: number = 0.10;
  static readonly hoverLayer: number = 0.08;
  static readonly focusLayer: number = 0.12;
  static readonly disabledOpacity: number = 0.38;
}

/**
 * 页面转场，对应源码 `HarmonyPageTransitionsBuilder`：
 * 进入 `decelerate`、退出 `accelerate`，
 * 动画是 `FadeTransition` + `SlideTransition(begin: Offset(0, 0.02))`。
 *
 * ArkUI 侧对应 `router.pushUrl` 的 `pageTransition` / `Navigation` 转场配置，
 * 阶段 3 建路由表时按这里的参数下发。
 */
export class PageTransitionSpec {
  /** 起点纵向偏移（占自身高度的比例）。 */
  static readonly slideBeginY: number = 0.02;
  /** 进入曲线。 */
  static enterCurve(): ICurve {
    return AppCurves.easeOutCubic();
  }

  /**
   * 退出曲线。
   *
   * ⚠️ **和进场是同一条（`easeOutCubic`），不是笔误。**
   *
   * 参照实现那条是
   * `CurvedAnimation(parent: animation, curve: HS.decelerate, reverseCurve: HS.accelerate)`
   * （`harmony_tokens.dart:80-84`）。关键是 **`reverseCurve` 作用在动画的「值」上，
   * 不是作用在「进度」上**——Flutter 的 `CurvedAnimation.value` 是
   * `activeCurve.transform(parent.value)`：弹栈时 `parent.value` 从 1 走到 0，
   * 取的是 `reverseCurve`，于是
   *
   *     退出透明度 = easeInCubic(1 - t) = (1 - t)³
   *
   * 而 ArkUI 的 `animateTo({ curve })` 是把曲线作用在 **0 → 1 的进度** 上
   * （属性值 = 起点 + (终点 − 起点) × curve(t)）。同一个「退出透明度」写成
   * ArkUI 形式是 `1 − c(t) = (1 − t)³`，解得
   *
   *     c(t) = 1 − (1 − t)³ = easeOutCubic(t)
   *
   * 所以**在 ArkUI 这边，退场曲线就是进场曲线**。上一版直接把 `HS.accelerate`
   * 的名字抄了过来（写成 easeInCubic），方向刚好反了：`easeInCubic(0.5) = 0.125`，
   * 意味着前 150ms 整页还留着 87% 的不透明度、几乎看不出在动，观感就是
   * 「点了返回没反应，过一会儿才开始」——用户 2026-10-08 反馈的
   * 「返回的转场还是不及时 / 返回之后进入的转场延时大 / 和进场观感不一样」
   * 三条都是它引起的（进场那条是 easeOutCubic，所以进场一按就动）。
   */
  static exitCurve(): ICurve {
    return AppCurves.easeOutCubic();
  }

  /**
   * 共享元素飞行的曲线（**进、出共用这一条**）。
   *
   * 参照实现里 Hero 走的是路由动画的**原始进度**（Flutter 的 Hero 不额外套曲线，
   * 所以严格说它对应 `Curve.Linear`）；但本项目进场那条飞行是拿
   * `animateTo({ curve: enterCurve() })` 驱动的、观感已确认可以，
   * 退场如果单独用线性，封面和页面就会「一条匀速、一条先快后慢」——用户
   * 2026-10-08 反馈的「和进场观感不一样」有它一份。所以这里进出一致，
   * 都用进场那条曲线；哪天想严格照 Flutter 的线性，把返回值换成
   * `Curve.Linear` 即可（进、出会一起变）。
   */
  static flightCurve(): ICurve {
    return AppCurves.easeOutCubic();
  }

  /**
   * 时长：源码 `HarmonyPageTransitionsBuilder` **没有**显式指定，
   * 走 `MaterialPageRoute` 的框架默认值 **300ms**
   * （Flutter 的 `MaterialPageRoute.transitionDuration` = 300ms）。
   * 上一版写的是 `HS.full`（320，项目自定语义值），与参照不符，已改回 300。
   */
  static readonly duration: number = 300;

  /**
   * 返回时「动画播完 → 真正弹栈」之间的余量（ms）。
   *
   * 参照实现的退场是**整页自己淡出、弹栈发生在动画结束之后**：Flutter 的
   * `Navigator.pop()` 把路由留在 overlay 里一直演到动画结束才拆掉，
   * 所以「拆页面」这笔开销（详情页里有一层全屏模糊 + 长列表 + 网络图）
   * 用户从来感觉不到。我们原来是在**点下去的同一帧**就弹栈、再拿一张整页
   * 快照当替身顶上，等于把「抓图 + 拆页面 + 传整屏位图纹理」三笔开销全压在
   * 用户点下去那一帧上——这就是「返回有延迟」的来源（用户 2026-10-08 连着
   * 反馈了三次）。现在改成和参照实现同构：先播动画、播完再弹。
   *
   * 留 40ms 余量：动画是 300ms，这里没有「动画结束」回调可用，只能把弹栈
   * 排在 340ms。多等 40ms 什么也看不见（那时页面已经全透明），
   * 少等了才会在动画尾巴上把页面拆掉、闪一下。
   */
  static readonly heroPopDelayMs: number = 40;
}

/**
 * 底部导航的滚动隐藏规格，对应源码 `menu.dart:61-89 / 179-199`。
 */
export class NavScrollSpec {
  /** 向下累加到该距离即隐藏。 */
  static readonly hideThreshold: number = 48;
  /** 小于该位移视为抖动，忽略。 */
  static readonly minDelta: number = 0.5;
  /** 位移与透明度的时长。 */
  static readonly transformDuration: number = 260;
  static readonly opacityDuration: number = 200;
  /** 隐藏时下沉比例（AnimatedSlide offset y）与缩放。 */
  static readonly hiddenSlideY: number = 0.9;
  static readonly hiddenScale: number = 0.35;
  /** 双击返回的间隔上限。 */
  static readonly exitPromptWindowMs: number = 2000;
}

/**
 * 主 Tab 之间的转场。对应规格 §12.2 `index_module.dart:32-43`：
 * Tab 相互切换是 **70ms 的 FadeTransition**（图片预览是 220ms，另见 §59）。
 */
export class TabTransition {
  static readonly duration: number = 70;

  /** 源码未指定曲线，采用全局最高频的 easeOutCubic。 */
  static curve(): ICurve {
    return AppCurves.easeOutCubic();
  }
}

/**
 * 跨页共享元素飞行（规格 §38.7 的 Hero）。
 *
 * ⚠️ **必须用 `sharedTransition`，不能用 `geometryTransition`**：
 * ArkUI 把它们分成了两件事（DevEco 自带 API 参考）：
 *
 * | API | 文档标题 | 适用范围 |
 * | --- | --- | --- |
 * | `sharedTransition(id, options)` | 共享元素转场 | **仅发生在 `@ohos.router` 页面跳转时** |
 * | `geometryTransition(id, options)` | 组件内隐式共享元素转场 | 同一页面内的 if/else 两分支互换 |
 *
 * 本工程第一版错用了 `geometryTransition`，实测转场帧里目标页海报从第一帧
 * 就已经在终点位置——因为 router 跳转时源页节点已析构（转场中途 dump 布局树，
 * 源页文本一个都不在），没有「旧视图」可飞。
 *
 * 参数与 Flutter 的 Hero 对齐：
 *   - 时长 = 路由转场时长 300ms（Flutter 里 Hero 直接用路由的 animation）；
 *   - 曲线 = 线性（Flutter 的 Hero 飞行没有额外套曲线，整页转场才套 easeOutCubic）；
 *   - `type` 用默认的 `Exchange`：只过渡位置与大小、不插值内容
 *     （两端都是同一张封面，够用；这也是文档明确的行为）。
 */
export class HeroFlight {
  /**
   * 飞行时长（ms）。
   *
   * 原来取 300，与路由转场（`PageTransitionSpec.duration`）完全一致。
   * 用户 2026-09-17 反馈「封面移动有一点慢」，调到 **240**：
   * 封面比页面转场**先落地**约 60ms，形成「封面先到位、页面随后铺开」的层次，
   * 观感上更快，也不会出现「页面已经停住、封面还在漂」的拖尾。
   */
  static readonly duration: number = 240;
  /** 曲线：线性（用户 2026-10-08 明确：要跟 Flutter 对齐的是**背景层的转场**，
   *  不是封面飞行这条曲线，所以这里保持原样）。 */
  static curve(): Curve {
    return Curve.Linear;
  }

  /**
   * 生成共享元素 id。
   *
   * 参照实现把 `heroTag` 随路由参数传给详情页（`InfoRouteData.heroTag`），
   * 因此这里也用「来源 + 条目 id」拼一个：同一个番剧可能同时出现在
   * Banner 与网格里，只按 id 拼会出现**一个 id 绑两个组件**（文档明确不允许）。
   */
  static tag(origin: string, id: number): string {
    return `poster-${origin}-${id}`;
  }

  /**
   * ⚠️ **共享元素两端必须用同一个封面 URL**（同一个档位、同一个代理开关）。
   *
   * 2026-09-20 的教训（两次都踩在这上面）：
   *   - 卡片封面改走 `/r/400/` 缩略档、详情页海报还是原图 → URL 不同 =
   *     两条缓存 → 飞行途中目标端那张 200+ KB 的图还在下载，用户看到
   *     「一张没加载好的图片在动画」；
   *   - 反过来，如果只有一端走代理改写，同样对不上。
   *
   * 所以卡片一律用 `BangumiItem.coverUrl()`，**别在卡片上自己降档**。
   */
}
