import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PageTransitionSpec } from '../theme/Tokens';
import { Logger } from '../services/Logger';

/**
 * 路由表。对应规格 §12（根结构 / 四个主 Tab / 设置路由表 / 二级页转场）。
 *
 * 参照实现是 Flutter Modular 的声明式路由；原生版用 ArkUI 的 `router`
 * 页面路由对应——`path` 是 `main_pages.json` 里登记的页面，
 * `route` 保留 Modular 侧的原始路径，方便逐条对表与后续迁移到
 * `Navigation` / `NavPathStack`（平板分栏时要换成后者）。
 */
export class RouteEntry {
  /** ArkUI 页面路径（`main_pages.json` 里登记）。 */
  readonly path: string;
  /** 参照实现的 Modular 路由。 */
  readonly route: string;
  readonly name: string;
  /** ready = 已实现；stage4 / stage5 = 规划中（避免「有路由没页面」的假象）。 */
  readonly status: string;

  constructor(path: string, route: string, name: string, status: string) {
    this.path = path;
    this.route = route;
    this.name = name;
    this.status = status;
  }
}

export class RouteTable {
  // ---- §12.1 根结构 ----
  static readonly index: string = 'pages/Index';
  /** §12.1 `<searchModule>`。 */
  static readonly search: string = 'pages/SearchPage';
  /** §12.3 `/settings/` 的入口页（外观设置，其余设置项随阶段五补齐）。 */
  static readonly settings: string = 'pages/ThemeSettingsPage';
  static readonly playerSettings: string = 'pages/PlayerSettingsPage';
  static readonly danmakuSettings: string = 'pages/DanmakuSettingsPage';
  static readonly danmakuShield: string = 'pages/DanmakuShieldPage';
  static readonly downloadSettings: string = 'pages/DownloadSettingsPage';
  static readonly interfaceSettings: string = 'pages/InterfaceSettingsPage';
  static readonly superResolutionSettings: string = 'pages/SuperResolutionSettingsPage';
  static readonly networkSettings: string = 'pages/NetworkSettingsPage';
  static readonly proxyEditor: string = 'pages/ProxyEditorPage';
  static readonly logs: string = 'pages/LogsPage';
  static readonly plugin: string = 'pages/PluginPage';
  static readonly pluginCatalog: string = 'pages/PluginCatalogPage';
  static readonly pluginEditor: string = 'pages/PluginEditorPage';
  static readonly pluginTest: string = 'pages/PluginTestPage';
  /** 阶段 0 的 ArkWeb 取流原型页（播放链路落地后由播放页取代）。 */
  /** 注意不能叫 `prototype`：那是构造函数的内置属性，ArkTS 会报冲突。 */
  static readonly prototypePage: string = 'pages/ProtoPage';
  /** §12.3 `/settings/history/`。 */
  static readonly history: string = 'pages/HistoryPage';
  /** §12.3 `/settings/download/`。 */
  static readonly download: string = 'pages/DownloadPage';
  /** §12.3 `/settings/storage`。 */
  static readonly storage: string = 'pages/StoragePage';
  /** §9 番剧详情。 */
  static readonly info: string = 'pages/InfoPage';
  /** §10 / §37 播放页。 */
  static readonly video: string = 'pages/VideoPage';

  /**
   * 全量对照表。
   *
   * 未实现的页面按目标阶段标记，这份清单同时是「阶段三之后要补的路由」。
   */
  static readonly all: RouteEntry[] = [
    new RouteEntry('pages/Index', '/tab/', '首页外壳（四个 Tab）', 'ready'),
    new RouteEntry('pages/SearchPage', '/search', '番剧搜索', 'ready'),
    new RouteEntry('pages/ThemeSettingsPage', '/settings/theme', '外观设置', 'ready'),
    new RouteEntry('pages/ProtoPage', '/prototype', '取流原型', 'ready'),
    new RouteEntry('pages/HistoryPage', '/settings/history/', '历史记录', 'ready'),
    new RouteEntry('pages/DownloadPage', '/settings/download/', '离线下载', 'ready'),
    new RouteEntry('pages/StoragePage', '/settings/storage', '存储管理', 'ready'),
    new RouteEntry('pages/InfoPage', '/info', '番剧详情', 'ready'),
    new RouteEntry('pages/VideoPage', '/video', '播放页', 'ready'),
    new RouteEntry('pages/PlayerSettingsPage', '/settings/player', '播放设置', 'ready'),
    new RouteEntry('pages/DanmakuSettingsPage', '/settings/danmaku/', '弹幕设置', 'ready'),
    new RouteEntry('pages/DanmakuShieldPage', '/settings/danmaku/shield', '屏蔽规则', 'ready'),
    new RouteEntry('pages/DownloadSettingsPage', '/settings/download/settings', '下载设置', 'ready'),
    new RouteEntry('pages/InterfaceSettingsPage', '/settings/interface', '界面设置', 'ready'),
    new RouteEntry('pages/SuperResolutionSettingsPage', '/settings/player/super-resolution', '超分辨率', 'ready'),
    new RouteEntry('pages/NetworkSettingsPage', '/settings/proxy', '网络设置', 'ready'),
    new RouteEntry('pages/ProxyEditorPage', '/settings/proxy/editor', '代理配置', 'ready'),
    new RouteEntry('pages/LogsPage', '/settings/storage/logs', '日志', 'ready'),
    new RouteEntry('pages/PluginPage', '/settings/plugin/', '规则管理', 'ready'),
    new RouteEntry('pages/PluginCatalogPage', '/settings/plugin/shop', '规则仓库', 'ready'),
    new RouteEntry('pages/PluginEditorPage', '/settings/plugin/editor', '规则编辑', 'ready'),
    new RouteEntry('pages/PluginTestPage', '/settings/plugin/test', '规则测试', 'ready'),
    new RouteEntry('pages/PlayerSettingsPage', '/settings/player', '播放器设置', 'stage5'),
    new RouteEntry('pages/DanmakuSettingsPage', '/settings/danmaku/', '弹幕设置', 'stage5'),
    new RouteEntry('pages/PluginPage', '/settings/plugin/', '规则设置', 'stage5'),
    new RouteEntry('pages/InterfaceSettingsPage', '/settings/interface', '界面设置', 'stage5'),
    new RouteEntry('pages/LogsPage', '/settings/storage/logs', '日志', 'stage5')
  ];

  /** 二级页转场时长（§12.4）。 */
  static duration(): number {
    return PageTransitionSpec.duration;
  }

  /** 转场起始纵向偏移（vp）：屏高的 2%，对应 `Offset(0, 0.02)`。 */
  static slideOffset(): number {
    try {
      const info = display.getDefaultDisplaySync();
      return (info.height / info.densityPixels) * PageTransitionSpec.slideBeginY;
    } catch (e) {
      return 16;
    }
  }

  static push(path: string): void {
    // 走 Navigation 栈（迁移后所有页面都是 NavDestination，名字就是原来的 page 路径，
    // 因此 RouteTable.xxx 这些常量一个都不用改，调用点也一个都不用动）。
    NavHost.push(path);
  }

  static back(): void {
    NavHost.pop();
  }
}

/**
 * 导航栈的静态持有者。
 *
 * 由 `Index`（Navigation 宿主）在 `aboutToAppear` 里把自己的 `NavPathStack`
 * 存进来，`RouteTable` / `RouteArgs` 这些**非组件**的地方就能直接入栈出栈，
 * 不必给 30 个页面各加一个 `@Consume`。
 *
 * 为什么不让各页面自己 `@Consume('pathStack')`：参考实现（夏绊）是那样做的，
 * 但它的页面少、且都用 `pathStack.pushPathByName` 直连。本工程已经有一层
 * `RouteTable` 抽象，挂在它下面改动面最小（31 个页面里只有 4 处裸 `router.back()`
 * 需要改），风险也最低。
 */
export class NavHost {
  /** 由 Index 注入；未注入时所有导航调用安全空转。 */
  static stack: NavPathStack | null = null;
  /** 由 Index 注入：驱动共享元素转场动画的 UIContext。 */
  static uiContext: UIContext | null = null;
  /** 共享元素返回进行中（预热 → 弹栈两拍之间），期间忽略重复返回。 */
  private static heroPopPending: boolean = false;
  /**
   * 每个详情覆盖层打开时所在的导航栈深。
   *
   * 详情页可以从首页、搜索页或另一层详情打开。不能只记一个全局深度：
   * 「原详情 → 标签搜索 → 新详情」时，原详情属于第 1 层，新详情属于第 2 层；
   * 新详情退出后应该露出第 2 层的搜索页，而不是让第 1 层的原详情重新盖上来。
   */
  private static infoOverlayBases: number[] = [];
  /**
   * 各目的地的**返回拦截器**。
   *
   * 迁移到 NavDestination 之后，页面里的 `onBackPress()`（@Entry 页的回调）
   * 不再被调用——比如播放页的「先退全屏再返回」、详情页的「先关弹层再返回」。
   * 页面在 `aboutToAppear` 里把原来的处理函数注册进来，
   * 宿主 `Dest()` 用 `NavDestination.onBackPressed` 转调，行为与迁移前一致。
   */
  private static backHandlers: Map<string, () => boolean> = new Map<string, () => boolean>();

  /**
   * 每一层压栈是否「带共享元素」（海报飞行）。
   *
   * 带共享元素的跳转**必须**关掉系统转场（否则「整页滑入」会和「封面飞出」
   * 叠成两套动画），普通跳转则相反——**要**交给系统做鸿蒙标准的导航转场。
   * 因此这里与导航栈同步记一叠布尔，返回时按同一层的信息决定用哪种。
   */
  private static heroFrames: boolean[] = [];

  static registerBack(name: string, handler: () => boolean): void {
    NavHost.backHandlers.set(name, handler);
  }

  /** 返回 true = 已消费（不弹栈）。 */
  static handleBack(name: string): boolean {
    /**
     * 播放页压在最上面（它是压在详情覆盖层之上的覆盖层，见 `pushInternal`），
     * 所以返回/右滑先归它——它自己会先退全屏、再滑出，露出下面的详情页。
     */
    if (NavHost.requestVideoExit()) {
      return true;
    }
    /**
     * 详情页覆盖层压在**所有页面之上**（它在 `Index` 最外层，见那里的注释），
     * 所以不管当前栈顶是首页、搜索页还是历史页，返回都该先关它——
     * 与参照实现里「详情路由在栈顶、先被返回消费」一致。
     */
    if (NavHost.requestInfoExit()) {
      return true;
    }
    const handler: (() => boolean) | undefined = NavHost.backHandlers.get(name);
    return handler === undefined ? false : handler();
  }

  /**
   * 把帧栈对齐到真实栈深（只裁多余的）。
   *
   * 系统返回（边缘手势）直接弹栈，不经过 `NavHost.pop`，帧栈会多出一层；
   * 每次进栈 / 出栈前先对齐，就不会越积越偏。裁的位置正好是栈顶，
   * 与「被系统弹掉的是最上面那页」一致。
   */
  private static syncFrames(expected: number): void {
    while (NavHost.heroFrames.length > expected) {
      NavHost.heroFrames.pop();
    }
  }

  /** 普通跳转：用系统默认转场（鸿蒙的压栈动效 + 跟手返回）。 */
  static push(name: string): void {
    NavHost.pushInternal(name, false);
  }

  /** 带共享元素（海报飞行）的跳转：详情页专用，关掉系统转场。 */
  static pushWithHero(name: string): void {
    NavHost.pushInternal(name, true);
  }

  private static pushInternal(name: string, hero: boolean): void {
    const s: NavPathStack | null = NavHost.stack;
    if (s === null) {
      hilog.error(0x0000, 'AutumnRoute', '导航栈未就绪，忽略跳转: %{public}s', name);
      return;
    }
    NavHost.syncFrames(s.size() - 1);
    /**
     * 详情页**不是目的地**，是首页里的一层覆盖（方案 C，2026-10-08）。
     *
     * 为什么非要这样：ArkUI 的 `Navigation` 只绘制栈顶目的地，被盖住的那一页在
     * 转场期间根本不画（真机抓帧复核过）。于是整页 `opacity` 动画实际是在
     * 「页面 ↔ 窗口底色」之间淡——浅色主题下就是白闪 / 白屏。参照实现（Flutter）
     * 的 `Navigator` 把每条路由都留在 overlay 里，下面那页一直在，淡入淡出永远是
     * 两页之间的交叉淡化。改成覆盖层之后，首页和详情页在**同一棵树**里，
     * 两个方向的白屏就都没了，300ms/easeOutCubic/下移 2% 也还归我们控制。
     */
    if (name === RouteTable.info) {
      NavHost.openInfoOverlay(hero);
      return;
    }
    /**
     * 播放页同理，也走**覆盖层**（方案 C 的第二步，2026-10-09）。
     *
     * 详情页是压在 `Navigation` 之上的覆盖层，如果播放页还是「详情页下面的
     * 目的地」，它滑入时会被详情页挡住——之前只能靠让详情页淡出来让它可见，
     * 观感就变成了"交叉淡化"而不是普通压栈（用户：「为什么详情页到播放页也有
     * 模糊转场，做成主页到搜索页的普通转场就可以了」）。
     * 把播放页提到详情覆盖层**之上**，压栈就回到它该有的样子：
     * 新页面从右滑入、详情页原地不动被盖住、返回时原样露出来
     * ——与 2.0.1 里「详情页和播放页都是页面」的关系一致。
     */
    if (name === RouteTable.video) {
      NavHost.openVideoOverlay();
      return;
    }
    NavHost.heroFrames.push(hero);
    // 压栈/弹栈各留一条日志：真机上出现过「两个页面来回切」类的导航异常，
    // 有这条就能一眼看出是谁在反复压栈（用户导出日志即可）。
    Logger.info('AutumnRoute',
      `压栈 ${name}（hero=${hero}，栈深 ${s.size()}→${s.size() + 1}）`);
    if (!hero) {
      // 普通跳转：`animated = true`，交给系统
      s.pushPathByName(name, null, () => {
      }, true);
      return;
    }
    // 共享元素转场的关键（对照参考实现 `F:\app` 夏绊的 openBook）：
    //   1. 路由动作放进 `animateTo` 闭包 —— 几何转场的时长与曲线由它驱动；
    //   2. push 的 `animated` 传 false —— 关掉系统自带的页面滑入，
    //      否则「整页滑入」会和「封面飞出」叠成两套动画。
    const go: () => void = () => {
      s.pushPathByName(name, null, () => {
      }, false);
    };
    const ctx: UIContext | null = NavHost.uiContext;
    if (ctx === null) {
      go();
      return;
    }
    /**
     * 飞行用**300ms + `flightCurve()`**（与页面转场同长、同一条曲线），
     * 不是自己一套参数——海报和页面**同步起停**。原来给飞行单独配了
     * 240ms 线性，海报总比页面先落地，观感就和 Flutter 不一样。
     * 退场那条飞行在 `InfoPage.backOut()` 里，用的是同一个 token。
     */
    ctx.animateTo({ duration: PageTransitionSpec.duration,
      curve: PageTransitionSpec.flightCurve() }, go);
  }

  static pop(): void {
    const s: NavPathStack | null = NavHost.stack;
    // **不要弹掉最后一个**：栈空掉就是白屏。
    // 首页（Home）由 `Index.onBackPress` 负责退出应用，不靠弹栈。
    if (s === null || s.size() <= 1) {
      return;
    }
    // 先对齐帧栈，再取「即将被弹掉的那一层」是不是共享元素
    NavHost.syncFrames(s.size() - 1);
    const hero: boolean = NavHost.heroFrames.length > 0
      ? NavHost.heroFrames.pop() === true : false;
    Logger.info('AutumnRoute',
      `弹栈 ${s.getAllPathName().length > 0 ? s.getAllPathName()[s.size() - 1] : '?'}` +
        `（hero=${hero}，栈深 ${s.size()}→${s.size() - 1}）`);
    if (!hero) {
      // 普通返回：系统默认返回转场（含跟手）
      s.pop(true);
      return;
    }
    /**
     * 带共享元素的返回。
     *
     * ⚠️ **正常路径不在这里**：详情页自己的返回（返回键 / 系统返回手势）在
     * `InfoPage.backOut()` 里接手——它置位 `heroExitRequested` 之后调
     * `popWithHeroExit()`，由 `Index.customNavContentTransition` 返回一条
     * 不做属性动画的自定义转场：**只为了把 from/to 两页同时留在渲染里**
     * （ArkUI 默认不绘制被盖住的目的地，那会让淡出露出白底）。
     *
     * 为什么不让这里统一驱动：栈里可能叠着两层详情页（相关推荐 → 详情页），
     * 广播式的「谁该退场」只能靠栈深猜，两个实例都可能以为自己该动。
     * 由页面自己发起就没有歧义——能按到那颗返回键、能被系统返回手势命中的，
     * 本来就只有栈顶那一层。
     *
     * 走到这里说明是一次**没有页面接手的共享元素返回**（例如外部代码直接调
     * `RouteTable.back()`）。退而求其次：不演动画，直接弹栈，至少不会卡住。
     */
    if (NavHost.heroPopPending) {
      // 连点返回：这一次还没演完，忽略后来的（否则动画叠着弹两层）
      return;
    }
    s.pop(false);
  }

  // ---- 详情页覆盖层（方案 C：详情页不再是目的地，而是首页里的一层） ----

  /** 详情页覆盖层是否打开（首页读它决定挂不挂 `InfoPage`）。 */
  static isInfoOpen(): boolean {
    const open: number = AppStorage.get<number>('infoOverlayOpen') ?? 0;
    return open > 0;
  }

  /** 当前每个详情覆盖层的来源栈深，供 `Index` 分别控制显隐。 */
  static getInfoOverlayBases(): number[] {
    return NavHost.infoOverlayBases.slice();
  }

  private static currentStackDepth(): number {
    return NavHost.stack === null ? 1 : NavHost.stack.size();
  }

  private static maxInfoOverlayBase(): number {
    let max: number = 1;
    for (let i = 0; i < NavHost.infoOverlayBases.length; i++) {
      max = Math.max(max, NavHost.infoOverlayBases[i]);
    }
    return max;
  }

  /**
   * 打开详情页覆盖层。
   *
   * 对照原来的 `pushPathByName`：这里只是把 `infoOverlayOpen` 置 1，但**必须走
   * `animateTo`**——共享元素（封面从卡片飞到详情页）是由「节点出现在同一帧的
   * 动画闭包里」触发的，跟原来 push 那条路径同一个道理。时长/曲线与页面转场
   * 共用 `flightCurve()`（300ms）。
   */
  private static openInfoOverlay(hero: boolean): void {
    const depth: number = (AppStorage.get<number>('infoOverlayOpen') ?? 0) + 1;
    /**
     * 记下「详情页是在第几层目的地上打开的」。
     *
     * 覆盖层压在**整个 Navigation 之上**（见 `Index` 的注释），所以从详情页
     * 再压别的目的地（播放页）时，那个页面会落在覆盖层**下面**、被挡住——
     * 表现就是用户 2026-10-09 报的「从播放来源进播放页跳转失败」。
     * 规则：**只有当前栈深回到打开详情时的那一层，才画覆盖层**；
     * 上面压了别的页面就先让开，等它退回来再露出来（这时详情页与它的
     * 「播放来源」弹层都还在，正好接上原来的流程）。
     */
    const currentDepth: number = NavHost.currentStackDepth();
    const previousBase: number =
      AppStorage.get<number>('infoOverlayBase') ?? 1;
    /**
     * `infoOverlayBases` 与详情层一一对应。正常运行时长度正好是 `depth - 1`；
     * 补齐只用于页面热重载等极端情况，保证旧层仍按原来的基准显示。
     */
    while (NavHost.infoOverlayBases.length < depth - 1) {
      NavHost.infoOverlayBases.push(previousBase);
    }
    NavHost.infoOverlayBases.push(currentDepth);
    AppStorage.setOrCreate('infoOverlayBase', NavHost.maxInfoOverlayBase());
    Logger.info('AutumnRoute', `打开详情页覆盖层（hero=${hero}，层数 ${depth}）`);
    const ctx: UIContext | null = NavHost.uiContext;
    if (!hero || ctx === null) {
      AppStorage.setOrCreate('infoOverlayOpen', depth);
      return;
    }
    ctx.animateTo({ duration: PageTransitionSpec.duration,
      curve: PageTransitionSpec.flightCurve() }, () => {
      AppStorage.setOrCreate('infoOverlayOpen', depth);
    });
  }

  /**
   * 关闭详情页覆盖层（由 `InfoPage.backOut()` 在退场动画播完后调用）。
   *
   * ⚠️ **不要包在 `animateTo` 里**：这一步只是把已经全透明的那一层摘掉；
   * 一旦包进动画闭包，框架会再安排一次共享元素转场，卡片端那张封面会从详情页
   * 的位置又飞一次。
   */
  static closeInfoOverlay(): void {
    const depth: number = Math.max(0, (AppStorage.get<number>('infoOverlayOpen') ?? 1) - 1);
    if (NavHost.infoOverlayBases.length > 0) {
      NavHost.infoOverlayBases.pop();
    }
    /**
     * 关掉搜索页上打开的那层详情后，剩余最上层详情可能仍属于较浅的导航层。
     * 同步收低基准：搜索页还在时所有剩余详情保持隐藏；搜索页退掉后才重新出现。
     */
    AppStorage.setOrCreate('infoOverlayBase', NavHost.maxInfoOverlayBase());
    Logger.info('AutumnRoute', `关闭详情页覆盖层（剩余层数 ${depth}）`);
    AppStorage.setOrCreate('infoOverlayOpen', depth);
  }

  /**
   * 详情页登记的「请开始退场」回调。
   *
   * 覆盖层不是目的地，系统返回不再经过它的 `onBackPress`：首页那一层的
   * `onBackPress` 会先问这里（`requestInfoExit`），有人应答就先播退场动画，
   * 没人应答才走「再按一次退出应用」。
   */
  /**
   * 「请开始退场」回调**按栈存**。
   *
   * 详情页可以叠层（详情页里的「相关推荐」再点进一部番，参照实现就是压第二条
   * 详情路由）。每层在 `aboutToAppear` 里压入、`aboutToDisappear` 里按引用移除，
   * 取栈顶那个——否则上层退掉之后下层的回调就丢了，返回会没反应。
   */
  private static infoExitHooks: (() => void)[] = [];

  static registerInfoExit(hook: () => void): void {
    NavHost.infoExitHooks.push(hook);
  }

  static unregisterInfoExit(hook: () => void): void {
    NavHost.infoExitHooks = NavHost.infoExitHooks.filter((item: () => void) => item !== hook);
  }

  /** 返回 true = 详情页接下了这次返回（正在播退场动画）。 */
  static requestInfoExit(): boolean {
    if (!NavHost.isInfoOpen() || NavHost.infoExitHooks.length === 0) {
      return false;
    }
    /**
     * ⚠️ **只有覆盖层真的在最上面时，返回才归它**。
     *
     * 覆盖层是压在整个 `Navigation` 之上的（见 `Index`），上面还能再压目的地
     * （播放页就是）。播放页在最上面时，返回/右滑是给播放页的——不判这一条的话，
     * 那次返回会被这里吃掉、把看不见的详情页退掉，然后播放页弹回首页，
     * 用户看到的就是「从播放页右滑回到的是首页而不是详情页」
     * （用户 2026-10-09 的反馈）。
     */
    const base: number = AppStorage.get<number>('infoOverlayBase') ?? 1;
    const size: number = NavHost.stack === null ? 1 : NavHost.stack.size();
    if (size > base) {
      return false;
    }
    const hook: () => void = NavHost.infoExitHooks[NavHost.infoExitHooks.length - 1];
    /**
     * ⚠️ **刚回到首页的那一下不要动详情页**。
     *
     * 从播放页弹栈回来时，那一次「返回」会**再落到刚露出来的首页**上
     * （真机复现：播放页返回后详情页跟着一起退掉，用户看到的是首页——
     * 用户 2026-10-08 报的「播放一段时间后返回不能回到详情页」）。
     * 这里用一个很短的时间窗挡掉它：弹栈发生在几十毫秒内，用户真要
     * 自己按返回至少要隔半秒。
     * 注意返回的是 `true`（这次返回被吃掉）——返回 false 会让首页的
     * 「再按一次退出应用」接上去，那是另一个更糟的结果。
     */
    if (Date.now() - NavHost.homeShownAtMs < 500) {
      return true;
    }
    hook();
    return true;
  }

  /** 首页最近一次被显示的时刻（ms），供 `requestInfoExit` 挡「漏过来的返回」。 */
  private static homeShownAtMs: number = 0;

  static noteHomeShown(): void {
    NavHost.homeShownAtMs = Date.now();
  }

  // ---- 播放页覆盖层（压在详情覆盖层之上，见 `pushInternal` 的注释） ----

  /** 播放页覆盖层是否打开（`Index` 读它决定挂不挂 `VideoPage`）。 */
  static isVideoOpen(): boolean {
    return (AppStorage.get<number>('videoOverlayOpen') ?? 0) > 0;
  }

  /** 打开播放页覆盖层（由 `pushInternal` 拦截 `pages/VideoPage` 时调用）。 */
  private static openVideoOverlay(): void {
    Logger.info('AutumnRoute', '打开播放页覆盖层');
    AppStorage.setOrCreate('videoOverlayOpen', 1);
  }

  /**
   * 关闭播放页覆盖层（由播放页在滑出动画播完后调用）。
   *
   * 同时发一次 `infoReshownTick`：详情页在下面原地没动，但它的系统栏/来源弹层
   * 需要重新确认一次（播放页改过状态栏，见 `InfoPage.onInfoReshown`）。
   */
  static closeVideoOverlay(): void {
    Logger.info('AutumnRoute', '关闭播放页覆盖层');
    AppStorage.setOrCreate('videoOverlayOpen', 0);
    const tick: number = AppStorage.get<number>('infoReshownTick') ?? 0;
    AppStorage.setOrCreate('infoReshownTick', tick + 1);
  }

  /** 播放页登记的「请开始退场」回调（返回键 / 右滑都走它）。 */
  private static videoExitHook: (() => void) | null = null;

  static registerVideoExit(hook: () => void): void {
    NavHost.videoExitHook = hook;
  }

  static unregisterVideoExit(hook: () => void): void {
    if (NavHost.videoExitHook === hook) {
      NavHost.videoExitHook = null;
    }
  }

  /** 返回 true = 播放页接下了这次返回（正在播滑出动画）。 */
  static requestVideoExit(): boolean {
    if (!NavHost.isVideoOpen() || NavHost.videoExitHook === null) {
      return false;
    }
    NavHost.videoExitHook();
    return true;
  }
}
