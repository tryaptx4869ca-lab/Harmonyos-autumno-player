import { CollectType } from '../model/CollectType';
import { AppColor } from '../theme/AppColors';
import { TS } from '../theme/Typography';
import { Dimens, Motion, AppCurves, HeroFlight } from '../theme/Tokens';
import { AppMaterial } from '../theme/Material';
import { MotionRuntime } from '../theme/MotionRuntime';
import { BangumiImageUrlRewriter } from '../services/BangumiImageUrlRewriter';
import { CoverImage } from '../components/CoverImage';
import { CollectEntry, CollectStore } from '../services/collect/CollectStore';
import { Viewport } from '../utils/Viewport';
import { InfoRouteArgs } from '../router/RouteArgs';
import { HeroRects } from '../router/HeroRects';
import { BangumiItem } from '../model/BangumiItem';
import { RouteTable } from '../router/RouteTable';
import { HistoryEntry } from '../model/HistoryModels';
import { HistoryRepository } from '../services/HistoryRepository';
import { promptAction } from '@kit.ArkUI';

/**
 * 悬浮标题层高度（vp）：8 上留白 + 52（标题 27 + 副标题 16 + 间距）+ 8 下留白。
 *
 * 与历史记录页 `HistoryPage.topLayerHeight()` 同一套数值，也与 `titleRow()`
 * 的实际尺寸**必须同步改**——内容区顶部的占位就是按它算的。
 */
const TITLE_LAYER_HEIGHT: number = 68;
/**
 * 标题行的下缘（vp）：8 上留白 + 52 标题行。
 *
 * 内容层顶部的占位用**它**而不是 `TITLE_LAYER_HEIGHT`，搜索条才能紧贴在
 * 「追番 + 副标题」下面（用户 2026-09-19：「紧贴在标题的下方」）；
 * 两者差的那 8vp 是标题层给下面留的呼吸，放在搜索条下方更自然。
 */
const TITLE_ROW_BOTTOM: number = 60;
/** 搜索条与标题行之间的空隙（vp）——「紧贴」但不能贴死。 */
const SEARCH_TOP_GAP: number = 6;
/**
 * 搜索栏高度（vp）。
 *
 * 参照实现 `SearchBar` 是 `minHeight: 56`，那是**独立浮层**里的尺寸；
 * 现在它和卡片在同一层滚动，56 会显得又厚又长（用户 2026-09-18：
 * 「搜索栏太长了，缩短一下」），收到 44。
 */
const SEARCH_ROW_HEIGHT: number = 44;
/**
 * 分类胶囊条的高度（vp）：上面的间距 + 胶囊本身（`categoryChip` minHeight 48）。
 */
const CHIP_TOP_GAP: number = 10;
const CHIP_ROW_HEIGHT: number = 48;
/**
 * 悬浮头让位高度（vp）：标题行底 + 间距 + 搜索条 + 胶囊条。
 *
 * 标题、搜索条、分类胶囊**三层都钉在顶部**（用户 2026-09-19：「把筛选胶囊也
 * 加入到搜索条的那一层悬浮着，只有番剧列表铺满全页」）；分页内容里只剩番剧
 * 列表，从这一块下面开始。
 */
const HEADER_BLOCK_HEIGHT: number =
  TITLE_ROW_BOTTOM + SEARCH_TOP_GAP + SEARCH_ROW_HEIGHT +
    CHIP_TOP_GAP + CHIP_ROW_HEIGHT;

/**
 * 追番页。对应参照实现 lib/pages/collect/collect_library_view.dart。
 *
 * 关键交互（源码核对，静态截图看不到）：
 *   1. 分类共 6 个：全部 / 在看 / 想看 / 搁置 / 看过 / 抛弃。
 *      筛选条横向可滚动，屏幕内只可见约 3 个，左右滑动露出其余。
 *   2. 两套切换方式并存：
 *        点胶囊 → jumpToPage（瞬时、无动画）
 *        横向滑动 → PageView 原生翻页动画
 *   3. 选中胶囊会自动滚入视野并居中：200ms easeOutCubic，alignment 0.5
 *   4. 胶囊：选中 primaryContainer / 圆角 20 / onPrimaryContainer，
 *      未选中 surfaceContainer / 圆角 12 / onSurfaceVariant；
 *      AnimatedContainer 250ms easeInOutCubicEmphasized；
 *      内边距 h16 v12；间距 8；最小高 48。
 *   5. 顶部渐变 primaryContainer 42% → tertiaryContainer 18% → 透明，
 *      stops 0 / 0.45 / 1。
 */
@Component
export struct CollectPage {
  @State selectedIndex: number = 0;
  /** 当前分类下的收藏（点胶囊时重算）。 */
  @State visible: CollectEntry[] = [];
  /**
   * 收藏数据版本号。
   *
   * 为什么要它：Swiper 里 6 个分类页是**常驻子树**，`listOf()` 直接读存储、
   * 不是 @State 读取，框架不会把「收藏数据变了」这条依赖注册到那些子树上——
   * 实测表现是「改了分类：胶囊计数会变、列表不变」。在 `listOf()` 里读一次
   * 这个版本号，就把依赖挂上了。
   */
  @State private revision: number = 0;
  @StorageProp('topInset') topInset: number = 39;
  /** 主题版本：由 Index 下发，@Prop 变化会让本组件整体重跑 build。 */
  @Prop themeRev: number = 0;
  /**
   * 历史版本号（`HistoryRepository` 每次落盘 +1）。
   *
   * 卡片上的「看到第 N 集」来自本地历史，看完一集回到这里必须跟着变，
   * 所以订阅同一个键（推荐页 / 历史页 / 我的页都是这套机制）。
   */
  @StorageProp('historyRevision') @Watch('onHistoryChanged') historyRevision: number = 0;
  /**
   * 收藏变更版本号（`CollectStore` 每次写盘 +1）。
   *
   * 这六个分类页显示的就是收藏表本身：在播放页把某部番改成「在看」再回到这里，
   * 分类计数与列表都要跟着动（同 `HistoryRepository` 那套订阅）。
   */
  @StorageProp('collectRevision') @Watch('onCollectChanged') collectRevision: number = 0;
  /** 滚动上报（导航条弹入弹出 + 末尾回弹判定），见 `NavScrollController`。 */
  onScrollOffset: (offset: number, maxOffset: number) => void = () => {
  };
  /**
   * 每个分类页的内容高度（vp）。
   *
   * 六个分类页是**常驻子树**，各自独立量高；只有当前页会上报，
   * 所以按 index 分开存，不能让相邻页把数值覆盖掉。
   */
  private pageContentHeight: number[] = [0, 0, 0, 0, 0, 0];
  /** Swiper 实测高度（vp）：分类页内容至少撑满它，避免短内容被垂直居中。 */
  @State private pagerHeight: number = 0;
  /** 实测可用宽度（横屏 / 平板上胶囊居中要按可用宽度算）。 */
  @State viewportWidth: number = 0;
  /**
   * 在悬浮标题上开始拖动时的内容偏移（vp）。
   *
   * `PanGesture` 给的 `offsetY` 是**从手势起点累计**的位移，所以每次拖动的
   * 基准要在 `onActionStart` 里取一次当前偏移，不能拿上一帧的位置当基准。
   */
  private titleDragBase: number = 0;
  /**
   * 搜索词（对应参照实现 `_query`）。
   *
   * 分词规则与源码一致：`trim().toLowerCase().split(/\s+/)`，**每个词都要命中**
   * 名称才留下（`CollectLibraryQuery._match` 的 `terms.every(names.contains)`）。
   */
  @State private query: string = '';
  /** 排序：0 最近变更 / 1 番剧名称 / 2 评分最高 / 3 开播时间（`CollectSort`）。 */
  @State private sortIndex: number = 0;
  @State private sortMenuOpen: boolean = false;
  /** 多选模式（长按卡片进入；交互对齐历史记录页的「编辑」模式）。 */
  @State private selecting: boolean = false;
  /** 多选中条目的番剧 id。 */
  @State private selectedIds: number[] = [];
  @State private statusMenuOpen: boolean = false;
  /**
   * 长按之后短暂屏蔽同一次触摸带出来的 `onClick`。
   *
   * ArkUI 里 `LongPressGesture` 与 `onClick` 挂在同一个节点上时，抬手那一下
   * 仍可能补一个 click：不挡的话「长按进入多选」会立刻被当成「点一下」，
   * 变成刚选中又取消。这个时间戳就是给这一下留的窗口。
   */
  private suppressClickUntil: number = 0;
  /**
   * 观看进度索引：番剧 id → 已看到第几集。
   *
   * 数据来自本地历史（`HistoryEntry.lastWatchEpisode`）。每次 `refresh()` 重建
   * 一次用 Map 缓存：三十张卡片各遍历一遍历史表是 O(卡片 × 历史)，滚动会掉帧。
   */
  private progressBySubject: Map<number, number> = new Map<number, number>();
  /** 排序下拉的四个名字（`CollectSort` 的 label）。 */
  private readonly sortLabels: string[] = ['最近变更', '番剧名称', '评分最高', '开播时间'];
  @StorageProp('bottomInset') bottomInset: number = 28;
  /**
   * 分类胶囊的横向滚动控制器（选中项自动居中）。
   *
   * 胶囊条只有**一条**、在悬浮层里（用户 2026-09-19：「把筛选胶囊也加入到
   * 搜索条的那一层悬浮着」），所以一个 `Scroller` 就够。
   */
  private chipScroller: Scroller = new Scroller();
  /**
   * 六个分类页各自的纵向滚动容器。
   *
   * ⚠️ `onDidScroll` 的第二个参数是 **`ScrollState`（0/1/2）**，不是 yOffset：
   * 直接把它当偏移上报，`NavScrollController` 的 delta 几乎恒为 0，
   * 底部导航条永远不会隐藏（推荐页是从 Scroller 读的，所以它正常）。
   */
  private pageScrollers: Scroller[] = [
    new Scroller(), new Scroller(), new Scroller(),
    new Scroller(), new Scroller(), new Scroller()
  ];
  /** PageView 控制器：点胶囊瞬时跳页，滑动交给原生翻页动画。 */
  private pager: SwiperController = new SwiperController();
  /** 每个胶囊在滚动内容里的 x 与宽度（onAreaChange 实测，单位 vp）。 */
  private chipX: number[] = [-1, -1, -1, -1, -1, -1];
  private chipWidth: number[] = [0, 0, 0, 0, 0, 0];
  private readonly types: CollectType[] = [
    new CollectType(-1, '全部', ''),
    new CollectType(1, '在看', 'play_circle_outline'),
    new CollectType(2, '想看', 'bookmark_border'),
    new CollectType(3, '搁置', 'pause_circle_outline'),
    new CollectType(4, '看过', 'task_alt'),
    new CollectType(5, '抛弃', 'delete_outline')
  ];

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.progressBySubject = CollectPage.buildProgressIndex();
    this.visible = CollectStore.listByType(this.types[this.selectedIndex].value);
    this.revision++;
  }

  /** 历史变了：重建进度索引 + 踢一次 revision 让列表重跑（见行 key 的注释）。 */
  private onHistoryChanged(): void {
    this.progressBySubject = CollectPage.buildProgressIndex();
    this.revision++;
  }

  /**
   * 收藏变了：踢一次 revision。
   *
   * 列表与分类计数都是**每次 build 现读** `CollectStore`（见 `listOf` /
   * `countOf`），所以不需要重建数据，只要把依赖注册的那颗计数推进一格。
   */
  private onCollectChanged(): void {
    this.revision++;
  }

  /** 本地历史的观看进度索引（同一部番取最大集数）。 */
  private static buildProgressIndex(): Map<number, number> {
    const map: Map<number, number> = new Map<number, number>();
    const entries: HistoryEntry[] = HistoryRepository.getAll();
    for (let i = 0; i < entries.length; i++) {
      const entry: HistoryEntry = entries[i];
      const id: number = entry.bangumiItem.id;
      const watched: number = entry.lastWatchEpisode;
      if (id <= 0 || watched <= 0) {
        continue;
      }
      const previous: number | undefined = map.get(id);
      if (previous === undefined || watched > previous) {
        map.set(id, watched);
      }
    }
    return map;
  }

  /**
   * 某个分类下的条目：**先按查询词过滤、再排序**。
   *
   * 对齐参照实现 `CollectLibraryQuery.results(type, sort)`：
   * 过滤与排序都在「取用」这一层做，存储里的顺序不动。
   */
  private listOf(index: number): CollectEntry[] {
    // 读一次 revision 注册依赖（见字段注释），再返回当前分类的数据
    const revision: number = this.revision;
    if (revision < 0) {
      return [];
    }
    const type: number = this.types[index].value;
    const terms: string[] = this.queryTerms();
    const out: CollectEntry[] = [];
    for (let i = 0; i < CollectStore.entries.length; i++) {
      const entry: CollectEntry = CollectStore.entries[i];
      if (type > 0 && entry.collectType !== type) {
        continue;
      }
      if (!CollectPage.matchesTerms(entry, terms)) {
        continue;
      }
      out.push(entry);
    }
    CollectPage.sortEntries(out, this.sortIndex);
    return out;
  }

  /** 查询词切分（对照 `_match` 的分词）。 */
  private queryTerms(): string[] {
    const trimmed: string = this.query.trim().toLowerCase();
    return trimmed.length === 0 ? [] : trimmed.split(/\s+/);
  }

  /** 名称命中全部查询词（本地只存了中文名与原名，源码还会查别名）。 */
  private static matchesTerms(entry: CollectEntry, terms: string[]): boolean {
    if (terms.length === 0) {
      return true;
    }
    const names: string = `${entry.nameCn}\n${entry.name}`.toLowerCase();
    for (let i = 0; i < terms.length; i++) {
      if (names.indexOf(terms[i]) < 0) {
        return false;
      }
    }
    return true;
  }

  /**
   * 排序（对照 `results()` 的比较器）：
   * 主键 → 最近变更倒序 → id 升序，后两级是稳定兜底。
   */
  private static sortEntries(list: CollectEntry[], sortIndex: number): void {
    list.sort((a: CollectEntry, b: CollectEntry) => {
      let primary: number = 0;
      if (sortIndex === 1) {
        const left: string = a.displayName().toLowerCase();
        const right: string = b.displayName().toLowerCase();
        primary = left < right ? -1 : (left > right ? 1 : 0);
      } else if (sortIndex === 2) {
        primary = b.score - a.score;
      } else if (sortIndex === 3) {
        primary = CollectPage.airSortKey(b) - CollectPage.airSortKey(a);
      } else {
        primary = b.updatedAt - a.updatedAt;
      }
      if (primary !== 0) {
        return primary;
      }
      const byTime: number = b.updatedAt - a.updatedAt;
      return byTime !== 0 ? byTime : a.id - b.id;
    });
  }

  /** 开播时间的数值形式（缺日期按 0，排到最后）。 */
  private static airTimeOf(entry: CollectEntry): number {
    if (entry.airDate.length < 8) {
      return 0;
    }
    const ms: number = Date.parse(entry.airDate);
    return Number.isNaN(ms) ? 0 : ms;
  }

  /**
   * 按「开播时间」排序时的退化处理。
   *
   * 自建番没有开播日期（`airDate` 恒为空），直接按 0 排会把它们全部沉到底，
   * 而那一档的语义是「最近开播的在前」。这里把自建番按 `updatedAt` 折算，
   * 和 Bangumi 条目混在同一条时间轴上：谁更新过谁靠前。
   */
  private static airSortKey(entry: CollectEntry): number {
    const air: number = CollectPage.airTimeOf(entry);
    return air > 0 ? air : entry.updatedAt;
  }

  // ---------------- 标题副文案 / 多选 ----------------

  /**
   * 标题下面那行小字（对标推荐页「晚上好」下面的副标题）：
   * 平时是「共 12 部 · 在看 3 部」，进多选模式后换成「已选 N 部」。
   */
  private subtitleText(): string {
    if (this.selecting) {
      return this.selectedIds.length > 0
        ? `已选 ${this.selectedIds.length} 部` : '点选要处理的番剧';
    }
    const total: number = this.countOfType(0);
    if (total === 0) {
      return '还没有收藏的番剧';
    }
    const watching: number = this.countOfType(1);
    return watching > 0
      ? `共 ${total} 部 · 在看 ${watching} 部` : `共 ${total} 部`;
  }

  /** 某分类的条目数（`type <= 0` = 全部）；读一次 revision 注册依赖。 */
  private countOfType(type: number): number {
    const revision: number = this.revision;
    if (revision < 0) {
      return 0;
    }
    let count: number = 0;
    for (let i = 0; i < CollectStore.entries.length; i++) {
      if (type <= 0 || CollectStore.entries[i].collectType === type) {
        count++;
      }
    }
    return count;
  }

  /**
   * 查询词在**所有分类**里的命中数。
   *
   * 空态文案靠它区分「全局都没搜到」和「搜到了但不在这个分类」
   * （对照 `_emptyState` 的 `matchCount > 0` 分支）。
   */
  private matchedTotal(): number {
    const terms: string[] = this.queryTerms();
    if (terms.length === 0) {
      return 0;
    }
    let count: number = 0;
    for (let i = 0; i < CollectStore.entries.length; i++) {
      if (CollectPage.matchesTerms(CollectStore.entries[i], terms)) {
        count++;
      }
    }
    return count;
  }

  /** 长按卡片 → 进入多选并选中它。 */
  private enterSelecting(id: number): void {
    if (this.selecting) {
      return;
    }
    this.selecting = true;
    this.selectedIds = [id];
    this.suppressClickUntil = Date.now() + 400;
  }

  private toggleSelected(id: number): void {
    const next: number[] = this.selectedIds.slice();
    const at: number = next.indexOf(id);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(id);
    }
    this.selectedIds = next;
  }

  private isSelected(id: number): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  private exitSelecting(): void {
    this.selecting = false;
    this.selectedIds = [];
    this.statusMenuOpen = false;
  }

  /** 全选当前分类（含搜索过滤）里的条目。 */
  private selectAll(): void {
    const list: CollectEntry[] = this.listOf(this.selectedIndex);
    const ids: number[] = [];
    for (let i = 0; i < list.length; i++) {
      ids.push(list[i].id);
    }
    this.selectedIds = ids;
  }

  /** 批量改分类（只写本地存储——Bangumi 收藏同步在本移植里没有落地）。 */
  private applyTypeToSelection(type: number): void {
    if (this.selectedIds.length === 0) {
      return;
    }
    const count: number = this.selectedIds.length;
    CollectStore.setTypes(this.selectedIds, type);
    this.exitSelecting();
    this.refresh();
    this.toast(`已把 ${count} 部改为「${this.typeLabel(type)}」`);
  }

  /** 批量取消收藏（破坏性操作，先确认一次）。 */
  private confirmRemoveSelection(): void {
    const count: number = this.selectedIds.length;
    if (count === 0) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '取消收藏？',
        message: `将从收藏列表移除选中的 ${count} 部番剧。`,
        buttons: [
          { text: '取消', color: AppColor.onSurfaceVariant },
          { text: '取消收藏', color: AppColor.error }
        ]
      })
        .then((result: promptAction.ShowDialogSuccessResponse) => {
          if (result.index === 1) {
            CollectStore.removeAll(this.selectedIds);
            this.exitSelecting();
            this.refresh();
            this.toast(`已取消收藏 ${count} 部`);
          }
        })
        .catch(() => {
          // 弹窗被系统拒绝（例如没有 UI 上下文）时不影响其它操作
        });
    } catch (e) {
      // 同上：拿不到 PromptAction 时静默跳过
    }
  }

  /** 多选时的「改状态」菜单（与单卡的收藏菜单同一套图标与文案）。 */
  @Builder
  batchStatusMenu() {
    Menu() {
      ForEach(CollectPage.statusOptions(), (value: number) => {
        MenuItem({
          content: this.typeLabel(value),
          startIcon: CollectPage.iconOf(value)
        }).onClick(() => {
          this.applyTypeToSelection(value);
        })
      }, (value: number) => `batch-status-${value}`)
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 提示失败不影响主流程（与时间表页 `showTip` 同一写法）
    }
  }

  /**
   * 按行切分（宽屏两列，手机一列）。
   *
   * 参照实现 `collect_library_view.dart:405-407`：
   * `columns = contentWidth >= 840 && textScale <= 1.3 ? 2 : 1`。
   * 文本缩放本工程没有单独的设置项，按 1.0 处理。
   */
  private rowsOf(index: number): CollectEntry[][] {
    const entries: CollectEntry[] = this.listOf(index);
    const columns: number = this.screenWidthVp() - Dimens.contentInset * 2 >= 840 ? 2 : 1;
    if (columns === 1) {
      return entries.map((entry: CollectEntry) => [entry]);
    }
    const rows: CollectEntry[][] = [];
    for (let i = 0; i < entries.length; i += 2) {
      const row: CollectEntry[] = [entries[i]];
      if (i + 1 < entries.length) {
        row.push(entries[i + 1]);
      }
      rows.push(row);
    }
    return rows;
  }

  private screenWidthVp(): number {
    return Viewport.widthVp(this.viewportWidth);
  }

  /** 大屏内容最大宽度（与推荐页 1120 / 时间表 1280 同一条思路）。 */
  private static readonly CONTENT_MAX_WIDTH: number = 1100;

  /**
   * 内容的左右内边距。
   *
   * 窄屏就是 `Dimens.contentInset`（16，保持原样）；大屏再加一层居中留白，
   * 把标题行、搜索栏、筛选胶囊、剧集列表一起收在 `CONTENT_MAX_WIDTH` 以内并
   * 居中——否则平板上「追番」标题贴最左、排序胶囊贴最右，中间隔着 1400vp 的
   * 空白（用户 2026-10-07：平板没适配好）。
   */
  private hInset(): number {
    const screen: number = this.screenWidthVp();
    const base: number = Dimens.contentInset;
    const cap: number = CollectPage.CONTENT_MAX_WIDTH;
    return screen > cap + base * 2 ? (screen - cap) / 2 : base;
  }

  /**
   * 选中胶囊自动滚入视野并居中。
   *
   * 对应参照实现 `_categoryStrip` 里的 `ensureVisible(alignment: 0.5,
   * duration: 200ms, curve: easeOutCubic)`——把目标胶囊的中心对齐到
   * 视口中心（两侧各自被裁掉，因此要夹到可滚动范围内）。
   */
  private centerChip(index: number): void {
    const x: number = this.chipX[index];
    const width: number = this.chipWidth[index];
    if (x < 0 || width <= 0) {
      return;
    }
    const viewport: number = this.screenWidthVp();
    const target: number = x - (viewport - width) / 2;
    try {
      this.chipScroller.scrollTo({
        xOffset: Math.max(0, target),
        yOffset: 0,
        animation: { duration: Motion.standard, curve: AppCurves.easeOutCubic() }
      });
    } catch (e) {
      // 那一页还没挂载时忽略
    }
  }

  /** 点胶囊：瞬时跳页（对应源码 `jumpToPage`），并让胶囊居中。 */
  private selectCategory(index: number): void {
    if (index !== this.selectedIndex) {
      this.pager.changeIndex(index, false);
      this.selectedIndex = index;
      this.refresh();
    }
    this.centerChip(index);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      /**
       * 层 1：内容（6 个分类页）**铺满整页**，包括状态栏那一条。
       *
       * 2026-09-18：这里原来是一整页 gradient（`primaryContainer` 42% →
       * `tertiaryContainer` 18% → `surface` 0），把 Index 那层 `AppBackground`
       * 整个盖住了——所以推荐页/时间表/追番三个 Tab 的底色各是一套，换主题、
       * 换壁纸时追番页永远不跟着走。用户要求「背景做成和推荐页一样的」，
       * 直接把这一层删掉：四个 Tab 从此共用同一个背景。
       *
       * 内容从 y=0 开始（不再给整页加 `topInset` 内边距），卡片往上滚时从
       * 悬浮标题**后面**穿过去，这才是「沉浸」；顶部让位的空间由内容层里那块
       * 占位（见 `page()`）负责，光靠 padding 会把内容裁在标题下缘。
       */
      this.pagerView()

      /** 层 2：只有标题是悬浮的（钉住）；搜索栏、筛选胶囊、番剧列表都在层 1。 */
      this.floatingHeader()

      /** 层 3：多选操作条（只在真的选中了东西时出现，浮在底部导航之上）。 */
      if (this.selecting && this.selectedIds.length > 0) {
        Column() {
          this.selectionBar()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        /**
         * `HitTestMode.None`：这一整层只是「把操作条摆到底部」，自身不吃触摸、
         * 子节点照常响应。不设的话这张全屏浮层会把所有卡片的点击都吞掉。
         */
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width: number = Number(newValue.width);
      if (width > 0 && Math.abs(width - this.viewportWidth) > 0.5) {
        this.viewportWidth = width;
      }
    })
  }

  /**
   * 悬浮标题层：一层柔和的顶部遮罩 + 标题行（标题 + 副标题 + 排序胶囊）。
   *
   * 标题规格取推荐页「晚上好」那一套（headlineSmall 20/27 + w700 +
   * letterSpacing 0.3 + onSurface）——用户 2026-09-18：「追番做成类似晚上好
   * 一样的悬浮标题」。同一套数值历史记录页也在用（那边为了和返回键配平用了
   * w800，差一档，视觉上几乎看不出）。
   *
   * 遮罩（surface 94% → 0）和标题一样是「垫在文字后面的底色」，不是控件，
   * 所以 `HitTestMode.None` 不吃手势——它是为了卡片滚到标题后面时文字还看得清。
   * 遮罩从 y=0 开始画：内容现在会从状态栏下方穿过去，不铺这一层的话状态栏
   * 图标会直接压在卡片上。
   */
  @Builder
  floatingHeader() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height(this.topInset + HEADER_BLOCK_HEIGHT + 16)
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
        // 搜索条紧贴在标题下方
        this.searchRow()
        /**
         * 分类胶囊也在这一层：标题 / 搜索条 / 胶囊三者一起钉住，左右翻页和
         * 上下滚动都不动（用户 2026-09-19：「把筛选胶囊也加入到搜索条的那一层
         * 悬浮着，只有番剧列表铺满全页」），页里只剩番剧列表。
         */
        this.categoryStrip()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      /**
       * 整个悬浮头（标题 + 搜索条 + 胶囊）都是浮层、不在分类页的 Scroll 里，
       * 所以在这一块上往上滑也要能滚列表（不然只有列表那一片能滚）。
       * 方向限定纵向、门槛 5vp：点排序胶囊、点分类胶囊仍然是点击
       * （没移动就不会触发挥手）。
       */
      .gesture(
        PanGesture({ direction: PanDirection.Vertical, distance: 5 })
          .onActionStart(() => {
            this.titleDragBase = this.pageOffsetOf(this.selectedIndex);
          })
          .onActionUpdate((event: GestureEvent) => {
            this.scrollPageTo(this.selectedIndex,
              this.titleDragBase - event.offsetY);
          })
      )
    }
    .width('100%')
  }

  /** 标题行：纯文字标题（+副标题）+ 右侧排序胶囊。 */
  @Builder
  titleRow() {
    Row() {
      Column() {
        Text('追番')
          .fontSize(TS.headlineSmallSize)
          .lineHeight(TS.headlineSmallLine)
          .fontWeight(TS.w700)
          .letterSpacing(0.3)
          .fontColor(AppColor.onSurface)
          .maxLines(1)
        /**
         * 副标题：与推荐页「晚上好」下面那句同一档尺寸（bodyMedium 14/21 + w400），
         * 颜色**跟标题一样是 `onSurface`（黑色）**——用户 2026-09-18 两次强调
         * 「追番和副标题变成像晚上好一样那种悬浮黑色文字」，不再用灰的
         * `onSurfaceVariant`。
         */
        Text(this.subtitleText())
          .fontSize(TS.bodyMediumSize)
          .lineHeight(TS.bodyMediumLine)
          .fontWeight(TS.w400)
          .letterSpacing(TS.ls)
          .fontColor(AppColor.onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.selecting) {
        // 多选模式：右侧让位给「完成」（对齐历史记录页的编辑态）
        this.headerTextCapsule('完成', () => {
          this.exitSelecting();
        })
      } else {
        this.sortCapsule()
      }
    }
    .width('100%')
    .height(52)
    .alignItems(VerticalAlign.Center)
    .padding({ left: this.hInset(), right: this.hInset() })
    .margin({ top: 8 })
  }

  /** 文字胶囊（完成；与历史记录页 `headerTextCapsule` 同一规格）。 */
  @Builder
  headerTextCapsule(label: string, action: () => void) {
    Text(label)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(AppColor.primary)
      .textAlign(TextAlign.Center)
      .constraintSize({ minWidth: 64 })
      .height(36)
      .padding({ left: 14, right: 14 })
      .borderRadius(18)
      .backgroundBlurStyle(AppMaterial.capsule, AppMaterial.options())
      .backgroundColor(AppColor.glassCapsuleFill)
      .border({ width: 1, color: AppColor.glassBorder })
      .onClick(() => {
        action();
      })
  }

  /**
   * 搜索栏：系统 `Search`。
   *
   * 它和分类胶囊、番剧列表**同属最下面那一个滚动层**（在 `page()` 里跟着内容
   * 一起滚），不再是自己浮在上面、按滚动量收起的第二层——
   * 用户 2026-09-18：「现在往上滑会莫名分裂，我希望搜索栏、筛选胶囊和下面番剧
   * 是最下面的图层」。那套 `translate` 收起（外层 clip + 内层位移）整个删掉了：
   * 分裂感就是「两块东西以不同速度各自移动」来的。
   *
   * 高度 56 → 44、左右按卡片同样的 16vp 内缩（原来顶到屏幕两边）：
   * 原来那个尺寸是照搬参照实现的独立浮层，放进内容层之后显得又厚又长。
   */
  @Builder
  searchRow() {
    // 内缩放在外层 `Row` 的 padding 上，不给 Search 自己加左右 margin：
    // `width('100%') + margin` 在 ArkUI 里会撑出父容器、把左边挤出屏幕。
    Row() {
      Search({ value: this.query, placeholder: '搜索收藏番剧的名称、别名' })
        .layoutWeight(1)
        .height(SEARCH_ROW_HEIGHT)
        .borderRadius(16)
        .backgroundColor(AppColor.surfaceContainerHigh)
        .placeholderColor(AppColor.onSurfaceVariant)
        .textFont({ size: TS.bodyMediumSize })
        .onChange((value: string) => {
          if (value !== this.query) {
            this.query = value;
            // 结果集变了就回到顶部（对照 `_resetResults`）
            this.scrollContentToTop();
          }
        })
        .onSubmit(() => {
          this.scrollContentToTop();
        })
    }
    .width('100%')
    .height(SEARCH_ROW_HEIGHT)
    .alignItems(VerticalAlign.Center)
    .padding({ left: this.hInset(), right: this.hInset() })
    .margin({ top: SEARCH_TOP_GAP })
  }

  /** 四个排序档位（对照 `CollectSort`，当前档位打勾）。 */
  @Builder
  sortMenu() {
    Menu() {
      ForEach(this.sortLabels, (label: string, index: number) => {
        MenuItem({
          content: label,
          endIcon: index === this.sortIndex
            ? $r('sys.symbol.checkmark') : undefined
        }).onClick(() => {
          if (index !== this.sortIndex) {
            this.sortIndex = index;
            // 顺序变了就回到顶部（对照 `_resetResults`）
            this.scrollContentToTop();
          }
        })
      }, (label: string) => `collect-sort-${label}`)
    }
  }

  /**
   * 分类胶囊条（第 `index` 个分类页里的那一条）。
   *
   * 现在它就在页面的滚动内容里，所以横向滑动归它自己、纵向滑动自然落到页面的
   * `Scroll`——不需要再用手势把位移「转发」给内容（参照实现为此挂的
   * `Listener(onPointerMove:)` 在我们这套结构里没必要）。
   */
  @Builder
  categoryStrip() {
    Scroll(this.chipScroller) {
      Row() {
        ForEach(this.types, (type: CollectType, index: number) => {
          this.categoryChip(type, index)
        }, (type: CollectType, index: number) => `${index}-${type.label}`)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(CHIP_ROW_HEIGHT)
    .margin({ top: CHIP_TOP_GAP })
  }

  /** 某个分类页当前的滚动偏移（还没挂载就按 0 算）。 */
  private pageOffsetOf(index: number): number {
    try {
      return this.pageScrollers[index].currentOffset().yOffset;
    } catch (e) {
      return 0;
    }
  }

  /** 某个分类页能滚的最大距离（内容高 − 视口高，负数按 0 算）。 */
  private pageMaxOffset(index: number): number {
    const reachable: number = this.pageContentHeight[index] - this.pagerHeight;
    return reachable > 0 ? reachable : 0;
  }

  /** 把某个分类页滚到指定位置（悬浮标题上手动跟手拖动用，带边界夹取）。 */
  private scrollPageTo(index: number, y: number): void {
    const max: number = this.pageMaxOffset(index);
    const target: number = y < 0 ? 0 : (y > max ? max : y);
    try {
      this.pageScrollers[index].scrollTo({
        xOffset: 0,
        yOffset: target,
        animation: false
      });
    } catch (e) {
      // 还没挂载时忽略
    }
  }

  /** 回到当前分类页顶部（换搜索词 / 换排序之后调，对照 `_resetResults`）。 */
  private scrollContentToTop(): void {
    this.scrollPageTo(this.selectedIndex, 0);
  }

  /**
   * 多选操作条：全选 / 改状态 / 取消收藏。
   *
   * 底边距与推荐页的回顶按钮同一套基准（`bottomInset + 导航条高 + 间距 + 16`），
   * 所以它不会压在底部导航胶囊上。
   */
  @Builder
  selectionBar() {
    Row() {
      this.barButton('全选', AppColor.onSurface, () => {
        this.selectAll();
      })

      Text('改状态')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.onSurface)
        .textAlign(TextAlign.Center)
        .height(40)
        .padding({ left: 16, right: 16 })
        .borderRadius(20)
        .onClick(() => {
          this.statusMenuOpen = true;
        })
        .bindMenu(this.statusMenuOpen, this.batchStatusMenu(), {
          placement: Placement.Top,
          onDisappear: () => {
            this.statusMenuOpen = false;
          }
        })

      this.barButton('取消收藏', AppColor.error, () => {
        this.confirmRemoveSelection();
      })
    }
    .padding({ left: 6, right: 6, top: 6, bottom: 6 })
    .borderRadius(26)
    .backgroundBlurStyle(AppMaterial.capsule, AppMaterial.options())
    .backgroundColor(AppColor.glassCapsuleFill)
    .border({ width: 1, color: AppColor.glassBorder })
    .shadow({ radius: 16, color: '#14000000', offsetX: 0, offsetY: 5 })
    .alignItems(VerticalAlign.Center)
    .margin({
      bottom: this.bottomInset + Dimens.navHeight + Dimens.navBottomGap + 16
    })
  }

  /** 操作条上的文字按钮。 */
  @Builder
  barButton(label: string, color: string, action: () => void) {
    Text(label)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(color)
      .textAlign(TextAlign.Center)
      .height(40)
      .padding({ left: 16, right: 16 })
      .borderRadius(20)
      .onClick(() => {
        action();
      })
  }

  /**
   * 排序胶囊（标题行右侧）。
   *
   * 原来这个位置是「同步」按钮——用户 2026-09-18：「去掉全部的同步功能吧」，
   * 于是把排序从搜索行搬过来：胶囊外壳沿用参照实现 `_capsuleDecoration` 那一套
   * （`surfaceContainerHigh` @0.9 + `onSurface` @0.05 描边 + 5% 阴影），
   * 只把图标换成 `sys.symbol.sort`（已在 `hm_symbol_names.txt` 里核对过），
   * 文案改显示当前档位。
   */
  @Builder
  sortCapsule() {
    Row() {
      SymbolGlyph($r('sys.symbol.sort'))
        .fontSize(20)
        .fontColor([AppColor.onSurface])
      Text(this.sortLabels[this.sortIndex])
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.onSurface)
        .margin({ left: 8 })
    }
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(999)
    .backgroundColor(AppColor.withAlpha(AppColor.surfaceContainerHigh, 0.9))
    .border({ width: 1, color: AppColor.withAlpha(AppColor.onSurface, 0.05) })
    .shadow({
      radius: 16,
      color: AppColor.isDark ? '#29000000' : '#0D000000',
      offsetX: 0,
      offsetY: 5
    })
    .onClick(() => {
      this.sortMenuOpen = true;
    })
    .bindMenu(this.sortMenuOpen, this.sortMenu(), {
      placement: Placement.BottomRight,
      onDisappear: () => {
        this.sortMenuOpen = false;
      }
    })
  }

  @Builder
  categoryChip(type: CollectType, index: number) {
    Row() {
      SymbolGlyph(CollectPage.iconOf(index))
        .fontSize(20)
        .fontColor([index === this.selectedIndex
          ? AppColor.onPrimaryContainer : AppColor.onSurfaceVariant])
      Text(type.label)
        .fontSize(14)
        .fontWeight(index === this.selectedIndex ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(index === this.selectedIndex ? AppColor.onPrimaryContainer : AppColor.onSurfaceVariant)
        .margin({ left: 10 })
      Text(`${this.listOf(index).length}`)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(index === this.selectedIndex
          ? AppColor.onPrimaryContainer : AppColor.onSurfaceVariant)
        .margin({ left: 10 })
    }
    .constraintSize({ minHeight: 48 })
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(index === this.selectedIndex ? 20 : 12)
    .backgroundColor(index === this.selectedIndex ? AppColor.primaryContainer : AppColor.surfaceContainer)
    .margin({ left: index === 0 ? Dimens.contentInset : 0, right: 8 })
    // 分类胶囊：`collect_library_view.dart:484-490` —— 250ms + 强调曲线，
    // 关闭动画时降为 0（§38.15 的 collect_library_view 落点）。
    .animation({
      duration: MotionRuntime.ms(Motion.normal),
      curve: AppCurves.easeInOutCubicEmphasized()
    })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // 记录胶囊在滚动内容里的位置与宽度，供自动居中计算（单位 vp）。
      this.chipX[index] = Number(newValue.position.x);
      this.chipWidth[index] = Number(newValue.width);
    })
    .onClick(() => {
      this.selectCategory(index);
    })
  }

  /**
   * 分类图标（规格 §46.4 的映射表）：
   * 全部 film / 在看 play_circle_fill / 想看 bookmark /
   * 搁置 pause_circle / 看过 checkmark_circle_fill / 抛弃 trash。
   */
  private static iconOf(index: number): Resource {
    if (index === 1) {
      return $r('sys.symbol.play_circle_fill');
    }
    if (index === 2) {
      return $r('sys.symbol.bookmark');
    }
    if (index === 3) {
      return $r('sys.symbol.pause_circle');
    }
    if (index === 4) {
      return $r('sys.symbol.checkmark_circle_fill');
    }
    if (index === 5) {
      return $r('sys.symbol.trash');
    }
    return $r('sys.symbol.film');
  }

  @Builder
  pagerView() {
    Swiper(this.pager) {
      ForEach(this.types, (type: CollectType, index: number) => {
        this.page(index)
      }, (type: CollectType, index: number) => `page-${index}`)
    }
    .loop(false)
    .indicator(false)
    .duration(Motion.normal)
    .width('100%')
    // 整页铺满（含状态栏区域）：内容要从悬浮标题后面穿过去，见 `build()`
    .height('100%')
    // 滑动翻页后回写选中态：点胶囊是瞬时跳页，滑动保留原生动画，
    // 两者最终都收敛到同一个 selectedIndex（对应源码的 onPageChanged）。
    .onChange((index: number) => {
      this.selectedIndex = index;
      this.refresh();
      this.centerChip(index);
    })
    // 记下 Swiper 的实测高度：分类页内容要**至少撑满**它，
    // 否则内容一短（比如只有一张卡）就会被 Scroll 垂直居中——
    // 真机实测「全部」只有 1 条时，内容整块落在屏幕 40% 处（用户反馈「没有顶格」）。
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const height: number = Number(newValue.height);
      if (height > 0 && Math.abs(height - this.pagerHeight) > 0.5) {
        this.pagerHeight = height;
      }
    })
  }

  @Builder
  page(index: number) {
    Scroll(this.pageScrollers[index]) {
      Column() {
        /**
         * 给悬浮头（标题 + 搜索条 + 分类胶囊）让位的占位。
         *
         * 必须放在**滚动内容里**，不能改成给 Scroll 加 `padding`：padding 是
         * 裁剪边界，内容滚到标题下面会被自己的上边界裁掉。
         */
        Column()
          .width('100%')
          .height(this.topInset + HEADER_BLOCK_HEIGHT)

        if (this.listOf(index).length === 0) {
          this.emptyState(index)
        } else {
          // 1:1 对齐参照实现 `collect_library_view.dart:411-450` 的 `_scrollableContent`：
          // 手机是**列表行**（每行一张卡，行距 10），
          // 宽屏（内容宽 ≥ 840）才两列并排。
          List({ space: 10 }) {
            ForEach(this.rowsOf(index), (row: CollectEntry[], rowIndex: number) => {
              ListItem() {
                if (row.length > 1) {
                  Row({ space: 12 }) {
                    Column() {
                      this.card(row[0], index)
                    }.layoutWeight(1)
                    Column() {
                      this.card(row[1], index)
                    }.layoutWeight(1)
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Top)
                } else {
                  this.card(row[0], index)
                }
              }
            }, (row: CollectEntry[], rowIndex: number) =>
              // key 里带上分类与观看集数：ArkUI 的 ForEach **按 key 复用子树**，
              // 只放 id 的话「改分类」后卡片不会重建（实测：库里已是「看过」，
              // 卡片上仍写着「想看」）；集数同理——进度线读的是缓存 Map，
              // key 不变就不会重算，「看完一集回来数字还是旧的」。
              `collect-row-${index}-${rowIndex}-` +
                row.map((e: CollectEntry) =>
                  `${e.id}-${e.collectType}-${this.watchedEpisode(e.id)}`).join('_'))
          }
          .width('100%')
          .padding({ left: this.hInset(), right: this.hInset() })
          .scrollBar(BarState.Off)
          // 列表与上面的胶囊之间留一点呼吸（用户 2026-09-18：「距离稍微大一点点」）
          .margin({ top: 12 })
        }

        Blank().height(Dimens.contentBottomSpacer)
      }
      .width('100%')
      // 短内容也要顶格：minHeight = Swiper 高度（长内容自然增长，不挡滚动）
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start)
      .constraintSize({
        minHeight: this.pagerHeight > 0 ? this.pagerHeight : 600
      })
      // 量本分类页的内容高度（各页独立存，见 `pageContentHeight` 注释）
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const h: number = Number(newValue.height);
        if (h > 0) {
          this.pageContentHeight[index] = h;
        }
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onDidScroll(() => {
      // 只在「当前分类页」上报：Swiper 同时挂载相邻页，不设这道闸，
      // 横向滑页时会被邻居页抢报滚动量，导航条乱弹。
      if (index !== this.selectedIndex) {
        return;
      }
      // 从 Scroller 读真实偏移（第二个参数是 ScrollState，见字段注释）
      const offset: number = this.pageScrollers[index].currentOffset().yOffset;
      const reachable: number = this.pageContentHeight[index] - this.pagerHeight;
      this.onScrollOffset(offset, reachable > 0 ? reachable : 0);
    })
  }

  /** 分类空态文案（对应参照实现 `_emptyState` 的六个分支）。 */
  private static emptyTitle(index: number): string {
    return CollectPage.emptyTitles()[index];
  }

  /**
   * 空态（对照 `GeneralEmptyState`：图标 + 标题，我们再加一个动作按钮）。
   *
   * 原来这里是两行灰字，看完不知道下一步能干什么；现在：
   *   - 搜索无结果 → 「清除搜索」；
   *   - 分类为空   → 「去搜索」，直接把用户送到搜索页。
   */
  @Builder
  emptyState(index: number) {
    Column() {
      SymbolGlyph($r(this.searching()
        ? 'sys.symbol.minus_magnifyingglass' : 'sys.symbol.film'))
        .fontSize(36)
        .fontColor([AppColor.onSurfaceVariant])
        .margin({ bottom: 12 })
      Text(this.emptyTitleOf(index))
        .fontSize(15)
        .fontColor(AppColor.onSurfaceVariant)
      if (!this.searching()) {
        Text('在番剧详情页点「追番」，或在搜索里找番剧')
          .fontSize(12)
          .fontColor(AppColor.onSurfaceVariant)
          .margin({ top: 8 })
      }
      Text(this.searching() ? '清除搜索' : '去搜索')
        .fontSize(13)
        .fontColor(AppColor.primary)
        .margin({ top: 16 })
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .borderRadius(16)
        .backgroundColor(AppColor.primaryContainer)
        .onClick(() => {
          if (this.searching()) {
            this.query = '';
            this.scrollContentToTop();
          } else {
            RouteTable.push(RouteTable.search);
          }
        })
    }
    .width('100%')
    .height(420)
    .justifyContent(FlexAlign.Center)
  }

  /** 是否处于搜索状态。 */
  private searching(): boolean {
    return this.query.trim().length > 0;
  }

  /** 空态标题：搜索态用「没找到 / 这个分类没有」两档，否则按分类给文案。 */
  private emptyTitleOf(index: number): string {
    if (!this.searching()) {
      return CollectPage.emptyTitle(index);
    }
    return this.matchedTotal() > 0
      ? '当前分类没有匹配的番剧' : '没有找到匹配的番剧';
  }

  private static emptyTitles(): string[] {
    const titles: string[] = [
      '还没有收藏的番剧',
      '还没有在追的番剧',
      '还没有想看的番剧',
      '没有搁置的番剧',
      '还没有看过的番剧',
      '没有弃追的番剧'
    ];
    return titles;
  }

  /**
   * 收藏卡片（1:1 对齐参照实现 `_CollectLibraryCard`）。
   *
   * ```
   * GlassSurface(圆角 24) → Padding(12,12,16,8) → Row
   *   ├ Hero：80×120 封面、圆角 16
   *   ├ 间距 16
   *   └ Column(minHeight 76)
   *       ├ 标题 titleMedium w700（最多 2 行）
   *       ├ 年份 / 评分：bodySmall + onSurfaceVariant，'  ·  ' 连接
   *       └ 状态按钮：高 40、圆角胶囊、右侧 expand_more
   * ```
   *
   * 整卡可点进详情页；状态按钮单独弹菜单（改分类 / 取消收藏）。
   */
  @Builder
  card(entry: CollectEntry, pageIndex: number) {
    Row() {
      // ---- 封面（Hero）+ 多选角标 ----
      Stack({ alignContent: Alignment.TopEnd }) {
        /**
         * 存的是原始 lain.bgm.tv 地址，渲染前过一遍镜像改写。
         *
         * ⚠️ **别在这里降档**：这张封面是共享元素（Hero）的起点，详情页海报
         * 用的是 `coverUrl()` 原图，两端 URL 一旦不同，飞行途中目标端就是
         * 一张没加载好的图（2026-09-20 试过 `/r/400/`，已回退）。
         */
        CoverImage({
          src: BangumiImageUrlRewriter.rewriteWithSettings(entry.cover),
          fit: ImageFit.Cover,
          radius: 16
        })
          .width(80)
          .height(120)
          .backgroundColor(AppColor.surfaceContainerHighest)
          .borderRadius(16)
          .clip(true)
          // Hero 共享元素（§38.7）：书架卡海报 → 详情页海报（跨页用 sharedTransition）。
          // 只让**当前分类**的卡片参与：同一个 id 不能有两个组件绑定，
          // 而 Swiper 里 6 个分类的卡片是同时挂着的（参照实现用
          // `HeroMode(enabled: 是当前分类)` 解决，注释原文
          // 「Avoid duplicate Hero tags across collection categories」）。
          .geometryTransition(this.selectedIndex === pageIndex
            ? HeroFlight.tag('collect', entry.id) : '')
          // 记下源封面在**窗口**里的位置（退场自绘飞行用；空 tag 会被忽略）
          .onAreaChange((oldValue: Area, newValue: Area) => {
            HeroRects.setCard(this.selectedIndex === pageIndex
              ? HeroFlight.tag('collect', entry.id) : '', newValue);
          })
          .zIndex(1)

        /**
         * 多选角标：压在海报右上角。
         * 垫一个 surface 小圆底——不垫的话浅色海报上「空心勾」几乎看不见。
         */
        if (this.selecting) {
          Stack() {
            SymbolGlyph($r(this.isSelected(entry.id)
              ? 'sys.symbol.checkmark_circle_fill'
              : 'sys.symbol.checkmark_circle'))
              .fontSize(20)
              .fontColor([this.isSelected(entry.id)
                ? AppColor.primary : AppColor.onSurfaceVariant])
          }
          .width(26)
          .height(26)
          .borderRadius(13)
          .backgroundColor(AppColor.withAlpha(AppColor.surface, 0.86))
          .margin({ top: 4, right: 4 })
          // 海报本身带着 `zIndex(1)`（共享元素用），角标要压在它上面
          .zIndex(2)
        }
      }
      .width(80)
      .height(120)

      Blank().width(16)

      // ---- 文字 + 状态按钮 ----
      Column() {
        Column() {
          Text(entry.displayName())
            .fontSize(TS.titleMediumSize)
            .lineHeight(TS.titleMediumSize * 1.35)
            .fontWeight(TS.w700)
            .fontColor(AppColor.onSurface)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.metaLine(entry).length > 0) {
            Text(this.metaLine(entry))
              .fontSize(TS.bodySmallSize)
              .lineHeight(TS.bodySmallLine)
              .fontColor(AppColor.onSurfaceVariant)
              .maxLines(1)
              .margin({ top: 8 })
              .width('100%')
          }
          // 观看进度：本地历史（看到第 N 集）+ 收藏记录里的总集数
          if (this.progressText(entry).length > 0) {
            Text(this.progressText(entry))
              .fontSize(TS.bodySmallSize)
              .lineHeight(TS.bodySmallLine)
              .fontColor(AppColor.onSurfaceVariant)
              .maxLines(1)
              .margin({ top: 4 })
              .width('100%')
          }
          this.progressBar(entry)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .constraintSize({ minHeight: 76 })
        .padding({ top: 4, bottom: 8 })

        Row({ space: 2 }) {
          Text(this.typeLabel(entry.collectType))
            .fontSize(14)
            .fontColor(AppColor.onSecondaryContainer)
          // §46.4：`expand_more_rounded` → `chevron_down`
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(18)
            .fontColor([AppColor.onSecondaryContainer])
        }
        .height(40)
        .padding({ left: 16, right: 12 })
        .borderRadius(20)
        .backgroundColor(AppColor.secondaryContainer)
        .bindMenu(this.statusMenu(entry), {
          placement: Placement.BottomLeft
        })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 12, right: 16, top: 12, bottom: 8 })
    .borderRadius(24)
    // 多选中被选中的卡片整块提亮成主色容器色，配合角标说明「这张要被处理」
    .backgroundColor(this.selecting && this.isSelected(entry.id)
      ? AppColor.withAlpha(AppColor.primaryContainer, 0.55) : AppColor.glassCardFill)
    .border({
      width: 1,
      color: this.selecting && this.isSelected(entry.id)
        ? AppColor.primary : AppColor.glassBorder
    })
    /**
     * 长按卡片 → 进多选（对齐历史记录页的「编辑」模式，只是入口放在长按上）。
     * 450ms 与系统长按手感一致；已经进多选之后长按不再重复触发。
     */
    .gesture(
      LongPressGesture({ repeat: false, duration: 450 })
        .onAction(() => {
          this.enterSelecting(entry.id);
        })
    )
    .onClick(() => {
      // 长按刚触发的这一次抬手不要再当成点击（否则刚选中就被取消）
      if (Date.now() < this.suppressClickUntil) {
        return;
      }
      if (this.selecting) {
        this.toggleSelected(entry.id);
        return;
      }
      // 收藏表只存列表要用的字段，进详情页时把已知字段拼回条目再补拉
      // （与参照实现 `collect_page.dart` 传 BangumiItem 的语义一致）。
      InfoRouteArgs.open(this.toBangumiItem(entry), 'collect',
        this.selectedIndex === pageIndex ? HeroFlight.tag('collect', entry.id) : '');
    })
  }

  /** 本地历史里这部番看到第几集（没有记录就是 0）。 */
  private watchedEpisode(id: number): number {
    const value: number | undefined = this.progressBySubject.get(id);
    return value === undefined ? 0 : value;
  }

  /** 进度文案：看到第 N 集 / 共 M 集（缺哪一半就只显示另一半）。 */
  private progressText(entry: CollectEntry): string {
    const watched: number = this.watchedEpisode(entry.id);
    const total: number = entry.epsTotal;
    if (watched > 0 && total > 0) {
      return `看到第 ${watched} 集 · 共 ${total} 集`;
    }
    if (watched > 0) {
      return `看到第 ${watched} 集`;
    }
    return total > 0 ? `共 ${total} 集` : '';
  }

  /**
   * 进度百分比；**未知总集数或还没看**时返回 -1（调用方据此不画进度线）。
   */
  private progressPercent(entry: CollectEntry): number {
    const total: number = entry.epsTotal;
    const watched: number = this.watchedEpisode(entry.id);
    if (total <= 0 || watched <= 0) {
      return -1;
    }
    const percent: number = Math.round(watched / total * 100);
    return percent > 100 ? 100 : percent;
  }

  /** 3vp 细进度线（轨道 + 主色填充），只在百分比有效时画。 */
  @Builder
  progressBar(entry: CollectEntry) {
    if (this.progressPercent(entry) >= 0) {
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(3)
          .borderRadius(1.5)
          .backgroundColor(AppColor.withAlpha(AppColor.onSurface, 0.08))
        Row()
          .width(`${this.progressPercent(entry)}%`)
          .height(3)
          .borderRadius(1.5)
          .backgroundColor(AppColor.primary)
      }
      .width('100%')
      .height(3)
      .margin({ top: 6 })
    }
  }

  /**
   * 卡片副标题（参照实现 `collect_library_card.dart:22-25`）：
   * `['{年} 年', '{评分} 分']` 里非空项用 `'  ·  '` 连接。
   */
  private metaLine(entry: CollectEntry): string {
    const parts: string[] = [];
    const year: number = Number.parseInt(entry.airDate.substring(0, 4), 10);
    if (!Number.isNaN(year) && entry.airDate.length >= 4) {
      parts.push(`${year} 年`);
    }
    if (entry.score > 0) {
      parts.push(`${entry.score.toFixed(1)} 分`);
    }
    return parts.join('  ·  ');
  }

  /** 可选的观看状态（参照实现 `CollectType.values.where(isCollected)`，5 项）。 */
  private static statusOptions(): number[] {
    return [1, 2, 3, 4, 5];
  }

  /** 状态菜单（参照实现 `_statusMenu`）：5 个状态 + 分隔线 + 取消收藏。 */
  @Builder
  statusMenu(entry: CollectEntry) {
    Menu() {
      // 参照实现里两组之间是一条 `Divider`；ArkUI 的 Menu 只允许
      // MenuItem / MenuItemGroup，所以用**两个 MenuItemGroup** 代替——
      // 组间本来就带分割线，视觉效果一致。
      MenuItemGroup() {
        ForEach(CollectPage.statusOptions(), (value: number) => {
          MenuItem({
            content: this.typeLabel(value),
            endIcon: value === entry.collectType ? $r('sys.symbol.checkmark') : undefined
          })
            .enabled(value !== entry.collectType)
            .onClick(() => {
              this.changeCollectType(entry, value);
            })
        }, (value: number) => `collect-status-${value}`)
      }
      MenuItemGroup() {
        MenuItem({ content: '取消收藏' })
          .onClick(() => {
            this.changeCollectType(entry, 0);
          })
      }
    }
  }

  /** 改分类 / 取消收藏：写库后刷新（参照实现 `onChangeType` → `CollectController`）。 */
  private changeCollectType(entry: CollectEntry, type: number): void {
    if (type === 0) {
      CollectStore.remove(entry.id);
    } else {
      CollectStore.setType(entry.id, type);
    }
    this.refresh();
  }

  /** 收藏记录 → 条目。详情页会按 id 再补 summary / 评分 / 别名等字段。 */
  private toBangumiItem(entry: CollectEntry): BangumiItem {
    const item = new BangumiItem();
    item.id = entry.id;
    item.name = entry.name;
    item.nameCn = entry.nameCn.length > 0 ? entry.nameCn : entry.name;
    item.airDate = entry.airDate;
    item.ratingScore = entry.score;
    item.images.set('large', entry.cover);
    return item;
  }

  private typeLabel(type: number): string {
    for (let i = 0; i < this.types.length; i++) {
      if (this.types[i].value === type) {
        return this.types[i].label;
      }
    }
    return '';
  }
}
