import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { AppColor } from '../theme/AppColors';
import { LoadingIndicator } from '../components/LoadingIndicator';
import { HeroFlight, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { BangumiApi, BangumiSearchPage } from '../api/BangumiApi';
import { BangumiItem } from '../model/BangumiItem';
import { SearchFilterPanel } from '../components/SearchFilterPanel';
import { SearchHistoryEntry, SearchHistoryStore } from '../services/search/SearchHistoryStore';
import { CollectEntry, CollectStore } from '../services/collect/CollectStore';
import {
  filterSummary,
  readableQuery,
  searchSortLabel,
  searchSortOptions,
  SearchFilterState,
  SearchParser,
  SearchSortOption
} from '../utils/SearchParser';
import { PluginManager } from '../services/plugin/PluginManager';
import { PluginBatchUpdateResult, PluginUpdateService } from '../services/plugin/PluginUpdateService';
import { InfoRouteArgs, SearchRouteArgs } from '../router/RouteArgs';
import { HeroRects } from '../router/HeroRects';
import { CoverImage } from '../components/CoverImage';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnSearchPage';
/** 每页条数（`search_controller.dart` 的 `_searchPageSize`）。 */
const PAGE_SIZE: number = 20;
/** 单次搜索最多连拉页数（`_maxPagesPerSearch`）。 */
const MAX_PAGES_PER_SEARCH: number = 3;
/** 悬浮标题层高（不含状态栏）：与原标题栏同高，内容区据此让位。 */
const TITLE_LAYER_HEIGHT: number = 56;
/** 结果态多出来的那一行悬浮头（`搜索结果` + 排序 + 筛选）。 */
const RESULT_HEADER_HEIGHT: number = 48;
/** 收藏类型：4 = 看过，5 = 抛弃（`CollectEntry.collectType`）。 */
const COLLECT_TYPE_WATCHED: number = 4;
const COLLECT_TYPE_ABANDONED: number = 5;

/**
 * 番剧搜索页。对应规格 §8（`pages/search/search_page.dart`）。
 *
 * 外壳（§8.1）：标题「番剧搜索」、内容宽 `min(hasSearched ? 1120 : 760, maxWidth - 2*horizontal)`、
 * `horizontal = maxWidth >= 700 ? 32 : 20`，左右各留 `(maxWidth - width) / 2` 的居中内缩。
 *
 * 两种状态：
 *   - 未搜索（§8.2）：按条件查找 + 最近搜索（管理）
 *   - 已搜索（§8.4）：`搜索结果` + 排序菜单 + 筛选按钮 → 条数行 → 条件摘要 →
 *     海报网格 → 底部（加载更多 / 已经看到全部结果）
 *
 * **搜索对象只有番剧条目**（Bangumi `/v0/search/subjects`）：规则站点（插件）的检索
 * 发生在详情页的「播放来源」弹层里（`SourceSheet`），与参照实现的分工一致——
 * 搜索页只管番剧，插件只负责给某个条目供源。
 *
 * 不过规则表仍是后续链路的前提，所以探索态保留了「从规则商店安装规则」入口
 * （见 `PluginUpdateService.installMissingFromCatalog`）。
 */
@Component
export struct SearchPage {
  /** 搜索框内容（归一化后的查询串）。 */
  @State keyword: string = '';
  /** `_submittedQuery != null`。 */
  @State hasSearched: boolean = false;
  /** `_controller.isLoading`。 */
  @State searching: boolean = false;
  /** `_controller.isTimeOut`：搜完一条都没有。 */
  @State timedOut: boolean = false;
  /** 最近搜索（落盘，见 SearchHistoryStore）。 */
  @State recent: SearchHistoryEntry[] = [];
  /** 「管理」态：显示逐条删除与「清空」。 */
  @State managing: boolean = false;
  /** 筛选面板显隐。 */
  @State showFilters: boolean = false;
  /** 已生效的条件（打开面板时作为初值）。 */
  @State filterState: SearchFilterState = new SearchFilterState();
  /** 结果条目（`_controller.bangumiList`）。 */
  @State items: BangumiItem[] = [];
  /** 筛选面板里的两个开关：过滤掉「看过 / 抛弃」的条目。 */
  @State hideWatched: boolean = false;
  @State hideAbandoned: boolean = false;
  /** `hasMoreSearchResults`。 */
  @State hasMore: boolean = true;
  /** 排序菜单展开（`bindMenu` 挂在容器上，与 ThemeSettingsPage 同一做法）。 */
  @State sortMenuOpen: boolean = false;
  /** 打开面板时的草稿初值；非状态量，创建面板前赋值即可。 */
  private pendingInitial: SearchFilterState = new SearchFilterState();
  /** 本轮已提交的查询串（「加载更多」沿用它）。 */
  private submittedQuery: string = '';
  /** 已取走的条数（`_searchOffset`）。 */
  private searchOffset: number = 0;
  /** 搜索世代号：过期响应直接丢弃（`_searchGeneration`）。 */
  private searchGeneration: number = 0;
  /**
   * 推荐热词。
   *
   * 规格 §8.2 的「最近搜索」只在搜过之后才有内容，而模拟器上中文输入要过 IME，
   * 自动化验证没法敲中文——所以探索态再加一组固定热词，点一下就能提交，
   * 让「搜索 → 结果」在模拟器上可以纯点击跑通。
   */
  @State hotKeywords: string[] = ['葬送的芙莉莲', '无职转生', 'Re：从零开始的异世界生活'];
  @State ruleCount: number = 0;
  @State installState: string = '';
  @StorageProp('topInset') topInset: number = 39;

  aboutToAppear(): void {
    this.ruleCount = PluginManager.pluginList.length;
    this.recent = SearchHistoryStore.getAll();
    // 详情页的标签卡带着关键词进来（`SearchRouteArgs`）。
    const pendingTag: string = SearchRouteArgs.pendingTag;
    SearchRouteArgs.pendingTag = '';
    const pendingKeyword: string = SearchRouteArgs.pendingKeyword;
    SearchRouteArgs.pendingKeyword = '';
    if (pendingTag.length > 0) {
      this.searchTag(pendingTag);
    } else if (pendingKeyword.length > 0) {
      this.keyword = pendingKeyword;
      this.submit(pendingKeyword);
    }
  }

  /** 二级页转场（规格 §12.4）：淡入 + 屏高 2% 上移，进入 easeOutCubic / 退出 easeInCubic。 */
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

  private async installRules(): Promise<void> {
    this.installState = '正在拉取规则目录…';
    try {
      const result: PluginBatchUpdateResult =
        await PluginUpdateService.installMissingFromCatalog(0);
      this.ruleCount = PluginManager.pluginList.length;
      this.installState = `已装 ${this.ruleCount} 条（候选 ${result.candidates}，`
        + `成功 ${result.updated}，需更高版本 ${result.requiresNewerClient}，失败 ${result.failed}）`;
      hilog.info(DOMAIN, TAG, '规则安装: candidates=%{public}d updated=%{public}d failed=%{public}d',
        result.candidates, result.updated, result.failed);
    } catch (e) {
      const err = e as Error;
      this.installState = `安装失败：${err.message}`;
    }
  }

  // ============================================================
  // 检索（对应 `search_controller.dart` 的 `searchBangumi`）
  // ============================================================

  /**
   * 提交一次搜索（参照实现 `_submit`）。
   *
   * 与参照实现一致：先把输入当查询串解析（`SearchParser`），再按 `fromFilterState`
   * 归一化（去掉重复 token、统一顺序），归一化后的整串既写进搜索框，也落进最近搜索。
   */
  private async submit(raw: string): Promise<void> {
    const parsed: SearchFilterState = SearchParser.toFilterState(raw);
    const query: string = SearchParser.fromFilterState(parsed);
    if (query.length === 0) {
      return;
    }
    this.keyword = query;
    await this.runSearch(query, true);
  }

  /** 详情页标签入口：直接构造 tags 条件，避免把标签名当作普通文字检索。 */
  private async searchTag(tagName: string): Promise<void> {
    const state: SearchFilterState = new SearchFilterState();
    state.tags = [tagName];
    const query: string = SearchParser.fromFilterState(state);
    this.keyword = query;
    await this.runSearch(query, true, state);
  }

  /**
   * 跑一次检索。`isInit` 为假时是「加载更多」（`searchBangumi(type:'add')`）：
   * 沿用上一次的查询串与偏移，只在还有下一页且不在请求中时才真的发请求。
   */
  private async runSearch(query: string, isInit: boolean,
    initialState: SearchFilterState | null = null): Promise<void> {
    if (!isInit && (this.searching || !this.hasMore)) {
      return;
    }
    const generation: number = isInit ? ++this.searchGeneration : this.searchGeneration;
    this.searching = true;
    this.timedOut = false;
    if (isInit) {
      this.submittedQuery = query;
      this.hasSearched = true;
      this.items = [];
      this.searchOffset = 0;
      this.hasMore = true;
      this.filterState = initialState === null
        ? SearchParser.toFilterState(query) : initialState;
      // 只记「有内容的查询」：空串 / 纯默认条件不进历史
      if (query.trim().length > 0) {
        SearchHistoryStore.save(query);
        this.recent = SearchHistoryStore.getAll();
      }
    }
    const state: SearchFilterState = initialState === null
      ? SearchParser.toFilterState(query) : initialState;
    if (generation !== this.searchGeneration) {
      return;
    }
    let idValue: number = 0;
    if (state.id.length > 0) {
      idValue = Number.parseInt(state.id, 10);
    }
    if (idValue > 0) {
      // `id:` 检索：单条结果、没有分页（`search_controller.dart:98-107`）
      const one: BangumiItem | null = await BangumiApi.getBangumiInfoByID(idValue);
      if (generation !== this.searchGeneration) {
        return;
      }
      const single: BangumiItem[] = [];
      if (one !== null) {
        single.push(one);
      }
      this.items = single;
      this.hasMore = false;
      this.searching = false;
      this.timedOut = single.length === 0;
      hilog.info(DOMAIN, TAG, 'id 检索 #%{public}d → %{public}d 条', idValue, single.length);
      return;
    }
    let list: BangumiItem[] = this.items.slice();
    let pagesFetched: number = 0;
    do {
      const page: BangumiSearchPage | null = await BangumiApi.bangumiSearchFiltered(
        state.keyword, state, PAGE_SIZE, this.searchOffset);
      // 过期响应直接丢弃，否则会把上一轮的结果写进这一轮
      if (generation !== this.searchGeneration) {
        return;
      }
      if (page === null) {
        break;
      }
      pagesFetched++;
      this.searchOffset += page.rawCount;
      this.hasMore = page.rawCount === PAGE_SIZE;
      const fresh: BangumiItem[] = [];
      for (let i = 0; i < page.items.length; i++) {
        const candidate: BangumiItem = page.items[i];
        let seen: boolean = false;
        for (let j = 0; j < list.length; j++) {
          if (list[j].id === candidate.id) {
            seen = true;
            break;
          }
        }
        if (!seen) {
          list.push(candidate);
          fresh.push(candidate);
        }
      }
      if (fresh.length > 0) {
        break;
      }
    } while (this.hasMore && pagesFetched < MAX_PAGES_PER_SEARCH);
    this.items = list;
    this.searching = false;
    this.timedOut = list.length === 0 && (pagesFetched === 0 || !this.hasMore);
    hilog.info(DOMAIN, TAG, '番剧检索「%{public}s」→ %{public}d 条（还有更多：%{public}s）',
      query, list.length, this.hasMore ? '是' : '否');
  }

  /** 加载更多（滚到底或点「加载更多」）。 */
  private loadMore(): void {
    if (this.submittedQuery.length === 0) {
      return;
    }
    this.runSearch(this.submittedQuery, false, this.filterState);
  }

  /** 打开筛选面板：用当前搜索框内容解析出的条件作为初值。 */
  private openFilters(): void {
    const parsed: SearchFilterState = SearchParser.toFilterState(this.keyword);
    if (parsed.keyword.length === 0) {
      parsed.keyword = this.filterState.keyword;
    }
    this.pendingInitial = parsed;
    this.showFilters = true;
  }

  /** 应用筛选条件（面板的「查看结果」/ 空态的「重新搜索」都走这里）。 */
  private async applyFilters(state: SearchFilterState, hideWatched: boolean,
    hideAbandoned: boolean): Promise<void> {
    this.showFilters = false;
    this.hideWatched = hideWatched;
    this.hideAbandoned = hideAbandoned;
    const query: string = SearchParser.fromFilterState(state);
    this.keyword = query;
    await this.runSearch(query, true, state);
  }

  /** 排序菜单选择（`_applyFilters(submitted.copyWith(sort: sort))`）。 */
  private applySort(sort: string): void {
    const next: SearchFilterState = this.filterState.clone();
    next.sort = sort;
    this.applyFilters(next, this.hideWatched, this.hideAbandoned);
  }

  /** 清空搜索框 → 回到探索态（`_clearSearch`）。 */
  private clearSearch(): void {
    // 世代号自增：正在飞的那次请求回来时会被丢弃
    this.searchGeneration++;
    this.keyword = '';
    this.submittedQuery = '';
    this.hasSearched = false;
    this.managing = false;
    this.searching = false;
    this.timedOut = false;
    this.items = [];
    this.filterState = new SearchFilterState();
    this.hasMore = true;
    this.searchOffset = 0;
  }

  private clearRecent(): void {
    SearchHistoryStore.clear();
    this.recent = SearchHistoryStore.getAll();
    this.managing = false;
  }

  private removeRecent(entry: SearchHistoryEntry): void {
    SearchHistoryStore.remove(entry.timestamp);
    this.recent = SearchHistoryStore.getAll();
  }

  // ============================================================
  // 结果区的派生量（规格 §8.4）
  // ============================================================

  /** 按「收藏状态」过滤结果（`notShowWatchedBangumis / notShowAbandonedBangumis`）。 */
  private visibleItems(): BangumiItem[] {
    if (!this.hideWatched && !this.hideAbandoned) {
      return this.items;
    }
    const hidden: number[] = [];
    if (this.hideWatched) {
      const watched: CollectEntry[] = CollectStore.listByType(COLLECT_TYPE_WATCHED);
      for (let i = 0; i < watched.length; i++) {
        hidden.push(watched[i].id);
      }
    }
    if (this.hideAbandoned) {
      const abandoned: CollectEntry[] = CollectStore.listByType(COLLECT_TYPE_ABANDONED);
      for (let i = 0; i < abandoned.length; i++) {
        hidden.push(abandoned[i].id);
      }
    }
    return this.items.filter((item: BangumiItem) => hidden.indexOf(item.id) < 0);
  }

  /** 条数行：`正在搜索…` / `N 部番剧` / `N 部番剧 · 隐藏 M 部`。 */
  private countLine(): string {
    if (this.searching) {
      return '正在搜索…';
    }
    const total: number = this.items.length;
    const visible: number = this.visibleItems().length;
    if (visible < total) {
      return `${visible} 部番剧 · 隐藏 ${total - visible} 部`;
    }
    return `${total} 部番剧`;
  }

  /** 条件摘要（`_filterSummary`）。 */
  private summaryText(): string {
    return filterSummary(this.filterState);
  }

  /** 筛选按钮上的小圆点（`submitted.hasAdvancedFilters || notShowWatched || notShowAbandoned`）。 */
  private filterBadgeVisible(): boolean {
    return this.filterState.hasAdvancedFilters() || this.hideWatched || this.hideAbandoned;
  }

  /** 列数：`max(2, floor(width / 180))`。 */
  private columnCount(): number {
    const columns: number = Math.floor(this.contentWidthVp() / 180);
    return columns < 2 ? 2 : columns;
  }

  /** 卡片宽：`(width - (columns - 1) * 12) / columns`。 */
  private cardWidth(): number {
    const columns: number = this.columnCount();
    return (this.contentWidthVp() - (columns - 1) * 12) / columns;
  }

  private columnsTemplate(): string {
    const parts: string[] = [];
    const columns: number = this.columnCount();
    for (let i = 0; i < columns; i++) {
      parts.push('1fr');
    }
    return parts.join(' ');
  }

  /** 单格高：`cardWidth / 0.7 + scale(40) + scale(18) + 20`（默认缩放下即 40 / 18）。 */
  private cellExtent(): number {
    return this.cardWidth() / 0.7 + 40 + 18 + 20;
  }

  /**
   * 网格总高。
   *
   * ArkUI 的 Grid 放在 Scroll 里高度不受约束，必须显式给总高，
   * 否则只会排第一行（阶段 3 已踩过一次）。
   */
  private gridHeight(): number {
    const rows: number = Math.ceil(this.visibleItems().length / this.columnCount());
    if (rows === 0) {
      return 0;
    }
    return rows * this.cellExtent() + (rows - 1) * 20;
  }

  /**
   * 内容宽度（规格 §8.1）：
   *   horizontal = maxWidth >= 700 ? 32 : 20
   *   width      = min(hasSearched ? 1120 : 760, maxWidth - horizontal*2)
   */
  private contentWidthVp(): number {
    try {
      const info = display.getDefaultDisplaySync();
      const maxWidth: number = info.width / info.densityPixels;
      const horizontal: number = maxWidth >= 700 ? 32 : 20;
      return Math.min(this.hasSearched ? 1120 : 760, maxWidth - horizontal * 2);
    } catch (e) {
      return 360;
    }
  }

  // ============================================================
  // 搜索框与探索态（§8.2 / §8.3）
  // ============================================================

  @Builder
  searchField() {
    Row() {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(18)
        .fontColor([AppColor.onSurfaceVariant])
        .margin({ right: 6 })
        .onClick(() => {
          this.submit(this.keyword);
        })
      TextInput({ text: this.keyword, placeholder: '搜索番剧名称' })
        .onChange((value: string) => {
          this.keyword = value;
        })
        .onSubmit(() => {
          this.submit(this.keyword);
        })
        .layoutWeight(1)
        .fontSize(15)
        .backgroundColor(Color.Transparent)
      // 「输入框非空 **或** 已搜索」时出现清空按钮（参照实现的 trailing 判据）
      if (this.keyword.length > 0 || this.hasSearched) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(16)
          .fontColor([AppColor.onSurfaceVariant])
          .padding(8)
          .onClick(() => {
            this.clearSearch();
          })
      }
    }
    .width('100%')
    /**
     * 2026-09-19：64 → **52**（用户「我的想法是把搜索条弄细一点」），
     * 圆角同步收窄到 26 —— 正好是 52 的一半，全圆胶囊，与底部导航、
     * 设置页的胶囊滑杆是同一种形状语言。
     */
    .height(52)
    .padding({ left: 14, right: 8 })
    .backgroundColor(AppColor.surfaceContainerHighest)
    .borderRadius(26)
    .border({ width: 1, color: AppColor.outlineVariant })
  }

  @Builder
  discovery() {
    Column() {
      // 按条件查找（§8.2）
      Row() {
        Column() {
          Text('按条件查找').fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(AppColor.onSurface)
          Text('题材、放送时间与评分').fontSize(12)
            .fontColor(AppColor.onSurfaceVariant).margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('›').fontSize(20).fontColor(AppColor.onSurfaceVariant)
      }
      .width('100%')
      .padding(16)
      .backgroundColor(AppColor.primaryContainer)
      .borderRadius(18)
      .onClick(() => {
        this.openFilters();
      })

      // 规则表：详情页「播放来源」的前提
      Column() {
        Row() {
          Column() {
            Text('规则表').fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor(AppColor.onSurface)
            Text(this.ruleCount === 0
              ? '还没有规则，详情页的播放来源不会有结果'
              : `已安装 ${this.ruleCount} 条规则`).fontSize(12)
              .fontColor(AppColor.onSurfaceVariant).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Button(this.ruleCount === 0 ? '安装规则' : '补齐规则')
            .fontSize(13).height(34)
            .onClick(() => {
              this.installRules();
            })
        }
        .width('100%')
        if (this.installState.length > 0) {
          Text(this.installState).fontSize(11).width('100%').margin({ top: 6 })
            .fontColor(AppColor.onSurfaceVariant)
        }
      }
      .width('100%')
      .padding(16)
      .margin({ top: 12 })
      .backgroundColor(AppColor.surfaceContainerHighest)
      .borderRadius(18)

      // 推荐热词（点一下即提交）
      Row() {
        Text('推荐热词').fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(AppColor.onSurface).layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 20, bottom: 8 })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.hotKeywords, (item: string) => {
          Text(item).fontSize(13).fontColor(AppColor.onSurface)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .margin({ right: 8, bottom: 8 })
            .backgroundColor(AppColor.surfaceContainerHighest)
            .borderRadius(16)
            .onClick(() => {
              this.submit(item);
            })
        }, (item: string) => `hot-${item}`)
      }
      .width('100%')

      // 最近搜索（§8.2）：卡片 + 逐行条目，管理态可单删 / 清空
      if (this.recent.length > 0) {
        Column() {
          Row() {
            Text('最近搜索').fontSize(14)
              .fontColor(AppColor.onSurfaceVariant)
              .layoutWeight(1)
            if (this.managing) {
              Text('清空').fontSize(13).fontColor(AppColor.primary)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .onClick(() => {
                  this.clearRecent();
                })
            }
            Text(this.managing ? '完成' : '管理')
              .fontSize(13).fontColor(AppColor.primary)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .onClick(() => {
                this.managing = !this.managing;
              })
          }
          .width('100%')
          .padding({ left: 16, right: 8, top: 10 })

          ForEach(this.recent, (entry: SearchHistoryEntry, index: number) => {
            Column() {
              Row() {
                SymbolGlyph($r('sys.symbol.clock_arrow_2_circlepath'))
                  .fontSize(18)
                  .fontColor([AppColor.onSurfaceVariant])
                Text(readableQuery(entry.keyword))
                  .fontSize(14)
                  .fontColor(AppColor.onSurface)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                  .margin({ left: 12 })
                if (this.managing) {
                  Text('✕').fontSize(14)
                    .fontColor(AppColor.onSurfaceVariant)
                    .padding(8)
                    .onClick(() => {
                      this.removeRecent(entry);
                    })
                } else {
                  SymbolGlyph($r('sys.symbol.arrow_up_left'))
                    .fontSize(16)
                    .fontColor([AppColor.onSurfaceVariant])
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => {
                if (!this.managing) {
                  this.submit(entry.keyword);
                }
              })
              if (index < this.recent.length - 1) {
                Divider().color(AppColor.outlineVariant)
                  .margin({ left: 16, right: 16 })
              }
            }
            .width('100%')
          }, (entry: SearchHistoryEntry) => `recent-${entry.timestamp}`)
        }
        .width('100%')
        .margin({ top: 28 })
        .borderRadius(24)
        .clip(true)
        .linearGradient({
          angle: 135,
          colors: [[AppColor.glassCardHighlight, 0.0], [AppColor.glassCardBase, 1.0]]
        })
        .border({ width: 1, color: AppColor.glassBorder })
      }
    }
    .width('100%')
  }

  // ============================================================
  // 结果态（§8.4）
  // ============================================================

  /**
   * 头部行：`搜索结果` + 排序胶囊 + 筛选胶囊。
   *
   * 2026-09-19 用户：「搜索的结果页，热度包括旁边的筛选都做成胶囊形式」。
   *
   * 两个控件都按 M3 **Assist chip** 规格（与播放页「线路胶囊」、时间表的胶囊
   * 同一套）：高 32、圆角 16、`surfaceContainerHighest` 底 + `outlineVariant`
   * 细描边。原来是「裸文字 + 裸图标」悬在结果列表上方，像两个散件；
   * 做成胶囊之后和下面的结果卡片是同一套圆角语言。
   * 筛选多一个「筛选」文字（只看一个图标时，胶囊里空落落的），
   * 有生效条件时仍带主色小圆点。
   */
  @Builder
  resultHeader() {
    Row({ space: 8 }) {
      Text('搜索结果')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.onSurface)
        .layoutWeight(1)

      // 排序（当前项就是「热度」等）：`id:` 检索时不显示
      if (!this.filterState.isIdSearch()) {
        Row({ space: 4 }) {
          Text(searchSortLabel(this.filterState.sort))
            .fontSize(13)
            .fontColor(AppColor.onSurfaceVariant)
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(16)
            .fontColor([AppColor.onSurfaceVariant])
        }
        .height(32)
        .padding({ left: 12, right: 10 })
        .borderRadius(16)
        .backgroundColor(AppColor.surfaceContainerHighest)
        .border({ width: 1, color: AppColor.outlineVariant })
        .onClick(() => {
          this.sortMenuOpen = true;
        })
        .bindMenu(this.sortMenuOpen, this.sortMenu, {
          onDisappear: () => {
            this.sortMenuOpen = false;
          }
        })
      }

      // 筛选胶囊（图标 + 文字 + 生效时的小圆点）
      Row({ space: 4 }) {
        // 小圆点贴在**图标**右上角（就是参照实现 `Badge` 的位置），
        // 放到整个胶囊的角上会压在圆角描边上。
        Stack({ alignContent: Alignment.TopEnd }) {
          // §46.4：参照实现的 `tune_rounded` / `filter_alt_*` 映射到 `slider_horizontal_2`
          SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
            .fontSize(16)
            .fontColor([AppColor.onSurfaceVariant])
          if (this.filterBadgeVisible()) {
            Column()
              .width(6)
              .height(6)
              .borderRadius(3)
              .backgroundColor(AppColor.primary)
          }
        }
        Text('筛选')
          .fontSize(13)
          .fontColor(AppColor.onSurfaceVariant)
      }
      .height(32)
      .padding({ left: 12, right: 12 })
      .borderRadius(16)
      .backgroundColor(AppColor.surfaceContainerHighest)
      .border({ width: 1, color: AppColor.outlineVariant })
      .onClick(() => {
        this.openFilters();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 排序菜单内容（`_SearchSortMenu`：4 项，选中项打勾、主色）。 */
  @Builder
  sortMenu() {
    Column() {
      ForEach(searchSortOptions, (option: SearchSortOption) => {
        Row() {
          SymbolGlyph($r(this.filterState.sort === option.key
            ? 'sys.symbol.checkmark' : 'sys.symbol.circle'))
            .fontSize(18)
            .fontColor([this.filterState.sort === option.key
              ? AppColor.primary : AppColor.onSurfaceVariant])
            .margin({ right: 8 })
          Text(`按${option.label}排序`)
            .fontSize(15)
            .fontColor(this.filterState.sort === option.key
              ? AppColor.primary : AppColor.onSurface)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .onClick(() => {
          this.sortMenuOpen = false;
          this.applySort(option.key);
        })
      }, (option: SearchSortOption) => `sort-${option.key}`)
    }
    .width(200)
    .padding({ top: 8, bottom: 8 })
    /**
     * 白色底（2026-09-19 用户：「热度的弹窗……颜色也做成白色」）。
     *
     * 「热度」就是排序按钮上显示的当前项（`searchSortLabel` 默认值），
     * 点它弹出的就是这个菜单。底色用 `sys.color.comp_background_primary`——
     * 弹幕设置弹层 / `CharacterSheet` 用的同一个「系统默认白」，跟着系统深浅色走。
     */
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(16)
  }

  /** 加载态（`_SearchLoadingState`）：圈 40 + 「正在搜索番剧」。 */
  @Builder
  loadingState() {
    Column() {
      LoadingIndicator({ sizeVp: 40 })
      Text('正在搜索番剧')
        .fontSize(16)
        .fontColor(AppColor.onSurface)
        .textAlign(TextAlign.Center)
        .margin({ top: 20 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 48, bottom: 48 })
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 空态（`GeneralEmptyState`）：
   *   - 一条都没有 → 「没有找到番剧」+ 重新搜索 / 调整筛选
   *   - 全被收藏状态筛掉 → 「这些番剧被筛选隐藏了」+ 显示全部 / 调整筛选
   */
  @Builder
  emptyState() {
    Column() {
      SymbolGlyph($r(this.items.length === 0
        ? 'sys.symbol.magnifyingglass'
        : 'sys.symbol.slider_horizontal_2'))
        .fontSize(36)
        .fontColor([AppColor.onSurfaceVariant])
      Text(this.items.length === 0 ? '没有找到番剧' : '这些番剧被筛选隐藏了')
        .fontSize(16)
        .fontColor(AppColor.onSurface)
        .margin({ top: 12 })
      Row({ space: 8 }) {
        if (this.items.length === 0) {
          Button('重新搜索')
            .fontSize(13)
            .height(36)
            .backgroundColor(AppColor.primaryContainer)
            .fontColor(AppColor.onPrimaryContainer)
            .onClick(() => {
              this.submit(this.submittedQuery);
            })
        } else {
          Button('显示全部')
            .fontSize(13)
            .height(36)
            .backgroundColor(AppColor.primaryContainer)
            .fontColor(AppColor.onPrimaryContainer)
            .onClick(() => {
              this.hideWatched = false;
              this.hideAbandoned = false;
            })
        }
        Button('调整筛选')
          .fontSize(13)
          .height(36)
          .backgroundColor(Color.Transparent)
          .fontColor(AppColor.primary)
          .onClick(() => {
            this.openFilters();
          })
      }
      .margin({ top: 14 })

    }
    .width('100%')
    .padding({ top: 32, bottom: 32 })
    .justifyContent(FlexAlign.Center)
  }

  /** 底部：加载中 / 加载更多 / 已经看到全部结果。 */
  @Builder
  footer() {
    Row() {
      if (this.searching) {
        if (this.items.length > 0) {
          LoadingIndicator({ sizeVp: 32 })
        }
      } else if (this.hasMore) {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(18)
            .fontColor([AppColor.primary])
            .margin({ right: 6 })
          Text('加载更多').fontSize(14).fontColor(AppColor.primary)
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .onClick(() => {
          this.loadMore();
        })
      } else {
        Text('已经看到全部结果')
          .fontSize(12)
          .fontColor(AppColor.onSurfaceVariant)
      }
    }
    .width('100%')
    .height(72)
    .justifyContent(FlexAlign.Center)
  }

  /** 结果卡片（`_SearchResultCard`）。 */
  @Builder
  resultCard(item: BangumiItem) {
    Column() {
      // ⚠️ 封面地址的档位别在这里改：共享元素（Hero）两端必须是**同一个 URL**，
      // 详情页海报用的是 `coverUrl()`，所以卡片也只能用它。
      // 2026-09-20 试过让卡片走 `/r/400/` 缩略档省流量，结果飞行途中目标端
      // 是另一个 URL、缓存里没有 → 动画里是一张没加载好的图，已回退。
      CoverImage({
        src: item.coverUrl().length > 0 ? item.coverUrl() : $r('app.media.icon'),
        fit: ImageFit.Cover,
        radius: 16
      })
        .width('100%')
        .aspectRatio(0.7)
        .backgroundColor(AppColor.surfaceContainerHighest)
        .borderRadius(16)
        .clip(true)
        // Hero 共享元素（§38.7）：结果卡海报 → 详情页海报。
        // 跨页共享元素要用 `sharedTransition`（仅 router 跳转生效）
        .geometryTransition(HeroFlight.tag('search', item.id))
          .onAreaChange((oldValue: Area, newValue: Area) => {
            HeroRects.setCard(HeroFlight.tag('search', item.id), newValue);
          })
          .zIndex(1)
      Text(item.nameCn.length > 0 ? item.nameCn : item.name)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .lineHeight(20)
        .fontColor(AppColor.onSurface)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .height(40)
        .width('100%')
        .margin({ top: 10 })
      Row() {
        if (item.ratingScore > 0) {
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(14)
            .fontColor([AppColor.primary])
          Text(item.ratingScore.toFixed(1))
            .fontSize(12)
            .fontColor(AppColor.onSurface)
            .margin({ left: 3 })
          Text('').width(10)
        }
        Text(item.airDate.length >= 4 ? item.airDate.substring(0, 4) : '')
          .fontSize(12)
          .fontColor(AppColor.onSurfaceVariant)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .height(18)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      // 与参照实现一致：点卡片进**详情页**（播放来源在详情页里）
      InfoRouteArgs.open(item, 'search-subject', HeroFlight.tag('search', item.id));
    })
  }

  @Builder
  results() {
    Column() {
      Text(this.countLine())
        .fontSize(12)
        .fontColor(AppColor.onSurfaceVariant)
        .width('100%')
        .margin({ top: 4 })

      if (this.summaryText().length > 0) {
        Text(this.summaryText())
          .fontSize(12)
          .fontColor(AppColor.onSurfaceVariant)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 6 })
      }

      if (this.searching && this.items.length === 0) {
        this.loadingState()
      } else if (this.visibleItems().length === 0) {
        this.emptyState()
      } else {
        Grid() {
          ForEach(this.visibleItems(), (item: BangumiItem) => {
            GridItem() {
              this.resultCard(item)
            }
          }, (item: BangumiItem) => `subject-${item.id}`)
        }
        .columnsTemplate(this.columnsTemplate())
        .columnsGap(12)
        .rowsGap(20)
        .height(this.gridHeight())
        .width('100%')
        .margin({ top: 12 })
      }

      // 底部：有结果、或不是「一条都没搜到」时才渲染（参照实现同一条件）
      if (this.items.length > 0 || !this.timedOut) {
        this.footer()
      }
    }
    .width('100%')
  }

  /**
   * 悬浮头部总高（含状态栏）。
   *
   * 内容区（Scroll 里的那个 Row）据此留出上边距，搜索框与海报才能滚到标题
   * **下面**去；结果态多一行「搜索结果 + 排序 + 筛选」，所以这里跟着
   * `hasSearched` 变。
   */
  private headerBlockHeight(): number {
    return this.topInset + TITLE_LAYER_HEIGHT +
      (this.hasSearched ? RESULT_HEADER_HEIGHT : 0);
  }

  /**
   * 悬浮头部（2026-09-19，用户：「番剧搜索一样做成沉浸式的（悬浮标题）」
   * 「搜索的结果栏也是做成沉浸式的（悬浮标题）」）。
   *
   * 两层，与 `CollectPage.floatingTitle` / `TimetablePage` 同一套做法：
   *   1. 渐隐遮罩：`surface` 94% → 0，垫在文字后面——搜索框、海报滚到标题之下时
   *      文字仍然看得清；`HitTestMode.None`，不吃手势；
   *   2. 内容：状态栏占位 + 标题行，结果态再叠一行「搜索结果 + 排序 + 筛选」。
   *
   * ⚠️ 让位的内边距必须加在 **Scroll 里的那个 Row 上**，不能加在 Scroll 上：
   * 加在 Scroll 上会连内容一起裁掉，滚动的卡片到不了标题下面——这是「沉浸」
   * 成败的关键（`TimetablePage` 也是把 padding 加在 Scroll 的内层容器上）。
   */
  @Builder
  floatingHeader() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height(this.headerBlockHeight() + 16)
        .linearGradient({
          angle: 180,
          colors: [
            [AppColor.withAlpha(AppColor.surface, 0.94), 0.0],
            [AppColor.withAlpha(AppColor.surface, 0.0), 1.0]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      Column() {
        Column()
          .width('100%')
          .height(this.topInset)
        this.titleRow()
        if (this.hasSearched) {
          Row() {
            Column() {
              this.resultHeader()
            }
            .width(this.contentWidthVp())
          }
          .width('100%')
          .height(RESULT_HEADER_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
  }

  /** 标题行：返回 + 「番剧搜索」。 */
  @Builder
  titleRow() {
    Row() {
      SymbolGlyph($r('sys.symbol.arrow_left'))
        .fontSize(22)
        .fontColor([AppColor.onSurface])
        .padding({ left: 12, right: 12 })
        .onClick(() => {
          RouteTable.back();
        })
      Text('番剧搜索').fontSize(18).fontWeight(FontWeight.Medium)
        .fontColor(AppColor.onSurface).layoutWeight(1)
      Text('').width(48)
    }
    .width('100%')
    .height(TITLE_LAYER_HEIGHT)
  }

  build() {
    /**
     * `alignContent` 从 `Bottom` 改成 `TopStart`：悬浮标题是「按自身高度贴在顶部」
     * 的一层，`Bottom` 会把它贴到屏幕底部去。
     */
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // ---- 内容：按规格夹紧宽度并居中；头部不再占流内空间，内容从标题后穿过 ----
        Scroll() {
          Row() {
            Column() {
              this.searchField()
              Column() {
                if (this.hasSearched) {
                  this.results()
                } else {
                  this.discovery()
                }
              }
              .width('100%')
              .margin({ top: 12 })
            }
            .width(this.contentWidthVp())
            .padding({ bottom: 24 })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Top)
          // 悬浮头部让位（加在这里而不是 Scroll 上，见 `floatingHeader` 的注释）
          .padding({ top: this.headerBlockHeight() })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        // 参照实现是「距底 <= 360vp 触发」；ArkUI 侧用触底事件（阈值 360 只是提前量，
        // 底部还留了「加载更多」按钮兜底，行为一致）。
        .onReachEnd(() => {
          this.loadMore();
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppColor.surface)

      // ---- 悬浮标题（本页的沉浸式头部） ----
      this.floatingHeader()

      // ---- 筛选面板（模态：点遮罩或 ✕ 关闭） ----
      if (this.showFilters) {
        /**
         * 模态层单独套一个 **Bottom 对齐的 Stack**。
         *
         * 外层 Stack 为了悬浮标题已经改成 `TopStart`，筛选面板（底部大弹层）
         * 再直接挂在外层就会被贴到屏幕顶部去——所以这里自己带一层对齐。
         */
        Stack({ alignContent: Alignment.Bottom }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#99000000')
            .onClick(() => {
              this.showFilters = false;
            })
          SearchFilterPanel({
            initial: this.pendingInitial,
            initialHideWatched: this.hideWatched,
            initialHideAbandoned: this.hideAbandoned,
            onApply: (state: SearchFilterState, hideWatched: boolean,
              hideAbandoned: boolean) => {
              this.applyFilters(state, hideWatched, hideAbandoned);
            },
            onClose: () => {
              this.showFilters = false;
            }
          })
        }
        .width('100%')
        .height('100%')
      }

    }
    .width('100%')
    .height('100%')
  }
}
