import { common } from '@kit.AbilityKit';
import { AppColor } from '../theme/AppColors';
import { Dimens } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { CollectStore } from '../services/collect/CollectStore';
import { WatchDay, WatchTimeStore } from '../services/WatchTimeStore';
import { PluginManager } from '../services/plugin/PluginManager';
import { CacheUsage } from '../services/storage/CacheUsage';
import { appDisplayName, appVersion } from '../utils/AppMeta';
import { Viewport } from '../utils/Viewport';
import { HistoryRepository } from '../services/HistoryRepository';
import { WatchStats } from '../services/WatchStats';
import {
  SectionHeader,
  SettingsIconTone,
  SettingsRow,
  SettingsRowKind
} from '../components/SettingsList';
import { groupBottomRadius, groupTopRadius } from '../components/SettingsRows';

/**
 * 我的页。对应参照实现 `lib/pages/my/my_page.dart` + `my_space_view.dart`（规格 §7）。
 *
 * 公开快照不包含私人反馈群信息。
 *
 * 旧版是一屏「大卡片」：规则设置 / 历史记录 / 离线下载 / 偏好设置 / 存储管理 /
 * 应用信息卡。想改某一项设置得先猜它在哪张卡里，外观 / 播放 / 弹幕还挤在同一个
 * 「偏好设置」的三连按钮里——这正是要改掉的地方。
 *
 * 现在照参照实现夏绊（`F:\app\entry\src\main\ets\pages\SettingsView.ets`）的做法，
 * 把设置项**直接摊成列表**：
 *
 *   观看统计（保留：这是「我的」页唯一的非设置内容）
 *   播放  播放设置 / 弹幕设置 / 历史记录
 *   资源  规则管理 / 离线下载 / 下载设置
 *   应用  外观设置 / 界面设置 / 网络设置
 *   其他  更新设置 / 存储与日志
 *   关于  版本号（只读）/ 问题反馈（点击弹 QQ 群号，可一键复制）
 *
 * 行组件直接复用 `SettingsList` / `SettingsRows`（首行上圆角 24、末行下圆角 24、
 * 中间 4、底色 surfaceContainerLow），因此与各二级设置页是同一套皮肤与规格。
 *
 * 2026-09-18 二次调整（用户三条）：
 *   1. **背景改成和推荐页同一层**——删掉页面级渐变（见 `build` 里的注释），
 *      四个 Tab 从此刻起共用 Index 那层 `AppBackground`（壁纸 / 纯色主题连续）；
 *   2. 悬浮标题与「观看统计」卡之间留出足够距离（`contentTopPadding`）；
 *   3. **取消「设置」胶囊**（用户要求）——设置项已经全部摊在本页，
 *      于是设置总览 `pages/SettingsPage` 不再有入口（路由与页面都还在，
 *      想挂回来只需在 `header()` 里加回那个胶囊）。
 *
 * 2026-09-19 第三次调整（用户：「想更有鸿蒙感」，只看排版）：
 *   1. **图标换成圆角方块容器**（`iconTone`）——原来左侧是 24 裸线性符号，
 *      现在是一级入口该有的样子：32 方块 / 圆角 10 / 符号 20，
 *      底色按**分组**取 `primary / secondary / neutral` 三档
 *      （播放=主色、资源=次色、应用=次色、其他=次色、关于=中性），
 *      符号色由 `SettingsIconToneColors` 配对给出，深浅色主题自动跟随；
 *   2. **可点行补行尾 `›`**（`showChevron`）——本页 10 行都是「进二级页」，
 *      此前右侧空着，看不出能不能点。
 *
 * ⚠️ 2026-09-19 用户反馈修正：「设置页的应用那一栏的图标好像颜色不统一了，
 * 弄成和其他一样的」——**应用组原来用的是 `tertiary`（第三色）**，
 * M3 里第三色的色相与主/次色错开约 60°，在暖色种子下会偏绿，
 * 夹在播放（主色）与资源（次色）之间就是「这一栏颜色不对」。
 * 已改回 `secondary`，与资源 / 其他两组同色。
 * 教训：**一级入口的图标底色不要跨色相**，`tertiary` 在这类「一整屏同类入口」里
 * 只会显得脏，想再拉开层级就用 `primary`（唯一强调）而不是换色相。
 *
 * 两条**不给**的行记在这里，避免下次被「统一」掉：
 *   - 「版本号」是 `SettingsRowKind.info`（只读），不补箭头；
 *   - 「问题反馈」弹的是对话框不是页面，也不补箭头（箭头会承诺一次页面跳转），
 *     但它仍用图标容器，否则「关于」组里两行一有一无会显得缺了一块。
 * 二级设置页（播放 / 弹幕 / 网络…）的开关行、滑杆行**保持裸符号**，
 * 那里一行一个色块会盖过内容本身。
 */
@Component
export struct MinePage {
  @StorageProp('topInset') topInset: number = 39;
  /** 主题版本：由 Index 下发；配色刷新靠 Index 侧按版本整体重建（见 Index 注释）。 */
  @Prop themeRev: number = 0;
  /** 滚动上报（导航条弹入弹出 + 末尾回弹判定），见 `NavScrollController`。 */
  onScrollOffset: (offset: number, maxOffset: number) => void = () => {
  };
  @State private contentHeight: number = 0;
  @State private viewportHeight: number = 0;
  /**
   * 内容滚动容器。
   *
   * ⚠️ `onDidScroll` 的第二个参数是 **`ScrollState`（0/1/2）**，不是 yOffset：
   * 直接把它当偏移上报，`NavScrollController` 的 delta 几乎恒为 0，
   * 底部导航条永远不会隐藏。偏移必须从 `Scroller.currentOffset()` 读。
   */
  private contentScroller: Scroller = new Scroller();
  /**
   * 观看统计（§7.2 第 1 项）：番剧数与集数都来自播放历史（阶段五已落地），
   * 与「收藏数」是三件不同的事，别混用。
   */
  @State statDramas: number = 0;
  @State statEpisodes: number = 0;
  /** 累计观看时长（秒）——来自 `WatchTimeStore` 的真实播放秒数，不是历史里的进度和。 */
  @State statWatchSeconds: number = 0;
  /** 最近 7 天的观看时长（秒），从早到晚（最后一个是今天）。 */
  @State statWeek: number[] = [0, 0, 0, 0, 0, 0, 0];
  /** 那 7 天的柱下标签（一…日，最后一个是「今」）。 */
  @State statWeekLabels: string[] = ['', '', '', '', '', '', ''];
  /** 连续观看天数。 */
  @State statStreak: number = 0;
  /** 收藏数（底部那行「收藏 N 部」）。 */
  @State statCollect: number = 0;
  @State statRules: number = 0;
  @State downloadCount: number = 0;
  /** 缓存占用（存储管理卡片副标题）。 */
  @State cacheText: string = '计算中…';
  /** 实测可用宽度（横屏 / 平板左侧有 88vp 导航栏）。 */
  @State viewportWidth: number = 0;
  /** 订阅历史变更：播放后回到「我的」页统计要跟着变。 */
  @StorageProp('historyRevision') @Watch('onHistoryChanged') historyRevision: number = 0;
  /** 订阅收藏变更：「收藏 N 部」与追番分类统计要跟着变（同历史那套机制）。 */
  @StorageProp('collectRevision') @Watch('onCollectChanged') collectRevision: number = 0;
  /** 订阅观看时长变更：播放页每 20 秒落一次盘，回到「我的」页要看到最新数字。 */
  @StorageProp('watchTimeRevision') @Watch('onWatchTimeChanged') watchTimeRevision: number = 0;
  /**
   * 卡片按压（旧版 `_ExpressiveAction`：按下 0.97 / 150ms、松开 300ms 回弹）
   * 随卡片一起下线了——现在每一行都是 `SettingsRow`，按压反馈是它自带的那一套
   * （按下圆角收到 24、250ms `easeInOutCubicEmphasized`），全应用统一。
   */
  aboutToAppear(): void {
    this.statCollect = CollectStore.countAll();
    this.statRules = PluginManager.pluginList.length;
    this.downloadCount = 0;
    this.loadStats();
    this.measureCache();
  }

  onHistoryChanged(): void {
    this.loadStats();
  }

  /** 收藏变了：重读底部那行「收藏 N 部」。 */
  onCollectChanged(): void {
    this.statCollect = CollectStore.countAll();
  }

  onWatchTimeChanged(): void {
    this.loadWatchTime();
  }

  /** 观看统计：去重后的番剧数与 (番剧, 集数) 对数（`watch_stats.dart`）。 */
  private loadStats(): void {
    const stats: WatchStats = WatchStats.from(HistoryRepository.getAll());
    this.statDramas = stats.watchedBangumiCount;
    this.statEpisodes = stats.watchedEpisodeCount;
    this.loadWatchTime();
  }

  /**
   * 观看时长读数：总量 + 近 7 天（画柱状）+ 连续天数。
   *
   * 数据源是 `WatchTimeStore`（播放页每 500ms 采样、只累加「位置正常前进」的部分），
   * 与历史里的 `progressMs` 不是一回事，别拿后者求和代替。
   */
  private loadWatchTime(): void {
    const now: number = Date.now();
    this.statWatchSeconds = WatchTimeStore.totalSeconds();
    const days: WatchDay[] = WatchTimeStore.lastDays(7, now);
    const week: number[] = [];
    const labels: string[] = [];
    for (let i = 0; i < days.length; i++) {
      week.push(days[i].seconds);
      labels.push(days[i].today ? '今' : MinePage.weekdayLabel(days[i].day));
    }
    this.statWeek = week;
    this.statWeekLabels = labels;
    this.statStreak = WatchTimeStore.streakDays(now);
  }

  /** `2026-09-20` → 「一/二/…/日」。串解析成 Date 时**别用 `new Date(字符串)`**：
   * 那个按 UTC 解析，东八区会整体错一天。 */
  private static weekdayLabel(day: string): string {
    const parts: string[] = day.split('-');
    if (parts.length !== 3) {
      return '';
    }
    const year: number = Number.parseInt(parts[0], 10);
    const month: number = Number.parseInt(parts[1], 10);
    const date: number = Number.parseInt(parts[2], 10);
    if (Number.isNaN(year) || Number.isNaN(month) || Number.isNaN(date)) {
      return '';
    }
    const names: string[] = ['日', '一', '二', '三', '四', '五', '六'];
    const week: number = new Date(year, month - 1, date).getDay();
    return names[week];
  }

  /**
   * 时长文案：「12 小时 38 分」/「38 分钟」/「0 分钟」。
   *
   * 卡片里用它写「本周 / 日均」两处小字；主数字那一行走 `heroValue` + `heroUnit`
   * （同一个数拆成「大号数字 + 小号单位」，层级更清楚）。
   */
  private static formatDuration(seconds: number): string {
    const total: number = seconds < 0 ? 0 : Math.round(seconds);
    const hours: number = Math.floor(total / 3600);
    const minutes: number = Math.round((total % 3600) / 60);
    if (hours <= 0) {
      return `${minutes} 分钟`;
    }
    return minutes <= 0 ? `${hours} 小时` : `${hours} 小时 ${minutes} 分`;
  }

  /** 主数字：不足 1 小时给分钟数，否则给小时数。 */
  private heroValue(): string {
    const total: number = this.statWatchSeconds;
    if (total < 3600) {
      return `${Math.floor(total / 60)}`;
    }
    return `${Math.floor(total / 3600)}`;
  }

  /** 主数字的单位：与 `heroValue` 配对（「小时 38 分」/「分钟」）。 */
  private heroUnit(): string {
    const total: number = this.statWatchSeconds;
    if (total < 3600) {
      return '分钟';
    }
    const minutes: number = Math.round((total % 3600) / 60);
    return minutes <= 0 ? '小时' : `小时 ${minutes} 分`;
  }

  /** 柱高：按「近 7 天最大值」归一化，最高 44、最低 3（0 也留一小截，看着像图表）。 */
  private weekBarHeight(seconds: number): number {
    let peak: number = 0;
    for (let i = 0; i < this.statWeek.length; i++) {
      if (this.statWeek[i] > peak) {
        peak = this.statWeek[i];
      }
    }
    if (peak <= 0) {
      return 3;
    }
    const raw: number = Math.round(44 * (seconds / peak));
    return raw < 3 ? 3 : raw;
  }

  /** 数组求和（`reduce` 在 ArkTS 里类型更啰嗦，直接写循环）。 */
  private static sumOf(values: number[]): number {
    let total: number = 0;
    for (let i = 0; i < values.length; i++) {
      total += values[i];
    }
    return total;
  }

  private measureCache(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const usage = CacheUsage.compute(context);
      this.cacheText = `缓存 ${CacheUsage.formatBytes(usage.totalBytes())}`;
    } catch (e) {
      this.cacheText = '缓存与日志';
    }
  }

  private screenWidthVp(): number {
    return Viewport.widthVp(this.viewportWidth);
  }

  private inset(): number {
    const screen: number = this.screenWidthVp();
    const base: number = screen < 600 ? 16 : 32;
    /**
     * 大屏再加一层**居中留白**：平板上屏宽 1400+，内容整宽铺开会让
     * 「我的」这种列表页的每一项都拉成一条超长横杠（用户 2026-10-07：
     * 平板没适配好）。参照实现里设置类页面用 `SettingsList(maxWidth: 1000)`
     * 收敛，这里取同一条上限。
     */
    const cap: number = MinePage.CONTENT_MAX_WIDTH;
    return screen > cap + base * 2 ? (screen - cap) / 2 : base;
  }

  /** 大屏内容最大宽度（对照参照实现 `settings_list.dart` 的 `maxWidth: 1000`）。 */
  private static readonly CONTENT_MAX_WIDTH: number = 1000;

  /**
   * 滚动内容的顶部让位高度（含 `topInset`）。
   *
   * 标题行是**浮在内容之上**的一层（Stack 的最后一层），本身只有 27 高
   * （20 号字一行）+ 顶部 10，所以内容必须自己让位，否则标题会压在
   * 「观看统计」卡上。用户 2026-09-18：「最顶上的观看统计和我的这个标题
   * 多一点距离」，因此留到 64（标题行底边在 37，卡片上方空出 27）。
   */
  private contentTopPadding(): number {
    return this.topInset + 64;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      /**
       * 背景 = **与推荐页同一层**（2026-09-18 用户：「背景换成和推荐页一样的」）。
       *
       * 这里原本铺了一整页渐变（primaryContainer 42% → tertiaryContainer 18% →
       * 透明），把 Index 那层 `AppBackground`（自定义背景图 + 遮罩）整个盖住了，
       * 所以「我的」和推荐页的底色各是一套，换壁纸时本页永远不跟着走。
       *
       * 与 `TimetablePage` / `CollectPage` 同一天的处理完全一致：整层删掉，
       * 本页变成透明，直接露下面的 `AppBackground`，四个 Tab 从此共用同一个背景。
       */

      Scroll(this.contentScroller) {
        Column() {
          this.statsPanel()
          Blank().height(24)

          SectionHeader({ title: '播放', themeRev: this.themeRev })
          this.playGroup()
          Blank().height(16)

          SectionHeader({ title: '资源', themeRev: this.themeRev })
          this.resourceGroup()
          Blank().height(16)

          SectionHeader({ title: '应用', themeRev: this.themeRev })
          this.appGroup()
          Blank().height(16)

          SectionHeader({ title: '其他', themeRev: this.themeRev })
          this.otherGroup()
          Blank().height(16)

          SectionHeader({ title: '关于', themeRev: this.themeRev })
          this.aboutGroup()

          Blank().height(Dimens.contentBottomSpacer)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({
          left: this.inset(),
          right: this.inset(),
          top: this.contentTopPadding()
        })
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
        // ⚠️ 第二个参数是 `ScrollState`（0/1/2），不是 yOffset——
        // 直接上报会让 `NavScrollController` 的 delta 恒为 0、导航条永不隐藏。
        // 偏移从 Scroller 读（与推荐页同一写法）。
        const offset: number = this.contentScroller.currentOffset().yOffset;
        const reachable: number = this.contentHeight - this.viewportHeight;
        this.onScrollOffset(offset, reachable > 0 ? reachable : 0);
      })

      this.header()
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
   * 悬浮标题。
   *
   * 2026-09-18：右侧那颗「设置」胶囊（§46.4 的 `slider_horizontal_2`）按用户
   * 要求取消——设置项已经全部摊在本页，「我的 → 设置 → 总览」两层就重复了。
   * 设置总览 `pages/SettingsPage` 因此没有入口（路由与页面都保留着），
   * 需要时把胶囊加回来即可（`RouteTable.push(RouteTable.settingsHome)`）。
   */
  @Builder
  header() {
    Row() {
      Text('我的')
        .fontSize(20)
        .lineHeight(27)
        .fontWeight(700)
        .letterSpacing(0.3)
        .fontColor(AppColor.onSurface)
    }
    .width('100%')
    .padding({
      left: Dimens.contentInset,
      right: Dimens.contentInset,
      top: this.topInset + 10
    })
  }

  /**
   * 观看统计卡（规格 §7.2 第 1 项）。
   *
   * 2026-09-20 美化（用户：「最顶上的观看统计能不能稍微优化美化一下」，
   * 参考图在 `统计美化/`）。照着对截图做的一次设计批评，改了三处：
   *
   *   1. **中间那个小魔杖图标从数字行挪到标题行**。它夹在 34sp 的大数字中间
   *      只有 20sp，既没和数字垂直居中、也不像分隔符，图上看着就是一个
   *      「没对齐的噪点」；挪到「观看统计」标题前面当小小的强调符号就顺了
   *      （`wand_and_stars` 的映射本身保留，见 §46.4）；
   *   2. **左右两栏之间换成一条 1×36 的细竖线**，两栏才是真正的对称布局，
   *      数字成为唯一的视觉焦点；
   *   3. **底部「已装规则 N 条 · 收藏 N 部」单独成「页脚」**：上面加一条
   *      发丝分隔线、字号 12→11、颜色降到 `outline`，不再和统计数据挤在同一层。
   *
   * 另外补了两点对比度：卡片自身加一层极淡的投影（原来与页面底色几乎贴在一起，
   * 「像涂上去的一块色」），数字与标签之间的间距 2→8（原来偏挤）。
   */
  @Builder
  statsPanel() {
    Column() {
      /**
       * ---- 标题行：左「✨ 观看统计」，右「连续 N 天」小胶囊 ----
       *
       * 连续天数只在 ≥ 2 天时出现：第 1 天就挂着「连续 1 天」既没用，
       * 也让卡片多一块颜色。
       */
      Row() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.wand_and_stars'))
            .fontSize(14)
            .fontColor([AppColor.primary])
          Text('观看统计')
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
        }
        Blank()
        if (this.statStreak >= 2) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.clock'))
              .fontSize(12)
              .fontColor([AppColor.primary])
            Text(`连续 ${this.statStreak} 天`)
              .fontSize(11)
              .fontColor(AppColor.primary)
          }
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(10)
          .backgroundColor(AppColor.withAlpha(AppColor.primary, 0.12))
        }
      }
      .width('100%')

      /**
       * ---- 主数字：累计观看时长 ----
       *
       * 「12 小时 38 分」拆成 36sp 数字 + 14sp 单位：小卡片里一眼能抓住数字，
       * 单位又不会跟数字抢。基线用 `VerticalAlign.Bottom` 对齐，
       * 否则大号字和小号字会在垂直方向错开一截。
       */
      Row({ space: 4 }) {
        Text(this.heroValue())
          .fontSize(36)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.onSurface)
        Text(this.heroUnit())
          .fontSize(14)
          .fontColor(AppColor.onSurfaceVariant)
          .margin({ bottom: 6 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 12 })

      // ---- 次级：原来的两个统计数，收成一行小字 ----
      Text(`看过番剧 ${this.statDramas} · 观看集数 ${this.statEpisodes}`)
        .fontSize(12)
        .fontColor(AppColor.onSurfaceVariant)
        .margin({ top: 6 })

      /**
       * ---- 近 7 天迷你柱状图 ----
       *
       * 没有坐标轴、没有网格、没有图例：高度按这一周的最大值归一化，
       * 今天用主色、其余日子用主色 32% 透明度，0 的那天也留一小截（3vp），
       * 这样「这周几乎没看」和「完全没有数据」在视觉上不会混成一片空白。
       * 每根柱下面挂一个字（一…日，今天写「今」）。
       */
      Row() {
        ForEach(this.statWeek, (seconds: number, index: number) => {
          Column() {
            Column()
              .width(12)
              .height(this.weekBarHeight(seconds))
              .borderRadius(6)
              .backgroundColor(index === this.statWeek.length - 1
                ? AppColor.primary
                : AppColor.withAlpha(AppColor.primary, 0.32))
            Text(this.statWeekLabels.length > index ? this.statWeekLabels[index] : '')
              .fontSize(9)
              .fontColor(AppColor.outline)
              .margin({ top: 6 })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.End)
          .alignItems(HorizontalAlign.Center)
        }, (seconds: number, index: number) => `week-${index}-${seconds}`)
      }
      .width('100%')
      .height(62)
      .margin({ top: 16 })
      .alignItems(VerticalAlign.Bottom)

      // ---- 一周汇总 ----
      Text(`本周 ${MinePage.formatDuration(
        MinePage.sumOf(this.statWeek))} · 日均 ${MinePage.formatDuration(
        Math.round(MinePage.sumOf(this.statWeek) / 7))}`)
        .fontSize(11)
        .fontColor(AppColor.outline)
        .margin({ top: 8 })

      // 页脚：发丝分隔线 + 更小更淡的一行「已装规则 / 收藏」
      Column()
        .width('100%')
        .height(1)
        .backgroundColor(AppColor.outlineVariant)
        .margin({ top: 14 })
      Text(`已装规则 ${this.statRules} 条 · 收藏 ${this.statCollect} 部`)
        .fontSize(11)
        .fontColor(AppColor.outline)
        .margin({ top: 10 })
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 18, bottom: 18 })
    .borderRadius(48)
    .backgroundColor(AppColor.surfaceContainerHigh)
    // 极淡的投影：把卡片从页面底色上「托起来」（原来两者几乎同色）
    .shadow({ radius: 18, color: '#14000000', offsetX: 0, offsetY: 3 })
  }

  private showTip(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 提示失败不影响主流程
    }
  }

  // ---------------- 以下为 2026-09-18 改版新增：直接把设置项摊成列表 ----------------

  /**
   * 播放组：播放设置 / 弹幕设置 / 历史记录。
   *
   * 圆角按行在分组里的位置给（`groupTopRadius` / `groupBottomRadius`），
   * 与各二级设置页是同一套算法、同一套皮肤。
   */
  @Builder
  playGroup() {
    Column({ space: 4 }) {
      SettingsRow({
        themeRev: this.themeRev,
        title: '播放设置',
        description: '解码、渲染与播放行为',
        icon: $r('sys.symbol.play_circle_fill'),
        iconTone: SettingsIconTone.primary,
        showChevron: true,
        topRadius: groupTopRadius(0),
        bottomRadius: groupBottomRadius(0, 3),
        onTap: () => {
          RouteTable.push(RouteTable.playerSettings);
        }
      })
      SettingsRow({
        themeRev: this.themeRev,
        title: '弹幕设置',
        description: '弹幕来源与显示效果',
        icon: $r('sys.symbol.text_bubble_left_2'),
        iconTone: SettingsIconTone.primary,
        showChevron: true,
        topRadius: groupTopRadius(1),
        bottomRadius: groupBottomRadius(1, 3),
        onTap: () => {
          RouteTable.push(RouteTable.danmakuSettings);
        }
      })
      SettingsRow({
        themeRev: this.themeRev,
        title: '历史记录',
        description: this.statDramas === 0 ? '暂无观看记录' : '查看观看记录',
        icon: $r('sys.symbol.clock_arrow_2_circlepath'),
        iconTone: SettingsIconTone.primary,
        showChevron: true,
        topRadius: groupTopRadius(2),
        bottomRadius: groupBottomRadius(2, 3),
        onTap: () => {
          RouteTable.push(RouteTable.history);
        }
      })
    }
    .width('100%')
  }

  /** 资源组：规则管理 / 离线下载 / 下载设置。 */
  @Builder
  resourceGroup() {
    Column({ space: 4 }) {
      SettingsRow({
        themeRev: this.themeRev,
        title: '规则管理',
        description: `已装 ${this.statRules} 条番剧来源规则`,
        icon: $r('sys.symbol.gearshape'),
        iconTone: SettingsIconTone.secondary,
        showChevron: true,
        topRadius: groupTopRadius(1),
        bottomRadius: groupBottomRadius(1, 4),
        onTap: () => {
          RouteTable.push(RouteTable.plugin);
        }
      })
      SettingsRow({
        themeRev: this.themeRev,
        title: '离线下载',
        description: this.downloadCount === 0
          ? '管理离线内容' : `${this.downloadCount} 集下载任务`,
        icon: $r('sys.symbol.download'),
        iconTone: SettingsIconTone.secondary,
        showChevron: true,
        topRadius: groupTopRadius(2),
        bottomRadius: groupBottomRadius(2, 4),
        onTap: () => {
          RouteTable.push(RouteTable.download);
        }
      })
      SettingsRow({
        themeRev: this.themeRev,
        title: '下载设置',
        description: '并发数与弹幕缓存',
        icon: $r('sys.symbol.arrow_down_to_line'),
        iconTone: SettingsIconTone.secondary,
        showChevron: true,
        topRadius: groupTopRadius(3),
        bottomRadius: groupBottomRadius(3, 4),
        onTap: () => {
          RouteTable.push(RouteTable.downloadSettings);
        }
      })
    }
    .width('100%')
  }

  /**
   * 应用组：外观设置 / 界面设置 / 网络设置。
   *
   * 2026-09-18：同步类目已整体摘除，这里**不要**再补「同步设置」行
   * （`SyncSettingsPage` 等页面同批删除，路由表里也没有对应常量了）。
   */
  @Builder
  appGroup() {
    Column({ space: 4 }) {
      SettingsRow({
        themeRev: this.themeRev,
        title: '外观设置',
        description: '主题、配色与字体',
        icon: $r('sys.symbol.paintpalette'),
        iconTone: SettingsIconTone.secondary,
        showChevron: true,
        topRadius: groupTopRadius(0),
        bottomRadius: groupBottomRadius(0, 3),
        onTap: () => {
          RouteTable.push(RouteTable.settings);
        }
      })
      SettingsRow({
        themeRev: this.themeRev,
        title: '界面设置',
        description: '展示信息与评分显示',
        icon: $r('sys.symbol.picture'),
        iconTone: SettingsIconTone.secondary,
        showChevron: true,
        topRadius: groupTopRadius(1),
        bottomRadius: groupBottomRadius(1, 3),
        onTap: () => {
          RouteTable.push(RouteTable.interfaceSettings);
        }
      })
      SettingsRow({
        themeRev: this.themeRev,
        title: '网络设置',
        description: '镜像加速番剧信息与规则访问',
        icon: $r('sys.symbol.worldclock'),
        iconTone: SettingsIconTone.secondary,
        showChevron: true,
        topRadius: groupTopRadius(2),
        bottomRadius: groupBottomRadius(2, 3),
        onTap: () => {
          RouteTable.push(RouteTable.networkSettings);
        }
      })
    }
    .width('100%')
  }

  /** 其他组：存储与日志。 */
  @Builder
  otherGroup() {
    Column({ space: 4 }) {
      SettingsRow({
        themeRev: this.themeRev,
        title: '存储与日志',
        description: this.cacheText,
        icon: $r('sys.symbol.hidisk'),
        iconTone: SettingsIconTone.secondary,
        showChevron: true,
        topRadius: groupTopRadius(0),
        bottomRadius: groupBottomRadius(0, 1),
        onTap: () => {
          RouteTable.push(RouteTable.storage);
        }
      })
    }
    .width('100%')
  }

  /**
   * 关于组：版本号（只读）+ 问题反馈。
   *
   * 公开快照只保留版本号，不包含私人联系方式和反馈群入口。
   */
  @Builder
  aboutGroup() {
    Column({ space: 4 }) {
      SettingsRow({
        themeRev: this.themeRev,
        title: '版本号',
        description: appDisplayName,
        valueText: appVersion,
        icon: $r('sys.symbol.info_circle'),
        iconTone: SettingsIconTone.neutral,
        kind: SettingsRowKind.info,
        topRadius: groupTopRadius(0),
        bottomRadius: groupBottomRadius(0, 1)
      })
    }
    .width('100%')
  }
}




