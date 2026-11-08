import { ImmersiveBottomBar, NavItemModel } from '../components/ImmersiveBottomBar';
import { RecommendPage } from '../views/RecommendPage';
import { TimetablePage } from '../views/TimetablePage';
import { CollectPage } from '../views/CollectPage';
import { MinePage } from '../views/MinePage';
import { Dimens, Motion, AppCurves, TabTransition, PageTransitionSpec } from '../theme/Tokens';
import { AppColor } from '../theme/AppColors';
import { NavScrollController } from '../components/NavScrollController';
import { NavScrollSpec } from '../theme/Tokens';
import { AppMaterial } from '../theme/Material';
import { ArkUITheme } from '../theme/ArkUITheme';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { NavHost } from '../router/RouteTable';
import { DanmakuSettingsPage } from './DanmakuSettingsPage';
import { DanmakuShieldPage } from './DanmakuShieldPage';
import { DownloadPage } from './DownloadPage';
import { DownloadSettingsPage } from './DownloadSettingsPage';
import { HistoryPage } from './HistoryPage';
import { InfoPage } from './InfoPage';
import { InterfaceSettingsPage } from './InterfaceSettingsPage';
import { LogsPage } from './LogsPage';
import { NetworkSettingsPage } from './NetworkSettingsPage';
import { PlayerSettingsPage } from './PlayerSettingsPage';
import { PluginCatalogPage } from './PluginCatalogPage';
import { PluginEditorPage } from './PluginEditorPage';
import { PluginPage } from './PluginPage';
import { PluginTestPage } from './PluginTestPage';
import { ProtoPage } from './ProtoPage';
import { ProxyEditorPage } from './ProxyEditorPage';
import { SearchPage } from './SearchPage';
import { StoragePage } from './StoragePage';
import { SuperResolutionSettingsPage } from './SuperResolutionSettingsPage';
import { ThemeSettingsPage } from './ThemeSettingsPage';
import { VideoPage } from './VideoPage';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppBackground } from '../components/AppBackground';

/**
 * 「再滑一次退出应用」的门闩。
 *
 * 为什么要单独放一处：首页这次返回**有两个回调可能被调到**——
 *   1. `NavDestination.onBackPressed`（`Dest()` 里转调 `HomeShell.onBackPress`）；
 *   2. `@Entry` 页自己的 `Index.onBackPress`。
 *
 * 「返回 true 是不是就能拦住系统级回调」在不同 API 版本上表现并不一致，
 * 与其赌，不如把判定收在一处：两处回调都问这个门闩，门闩自己保证
 * **一次手势只算一次**（50ms 内的第二次询问直接复用上次结论）。
 */
class ExitGate {
  /** 提示文案。手机上是手势返回，没有返回键，所以叫「再滑一次」。 */
  static readonly promptText: string = '再滑一次退出应用';

  /** 上次「只提示、不退出」的时间戳；0 表示还没提示过。 */
  private static promptedAt: number = 0;
  /** 上次被询问的时间戳：用来把同一次手势的两次回调并成一次判定。 */
  private static askedAt: number = 0;
  /** 上一次的判定结果（true = 该退出）。 */
  private static lastVerdict: boolean = false;

  /**
   * 返回 true = 这一次真的退出；false = **只是提示**，调用方必须把这次返回消费掉
   * （返回 true），否则 Navigation 会弹掉首页、栈一空就是白屏。
   */
  static ask(): boolean {
    const now: number = Date.now();
    // 同一次手势里的第二次询问（两处回调都触发时）：复用上次结论
    if (now - ExitGate.askedAt <= 50) {
      return ExitGate.lastVerdict;
    }
    ExitGate.askedAt = now;
    if (ExitGate.promptedAt !== 0 &&
      now - ExitGate.promptedAt <= NavScrollSpec.exitPromptWindowMs) {
      ExitGate.promptedAt = 0;
      ExitGate.lastVerdict = true;
      return true;
    }
    ExitGate.promptedAt = now;
    ExitGate.lastVerdict = false;
    return false;
  }

  /**
   * 弹提示。
   *
   * 必须走 `UIContext` 版接口：全局 `promptAction.showToast` 在当前 API 上已废弃，
   * 实测直接调用不会弹出提示（静默失败）。
   */
  static prompt(ui: UIContext): void {
    try {
      ui.getPromptAction().showToast({ message: ExitGate.promptText });
    } catch (error) {
      const err = error as Error;
      hilog.error(0x0000, 'AutumnArkUI', 'showToast 失败: %{public}s', err.message);
    }
  }

  /** 真的退出应用。 */
  static exit(ui: UIContext): void {
    try {
      const context = ui.getHostContext() as common.UIAbilityContext;
      context.terminateSelf();
    } catch (error) {
      const err = error as Error;
      hilog.warn(0x0000, 'AutumnArkUI', '退出应用失败: %{public}s', err.message);
    }
  }
}

/**
 * 主框架。对应参照实现 lib/pages/menu/menu.dart。
 *
 * 四个主 Tab 常驻挂载、切换不重新加载；底部导航是全局悬浮胶囊，
 * 不属于任何页面。导航内缩 18、距系统底 8。
 */
/**
 * 主界面外壳（四个 Tab + 底部悬浮导航）。
 *
 * 2026-09-17 起它是**导航栈里的第一个 NavDestination**（原来是 @Entry 页）。
 * 为什么首页也要入栈：`geometryTransition` 要求做共享元素转场的两个组件
 * 在**同一棵 Navigation 树**里，且都挂在 NavDestination 上——
 * 参考实现（`F:\app` 夏绊）的注释写得很直接：「首页本身也是一个 NavDestination，
 * 入栈后才能让书架 → 详情的共享元素转场生效」。四个 Tab 里的封面正是转场的起点。
 *
 * 沉浸式结构原样保留：`hideTitleBar(true)` + 根容器 `expandSafeArea` +
 * `systemTransition(NONE)`（关掉系统滑动转场，免得和共享元素叠在一起）。
 */
@Component
export struct HomeShell {
  @State currentIndex: number = 0;
  /**
   * 导航隐藏状态。由 `NavScrollController` 写入 AppStorage，
   * 这里只负责表现（下沉 / 缩放 / 淡出 + 停止响应点击）。
   */
  @StorageProp('navHidden')
  @Watch('onNavHiddenChanged')
  navHidden: boolean = false;
  /** 隐藏时下沉比例（AnimatedSlide offset y = 0.9）。 */
  @State private navSlideY: number = 0;
  /** 隐藏时缩放（AnimatedScale scale = 0.35）。 */
  @State private navScale: number = 1;
  /** 隐藏时透明度（AnimatedOpacity，独立 200ms）。 */
  @State private navOpacity: number = 1;
  /** 标签页切换的 70ms 淡入（规格 §12.2 `_tabTransition`）。 */
  @State private pageOpacity: number = 1;
  /**
   * 是否用**侧边导航栏**（规格 §1.5）。
   *
   * 2026-10-07 用户要求：平板上也要跟手机一样用**底部 HDS 胶囊**
   * （原来横屏/宽屏一律换成左侧 NavigationRail，用户觉得平板上不好看）。
   * 所以这条只在 **2in1 / PC** 上还成立——那种设备侧边竖栏才是平台惯例；
   * 手机、平板一律走底部胶囊（见 `onAreaChange` 里的判据）。
   */
  @State private wideLayout: boolean = false;
  /** 本机是不是 2in1/PC（只有它横屏时保留侧边竖栏）。 */
  private isDesktopDevice: boolean = false;
  /** 根容器实测宽度（vp）：底部胶囊在平板上要限宽居中，需要它。 */
  @State private shellWidth: number = 0;
  /**
   * 底部胶囊最大宽度（vp）。
   *
   * 手机上整条就是屏宽（324 左右），照搬即可；平板上屏宽 1400+，胶囊拉满
   * 会变成一条巨大的横杠。这里给外壳一个上限，让它像手机那样居中成一颗
   * 正常的胶囊（4 项 × ~150vp）。
   */
  private static readonly BAR_MAX_WIDTH: number = 640;

  // ---- 底部导航：HarmonyOS 官方「沉浸光感」材质（HDS HdsTabs） ----
  private tabsController: HdsTabsController = new HdsTabsController();
  /**
   * 材质类型：能上 IMMERSIVE 就上，否则退到 ADAPTIVE（与夏绊工程同一判据）。
   * 设备不支持 HDS 时整条导航回退到自绘玻璃胶囊，见 `bottomBar()`。
   */
  @State private barMaterialType: hdsMaterial.MaterialType =
    hdsMaterial.MaterialType.ADAPTIVE;
  private barMaterialLevel: hdsMaterial.MaterialLevel =
    hdsMaterial.MaterialLevel.EXQUISITE;
  /** 胶囊实测宽度（vp）：HdsTabs 的浮动栏要显式给宽度。 */
  @State private barWidth: number = 0;
  /**
   * 首页是否是导航栈的栈顶（栈里只有自己）。
   *
   * 底部悬浮胶囊**只在栈顶时显示**：栈里压着别的页面时如果它还画着，
   * 上层页面的内容盒一旦在底部短一截（实测短约 94vp），
   * 从下面透出来的就是这颗白玻璃胶囊——用户看到的那块「白块」。
   *
   * ⚠️ 2026-09-18 更正：「透出白块」这个推断已被推翻（真凶是 `InfoPage`
   * 里被摆到底部的那层顶部遮罩，见 `Dest()` 上方 `hideToolBar` 的注释）。
   * 这条规则本身仍然成立——被路由覆盖时不该画底部胶囊，保留。
  *
   * 由 `Dest()` 的 `onShown`/`onHidden` 改 `NavHost` 的栈深度触发。
   */
  @StorageProp('navStackDepth') @Watch('onStackDepthChanged') navStackDepth: number = 1;
  @State private isStackTop: boolean = true;

  onStackDepthChanged(): void {
    const top: boolean = this.navStackDepth <= 1;
    if (top !== this.isStackTop) {
      this.isStackTop = top;
    }
  }
  /** 底部系统手势区高度（vp），由 EntryAbility 写入 */
  @StorageProp('bottomInset') bottomInset: number = 28;
  /** 主题版本号；变化即触发整棵树重绘，取到新算出的配色。 */
  @StorageProp('themeRevision') themeRevision: number = 0;
  private navItems: NavItemModel[] = [
    new NavItemModel($r('sys.symbol.house'), $r('sys.symbol.house_fill'), '推荐'),
    /**
     * 2026-09-19 用户：「导航栏上时间表的图案换成时钟图案」。
     *
     * 原来是 `clock_arrow_2_circlepath`（规格 §46.5 按参照实现的映射取的）。
     * 换成 `clock` 之后**选中态仍是同一个符号**：参照实现里 `timeline` 与
     * `timeline_outlined` 本来就映射到同一个符号，两态同名是它的原样行为
     * （其余三个 Tab 才是线框 / 实心两套）。若哪天想让这一档也「选中变实心」，
     * 把第二个参数换成 `sys.symbol.clock_fill` 即可（符号名已核对存在）。
     */
    new NavItemModel($r('sys.symbol.clock'), $r('sys.symbol.clock'), '时间表'),
    new NavItemModel($r('sys.symbol.heart'), $r('sys.symbol.heart_fill'), '追番'),
    new NavItemModel($r('sys.symbol.gearshape'), $r('sys.symbol.gearshape_fill'), '我的')
  ];

  /**
   * 初始化官方材质档位。
   *
   * `getSystemMaterialTypes()` 返回本机支持的材质类型：支持 IMMERSIVE 就用
   * IMMERSIVE（完整点光源光效），否则退到 ADAPTIVE。取不到就按 ADAPTIVE 处理
   * ——宁可少一点光效，也不能因为一个查询失败整条导航不显示。
   */
  aboutToAppear(): void {
    /**
     * 首页登记自己的返回拦截器——**不登记的话，右滑手势会把首页也弹掉**。
     *
     * `Dest()` 里的 `NavDestination.onBackPressed` 转调 `NavHost.handleBack(name)`，
     * 找不到 'Home' 的处理器就返回 false＝「没消费」，Navigation 于是弹掉首页；
     * 栈一空，Navigation 只剩一块白底（2026-09-19 用户「右滑退出白屏」）。
     * 登记之后 `HomeShell.onBackPress` 永远返回 true，首页不会被弹掉。
     */
    NavHost.registerBack('Home', () => this.onBackPress());
    /**
     * 设备形态：只有 2in1/PC 在横屏时保留左侧竖栏，手机/平板一律底部胶囊
     * （用户 2026-10-07 的要求）。取不到设备类型时按「非桌面」处理——
     * 宁可给底部胶囊，也不要在大屏上突然冒出一条竖栏。
     */
    try {
      this.isDesktopDevice = deviceInfo.deviceType === '2in1';
    } catch (error) {
      this.isDesktopDevice = false;
    }
    try {
      const types: hdsMaterial.MaterialType[] = hdsMaterial.getSystemMaterialTypes();
      this.barMaterialType = types.includes(hdsMaterial.MaterialType.IMMERSIVE)
        ? hdsMaterial.MaterialType.IMMERSIVE
        : hdsMaterial.MaterialType.ADAPTIVE;
    } catch (error) {
      this.barMaterialType = hdsMaterial.MaterialType.ADAPTIVE;
    }
    this.barMaterialLevel = hdsMaterial.MaterialLevel.EXQUISITE;
  }

  /**
   * 读一次主题版本号，让本页与主题状态建立依赖。
   *
   * 为什么必须读：ArkUI 只重绘「build 里读到过」的状态。
   * 本页不读的话，主题变化时 Index 不会重跑 build，
   * 也就不会把新的 `themeRev` 传给四个 Tab 页与导航栏 —— 它们会停在旧配色。
   */
  private navBottomPadding(): number {
    return this.themeRevision < 0 ? 0 : this.bottomInset;
  }

  /**
   * 底部胶囊外壳宽度。
   *
   * 手机上就是整屏宽（保持不变）；平板上限到 `BAR_MAX_WIDTH` 再居中——
   * 外层 Stack 是 `Alignment.Bottom`（水平居中），所以直接收窄宽度即可。
   * 首帧还没量到宽度时按上限返回，避免先画一条超长横杠再抖一下。
   */
  private barShellWidth(): number {
    const maxShell: number = HomeShell.BAR_MAX_WIDTH + Dimens.navSideInset * 2;
    const avail: number = this.shellWidth > 0 ? this.shellWidth : maxShell;
    return avail < maxShell ? avail : maxShell;
  }

  /**
   * 导航显隐。
   * 对应源码 `menu.dart:179-199`：位移与缩放 260ms，隐藏用 `easeInCubic`；
   * 透明度单独 200ms。
   *
   * ⚠️ **恢复**那一档原样照搬了源码的 `Curves.easeOutBack`，但它在 ArkUI 里
   * 会把两个属性一起甩过头：`scale` 越过 1（>1 = 放大）、`translateY` 越过 0
   * （负值 = 往上跑）。源码那边是 Flutter 的 `AnimatedScale/AnimatedSlide`，
   * 过冲量小且被自身裁剪吃掉，看不出问题；这边用户直接看到「用力滑一下，
   * 底部导航会向上放大一下」（2026-09-19 反馈），所以恢复改用**不过冲**的
   * `easeOutCubic`（隐藏方向仍是 `easeInCubic`，与源码一致）。
   */
  onNavHiddenChanged(): void {
    const hidden: boolean = this.navHidden;
    animateTo({
      duration: NavScrollSpec.transformDuration,
      curve: hidden ? AppCurves.easeInCubic() : AppCurves.easeOutCubic()
    }, () => {
      this.navSlideY = hidden ? NavScrollSpec.hiddenSlideY : 0;
      this.navScale = hidden ? NavScrollSpec.hiddenScale : 1;
    });
    animateTo({ duration: NavScrollSpec.opacityDuration }, () => {
      this.navOpacity = hidden ? 0 : 1;
    });
  }

  /**
   * 最外层页面的返回（系统返回键 / **右滑手势**）。
   *
   * 2026-09-19（用户）：「在最表面的页（推荐、时间表这些）右滑退出不要白屏
   * （保持当前画面），显示再滑一次退出，然后两次就退出」。
   *
   * 于是这里只做两件事，**两次滑动手势就退出**：
   *   1. 首次：只弹提示「再滑一次退出应用」，返回 true；
   *   2. `exitPromptWindowMs`（2s）内再滑一次：`terminateSelf()` 退出应用。
   *
   * 返回 true 是**关键**：它是「已消费」的意思，Navigation 因此不会把首页
   * 弹掉，画面原地不动——不会出现「栈一空就是白屏」。
   *
   * 与参照实现 `menu.dart:101-125` 的差别：那边第 2 条是「非 Tab 0 → 先切回
   * Tab 0」，本工程从来没接上（首页当时**没有登记**返回拦截器，那段是死代码，
   * 真机只会白屏）。用户这次要的是「两次就退出」，所以这里不再夹一层切回首个
   * Tab；要恢复那条，就在下面的首次分支里加 `this.currentIndex = 0`。
   */
  onBackPress(): boolean {
    /**
     * 详情页覆盖层打开时，系统返回先交给它播退场动画（见 `InfoPage.backOut`）。
     * 覆盖层不是目的地，框架不会替我们转达，所以在这里拦一道。
     */
    if (NavHost.requestInfoExit()) {
      return true;
    }
    if (!ExitGate.ask()) {
      ExitGate.prompt(this.getUIContext());
      return true;
    }
    ExitGate.exit(this.getUIContext());
    return true;
  }

  build() {
    // 首页自己也是一个 NavDestination：四个 Tab 里的封面要参与共享元素转场，
    // 起点必须与详情页在同一个 Navigation 树里。
    NavDestination() {
     /**
      * 这一层只为一件事：把**详情页覆盖层**放在主题重建子树之外。
      *
      * 下面 `ForEach([themeRevision])` 的 key 一变就把整棵子树重建（这是让
      * `AppColor.*` 生效的手段，见注释）。实测：从播放页返回时刚好赶上一次
      * 重建，覆盖层跟着被销毁又重建，中间那一拍露出的就是首页——
      * 用户 2026-10-08 报的「从播放页返回会先回首页、再回到详情页」就是它。
      * 放到 `ForEach` 外面之后，主题变化不再影响已经打开的详情页
      * （详情页每次打开都会新建，配色本来就是当前的）。
      */
     Stack() {
     Column() {
      // 主题切换时靠 ForEach 的 key 变化**整体重建**这棵子树。
      //
      // 为什么必须这么做：ArkUI V1 是按属性更新的——状态变化只会重跑
      // 「读取过该状态」的属性表达式，而 `AppColor.*` 是普通取值、不会被追踪。
      // 因此只改颜色来源无法让已存在的组件换色，重建是最可靠的做法
      //（Flutter 侧是 ChangeNotifier → MaterialApp 全树 rebuild，语义一致）。
      ForEach([this.themeRevision], (revision: number) => {
        /**
         * 首页 + **详情页覆盖层**（方案 C）。
         *
         * 详情页不再是 `NavDestination`，而是**同一棵树里的第二层**：
         * 参照实现（Flutter）的 `Navigator` 把每条路由都留在 overlay 里，
         * 进场/退场永远是「上面那页 ↔ 下面那页」的交叉淡化；ArkUI 的
         * `Navigation` 只画栈顶目的地，被盖住的那页在转场期间不画，整页
         * `opacity` 动画实际是在和窗口底色（浅色主题下就是近白）之间淡——
         * 用户 2026-10-08 反馈的进场白闪与退场白屏都是它。
         *
         * 放到这里（`AppBackground` 之外、底部胶囊之上）之后：
         *   - 首页永远在画，两个方向的交叉淡化都成立；
         *   - 底部胶囊在详情页打开期间**照旧渲染**、被详情页盖住——与参照实现
         *     「导航栏属于首页、只是被盖住」一致，不用再靠栈深去摘它；
         *   - 封面飞行、300ms/easeOutCubic/下移 2% 全在我们手里，不受框架限制。
         */
        Stack() {
          AppBackground() {
            if (this.wideLayout) {
              // 横屏 / 平板：左侧 NavigationRail，内容占满其余宽度
              Row() {
                this.sideRail()
                Column() {
                  this.pagesStack()
                }
                .layoutWeight(1)
                .height('100%')
              }
              .width('100%')
              .height('100%')
              .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
            } else {
             Stack({ alignContent: Alignment.Bottom }) {
               this.pagesStack()
               // 只有首页在栈顶时才画底部胶囊：压在别的页面下面时它会被透出来
               if (this.isStackTop) {
                 this.bottomBar()
               }
             }
              .width('100%')
              .height('100%')
              .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
            }
          }
        }
        .width('100%')
        .height('100%')
      }, (revision: number) => `theme-${revision}`)
     }
     .width('100%')
     .height('100%')
     // 沉浸式：内容要铺到状态栏与手势区（与原 @Entry 页行为一致）
     .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
     /**
      * 导航形态：
      *   - 手机 / 平板：**一律底部 HDS 胶囊**（用户 2026-10-07：「导航也弄成
      *     跟手机一样在下方的 HdsTabs 形式」）；
      *   - 2in1 / PC：横屏（或宽 ≥840）时才换成左侧 NavigationRail（规格 §1.5，
      *     桌面端侧边竖栏才是惯例）。
      * 判据用根容器实测尺寸：横竖切换、分栏、自由窗口拉伸都会走这里。
      */
     .onAreaChange((oldValue: Area, newValue: Area) => {
       const width: number = Number(newValue.width);
       const height: number = Number(newValue.height);
       if (Math.abs(width - this.shellWidth) > 0.5) {
         this.shellWidth = width;
       }
       const wide: boolean = this.isDesktopDevice && (width > height || width >= 840);
       if (wide !== this.wideLayout) {
         this.wideLayout = wide;
         NavScrollController.setHidden(false);
       }
     })
     }
     .width('100%')
     .height('100%')
     .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
   // 自己画顶栏（四个 Tab 的标题在页面内部），系统标题栏一律隐藏
   .hideTitleBar(true)
   // 关掉系统滑动转场：共享元素转场由 geometryTransition 负责，
   // 两者叠加会看到「整页滑入 + 封面飞出」的双重动画
   .systemTransition(NavigationSystemTransitionType.NONE)
  }

  /** 四个主 Tab 的常驻挂载层（切换只改可见性，不重建页面）。 */
  @Builder
  pagesStack() {
    Stack() {
      RecommendPage({
        themeRev: this.themeRevision,
        // 滚动上报给导航控制器（对应源码的 ScrollNotification 监听）
        onScrollOffset: (offset: number, maxOffset: number) => {
          NavScrollController.report(offset, this.currentIndex !== 0, maxOffset);
        }
      })
        .visibility(this.currentIndex === 0 ? Visibility.Visible : Visibility.None)
      // 四个主 Tab 都上报滚动：导航条的弹入弹出在每一页都成立
      // （第二个参数是「本页是否被路由覆盖」，只有当前 Tab 才作数）
      TimetablePage({
        themeRev: this.themeRevision,
        onScrollOffset: (offset: number, maxOffset: number) => {
          NavScrollController.report(offset, this.currentIndex !== 1, maxOffset);
        }
      })
        .visibility(this.currentIndex === 1 ? Visibility.Visible : Visibility.None)
      CollectPage({
        themeRev: this.themeRevision,
        onScrollOffset: (offset: number, maxOffset: number) => {
          NavScrollController.report(offset, this.currentIndex !== 2, maxOffset);
        }
      })
        .visibility(this.currentIndex === 2 ? Visibility.Visible : Visibility.None)
      MinePage({
        themeRev: this.themeRevision,
        onScrollOffset: (offset: number, maxOffset: number) => {
          NavScrollController.report(offset, this.currentIndex !== 3, maxOffset);
        }
      })
        .visibility(this.currentIndex === 3 ? Visibility.Visible : Visibility.None)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.TopStart)
    .opacity(this.pageOpacity)
  }

  /** 底部胶囊导航（竖屏）。 */
  @Builder
  bottomBar() {
    Column() {
      // 设备支持 HDS 就用官方「沉浸光感」材质；不支持则回退到自绘玻璃胶囊。
      // 判据用 syscap，而不是平台名——能力是以 syscap 授权的。
      if (canIUse('SystemCapability.UIDesign.HDSComponent.Core')) {
        this.hdsBottomBar()
      } else {
        ImmersiveBottomBar({
          themeRev: this.themeRevision,
          selectedIndex: this.currentIndex,
          items: this.navItems,
          onSelected: (index: number) => {
            this.selectTab(index);
          }
       })
      }
     }
    .width(this.barShellWidth())
    .padding({
      left: Dimens.navSideInset,
      right: Dimens.navSideInset,
      bottom: this.navBottomPadding() + Dimens.navBottomGap
    })
    // 隐藏时整体下沉 90% 并缩放、淡出；同时停止响应点击
    // （对应源码的 IgnorePointer(ignoring: _navHidden)）
    .translate({ y: `${this.navSlideY * 100}%` })
    .scale({ x: this.navScale, y: this.navScale })
    .opacity(this.navOpacity)
    .hitTestBehavior(this.navHidden ? HitTestMode.None : HitTestMode.Default)
  }

  /**
   * HarmonyOS 官方「沉浸光感」底部胶囊（HDS `HdsTabs`）。
   *
   * 参考实现（用户指名的「夏绊」工程 `pages/HomePage.ets`）的做法，逐项照搬：
   *
   *   1. **只借外壳**：每个 `TabContent` 都是空的，`.onContentWillChange` 返回
   *      `false` 阻止 HdsTabs 自己切内容——四个主 Tab 仍由 `pagesStack()`
   *      常驻挂载、切换只改可见性；
   *   2. **浮动胶囊三件套**：`barPosition(End)` + `barOverlap(true)` +
   *      `barFloatingStyle`，缺一个就退化成贴边的普通 TabBar；
   *   3. 尺寸/圆角/裁剪都由外层给（高 52、圆角 26、左右内缩 18），
   *      系统只负责材质与光效；
   *   4. 显隐仍走我们自己的 `navSlideY/navScale/navOpacity`
   *      （HdsTabs 自带的 `applyHideAnimation` 是另一套语义，不用它）。
   *
   * 与自绘版本的差别：不再是「surface @ 72% 色块」，而是系统按设备能力
   * 给出的真实材质 + 品牌点光源——这正是自绘做不到的那部分。
   */
  @Builder
  hdsBottomBar() {
    HdsTabs({ controller: this.tabsController }) {
      ForEach(this.navItems, (item: NavItemModel, index: number) => {
        TabContent() {
        }
        .tabBar(this.navTabItem(index, item))
      }, (item: NavItemModel) => `hds-tab-${item.label}`)
    }
    .vertical(false)
    .barPosition(BarPosition.End)
    .scrollable(false)
    .barOverlap(true)
    .barHeight(Dimens.navHeight)
    .barFloatingStyle({
      barBottomMargin: 0,
      barWidth: {
        smallWidth: this.barWidth,
        mediumWidth: this.barWidth,
        largeWidth: this.barWidth
      },
      // 品牌点光源：主题主色提亮后的暖光（见 AppColor.navLightSource）
      lightColor: AppColor.navLightSource,
      systemMaterialEffect: {
        materialType: this.barMaterialType,
        materialLevel: this.barMaterialLevel
      },
      barOpacity: 0.9
    })
    .onContentWillChange((currentIndex: number, comingIndex: number): boolean => {
      return false;
    })
    .onTabBarClick((index: number) => {
      this.selectTab(index);
    })
    .width('100%')
    .height(Dimens.navHeight)
    // 与胶囊同形裁剪，限制系统材质的阴影沿胶囊轮廓扩散
    .borderRadius(Dimens.navHeight / 2)
    .clip(true)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const w: number = Number(newValue.width);
      if (w > 0 && Math.abs(w - this.barWidth) > 0.5) {
        this.barWidth = w;
      }
    })
  }

  /** 单个导航项的外观（图标 23 / 文字 11 / 选中 w600 + 主色）。 */
  @Builder
  navTabItem(index: number, item: NavItemModel) {
    Column() {
      SymbolGlyph(index === this.currentIndex ? item.filledIcon : item.outlineIcon)
        .fontSize(23)
        .fontColor([index === this.currentIndex
          ? AppColor.primary : AppColor.onSurfaceVariant])
      Text(item.label)
        .fontSize(11)
        .lineHeight(11)
        .fontWeight(index === this.currentIndex ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(index === this.currentIndex
          ? AppColor.primary : AppColor.onSurfaceVariant)
        .margin({ top: 2 })
        .maxLines(1)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .accessibilityText(item.label)
  }

  /** 侧边导航栏（横屏 / 平板）：与底部胶囊同源的选中态与图标。 */
  @Builder
  sideRail() {
    Column() {
      ForEach(this.navItems, (item: NavItemModel, index: number) => {
        Column() {
          SymbolGlyph(index === this.currentIndex ? item.filledIcon : item.outlineIcon)
            .fontSize(24)
            .fontColor([index === this.currentIndex
              ? AppColor.onPrimaryContainer : AppColor.onSurfaceVariant])
          Text(item.label)
            .fontSize(11)
            .fontWeight(index === this.currentIndex ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(index === this.currentIndex
              ? AppColor.onPrimaryContainer : AppColor.onSurfaceVariant)
            .margin({ top: 4 })
            .maxLines(1)
        }
        .width(64)
        .height(64)
        .justifyContent(FlexAlign.Center)
        .borderRadius(20)
        .backgroundColor(index === this.currentIndex
          ? AppColor.primaryContainer : Color.Transparent)
        .margin({ bottom: 8 })
        .animation({ duration: Motion.medium, curve: AppCurves.easeOutCubic() })
        .onClick(() => {
          this.selectTab(index);
        })
      }, (item: NavItemModel) => `rail-${item.label}`)
    }
    .width(88)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 12, right: 12 })
    // 宽屏侧边导航栏与底部胶囊用同一档系统材质
    .backgroundBlurStyle(AppMaterial.bar, AppMaterial.options())
    .backgroundColor(AppColor.navGlassLight)
    .border({ width: { right: 1 }, color: AppColor.navBorderLight })
  }

  /**
   * 切换 Tab。
   *
   * 规格 §12.2：Tab 之间是 70ms 的 `FadeTransition`。ArkUI 里没有全局
   * 路由交叉淡入，这里用「先把新页透明再 70ms 淡到不透明」逼近——
   * 时长与曲线都取自同一处令牌。
   */
  private selectTab(index: number): void {
    if (index === this.currentIndex) {
      return;
    }
    // 切 Tab 时重置滚动基线：每个 Tab 有自己的滚动位置，
    // 直接用上一次的绝对偏移算 delta 会得到一次假的「大幅滚动」。
    NavScrollController.reset();
    this.pageOpacity = 0;
    this.currentIndex = index;
    NavScrollController.setHidden(false);
    animateTo({ duration: TabTransition.duration, curve: TabTransition.curve() }, () => {
      this.pageOpacity = 1;
    });
  }
}

// 导航栈的目的地表。
//
// 做过迁移的页面在这里登记；没登记的页面仍然走 router
// （main_pages.json 里还留着它们），所以迁移可以一页一页来，
// 中途任何时候工程都是可用的。
//
// param 目前用不到：本工程一直用 RouteArgs 那套静态槽位传值
// （详情页要传的是带方法的 BangumiItem 实例，JSON 化参数传不了），
// 迁移时保留这套，省掉一处大改。
/**
 * 所有页面统一套的 NavDestination 外壳。
 *
 * 三点都是刻意的（照搬参考实现 `F:\app` 夏绊）：
 *   - `hideTitleBar(true)`：页面自己画标题栏，不要系统标题栏；
 *   - `systemTransition(NONE)`：关掉系统滑动转场，只留 `geometryTransition`，
 *     否则会看到「整页滑入 + 封面飞出」两套动画叠在一起；
 *   - `expandSafeArea(TOP|BOTTOM)`：**这条是保住沉浸式的关键**。
 *     页面内部都按 AppStorage 里的 `topInset` 自己让位，如果 NavDestination
 *     再按安全区收一次，就是双重内缩——状态栏与手势区会露出底色。
 */
@Builder
function Dest(name: string, param: Object) {
  NavDestination() {
    /**
     * 中间这层 `Stack` **不能省**。
     *
     * `expandSafeArea` 只有挂在 **NavDestination 的直接子节点**上才生效；
     * 而 `NavDestination() { InfoPage() }` 里 InfoPage 是自定义组件，
     * 真正要铺满的根容器（页面内部的 Stack）成了**孙节点**，扩不出去——
     * 表现就是底部短一截，露出下面 Index 的 `AppBackground` 底色（近白）：
     * 一条白条（用户反馈的现象）。
     *
     * 参考实现（`F:\app` 夏绊）是 `NavDestination() { Stack(...) ... }`，
     * 铺满的 Stack 就是直接子节点，所以没这个问题。
     */
    Stack() {
    if (name === 'Home') {
      HomeShell()
    } else if (name === 'pages/VideoPage') {
      VideoPage()
    } else if (name === 'pages/SearchPage') {
      SearchPage()
    } else if (name === 'pages/HistoryPage') {
      HistoryPage()
    } else if (name === 'pages/DownloadPage') {
      DownloadPage()
    } else if (name === 'pages/StoragePage') {
      StoragePage()
    } else if (name === 'pages/ThemeSettingsPage') {
      ThemeSettingsPage()
    } else if (name === 'pages/PlayerSettingsPage') {
      PlayerSettingsPage()
    } else if (name === 'pages/DanmakuSettingsPage') {
      DanmakuSettingsPage()
    } else if (name === 'pages/DanmakuShieldPage') {
      DanmakuShieldPage()
    } else if (name === 'pages/DownloadSettingsPage') {
      DownloadSettingsPage()
    } else if (name === 'pages/InterfaceSettingsPage') {
      InterfaceSettingsPage()
    } else if (name === 'pages/SuperResolutionSettingsPage') {
      SuperResolutionSettingsPage()
    } else if (name === 'pages/NetworkSettingsPage') {
      NetworkSettingsPage()
    } else if (name === 'pages/ProxyEditorPage') {
      ProxyEditorPage()
    } else if (name === 'pages/LogsPage') {
      LogsPage()
    } else if (name === 'pages/PluginPage') {
      PluginPage()
    } else if (name === 'pages/PluginCatalogPage') {
      PluginCatalogPage()
    } else if (name === 'pages/PluginEditorPage') {
      PluginEditorPage()
    } else if (name === 'pages/PluginTestPage') {
      PluginTestPage()
    } else if (name === 'pages/ProtoPage') {
      ProtoPage()
    }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
  .hideTitleBar(true)
  // STANDARD：普通压栈。共享元素转场要求两端的 NavDestination 都是这个模式
  // （SINGLE 之类会复用实例，geometryTransition 拿不到「两个节点同时存在」的时机）
  .mode(NavDestinationMode.STANDARD)
  /**
   * **交给系统做导航转场**（原来这里是 `NONE`）。
   *
   * 起因（2026-09-18，用户：「让所有页面的切换都加上鸿蒙化的动画」）：
   *   1. 30 个页面里写的 `PageTransitionEnter/Exit` 是 **`router` 页面路由**
   *      的 API，9-17 迁到 `Navigation`/`NavDestination` 之后已经失效；
   *   2. 这里又把系统转场关成 `NONE`（当时是为了让「海报共享元素」成为
   *      唯一的动画，避免两套动画叠加）；
   *   3. 而 `NavHost` 的 push/pop 一律传 `animated = false`。
   * 三条叠起来的结果是**整页转场等于没有**——设置、历史、日志这些页面
   * 都是「啪」地出现。
   *
   * 现在改成按跳转类型区分：带共享元素的（海报 → 详情页）走
   * `NavHost.pushWithHero`，那一侧仍然关掉系统转场、由几何转场驱动；
   * 其余跳转交给系统——方向感、弹簧曲线、返回手势的跟手都是鸿蒙自己的。
   */
  .systemTransition(NavigationSystemTransitionType.DEFAULT)
  .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  /**
   * NavDestination 没有 `onPageShow`（那是 @Entry 页的回调）。
   *
   * 各页面里原本靠 `onPageShow` 做的「回到本页时刷新」，改成看这个计数：
   * 每次本目的地被显示就把 `navShown:<名字>` +1，页面用
   * `@StorageProp` + `@Watch` 订阅它。
   * 用**按目的地分开的 key**而不是一个全局计数——否则后台还活着的页面
   * 也会跟着刷新。
   */
  .onShown(() => {
    const key: string = `navShown:${name}`;
    const current: number | undefined = AppStorage.get<number>(key);
    AppStorage.setOrCreate(key, (current === undefined ? 0 : current) + 1);
    /**
     * 详情页是覆盖层、不再有 `onShown`：从播放页返回时「重开播放来源弹层」
     * 那条流程原来靠目的地回调触发，这里由首页代转一次（详情页订阅的是同一个
     * key，见 `InfoPage.onNavShown`）。
     */
    if (name === 'Home' && NavHost.isInfoOpen()) {
      const infoKey: string = 'navShown:pages/InfoPage';
      const infoCurrent: number | undefined = AppStorage.get<number>(infoKey);
      AppStorage.setOrCreate(infoKey, (infoCurrent === undefined ? 0 : infoCurrent) + 1);
    }
    // 记一笔「首页刚露出来」：弹栈那一下的返回事件会再落到这里，
    // 靠这个时间戳把它挡掉（见 NavHost.requestInfoExit）
    if (name === 'Home') {
      NavHost.noteHomeShown();
    }
    // 栈深：首页据此决定要不要画底部胶囊
    AppStorage.setOrCreate('navStackDepth',
      NavHost.stack === null ? 1 : NavHost.stack.size());
  })
  .onHidden(() => {
    AppStorage.setOrCreate('navStackDepth',
      NavHost.stack === null ? 1 : NavHost.stack.size());
  })
  // 页面自己的返回拦截（原来的 onBackPress）由 NavHost 转调
  .onBackPressed(() => NavHost.handleBack(name))
}

/**
 * 导航栈的目的地表。
 *
 * 做过迁移的页面在这里登记；没登记的页面仍然走 `router`
 * （`main_pages.json` 里还留着它们），所以迁移可以一页一页来，
 * 中途任何时候工程都是可用的。
 */
@Builder
function PageMap(name: string, param: Object) {
  Dest(name, param)
}

// 应用入口：只负责搭 Navigation 宿主。
//
// 结构照搬参考实现（F:\app 夏绊的 pages/Index.ets）：
// Navigation 只提供一个空宿主 + navDestination(PageMap)，
// 真正的界面全部是 NavDestination，由 pathStack 驱动——
// 跨页面的共享元素才有几何插值的依据。
@Entry
@Component
struct Index {
  // 全应用唯一的导航栈（@Provide 给各个 NavDestination 取用）。
  @Provide('pathStack') pathStack: NavPathStack = new NavPathStack();
  /**
   * 详情页覆盖层挂在**这一层**（`Navigation` 之上）。
   *
   * 一开始我把它放在首页那个 NavDestination 里，结果「从搜索页 / 历史页点封面」
   * 就看不见了——那两页是压在首页**上面**的目的地，覆盖层被它们盖住
   * （用户 2026-10-08：「搜索页点击图片不能触发封面进详情页的动画」）。
   * 放在 `Navigation` 之上就没有这个问题：从哪个页面点进来都能盖住，
   * 关掉之后露出来的也正是「点进来的那一页」（和参照实现里详情路由压在当前页
   * 之上、返回时回到当前页一致）。
   */
  @StorageProp('infoOverlayOpen') @Watch('onInfoOverlayChanged') infoOpenTick: number = 0;
  /** 每个详情层打开时所在的导航深度（见 `NavHost.openInfoOverlay`）。 */
  @State private infoLayerBases_: number[] = [];
  /** 当前栈深（由 `Dest` 的 onShown/onHidden 维护）。 */
  @StorageProp('navStackDepth') @Watch('onNavDepthChanged') navDepthNow: number = 1;
  @State private infoOpen: boolean = false;

  /** 覆盖层从「被压住」回到「露出来」时，让详情页重新设一次系统栏。 */
  onNavDepthChanged(): void {
    if (!this.infoOpen) {
      return;
    }
    /**
     * 覆盖层「让开 / 回来」都要**跟转场同步地淡**，不能瞬间切显隐。
     *
     * 上面压了新页面（播放页）时，覆盖层必须让位；但如果直接切
     * `Visibility.Hidden`，详情页就会**啪地消失**，播放页的滑入压在首页上——
     * 状态栏转黑那一刻落在的背景和 2.0.1（详情页还是目的地、播放页压着详情页
     * 滑进来）完全不同，观感就是「没以前流畅」（用户 2026-10-09 的反馈）。
     * 这里改成：让位时 250ms 淡出（播放页在下面滑入，交叉淡化），
     * 回来时 250ms 淡入。
     */
    const maxBase: number = this.maxInfoLayerBase();
    const visible: boolean = this.navDepthNow <= maxBase;
    animateTo({
      duration: 250,
      curve: AppCurves.easeOutCubic()
    }, () => {
      this.infoOverlayOpacity = visible ? 1 : 0;
    });
    if (visible) {
      this.notifyInfoReshown();
    }
  }

  /** 覆盖层透明度（让位/回来时用；见 `onNavDepthChanged`）。 */
  @State private infoOverlayOpacity: number = 1;

  private maxInfoLayerBase(): number {
    let max: number = 1;
    for (let i = 0; i < this.infoLayerBases_.length; i++) {
      max = Math.max(max, this.infoLayerBases_[i]);
    }
    return max;
  }

  /**
   * 某一层详情是否属于当前可见的导航位置。
   *
   * 例：原详情在第 1 层，标签搜索在第 2 层，搜索中新开详情也在第 2 层。
   * 此时只显示第 2 层的详情；关掉它以后，第 1 层的原详情继续隐藏，
   * 返回搜索页；搜索页退到第 1 层后，原详情才重新显示。
   */
  private isInfoLayerVisible(level: number): boolean {
    const base: number = level < this.infoLayerBases_.length
      ? this.infoLayerBases_[level] : 1;
    return this.navDepthNow <= base;
  }

  /**
   * 播放页覆盖层（压在详情覆盖层之上，见 `NavHost.pushInternal` 的注释）。
   *
   * 它自带**从右滑入/滑出**（和系统压栈同一种观感），因此详情页在它进出时
   * 原地不动、被盖住——这正是 2.0.1 里「详情页和播放页都是页面」的关系。
   * `videoSlide` 是横向位移（占自身宽度比例）：1 = 完全在屏幕右侧，
   * 0 = 就位。
   */
  @StorageProp('videoOverlayOpen') @Watch('onVideoOverlayChanged') videoOpenTick: number = 0;
  @State private videoOpen: boolean = false;
  @State private videoSlide: number = 1;

  onVideoOverlayChanged(): void {
    const open: boolean = this.videoOpenTick > 0;
    if (open) {
      // 先挂上、放到屏幕右侧，再推曲线滑入（首帧必须是屏外那一格）
      this.videoSlide = 1;
      this.videoOpen = true;
      animateTo({
        duration: 300,
        curve: AppCurves.easeOutCubic()
      }, () => {
        this.videoSlide = 0;
      });
      return;
    }
    if (!this.videoOpen) {
      return;
    }
    // 滑出之后再卸载，避免"啪"地消失
    animateTo({
      duration: 300,
      curve: AppCurves.easeInCubic()
    }, () => {
      this.videoSlide = 1;
    });
    setTimeout(() => {
      this.videoOpen = false;
    }, 320);
  }

  onInfoOverlayChanged(): void {
    const open: boolean = this.infoOpenTick > 0;
    if (open !== this.infoOpen) {
      this.infoOpen = open;
    }
    /**
     * 层号数组必须**自己存住**、不能每次 build 现造。
     *
     * `ForEach` 是按「数据源 + key」复用的：每次 build 新建一个数组实例时，
     * ArkUI 会把它当成新数据源重算一遍，已经在树上的那几层详情页会被
     * **重新创建**——重建的实例会重跑进场动画（首帧透明 + 下移 2%），
     * 表现就是「点关联时当前详情页被往下拖了一下」（用户 2026-10-09）。
     * 存成 `@State` 之后数组只在层数变化时变，已有的层按 key 原样复用。
     */
    const levels: number[] = [];
    for (let i = 0; i < this.infoOpenTick; i++) {
      levels.push(i);
    }
    this.infoLevels_ = levels;
    this.infoLayerBases_ = NavHost.getInfoOverlayBases();
    // 搜索页上打开新详情时，覆盖层基准会从旧详情页抬到搜索页；
    // 这里按新的基准立即重算显隐，不能等用户关闭搜索页触发下一次栈深变化。
    this.onNavDepthChanged();
  }

  /**
   * 覆盖层「重新露出来」（播放页等压在上面的页面退掉）时，通知详情页**重新确认
   * 一次系统栏样式**。
   *
   * 状态栏/导航条是全局的，整个工程只有播放页在改（进入时黑底白标、离开时还原）。
   * 详情页现在是覆盖层、不是目的地，播放页返回时它只是重新可见、不会重新挂载，
   * 于是没人去把系统栏改回来——用户看到的就是「退出播放页后状态栏黑一段时间」
   * （2026-10-09）。这里发一个计数，详情页收到后自己再设一次。
   */
  @Watch('onInfoReshown') @StorageProp('infoReshownTick') infoReshownTick: number = 0;

  onInfoReshown(): void {
    // 只用于触发详情页的 watch，本身不需要状态
  }

  private notifyInfoReshown(): void {
    const tick: number = AppStorage.get<number>('infoReshownTick') ?? 0;
    AppStorage.setOrCreate('infoReshownTick', tick + 1);
  }

  /** 详情覆盖层的层号数组（`ForEach` 用；层数 = `infoOverlayOpen` 的值）。 */
  @State private infoLevels_: number[] = [];

  aboutToAppear(): void {
    // 把栈交给 `RouteTable` / `RouteArgs` 这些非组件的地方用（见 `NavHost`）
    NavHost.stack = this.pathStack;
    // 共享元素转场的动画要一个 UIContext 来驱动（见 NavHost.push）
    NavHost.uiContext = this.getUIContext();
    // 再注入一次主题：Ability 级那次发生在 UI 创建之前，
    // 文档写明「在页面级调用」对**本页与后续打开的页面**生效——
    // 菜单 / 对话框都是后续打开的弹层，所以这里补一次最稳。
    ArkUITheme.apply();
    // 首页也要入栈：它自己是 NavDestination，四个 Tab 的封面是转场起点
    this.pathStack.pushPathByName('Home', null);
  }

  /**
   * `@Entry` 页这一层的返回兜底（含右滑手势）。
   *
   * 正常路径上这条**不会被调到**：栈顶目的地的 `onBackPressed`
   * （`Dest()` → `NavHost.handleBack` → `HomeShell.onBackPress`）已经返回 true
   * 把事件消费掉了。留着它是防「首页没登记处理器 / 栈已经空了」这类异常路径——
   * 这时返回 false 会让 Navigation 继续弹，栈一空就只剩白屏，所以按同一套
   * 「两次就退出」处理（见 `ExitGate`）。
   */
  onBackPress(): boolean {
    if (this.pathStack.size() > 1) {
      return false;
    }
    if (!ExitGate.ask()) {
      ExitGate.prompt(this.getUIContext());
      return true;
    }
    ExitGate.exit(this.getUIContext());
    return true;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Navigation(this.pathStack) {
      }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    /**
     * 关掉底部的「工具栏」预留位。
     *
     * Navigation 默认会在底部留一条工具栏区（即使里面是空的）。
     * 我们的容器里什么工具栏都没有，但这一条**仍然占着高度**——
     * 于是 NavDestination 的内容区比窗口短一截，底部露出宿主底色（近白）。
     *
     * ⚠️ 2026-09-18 更正：这条**不是**详情页「背景最下面一大块白」的原因。
     * 那次真机逐像素定位（`详情页美化/` 四张截图 + 设备复现）证明，
     * 白块来自 `InfoPage.build()` 里被 `Stack.alignContent(BottomEnd)`
     * 摆到屏幕底部的那层「顶部渐变遮罩」（高 `topInset + 72` = 108vp，
     * 与实测的距底 108vp 硬边完全吻合），与本条无关。
     * 这里保留 `hideToolBar`：配置了工具栏的页面本来就该能关掉它，无害。
     */
    .hideToolBar(true)
    .navDestination(PageMap)
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      /**
       * 详情页覆盖层：压在**整个 Navigation 之上**（见 `infoOpen` 的注释）。
       *
       * 按**层数**渲染：详情页里的「相关推荐」再点进一部番就是叠第二层，
       * 参照实现里那也是一条压在详情页之上的详情路由。每层各是一个实例，
       * 各自持有自己的番剧参数与退场动画，返回时只退栈顶那一层。
       */
      if (this.infoOpen) {
        /**
         * ⚠️ 上面压了别的页面（播放页）时，这一层是**藏起来**而不是**卸载**：
         * 卸载会把叠着的每层详情页都销毁，等播放页回来再重建——重建出来的实例
         * 拿不到自己那一层的番剧参数（只剩「最后打开的那一部」），
         * 于是「番1 → 关联进番2 → 播放 → 逐层返回」时第二层退出来还是番2、
         * 回到不番1（用户 2026-10-09 报的就是这个）。
         * 用 `Visibility.Hidden` 既看不见、也不吃触摸，实例与数据都留着。
         */
       Stack() {
        ForEach(this.infoLevels_, (level: number) => {
          Stack() {
            InfoPage()
          }
          .width('100%')
          .height('100%')
          .visibility(this.isInfoLayerVisible(level)
            ? Visibility.Visible : Visibility.Hidden)
          .hitTestBehavior(this.isInfoLayerVisible(level)
            ? HitTestMode.Default : HitTestMode.None)
        }, (level: number) => `info-level-${level}`)
        }
        .width('100%')
        .height('100%')
        // 淡到 0 之后才真正藏起来（实例与各层数据都留着，见上面的注释）
        .opacity(this.infoOverlayOpacity)
        .visibility(this.infoOverlayOpacity <= 0.01
          ? Visibility.Hidden : Visibility.Visible)
        .hitTestBehavior(this.infoOverlayOpacity >= 0.99
          ? HitTestMode.Default : HitTestMode.None)
      }

      // 播放页覆盖层：**压在详情覆盖层之上**，自己从右滑入/滑出
      if (this.videoOpen) {
        Stack() {
          VideoPage()
        }
        .width('100%')
        .height('100%')
        .translate({ x: `${this.videoSlide * 100}%` })
        // 播放页原来是目的地，靠 `Dest()` 的 expandSafeArea 铺满；
        // 现在它是这一层覆盖，安全区得自己吃进来（否则状态栏那一条会短一截）
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
