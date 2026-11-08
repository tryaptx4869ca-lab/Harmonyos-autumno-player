import { RouteTable } from '../router/RouteTable';
import { InfoRouteArgs, SearchRouteArgs } from '../router/RouteArgs';
import { HeroRects } from '../router/HeroRects';
import { BangumiApi } from '../api/BangumiApi';
import { DailyQuoteService, DailyQuote } from '../api/HitokotoApi';
import { BangumiItem } from '../model/BangumiItem';
import { AppColor } from '../theme/AppColors';
import { AppMaterial } from '../theme/Material';
import { Dimens, Motion, AppCurves, HeroFlight } from '../theme/Tokens';
import { TS } from '../theme/Typography';
import { Viewport } from '../utils/Viewport';
import { defaultAnimeTags } from '../utils/SearchParser';
import { HistoryEntry } from '../model/HistoryModels';
import { HistoryRepository } from '../services/HistoryRepository';
import { LoadingIndicator } from '../components/LoadingIndicator';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';
import { CoverImage } from '../components/CoverImage';

/**
 * 标签菜单的最大高度（vp）。
 *
 * 16 个条目（全部 + 15 个题材）逐条排开是 768vp，比一屏还高，系统会把菜单
 * 掀到锚点上方。截到 5 项半（264vp）之后，「全部」按钮下方刚好放得下。
 * 超出部分**由我们自己放进 `Scroll` 里滚动**（不能靠 `Menu` 的约束，
 * 那会把滚动区一起压掉）。想再看几条改这个数即可。
 */
const TAG_MENU_MAX_HEIGHT: number = 264;

/** 标签菜单宽度（vp）：题材名最多 3 个字，168 够放且不显空。 */
const TAG_MENU_WIDTH: number = 168;

/**
 * 榜单缓存（**模块级**，跨页面实例存活）。
 *
 * 对应参照实现把数据放在 `PopularController`（MobX store）里的做法
 * ——`popular_page.dart:75` 的加载条件是：
 *
 * ```dart
 * if (popularController.trendList.isEmpty) {
 *   popularController.queryBangumiByTrend();
 * }
 * scrollController = ScrollController(
 *   initialScrollOffset: popularController.scrollOffset,
 * );
 * ```
 *
 * 也就是「**列表非空就不重新拉**」+「滚动位置也存在 controller 里」。
 * 本工程的页面实例可能被重建（每次回来都会走 `aboutToAppear`），
 * 所以把这份状态提到模块级，语义与源码一致：回来时列表还在、滚动位置也还在，
 * 不再出现「每次退回推荐页都在重新加载」（用户 2026-09-18）。
 */
class RecommendCache {
  static items: BangumiItem[] = [];
  static trendOffset: number = 0;
  static currentTag: string = '';
  static scrollOffset: number = 0;
}

/**
 * 推荐页。对应参照实现 lib/pages/popular/popular_page.dart。
 *
 * 数据源与参照实现一致：默认走 Bangumi 镜像（api.kazumi.fyi），
 * 即 popular_controller.dart 中 `_bangumiMirrorEnabled` 为真的分支。
 * 直连 next.bgm.tv / api.bgm.tv 在部分网络下无法解析域名。
 *
 * 布局用 List 而非 Scroll：ArkUI 的 Scroll 在内容短于视口时会把内容居中，
 * 造成顶部偏移；List 始终从顶部排布，也更贴近参照实现的 CustomScrollView。
 */
@Component
export struct RecommendPage {
  @State heroItems: BangumiItem[] = [];
  @State gridItems: BangumiItem[] = [];
  @State quoteText: string = '';
  @State quoteSource: string = '';
  @State quoteAuthor: string = '';
  @State greeting: string = '';
  @State subtitle: string = '';
  /**
   * 首屏/切标签是否正在联网。
   *
   * ⚠️ **初值必须是 `false`**（用户 2026-09-19：「热门番组已经加载完了，
   * 但头上的加载条还在加载」）。`aboutToAppear` 里「有缓存就直接用缓存、
   * 不联网」这条分支**不会**进 `loadData()`，而 `loadData()` 是第一处
   * 把 `loading` 置 true 的地方——初值给 true 的话，缓存分支下这个状态
   * 永远是 true，顶部加载条就一直转下去（数据其实早就到位了）。
   * `loadData()` 自己是先 `loading = true` 再 await 的，所以初值给 false
   * 不会漏掉首屏那一次显示。
   */
  @State loading: boolean = false;
  /** 网格尺寸：屏宽 / 列数 / 0.65 + 32 */
  @State cardHeight: number = 217;
  @State cardWidth: number = 104;
  /** 实测可用宽度（横屏/平板上要扣掉侧边导航栏）。 */
  @State viewportWidth: number = 0;
  /** 回顶按钮显隐（参照实现：offset > 420） */
  @State showBackToTop: boolean = false;
  @State loadingMore: boolean = false;
  /** 当前标签：空 = 趋势榜（按钮显示「全部」）。 */
  @State currentTag: string = '';
  /**
   * 标签菜单展开态（规格 §4.6 的「全部 ∨」）。
   *
   * 2026-09-17 起由**自绘 `RevealMenu`** 换成 HarmonyOS 原生菜单
   * （`bindMenu` + `Menu`/`MenuItem`）：原生菜单自带毛玻璃、圆角、投影、
   * 出现动画、点击外部关闭与按键语义，也不再需要「节点挂载/卸载 + 播放
   * 收起动画」这套状态机。
   */
  @State private tagMenuOpen: boolean = false;
  /** Banner 自动播放：按下暂停、抬起恢复（规格 §4.4）。 */
  @State bannerAutoPlay: boolean = true;
  /** 分页偏移，参照实现 _trendOffset */
  private trendOffset: number = 0;
  /** 补最后一行时正在请求（与 `loadingMore` 分开，避免底部加载圈闪一下）。 */
  private fillingRow: boolean = false;
  /** 参照实现 _heroBannerCount */
  private readonly heroCount: number = 6;
  private listScroller: Scroller = new Scroller();
  /** 顶部系统状态栏高度（vp），由 EntryAbility 写入 */
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('bottomInset') bottomInset: number = 28;
  /** 主题版本：由 Index 下发，@Prop 变化会让本组件整体重跑 build。 */
  @Prop themeRev: number = 0;
  /**
   * 滚动上报。
   *
   * 第二个参数是**当前可滚动的最大偏移**（内容高 − 视口高）：导航隐藏控制器
   * 要靠它区分「真的在往下翻内容」和「已经到底了、手指还在往上推」。
   * 少了它，列表末尾的回弹位移会被当成正常滚动，把导航条顶没。
   */
  onScrollOffset: (offset: number, maxOffset: number) => void = () => {};

  /** 滚动内容与视口高度（vp），用于算 maxOffset。 */
  @State private contentHeight: number = 0;
  @State private viewportHeight: number = 0;

  /** 「今日一句」正在查条目（防连点，并把箭头换成加载圈）。 */
  @State private quoteOpening: boolean = false;

  /** 「最近在看」行（§4.2 第 4 项）：按番剧去重后的前 6 条在线/缓存历史。 */
  @State recentItems: HistoryEntry[] = [];
  @StorageProp('historyRevision') @Watch('onHistoryChanged') historyRevision: number = 0;

  aboutToAppear(): void {
    this.applyGreeting(new Date());
    this.applyGridMetrics();
    this.loadRecent();
    /**
     * **只在没有数据时才拉取**（对照 `popular_page.dart:75`）。
     *
     * 数据活在模块级缓存里（相当于源码的 `PopularController`），所以从详情页
     * 回来时直接用缓存的列表，不重新请求、也不跳回顶部。
     */
    if (RecommendCache.items.length > 0) {
      this.currentTag = RecommendCache.currentTag;
      this.trendOffset = RecommendCache.trendOffset;
      this.gridItems = RecommendCache.items.slice();
      this.heroItems = RecommendCache.items.slice(0, this.heroCount);
      this.restoreScrollOffset();
      // 缓存是按上次的列数切的：这次列数不同就要补满最后一行
      this.fillLastRow();
    } else {
      this.loadData();
    }
    this.loadQuote();
  }

  /**
   * 恢复上次的滚动位置（对照源码 `ScrollController(initialScrollOffset:)`）。
   *
   * 放在 setTimeout 里：`aboutToAppear` 时列表还没排版，`scrollTo` 会被忽略；
   * 等首帧排完版再滚，才落得准。
   */
  private restoreScrollOffset(): void {
    const offset: number = RecommendCache.scrollOffset;
    if (offset <= 0) {
      return;
    }
    setTimeout(() => {
      try {
        this.listScroller.scrollTo({ xOffset: 0, yOffset: offset });
      } catch (e) {
        // 列表还没就绪就忽略：下次进页面还会再试
      }
    }, 0);
  }

  onHistoryChanged(): void {
    this.loadRecent();
  }

  /**
   * 取「最近在看」。
   *
   * 参照实现 `_loadRecentHistories()`：历史已按时间倒序，
   * 按番剧 id 去重后取前 6 条（同一部番从多个规则看过只显示最近的那条）。
   * 隐私模式打开时按源码语义**整行为空**。
   */
  private loadRecent(): void {
    if (SettingsStore.getBool(SettingsKeys.privateMode)) {
      this.recentItems = [];
      return;
    }
    const all: HistoryEntry[] = HistoryRepository.getAll();
    const seen: number[] = [];
    const out: HistoryEntry[] = [];
    for (let i = 0; i < all.length; i++) {
      const entry: HistoryEntry = all[i];
      const id: number = entry.bangumiItem.id;
      if (seen.indexOf(id) >= 0) {
        continue;
      }
      seen.push(id);
      out.push(entry);
      if (out.length >= 6) {
        break;
      }
    }
    this.recentItems = out;
  }

  /**
   * 大屏（横屏 / 平板）内容最大宽度。
   *
   * 手机竖屏时没有任何影响；平板上页面可用宽度会到 1300vp 以上，而这一页
   * 的每一段（问候语、Banner、今日一句、热门网格）都是「整宽 + 16vp 内边距」，
   * 于是：Banner 被拉成 1300×236 的超扁长条（封面图裁得只剩中间一横条）、
   * 「今日一句」变成一行字横跨整屏的白条。这里给内容加一条上限并居中，
   * 与时间表页（1280）/ 搜索页（1120/760）的做法保持一致。
   */
  private static readonly CONTENT_MAX_WIDTH: number = 1120;

  /** 页面可用宽度（实测；拿不到时退回整屏）。 */
  private pageWidth(): number {
    return Viewport.widthVp(this.viewportWidth);
  }

  /** 大屏时内容两侧居中的额外留白（小屏恒为 0）。 */
  private sideInset(): number {
    const width: number = this.pageWidth();
    const cap: number = RecommendPage.CONTENT_MAX_WIDTH;
    return width > cap ? (width - cap) / 2 : 0;
  }

  /** 各段统一的左右内边距：16vp 内容边距 + 大屏居中留白。 */
  private hInset(): number {
    return Dimens.contentInset + this.sideInset();
  }

  /** 内容区宽度（已扣掉大屏居中留白）。 */
  private contentRegion(): number {
    return this.pageWidth() - this.sideInset() * 2;
  }

  /**
   * Banner 一屏放几张。
   *
   * 手机上 1 张（保持原样）；平板上并排 2 张——一张 1088 宽的横幅只能把
   * 2:3 的封面裁成一条 3:1 的横带，并排 2 张后每张约 544×326 ≈ 1.7:1，
   * 既不用把封面裁得那么狠，一屏还能多看一部（用户 2026-10-07 的平板适配）。
   */
  private heroColumns(): number {
    return this.contentRegion() >= 840 ? 2 : 1;
  }

  /**
   * Banner 高度。
   *
   * 参照实现固定 236：手机上（可用宽 ~330）约 1.4:1，正常；平板上可用宽
   * 1088 时就是 4.6:1 的扁条，封面被裁得看不出画面（用户 2026-10-07：
   * 「发现页没适配好」）。现在按「每张卡片的实际宽度」反推高度，夹在
   * 236~340 之间：手机保持 236 不变，平板并排两张时约 540×326（1.65:1）。
   */
  private heroHeight(): number {
    const columns: number = this.heroColumns();
    const cardWidth: number =
      (this.contentRegion() - Dimens.contentInset * 2) / columns;
    /**
     * 比例取 0.5（≈ 2:1）。手机算出来 164 → 被 236 的下限托住，逐字不变；
     * 平板并排两张时是 544×272 ≈ 1.94:1。高度还兼着一个约束：平板首屏要让
     * **一整行卡片连同标题**落在悬浮的底部胶囊之上（否则胶囊会压住卡片标题，
     * 用户 2026-10-07 的截图反馈），所以这个值不能再大。
     */
    const scaled: number = cardWidth * 0.50;
    if (scaled > 280) {
      return 280;
    }
    return scaled > 236 ? scaled : 236;
  }

  /**
   * 参照实现：mainAxisExtent = 屏宽 / crossCount / 0.65 + 32。
   *
   * 注意「屏宽」在大屏上要取**内容区宽度**：这一页在大屏会把内容居中收到
   * `CONTENT_MAX_WIDTH`，网格行宽也因此只有内容区那么宽，卡片按整屏宽算
   * 会溢出。
   */
  private applyGridMetrics(): void {
    const screenW: number = this.contentRegion();
    const columns: number = Viewport.gridColumns(screenW);
    this.cardHeight = screenW / columns / 0.65 + 32;
    /**
     * 间距只放在卡片之间，不再给最后一列补右外边距。
     * 否则左侧是 16vp 内边距、右侧却多出 8vp 的尾部空位，整组卡片会明显左偏。
     */
    this.cardWidth =
      (screenW - Dimens.contentInset * 2 - Dimens.cardSpace * (columns - 1)) / columns;
  }

  /** 列数（规格 §4.6）：compact 3 / medium 5 / expanded 6。 */
  private columns(): number {
    return Viewport.gridColumns(this.contentRegion());
  }

  /**
   * 每页条数：**必须是列数的整数倍**。
   *
   * 参照实现固定 12 条：手机 3 列正好 4 行；但平板竖屏是 5 列（规格 §4.6），
   * 12 条 = 2 行零 2 个，最后一行右侧空出 3 个卡位（用户 2026-10-31 的截图
   * 里那块「缺了 3 张」的空白）。改成「列数 × 4 行」：手机仍是 12（逐字不变），
   * 平板竖屏 20、大屏 6 列 24，每一页都刚好排满整行。
   */
  private pageSize(): number {
    return this.columns() * 4;
  }

  /** 问候语分档，取自 popular_page.dart `_greetingFor`。 */
  private applyGreeting(now: Date): void {
    const hour: number = now.getHours();
    if (hour >= 5 && hour < 12) {
      this.greeting = '早上好';
      this.subtitle = '今天想看点什么？';
    } else if (hour >= 12 && hour < 18) {
      this.greeting = '下午好';
      this.subtitle = '逛一逛，发现好番';
    } else if (hour >= 18 && hour < 24) {
      this.greeting = '晚上好';
      this.subtitle = '今晚想看点什么？';
    } else {
      this.greeting = '夜深了';
      this.subtitle = '早点休息，明天再追';
    }
  }

  private showTip(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 提示失败不影响主流程
    }
  }

  private async loadData(): Promise<void> {
    this.loading = true;
    try {
      let list: BangumiItem[] = [];
      try {
        // 参照实现 popular_controller.dart：enableBangumiProxy 默认为 true，
        // 因此首次加载走镜像榜单。页大小按列数取整行（见 `pageSize()`）。
        list = await BangumiApi.popular('', this.pageSize(), 0);
        // 2. 退路一：趋势榜
        if (list.length === 0) {
          list = await BangumiApi.trending(this.pageSize(), 0);
        }
        // 3. 退路二：官方排名检索
        if (list.length === 0) {
          list = await BangumiApi.rankSearch('', this.pageSize(), 0);
        }
      } catch (e) {
        list = [];
      }
      if (list.length > 0) {
        // 偏移 = 服务端已经给过多少条，而不是本地数组长度：
        // 去重会从本地数组里减人，用长度当偏移会重复请求同一段
        this.trendOffset = list.length;
        this.heroItems = list.slice(0, this.heroCount);
        this.gridItems = this.uniqueById(list);
        this.saveCache();
      }
    } finally {
      // 同 `loadMore`：收旗必须在 finally，漏一条路径就是「加载条一直转」
      this.loading = false;
    }
    // ⚠️ 补行必须在 `finally` 之后：`fillLastRow()` 自己会避开 `loading`
    // 期间（首屏加载时列数还没定、数据也没到），写在 try 里会被自己挡掉。
    this.fillLastRow();

    // 今日一句不在这里取：它有自己的按天缓存，见 `loadQuote()`。
  }

  /**
   * 今日一句。
   *
   * 2026-09-19 两条要求叠在一起：
   *   - 「优化一下加载？每次回到推荐页都要重新加载」→ 返回本页时**不再联网**；
   *   - 「改成每次打开都换？」→ **每次冷启动应用**都换一条。
   *
   * 于是缓存落在 `DailyQuoteService` 的**进程内**内存里：页面实例被重建时
   *   1. 本次运行已经取过 → 同步填上，第一帧就是完整的一条，不闪不联网；
   *   2. 还没取过（刚启动）→ 先用**本地文案**顶上（不出现空白卡片），
   *      同时后台请求 hitokoto，回来再换成网络那条。
   */
  private loadQuote(): void {
    const cached: DailyQuote | null = DailyQuoteService.cached();
    if (cached !== null) {
      this.applyQuote(cached);
      return;
    }
    this.applyQuote(DailyQuoteService.localToday());
    DailyQuoteService.load().then((quote: DailyQuote) => {
      this.applyQuote(quote);
    });
  }

  private applyQuote(quote: DailyQuote): void {
    this.quoteText = quote.text;
    this.quoteSource = quote.source;
    this.quoteAuthor = quote.author;
  }

  /** 触底续拉，参照实现滚到距底 600 时追加下一页。 */
  private async loadMore(): Promise<void> {
    if (this.loadingMore || this.gridItems.length === 0) {
      return;
    }
    this.loadingMore = true;
    try {
      let more: BangumiItem[] = [];
      try {
        more = await BangumiApi.popular(this.currentTag, this.pageSize(),
          this.trendOffset);
      } catch (e) {
        more = [];
      }
      if (more.length > 0) {
        // 偏移按**服务端实际给出的条数**推进：镜像榜单偶尔少给几条，
        // 按 pageSize 推进会把下一次请求的起点推过头、白丢几条
        this.trendOffset += more.length;
        // 按 id 去重，参照实现同样是 where(existingIds.add)
        const ids: Set<number> = new Set<number>();
        for (const it of this.gridItems) {
          ids.add(it.id);
        }
        const merged: BangumiItem[] = this.gridItems.slice();
        for (const it of more) {
          if (!ids.has(it.id)) {
            ids.add(it.id);
            merged.push(it);
          }
        }
        this.gridItems = merged;
        this.saveCache();
      }
    } finally {
      /**
       * 一定要在 `finally` 里收旗：续拉的加载圈就是看这个标志位的，
       * 任何一条早早 return / 抛出的路径漏掉它，圈就会一直转下去
       * （顶部那条旧进度条 2026-09-19 就是这么被用户抓到的）。
       */
      this.loadingMore = false;
    }
    // 续拉这一页里去重掉了几条时，最后一行可能又缺格：顺手补满
    this.fillLastRow();
  }

  /**
   * 把最后一行补满。
   *
   * 每页条数已经是列数的整数倍，但**换屏会改列数**：平板竖屏 5 列拿到 20 条，
   * 转成横屏 6 列，最后一行就只剩 2 条；从缓存恢复的列表也可能是按旧列数切的。
   * 行里缺格子看起来就是「这块少了番剧」（用户 2026-10-31 的截图），
   * 所以缺几条就按当前偏移补几条，补完恰好又是一整行。
   *
   * 平时不用管：续拉按整页走，列数又是每页条数的约数，正常不会切出不完整的行。
   * 只有两种例外会调用它——换屏改了列数，以及续拉那页被去重吃掉几条。
   */
  private async fillLastRow(): Promise<void> {
    if (this.fillingRow || this.loading || this.loadingMore) {
      return;
    }
    const columns: number = this.columns();
    const loaded: number = this.gridItems.length;
    if (loaded === 0 || columns <= 0) {
      return;
    }
    const missing: number = columns - loaded % columns;
    if (missing === 0 || missing === columns) {
      return;
    }
    this.fillingRow = true;
    try {
      let more: BangumiItem[] = [];
      try {
        more = await BangumiApi.popular(this.currentTag, missing, this.trendOffset);
      } catch (e) {
        more = [];
      }
      if (more.length === 0) {
        return;
      }
      this.trendOffset += more.length;
      const ids: Set<number> = new Set<number>();
      for (const it of this.gridItems) {
        ids.add(it.id);
      }
      const merged: BangumiItem[] = this.gridItems.slice();
      for (const it of more) {
        if (!ids.has(it.id)) {
          ids.add(it.id);
          merged.push(it);
        }
      }
      this.gridItems = merged;
      this.saveCache();
    } finally {
      this.fillingRow = false;
    }
  }

  /**
   * 切换标签（规格 §4.6「全部 ∨」）。
   *
   * 参照实现 `showTagMenu`：菜单项 = 空项（全部）+ `defaultAnimeTags`；
   * 选「全部」且当前有标签时清空回趋势榜；选其它标签则按标签重新检索首页。
   */
  private async selectTag(tag: string): Promise<void> {
    this.tagMenuOpen = false;
    if (tag === this.currentTag) {
      return;
    }
    this.loading = true;
    this.gridItems = [];
    this.heroItems = [];
    this.trendOffset = 0;
    this.currentTag = tag;
    try {
      let list: BangumiItem[] = [];
      try {
        if (tag.length === 0) {
          // 回趋势榜：镜像榜单失败时逐级回落到趋势 / 排名检索
          list = await BangumiApi.popular('', this.pageSize(), 0);
          if (list.length === 0) {
            list = await BangumiApi.trending(this.pageSize(), 0);
          }
          if (list.length === 0) {
            list = await BangumiApi.rankSearch('', this.pageSize(), 0);
          }
        } else {
          list = await BangumiApi.popular(tag, this.pageSize(), 0);
        }
      } catch (e) {
        list = [];
      }
      if (list.length > 0) {
        this.trendOffset = list.length;
        this.heroItems = list.slice(0, this.heroCount);
        this.gridItems = this.uniqueById(list);
        RecommendCache.scrollOffset = 0;
        this.saveCache();
      }
    } finally {
      // 同 `loadMore`：收旗必须在 finally
      this.loading = false;
    }
    // 同上：补行放在 `finally` 之后，避免被 `loading` 标志挡掉
    this.fillLastRow();
  }

  /**
   * 把当前列表写进模块级缓存（相当于源码把数据留在 `PopularController` 里）。
   * 滚动位置由滚动回调单独维护。
   */
  private saveCache(): void {
    RecommendCache.items = this.gridItems.slice();
    RecommendCache.trendOffset = this.trendOffset;
    RecommendCache.currentTag = this.currentTag;
  }

  /**
   * 按 id 去重（保持顺序）。
   *
   * 镜像榜单在同一页里偶尔会重复给同一条目：不去重的话，网格里会出现
   * 两张一模一样的卡；更早的实现还因为 ForEach 按 key 去重，把重复的那张
   * 直接吞掉，行里留下空格——两种都不对，所以在**数据层**先去掉。
   */
  private uniqueById(items: BangumiItem[]): BangumiItem[] {
    const seen: Set<number> = new Set<number>();
    const out: BangumiItem[] = [];
    for (const it of items) {
      if (!seen.has(it.id)) {
        seen.add(it.id);
        out.push(it);
      }
    }
    return out;
  }

  /** 把列表切成每行 3 个，保证网格与 Flutter 的 SliverGrid 一致。 */
  private rows(items: BangumiItem[]): BangumiItem[][] {
    const out: BangumiItem[][] = [];
    const columns: number = this.columns();
    for (let i = 0; i < items.length; i += columns) {
      out.push(items.slice(i, i + columns));
    }
    return out;
  }

  private quoteAttribution(): string {
    const parts: string[] = [];
    if (this.quoteAuthor.length > 0) {
      parts.push(this.quoteAuthor);
    }
    if (this.quoteSource.length > 0) {
      parts.push(`《${this.quoteSource}》`);
    }
    return parts.length > 0 ? `— ${parts.join(' · ')}` : '';
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // 用 Scroll 而非 List：Swiper 放在 List 里时，轮播换页会把父列表
      // 滚动到焦点项，导致整个页面被推走。Scroll + 最小高度约束更稳。
      Scroll(this.listScroller) {
        Column() {
          this.greetingHeader()
          this.heroSection()
          this.quoteSection()
          if (this.recentItems.length > 0) {
            this.recentSection()
          }
          this.hotHeader()
          this.hotGrid()
          Row() {
            Blank()
          }
          .width('100%')
          .height(Dimens.contentBottomSpacer)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .constraintSize({ minHeight: '100%' })
        // 量内容高度：maxOffset = 内容高 − 视口高
        .onAreaChange((oldValue: Area, newValue: Area) => {
          const h: number = Number(newValue.height);
          if (h > 0 && h !== this.contentHeight) {
            this.contentHeight = h;
          }
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const h: number = Number(newValue.height);
        if (h > 0 && h !== this.viewportHeight) {
          this.viewportHeight = h;
        }
      })
      .onDidScroll(() => {
        const off: number = this.listScroller.currentOffset().yOffset;
        // 记进缓存：回来时用 `restoreScrollOffset()` 恢复（对照源码把
        // `scrollOffset` 存在 controller 里）。这里只是赋值，不触发重绘。
        RecommendCache.scrollOffset = off;
        const next: boolean = off > 420;
        if (next !== this.showBackToTop) {
          this.showBackToTop = next;
        }
        const reachable: number = this.contentHeight - this.viewportHeight;
        this.onScrollOffset(off, reachable > 0 ? reachable : 0);
      })
      .onReachEnd(() => {
        this.loadMore();
      })

      this.backToTopButton()
    }
    .width('100%')
    .height('100%')
    // 响应式：横屏 / 平板下可用宽度会变（侧边导航栏占 88vp），
    // 网格列数与卡片尺寸都按实测宽度重算（规格 §4.6）。
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width: number = Number(newValue.width);
      if (Math.abs(width - this.viewportWidth) > 0.5) {
        this.viewportWidth = width;
        this.applyGridMetrics();
        // 列数变了，最后一行会缺格（横竖屏切换、分屏拖拽都会走到这里）
        this.fillLastRow();
      }
    })
  }

  /**
   * 回顶按钮。参照实现 popular_page.dart `_buildBackToTopButton`：
   *   right: 14；bottom: bottomInset + 58 + 8 + 16
   *   出现：scale 0.4→1 / 220ms easeOutCubic，opacity / 180ms
   */
  @Builder
  backToTopButton() {
    Stack() {
      SymbolGlyph($r('sys.symbol.arrow_up'))
        .fontSize(22)
        .fontColor([AppColor.primary])
    }
    .width(46)
    .height(46)
    .borderRadius(23)
    .backgroundBlurStyle(AppMaterial.capsule, AppMaterial.options())
    .backgroundColor(AppColor.navGlassLight)
    .border({ width: 1, color: AppColor.navBorderLight })
    .shadow({ radius: 16, color: '#14000000', offsetX: 0, offsetY: 5 })
    .margin({
      right: 14,
      bottom: this.bottomInset + Dimens.navHeight + Dimens.navBottomGap + 16
    })
    .scale({ x: this.showBackToTop ? 1 : 0.4, y: this.showBackToTop ? 1 : 0.4 })
    .animation({ duration: Motion.medium, curve: AppCurves.easeOutCubic() })
    .opacity(this.showBackToTop ? 1 : 0)
    .animation({ duration: Motion.quick, curve: AppCurves.easeOutCubic() })
    .onClick(() => {
      this.listScroller.scrollTo({
        xOffset: 0,
        yOffset: 0,
        animation: { duration: Motion.slow, curve: AppCurves.easeOutCubic() }
      });
    })
  }

  // ---------- 1. 问候头 ----------

  @Builder
  greetingHeader() {
    Row() {
      Column() {
        Text(this.greeting)
          .fontSize(TS.headlineSmallSize)
          .lineHeight(TS.headlineSmallLine)
          .fontWeight(TS.w700)
          .letterSpacing(0.3)
          .fontColor(AppColor.onSurface)
        Text(this.subtitle)
          .fontSize(TS.bodyMediumSize)
          .lineHeight(TS.bodyMediumLine)
          .fontWeight(TS.w400)
          .letterSpacing(TS.ls)
          .fontColor(AppColor.onSurfaceVariant)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Stack() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(22)
        .fontColor([AppColor.primary])
      }
      .width(46)
      .height(46)
      .borderRadius(23)
      .backgroundColor(AppColor.navGlassLight)
      .border({ width: 1, color: AppColor.navBorderLight })
      .shadow({ radius: 16, color: '#14000000', offsetX: 0, offsetY: 5 })
      .margin({ left: 14 })
      // 规格 §8 / `popular_page.dart:346`：问候语行右侧的搜索入口
      .onClick(() => {
        RouteTable.push(RouteTable.search);
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .padding({
      left: this.hInset(),
      right: this.hInset(),
      top: this.topInset + 10,
      // 大屏收 8：首屏要让一整行卡片落在悬浮胶囊之上（见 `heroHeight()`）
      bottom: this.sideInset() > 0 ? 10 : 18
    })
  }

  // ---------- 2. Banner ----------

  @Builder
  heroSection() {
    Column() {
      if (this.heroItems.length === 0) {
        Row() {
          LoadingIndicator({ sizeVp: 40 })
        }
        .width('100%')
        .height(this.heroHeight())
        .justifyContent(FlexAlign.Center)
      } else {
        Swiper() {
          ForEach(this.heroItems, (item: BangumiItem, index: number) => {
            this.heroCard(item, index)
          }, (item: BangumiItem) => item.id.toString())
        }
        // 规格 §4.4：手动 Timer + Listener.onPointerDown 暂停 / onPointerUp 恢复。
        .autoPlay(this.bannerAutoPlay)
        .interval(6000)
        .loop(true)
        .indicator(false)
        .duration(400)
        // 平板一屏并排两张（见 `heroColumns()`）；手机仍是 1，逐字不变
        .displayCount(this.heroColumns())
        .width('100%')
        .height(this.heroHeight())
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.bannerAutoPlay = false;
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.bannerAutoPlay = true;
          }
        })
      }
    }
    .width('100%')
    .padding({ left: this.hInset(), right: this.hInset() })
  }

  @Builder
  heroCard(item: BangumiItem, index: number) {
    Stack({ alignContent: Alignment.BottomStart }) {
      CoverImage({
        src: item.cover.length > 0 ? item.coverUrl() : $r('app.media.icon'),
        fit: ImageFit.Cover
      })
        .width('100%')
        .height('100%')
        // Hero 共享元素（§38.7）：Banner 海报 → 详情页海报
        .geometryTransition(HeroFlight.tag('recommend-banner', item.id))
        // 记下源封面在**窗口**里的位置：退场时自绘的飞行层要用（见 HeroRects）
        .onAreaChange((oldValue: Area, newValue: Area) => {
          HeroRects.setCard(HeroFlight.tag('recommend-banner', item.id), newValue);
        })
        /**
         * ⚠️ **这里不能给海报加 `zIndex(1)`**（2026-09-18 修）。
         *
         * 本卡片是 `Stack` 叠放：海报在最底，上面依次是压暗渐变和标题/评分。
         * ArkUI 里 zIndex 大的后画（盖在上面），海报一旦拿到 zIndex(1)，
         * 就会把**标题、评分、渐变一起盖掉**——真机表现就是「推荐页 Banner
         * 上的标题和评分消失了」（海报本身还在，所以看着只是少了文字）。
         * 旁边那些「海报在图左、文字在图右」的卡片（时间表 / 收藏 / 搜索）
         * 不叠放，加 zIndex 没有视觉影响，所以只有这两处要改。
         */

      // 底部压暗渐变：transparent → 0xB3000000，stops 0.42 / 1.0
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.42], ['#B3000000', 1.0]]
        })

      Column() {
        Text(item.displayName())
          .fontSize(TS.titleMediumSize)
          .lineHeight(TS.titleMediumLine)
          .fontWeight(TS.w700)
          .letterSpacing(TS.ls)
          .fontColor(Color.White)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (item.score > 0) {
          Row() {
            SymbolGlyph($r('sys.symbol.star_fill'))
              .fontSize(14)
              .fontColor(['#FFC24B'])
            Text(item.score.toFixed(1))
              .fontSize(TS.labelMediumSize)
              .lineHeight(TS.labelMediumLine)
              .letterSpacing(TS.ls)
              .fontColor('#E6FFFFFF')
              .margin({ left: 4 })
          }
          .margin({ top: 4 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 14 })
    }
    .width('100%')
    // 高度跟着 Banner 宽度走（见 `heroHeight()`）：平板上不再被拉成超扁长条
    .height(this.heroHeight())
    .borderRadius(24)
    .clip(true)
    /**
     * 平板并排两张时，只在**左边那张**右边留 10 的间距（`index` 是偶数的一对
     * 里的前一张），右边缘与下面「今日一句」「热门网格」严格对齐；手机
     * （`heroColumns() == 1`）这条恒为 0，逐字不变。
     */
    .margin({
      right: this.heroColumns() > 1 && index % this.heroColumns() === 0 ? 10 : 0
    })
    // 规格 §4.4 里每页是 `EdgeInsets.only(right: 10)`（外层 SliverPadding 左右各 16），
    // 展开后是「左 16 / 右 26」——海报会被挤向左侧，用户反馈左右不对称。
    // 这里把这段 10 的内边距**左右均分**（各 5）：海报尺寸与源码完全一致
    // （仍是屏宽 - 42），只是左右留白变成 21 / 21，视觉上居中。
    .padding({ left: 5, right: 5 })
    .onClick(() => {
      // 参照实现：Banner 卡片点进详情页（`popular_page.dart` 的 onTap）
      InfoRouteArgs.open(item, 'recommend-banner',
        HeroFlight.tag('recommend-banner', item.id));
    })
  }

  // ---------- 3. 今日一句 ----------

  @Builder
  quoteSection() {
    Row() {
      // GlassSurface(card)：surface 66% 底 + 左上白色 16% 高光。
      // 两层在 ArkUI 里用 Stack 叠加会让 height('100%') 的渐变层把卡片撑满
      // 剩余视口，故预先合成为单层渐变（页面底色即为 surface，两者等价）。
      Row() {
        // 参照实现使用 Material 的 format_quote 图标；
        // 鸿蒙符号库无对应名，先用文字引号逼近，待图标保真阶段替换。
        Text('“')
          .fontSize(34)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.primary)
          .height(26)
          .margin({ top: 2 })

        Column() {
          Row() {
            Text('今日一句')
              .fontSize(TS.labelMediumSize)
              .lineHeight(TS.labelMediumLine)
              .fontWeight(TS.w500)
              .letterSpacing(1.2)
              .fontColor(AppColor.onSurfaceVariant)
            Blank()
            // 在查条目时把箭头换成系统加载圈，避免连点
            if (this.quoteOpening) {
              LoadingIndicator({ sizeVp: 12 })
            } else {
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(11)
                .fontColor([AppColor.onSurfaceVariant])
            }
          }
          .width('100%')

          Text(this.quoteText)
            .fontSize(TS.bodyLargeSize)
            .lineHeight(TS.bodyLargeLine)
            .fontWeight(TS.w500)
            .letterSpacing(TS.ls)
            .fontColor(AppColor.onSurface)
            .margin({ top: 8 })
            .width('100%')

          if (this.quoteAttribution().length > 0) {
            Text(this.quoteAttribution())
              .fontSize(TS.labelMediumSize)
              .lineHeight(TS.labelMediumLine)
              .fontWeight(TS.w500)
              .letterSpacing(TS.ls)
              .fontColor(AppColor.onSurfaceVariant)
              .margin({ top: 10 })
              .width('100%')
              .textAlign(TextAlign.End)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: 20, right: 20, top: 16, bottom: 14 })
      .borderRadius(22)
      .clip(true)
      .linearGradient({
        angle: 135,
        colors: [[AppColor.glassCardHighlight, 0.0], [AppColor.glassCardBase, 1.0]]
      })
      .border({ width: 1, color: AppColor.glassBorder })
      // 规格 §4.5：整卡可点 → 跳转到所引作品的条目。
      // 进入逻辑见 `openQuoteEntry()`：搜得到就直进详情页，搜不到才去搜索结果页。
      .onClick(() => {
        this.openQuoteEntry();
      })
    }
    .width('100%')
    /**
     * 顶部间距 22 → 16（平板自适配时一起收的）：平板首屏 76 问候 + Banner +
     * 这句 + 热门页头就把竖直空间吃完了，网格只能露一行。
     */
    .padding({
      left: this.hInset(),
      right: this.hInset(),
      top: this.sideInset() > 0 ? 12 : 16
    })
  }

  /**
   * 「今日一句」的进入逻辑（用户 2026-09-17 指定）。
   *
   * 引文只给「作者 · 《作品》」这种文本，没有 Bangumi 条目 id，所以：
   *
   *   1. 取**作品名**（没有作品名时退到作者名）去 Bangumi 搜一遍；
   *   2. 结果里有条目标题与关键词**完全相同**（归一化后）→ **直接进详情页**；
   *   3. 没有完全匹配、或请求失败 → 进搜索结果页，把判断权交回用户。
   *
   * **只要完全匹配**（用户 2026-09-17 收紧）：早先允许「互相包含」也算命中，
   * 但引文出处经常是小说 / 剧场版 / 同名游戏，`关键词 ⊂ 条目名` 这种弱匹配
   * 会把用户直接送进一个不相干的条目——那比多点一次搜索结果页更糟。
   * 宁可多一次点击，也不要进错页面。
   */
  private async openQuoteEntry(): Promise<void> {
    if (this.quoteOpening) {
      return;
    }
    const keyword: string = RecommendPage.quoteKeyword(this.quoteSource, this.quoteAuthor);
    if (keyword.length === 0) {
      this.showTip('这句没有可跳转的作品');
      return;
    }
    this.quoteOpening = true;
    let hit: BangumiItem | null = null;
    try {
      const list: BangumiItem[] = await BangumiApi.bangumiSearch(keyword, 5, 0);
      hit = RecommendPage.pickQuoteHit(list, keyword);
    } catch (e) {
      hit = null;
    }
    this.quoteOpening = false;
    if (hit !== null) {
      InfoRouteArgs.open(hit, 'quote');
      return;
    }
    SearchRouteArgs.open(keyword);
  }

  /** 关键词：优先作品名，其次作者名；`《》`「」 之类书名号去掉。 */
  private static quoteKeyword(source: string, author: string): string {
    const raw: string = source.trim().length > 0 ? source : author;
    return raw.replace(/[《》「」【】〈〉\s]/g, '').trim();
  }

  /**
   * 从搜索结果里挑出**标题完全一致**的条目，没有就返回 null。
   *
   * 比对前做归一化（去书名号、去空白、转小写），这样
   * 「《葬送的芙莉莲》」与「葬送的芙莉莲」算同一部；
   * 但**不做包含匹配**——带副标题的「葬送的芙莉莲 第二季」不算命中，
   * 那种情况交给搜索结果页，由用户自己挑。
   */
  private static pickQuoteHit(list: BangumiItem[], keyword: string): BangumiItem | null {
    const key: string = RecommendPage.normalizeTitle(keyword);
    if (key.length === 0) {
      return null;
    }
    for (let i = 0; i < list.length; i++) {
      const cn: string = RecommendPage.normalizeTitle(list[i].nameCn);
      const jp: string = RecommendPage.normalizeTitle(list[i].name);
      if (cn === key || jp === key) {
        return list[i];
      }
    }
    return null;
  }

  /** 标题归一化：去空白、去书名号、转小写。 */
  private static normalizeTitle(text: string): string {
    return text.replace(/[《》「」【】〈〉\s]/g, '').toLowerCase();
  }

  // ---------- 3.5 最近在看（仅有历史时，§4.2 第 4 项） ----------

  /**
   * 「最近在看」行。
   *
   * 参照实现 `popular_page.dart` 的 `_buildRecentSection`：
   * 上边距 24；标题行左右 16，右侧「全部」跳历史页；
   * 列表高 214、横向滚动、卡片间距 12、左右各留 16。
   */
  @Builder
  recentSection() {
    Column() {
      Row() {
        Text('最近在看')
          .fontSize(TS.titleLargeSize)
          .lineHeight(TS.titleLargeLine)
          .fontWeight(TS.w700)
          .letterSpacing(TS.ls)
          .fontColor(AppColor.onSurface)
        Blank()
        Row() {
          Text('全部')
            .fontSize(TS.bodyMediumSize)
            .fontWeight(TS.w500)
            .fontColor(AppColor.onSurfaceVariant)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([AppColor.onSurfaceVariant])
            .margin({ left: 2 })
        }
        .padding({ left: 12, right: 4, top: 6, bottom: 6 })
        .borderRadius(18)
        .onClick(() => {
          RouteTable.push(RouteTable.history);
        })
      }
      .width('100%')
      .padding({ left: this.hInset(), right: this.hInset() })

      Scroll() {
        Row() {
          ForEach(this.recentItems, (entry: HistoryEntry) => {
            this.recentCard(entry)
          }, (entry: HistoryEntry) => `recent-${entry.key()}`)
        }
        .padding({ left: this.hInset(), right: this.hInset() })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(214)
      .margin({ top: 12 })
      .align(Alignment.Start)
    }
    .width('100%')
    .padding({ top: 24 })
  }

  /**
   * 「最近在看」卡片：150×214、圆角 18、底部三段信息。
   * 点卡片进**详情页**（不是直接播放），与参照实现一致。
   */
  @Builder
  recentCard(entry: HistoryEntry) {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 与详情页海报同址（`coverUrl()`）：共享元素两端必须是同一个 URL
      if (entry.bangumiItem.coverUrl().length > 0) {
        CoverImage({ src: entry.bangumiItem.coverUrl(), fit: ImageFit.Cover })
          .width(150)
          .height(214)
          .draggable(false)
          // Hero 共享元素（§38.7）：最近在看卡片 → 详情页海报
          .geometryTransition(HeroFlight.tag('recommend-recent', entry.bangumiItem.id))
          .onAreaChange((oldValue: Area, newValue: Area) => {
            HeroRects.setCard(HeroFlight.tag('recommend-recent', entry.bangumiItem.id), newValue);
          })
          // 同 heroCard：这是 Stack 叠放卡，海报加 zIndex 会盖掉上面的标题/进度文字
      } else {
        Column()
          .width(150)
          .height(214)
          .backgroundColor(AppColor.surfaceContainerHighest)
      }

      // 底部渐变（transparent → 黑 78%，stops 0.48 / 1.0）
      Column()
        .width(150)
        .height(214)
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], ['#C7000000', 1.0]]
        })

      Column() {
        Text(entry.displayName())
          .fontSize(TS.bodyMediumSize)
          .lineHeight(TS.bodyMediumLine * 1.2)
          .fontWeight(TS.w600)
          .fontColor('#FFFFFF')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(entry.lastWatchEpisodeName.length === 0
          ? `看到第 ${entry.lastWatchEpisode} 话`
          : `看到 ${entry.lastWatchEpisodeName}`)
          .fontSize(TS.labelSmallSize)
          .fontColor('#D1FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 10, right: 10, bottom: 10 })
    }
    .width(150)
    .height(214)
    .borderRadius(18)
    .clip(true)
    .margin({ right: 12 })
    .onClick(() => {
      InfoRouteArgs.open(entry.bangumiItem, 'recommend-recent',
        HeroFlight.tag('recommend-recent', entry.bangumiItem.id));
    })
  }

  // ---------- 4. 热门番组 标题 ----------

  @Builder
  hotHeader() {
    Row() {
      Text('热门番组')
        .fontSize(TS.titleLargeSize)
        .lineHeight(TS.titleLargeLine)
        .fontWeight(TS.w700)
        .letterSpacing(TS.ls)
        .fontColor(AppColor.onSurface)
      Blank()
      Row() {
        Text(this.currentTag.length === 0 ? '全部' : this.currentTag)
          .fontSize(TS.bodyMediumSize)
          .lineHeight(TS.bodyMediumLine)
          .fontWeight(TS.w400)
          .letterSpacing(TS.ls)
          .fontColor(AppColor.onSurfaceVariant)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(18)
          .fontColor([AppColor.onSurfaceVariant])
          .margin({ left: 2 })
      }
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(18)
      .onClick(() => {
        this.tagMenuOpen = true;
      })
      // 原生菜单：挂在内置容器上、且不写空 onClick（本工程实测的可用组合）
      .bindMenu(this.tagMenuOpen, this.tagMenu, {
        placement: Placement.BottomRight,
        onDisappear: () => {
          this.tagMenuOpen = false;
        }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: this.hInset(),
      right: this.hInset(),
      // 与「今日一句」同上：平板首屏竖直预算紧张，页头收 8
      top: this.sideInset() > 0 ? 8 : 16,
      bottom: 4
    })
  }

  // ---------- 5. 网格 ----------

  @Builder
  hotGrid() {
    Column() {
      ForEach(this.rows(this.gridItems), (row: BangumiItem[], rowIndex: number) => {
        Row({ space: Dimens.cardSpace }) {
          ForEach(row, (item: BangumiItem, index: number) => {
            this.posterCard(item)
          }, (item: BangumiItem, index: number) => `${item.id}-${rowIndex}-${index}`)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ bottom: Dimens.cardSpace - 2 })
      /**
       * key 带上行号：镜像榜单偶尔会**重复给同一个条目**（续拉去重只挡新加的那批，
       * 服务端一页内部重复挡不住）。ForEach 按 key 去重，重了的那张卡就整张不渲染，
       * 行里留下一个空格——看起来正是「少了一部番剧」。加行号/序号后每张卡都有
       * 唯一 key，重复条目照旧显示（内容一样，用户看不出来），但格子不会再缺。
       */
      }, (row: BangumiItem[], rowIndex: number) => `row-${rowIndex}-${row.length}`)
      // 续拉的加载圈放在网格**下方**（新内容出现的位置），不是页面顶部
      this.loadingMoreFooter()
    }
    .width('100%')
    .padding({
      left: this.hInset(),
      right: this.hInset(),
      top: Dimens.cardSpace
    })
  }

  @Builder
  posterCard(item: BangumiItem) {
    // 对应参照实现 bean/card/bangumi_card.dart 的 BangumiCardV：
    //   GlassSurface(borderRadius 18)
    //     └ Column(stretch)
    //         ├ AspectRatio(0.65) 封面图
    //         └ Expanded → Padding(fromLTRB(5,3,5,1)) → Text(nameCn)
    //   标题为纯文字、位于图片下方，w500 / letterSpacing 0.3 / 最多 2 行，
    //   卡片不显示评分。
    Column() {
      // 与详情页海报同址（`coverUrl()`）：共享元素两端必须是同一个 URL
      CoverImage({
        src: item.cover.length > 0 ? item.coverUrl() : $r('app.media.icon'),
        fit: ImageFit.Cover
      })
        .width('100%')
        .aspectRatio(0.65)
        // Hero 共享元素（§38.7）：热门网格海报 → 详情页海报
        .geometryTransition(HeroFlight.tag('recommend-grid', item.id))
          .onAreaChange((oldValue: Area, newValue: Area) => {
            HeroRects.setCard(HeroFlight.tag('recommend-grid', item.id), newValue);
          })
          .zIndex(1)

      Text(item.nameCn)
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 5, right: 5, top: 3, bottom: 1 })
        .fontSize(TS.bodyMediumSize)
        .lineHeight(TS.bodyMediumLine)
        .fontWeight(TS.w500)
        .letterSpacing(0.3)
        .fontColor(AppColor.onSurface)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(this.cardWidth)
    .height(this.cardHeight)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(18)
    .clip(true)
    .backgroundColor(AppColor.glassCardFill)
    .border({ width: 1, color: AppColor.glassBorder })
    .onClick(() => {
      InfoRouteArgs.open(item, 'recommend-grid',
        HeroFlight.tag('recommend-grid', item.id));
    })
  }

  /**
   * 触底续拉的加载行（鸿蒙化后的「加载中」）。
   *
   * ## 为什么把参照实现那条顶部进度条换掉（用户 2026-09-19 提的）
   *
   * 参照实现用 Material 的 `LinearProgressIndicator`（不定长）压在内容顶部，
   * 本工程此前是**自绘**等价物：32% 宽的高亮块 + 900ms 无限往复 `translate`。
   * 两个问题：
   *   1. 它不是平台的东西——HarmonyOS 的「加载」语义由系统 `LoadingProgress`
   *      承载（见 `components/LoadingIndicator.ets` 的同一决定），
   *      自绘的无限动画在动效、省电与无障碍上都跟系统对不齐；
   *   2. 它**跟真实加载状态解耦**：只要有一个标志位没收，它就一直转
   *      （2026-09-19 真机：缓存分支下 `loading` 初值为 true，内容早已到位、
   *      条子却永远在跑）。
   *
   * 现在改成**只有真的在等网络时才出现**的系统加载圈：
   *   - 首屏 / 切标签：Banner 区已有的 `LoadingIndicator`（系统圈）负责；
   *   - 触底续拉：网格底部这一行（圈 + 「正在加载…」），
   *     位置就在新内容将要出现的地方，也是鸿蒙列表的常规做法。
   */
  @Builder
  loadingMoreFooter() {
    if (this.loadingMore) {
      Row({ space: 8 }) {
        LoadingIndicator({ sizeVp: 20 })
        Text('正在加载…')
          .fontSize(TS.bodySmallSize)
          .fontColor(AppColor.onSurfaceVariant)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 16, bottom: 4 })
      .accessibilityText('正在加载更多番剧')
    }
  }

  /**
   * 标签菜单（规格 §4.6）。
   *
   * 参照实现 `showTagMenu` 是 `CustomDropdownMenu`（宽 96、最大高 250）。
   *
   * ⚠️ **这里不能用 `Menu()` + `MenuItem`**（2026-09-17 踩了两轮）：
   *
   * 1. 直接用 `Menu()`：条目 1（全部）+ 15（题材）= 16 条 × 48vp = **768vp**，
   *    比一屏还高，系统的菜单放不下就从锚点**上方**弹出来；
   * 2. 给 `Menu()` 加 `.constraintSize({ maxHeight: 264 })` 把它压短：
   *    方向是对了，但**滚动区一起被压掉了**——后面的题材既看不到也滑不动
   *    （用户实测反馈「无法上下滑动」）。
   *
   * 所以改成**自己带滚动**：`bindMenu` 接受任意 `CustomBuilder`
   * （本工程 `SearchPage` 的排序菜单就是这么用的），菜单外壳与动效仍由系统给，
   * 内容换成 `Scroll` + 自绘行。高度由我们定，滚动由我们保证。
   */
  @Builder
  tagMenu() {
    Scroll() {
      Column() {
        this.tagMenuOption('', '全部')
        ForEach(defaultAnimeTags, (tag: string) => {
          this.tagMenuOption(tag, tag)
        }, (tag: string) => `tag-option-${tag}`)
      }
      .width('100%')
    }
    .width(TAG_MENU_WIDTH)
    // 5.5 项 ≈ 264vp：锚点（「全部」按钮）在首屏约 y=537vp，
    // 屏高 804vp，264 刚好放得下，菜单才会从下方展开。
    .constraintSize({ maxHeight: TAG_MENU_MAX_HEIGHT })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /**
   * 单个标签项：当前标签打勾。
   *
   * 尺寸对齐 HarmonyOS 菜单项（高 48 / 左右 16 / 文字 16），
   * 因为外壳是系统菜单，里面这一行必须自己画。
   */
  @Builder
  tagMenuOption(tag: string, label: string) {
    Row() {
      Text(label)
        .fontSize(16)
        .fontColor(AppColor.onSurface)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (tag === this.currentTag) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(18)
          .fontColor([AppColor.primary])
          .margin({ left: 8 })
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      this.selectTag(tag);
    })
  }
}
