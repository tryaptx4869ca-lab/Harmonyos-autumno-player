import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppColor } from '../theme/AppColors';
import { AppMaterial } from '../theme/Material';
import { LoadingIndicator } from '../components/LoadingIndicator';
import { Dimens, HeroFlight, PageTransitionSpec } from '../theme/Tokens';
import { Logger } from '../services/Logger';
import { RouteTable } from '../router/RouteTable';
import { InfoRouteArgs, VideoRouteArgs } from '../router/RouteArgs';
import { HeroRects } from '../router/HeroRects';
import { CollectType } from '../model/CollectType';
import {
  HistoryDateGroup,
  HistoryEntry,
  HistorySourceFilter,
  filterHistoryEntries,
  groupHistoryEntries
} from '../model/HistoryModels';
import { HistoryRepository } from '../services/HistoryRepository';
import { HistoryPlaybackResult, HistoryPlaybackService } from '../services/HistoryPlaybackService';
import { CollectStore, CollectEntry } from '../services/collect/CollectStore';
import { CoverImage } from '../components/CoverImage';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnHistoryPage';

/** 收藏类型（§6 / `collect_type.dart`）：值与文案同追番页。 */
const COLLECT_TYPES: CollectType[] = [
  new CollectType(1, '在看', 'play_circle_outline'),
  new CollectType(2, '想看', 'bookmark_border'),
  new CollectType(3, '搁置', 'pause_circle_outline'),
  new CollectType(4, '看过', 'task_alt'),
  new CollectType(5, '抛弃', 'delete_outline')
];

/** 卡片圆角（§51.2：首行上圆角 24、末行下圆角 24，中间行 4）。 */
const CARD_OUTER_RADIUS: number = 24;
const CARD_INNER_RADIUS: number = 4;

/**
 * 历史记录（我的 → 历史记录，规格 §51.2 / §7.4）。
 *
 * 数据来自阶段五落地的历史服务：`HistoryRepository` 落盘、
 * `HistoryPlaybackService` 负责「点卡片继续播放」（复用规则引擎查线路）。
 *
 * 与参照实现的逐条对齐点：
 *   1. 顶部搜索框（番剧名 / 别名 / 来源）+「全部 / 在线 / 缓存」筛选胶囊
 *   2. 胶囊切换是 **250ms `easeInOutCubicEmphasized`**，选中态圆角 20、未选 12
 *   3. 按日分组（今天 / 昨天 / M月D日），组头右侧带条数
 *   4. 空态分两种：真的没记录 vs 筛选后为空（后者带「查看全部记录」）
 *   5. 卡片：海报 60×84、标题 w700、集数、主色「看到 mm:ss」、来源行、
 *      主色继续播放按钮 + 更多菜单（番剧详情 / 收藏 / 删除记录）
 *   6. 编辑模式：右上「编辑 → 完成」与「清空」，卡片只留删除按钮
 */
@Component
export struct HistoryPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('themeRevision') themeRevision: number = 0;
  /** 订阅历史变更：别的页面写了历史（如播放页）回到这里能立刻刷新。 */
  @StorageProp('historyRevision') @Watch('onHistoryChanged') historyRevision: number = 0;
  /**
   * 订阅收藏变更：每行卡片上的「在看 / 想看…」是现读 `CollectStore` 的，
   * 在播放页改完状态回到历史页也要跟着变（同 `historyRevision` 那套）。
   */
  @StorageProp('collectRevision') @Watch('onCollectChanged') collectRevision: number = 0;

  @State private entries: HistoryEntry[] = [];
  @State private groups: HistoryDateGroup[] = [];
  @State private query: string = '';
  /**
   * 来源筛选：**恒为「全部」**。
   *
   * 用户 2026-09-17 要求「番剧不要按源分开」，所以筛选胶囊与卡片上的源标注
   * 都去掉了。字段与 `filterHistoryEntries(...)` 的调用保留着——列表已经按
   * 番剧合并，这个维度不再参与展示；哪天真要加回筛选，接上即可。
   */
  @State private source: HistorySourceFilter = HistorySourceFilter.all;
  @State private editing: boolean = false;
  @State private clearing: boolean = false;
  /** 正在解析 / 删除的卡片 key（转圈 + 屏蔽重复点击）。 */
  @State private busyKey: string = '';

  // ---- 卡片「更多」菜单 ----
  /**
   * 原生菜单不需要「哪张卡的菜单开着」这个状态：`bindMenu` 挂在每张卡自己的
   * 「更多」按钮上，由系统负责定位、遮罩、出现动画与点击外部关闭
   * （与 `CollectPage.statusMenu` 同一做法）。
   */

  private confirmDialog: CustomDialogController | null = null;
  private pendingDelete: HistoryEntry | null = null;

  aboutToAppear(): void {
    this.confirmDialog = new CustomDialogController({
      builder: ConfirmDialog({
        title: '',
        message: '',
        confirmLabel: '确定',
        onConfirm: () => {
        }
      }),
      autoCancel: true,
      customStyle: false
    });
    this.reload();
    hilog.info(DOMAIN, TAG, '历史页打开，共 %{public}d 条', this.entries.length);
  }

  onHistoryChanged(): void {
    this.reload();
  }

  /**
   * 收藏变了：踢一次列表重绘。
   *
   * 行上的状态来自 `currentCollectType()`（现读 `CollectStore`），
   * 数据不用重建，只要让列表重跑一次 build。
   */
  onCollectChanged(): void {
    this.reload();
  }

  /** 二级页转场（§12.4）。 */
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

  // ============================================================
  // 数据
  // ============================================================

  private reload(): void {
    this.entries = HistoryRepository.getAll();
    this.applyFilters();
    if (this.entries.length === 0 && this.editing) {
      this.editing = false;
    }
  }

  private applyFilters(): void {
    // 先按**番剧**合并：同一部番换源看过只会留下最近那条记录。
    // 用户 2026-09-17 要求「番剧不要按源分开」——原来 `HistoryEntry.key()`
    // 是 `规则名 + 番剧id`，同一部番看过两个源就会在列表里出现两张长得
    // 一模一样的卡片（源标注上一轮已经去掉，所以看上去就是纯重复）。
    // 更糟的是：两张封面写着**同一个**共享元素 tag
    // （`HeroFlight.tag('history', id)`），而 ArkUI 不允许一个 tag 绑两个组件
    // ——于是点击后的封面动画会从另一张卡片起飞。合并之后 tag 唯一，动画才对得上。
    const filteredEntries: HistoryEntry[] =
      filterHistoryEntries(HistoryPage.dedupeByAnime(this.entries),
        this.query, this.source);
    this.groups = groupHistoryEntries(filteredEntries, Date.now());
  }

  /**
   * 分组在 `ForEach` 里的 key：日期 + 组内内容签名。
   *
   * 见调用处的注释——只用日期的话，组内增删不会触发外层重建，
   * 内层 `ForEach` 会一直引用旧数组，卡片删不掉。
   */
  private static groupSignature(group: HistoryDateGroup): string {
    const count: number = group.entries.length;
    if (count === 0) {
      return `${group.dayStartMs}-0`;
    }
    const first: string = group.entries[0].key();
    const last: string = group.entries[count - 1].key();
    return `${group.dayStartMs}-${count}-${first}-${last}`;
  }

  /**
   * 按番剧合并：每部番只保留**最近观看**的那条记录，并保持原有顺序。
   *
   * 只在展示层做，不动存储——数据库里仍然按「规则名 + 番剧id」分开存，
   * 这样「继续播放」还能用具体某个源的进度，而列表不再出现重复卡片。
   */
  private static dedupeByAnime(entries: HistoryEntry[]): HistoryEntry[] {
    const newest: Map<number, HistoryEntry> = new Map<number, HistoryEntry>();
    for (let i = 0; i < entries.length; i++) {
      const e: HistoryEntry = entries[i];
      const kept: HistoryEntry | undefined = newest.get(e.bangumiItem.id);
      if (kept === undefined || e.lastWatchTime > kept.lastWatchTime) {
        newest.set(e.bangumiItem.id, e);
      }
    }
    const out: HistoryEntry[] = [];
    for (let i = 0; i < entries.length; i++) {
      const e: HistoryEntry = entries[i];
      if (newest.get(e.bangumiItem.id) === e) {
        out.push(e);
      }
    }
    return out;
  }

  private setQuery(value: string): void {
    this.query = value;
    this.applyFilters();
  }

  private resetFilters(): void {
    this.query = '';
    this.source = HistorySourceFilter.all;
    this.applyFilters();
  }

  // ============================================================
  // 卡片动作
  // ============================================================

  private async play(entry: HistoryEntry): Promise<void> {
    // 这一行留着：排查「点继续播放没反应」时必须能区分
    // 「按钮没点到」和「点了但源站解析失败」——后者只弹一个转瞬即逝的 Toast。
    Logger.info('AutumnHistory',
      `点继续播放：editing=${this.editing} busy=${this.busyKey.length > 0}`);
    if (this.editing || this.busyKey.length > 0) {
      return;
    }
    const key: string = entry.key();
    this.busyKey = key;
    const result: HistoryPlaybackResult = await HistoryPlaybackService.open(entry);
    this.busyKey = '';
    if (!result.ok || result.args === null) {
      this.toast(result.reason.length > 0
        ? result.reason : '暂时无法继续播放，请稍后重试');
      return;
    }
    VideoRouteArgs.open(result.args);
  }

  private openDetails(entry: HistoryEntry): void {
    InfoRouteArgs.open(entry.bangumiItem, 'history',
      HeroFlight.tag('history', entry.bangumiItem.id));
  }

  private currentCollectType(entry: HistoryEntry): number {
    const stored: CollectEntry | null = CollectStore.find(entry.bangumiItem.id);
    return stored === null ? 0 : stored.collectType;
  }

  private collectLabel(entry: HistoryEntry): string {
    const type: number = this.currentCollectType(entry);
    for (let i = 0; i < COLLECT_TYPES.length; i++) {
      if (COLLECT_TYPES[i].value === type) {
        return COLLECT_TYPES[i].label;
      }
    }
    return '未收藏';
  }

  /** 改收藏状态：没有记录先补一条（对应源码 `addCollect` 的 upsert 语义）。 */
  private changeCollect(entry: HistoryEntry, type: number): void {
    const existing: CollectEntry | null = CollectStore.find(entry.bangumiItem.id);
    if (existing === null) {
      const created = new CollectEntry();
      created.id = entry.bangumiItem.id;
      created.name = entry.bangumiItem.name;
      created.nameCn = entry.bangumiItem.nameCn;
      created.cover = entry.bangumiItem.cover;
      created.airDate = entry.bangumiItem.airDate;
      created.score = entry.bangumiItem.ratingScore;
      created.epsTotal = entry.bangumiItem.episodeCount();
      created.collectType = type;
      created.updatedAt = Date.now();
      CollectStore.upsert(created);
    } else {
      CollectStore.setType(entry.bangumiItem.id, type);
    }
    this.toast(`已标记为「${this.typeLabel(type)}」`);
  }

  private typeLabel(type: number): string {
    for (let i = 0; i < COLLECT_TYPES.length; i++) {
      if (COLLECT_TYPES[i].value === type) {
        return COLLECT_TYPES[i].label;
      }
    }
    return '在看';
  }

  private remove(entry: HistoryEntry): void {
    if (this.busyKey.length > 0 || this.clearing) {
      return;
    }
    this.busyKey = entry.key();
    // 卡片是按番剧合并展示的，删除也必须删掉**同一部番的所有来源记录**，
    // 否则剩下的那条会让卡片立刻「复活」（用户看到的就是删不掉）。
    const all: HistoryEntry[] = HistoryRepository.getAll();
    for (let i = 0; i < all.length; i++) {
      if (all[i].bangumiItem.id === entry.bangumiItem.id) {
        HistoryRepository.deleteHistory(all[i]);
      }
    }
    this.busyKey = '';
    this.reload();
    this.toast('已删除该番剧的记录');
  }

  private confirmClear(): void {
    if (this.clearing || this.entries.length === 0) {
      return;
    }
    const controller: CustomDialogController | null = this.confirmDialog;
    if (controller === null) {
      return;
    }
    this.confirmDialog = new CustomDialogController({
      builder: ConfirmDialog({
        title: '清空历史记录？',
        message: `将删除全部 ${this.entries.length} 条观看记录，包括在线和缓存记录。此操作无法撤销。`,
        confirmLabel: '清空全部',
        onConfirm: () => {
          this.doClear();
        }
      }),
      autoCancel: true,
      customStyle: false
    });
    this.confirmDialog.open();
  }

  private doClear(): void {
    this.clearing = true;
    HistoryRepository.clearAll();
    this.clearing = false;
    this.editing = false;
    this.reload();
    this.toast('历史记录已清空');
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // ============================================================
  // 文案
  // ============================================================

  private titleOf(entry: HistoryEntry): string {
    return entry.displayName();
  }

  private episodeOf(entry: HistoryEntry): string {
    return entry.lastWatchEpisodeName.length === 0
      ? `第 ${entry.lastWatchEpisode} 话` : entry.lastWatchEpisodeName;
  }

  private positionOf(entry: HistoryEntry): string {
    const progress = entry.progresses.get(entry.lastWatchEpisode);
    if (progress === undefined || progress.progressMs <= 0) {
      return '';
    }
    const totalSeconds: number = Math.floor(progress.progressMs / 1000);
    const seconds: number = totalSeconds % 60;
    const minutes: number = Math.floor(totalSeconds / 60) % 60;
    const hours: number = Math.floor(totalSeconds / 3600);
    const ss: string = seconds < 10 ? `0${seconds}` : `${seconds}`;
    const mm: string = minutes < 10 ? `0${minutes}` : `${minutes}`;
    return hours > 0 ? `看到 ${hours}:${mm}:${ss}` : `看到 ${minutes}:${ss}`;
  }

  /**
   * 卡片副信息。
   *
   * 用户 2026-09-17 要求卡片**只保留番剧、不标注来源**，所以这里去掉了
   * 「在线 / 缓存」标记与规则名（`adapterName`）——同一部番换源看过之后，
   * 卡片不该跟着变样。只留观看时刻（日期由上面的分组头给出）。
   */
  private metaOf(entry: HistoryEntry): string {
    return HistoryPage.clockText(entry.lastWatchTime);
  }

  /** `HH:mm`（对应参照实现的 `TimeOfDay.format`）。 */
  private static clockText(timestampMs: number): string {
    const date = new Date(timestampMs);
    const hours: number = date.getHours();
    const minutes: number = date.getMinutes();
    const hh: string = hours < 10 ? `0${hours}` : `${hours}`;
    const mm: string = minutes < 10 ? `0${minutes}` : `${minutes}`;
    return `${hh}:${mm}`;
  }

  // ============================================================
  // 视图
  // ============================================================

  /**
   * 沉浸式布局：**两层**。
   *
   *   层 1（下面那层，铺满全屏）：搜索胶囊 + 番剧记录，**整体可滚动**；
   *   层 2（上面那层，固定）：返回键 + 标题「历史记录」+ 编辑。
   *
   * 用户 2026-09-17 明确要求只把这三个控件钉在上面——搜索栏属于内容，
   * 应该跟着列表一起滚走，而不是一直占着屏幕顶部。
   *
   * 为了内容能真的从标题**后面**穿过，层 1 不能带顶部内边距
   * （否则列表会从标题下方开始渲染，滚动时被自己的上边界裁掉），
   * 而是由列表**第一项占位**把首屏内容推到标题下方。
   */
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 层 1：全屏（搜索 + 记录一起滚）
      Column() {
        if (this.entries.length === 0) {
          this.emptyState()
        } else {
          this.historyList()
        }
      }
      .width('100%')
      .height('100%')

      // 层 2：固定在顶部的标题层
      this.topTitleBar()
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
    .backgroundColor(AppColor.surface)
  }

  /**
   * 顶部标题层的高度（vp）：列表第一项按它占位。
   *
   * 与 `topTitleBar()` 的实际尺寸**必须同步改**（上留白 8 + 标题行 44 + 下留白 8）。
   */
  private topLayerHeight(): number {
    return 8 + 44 + 8;
  }

  /**
   * 顶部标题层（钉住的那一层）。
   *
   * 只有三个控件：返回圆钮 / 标题文字 / 编辑（编辑模式下再加清空）。
   * 标题是纯文字（对齐推荐页的「下午好」：同样 w800、不发光、不带底）。
   *
   * 后面垫了一层**很轻的顶部渐变**（surface → 透明）：标题是纯文字，
   * 番剧封面滚到它后面时如果没有这层，文字会被海报糊掉看不清。
   * 渐变只是底色，不算控件，所以不违背「上面只留那三个」。
   */
  @Builder
  topTitleBar() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height(this.topLayerHeight() + 16)
        .linearGradient({
          angle: 180,
          colors: [
            [AppColor.surface, 0.0],
            [AppColor.withAlpha(AppColor.surface, 0), 1.0]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      Row() {
        // 返回：圆形玻璃胶囊（与二级页外壳同一规格）
        Stack() {
          SymbolGlyph($r('sys.symbol.arrow_left'))
            .fontSize(20)
            .fontColor([AppColor.onSurface])
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundBlurStyle(AppMaterial.capsule, AppMaterial.options())
        .backgroundColor(AppColor.glassCapsuleFill)
        .border({ width: 1, color: AppColor.glassBorder })
        .onClick(() => {
          RouteTable.back();
        })

        Text('历史记录')
          .fontSize(20)
          .lineHeight(27)
          .fontWeight(800)
          .letterSpacing(0.3)
          .fontColor(AppColor.onSurface)
          .maxLines(1)
          .layoutWeight(1)
          .margin({ left: 12 })

        if (this.entries.length > 0) {
          this.headerTextCapsule(this.editing ? '完成' : '编辑', () => {
            this.editing = !this.editing;
          })
        }
        if (this.editing) {
          this.headerIconCapsule($r('sys.symbol.trash'),
            this.clearing ? AppColor.onSurfaceVariant : AppColor.error, () => {
              this.confirmClear();
            })
        }
      }
      .width('100%')
      .height(44)
      .alignItems(VerticalAlign.Center)
      .padding({ left: Dimens.contentInset, right: Dimens.contentInset })
      .margin({ top: 8 })
    }
    .width('100%')
    .height(this.topLayerHeight())
  }

  /** 文字胶囊（编辑 / 完成）。 */
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
      .margin({ left: 8 })
      .onClick(() => {
        action();
      })
  }

  /** 图标胶囊（清空）。 */
  @Builder
  headerIconCapsule(icon: Resource, color: string, action: () => void) {
    Stack() {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([color])
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .backgroundBlurStyle(AppMaterial.capsule, AppMaterial.options())
    .backgroundColor(AppColor.glassCapsuleFill)
    .border({ width: 1, color: AppColor.glassBorder })
    .margin({ left: 8 })
    .onClick(() => {
      action();
    })
  }

  /**
   * 搜索胶囊。
   *
   * 用户在 2026-09-17 把它从「钉在顶部的头部」挪到了**内容层**：
   * 它跟着列表一起滚走，首屏在标题下面，滚上去之后让位给番剧记录。
   *
   * 底仍是不透明的 `surfaceContainerHigh`——它已经不悬在列表之上了，
   * 用材质只会平白多一个模糊节点。
   */
  @Builder
  searchCapsule() {
    Row() {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(18)
        .fontColor([AppColor.onSurfaceVariant])
        .margin({ left: 16 })
      TextInput({ text: this.query, placeholder: '搜索番剧' })
        .placeholderColor(AppColor.onSurfaceVariant)
        .backgroundColor(Color.Transparent)
        .fontSize(15)
        .fontColor(AppColor.onSurface)
        .layoutWeight(1)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.setQuery(value);
        })
      if (this.query.length > 0) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(16)
          .fontColor([AppColor.onSurfaceVariant])
          .padding({ left: 8, right: 16 })
          .onClick(() => {
            this.setQuery('');
          })
      }
    }
    .width('100%')
    .height(48)
    .borderRadius(24)
    .backgroundColor(AppColor.surfaceContainerHigh)
    .border({ width: 1, color: AppColor.glassBorder })
  }

  @Builder
  historyList() {
    List() {
      // 第一项：为顶部标题层让位的占位。
      // 放在**列表内部**而不是给 List 加 padding —— 这样内容向上滚动时
      // 会从标题**后面**穿过去，而不是被列表自己的上边界裁掉。
      ListItem() {
        Column()
          .width('100%')
          .height(this.topLayerHeight())
      }

      // 第二项：搜索胶囊。它属于内容层（用户要求），跟着列表一起滚走。
      ListItem() {
        this.searchCapsule()
      }

      ListItem() {
        Column()
          .width('100%')
          .height(4)
      }

      ForEach(this.groups, (group: HistoryDateGroup) => {
        ListItem() {
          this.groupHeader(group)
        }
        ForEach(group.entries, (entry: HistoryEntry, index: number) => {
          if (this.editing) {
            ListItem() {
              this.historyCard(entry,
                index === 0 ? CARD_OUTER_RADIUS : CARD_INNER_RADIUS,
                index === group.entries.length - 1
                  ? CARD_OUTER_RADIUS : CARD_INNER_RADIUS)
            }
            .padding({ bottom: 2 })
          } else {
            ListItem() {
              this.historyCard(entry,
                index === 0 ? CARD_OUTER_RADIUS : CARD_INNER_RADIUS,
                index === group.entries.length - 1
                  ? CARD_OUTER_RADIUS : CARD_INNER_RADIUS)
            }
            .padding({ bottom: 2 })
            .swipeAction({
              end: {
                builder: () => {
                  this.swipeDelete(entry)
                }
              }
            })
          }
        }, (entry: HistoryEntry) => `${entry.key()}:${this.editing}`)
      /**
       * 分组 key 必须带上**组内内容**，不能只用日期。
       *
       * ArkUI 的 `ForEach` 只对 **key 变化**的项重跑 itemGenerator；key 没变就
       * 直接复用旧节点、连里面的 `ForEach` 都不会重新求值。原来这里只写
       * `${group.dayStartMs}`，于是在同一天里删掉一张卡片时，外层 key 没变
       * → 内层那个 ForEach 仍指向**旧的 entries** → 卡片留在屏幕上不消失
       * （用户 2026-09-18：「历史记录里删除，番剧不会即时消失」）。
       * 只有把当天**最后一条**删掉（整组消失）或重新进页面，才会刷新——
       * 这也解释了为什么感觉「有时候删得掉、有时候删不掉」。
       *
       * 签名里放 条数 + 首条 + 末条：增删、换序都会让签名变化。
       */
      }, (group: HistoryDateGroup) => HistoryPage.groupSignature(group))

      // 搜不到时**不能换成整页空态**：搜索栏本身在列表里，换掉它用户就没法清空关键词了。
      // 所以提示放进列表内部，搜索栏原地不动。
      if (this.groups.length === 0) {
        ListItem() {
          this.noResultHint()
        }
      }

      ListItem() {
        Column() {
          Blank().height(24 + Dimens.contentBottomSpacer)
        }
      }
    }
    .layoutWeight(1)
    .width('100%')
    // 顶部不留内边距：让位由第一项（占位 ListItem）负责，
    // 否则列表会在标题下方就裁掉内容，滚不到标题后面去。
    .padding({ left: Dimens.contentInset, right: Dimens.contentInset })
    .scrollBar(BarState.Off)
  }

  @Builder
  groupHeader(group: HistoryDateGroup) {
    Row() {
      Text(group.label)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.onSurface)
        .layoutWeight(1)
      Text(`${group.entries.length} 条`)
        .fontSize(14)
        .fontColor(AppColor.onSurfaceVariant)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 24, bottom: 12 })
  }

  /** 滑动删除的红色底（§51.2 的 `Dismissible` 背景）。 */
  @Builder
  swipeDelete(entry: HistoryEntry) {
    Row() {
      Blank().layoutWeight(1)
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(22)
        .fontColor([AppColor.onErrorContainer])
        .margin({ right: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.errorContainer)
    .borderRadius(CARD_OUTER_RADIUS)
    .onClick(() => {
      this.remove(entry);
    })
  }

  /**
   * 一条记录卡片。
   *
   * 与参照实现的差异：宽屏（≥600）时海报 72×100.8，原生版手机是主场景，
   * 统一用 60×84；其余（文案、色板、按钮形状）逐条对齐。
   */
  @Builder
  historyCard(entry: HistoryEntry, topRadius: number, bottomRadius: number) {
    Row() {
      // 海报
      // ⚠️ 与详情页海报同址（`coverUrl()`）——共享元素两端必须同一个 URL，
      // 改成缩略档会让飞行途中目标端没图可画（2026-09-20 已回退一次）。
      if (entry.bangumiItem.coverUrl().length > 0) {
        CoverImage({
          src: entry.bangumiItem.coverUrl(),
          fit: ImageFit.Cover,
          radius: 12
        })
          .width(60)
          .height(84)
          .draggable(false)
          // Hero 共享元素（§38.7）：历史卡片封面 → 详情页海报
          .geometryTransition(HeroFlight.tag('history', entry.bangumiItem.id))
            .onAreaChange((oldValue: Area, newValue: Area) => {
              HeroRects.setCard(HeroFlight.tag('history', entry.bangumiItem.id), newValue);
            })
            .zIndex(1)
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.film'))
            .fontSize(22)
            .fontColor([AppColor.onSurfaceVariant])
        }
        .width(60)
        .height(84)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(AppColor.surfaceContainerHighest)
        .borderRadius(12)
      }

      Blank().width(16)

      Column() {
        Text(this.titleOf(entry))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.onSurface)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.episodeOf(entry))
          .fontSize(14)
          .fontColor(AppColor.onSurfaceVariant)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 6 })
        if (this.positionOf(entry).length > 0) {
          Text(this.positionOf(entry))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.primary)
            .maxLines(1)
            .width('100%')
            .margin({ top: 4 })
        }
        Text(this.metaOf(entry))
          .fontSize(12)
          .fontColor(AppColor.onSurfaceVariant)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 8 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .constraintSize({ minHeight: 32 })

      Blank().width(8)

      // 右侧动作：编辑模式只留删除；平时是「继续播放 + 更多」
      if (this.busyKey === entry.key()) {
        Column() {
          LoadingIndicator({ sizeVp: 24 })
        }
        .width(48)
        .height(48)
        .justifyContent(FlexAlign.Center)
      } else if (this.editing) {
        Column() {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(20)
            .fontColor([AppColor.onErrorContainer])
        }
        .width(48)
        .height(48)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(AppColor.errorContainer)
        .borderRadius(24)
        .onClick(() => {
          this.remove(entry);
        })
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(22)
            .fontColor([AppColor.onPrimaryContainer])
        }
        .width(48)
        .height(48)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(AppColor.primaryContainer)
        .borderRadius(24)
        .onClick(() => {
          this.play(entry);
        })

        Column() {
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(22)
            .fontColor([AppColor.onSurfaceVariant])
        }
        .width(48)
        .height(48)
        .justifyContent(FlexAlign.Center)
        .margin({ top: 4 })
        // 原生菜单：挂在内置容器（Column）上，且不写空 onClick
        .bindMenu(this.historyMenu(entry), {
          placement: Placement.BottomRight
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(16)
    .backgroundColor(AppColor.surfaceContainerLow)
    .borderRadius({
      topLeft: topRadius,
      topRight: topRadius,
      bottomLeft: bottomRadius,
      bottomRight: bottomRadius
    })
    .onClick(() => {
      if (!this.editing && this.busyKey.length === 0) {
        // 整卡点击 → 详情页（用户 2026-09-17 要求）。
        // 详情页用同一个 `HeroFlight.tag('history', id)`，封面共享元素转场生效；
        // 「继续播放」保留在右侧那个播放圆钮上，不用先进详情页再点一次。
        this.openDetails(entry);
      }
    })
  }

  /**
   * 卡片「更多」菜单：番剧详情 / 收藏（五个分类，当前项打勾）/ 删除记录。
   *
   * 参照实现是 `MenuAnchor` + `SubmenuButton`（收藏是二级子菜单）。
   * 原生 ArkUI 菜单不做二级，这里按 HarmonyOS 自己的做法**平铺成分组**：
   * 收藏五项直接展开在 `MenuItemGroup({ header: '收藏' })` 里——
   * 少一次点击，也避免「菜单里再弹菜单」。
   *
   * 2026-09-17 起改用原生 `bindMenu`（此前是自绘浮层）：
   * 自绘是「`bindMenu` 不展开」时代的将就方案；后来确认可用条件是
   * **挂在内置容器上、且不要挂空 `onClick`**（同 `CollectPage.statusMenu`）。
   * 换成原生后毛玻璃底、圆角、投影、出现动画、点击外部关闭、
   * 按键与读屏语义全部由系统给。
   */
  @Builder
  historyMenu(entry: HistoryEntry) {
    Menu() {
      MenuItem({ content: '番剧详情', startIcon: $r('sys.symbol.info_circle') })
        .onClick(() => {
          this.openDetails(entry);
        })

      MenuItemGroup({ header: this.collectLabel(entry) === '未收藏'
        ? '收藏' : `收藏 · ${this.collectLabel(entry)}` }) {
        ForEach(COLLECT_TYPES, (type: CollectType) => {
          if (this.currentCollectType(entry) === type.value) {
            MenuItem({ content: type.label, endIcon: $r('sys.symbol.checkmark') })
              .onClick(() => {
                this.changeCollect(entry, type.value);
              })
          } else {
            MenuItem({ content: type.label })
              .onClick(() => {
                this.changeCollect(entry, type.value);
              })
          }
        }, (type: CollectType) => `history-collect-${type.value}`)
      }

      MenuItem({ content: '删除记录', startIcon: $r('sys.symbol.trash') })
        .contentFontColor(AppColor.error)
        .onClick(() => {
          this.remove(entry);
        })
    }
  }

  /**
   * 搜索无结果提示（列表内部，搜索栏保持可见）。
   */
  @Builder
  noResultHint() {
    Column() {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(40)
        .fontColor([AppColor.onSurfaceVariant])
      Text('没有找到相关记录')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.onSurface)
        .margin({ top: 16 })
      Text('换个关键词试试')
        .fontSize(13)
        .fontColor(AppColor.onSurfaceVariant)
        .margin({ top: 8 })
      Text('清除搜索')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.onSecondaryContainer)
        .padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .backgroundColor(AppColor.secondaryContainer)
        .borderRadius(20)
        .margin({ top: 20 })
        .onClick(() => {
          this.resetFilters();
        })
    }
    .width('100%')
    .padding({ top: 80, bottom: 32 })
    .justifyContent(FlexAlign.Center)
  }

  /** 一条记录都没有时的整页空态。 */
  @Builder
  emptyState() {
    Column() {
      // §46.4：`history_rounded` → `clock_arrow_2_circlepath`
      SymbolGlyph($r('sys.symbol.clock_arrow_2_circlepath'))
        .fontSize(44)
        .fontColor([AppColor.onSurfaceVariant])
      Text('还没有观看记录')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.onSurface)
        .margin({ top: 16 })
      Text('播放一集后，这里会按时间倒序列出看过的番剧与集数')
        .fontSize(13)
        .fontColor(AppColor.onSurfaceVariant)
        .margin({ top: 8 })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: Dimens.contentInset * 2, right: Dimens.contentInset * 2 })
  }
}

/**
 * 通用确认对话框（对应参照实现的 `AlertDialog` +「取消 / 确认」）。
 *
 * 确认按钮用 `error` 配色：这个对话框在历史页只用于删除类操作。
 */
@CustomDialog
struct ConfirmDialog {
  controller: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialog({
      title: '',
      message: '',
      confirmLabel: '确定',
      onConfirm: () => {
      }
    })
  });
  title: string = '';
  message: string = '';
  confirmLabel: string = '确定';
  onConfirm: () => void = () => {
  };

  build() {
    Column({ space: 16 }) {
      Row() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(22)
          .fontColor([AppColor.error])
        Blank().width(10)
        Text(this.title)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.onSurface)
          .layoutWeight(1)
      }
      .width('100%')

      Text(this.message)
        .fontSize(14)
        .fontColor(AppColor.onSurfaceVariant)
        .width('100%')

      Row({ space: 12 }) {
        Button('取消')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .fontColor(AppColor.onSurfaceVariant)
          .onClick(() => {
            this.controller.close();
          })
        Button(this.confirmLabel)
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor(AppColor.error)
          .fontColor(AppColor.onError)
          .onClick(() => {
            this.onConfirm();
            this.controller.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(24)
  }
}
