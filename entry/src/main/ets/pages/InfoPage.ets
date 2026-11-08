import { router, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BangumiApi } from '../api/BangumiApi';
import { BangumiItem } from '../model/BangumiItem';
import { BangumiTag } from '../model/BangumiTag';
import { BangumiRelation, CharacterItem, StaffItem } from '../model/InfoModels';
import { SourceSheet } from '../components/SourceSheet';
import { DetailBackdrop } from '../components/DetailBackdrop';
import { AppColor } from '../theme/AppColors';
import { AppMaterial } from '../theme/Material';
import { BangumiImageUrlRewriter } from '../services/BangumiImageUrlRewriter';
import { CoverImage } from '../components/CoverImage';
import { AppCurves, HeroFlight, HS, PageTransitionSpec } from '../theme/Tokens';
import { NavHost, RouteTable } from '../router/RouteTable';
import { HeroRect, HeroRects } from '../router/HeroRects';
import { InfoRouteArgs, SearchRouteArgs, VideoRouteArgs } from '../router/RouteArgs';
import { CharacterSheet } from '../components/CharacterSheet';
import { Viewport } from '../utils/Viewport';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';
import { CollectStore, CollectEntry } from '../services/collect/CollectStore';
import { HistoryRepository } from '../services/HistoryRepository';
import { HistoryEntry, HistoryProgress } from '../model/HistoryModels';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnInfo';

/** 详情页骨架尺寸（规格 §9.2 / §62.1）。 */
class InfoMetrics {
  /** `kToolbarHeight`。 */
  static readonly toolbar: number = 56;
  /** `kTextTabBarHeight`。 */
  static readonly tabBar: number = 48;
  /** SliverAppBar 展开时 flexibleSpace 的高度。 */
  static readonly flexible: number = 322;
  /** 信息卡自身高度（§62.1）。 */
  static readonly cardHeight: number = 300;
  /** 骨架最少显示时长（`_minimumBangumiInfoLoadingDuration`）。 */
  static readonly minSkeletonMs: number = 600;
  /** 关联卡（`_RelatedBangumiCardH`）。 */
  static readonly relatedCardHeight: number = 108;
  static readonly relatedImageHeight: number = 92;
}

/** 播出状态角标（§62.2 / §62.3）。 */
enum AiringStatus {
  none = 0,
  finished = 1,
  airing = 2,
  notStarted = 3
}

/**
 * 番剧详情页。
 * 对应参照实现 `lib/pages/info/info_page.dart` + `info_tabview.dart`
 * + `bean/card/bangumi_info_card.dart`。
 *
 * ArkUI 没有 `NestedScrollView + SliverAppBar`，这里用等价结构：
 *   Column { 工具条（固定）→ 信息卡区（高度随滚动线性收缩）→ 分段栏（固定）
 *            → 内容区（Swiper，四页各自可滚） }
 * 收缩比例与 SliverAppBar 一致：滚 1vp，信息卡矮 1vp；
 * `scrollOffset` 由当前页的滚动容器上报（`onDidScroll`）。
 */
@Component
export struct InfoPage {
  /**
   * 本次运行里已经补拉过详情的条目 id。
   *
   * 只服务于 `needsRefresh()` 里那条「判不出播出状态就补拉一次」的规则：
   * 漫画 / 游戏这类条目补拉完 `platform` 仍然是空（确实不是 TV/WEB），
   * 没有这个名单就会**每次打开详情页都再请求一次**。
   */
  private static refreshedIds: number[] = [];
  /** 名单上限（只用来避免长会话里无限增长）。 */
  private static readonly REFRESHED_MAX: number = 60;
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('bottomInset') bottomInset: number = 28;
  @StorageProp('themeRevision') themeRevision: number = 0;
  /** Tab 正文的过渡进度：0 = 已淡出（换内容那一刻），1 = 就位。 */
  @State private tabFade: number = 1;
  /** 最近一次切 Tab 的方向：1 = 往下一个（向左滑），-1 = 往上一个。 */
  @State private tabDir: number = 1;
  /** 过渡令牌：快速连滑时用它作废旧回调。 */
  private tabAnimToken: number = 0;

  @State private item: BangumiItem = new BangumiItem();
  @State private ready: boolean = false;
  @State private loadingInfo: boolean = false;
  /** 历史基线快照不包含自建番剧功能。 */
  @State private isLocalItem: boolean = false;
  /** 保留布局字段，历史基线中始终为 0。 */
  @State private localCreatedAt: number = 0;
  /** 当前分段。**不能叫 `tabIndex`**：那是 ArkUI 内置组件属性名，会与基类冲突。 */
  @State private activeTab: number = 0;
  @State private scrollOffset: number = 0;
  @State private viewportWidth: number = 0;
  /**
   * 整页背景层（模糊海报 + 蒙层 + 渐变）的透明度。
   *
   * 为什么要它：详情页是**共享元素**跳转（`systemTransition(NONE)` +
   * `animated=false`，整页只有封面在动），所以以前那张大模糊海报是「瞬现瞬灭」
   * 的——用户 2026-10-07 反馈的「进/返回时那个模糊过渡不自然」。
   * 现在：
   *   - 进场：0 → 1（与封面飞行同为 300ms，两者并行）；
   *   - 返回：`onHeroExit()` 把它推到 0、并下移 2%，淡完 `NavHost` 才真正弹栈
   *     （见 `RouteTable.pop()`）。
   * ⚠️ 只动这一层，**内容层不淡**：封面飞行的目标节点在内容里，父节点 opacity
   * 归零会把飞行中的封面一起淡掉。
   */
  /**
   * 整页进场动画：**透明度和位移都作用在页面根节点上**（不只是模糊背景）。
   *
   * 参照实现是整页 `Fade + Slide(2%)`（`PageTransitionEnter/Exit`，300ms），
   * 内容层和背景层一起淡入淡出——之前我只淡了背景层，所以「感觉不一样」。
   * 封面飞行不受影响：ArkUI 的共享元素转场（`geometryTransition`）由框架在
   * 转场层里画，不跟着页面根的 opacity/translate 走（与 Flutter 的 Hero 画在
   * overlay 里一致）。
   */
  @State private enterOpacity: number = 1;
  /** 整页进场的纵向偏移（占自身高度比例）：从下方 2% 滑到位。 */
  @State private enterSlide: number = 0;

  /**
   * 退场进行中。
   *
   * 两件事：① 连点返回时忽略第二次（动画已经在跑了）；② 转场期间铺一层
   * 吞触摸的透明层——参照实现里正在退场的路由是 `IgnorePointer` 的，
   * 否则这 300ms 里用户点到的是**底下的首页**（点开另一部番）。
   */
  @State private exiting: boolean = false;
  /**
   * 退场时把页面里这张封面藏起来（**不是摘掉**）。
   *
   * 摘掉会连带触发框架那一套共享元素转场（我们不需要它，见 `backOut` 的注释），
   * 而且会改布局（信息卡宽度跳一下）。`Visibility.Hidden` 只藏不撤：
   * 位置尺寸照旧、布局不动，也不需要占位。
   */
  @State private coverHidden: boolean = false;
  /** 自绘飞行层是否在飞（见 `build()` 里的 shuttle）。 */
  @State private heroFly: boolean = false;
  @State private heroFlyX: number = 0;
  @State private heroFlyY: number = 0;
  @State private heroFlyW: number = 0;
  @State private heroFlyH: number = 0;
  @State private heroFlyUrl: string = '';
  /**
   * 登记给 `NavHost` 的退场回调（系统返回转达用）。
   *
   * 存成字段是为了 `aboutToDisappear` 能按**同一个引用**注销——
   * `NavHost.unregisterInfoExit` 靠引用比较，不然会把后来那一层详情页
   * （相关推荐 → 详情页）的回调一起清掉。
   */
  private exitHook: () => void = () => {
    this.backOut();
  };

  /**
   * 播放页等页面退掉、覆盖层重新露出来时 +1（由 `Index` 发，见那里的注释）。
   *
   * 原因：状态栏/导航条是全局的，整个工程只有播放页会改它；详情页现在是覆盖层，
   * 返回时只是重新可见、不会重新挂载，所以没人把系统栏改回详情页该有的样子
   * （用户 2026-10-09：「退出到详情页时状态栏会黑一段时间」）。
   */
  @StorageProp('infoReshownTick') @Watch('onInfoReshown') infoReshownTick: number = 0;

  onInfoReshown(): void {
    this.restoreSystemBar();
    /**
     * 从播放页返回时重开「播放来源」弹层。
     *
     * 原来靠目的地的 `onShown` 转达，但播放页现在是覆盖层（不是目的地），
     * 栈深不变、`navShown` 不会变；所以改由这条「重新露出来」的通知带过来
     * （播放页滑出后由 `NavHost.closeVideoOverlay` 发出）。
     */
    if (InfoRouteArgs.reopenSourceSheet) {
      InfoRouteArgs.reopenSourceSheet = false;
      setTimeout(() => {
        this.openSheet(1);
      }, InfoPage.SHEET_CLOSE_MS);
    }
  }

  /**
   * 恢复「详情页这一档」的系统栏：透明底 + 跟随主题的图标色。
   *
   * 与 `VideoPage.applyStatusBar(false)` 同一套值（那边是离开播放页时用的），
   * 只是现在要由详情页自己再确认一次。
   */
  private async restoreSystemBar(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      await win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: AppColor.isDark ? '#FFFFFF' : '#000000'
      });
    } catch (error) {
      // 拿不到窗口就算了：只是系统栏配色，不该影响页面
    }
  }

  /** 大屏内容最大宽度（对照参照实现 `bangumi_info_card.dart` 的 `maxWidth: 950`）。 */
  private static readonly CONTENT_MAX_WIDTH: number = 950;
  /**
   * 系统 `bindSheet` 收起动画的时长（ms）。
   *
   * 手机上「关闭播放来源弹层」与「压栈进播放页」**不能在同一帧**做：系统模态
   * 收起与路由压栈会互相打架，表现就是用户 2026-10-08 反馈的「整个页面在详情页
   * / 播放页之间来回切、怎么都进不去」。大屏走的是自绘弹层（`.sourceOverlay`），
   * 动画由我们自己管，没有这个问题，所以只有手机这一档需要错开。
   */
  private static readonly SHEET_CLOSE_MS: number = 240;

  /**
   * 大屏（平板 / 横屏）内容两侧的居中留白。
   *
   * 详情页的背景海报是整幅铺满的，收窄的只是**内容列**（信息卡与四个 Tab 的
   * 正文）——否则平板上简介、评分、演职员表都会横跨 1400vp，一行字拉得很散。
   */
  private wideInset(): number {
    const screen: number = this.pageWidthVp();
    return screen > InfoPage.CONTENT_MAX_WIDTH
      ? (screen - InfoPage.CONTENT_MAX_WIDTH) / 2 : 0;
  }

  /**
   * 页面可用宽度（vp）。
   *
   * 优先用根容器实测值；还没测到时 `Viewport.widthVp` 会退回整屏宽——
   * 详情页的响应式判断（内容限宽、封面尺寸、弹层宽度）都走这里，
   * 免得首帧按 0 算成「窄屏」。
   */
  private pageWidthVp(): number {
    return Viewport.widthVp(this.viewportWidth);
  }

  /**
   * 大屏（平板 / 横屏）详情页的统一放大系数。
   *
   * 封面从 124×191 放到 210×323（约 1.7 倍）之后，标题、标签、数值、间距、
   * 卡片高度、Tab 条都得**跟着一起放大**，否则一颗大封面旁边还是一行小字，
   * 整页比例就散了（用户 2026-10-07：「比例也要随着封面大小一起变化」）。
   * 系数取 1.4：介于封面倍率与 1.0 之间，读起来稳，也不会把首屏撑得过高。
   */
  private wideScale(): number {
    return this.wideInset() > 0 ? 1.4 : 1;
  }

  /** 按大屏系数取整后的尺寸（手机竖屏等同于原值，逐字不变）。 */
  private ws(base: number): number {
    return Math.round(base * this.wideScale());
  }

  @State private showRating: boolean = true;
  @State private collectType: number = 0;
  /**
   * 底部弹层：本页两个弹层（播放来源 / 角色详情）**共用同一个 `bindSheet`**。
   *
   * 为什么不各挂一个：本工程有过「同一页挂多个 bindSheet 只有一个能显示」
   * 的先例（播放页那一批，最后全改成自绘）。这里用一个 bindSheet + `sheetKind`
   * 切换内容，从根上避开这个坑。
   * 0 = 关闭，1 = 播放来源，2 = 角色详情。
   */
  @State private sheetVisible: boolean = false;
  @State private sheetKind: number = 0;
  /**
   * 平板 / 大屏的「播放来源」自绘弹层。
   *
   * 系统 `bindSheet` 在大屏上是一条固定 **360vp** 宽的面板（真机实测
   * 2880px 屏里只占 720px），而参照实现的弹层宽度是 `min(屏宽 × 0.72, 640)`。
   * `SheetOptions` 里没有 width 字段，所以大屏这一档自己画：底部居中的面板
   * ＋ 上方压暗遮罩，内容仍是同一个 `SourceSheet`（只是带 `wide` 放大一档）。
   */
  @State private sourceOverlay: boolean = false;
  /** 角色弹层的入参（点角色行时写入）。 */
  @State private chId: number = 0;
  @State private chName: string = '';
  @State private chRelation: string = '';
  @State private chActors: string[] = [];
  /** 本页海报的共享元素 id（由源页经路由参数传入，见 `HeroFlight`）。 */
  @State private heroTag: string = '';
  /** 续播：该番剧最近一条在线历史的集数与线路（0 表示没有历史）。 */
  @State private resumeEpisode: number = 0;
  @State private resumeRoad: number = 0;
  /** 订阅历史变更：从播放页返回详情页时，按钮上的集数要跟着更新。 */
  @StorageProp('historyRevision') @Watch('onHistoryChanged') historyRevision: number = 0;
  /**
   * 订阅收藏变更：在播放页把这部番设成「在看/想看/…」后，回到详情页要**立刻**显示。
   *
   * 详情页常驻在导航栈里，从播放页回来不会重建（`aboutToAppear` 只跑一次），
   * 所以这个状态不能只在打开时读一遍——`CollectStore` 每次写盘都会踢一次
   * `collectRevision`，这里跟着重读（用户 2026-09-19：「在播放页设置该番剧为在看，
   * 回到详情页不能第一时间显示」）。
   */
  @StorageProp('collectRevision') @Watch('onCollectChanged') collectRevision: number = 0;
  /** 概览页「加载更多 / 加载更少」。 */
  @State private fullIntro: boolean = false;
  @State private fullTag: boolean = false;

  // ---- 角色 / 关联 / 制作人员 ----
  @State private characters: CharacterItem[] = [];
  @State private charactersLoading: boolean = false;
  @State private charactersEmpty: boolean = false;
  @State private charactersFailed: boolean = false;

  @State private relations: BangumiRelation[] = [];
  @State private relationsLoading: boolean = false;
  @State private relationsLoaded: boolean = false;
  @State private relationsFailed: boolean = false;

  @State private staffList: StaffItem[] = [];
  @State private staffLoading: boolean = false;
  @State private staffEmpty: boolean = false;
  @State private staffFailed: boolean = false;

  /**
   * 整页只留**一个**滚动容器（用户 2026-09-17：「所有东西在同一图层」）。
   *
   * 原来四个 Tab 各有一个 Scroll、外面还有固定顶栏与固定 Tab 条，
   * 一共三层；现在标题行、信息卡、Tab 条、正文都排进同一个 `Scroll`，
   * 下滑时整页一起走。
   */
  private pageScroller: Scroller = new Scroller();

  /** 二级页转场（规格 §12.4）。 */
  pageTransition() {
    PageTransitionEnter({
      type: RouteType.Push,
      duration: RouteTable.duration(),
      curve: PageTransitionSpec.enterCurve()
    })
      .opacity(0)
      .translate({ y: RouteTable.slideOffset() })
    PageTransitionExit({
      type: RouteType.Pop,
      duration: RouteTable.duration(),
      curve: PageTransitionSpec.exitCurve()
    })
      .opacity(0)
      // 退出：与参照实现同一条 Fade + Slide（`Offset(0, 0.02)`）——下滑 2% 的同时淡出
      .translate({ y: RouteTable.slideOffset() })
  }

  aboutToAppear(): void {
    /**
     * 详情页是**首页里的覆盖层**（方案 C），不是目的地：系统返回不会再经过
     * 它自己的 `onBackPress`，所以在这里登记一个「请开始退场」的回调，
     * 由首页那一层的 `onBackPress` 转达（见 `NavHost.requestInfoExit`）。
     */
    NavHost.registerInfoExit(this.exitHook);
    const pending: BangumiItem | null = InfoRouteArgs.pending;
    InfoRouteArgs.pending = null;
    if (pending !== null) {
      this.item = pending;
    } else if (InfoRouteArgs.current !== null) {
      /**
       * 覆盖层被重建（真机上从播放页返回时实测会重建一次，见
       * `InfoRouteArgs.current` 的注释）：这时一次性参数已经被上一个实例
       * 消费掉了，退回「当前详情页」那份，页面才不会变成空壳。
       */
      this.item = InfoRouteArgs.current;
    }
    // 源页给的共享元素 id（参照实现的 `heroTag`）；没给就退回按 id 拼
    const tag: string = InfoRouteArgs.pendingHeroTag.length > 0
      ? InfoRouteArgs.pendingHeroTag : InfoRouteArgs.currentHeroTag;
    this.heroTag = tag.length > 0 ? tag : HeroFlight.tag('detail', this.item.id);
    InfoRouteArgs.pendingHeroTag = '';
    this.ready = true;
    /**
     * 从播放页返回时要重开「播放来源」弹层。原来只靠 `onNavShown`（目的地回调），
     * 但详情页现在是覆盖层、而且可能被重建（见 `InfoRouteArgs.current`），
     * 重建出来的实例收不到那次 revision，所以这里补一次。
     */
    if (InfoRouteArgs.reopenSourceSheet) {
      InfoRouteArgs.reopenSourceSheet = false;
      setTimeout(() => {
        this.openSheet(1);
      }, InfoPage.SHEET_CLOSE_MS);
    }
    this.showRating = SettingsStore.getBool(SettingsKeys.showRating);
    const entry: CollectEntry | null = CollectStore.find(this.item.id);
    this.collectType = entry === null ? 0 : entry.collectType;
    this.loadResume();
    if (!this.isLocalItem && this.needsRefresh()) {
      this.loadInfo();
    }
    hilog.info(DOMAIN, TAG, '详情页打开 id=%{public}d name=%{public}s',
      this.item.id, this.item.nameCn);
    /**
     * 整页进场（见 `enterOpacity`）：首帧先按透明 + 下移 2% 渲染，下一拍再用
     * 参照实现那条 300ms 曲线推到 1 / 0——与封面飞行并行，页面与海报一起到位。
     * 页面根底色在淡入期间也是透明的（见 `build()` 的 `backgroundColor`），
     * 所以这段时间透出的是下面那一页，是一次真正的交叉淡化。
     */
    this.enterOpacity = 0;
    this.enterSlide = PageTransitionSpec.slideBeginY;
    setTimeout(() => {
      try {
        this.getUIContext().animateTo({
          // 参照实现 `PageTransitionEnter`：整页 Fade + Slide(2%)、300ms、
          // 进场 easeOutCubic（MaterialPageRoute 默认时长）。封面飞行与它并行
          // （时长同为 300ms，见 `NavHost.pushWithHero`），两者叠起来才是
          // Flutter 那种「整页淡入 + 海报飞入」。
          duration: PageTransitionSpec.duration,
          curve: PageTransitionSpec.enterCurve()
        }, () => {
          this.enterOpacity = 1;
          this.enterSlide = 0;
        });
      } catch (e) {
        this.enterOpacity = 1;
        this.enterSlide = 0;
      }
    }, 16);
  }

  aboutToDisappear(): void {
    NavHost.unregisterInfoExit(this.exitHook);
  }

  /**
   * 返回：**整页自己演退场，弹栈挪到动画之后**。
   *
   * 结构照搬参照实现（`TransitionType.material` + `HarmonyPageTransitionsBuilder`）：
   * Flutter 的 `Navigator.pop()` 只是把路由切成「正在退场」，页面**留在 overlay
   * 里继续渲染**，`FadeTransition + SlideTransition` 直接作用在真实页面上，
   * Hero 是并行另一条动画，动画结束之后路由才真正被拆掉。
   *
   * 我们上一版是反过来的：**点下去的同一帧就弹栈**，再抓一张整页快照当替身
   * 顶上去。于是「同步抓图 + 拆详情页子树（整屏模糊 + 长列表）+ 传整屏位图纹理」
   * 三笔开销全压在用户点下去那一帧上——用户 2026-10-08 连报三次「返回有延迟」
   * 就是它。现在这里没有任何前置准备，两件**下一帧就开始**的事：
   *
   *   ① 摘掉**页面这一端的封面节点**（`coverInFlight`），卡片那一端的封面会从
   *      它的位置飞回去——共享元素飞行由框架在转场层里画；
   *   ② 整页 Fade(1 → 0) + Slide(0 → 2%)。
   *
   * 两条 `animateTo` 分开写、各带各的曲线：参照实现里 Hero 用路由动画的原始
   * 进度、页面转场另外套 `CurvedAnimation`，两者时长相同、曲线可以不同。
   * 这里 `flightCurve()` 与 `exitCurve()` 当前取同一条（见 Tokens 的注释）。
   *
   * 返回键与系统返回手势都走这里（`onBackPress`），所以「能退的那一层」是
   * 唯一的——不会出现栈里两层详情页都动起来的情况。
   */
  private backOut(): void {
    if (this.exiting) {
      return;
    }
    this.exiting = true;
    const ctx = this.getUIContext();
    /**
     * ① 封面：**自绘飞行层**。
     *
     * 两端位置都来自实测（`HeroRects`：卡片端在卡片自己的 `onAreaChange` 里登记，
     * 详情页端在上面那张封面的 `onAreaChange` 里登记）。先把飞行层按起点放好、
     * 同时把页面里那张封面藏起来——两者像素完全重合，所以这一帧看不出任何切换；
     * 下一帧再把位置/尺寸补到终点，就是「封面飞回去」。
     *
     * ⚠️ 藏封面这一步**不放在 `animateTo` 里**：放到里面会连带触发框架的共享元素
     * 转场（那套要求有路由动作，我们这条路径没有，触发出来只会打架）。
     */
    const src: HeroRect | null = HeroRects.detail(this.heroTag);
    const dst: HeroRect | null = HeroRects.card(this.heroTag);
    const canFly: boolean = src !== null && dst !== null && src.usable && dst.usable;
    this.coverHidden = true;
    if (canFly && src !== null && dst !== null) {
      this.heroFlyUrl = this.item.cover.length > 0 ? this.item.coverUrl() : '';
      this.heroFlyX = src.x;
      this.heroFlyY = src.y;
      this.heroFlyW = src.w;
      this.heroFlyH = src.h;
      this.heroFly = true;
    }
    // ② 整页：Fade(1 → 0) + Slide(0 → 2%)，与封面飞行并行
    ctx.animateTo({
      duration: PageTransitionSpec.duration,
      curve: PageTransitionSpec.exitCurve()
    }, () => {
      this.enterOpacity = 0;
      this.enterSlide = PageTransitionSpec.slideBeginY;
    });
    /**
     * ③ 飞行：起点先渲染一帧再推曲线（和进场同一个手法）。
     *
     * 同一帧里既建层又改到终点的话，框架可能一次都没画过起点，动画就会
     * 「不动」或「直接跳到终点」。等一拍再推，起点这一帧就是纯粹的像素接力。
     */
    if (canFly && dst !== null) {
      setTimeout(() => {
        ctx.animateTo({
          duration: PageTransitionSpec.duration,
          curve: PageTransitionSpec.flightCurve()
        }, () => {
          this.heroFlyX = dst.x;
          this.heroFlyY = dst.y;
          this.heroFlyW = dst.w;
          this.heroFlyH = dst.h;
        });
      }, 16);
    }
    /**
     * ④ 动画播完再摘掉这一层（那时它已经全透明，「拆页面/传纹理」的开销看不见）。
     *
     * 首页一直都在同一棵树里画着，所以这 340ms 里透出来的是**真首页**
     * ——这正是方案 C 要的效果：退场是「详情页 ↔ 首页」的交叉淡化，
     * 而不是和窗口底色之间淡。
     */
    setTimeout(() => {
      NavHost.closeInfoOverlay();
    }, PageTransitionSpec.duration + PageTransitionSpec.heroPopDelayMs);
  }

  onHistoryChanged(): void {
    this.loadResume();
  }

  /**
   * 收藏表变了（在播放页点了「在看 / 想看 / 看过…」）→ 重读本番剧的状态。
   *
   * 只在真的变了才写 `@State`：这条通知是全局的（任何一处收藏变动都会踢），
   * 别的番剧变动时不该让本页白刷一次。
   */
  onCollectChanged(): void {
    const entry: CollectEntry | null = CollectStore.find(this.item.id);
    const type: number = entry === null ? 0 : entry.collectType;
    if (type === this.collectType) {
      return;
    }
    this.collectType = type;
    hilog.info(DOMAIN, TAG, '收藏状态跟随变更：%{public}s', InfoPage.collectLabelOf(type));
  }

  /**
   * 从播放页返回时：按用户要求把「播放来源」弹层重新打开，
   * 即回到「点开详情页、正准备进播放页选源」的那一步
   * （标志由播放页的返回按钮置位，见 `InfoRouteArgs.reopenSourceSheet`）。
   */
  @StorageProp('navShown:pages/InfoPage') @Watch('onNavShown') navShownTick: number = 0;

  onNavShown(): void {
    if (!InfoRouteArgs.reopenSourceSheet) {
      return;
    }
    InfoRouteArgs.reopenSourceSheet = false;
    if (this.pageWidthVp() >= 840) {
      this.openSheet(1);
      return;
    }
    /**
     * 手机：这一拍正好是「从播放页弹回详情页」的路由转场进行中，
     * 此时再弹系统 `bindSheet` 会和转场打架（同 `SHEET_CLOSE_MS` 的注释）。
     * 等转场走完再开。
     */
    setTimeout(() => {
      this.openSheet(1);
    }, InfoPage.SHEET_CLOSE_MS);
  }

  /**
   * 取本番剧「最近一条在线历史」，对应参照实现 `_latestResumeHistory()`：
   * 只认**在线**记录、集数大于 0，多条时取观看时间最新的那条
   * （同一部番可能从不同规则看过，各算一条）。
   */
  private loadResume(): void {
    let latest: HistoryEntry | undefined = undefined;
    const all: HistoryEntry[] = HistoryRepository.getAll();
    for (let i = 0; i < all.length; i++) {
      const entry: HistoryEntry = all[i];
      if (entry.bangumiItem.id !== this.item.id
        || entry.entryKind !== 'online'
        || entry.lastWatchEpisode <= 0) {
        continue;
      }
      if (latest === undefined || latest.lastWatchTime < entry.lastWatchTime) {
        latest = entry;
      }
    }
    if (latest === undefined) {
      this.resumeEpisode = 0;
      this.resumeRoad = 0;
      return;
    }
    this.resumeEpisode = latest.lastWatchEpisode;
    const progress: HistoryProgress | undefined =
      latest.progresses.get(latest.lastWatchEpisode);
    this.resumeRoad = progress === undefined ? 0 : progress.road;
  }

  onBackPress(): boolean {
    if (this.sheetVisible) {
      this.sheetVisible = false;
      this.sheetKind = 0;
      return true;
    }
    // 系统返回手势 / 返回键：先关弹层，再走整页退场（见 `backOut`）
    this.backOut();
    return true;
  }

  /**
   * 需要补拉详情的判据（对应 `_needsBangumiInfoRefresh`）。
   *
   * 参照实现只看「简介 / 评分分布」，本工程额外看「排名 / 标签」——
   * 因为搜索这条链路在 2026-09-19 改成了旧版路由，而旧版响应不带
   * `tags`、排名也不在 `rating.rank` 里（详见下面每条注释）。
   */
  private needsRefresh(): boolean {
    const votesCount: number[] = this.item.votesCount;
    const missingVotes: boolean = votesCount.length === 0 ||
      this.item.votes <= 0 || votesCount.length < 10;
    /**
     * `rank` 缺失也要补一次（用户 2026-09-19：「搜索结果点进去详情页
     * bangumi rank 都是 0」）。
     *
     * 列表页带过来的条目**不一定带排名**：旧版搜索（`/search/subject/…`）
     * 把 `rank` 放在顶层、`rating.rank` 是空的；收藏 / 历史 / 日历进来的条目
     * 甚至整块没有 `rating`。详情接口 `/v0/subjects/{id}` 一定有 `rating.rank`，
     * 所以「这一页显示不了排名」时补拉一次是最经济的修法——
     * 原本只在「简介或评分分布缺失」时才拉，于是来源不同、表现就不同。
     */
    const missingRank: boolean = this.item.rank <= 0;
    /**
     * `tags` 缺失同样要补（用户 2026-09-19：「搜索得到的结果的详情页
     * 标签无法显示」）。
     *
     * 旧版搜索的响应体里**根本没有 `tags` 字段**（实测只有
     * `id/url/type/name/name_cn/summary/eps/air_date/rating/rank/images/collection`），
     * 而详情页的「标签」区只渲染 `item.tags`，于是从搜索进来的条目永远是一片空白。
     * 详情接口 `/p1/subjects/{id}` 带 tags（实测 12 条，`{name,count}`），
     * 所以这里把「没有标签」也算成该补拉的信号。
     *
     * 与参照实现的差异：上游 `_needsBangumiInfoRefresh` 只看简介和评分分布，
     * 因为它的搜索走 v0（响应自带 tags）。我们为了「搜索一直加载不出来」
     * 改走旧版路由（2026-09-19），这里必须跟着补上，否则就是按下葫芦浮起瓢。
     */
    const missingTags: boolean = this.item.tags.length === 0;
    /**
     * 「播出状态判不出来」同样要补拉一次（用户 2026-09-20：
     * 「从时间表点击进入的不显示状态」）。
     *
     * **日历接口（`/p1/calendar`）返回的条目既没有 `platform`、也没有 wiki 文本**，
     * 而 `airingStatus()` 判「TV / WEB」靠的正是这两样——两样都缺就直接
     * 返回 `none`，界面上连「连载中 / 已完结」那一行都不出现。
     * 而这类条目往往简介、评分、标签都齐，`needsRefresh()` 一直是 false，
     * 于是永远不补拉。
     *
     * 判据取「没有 platform 且没有结束日期」：详情接口补一次就能定下来
     * （`/p1/subjects/{id}` 的 wiki 文本里有 `Infobox animanga/TVAnime` 与播放结束），
     * 已经能判出状态的条目不会被反复请求。
     */
    const missingStatus: boolean =
      this.item.platform.length === 0 && !this.item.hasEndField &&
      InfoPage.refreshedIds.indexOf(this.item.id) < 0;
    return this.item.summary.length === 0 || missingVotes || missingRank ||
      missingTags || missingStatus;
  }

  /**
   * 补拉条目详情。
   *
   * 与源码一致：拉回来的字段**只做「补齐」**，不覆盖已经渲染出来的图片地址
   * （图片地址由列表页带过来，可能已经过镜像改写）；同时保证骨架至少显示
   * 600ms，避免闪现。
   */
  private async loadInfo(): Promise<void> {
    this.loadingInfo = true;
    const startedAt: number = Date.now();
    try {
      const value: BangumiItem | null =
        await BangumiApi.getBangumiInfoByID(this.item.id);
      if (value !== null) {
        const merged: BangumiItem = this.item;
        if (value.summary.length > 0) {
          merged.summary = value.summary;
        }
        if (value.tags.length > 0) {
          merged.tags = value.tags;
        }
        if (value.rank > 0) {
          merged.rank = value.rank;
        }
        if (value.airDate.length > 0) {
          merged.airDate = value.airDate;
        }
        if (value.ratingScore > 0) {
          merged.ratingScore = value.ratingScore;
        }
        if (value.votes > 0) {
          merged.votes = value.votes;
        }
        if (value.votesCount.length >= 10) {
          merged.votesCount = value.votesCount;
        }
        if (value.alias.length > 0) {
          merged.alias = value.alias;
        }
        if (value.platform.length > 0) {
          merged.platform = value.platform;
        }
        /**
         * `info` 也要补：`airingStatus()` 在 `platform` 缺失时靠它判「TVAnime」，
         * 而**从「最近在看」进来的条目来自历史记录**，只剩 id/标题/封面，
         * `info` / `platform` 都可能是空的 —— 这时连载中 / 已完结就显示不出来
         * （用户 2026-09-18：「从最近在看点击进入详情页的时候，连载中和已完结
         * 有的时候加载不出来」）。详情接口里这两个字段都有，补齐即可。
         */
        if (value.info.length > 0) {
          merged.info = value.info;
        }
        if (value.hasEndField) {
          merged.hasEndField = true;
          merged.endDate = value.endDate;
        }
        if (value.episodeCountText.length > 0) {
          merged.episodeCountText = value.episodeCountText;
        }
        if (value.eps !== undefined) {
          merged.eps = value.eps;
        }
        if (value.totalEpisodes !== undefined) {
          merged.totalEpisodes = value.totalEpisodes;
        }
        this.item = merged;
        // 记进「已补拉」名单：下一轮 needsRefresh() 不会为「判不出状态」再请求一次
        if (InfoPage.refreshedIds.indexOf(this.item.id) < 0) {
          InfoPage.refreshedIds.push(this.item.id);
          while (InfoPage.refreshedIds.length > InfoPage.REFRESHED_MAX) {
            InfoPage.refreshedIds.shift();
          }
        }
      }
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '详情补拉失败: %{public}s', err.message);
    }
    const elapsed: number = Date.now() - startedAt;
    if (elapsed < InfoMetrics.minSkeletonMs) {
      await this.delay(InfoMetrics.minSkeletonMs - elapsed);
    }
    this.loadingInfo = false;
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private async loadCharacters(): Promise<void> {
    if (this.charactersLoading || this.characters.length > 0 || this.charactersEmpty) {
      return;
    }
    // 自建番没有 Bangumi 数据可查：直接把这一档置成空态，别发请求
    if (this.isLocalItem) {
      this.charactersEmpty = true;
      return;
    }
    this.charactersLoading = true;
    this.charactersFailed = false;
    try {
      const list: CharacterItem[] = await BangumiApi.getCharacterListByID(this.item.id);
      this.characters = list;
      this.charactersEmpty = list.length === 0;
    } catch (error) {
      this.charactersFailed = true;
    }
    this.charactersLoading = false;
  }

  private async loadRelations(): Promise<void> {
    if (this.relationsLoading || this.relationsLoaded) {
      return;
    }
    if (this.isLocalItem) {
      this.relationsLoaded = true;
      return;
    }
    this.relationsLoading = true;
    this.relationsFailed = false;
    try {
      const list: BangumiRelation[] = await BangumiApi.getRelatedAnimeByID(this.item.id);
      this.relations = list;
      this.relationsLoaded = true;
    } catch (error) {
      this.relationsFailed = true;
    }
    this.relationsLoading = false;
  }

  private async loadStaff(): Promise<void> {
    if (this.staffLoading || this.staffList.length > 0 || this.staffEmpty) {
      return;
    }
    if (this.isLocalItem) {
      this.staffEmpty = true;
      return;
    }
    this.staffLoading = true;
    this.staffFailed = false;
    try {
      const list: StaffItem[] = await BangumiApi.getStaffListByID(this.item.id);
      this.staffList = list;
      this.staffEmpty = list.length === 0;
    } catch (error) {
      this.staffFailed = true;
    }
    this.staffLoading = false;
  }

  private onTabChanged(index: number): void {
    this.activeTab = index;
    if (index === 1) {
      this.loadCharacters();
    } else if (index === 2) {
      this.loadRelations();
    } else if (index === 3) {
      this.loadStaff();
    }
  }

  /** 整页只有一个滚动容器，直接读它的位移。 */
  private onPageScroll(): void {
    this.scrollOffset = this.pageScroller.currentOffset().yOffset;
  }

  private title(): string {
    return this.item.nameCn.length > 0 ? this.item.nameCn : this.item.name;
  }

  /** 播出状态（§62.3）。 */
  private airingStatus(): AiringStatus {
    const platform: string = this.item.platform.toUpperCase();
    const isTv: boolean = platform === 'TV' || platform === 'WEB' ||
      (platform.length === 0 && this.item.info.includes('TVAnime'));
    if (!isTv) {
      return AiringStatus.none;
    }
    const start: number = Date.parse(this.item.airDate);
    const now: number = Date.now();
    const hasStart: boolean = !Number.isNaN(start);
    if (this.item.hasEndField) {
      const end: string = this.item.endDate === undefined ? '' : this.item.endDate;
      if (end.trim().length > 0) {
        return AiringStatus.finished;
      }
      if (hasStart && start > now) {
        return AiringStatus.notStarted;
      }
      return AiringStatus.airing;
    }
    if (hasStart && start > now) {
      return AiringStatus.notStarted;
    }
    if (this.item.episodeCountText.trim() === '*') {
      return AiringStatus.airing;
    }
    const eps: number | undefined = this.item.eps;
    const total: number | undefined = this.item.totalEpisodes;
    if (eps !== undefined && total !== undefined && total > 0 && eps > 0) {
      const finished: boolean = eps >= total && hasStart &&
        start < now - 365 * 24 * 3600 * 1000;
      return finished ? AiringStatus.finished : AiringStatus.airing;
    }
    return AiringStatus.airing;
  }

  // ============================================================
  // 追番状态（多形态）
  // ============================================================

  /**
   * 六个追番状态（0 = 未追，1–5 与 Bangumi 的收藏值一致）。
   *
   * 与播放页顶栏那颗追番按钮**完全同源**（`VideoPage.collectIconOf` /
   * `collectLabelOf`）：图标随状态变，点开是六项菜单，当前项禁用。
   * 用户 2026-09-17 要求详情页「同理改成多形式」——原来这里是个简单开关，
   * 只能在「追番 / 已追番」之间来回切，切不到「想看 / 搁置 / 看过 / 抛弃」。
   */
  private static collectIconOf(type: number): Resource {
    if (type === 1) {
      return $r('sys.symbol.heart_fill');
    }
    if (type === 2) {
      return $r('sys.symbol.star_fill');
    }
    if (type === 3) {
      return $r('sys.symbol.clock');
    }
    if (type === 4) {
      return $r('sys.symbol.checkmark');
    }
    if (type === 5) {
      return $r('sys.symbol.trash');
    }
    return $r('sys.symbol.heart');
  }

  private static collectLabelOf(type: number): string {
    const labels: string[] = ['未追', '在看', '想看', '搁置', '看过', '抛弃'];
    return labels[type];
  }

  /** 按钮上的文案：未追时显示动作「追番」，其余显示当前状态。 */
  private collectButtonLabel(): string {
    return this.collectType > 0 ? InfoPage.collectLabelOf(this.collectType) : '追番';
  }

  /** 选状态：0 = 取消追番。 */
  private setCollectType(type: number): void {
    if (type === 0) {
      CollectStore.remove(this.item.id);
    } else {
      CollectStore.upsert(this.toEntry(type));
    }
    this.collectType = type;
  }

  /** 六项追番菜单：当前项禁用（与播放页顶栏追番菜单同一形态）。 */
  @Builder
  collectMenu() {
    Menu() {
      ForEach([0, 1, 2, 3, 4, 5], (type: number) => {
        MenuItem({
          content: InfoPage.collectLabelOf(type),
          startIcon: InfoPage.collectIconOf(type)
        })
          .enabled(type !== this.collectType)
          .onClick(() => {
            this.setCollectType(type);
          })
      }, (type: number) => `info-collect-${type}`)
    }
  }

  /** 自建番的「添加时间」文案（YYYY-MM-DD；没记到就给横杠）。 */
  private addedAtText(): string {
    if (this.localCreatedAt <= 0) {
      return '—';
    }
    const d: Date = new Date(this.localCreatedAt);
    const month: number = d.getMonth() + 1;
    const day: number = d.getDate();
    return `${d.getFullYear()}-${month < 10 ? '0' : ''}${month}` +
      `-${day < 10 ? '0' : ''}${day}`;
  }

  private toEntry(type: number): CollectEntry {    const entry = new CollectEntry();
    entry.id = this.item.id;
    entry.name = this.item.name;
    entry.nameCn = this.item.nameCn;
    entry.cover = this.item.coverUrl();
    // 这三项以前没往下传，结果追番页卡片的「年 · 评分」和集数一直是空的，
    // 而详情页手上本来就有（`BangumiItem` 的 date / rating / episodeCount）。
    entry.airDate = this.item.airDate;
    entry.score = this.item.ratingScore;
    entry.epsTotal = this.item.episodeCount();
    entry.collectType = type;
    entry.updatedAt = Date.now();
    return entry;
  }

  /**
   * 页面本体（原来就是整个 `build`）。
   *
   * 抽出来只为一件事：**退场时自绘的飞行层必须待在整页淡出/下移之外**——
   * 它要一直保持不透明、不跟着页面下移（参照实现里 Hero 画在 overlay 里，
   * 正是这个道理）。见下面的 `build()`。
   */
  @Builder
  pageBody() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // ---- 背景：模糊海报 + 蒙层 + 五段渐变（§9.1） ----
      this.poster()

      /**
       * 这里原来有一层「顶部渐变遮罩」（`Column().height(topInset + 72)` +
       * surface→透明 的 `linearGradient`），2026-09-18 已删除。
       *
       * 它正是用户反复反馈的「背景从『继续观看』按钮往下是一整个白块」——
       * 不是海报、不是卡片、也不是渐变停靠点的问题：
       *
       *   根容器是 `Stack({ alignContent: Alignment.BottomEnd })`（为了把右下角
       *   的悬浮按钮放定位），而 `Stack.alignContent` 会作用到**所有没有铺满
       *   容器的子节点**。这层遮罩只有 `topInset + 72`（本机 = 108vp）高、
       *   宽 100%，于是被摆到了**屏幕底部**：它自己的渐变是「上端
       *   `surface` @92% → 下端全透明」，落到屏幕上就变成一条
       *   **距底 108vp 处硬边起头、向下渐隐、横向铺满**的近白块。
       *   （真机 A/B 复核：把 108vp 那一层临时染成绿色，白块整块变绿；
       *   同一份截图与 `详情页美化/` 里那四张底部逐像素一致。）
       *
       * 为什么是**删掉**而不是挪回顶部：
       *   本页顶栏标题是白字（`headerBar()` 用 `#FFFFFF`），顶部压暗本来就由
       *   `poster()` 的海报暗角渐变负责（`#99000000` → `#4D000000` → 透明）。
       *   再叠一层近白 `surface` 反而会把白字洗掉——参考图里顶部就是纯海报暗角。
       *   历史页/推荐页那层同类遮罩能用，是因为它们顶部是**深色文字** + 浅色页面底。
       *
       * 另外：`Stack.alignContent` 这个坑对新加的子节点同样成立——以后往这个
       * Stack 里放任何非铺满的子节点，都会被摆到右下角，除非自己套一层
       * 铺满容器的 `Stack({ alignContent: ... })`。
       */

      /**
       * 整页只有**一个滚动容器**（用户 2026-09-17：「下滑的意思就是所有东西
       * 在同一图层」）。
       *
       * 原来是三层：固定顶栏 + 会收缩的信息卡 + 固定 Tab 条 + 四个各自滚动的
       * Swiper 页。现在标题行、信息卡、Tab 条、当前 Tab 的正文全部排进同一个
       * `Scroll`，下滑时整页一起走。
       *
       * 代价（已知并接受）：**Tab 切换只剩点击**。原来靠 Swiper 的横向滑动，
       * 而 Swiper 必须占一块固定区域，那就又变成「内容在动、外框不动」的两层；
       * 另外四个 Tab 各放一份信息卡会让主海报的共享元素 tag 出现四份，
       * 封面动画会从错误的卡片起飞（历史页踩过同一个坑）。
       */
      Scroll(this.pageScroller) {
        Column() {
          this.headerBar()
          this.flexibleSpace()
          // 自建番只有「简介」一档，没有角色 / 关联 / Staff，Tab 条整条不画
          if (!this.isLocalItem) {
            this.tabBarRow()
          }

          /**
           * 四个 Tab 的正文，**支持左右滑动切换**（用户 2026-09-18）。
           *
           * 之前这里是裸的 if/else，只能点 Tab 条；移植时为了「整页只有一个
           * 滚动容器」去掉了 Swiper（Swiper 必须占固定区域，会变成两层滚动）。
           * 这里改用**横向 PanGesture**：纵向照旧由外层 Scroll 负责，
           * 横向滑动落到这一层就切 Tab，既保留单容器滚动又能滑。
           */
          Column() {
            if (this.isLocalItem || this.activeTab === 0) {
              this.overviewPage()
            } else if (this.activeTab === 1) {
              this.characterPage()
            } else if (this.activeTab === 2) {
              this.relationPage()
            } else {
              this.staffPage()
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          // 同信息卡：正文列在大屏上一起收窄居中（见 `wideInset()`）
          .padding({ left: this.wideInset(), right: this.wideInset() })
          /**
           * 切 Tab 的过渡：淡出/淡入 + 按方向横移（数值用 vp，避免百分比模板串
           * 在 Rollup 里被判成非法 token）。补间由下面的 `.animation()` 提供。
           */
          .opacity(this.tabFade)
          .translate({ x: this.tabDir * (1 - this.tabFade) * 20 })
          .animation({ duration: 150, curve: AppCurves.easeOutCubic() })
          .gesture(
            PanGesture({ direction: PanDirection.Horizontal, distance: 24 })
              .onActionEnd((event: GestureEvent) => {
                // 滑得不够远（<48vp）或滑得太"斜"（纵向更多）就不切
                const dx: number = event.offsetX;
                if (Math.abs(dx) < 48 || Math.abs(dx) < Math.abs(event.offsetY)) {
                  return;
                }
                const next: number = dx < 0 ? this.activeTab + 1 : this.activeTab - 1;
                if (next < 0 || next > 3 || next === this.activeTab) {
                  return;
                }
                this.animateToTab(next);
              })
          )
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        /**
         * 内容至少撑满一屏。
         *
         * `Scroll` 里的内容比视口短时，内容会被摆到**中间**——自建番只有
         * 「添加时间 / 总集数 + 简介」，正好短于一屏，于是整页（连顶栏的
         * 返回键）都往下缩了一截（用户 2026-10-31 的两张对比图：在线番从
         * 顶部开始，自建番整体下沉）。
         * 给个 minHeight + 从顶排列，短内容也贴着上面。
         */
        .constraintSize({ minHeight: '100%' })
        .justifyContent(FlexAlign.Start)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onDidScroll(() => {
        this.onPageScroll();
      })

      // ---- 开始观看（§9.2 的 floatingActionButton） ----
      if (this.ready) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.play_circle_fill'))
            .fontSize(20)
            .fontColor([AppColor.onPrimaryContainer])
          Text(this.resumeEpisode > 0
            ? `继续观看 第${this.resumeEpisode}集` : '开始观看')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.onPrimaryContainer)
        }
        .height(52)
        .padding({ left: 20, right: 20 })
        .backgroundColor(AppColor.primaryContainer)
        .borderRadius(26)
        .shadow({ radius: 20, color: '#33000000', offsetX: 0, offsetY: 6 })
        .margin({ right: 16, bottom: 20 + this.bottomInset })
        .onClick(() => {
          this.openSheet(1);
        })
      }

      /**
       * 大屏的播放来源自绘弹层（见 `sourceOverlayLayer`）。放在最上层，
       * 盖住「开始观看」FAB 与整页内容。手机走系统 `bindSheet`，这里不画。
       */
      if (this.sourceOverlay) {
        this.sourceOverlayLayer()
      }

      /**
       * 退场转场期间的**吞触摸层**。
       *
       * 参照实现里正在退场的路由是 `IgnorePointer`（`_ModalScopeState`）：那 300ms
       * 里点到的东西都不该有反应。这里不铺的话，详情页在淡出、手指点到的是
       * **底下的首页**——会直接把另一部番打开。
       */
      if (this.exiting) {
        Column()
          .width('100%')
          .height('100%')
          .onClick(() => {
            // 只吞事件，不做任何事
          })
      }
    }
    .width('100%')
    .height('100%')
    // 兜底底色（用户要求改回近白）。实测压深也没用——白条不来自这一层，
    // 而是下面 Index 的 AppBackground 露出来了，见 `Dest()` 的修复。
    /**
     * ⚠️ 整页进场淡入期间（`enterOpacity < 1`）这层兜底底色必须是**透明**的：
     * 否则海报淡出的那几帧露出来的是这层近白，会闪一下白；透明之后透出的是
     * 下面那一页，才是真正的交叉淡化。静止时仍然是近白（用户 2026-09-18 的要求）。
     *
     * ⚠️ **退场同样要透明**（`this.exiting`），而且必须**立刻**透明：
     * 退场是「本页还在，靠淡出把下面那一页露出来」，如果这一层近白留到最后一刻，
     * 露出来的就是一块白屏——用户 2026-10-08 反馈的「封面回到原位但周围是白屏」
     * 就是它（封面是自绘飞行层、不在这一层里，所以只有封面是对的）。
     * 判据挂 `exiting` 而不是跟着 `enterOpacity` 算，就是为了**不等动画**：
     * 点下去那一帧底色就得让开。
     */
    .backgroundColor(this.exiting || this.enterOpacity < 1 ? '#00000000' : AppColor.surface)
    // 整页进场：Fade + Slide(2%)，与封面飞行并行（见 `enterOpacity` 的注释）
    .opacity(this.enterOpacity)
    .translate({ y: `${this.enterSlide * 100}%` })
    /**
     * 沉浸式：把状态栏与底部手势区都吃进来。
     *
     * 迁移到 NavDestination 之后，目的地默认按安全区收缩——底部会留一条
     * 约 28vp 的空档，而根节点铺的又是 `AppColor.surface`（近白），
     * 于是**海报最下方露出一条白边**（用户反馈的现象）。
     * `Dest()` 里那个 `expandSafeArea` 加在 NavDestination 本身上，
     * 不保证内容跟着扩；照参考实现（夏绊）的写法，
     * `expandSafeArea` 要加在**页面自己的根容器**上。
     */
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // 两个弹层共用一个 bindSheet，内容按 `sheetKind` 切换（见字段注释）
    .bindSheet($$this.sheetVisible, this.sheetContent(), {
      // 播放来源半页（用户要求「不要太大」）；角色详情资料多，给大页
      height: this.sheetKind === 2 ? SheetSize.LARGE : SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      // 不设 backgroundColor：交给系统画默认的弹层底（用户要求「跟系统一致」）。
      // 之前写死 `AppColor.surfaceContainerLow`（M3 中性色）是自绘的观感，
      // 和系统弹窗摆在一起就是两种白。
      onDisappear: () => {
        this.sheetVisible = false;
        this.sheetKind = 0;
      }
    })
    // 根容器实测宽度：详情页所有「大屏」判断都基于它（见 `pageWidthVp()`）
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width: number = Number(newValue.width);
      if (width > 0 && Math.abs(width - this.viewportWidth) > 0.5) {
        this.viewportWidth = width;
      }
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.pageBody()

      /**
       * 共享元素退场的**自绘飞行层**（shuttle）。
       *
       * 为什么自己画：ArkUI 的共享元素转场（`geometryTransition`）要由**路由动作**
       * 触发，而我们的退场是「整页自己淡出、弹栈放到动画之后」（见 `backOut`）——
       * 没有路由动作，框架那一端就不会有人接住封面。所以这里照着 Flutter 的
       * `Hero` 做同一件事：在**页面之上**单画一层，把封面从详情页的位置送到
       * 卡片的位置（两端坐标来自 `HeroRects`）。
       *
       * 它在 `pageBody()` 之外：不进淡出、不跟着页面下移，因此那一层永远是
       * 清晰不透明的——与 Flutter 把 shuttle 画在 navigator overlay 里一致。
       */
      if (this.heroFly) {
        CoverImage({
          src: this.heroFlyUrl.length > 0 ? this.heroFlyUrl : $r('app.media.icon'),
          fit: ImageFit.Cover,
          radius: this.ws(12)
        })
          .width(this.heroFlyW)
          .height(this.heroFlyH)
          .position({ x: this.heroFlyX, y: this.heroFlyY })
          .backgroundColor(AppColor.surfaceContainerHigh)
          .borderRadius(this.ws(12))
          .clip(true)
          .zIndex(10)
          // 只是画面，飞行途中不能吃触摸
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 打开底部弹层：1 = 播放来源，2 = 角色详情。 */
  private openSheet(kind: number): void {
    /**
     * 播放来源在大屏走自绘弹层（见 `sourceOverlay`）：系统 sheet 在平板上
     * 只有 360vp 宽，卡片挤成一条。角色详情那档资料多，继续用系统大页。
     */
    if (kind === 1 && this.pageWidthVp() >= 840) {
      this.sourceOverlay = true;
      return;
    }
    this.sheetKind = kind;
    this.sheetVisible = true;
  }

  /** 弹层内容：两个弹层共用同一个 bindSheet。 */
  @Builder
  sheetContent() {
    if (this.sheetKind === 2) {
      CharacterSheet({
        themeRev: this.themeRevision,
        characterId: this.chId,
        characterName: this.chName,
        characterRelation: this.chRelation,
        actorNames: this.chActors
      })
    } else {
      this.sourceSheet()
    }
  }

  @Builder
  poster() {
    /**
     * 具体图层（模糊海报 + 蒙层 + 五段渐变）抽到了 `components/DetailBackdrop`
     * （那两层参数多、又容易改漏，单独放一处）。这里只负责传封面。
     */
    DetailBackdrop({
      cover: this.item.cover.length > 0 ? this.item.coverUrl() : '',
      // 整页的淡入淡出由页面根节点负责（见 `enterOpacity`），这一层不单独动。
      layerOpacity: 1,
      slideRatio: 0
    })
  }

  /** 把当前表面色按给定透明度合成 `#AARRGGBB`。 */
  private surfaceWithAlpha(alpha: number): string {
    const base: string = AppColor.surface;
    const a: string = Math.round(alpha * 255).toString(16).toUpperCase().padStart(2, '0');
    return `#${a}${base.substring(1)}`;
  }

  @Builder
  headerBar() {
    Row() {
      SymbolGlyph($r('sys.symbol.arrow_left'))
        .fontSize(22)
        .fontColor(['#FFFFFF'])
        .padding({ left: 8, right: 8 })
        .onClick(() => {
          this.backOut();
        })
      Text(this.title())
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 4 })
      // 顶栏的收藏图标按用户要求去掉：追番入口只留信息卡里那一个，
      // 避免同一页两处入口、两种形态。顶栏只保留「返回 + 标题」。
    }
    .width('100%')
    .height(InfoMetrics.toolbar)
    .padding({ left: 8, right: 12 })
    .margin({ top: this.topInset })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  flexibleSpace() {
    // 信息卡就是滚动内容里的普通一项：不再收缩、不再单独位移。
    // （原来靠 `flexibleHeight()` 把容器从 322 收到 0，卡片被压扁 + 裁掉，
    // 和正文不是同一层运动——那正是用户反馈的问题。）
    Column() {
      this.infoCard()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    /**
     * 大屏（平板 / 横屏）居中收窄：参照实现的信息卡有 `maxWidth: 950`，
     * 平板上整宽铺开的话，「番剧名 + 评分 + 简介」这条信息流会横跨 1400vp。
     * 背景海报 `poster()` 仍是整幅，只有内容这一列收窄。
     */
    .padding({ left: this.wideInset(), right: this.wideInset() })
    /**
     * 关键：`zIndex` 只在**同一个父容器内**排序。
     *
     * 详情页的层级是 `Stack { poster ; Scroll { 标题行 ; 信息卡 ; Tab条 ; 正文 } ; FAB }`——
     * 飞行中的海报在信息卡里面，它和信息卡的兄弟节点是「信息卡内部那几个」，
     * 所以写在海报上的 zIndex 盖不住同一 Column 里的 Tab 条与正文。
     * 把 zIndex 提到**信息卡这一层**，整张卡（连同封面）才会浮在其余内容之上。
     */
    .zIndex(1)
  }

  @Builder
  tabBarRow() {
    Row() {
      this.tabItem(0, '概览')
      this.tabItem(1, '角色')
      this.tabItem(2, '关联')
      this.tabItem(3, '制作人员')
    }
    .width('100%')
    // 大屏 Tab 条一起放大（见 `wideScale()`）
    .height(this.ws(InfoMetrics.tabBar))
    .backgroundColor('#00000000')
  }

  @Builder
  tabItem(index: number, label: string) {
    Column({ space: this.ws(6) }) {
      Text(label)
        .fontSize(this.ws(14))
        .fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.activeTab === index ? '#FFFFFF' : '#B3FFFFFF')
      Column()
        .width(this.ws(20))
        .height(this.ws(2.5))
        .borderRadius(2)
        .backgroundColor(this.activeTab === index ? '#FFFFFF' : '#00000000')
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      if (this.activeTab !== index) {
        // 点 Tab 条与左右滑动共用同一条过渡路径（见 `animateToTab`）
        this.animateToTab(index);
      }
    })
  }

  // ============================================================
  // 信息卡（§62）
  // ============================================================

  @Builder
  infoCard() {
    Column() {
      Text(this.title())
        // 参照实现用 `headlineSmall`（M3 = 24），原来这里是 20，标题偏小
        .fontSize(this.ws(24))
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.isDark ? '#FFFFFF' : '#1B1B1F')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      /**
       * 信息行：**封面按行高自适应**，宽度由 0.65 的宽高比反推。
       *
       * 对照参照实现 `bangumi_info_card.dart:180-205`：
       *   `Expanded(Row(crossStart, [Flexible(AspectRatio(0.65, Hero(封面))),
       *                    SizedBox(width: 16),
       *                    Flexible(Column(spaceBetween, 元数据 + 追番按钮))]))`
       * 之前这里是**写死**的封面尺寸（手机 124×191、平板 210×323），卡片一放大
       * 封面就跟不上，整卡比例也不是原版那样。现在封面撑满整行高度、卡片多高
       * 它就多大（用户 2026-10-08：「学一下 flutter 版本的比例、封面调大一点」）。
       */
      Row({ space: this.ws(16) }) {
        // Hero 共享元素（§38.7）：两端写**同一个 id** 即可，**不要**写 `follow`。
        // id 由源页经路由参数传来，参数与 Flutter 的 Hero 对齐见 `HeroFlight`。
        CoverImage({
          src: this.item.cover.length > 0 ? this.item.coverUrl() : $r('app.media.icon'),
          fit: ImageFit.Cover,
          radius: this.ws(12)
        })
          // 撑满整行高度，宽度 = 高度 × 0.65（同参照实现的 AspectRatio(0.65)）
          .height('100%')
          .aspectRatio(0.65)
          .backgroundColor(AppColor.surfaceContainerHigh)
          .borderRadius(this.ws(12))
          .clip(true)
          /**
           * 对照参考实现（`F:\app` 夏绊）：源卡片与详情页封面都是裸的
           * `geometryTransition('bookcover_<id>_<suffix>')`，谁都没写 options。
           * 真正让封面「滑」起来的是**路由动作被 `animateTo` 包住**
           * （进场见 `NavHost.pushWithHero`；退场由自绘飞行层负责，见 `backOut`）。
           */
          .geometryTransition(this.heroTag)
          // 退场时藏起来，由自绘飞行层顶替（藏而不摘：布局不动、也不触发框架转场）
          .visibility(this.coverHidden ? Visibility.Hidden : Visibility.Visible)
          // 记下这张封面在**窗口**里的位置：退场飞行要用它当起点（见 HeroRects）
          .onAreaChange((oldValue: Area, newValue: Area) => {
            HeroRects.setDetail(this.heroTag, newValue);
          })
          // 飞行中的海报要盖在详情页内容之上，否则到达时会被信息卡压住
          .zIndex(1)

        Column() {
          // 上半：元数据（参照实现里这一列是 spaceBetween，追番按钮贴底）
          Column() {
          if (this.loadingInfo) {
            Column({ space: 10 }) {
              Column().width(120).height(16).borderRadius(8)
                .backgroundColor(AppColor.surfaceContainerHighest)
              Column().width(96).height(18).borderRadius(9)
                .backgroundColor(AppColor.surfaceContainerHighest)
              Column().width(110).height(16).borderRadius(8)
                .backgroundColor(AppColor.surfaceContainerHighest)
            }
            .alignItems(HorizontalAlign.Start)
          } else {
            if (this.isLocalItem) {
              /**
               * 自建番：没有放送日期、评分、排名，这三块换成「添加时间」。
               * 保留这三行只会显示一串「—」和「***」，不如直接给一个真实信息。
               */
              Text('添加时间:').fontSize(this.ws(14)).fontColor(AppColor.onSurface)
              Text(this.addedAtText())
                .fontSize(this.ws(20))
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.primary)
              Text('总集数:')
                .fontSize(this.ws(14))
                .fontColor(AppColor.onSurface)
                .margin({ top: this.ws(8) })
              Text(this.item.episodeCount() > 0
                ? `${this.item.episodeCount()} 集` : '—')
                .fontSize(this.ws(20))
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.primary)
            } else {
            if (this.airingStatus() !== AiringStatus.none) {
              this.airingBadge()
            }
            /**
             * 三个标签在参照实现里都**没有**显式 style / 颜色，走的是主题默认
             * （`bodyMedium` 14 + `onSurface`）。我们原来用的是 `onSurfaceVariant`
             * （偏灰），比原版淡一档；用户 2026-10-08：「信息层的字体颜色参考
             * flutter 调整」——所以改回 `onSurface`。
             */
            Text('放送开始:').fontSize(this.ws(14)).fontColor(AppColor.onSurface)
            Text(this.item.airDate.length > 0 ? this.item.airDate : '—')
              .fontSize(this.ws(20))
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.primary)
            Text(this.showRating ? `${this.item.votes} 人评分:` : '*** 人评分:')
              .fontSize(this.ws(14))
              .fontColor(AppColor.onSurface)
              .margin({ top: this.ws(8) })
            Row({ space: this.ws(8) }) {
              Text(this.showRating ? `${this.item.ratingScore}` : '***')
                .fontSize(this.ws(16))
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.primary)
              this.stars()
            }
            Text('Bangumi Ranked:')
              .fontSize(this.ws(14))
              .fontColor(AppColor.onSurface)
              .margin({ top: this.ws(8) })
            Text(this.showRating ? `#${this.item.rank}` : '***')
              .fontSize(this.ws(20))
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.primary)
            }
          }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 下半：追番按钮贴底（对照参照实现 Column(mainAxisAlignment: spaceBetween)）
          // 位置：参照实现这一列是 `crossAxisAlignment: start`，120 宽的按钮
          // 靠**左**落在元数据下方（原来是靠右，看着偏）。
          Row() {
            this.collectButton()
          }
          .width('100%')
          .justifyContent(FlexAlign.Start)
        }
        .layoutWeight(1)
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.SpaceBetween)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(VerticalAlign.Top)
      .margin({ top: this.ws(16) })
    }
    .width('100%')
    // 卡片高度：手机 300（参照实现原值），大屏乘同一套放大系数（见 `wideScale`）
    .height(this.ws(InfoMetrics.cardHeight))
    /**
     * 只留左右内边距：参照实现的卡片容器是固定 300 高、**没有**底部内边距
     * （信息列 `spaceBetween`，追番按钮就贴卡片下缘）。原来那 14 的底距会把
     * 信息行整体压缩，封面跟着变小，比例就对不上原版了。
     */
    .padding({ left: this.ws(16), right: this.ws(16) })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  stars() {
    Row({ space: 2 }) {
      ForEach([0, 1, 2, 3, 4], (index: number) => {
        SymbolGlyph($r(index < Math.round(this.item.ratingScore / 2)
          ? 'sys.symbol.star_fill' : 'sys.symbol.star_fill'))
          // 参照实现的 RatingBarIndicator `itemSize: 20.0`
          .fontSize(this.ws(20))
          .fontColor([index < Math.round(this.item.ratingScore / 2)
            /**
             * 点亮的那几颗＝`colorScheme.primary`（参照实现写死 primary）；
             * 未点亮的＝`Theme.of(context).disabledColor`＝`onSurface` 38%——
             * 我们原来用的是 `outlineVariant`（更浅一档），按原版换掉。
             */
            ? AppColor.primary : AppColor.withAlpha(AppColor.onSurface, 0.38)])
        // 星级跟着评分变，key 必须带上当前分值，否则补拉回来的评分不会重画
      }, (index: number) => `star-${index}-${Math.round(this.item.ratingScore)}`)
    }
  }

  @Builder
  collectButton() {
    Row({ space: this.ws(6) }) {
      SymbolGlyph(InfoPage.collectIconOf(this.collectType))
        .fontSize(this.ws(18))
        .fontColor([AppColor.onPrimary])
      Text(this.collectButtonLabel())
        .fontSize(this.ws(14))
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.onPrimary)
    }
    .width(this.ws(120))
    .height(this.ws(40))
    .justifyContent(FlexAlign.Center)
    .borderRadius(this.ws(20))
    /**
     * 配色对齐参照实现：那边的追番按钮是 `FilledButton.icon`
     * （`collect_button.dart:96`），M3 里 `FilledButton` 的容器 / 内容色就是
     * `primary` / `onPrimary`——**实心主色**，而不是我们之前用的
     * `primaryContainer`（那种偏淡的 tonal 底）。
     *
     * 之前那版是从「细描边幽灵按钮」改到 `primaryContainer` 的（当时用户要求
     * 「明显一点」）——现在按 Flutter 版改回 `primary`，比 tonal 更醒目。
     */
    .backgroundColor(AppColor.primary)
    // 原生菜单：挂在内置容器上、且不写空 onClick（本工程实测的可用组合）
    .bindMenu(this.collectMenu(), {
      placement: Placement.BottomLeft
    })
  }

  @Builder
  airingBadge() {
    Row({ space: this.ws(7) }) {
      Column()
        .width(7)
        .height(7)
        .borderRadius(4)
        .backgroundColor(this.airingColor())
      Text(this.airingLabel())
        .fontSize(this.ws(13))
        .fontWeight(FontWeight.Bold)
        .fontColor(this.airingColor())
        .letterSpacing(1.2)
    }
    .padding({
      left: this.ws(12),
      right: this.ws(12),
      top: this.ws(6),
      bottom: this.ws(6)
    })
    // 参照实现：角标之后 `SizedBox(height: 12)` 才是「放送开始:」
    .margin({ bottom: this.ws(12) })
    .borderRadius(999)
    .backgroundColor(this.airingColorWithAlpha(0.13))
    .border({ width: 1, color: this.airingColorWithAlpha(0.28) })
    .margin({ bottom: 12 })
  }

  private airingColor(): string {
    const status: AiringStatus = this.airingStatus();
    if (status === AiringStatus.finished) {
      return '#E5484D';
    }
    if (status === AiringStatus.airing) {
      return '#3B82F6';
    }
    return '#607D8B';
  }

  private airingColorWithAlpha(alpha: number): string {
    const hex: string = this.airingColor().substring(1);
    const a: string = Math.round(alpha * 255).toString(16).toUpperCase().padStart(2, '0');
    return `#${a}${hex}`;
  }

  private airingLabel(): string {
    const status: AiringStatus = this.airingStatus();
    if (status === AiringStatus.finished) {
      return '完结';
    }
    if (status === AiringStatus.airing) {
      return '连载中';
    }
    return '未开播';
  }

  // ============================================================
  // 四个 Tab 的内容
  // ============================================================

  @Builder
  overviewPage() {
    Column() {
        Column() {
          Text('简介').fontSize(this.ws(18)).fontColor(AppColor.onSurface)
            .width('100%')
          Text(this.item.summary.length > 0 ? this.item.summary : '暂无简介')
            .fontSize(this.ws(14))
            .lineHeight(this.ws(21))
            .fontColor(AppColor.onSurfaceVariant)
            .maxLines(this.fullIntro ? 300 : 7)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: this.ws(8) })
          if (this.item.summary.length > 220) {
            Text(this.fullIntro ? '加载更少' : '加载更多')
              .fontSize(this.ws(13))
              .fontColor(AppColor.primary)
              .alignSelf(ItemAlign.End)
              .margin({ top: this.ws(6) })
              .onClick(() => {
                this.fullIntro = !this.fullIntro;
              })
          }
          // 自建番没有标签，连「标签」这个标题一起不画（用户 2026-10-31：只保留简介）
          if (!this.isLocalItem) {
            Text('标签').fontSize(this.ws(18)).fontColor(AppColor.onSurface)
              .width('100%')
              .margin({ top: 16 })
            this.tagWrap()
          }
        }
        .width('100%')
        .padding(20)
        .borderRadius(28)
        /**
         * 半透明 + 模糊（用户 2026-09-18：那条白就是这张卡）。
         *
         * 实测四张截图的中心列剖面：距屏幕底 20% 往上全是 `#FFF8F5`
         * ——正是 `AppColor.surface`，也就是这张卡。它一直是白的，
         * 而卡的底边（距底 20%）在模糊海报上切出一条横线，
         * 看起来就是「遮罩层断开了」。
         *
         * 所以这里不再用不透明底：降到 72% 并叠一层系统材质，
         * 海报从卡下面透出来、卡的存在感只剩一层薄纱，正文依旧压得住。
         * 想更透就把 0.72 往 0.55 调；想更实就往 0.85 调。
         */
        .backgroundBlurStyle(AppMaterial.cardStrong, AppMaterial.options())
        .backgroundColor(AppColor.withAlpha(AppColor.surface, 0.72))
      }
      .width('100%')
     .padding({
       left: 16,
       right: 16,
       top: 16,
       bottom: 120 + this.bottomInset
     })
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  tagWrap() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.visibleTags(), (tag: BangumiTag) => {
        Row({ space: this.ws(4) }) {
          Text(tag.name).fontSize(this.ws(13)).fontColor(AppColor.onSurface)
          Text(`${tag.count}`).fontSize(this.ws(13)).fontColor(AppColor.primary)
        }
        .padding({
          left: this.ws(12),
          right: this.ws(12),
          top: this.ws(6),
          bottom: this.ws(6)
        })
        .margin({ right: this.ws(8), top: this.ws(8) })
        .borderRadius(this.ws(8))
        .border({ width: 1, color: AppColor.outlineVariant })
        .onClick(() => {
          SearchRouteArgs.openTag(tag.name);
        })
      }, (tag: BangumiTag) => `tag-${tag.name}`)
      if (!this.fullTag && this.item.tags.length > 13) {
        Text('更多 +')
          .fontSize(this.ws(13))
          .fontColor(AppColor.primary)
          .padding({
            left: this.ws(12),
            right: this.ws(12),
            top: this.ws(6),
            bottom: this.ws(6)
          })
          .margin({ right: this.ws(8), top: this.ws(8) })
          .borderRadius(this.ws(8))
          .border({ width: 1, color: AppColor.outlineVariant })
          .onClick(() => {
            this.fullTag = true;
          })
      }
    }
    .width('100%')
    .margin({ top: 8 })
  }

  private visibleTags(): BangumiTag[] {
    if (this.fullTag || this.item.tags.length <= 13) {
      return this.item.tags;
    }
    return this.item.tags.slice(0, 12);
  }

  @Builder
  characterPage() {
    Column() {
        if (this.characters.length > 0) {
          ForEach(this.characters, (character: CharacterItem) => {
            this.characterRow(character)
          }, (character: CharacterItem) => `char-${character.id}`)
        } else if (this.charactersFailed) {
          this.failureBlock('角色列表加载失败', () => {
            this.charactersFailed = false;
            this.loadCharacters();
          })
        } else if (this.charactersEmpty) {
          this.emptyBlock('暂无角色信息', $r('sys.symbol.person_2'))
        } else {
          ForEach([0, 1, 2, 3, 4], (index: number) => {
            this.skeletonRow()
          }, (index: number) => `char-skeleton-${index}`)
        }
      }
      .width('100%')
      .padding({ top: 8, bottom: 120 + this.bottomInset })
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  characterRow(character: CharacterItem) {
    Row() {
      // 角色头像来自 api.bgm.tv，渲染前过一遍镜像改写（见 BangumiImageUrlRewriter）
      Image(character.gridImage.length > 0
        ? BangumiImageUrlRewriter.rewriteWithSettings(character.gridImage)
        : $r('app.media.icon'))
        .width(40)
        .height(40)
        .borderRadius(20)
        .objectFit(ImageFit.Cover)
        .backgroundColor(AppColor.surfaceContainerHighest)
      Column() {
        Text(character.name)
          .fontSize(15)
          .fontColor(AppColor.onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (character.actorList.length > 0) {
          Text(character.actorList[0].name)
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 14 })
      Text(character.relation)
        .fontSize(13)
        .fontColor(AppColor.onSurfaceVariant)
    }
    .width('100%')
    .height(64)
    .padding({ left: 16, right: 16 })
    // 点角色进角色详情页（对应源码点击 `CharacterCard` →
    // `CharacterPage`）。关系与声优一起带过去，接口没回来时标题就已经是对的。
    .onClick(() => {
      const actors: string[] = [];
      for (let i = 0; i < character.actorList.length; i++) {
        actors.push(character.actorList[i].name);
      }
      // 点角色 → 底部弹层（对应源码：`CharacterPage` 是 MaterialBottomSheet）
      this.chId = character.id;
      this.chName = character.name;
      this.chRelation = character.relation;
      this.chActors = actors;
      this.openSheet(2);
    })
  }

  @Builder
  relationPage() {
    Column() {
        if (this.relations.length > 0) {
          ForEach(this.relations, (relation: BangumiRelation) => {
            this.relationCard(relation)
          }, (relation: BangumiRelation) => `rel-${relation.bangumiItem.id}`)
        } else if (this.relationsFailed) {
          this.failureBlock('关联条目加载失败', () => {
            this.relationsFailed = false;
            this.loadRelations();
          })
        } else if (this.relationsLoaded) {
          this.emptyBlock('暂无关联条目', $r('sys.symbol.list_bullet'))
        } else {
          ForEach([0, 1, 2], (index: number) => {
            this.skeletonRow()
          }, (index: number) => `rel-skeleton-${index}`)
        }
      }
      .width('100%')
      .padding({
        left: 16,
        right: 16,
        top: 16,
        bottom: 120 + this.bottomInset
      })
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  relationCard(relation: BangumiRelation) {
    Row() {
      CoverImage({
        src: relation.bangumiItem.cover.length > 0
          ? relation.bangumiItem.coverUrl() : $r('app.media.icon'),
        fit: ImageFit.Cover,
        radius: 8
      })
        .width(60)
        .height(InfoMetrics.relatedImageHeight)
        .backgroundColor(AppColor.surfaceContainerHighest)
        .borderRadius(8)
        .clip(true)
        // Hero 共享元素（§38.7）：**关联列表的封面 → 详情页海报**。
        // 用户 2026-09-17：「关联里也是加上封面到详情页的动画，只要出现封面都加上」。
        // tag 用 `detail-relation-<id>`：本页还有主海报那个 heroTag（来自源页），
        // 两者前缀不同不会撞；关联列表内部 id 唯一，也不会撞。
        .geometryTransition(HeroFlight.tag('detail-relation', relation.bangumiItem.id))
      Column() {
        Text(relation.bangumiItem.nameCn.length > 0
          ? relation.bangumiItem.nameCn : relation.bangumiItem.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.onSurface)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(relation.relation)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.primary)
          .maxLines(1)
      }
      .layoutWeight(1)
      .height(InfoMetrics.relatedImageHeight)
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.SpaceBetween)
      .margin({ left: 10 })
    }
    .width('100%')
    .height(InfoMetrics.relatedCardHeight)
    .padding(8)
    .margin({ bottom: 8 })
    .borderRadius(14)
    .backgroundColor(AppColor.surfaceContainerLow)
    .onClick(() => {
      // 传出去的 heroTag 必须与上面 `sharedTransition` 的完全一致，动画才对得上
      InfoRouteArgs.open(relation.bangumiItem, 'detail-relation',
        HeroFlight.tag('detail-relation', relation.bangumiItem.id));
    })
  }

  @Builder
  staffPage() {
    Column() {
        if (this.staffList.length > 0) {
          ForEach(this.staffList, (staff: StaffItem) => {
            this.staffRow(staff)
          }, (staff: StaffItem) => `staff-${staff.id}`)
        } else if (this.staffFailed) {
          this.failureBlock('制作人员加载失败', () => {
            this.staffFailed = false;
            this.loadStaff();
          })
        } else if (this.staffEmpty) {
          this.emptyBlock('暂无制作人员信息', $r('sys.symbol.person_2'))
        } else {
          ForEach([0, 1, 2, 3, 4], (index: number) => {
            this.skeletonRow()
          }, (index: number) => `staff-skeleton-${index}`)
        }
      }
      .width('100%')
      .padding({ top: 8, bottom: 120 + this.bottomInset })
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  staffRow(staff: StaffItem) {
    Row() {
      // 制作人员头像同上（api.bgm.tv）
      Image(staff.gridImage.length > 0
        ? BangumiImageUrlRewriter.rewriteWithSettings(staff.gridImage)
        : $r('app.media.icon'))
        .width(40)
        .height(40)
        .borderRadius(20)
        .objectFit(ImageFit.Cover)
        .backgroundColor(AppColor.surfaceContainerHighest)
      Column() {
        Text(staff.name)
          .fontSize(15)
          .fontColor(AppColor.onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (staff.nameCn.length > 0) {
          Text(staff.nameCn)
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 14 })
      Text(staff.relations.length > 0 ? staff.relations[0] : '')
        .fontSize(13)
        .fontColor(AppColor.onSurfaceVariant)
    }
    .width('100%')
    .height(64)
    .padding({ left: 16, right: 16 })
  }

  @Builder
  skeletonRow() {
    Row() {
      Column()
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(AppColor.surfaceContainerHighest)
      Column({ space: 6 }) {
        Column().width(100).height(14).borderRadius(7)
          .backgroundColor(AppColor.surfaceContainerHighest)
        Column().width(72).height(12).borderRadius(6)
          .backgroundColor(AppColor.surfaceContainerHighest)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 14 })
    }
    .width('100%')
    .height(64)
    .padding({ left: 16, right: 16 })
  }

  @Builder
  failureBlock(title: string, retry: () => void) {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.arrow_2_circlepath'))
        .fontSize(28)
        .fontColor([AppColor.error])
      Text(title).fontSize(15).fontColor(AppColor.onSurface)
      Text('请检查网络连接后重试。').fontSize(12).fontColor(AppColor.onSurfaceVariant)
      Button('重试')
        .fontSize(13)
        .height(34)
        .onClick(() => {
          retry();
        })
    }
    .width('100%')
    .padding({ top: 80, bottom: 80 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  /**
   * 各标签卡的空态。图标按 §46.4 对齐参照实现：
   *   角色 `people_alt_rounded` → `person_2`、关联 `account_tree_rounded` → `list_bullet`、
   *   制作人员 `groups_rounded` → `person_2`。
   */
  emptyBlock(title: string, icon: Resource) {
    Column({ space: 10 }) {
      SymbolGlyph(icon)
        .fontSize(28)
        .fontColor([AppColor.onSurfaceVariant])
      Text(title).fontSize(14).fontColor(AppColor.onSurfaceVariant)
    }
    .width('100%')
    .padding({ top: 80, bottom: 80 })
    .justifyContent(FlexAlign.Center)
  }

  // ============================================================
  // 播放来源弹层
  // ============================================================

  @Builder
  sourceSheet() {
    SourceSheet({
      item: this.item,
      preferredEpisode: this.resumeEpisode,
      preferredRoad: this.resumeRoad,
      // 大屏弹层放大一档（手机恒为 false，逐字不变）
      wide: this.pageWidthVp() >= 840,
      onPlay: (args: VideoRouteArgs) => {
        const wide: boolean = this.pageWidthVp() >= 840;
        this.sheetVisible = false;
        this.sourceOverlay = false;
        this.sheetKind = 0;
        if (wide) {
          // 大屏是自绘弹层，动画自己管，直接进播放页
          VideoRouteArgs.open(args);
          return;
        }
        // 手机：等系统弹层收完再压栈（原因见 `SHEET_CLOSE_MS` 的注释）
        setTimeout(() => {
          VideoRouteArgs.open(args);
        }, InfoPage.SHEET_CLOSE_MS);
      },
      onClose: () => {
        this.sheetVisible = false;
        this.sourceOverlay = false;
        this.sheetKind = 0;
      }
    })
  }

  /**
   * 大屏「播放来源」自绘弹层：底部居中的面板 + 上方压暗遮罩。
   *
   * 宽度 `min(屏宽 × 0.72, 640)`、最高 75%（同参照实现
   * `adaptive_bottom_sheet.dart` 的 `maxWidth` / `maxHeightFactor`），
   * 底色用 `sys.color.comp_background_primary`——和系统弹层同一套白，
   * 与播放页那几个自绘弹层一致。
   */
  @Builder
  sourceOverlayLayer() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 遮罩：点一下收起（系统弹层的点击外部关闭）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#52000000')
        .onClick(() => {
          this.sourceOverlay = false;
          this.sheetKind = 0;
        })

      Column() {
        this.sourceSheet()
      }
      .width(Math.min(this.pageWidthVp() * 0.72, 640))
      .constraintSize({ maxHeight: '75%' })
      .backgroundColor($r('sys.color.comp_background_primary'))
      .borderRadius({ topLeft: 28, topRight: 28 })
      .clip(true)
      .transition(TransitionEffect.OPACITY.animation({
        duration: 200,
        curve: AppCurves.easeOutCubic()
      }).combine(TransitionEffect.translate({ y: '100%' }).animation({
        duration: 200,
        curve: AppCurves.springSheet()
      })))
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 带动画地切 Tab：**先淡出，再换内容并淡入 + 横向归位**。
   *
   * 用户 2026-09-18：「左右滑动加一下动画吧，现在不好看」。之前是直接改
   * `activeTab`，内容硬切；这里分两拍：先把 `tabFade` 打到 0（正文淡出 +
   * 按 `tabDir` 横移一点），110ms 后换内容再淡入，视觉上就是「旧的被推走、
   * 新的从另一侧跟上」。补间由正文容器上的 `.animation()` 负责。
   *
   * 注：本方法必须留在 struct 内部——上一次改动画时它被插到了最后一个右花括号
   * 之外，直接导致整个文件编译不过（Rollup: Unexpected token）。
   */
  private animateToTab(next: number): void {
    if (next < 0 || next > 3 || next === this.activeTab) {
      return;
    }
    this.tabDir = next > this.activeTab ? 1 : -1;
    this.tabAnimToken += 1;
    const token: number = this.tabAnimToken;
    this.tabFade = 0;
    setTimeout(() => {
      // 快速连滑时旧回调作废，只认最后一次
      if (token !== this.tabAnimToken) {
        return;
      }
      this.onTabChanged(next);
      this.tabFade = 1;
    }, 110);
  }
}
