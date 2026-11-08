import { AppColor } from '../theme/AppColors';
import { AppMaterial } from '../theme/Material';
import { Dimens, Motion, AppCurves, HeroFlight } from '../theme/Tokens';
import { MotionRuntime } from '../theme/MotionRuntime';
import { BangumiApi } from '../api/BangumiApi';
import { BangumiItem } from '../model/BangumiItem';
import { display } from '@kit.ArkUI';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';
import { CoverImage } from '../components/CoverImage';
import { CollectEntry, CollectStore } from '../services/collect/CollectStore';
import {
  AnimeSeasonRange,
  isSameSeason,
  seasonLabel
} from '../utils/SearchDates';
import { Viewport } from '../utils/Viewport';
import { InfoRouteArgs } from '../router/RouteArgs';
import { HeroRects } from '../router/HeroRects';
import { LoadingIndicator } from '../components/LoadingIndicator';

/**
 * 日期标签的高度（vp）——与源码 `_TimelineWeekSelector.heightFor` 对齐：
 * `40 + scale(20) + scale(16)` = 76，再减掉外层 4vp 的上下内边距 → 68。
 */
const DAY_TAB_HEIGHT: number = 68;
/**
 * 顶部两个胶囊的高度（vp）。
 *
 * 用户 2026-09-18 反馈「顶部按钮占了很大一块、把日期栏和列表挤下去」：
 * 原来是 50，收到 **44**——HarmonyOS 悬浮控件的常见档位（HDS chip 32 +
 * 12 的内边距），触控热区仍在 44 以上，不影响可点性。
 */
const HEADER_CHIP_HEIGHT: number = 44;

/**
 * 时间表页。对应参照实现 lib/pages/timeline/timeline_page.dart。
 *
 * 实测结构（模拟器）：
 *   季度切换按钮 [48,177][637,303]
 *   排序筛选按钮 [667,165][1036,315]
 *   日期标签行 y 348–546，每标签宽 168，横向可滚动，共 7 个
 *   番剧卡片宽 988、高 432，卡间距 36
 *
 * 本期先落地骨架与日期标签行，卡片数据与筛选后续接入。
 */
@Component
export struct TimetablePage {
  @State selectedDay: number = 0;
  /** 7 天 × 当天的番剧（下标与 this.days 对齐）。 */
  @State week: BangumiItem[][] = [];
  @State loadState: string = '未加载';
  /** 内容区实测宽度：用于规格 §5.1 的列数公式。 */
  @State contentWidth: number = 0;
  /** 选中季度所在的时间点（毫秒）。默认当前。 */
  @State selectedDateMs: number = Date.now();
  /** 实测可用宽度（横屏/平板要扣掉侧边导航栏）。 */
  @State viewportWidth: number = 0;
  /** 排序：0 热度 / 1 评分 / 2 默认（对应 `TimelineSort`）。 */
  @State sortIndex: number = 0;
  @State notShowWatched: boolean = false;
  @State notShowAbandoned: boolean = false;
  @State onlyShowWatching: boolean = false;
  /**
   * 两个下拉菜单的展开态。
   *
   * 2026-09-17 起由自绘 `RevealMenu`（按进度截断高度复刻 Flutter 的
   * `heightFactor`）换成 **HarmonyOS 原生菜单**：原生菜单自带毛玻璃、圆角、
   * 投影、出现动画、点击外部关闭与按键语义，也不再需要「节点挂载/卸载 +
   * 播放收起动画」这套状态机。
   */
  @State private seasonMenuOpen: boolean = false;
  @State private optionsMenuOpen: boolean = false;
  @State showRating: boolean = true;
  @State loading: boolean = false;
  @StorageProp('topInset') topInset: number = 39;
  /**
   * 收藏变更版本号（`CollectStore` 每次写盘 +1）。
   *
   * 时间表受两处影响：「只看在追」筛选与卡片上的「在追」标记都**每次 build 现读**
   * `CollectStore`（`filtered()` / `isWatching()`）。在播放页改了状态回到这里时，
   * 页面不会重建，得靠这颗计数把它踢一次。
   */
  @StorageProp('collectRevision') @Watch('onCollectChanged') collectRevision: number = 0;
  /** 收藏变更后自增：`filtered()` 读它注册依赖（同 `CollectPage.revision` 的写法）。 */
  @State private collectTick: number = 0;
  /** 主题版本：由 Index 下发，@Prop 变化会让本组件整体重跑 build。 */
  @Prop themeRev: number = 0;
  /** 滚动上报（导航条弹入弹出 + 末尾回弹判定），见 `NavScrollController`。 */
  onScrollOffset: (offset: number, maxOffset: number) => void = () => {
  };
  @State private contentHeight: number = 0;
  @State private viewportHeight: number = 0;
  /**
   * 日期分页控制（`weekPager()` 用的原生 `Swiper`）。
   *
   * 点日期标签时用它带动画滑过去；换季后用它把下标**不带动画**地落位。
   */
  private weekPager: SwiperController = new SwiperController();
  /**
   * 内容滚动容器。
   *
   * ⚠️ `onDidScroll` 的第二个参数是 **`ScrollState`（0/1/2）**，不是 yOffset——
   * 直接把它当偏移上报，`NavScrollController` 里的 delta 几乎恒为 0，
   * 底部导航条就永远不会隐藏（用户 2026-09-18：「时间表下滑时导航胶囊
   * 也和在推荐页表现一样」）。偏移必须从 `Scroller.currentOffset()` 读，
   * 推荐页就是这么写的。
   */
  private contentScroller: Scroller = new Scroller();
  private readonly days: string[] = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
  private readonly dayShort: string[] = ['一', '二', '三', '四', '五', '六', '日'];
  private readonly sortLabels: string[] = ['热度优先', '评分优先', '默认顺序'];

  aboutToAppear(): void {
    this.contentWidth = TimetablePage.measureContentWidth();
    const today: Date = new Date();
    this.selectedDay = (today.getDay() + 6) % 7;
    this.notShowWatched =
      SettingsStore.getBool(SettingsKeys.timelineNotShowWatchedBangumis);
    this.notShowAbandoned =
      SettingsStore.getBool(SettingsKeys.timelineNotShowAbandonedBangumis);
    this.onlyShowWatching =
      SettingsStore.getBool(SettingsKeys.timelineOnlyShowWatchingBangumis);
    this.showRating = SettingsStore.getBool(SettingsKeys.showRating);
    this.loadSeason(today);
  }

  /**
   * 收藏变了：踢一次计数让 build 重跑。
   *
   * 「只看在追」的筛选与「在追」标记本身就是现读 `CollectStore` 的，
   * 所以这里不需要重新拉数据——`filtered()` / `isWatching()` 会在重绘时自己算对。
   */
  private onCollectChanged(): void {
    this.collectTick += 1;
  }

  /**
   * 规格 §5.1 的 contentWidth：`(maxWidth - sidePadding*2).clamp(0, 1280)`，
   * `sidePadding = maxWidth < 600 ? 16 : 24`。
   *
   * 用窗口宽度直接算，而不是等 `onAreaChange`——后者首次回调给的宽度偏小，
   * 会让列数算成 1（实测：1084 宽屏幕只排一列，卡片撑满整行）。
   */
  private static measureContentWidth(): number {
    try {
      const info = display.getDefaultDisplaySync();
      const widthVp: number = info.width / info.densityPixels;
      const sidePadding: number = widthVp < 600 ? 16 : 24;
      const content: number = widthVp - sidePadding * 2;
      return Math.max(0, Math.min(content, 1280));
    } catch (e) {
      return 0;
    }
  }

  /**
   * 载入某个季度（对应参照实现 `TimelineController.loadSeason`）。
   *
   * 本季走官方日历；其它季度走镜像季番日历，参数是**上一季起点 → 本季起点**
   * （见 `AnimeSeasonRange`）。载入后按当前排序重排（源码同样在载入后 `changeSort`）。
   */
  private async loadSeason(date: Date): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.loadState = '加载中…';
    this.selectedDateMs = date.getTime();
    this.week = [];
    try {
      const current: Date = new Date();
      const week: BangumiItem[][] = isSameSeason(date, current)
        ? await BangumiApi.getCalendar()
        : await BangumiApi.getBangumiMirrorSeasonCalendar(AnimeSeasonRange.of(date));
      this.week = week;
      this.applySort();
      let total: number = 0;
      for (let i = 0; i < week.length; i++) {
        total += week[i].length;
      }
      this.loadState = total === 0
        ? '该季度暂无数据' : `已加载 ${total} 部`;
    } catch (e) {
      const err = e as Error;
      this.loadState = `加载失败：${err.message}`;
    }
    this.loading = false;
    /**
     * 换季之后把分页下标落到新季的第一帧上（不带动画）。
     *
     * `.index(this.selectedDay)` 只在挂载时生效，换季是原地替换内容、不重挂，
     * 所以这里显式同步一次；`selectedDay` 没变时是空操作。
     */
    try {
      this.weekPager.changeIndex(this.selectedDay, false);
    } catch (e) {
      // 分页还没挂载时忽略
    }
  }

  /** 排序（参照实现 `changeSort`：热度=votes 降序 / 评分=rating 降序 / 默认=id 升序）。 */
  private applySort(): void {
    const sorted: BangumiItem[][] = [];
    for (let day = 0; day < this.week.length; day++) {
      const list: BangumiItem[] = this.week[day].slice();
      list.sort((a: BangumiItem, b: BangumiItem) => {
        if (this.sortIndex === 1) {
          return b.ratingScore - a.ratingScore;
        }
        if (this.sortIndex === 2) {
          return a.id - b.id;
        }
        return b.votes - a.votes;
      });
      sorted.push(list);
    }
    this.week = sorted;
  }

  /** 收藏状态过滤（参照实现 `filterCalendar`）。 */
  private filtered(day: number): BangumiItem[] {
    // 读一次 collectTick 注册依赖：在播放页改了「在看」之后，这一层要重算
    const tick: number = this.collectTick;
    if (tick < 0) {
      return [];
    }
    if (day >= this.week.length) {
      return [];
    }
    const hiddenIds: number[] = [];
    if (this.notShowWatched) {
      TimetablePage.pushIds(hiddenIds, CollectStore.listByType(4));
    }
    if (this.notShowAbandoned) {
      TimetablePage.pushIds(hiddenIds, CollectStore.listByType(5));
    }
    const watchingIds: number[] = [];
    TimetablePage.pushIds(watchingIds, CollectStore.listByType(1));
    return this.week[day].filter((item: BangumiItem) =>
      hiddenIds.indexOf(item.id) < 0 &&
        (!this.onlyShowWatching || watchingIds.indexOf(item.id) >= 0));
  }

  private static pushIds(out: number[], entries: CollectEntry[]): void {
    for (let i = 0; i < entries.length; i++) {
      out.push(entries[i].id);
    }
  }

  /** 生效中的筛选数量（右上角角标）。 */
  private activeFilterCount(): number {
    let count: number = 0;
    if (this.notShowWatched) {
      count++;
    }
    if (this.notShowAbandoned) {
      count++;
    }
    if (this.onlyShowWatching) {
      count++;
    }
    return count;
  }

  private seasonText(): string {
    return seasonLabel(new Date(this.selectedDateMs));
  }

  /**
   * 切到上 / 下一季（季度步进 = 3 个月，因为季度起点就是 1/4/7/10 月 1 日）。
   *
   * 「看不了全年」的第二个原因是**只能从菜单里挑**：想从冬季走到秋季要点开
   * 菜单两次。这里给两侧箭头做步进——按住连点就能把一年四季走一遍。
   * 不往前走：未来季度还没有数据，直接忽略。
   */
  private stepSeason(delta: number): void {
    const current: Date = new Date(this.selectedDateMs);
    const next: Date =
      new Date(current.getFullYear(), current.getMonth() + delta * 3, 1);
    if (next.getTime() > Date.now()) {
      /**
       * 之前这里是**静默 return**——点「下一季」没反应，用户看到的就是
       * 「10 月番没有数据」（2026-09-18 实测：镜像 `calendar/season?
       * start=2026-10-01&end=2027-01-01` 返回 200 但 7 天全是空数组，
       * 上游还没收录秋季新番；本季 7 月那季有 72 部）。
       *
       * 所以这里改成明确告知：把「点不动」变成「还没开播，所以没数据」。
       */
      this.showTip(`${seasonLabel(next)}的新番还没有开播，暂无数据`);
      return;
    }
    this.loadSeason(next);
  }

  /**
  /**
   * 点日期标签切日。
   *
   * 手滑那一路交给 `Swiper` 自己（见 `content()`），这里只负责「点哪格就带
   * 动画滑到哪一格」——所以用 `changeIndex(index, true)`，方向自然是从当前
   * 这页朝目标那页走。
   */
  private selectDay(day: number): void {
    if (day === this.selectedDay) {
      return;
    }
    this.selectedDay = day;
    try {
      this.weekPager.changeIndex(day, true);
    } catch (e) {
      // 分页还没挂载（首帧）时忽略即可，index 属性会在挂载时对齐
    }
  }

  /** 下一季（delta=+1）/ 上一季（delta=-1）是否已经开始——没开始就没有数据。 */
  private seasonStepEnabled(delta: number): boolean {
    const current: Date = new Date(this.selectedDateMs);
    const next: Date =
      new Date(current.getFullYear(), current.getMonth() + delta * 3, 1);
    return next.getTime() <= Date.now();
  }

  private todayIndex(): number {
    return isSameSeason(new Date(this.selectedDateMs), new Date())
      ? (new Date().getDay() + 6) % 7 : -1;
  }

  private showTip(title: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: title });
    } catch (e) {
      // 提示失败不影响主流程
    }
  }

  /**
   * 规格 §5.1 的列数公式：
   *   minCardWidth = 340（textScaler 放大时 440，这里先按默认缩放）
   *   columns = floor((contentWidth + 12) / (minCardWidth + 12))，夹在 1..3
   */
  private columnsTemplate(): string {
    const columns: number = this.columnCount();
    const parts: string[] = [];
    for (let i = 0; i < columns; i++) {
      parts.push('1fr');
    }
    return parts.join(' ');
  }

  /** 列数（规格 §5.1，夹在 1..3）。 */
  private columnCount(): number {
    let columns: number = Math.floor((this.contentWidth + 12) / (340 + 12));
    if (columns < 1) {
      columns = 1;
    }
    if (columns > 3) {
      columns = 3;
    }
    return columns;
  }

  /**
   * Grid 在 Scroll 里高度不受约束，不给显式高度就只排第一行。
   * 卡片高 ≈ 列宽 / 0.72（海报比例）+ 文本区 76。
   *
   * 按**指定的那一天**算——分页里 7 页各算各的（原来只按 `selectedDay` 算，
   * 分成 7 页之后那样 7 页会拿到同一个高度）。
   */
  private gridHeightFor(day: number): number {
    const items: number = this.filtered(day).length;
    const columns: number = this.columnCount();
    const rows: number = Math.ceil(items / columns);
    return rows * this.cardHeight() + (rows > 0 ? (rows - 1) * 12 : 0) + 8;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      /**
       * 背景 = **与推荐页同一层**（2026-09-18 用户：「背景与推荐页相同」）。
       *
       * 这里原本铺了一整页渐变（primaryContainer 42% → tertiaryContainer 18% → 透明），
       * 把 Index 那层 `AppBackground`（自定义背景图 + 遮罩）整个盖住了，
       * 所以两个 Tab 的底色完全不一样。去掉之后，本页和推荐页共用同一套背景，
       * 用户的壁纸/纯色主题在四个 Tab 上是连续的。
       */

      Scroll(this.contentScroller) {
        Column() {
          this.content()
          Blank().height(Dimens.contentBottomSpacer)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: this.headerBlockHeight() })
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
      /**
       * 这里**不再挂横向 `PanGesture`**（2026-09-18 第三次调整）。
       *
       * 左右切日期已经完全交给内容区那个原生 `Swiper`（见 `weekPagerView`），
       * 它自己会跟手、吸附、并在头尾回弹。如果这里再挂一层横向手势，两者会
       * 抢同一次拖动（Swiper 已经吃掉了这个 pan），就会出现「滑一次跳两格」
       * 或者跨季的手感；竖向滚动仍然归这个 `Scroll`，两边方向不同，不冲突。
       */
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const h: number = Number(newValue.height);
        if (h > 0 && h !== this.viewportHeight) {
          this.viewportHeight = h;
        }
      })
      .onDidScroll(() => {
        // 从 Scroller 读真实偏移（第二个参数是 ScrollState，见字段注释）
        const offset: number = this.contentScroller.currentOffset().yOffset;
        const reachable: number = this.contentHeight - this.viewportHeight;
        this.onScrollOffset(offset, reachable > 0 ? reachable : 0);
      })

      // 悬浮头部：季度胶囊 + 排序筛选胶囊（对应源码 Positioned(top: statusTop + 16)）
      Column() {
        this.header()
        this.dayStrip()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: this.topInset + 16 })

    }
    .width('100%')
    .height('100%')
    // 响应式：内容宽按实测可用宽度算（横屏 / 平板左侧有 88vp 导航栏）。
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width: number = Number(newValue.width);
      if (width <= 0 || Math.abs(width - this.viewportWidth) < 0.5) {
        return;
      }
      this.viewportWidth = width;
      const sidePadding: number = width < 600 ? 16 : 24;
      this.contentWidth = Math.min(1280, Math.max(0, width - sidePadding * 2));
    })
  }

  /**
   * 头部块总高：季度胶囊 50 + 间距 6 + 日期选择器 76，
   * 加上 statusTop 与 16 的上边距——内容区据此让位，卡片才能滚到胶囊之下。
   */
  private headerBlockHeight(): number {
    return this.topInset + 16 + 50 + 6 + 76;
  }

  /** `#AARRGGBB` → 换掉 alpha 通道（渐变层用）。 */
  private static fade(color: string, alphaHex: string): string {
    return color.length >= 9 ? `#${alphaHex}${color.substring(3)}` : color;
  }

  private screenWidthVp(): number {
    return Viewport.widthVp(this.viewportWidth);
  }

  @Builder
  header() {
    Row() {
      Row() {
        /**
         * 季度胶囊改成 `< [2026年7月 ▾] >` 三段式（2026-09-18）。
         * 标签用**季度起点月份**（1/4/7/10 月），不再用「冬季/秋季」季名——
         * 未来的季度不会列进菜单，用月份表述一眼就能看出「这个季度从几月开始」。
         *
         * 中间那段的文字仍然点开季度菜单（按年份分组）；两侧箭头直接步进
         * 上一季 / 下一季——「看不了全年」的体感有一半来自「只能开菜单挑」。
         */
        this.seasonStepButton(-1)
        Text(this.seasonText())
          /**
           * **一行显示**（用户 2026-09-18：「2026年冬季这种能在胶囊里以一行
           * 显示嘛」）。
           *
           * 原来没有限行：`2026年冬季` 在 360vp 屏上算下来需要约 86vp，
           * 而胶囊被两侧箭头（各 44）和下拉箭头挤掉之后只剩 ~88vp，
           * 于是一碰就折成两行、溢出 44 高的胶囊。这里三件事一起做：
           *   1. 箭头热区 44 → 36（胶囊整体仍是 44 高，垂直方向的热区不变）；
           *   2. 下拉箭头 20 → 18；
           *   3. 字号 16 → 15，并显式限一行 + 省略号兜底。
           * 现在 360vp 屏上可用宽度约 108vp，装得下整串。
           */
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.onSurface)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(18)
          .fontColor([AppColor.onSurfaceVariant])
        this.seasonStepButton(1)
      }
      .layoutWeight(1)
      .height(HEADER_CHIP_HEIGHT)
      .padding({ left: 4, right: 4 })
      .borderRadius(22)
      // 季度胶囊浮在列表之上 → 材质可见
      .backgroundBlurStyle(AppMaterial.capsule, AppMaterial.options())
      .backgroundColor(AppColor.glassCapsuleFill)
      .border({ width: 1, color: AppColor.glassBorder })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.seasonMenuOpen = true;
      })
      // 原生菜单：挂在内置容器（Row）上，且不写空 onClick（本工程实测的可用组合）
      .bindMenu(this.seasonMenuOpen, this.seasonMenu, {
        placement: Placement.BottomLeft,
        onDisappear: () => {
          this.seasonMenuOpen = false;
        }
      })

      Row() {
        // §46.4：`tune_rounded` → `slider_horizontal_2`
        SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
          .fontSize(18)
          .fontColor([AppColor.onSurface])
        Text(this.sortLabels[this.sortIndex])
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.onSurface)
          .margin({ left: 8 })
        if (this.activeFilterCount() > 0) {
          Text(`${this.activeFilterCount()}`)
            .fontSize(11)
            .fontColor(AppColor.onPrimary)
            .backgroundColor(AppColor.primary)
            .borderRadius(9)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .margin({ left: 6 })
        }
      }
      .height(HEADER_CHIP_HEIGHT)
      .padding({ left: 16, right: 16 })
      .borderRadius(22)
      .backgroundBlurStyle(AppMaterial.capsule, AppMaterial.options())
      .backgroundColor(AppColor.glassCapsuleFill)
      .border({ width: 1, color: AppColor.glassBorder })
      .margin({ left: 10 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.optionsMenuOpen = true;
      })
      .bindMenu(this.optionsMenuOpen, this.optionsMenu, {
        placement: Placement.BottomRight,
        onDisappear: () => {
          this.optionsMenuOpen = false;
        }
      })
    }
    .width('100%')
    .padding({ left: Dimens.contentInset, right: Dimens.contentInset })
  }

  @Builder
  dayStrip() {
    Column() {
      // 规格 §5.2 `_TimelineWeekSelector`：最小标签宽 clamp(14*2+16, 48, 112)，
      // 7 个标签放不下时整体横向可滚动（361vp 宽的模拟器正落在这个分支）。
      Scroll() {
        /**
         * 选中指示**整条只画一个**，按选中日弹性滑过去。
         *
         * 对应源码 `timeline_week_selector.dart` 的 TabBar：
         *   `indicator: BoxDecoration(color: colors.primary, borderRadius: 24)`
         *   `+ indicatorAnimation: TabIndicatorAnimation.elastic`
         * 形状与源码完全一致（整格主色 + 圆角 24），差别只在它是「滑」过去的，
         * 而不是每格突然长出一块——2026-09-18 用户反馈的那个「像贴了块补丁」
         * 的观感就来自这里。
         *
         * 格子宽度全都等于 `dayTabWidth()`，所以位移可以直接用
         * `选中下标 × 格宽` 算，不需要逐个量几何。
         */
        Stack({ alignContent: Alignment.TopStart }) {
          Row()
            .width(this.dayTabWidth())
            .height(DAY_TAB_HEIGHT)
            .borderRadius(24)
            .backgroundColor(AppColor.primary)
            .translate({ x: this.selectedDay * this.dayTabWidth() })
            // 弹簧曲线 = 源码的 elastic（带一点过冲，滑到位有回稳）
            .animation({
              duration: MotionRuntime.ms(Motion.normal),
              curve: AppCurves.springSheet()
            })

          Row() {
            ForEach([0, 1, 2, 3, 4, 5, 6], (index: number) => {
              Column() {
                Text(index === this.todayIndex() ? '今天' : `周${this.dayShort[index]}`)
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(index === this.selectedDay
                    ? AppColor.onPrimary : AppColor.onSurfaceVariant)
                Text(this.loading || this.week.length === 0
                  ? '—' : `${this.filtered(index).length}`)
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(index === this.selectedDay
                    ? AppColor.onPrimary : AppColor.onSurfaceVariant)
                  .margin({ top: 4 })
              }
              .width(this.dayTabWidth())
              .height(DAY_TAB_HEIGHT)
              .justifyContent(FlexAlign.Center)
              .onClick(() => {
                this.selectDay(index);
              })
            }, (index: number) => `day-${index}`)
          }
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(76)
      .padding(4)
      .borderRadius(28)
      .backgroundBlurStyle(AppMaterial.card, AppMaterial.options())
      .backgroundColor(AppColor.glassCardFill)
      .border({ width: 1, color: AppColor.glassBorder })
      .clip(true)
    }
    .width('100%')
    .padding({ left: Dimens.contentInset, right: Dimens.contentInset })
    .margin({ top: 6 })
  }

  /**
   * 上一季 / 下一季按钮：36×44 的热区，图标 18。
   *
   * 宽度从 44 收到 36 是给中间的季度文字让位（见 `header()` 里那条注释），
   * 高度仍是 44（胶囊高度），所以纵向热区没变小。
   */
  @Builder
  seasonStepButton(delta: number) {
    Row() {
      SymbolGlyph($r(delta < 0
        ? 'sys.symbol.arrow_left' : 'sys.symbol.arrow_right'))
        .fontSize(18)
        .fontColor([AppColor.onSurfaceVariant])
    }
    .width(36)
    .height(HEADER_CHIP_HEIGHT)
    .justifyContent(FlexAlign.Center)
    /**
     * 目标季度还没开播时**变淡**（不是变灰不可点）：点它仍然会给出
     * 「……还没有开播，暂无数据」的提示，只是先一步说明「这里现在没有东西可看」。
     * 之前这个箭头在季末是完全无反馈的死按钮（用户 2026-09-18：「10 月番
     * 都没有数据」说的就是它）。
     */
    .opacity(this.seasonStepEnabled(delta) ? 1 : 0.35)
    .onClick(() => {
      this.stepSeason(delta);
    })
  }

  /** 单个星期标签宽：放得下就等分，放不下就按最小 48vp（配合横向滚动）。 */
  private dayTabWidth(): number {
    const available: number = this.screenWidthVp() - Dimens.contentInset * 2 - 8;
    return Math.max(48, available / 7);
  }

  @Builder
  content() {
    Column() {
      Text(this.loadState).fontSize(12)
        .fontColor(AppColor.onSurfaceVariant)
        .width('100%')
        /**
         * 加载状态行的留白（2026-09-18）：原来紧贴日期栏下缘，视觉上很挤。
         * 上面给 4vp、下面给 10vp，让它和日期栏、第一张卡片都拉开一点，
         * 同时保持与内容相同的左右内缩。
         */
        .padding({ left: Dimens.contentInset, top: 4, bottom: 10 })
      this.weekPagerView()
    }
    .width('100%')
  }

  /**
   * 日期内容：原生 `Swiper` 的 7 页，一天一页。
   *
   * 2026-09-18 的第三次调整。前两版都是自绘：外面挂 `PanGesture` 认方向，
   * 内容做 40vp 的进出场 `transition`。用户两次的反馈是「感觉现在的反了」
   * → 「就改成正常的左右滑动就好」。
   *
   * 问题不在符号写反，而在那套写法**本来就不叫滑动**：`PanGesture` 只在
   * `onActionEnd` 里拿到 `offsetX`，拖动过程中画面不动、松手后才补一段动画，
   * 「跟手 → 吸附」的因果是断的；退场那一块读的还是它上一次 build 时的
   * `dayShiftSign`，与这一次的滑动方向未必一致，方向感自然会飘。
   *
   * 换成 `Swiper` 之后这些都不需要自己定义：拖动跟手、松手按速度吸附、拖一半
   * 能改主意，方向由系统按「往左拖 = 后一天从右边进来」处理，也就是用户说的
   * 「正常的左右滑动」。时长走项目 Token（`Motion.normal` = 250ms，对应公开
   * 参考里「短距离运动 ≈250ms」这一档），一周的头尾用系统回弹。
   *
   * 页高取**当前这一天**的高度：各天条目数差得多（实测 7 月那季是
   * 8/5/11/8/14/14/12），取最大值会让条目少的那天在几百 vp 的空白里结束滚动。
   */
  @Builder
  weekPagerView() {
    Swiper(this.weekPager) {
      ForEach([0, 1, 2, 3, 4, 5, 6], (day: number) => {
        this.dayPage(day)
      }, (day: number) => `day-page-${day}`)
    }
    // 一周就是一周：滑到周日再往左不绕回周一，跨季交给季度胶囊的两个箭头
    .loop(false)
    .index(this.selectedDay)
    .indicator(false)
    .cachedCount(1)
    .duration(MotionRuntime.ms(Motion.normal))
    .curve(AppCurves.easeOutCubic())
    .effectMode(EdgeEffect.Spring)
    .width('100%')
    .height(this.pagerHeight())
    .onChange((index: number) => {
      if (index !== this.selectedDay) {
        this.selectedDay = index;
      }
    })
  }

  /** 某一天的一页：加载态 / 卡片网格 / 空态。 */
  @Builder
  dayPage(day: number) {
    Column() {
      if (this.loading) {
        Row() {
          LoadingIndicator({ sizeVp: 32 })
        }
        .width('100%')
        .height(200)
        .justifyContent(FlexAlign.Center)
      } else if (this.filtered(day).length > 0) {
        Grid() {
          ForEach(this.filtered(day), (item: BangumiItem) => {
            GridItem() {
              this.card(item)
            }
          }, (item: BangumiItem) => `${item.id}`)
        }
        .columnsTemplate(this.columnsTemplate())
        .columnsGap(12)
        .rowsGap(12)
        .height(this.gridHeightFor(day))
        .width('100%')
        .padding({ left: Dimens.contentInset, right: Dimens.contentInset })
      } else {
        Column() {
          // §46.4：空态图标与参照实现一致——筛选掉的是 `filter_alt_off_rounded`
          // （→ `slider_horizontal_2`），当天没番的是 `event_available_rounded`
          // （→ `calendar_badge_checkmark`）
          SymbolGlyph($r(this.filteredOut(day)
            ? 'sys.symbol.slider_horizontal_2'
            : 'sys.symbol.calendar_badge_checkmark'))
            .fontSize(32)
            .fontColor([AppColor.onSurfaceVariant])
            .margin({ bottom: 12 })
          Text(this.filteredOut(day)
            ? '没有符合筛选的番剧' : '这一天暂无放送')
            .fontSize(15)
            .fontColor(AppColor.onSurfaceVariant)
          if (this.filteredOut(day)) {
            Text('清除筛选')
              .fontSize(13)
              .fontColor(AppColor.primary)
              .margin({ top: 12 })
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .borderRadius(16)
              .backgroundColor(AppColor.primaryContainer)
              .onClick(() => {
                this.notShowWatched = false;
                this.notShowAbandoned = false;
                this.onlyShowWatching = false;
                this.persistFilters();
              })
          }
        }
        .width('100%')
        .height(240)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
  }

  /** 分页高度：有条目的按当天算，空态 / 加载态用固定 240。 */
  private pagerHeight(): number {
    return this.filtered(this.selectedDay).length > 0
      ? this.gridHeightFor(this.selectedDay) : 240;
  }

  /** 该天原始有数据、但被筛选清空（空态文案与图标据此区分）。 */
  private filteredOut(day: number): boolean {
    return day < this.week.length && this.week[day].length > 0;
  }

  /** 窄竖屏：决定卡片宽高（规格 §5.1 的 `narrowPortrait`）。 */
  private narrowPortrait(): boolean {
    const width: number = this.screenWidthVp();
    return width < 600 && Viewport.heightVp() > width;
  }

  /**
   * 卡片高度（规格 §58.2）：
   *   contentHeight = max(compact ? 120 : 136, 标题两行 + 8 + 元信息 + 12 + 页脚)
   *   height        = 12*2 + contentHeight
   * 默认字体下 compact = true → 144vp（与源码实测 432px 吻合）。
   */
  private cardHeight(): number {
    const compact: boolean = this.narrowPortrait();
    const titleHeight: number = 16 * 1.5 * 2;
    const labelHeight: number = 12 * 4 / 3;
    const footerHeight: number = Math.max(16, labelHeight) + 12;
    const contentHeight: number = Math.max(compact ? 120 : 136,
      titleHeight + 8 + labelHeight + 12 + footerHeight);
    return 12 * 2 + contentHeight;
  }

  /**
   * 时间表卡片。对应参照实现 `card/bangumi_timeline_card.dart`（规格 §58）：
   * 圆角 28、内边距 12、封面宽 compact?80:88、与信息列间距 compact?12:16，
   * 标题 16/1.5 两行、元信息 12、页脚评分胶囊（h10 v6 + 16 星标）。
   */
  @Builder
  card(item: BangumiItem) {
    Row() {
      // 封面：没图时按参照实现给一个 `movie_outlined` → `movie` 占位
      // 与详情页海报同址（`coverUrl()`）：共享元素两端必须是同一个 URL
      if (item.coverUrl().length > 0) {
        CoverImage({ src: item.coverUrl(), fit: ImageFit.Cover, radius: 16 })
          .width(this.narrowPortrait() ? 80 : 88)
          .height(this.narrowPortrait() ? 120 : 136)
          .backgroundColor(AppColor.surfaceContainerHighest)
          .borderRadius(16)
          .clip(true)
          // Hero 共享元素（§38.7）：时间表卡片封面 → 详情页海报
          .geometryTransition(HeroFlight.tag('timetable', item.id))
            .onAreaChange((oldValue: Area, newValue: Area) => {
              HeroRects.setCard(HeroFlight.tag('timetable', item.id), newValue);
            })
            .zIndex(1)
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.movie'))
            .fontSize(24)
            .fontColor([AppColor.onSurfaceVariant])
        }
        .width(this.narrowPortrait() ? 80 : 88)
        .height(this.narrowPortrait() ? 120 : 136)
        .borderRadius(16)
        .backgroundColor(AppColor.surfaceContainerHighest)
        .justifyContent(FlexAlign.Center)
      }

      Column() {
        Text(item.displayName())
          .fontSize(16)
          .lineHeight(24)
          .fontColor(AppColor.onSurface)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.supportingText(item))
          .fontSize(12)
          .lineHeight(16)
          .fontColor(AppColor.onSurfaceVariant)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 8 })
        Blank()
        /**
         * 底行（`BangumiTimelineCard._buildDetails` 的 footer）：
         * 左「评分胶囊 / 暂无评分」，右「正在追」书签（`bookmark_rounded` → `bookmark`）。
         */
        if (this.showRating || this.isWatching(item.id)) {
          Row() {
            if (this.showRating) {
              if (item.ratingScore > 0) {
                Row() {
                  SymbolGlyph($r('sys.symbol.star_fill'))
                    .fontSize(16)
                    .fontColor([AppColor.onSecondaryContainer])
                  Text(item.ratingScore.toFixed(1))
                    .fontSize(12)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(AppColor.onSecondaryContainer)
                    .margin({ left: 4 })
                }
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .borderRadius(999)
                .backgroundColor(AppColor.secondaryContainer)
              } else {
                Text('暂无评分')
                  .fontSize(12)
                  .fontColor(AppColor.onSurfaceVariant)
              }
            }
            Blank()
            if (this.isWatching(item.id)) {
              SymbolGlyph($r('sys.symbol.bookmark'))
                .fontSize(20)
                .fontColor([AppColor.primary])
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .height(this.narrowPortrait() ? 120 : 136)
      .margin({ left: this.narrowPortrait() ? 12 : 16 })
    }
    .width('100%')
    .height(this.cardHeight())
    .padding(12)
    .borderRadius(28)
    .backgroundColor(AppColor.glassCardFill)
    .border({ width: 1, color: AppColor.glassBorder })
      .onClick(() => {
        InfoRouteArgs.open(item, 'timetable', HeroFlight.tag('timetable', item.id));
      })
  }

  /** 是否在追（`CollectType` 1 = 在看）。参照实现的 `isWatching` 就是这个判据。 */
  private isWatching(id: number): boolean {
    const watching: CollectEntry[] = CollectStore.listByType(1);
    for (let i = 0; i < watching.length; i++) {
      if (watching[i].id === id) {
        return true;
      }
    }
    return false;
  }

  /**
   * 副标题拼装（规格 §58.3）：
   *   [「N 话」] + （metaTags 优先，否则 tags[].name），去空去重，取前 3 条 ` · ` 连接；
   *   为空则回落到原名（且仅当原名 ≠ 标题）。
   */
  private supportingText(item: BangumiItem): string {
    const parts: string[] = [];
    const episodes: number = TimetablePage.episodeCount(item);
    if (episodes > 0) {
      parts.push(`${episodes} 话`);
    }
    const tags: string[] = [];
    if (item.metaTags.length > 0) {
      for (let i = 0; i < item.metaTags.length; i++) {
        tags.push(item.metaTags[i]);
      }
    } else {
      for (let i = 0; i < item.tags.length; i++) {
        tags.push(item.tags[i].name);
      }
    }
    for (let i = 0; i < tags.length; i++) {
      const tag: string = tags[i].trim();
      if (tag.length > 0 && parts.indexOf(tag) < 0) {
        parts.push(tag);
      }
    }
    if (parts.length > 0) {
      return parts.slice(0, 3).join(' · ');
    }
    const title: string = item.displayName();
    return item.name !== title ? item.name : '';
  }

  /** 从 `info` 里抓话数（规格 §58.3 的正则，简繁「话/話」都收）。 */
  private static episodeCount(item: BangumiItem): number {
    const match: RegExpExecArray | null =
      new RegExp('^\\s*([1-9]\\d*)\\s*[话話集](?=\\s*(?:[/／]|$))').exec(item.info);
    return match === null ? 0 : Number.parseInt(match[1], 10);
  }

  private persistFilters(): void {
    SettingsStore.put(SettingsKeys.timelineNotShowWatchedBangumis, this.notShowWatched);
    SettingsStore.put(SettingsKeys.timelineNotShowAbandonedBangumis, this.notShowAbandoned);
    SettingsStore.put(SettingsKeys.timelineOnlyShowWatchingBangumis, this.onlyShowWatching);
  }

  /**
   * 季度下拉（规格 §5.3）。
   *
   * 参照实现是 `opaque:false + barrierColor:transparent` 的浮层（宽 156~196、
   * 进入 180ms / 退出 140ms）。原生侧改用 **HarmonyOS 原生菜单**：
   * 条目 = 最近 20 年 × 4 季，当前季度打勾；条目多时由系统菜单自己滚动。
   *
   * ⚠️ **按年份分组**（2026-09-18）：原来是一份 80 项的平铺长列表，
   * 想找「2024 年夏季」得在菜单里滑很久——用户的原话是「好像看不了全年的」。
   * 数据本身是全的（实测镜像对 2015–2026 每个季度都有 46~87 部），
   * 问题只在菜单形态：加年份分组之后，一眼就能定位到哪一年。
   */
  @Builder
  seasonMenu() {
    Menu() {
      ForEach(TimetablePage.seasonYears(), (year: number) => {
        MenuItemGroup({ header: `${year} 年` }) {
          ForEach(TimetablePage.seasonDatesOfYear(year), (date: Date) => {
            this.seasonMenuOption(date)
          }, (date: Date) => `season-option-${date.getTime()}`)
        }
      }, (year: number) => `season-year-${year}`)
    }
  }

  /** 季度菜单的年份（新 → 旧，最近 20 年）。 */
  private static seasonYears(): number[] {
    const now: Date = new Date();
    const years: number[] = [];
    for (let year = now.getFullYear(); year >= now.getFullYear() - 19; year--) {
      years.push(year);
    }
    return years;
  }

  /** 某年的四个季度起点（新 → 旧，只保留已经开始的季度）。 */
  private static seasonDatesOfYear(year: number): Date[] {
    const now: Date = new Date();
    const items: Date[] = [];
    for (let quarter = 4; quarter >= 1; quarter--) {
      const start = new Date(year, (quarter - 1) * 3, 1);
      if (now.getTime() > start.getTime()) {
        items.push(start);
      }
    }
    return items;
  }

  /** 单个季度项：当前季度打勾。 */
  @Builder
  seasonMenuOption(date: Date) {
    if (TimetablePage.isCurrentSeason(date, this.selectedDateMs)) {
      MenuItem({ content: seasonLabel(date), endIcon: $r('sys.symbol.checkmark') })
        .onClick(() => {
          this.loadSeason(date);
        })
    } else {
      MenuItem({ content: seasonLabel(date) })
        .onClick(() => {
          this.loadSeason(date);
        })
    }
  }

  /** 两个日期是否落在同一个季度。 */
  private static isCurrentSeason(date: Date, selectedMs: number): boolean {
    const selected: Date = new Date(selectedMs);
    return date.getFullYear() === selected.getFullYear()
      && Math.floor(date.getMonth() / 3) === Math.floor(selected.getMonth() / 3);
  }

  /**
   * 排序与筛选菜单（规格 §5.4）—— HarmonyOS 原生菜单。
   *
   * 参照实现是宽 300 的自绘浮层（排序三选一 + 三个开关）。原生菜单不做
   * 「菜单里塞开关」这种形态，按系统做法改成**两组可选项、选中打勾**：
   * 语义与开关完全等价（开 = 打勾），视觉与播放页「更多」菜单一致。
   * 每一项都即刻落盘（`timelineNotShowWatchedBangumis` 等三个设置键）。
   */
  @Builder
  optionsMenu() {
    Menu() {
      MenuItemGroup({ header: '排序' }) {
        ForEach(this.sortLabels, (label: string, index: number) => {
          this.optionsMenuOption(label, index === this.sortIndex, () => {
            this.sortIndex = index;
            this.applySort();
          })
        }, (label: string) => `sort-option-${label}`)
      }

      MenuItemGroup({ header: '筛选' }) {
        this.optionsMenuOption('隐藏看过的番剧', this.notShowWatched, () => {
          this.notShowWatched = !this.notShowWatched;
          this.persistFilters();
        })
        this.optionsMenuOption('隐藏抛弃的番剧', this.notShowAbandoned, () => {
          this.notShowAbandoned = !this.notShowAbandoned;
          this.persistFilters();
        })
        this.optionsMenuOption('只看正在追的番剧', this.onlyShowWatching, () => {
          this.onlyShowWatching = !this.onlyShowWatching;
          this.persistFilters();
        })
      }
    }
  }

  /** 单个可选项：选中打勾；点一下就地切换。 */
  @Builder
  optionsMenuOption(label: string, selected: boolean, action: () => void) {
    if (selected) {
      MenuItem({ content: label, endIcon: $r('sys.symbol.checkmark') })
        .onClick(() => {
          action();
        })
    } else {
      MenuItem({ content: label })
        .onClick(() => {
          action();
        })
    }
  }
}
