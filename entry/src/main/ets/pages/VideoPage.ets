import { router, window } from '@kit.ArkUI';
import { LoadingIndicator } from '../components/LoadingIndicator';
import { common, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { settings } from '@kit.BasicServicesKit';
import { audio } from '@kit.AudioKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BangumiItem } from '../model/BangumiItem';
import { Road } from '../model/SearchModels';
import { Plugin } from '../plugins/Plugin';
import { InfoRouteArgs, OfflineEpisode, VideoRouteArgs } from '../router/RouteArgs';
import { DownloadManager } from '../services/DownloadManager';
import { DownloadEpisode, DownloadRequest, DownloadStatus } from '../model/DownloadModels';
import { NavHost, RouteTable } from '../router/RouteTable';
import { AppColor } from '../theme/AppColors';
import { AppCurves, HS, Motion, PageTransitionSpec } from '../theme/Tokens';
import { MotionRuntime } from '../theme/MotionRuntime';
import { EpisodeUrl } from '../utils/EpisodeUrl';
import { Viewport } from '../utils/Viewport';
import { toSimplifiedChinese } from '../utils/ChineseConverter';
import { HttpHeaders } from '../request/core/HttpHeaders';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';
import { PluginManager } from '../services/plugin/PluginManager';
import { AspectRatioMode, PlaybackParams, PlayerEngine } from '../services/PlayerEngine';
import { HistoryRepository } from '../services/HistoryRepository';
import { TimedShutdown } from '../services/TimedShutdown';
import { PlaybackHistoryIdentity } from '../model/HistoryModels';
import { DanmakuEntry } from '../model/DanmakuModels';
import { DanmakuBiliContext, DanmakuService, DanmakuLoadResult }
  from '../services/DanmakuService';
import { EpisodeTitleService } from '../services/metadata/EpisodeTitleService';
import { ActiveDanmaku, DanmakuLayer, DanmakuSchedule } from '../components/DanmakuLayer';
import { DanmakuShieldStore } from '../services/DanmakuShieldStore';
import { PlayPauseIcon } from '../components/PlayPauseIcon';
import { ScreenshotFeedback } from '../components/ScreenshotFeedback';
import { HarmonySlider } from '../components/HarmonySlider';
import { DanmakuSliderRow } from '../components/DanmakuSliderRow';
import { Logger } from '../services/Logger';
import { CollectEntry, CollectStore } from '../services/collect/CollectStore';
import { SettingKeyDef } from '../services/storage/SettingsKeys';
import { DlnaCastResult, DlnaCaster, DlnaDevice } from '../services/DlnaCaster';
import { VideoSourceResolver, VideoSourceResult } from '../webview/VideoSourceResolver';
import { VideoSourceWebHost } from '../webview/VideoSourceWebHost';
import { AgedmPlayback } from '../services/plugin/AgedmPlayback';
import { WatchTimeStore } from '../services/WatchTimeStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnVideoPage';

/** 自绘转场结束后、把窗口交接给系统的时长（与系统转屏动画对齐，真机再调）。 */
const FULLSCREEN_HANDOVER_MS: number = 620;

/** 横向滑动换算：整屏横扫 = 180 秒（§15.6）。 */
const SEEK_SCALE_MS: number = 180000;
/** 亮度手势：屏高 × 2 对应满量程（§15.7）。 */
const BRIGHTNESS_LEVEL_FACTOR: number = 2;
/**
 * 音量手势的位移刻度：**手势区高度 × 0.03 = 1 个音量点**（照抄 §15.7 / 源码
 * `player_item.dart` 的 `level = totalHeight * 0.03`）。
 *
 * 口径：一次「从视频区底边拖到顶边」≈ 33 个音量点（三次满拖走完 0 → 100）。
 *
 * ⚠️ 2026-09-19 用户反馈「音量手势不能调到 100%、会卡住」，根因**不是**这个刻度，
 * 而是手势结束时把系统读回值无条件写回 HUD 造成的**回弹**（见
 * `finishVolumeGesture`）：每拖一次就被弹回原值，量自然永远涨不上去。
 * 回弹修好之后再评估手感，别急着把这个刻度调大——1 个点 / 6vp 已经不算迟钝。
 *
 * 也别走另一个极端：早先写成 `(位移 / level) * 100`，等于把灵敏度放大 100 倍，
 * 手指一动音量就在 0 / 100 之间跳（09-15 已改掉，别改回去）。
 */
const VOLUME_LEVEL_FACTOR: number = 0.03;

/**
 * 手势方向判定的「占优倍数」：某一轴位移必须达到另一轴的 1.3 倍才定向。
 * 取值理由见 `gestureMove` 的注释（纵向滑动曾被判成拖进度）。
 */
const GESTURE_AXIS_DOMINANCE: number = 1.3;
/** 可选倍速（`defaultPlaySpeedList`）。 */
const PLAY_SPEEDS: number[] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0,
  2.25, 2.5, 2.75, 3.0];
/** 画面比例档位（§15.2）。 */
const ASPECT_LABELS: string[] = ['自动', '裁切填充', '拉伸填充', '4:3'];
/** 剧集分组大小（`_kEpisodeGroupSize`）。 */
const EPISODE_GROUP_SIZE: number = 100;
/** 剧集行高与行间分隔线（§37.3），定位滚动按 57 一档换算。 */
const EPISODE_ROW_HEIGHT: number = 56;
/**
 * 行间分隔线高度（vp）。
 *
 * 2026-09-18 美化：剧集行改成**圆角选中卡**，卡片之间不再画满宽分割线
 * （线 + 圆角卡片在真机截图里看就是「没闭合的框」）。这个常量同时参与
 * `scrollEpisodeToLocal` 的行距换算，所以必须跟着一起归零。
 */
const EPISODE_ROW_DIVIDER: number = 0;
/**
 * 剧集面板顶部的高度（vp）＝ 标题行 52 + 信息行 32。
 *
 * 2026-09-18 美化新增信息行：「第 N 集 / 共 M 集 · 上次看到 12:34」。
 * 长番最常问的就是「我看到哪了」，而目录里原先一点进度信息都没有。
 * 这里刻意**不显示实时播放位置**：`positionMs` 是 2Hz 更新的 @State，
 * 目录是常驻可见的，读它会让整页（含视频 Stack）每 500ms 重排一次——
 * 工程里别处都在躲这件事（见 `rotating` 那段注释）。改读历史里的
 * 「上次看到」，只在切集时算一次。
 */
const EPISODE_HEADER_HEIGHT: number = 52;
const EPISODE_INFO_HEIGHT: number = 32;
/**
 * 目录里**当前集**那条进度线的刷新间隔（ms）。
 *
 * 2026-09-22 用户要求「目录页上的集的时长进度条随时更新」，于是这里从
 * 「只读历史快照」改成**实时**。之所以不是直接用 500ms 的轮询节奏：
 * `positionMs` 每 500ms 变一次，读它的那行 `ListItem` 就得重建一次；
 * 1 秒一拍已经足够跟手，重建次数直接减半。
 *
 * ⚠️ **只有当前集读这个值**（别的行仍然是历史快照），所以重建范围限于
 * 那一行的子树，不会像当年担心的那样「整页每 500ms 重排」。
 * 真正让它看起来连续的是 key 里的**千分比**（0.1% ≈ 0.3vp，亚像素），
 * 见下面 key 生成器的注释。
 */
const LIVE_PROGRESS_INTERVAL_MS: number = 1000;
/**
 * 进度线宽度变化时的动画时长（ms）。
 *
 * 正常路径用不上（行是按 key 重建的，没有「旧值 → 新值」的过渡），
 * 留着给「哪天改成属性级更新」用；见进度线那段注释。
 */
const LIVE_PROGRESS_ANIM_MS: number = 900;
/**
 * 面板头部的**动画标题**字号（vp）。
 *
 * 用户 2026-09-18：「播放页下面卡片的那行动画标题调大一点点」。
 * 原来是 15，与 14 的集标题几乎一样大、层级拉不开；提到 17 之后
 * 「剧名 / 集标题 / 信息行（11）」是清楚的三级。
 */
const EPISODE_TITLE_SIZE: number = 17;
/** 右侧快速定位条宽度（vp，仅分段数 > 1 时出现）。 */
const EPISODE_SCRUBBER_WIDTH: number = 22;
/**
 * 弹层退场时长（ms）——**取自源码**。
 *
 * 参照实现 `bean/dialog/adaptive_bottom_sheet.dart` 的 `AnimationStyle`：
 * `duration: 250ms`（入场）、**`reverseDuration: 200ms`（退场）**，
 * 曲线 `Easing.legacyDecelerate`（两个方向都是）。所以退出不是弹簧、
 * 而是「短一点 + 减速」的干脆收束；入场才带弹簧过冲。
 */
const SHEET_EXIT_MS: number = 200;

/**
 * 视频画面在视频区容器里的实际矩形（vp）。
 *
 * ArkTS 没有元组/匿名结构，用一个最小类带出来。
 */
class VideoBox {
  w: number = 0;
  h: number = 0;
}
/**
 * 底栏**时间码 + 进度条**合并行的行高。
 *
 * 用户 2026-09-18：「进度条太高了」。官方参考图里这一行只有时间码那么高
 * （文字约 11vp，上下各留 4–5vp），而原来沿用「时间行 20 + 进度行 20 = 40」，
 * 底栏整体被顶高、进度条上下都是空档。合成一行后取 22。
 */
const TIME_ROW_HEIGHT: number = 20;
/**
 * 进度条行高。
 *
 * ⚠️ 参照实现用的是 `audio_video_progress_bar`：手机端 `timeLabelLocation = none`，
 * 整条高度取 `_heightWhenNoLabels() = max(2 * thumbRadius, barHeight)`
 * = max(2×8, 5) = **16vp**。ArkUI 的 `Slider` 默认高 40vp，直接用会把底栏撑高 24vp，
 * 这正是「下栏还是太高」的主因 —— 所以这里显式压到 20（比源码略宽松，方便点按）。
 */
/** 进度条那一行（与时间码同一行）的高度。 */
const SLIDER_ROW_HEIGHT: number = 20;
/**
 * 控制行高。
 *
 * 源码是 IconButton 默认的 **48**；用户两次反馈「下栏太高」，这里压到 **40**
 * （图标仍是 24，左右各留 8）。40 也是触控热区的常见下限，
 * 再小就该换成「底栏整体上滑展开」式的交互了。
 */
const CONTROL_ROW_HEIGHT: number = 36;
/**
 * 控制层统一水平边距（vp）：最外侧按钮的外边缘距视频区边缘的距离。
 *
 * 底栏本来就是这一档（行内 padding 10 + 内层行 padding 10 = 20），
 * 顶栏此前**贴边 0**、右侧竖排按钮**贴边 4**，三组各排各的——
 * 全屏时一眼就能看出没对齐。这里统一成同一个常量。
 * 全屏时再叠加系统左右安全区（`leftInset` / `rightInset`）。
 */
const CONTROL_EDGE_INSET: number = 20;
/** 右侧竖排按钮（截图 / 锁定）单个的高度：图标 20 + 上下 padding 10。 */
const SIDE_BUTTON_VP: number = 40;
/**
 * 底栏**内容高度**（不含系统底距）。
 * 参照实现 `bottomControlWidget` 在手机竖屏是 时间 24 + 进度条 16 + 按钮行 48 ≈ 88，
 * 这里按用户观感收到 20 + 20 + 40 = **80**。
 * 决定底栏顶边：`y = 视频区高 − bottomBarHeight()`。
 */
/** 底栏内容高度：合并行 + 控制行（原来是 20 + 20 + 40 = 80，现在 22 + 40 = 62）。 */
const BOTTOM_BAR_HEIGHT: number = TIME_ROW_HEIGHT + CONTROL_ROW_HEIGHT;
/** 控制层三层滑入时长（§39.3）。 */
const PANEL_ANIM_MS: number = 300;
/** 两条遮罩的显隐时长（§39.4：比面板慢，1 秒）。 */
const MASK_ANIM_MS: number = 1000;
/** HUD 常规进出 200ms（§15.11）。 */
const HUD_ANIM_MS: number = 200;
/**
 * 亮度 / 音量 HUD 面板宽度。
 *
 * 参考图逐像素实测（`播放页美化/69033a…`、`94609d…`，横屏 2412px = 804vp）：
 * 那条指示线本身是 **x 1038→约 1445 = 407px ≈ 136vp**（线右侧到 1445 是
 * 白 30% 的未填充段，1445 之后直接回到画面），整条 HUD 以屏幕中心对称。
 *
 * 第一次量成了「图标+线+一个亮点」的整体跨度 290–336vp，按那个做的 340 宽
 * 明显偏长（用户 2026-09-18：「音量条太长了，亮度条太长了」），已改回实测值：
 * 胶囊 180 = 内距 8 + 图标 20 + 间距 8 + 线 136 + 内距 8。
 */
const HUD_ADJUST_WIDTH: number = 180;
/** 进度 HUD 面板宽度（§30.1）。 */
const HUD_SEEK_WIDTH: number = 248;
/**
 * 进度 HUD 面板高度：图标胶囊 36 + 上下内距 8×2 = 52。
 *
 * 之前没写高度，面板被父级 `height('100%')` 的 HUD 列拉成**竖长条**
 * （用户 2026-09-18：「调整进度条时，中间那个东西太高了太大了」）。
 */
const HUD_SEEK_HEIGHT: number = 52;
/** 倍速 HUD 面板宽度（`player_adjustment_hud.dart` 的 `PlayerSpeedHud`）。 */
const HUD_SPEED_WIDTH: number = 94;
/** HUD 距视频区顶部（参照实现 `player_item_panel.dart:486` 的 `top: 25`）。 */
const HUD_TOP: number = 25;
/** 指示线长度：官方实测 136vp（胶囊 180 − 内距 16 − 图标 20 − 间距 8）。 */
const HUD_TRACK_WIDTH: number = 136;
/** HUD 胶囊高度（图标 20 + 上下内距各 8）。 */
const HUD_TRACK_HEIGHT: number = 36;
/** 轨道两端的圆角（`_HudSliderTrackShape` 的 outerRadius）。 */
const HUD_TRACK_OUTER_RADIUS: number = 12;
/** 轨道在滑块两侧留出的缺口一半（`_HudSliderTrackShape` 的 thumbGap/2）。 */
const HUD_THUMB_HALF_GAP: number = 6;
/** 轨道两端内缩（`_HudSliderTrackShape` 的 edgeInset）。 */
const HUD_TRACK_EDGE: number = 6;
/**
 * 播放页 HUD 的深色玻璃底。
 *
 * 对齐 `播放页美化/` 里的参考图：音量 / 亮度 / 进度 HUD 都压在**视频画面**上，
 * 一律用半透明黑底 + 白字白线。原来沿用主题的 `surfaceContainerHighest`
 * （浅色主题下是一块近白）压在画面上，比视频本身还亮，既不沉浸也刺眼。
 */
const HUD_GLASS_BG: string = '#CC000000';
/** HUD 描边：白 20%。 */
const HUD_GLASS_BORDER: string = '#33FFFFFF';
/** HUD 图标胶囊底：白 20%。 */
const HUD_GLASS_CHIP: string = '#33FFFFFF';
/** HUD 轨道未填充段：白 30%。 */
const HUD_TRACK_IDLE: string = '#4DFFFFFF';
/** 顶栏右侧「悬浮圆钮」直径（参考图里就是几颗圆钮，图标仍是 24）。 */
const TOP_FLOAT_BUTTON: number = 36;
/**
 * HUD 指示线的粗细（vp）。
 *
 * 从参考图实测：底部进度条与亮度/进度 HUD 的那条线都是 **12px ≈ 4vp**
 * （图宽 2412px / 3 = 804vp，与真机同尺度）。用户 2026-09-18：
 * 「ui 播放页的美化包括条粗细也得学」——所以 HUD 里那条线也按 4vp 画，
 * 不再用参照实现那套 32 高的粗轨道。
 */
const HUD_LINE_HEIGHT: number = 4;
/** 底栏进度条两端时间码的占宽（`00:00` 左右，用于推算「进度条长度」）。 */
const SHEET_TIME_LABEL_VP: number = 40;
/** 历史落盘间隔：轮询是 500ms 一次，每 3 秒写一次盘就够（§60 无节流要求，属工程取舍）。 */
const HISTORY_REPORT_INTERVAL_MS: number = 3000;
/** 顶部 / 底部渐隐遮罩高度（§39.4）。 */
const TOP_MASK_HEIGHT: number = 50;
const BOTTOM_MASK_HEIGHT: number = 100;
/** 超分辨率档位文案（§15.3）。 */
const SUPER_RESOLUTION_LABELS: string[] = ['关闭', '效率档', '质量档'];
/** Anime4K 效率档（与阶段 0 真机验证时用的是同一组）。 */
const ANIME4K_EFFICIENCY: string[] = [
  'Anime4K_Clamp_Highlights.glsl',
  'Anime4K_Restore_CNN_S.glsl',
  'Anime4K_Upscale_CNN_x2_S.glsl',
  'Anime4K_AutoDownscalePre_x2.glsl',
  'Anime4K_AutoDownscalePre_x4.glsl'
];
/** Anime4K 质量档。 */
const ANIME4K_QUALITY: string[] = [
  'Anime4K_Clamp_Highlights.glsl',
  'Anime4K_Restore_CNN_M.glsl',
  'Anime4K_Upscale_CNN_x2_M.glsl',
  'Anime4K_AutoDownscalePre_x2.glsl',
  'Anime4K_AutoDownscalePre_x4.glsl'
];

/** 手势进行中的模式（与 ArkUI 的 `GestureMode` 刻意不同名）。 */
enum PlayerGesture {
  none = 0,
  seek = 1,
  brightness = 2,
  volume = 3
}

/** `#RRGGBB` + alpha → `#AARRGGBB`。 */
function withAlpha(color: string, alpha: number): string {
  const a: string = Math.round(alpha * 255).toString(16).toUpperCase().padStart(2, '0');
  return `#${a}${color.substring(1)}`;
}

/**
 * 播放页。
 * 对应参照实现 `lib/pages/video/video_page.dart` + `video_controller.dart`
 * + `pages/player/player_item.dart`（手势 / 控制层）
 * + `episode_selection_panel.dart`（剧集面板）。
 *
 * 链路：详情页选来源 → 本页 `changeEpisode` → 播放页地址归一化
 *      → 无头 `VideoSourceWebHost` 三通道取流 → mpv `loadfile` → 出画面
 *
 * 竖屏（手机）布局与源码一致：视频区 16:9 固定在上、剧集面板占满剩余空间；
 * 全屏时视频铺满整窗，剧集面板改为右侧滑入的覆盖层
 * （120ms，面板 easeOut / 遮罩 easeIn，§37.2）。
 */
@Component
export struct VideoPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('bottomInset') bottomInset: number = 28;
  /** 横屏时的左右安全区（刘海/挖孔），全屏三组控制都要让开。 */
  @StorageProp('leftInset') leftInset: number = 0;
  @StorageProp('rightInset') rightInset: number = 0;
  @StorageProp('themeRevision') themeRevision: number = 0;

  // ---- 路由参数 ----
  private item: BangumiItem = new BangumiItem();
  private plugin: Plugin | null = null;
  private sourceTitle: string = '';
  /** 当前真正在播的地址（抓到的播放源），「外部播放」要用它。 */
  private currentVideoUrl: string = '';
  /** 番剧页地址（搜索结果里的 `src`）：历史记录的 `lastSrc`，历史页重进源时要用。 */
  private infoSrc: string = '';
  // ---- 离线播放（§18：下载完成后不进 WebView，直接播本地清单） ----
  /** 本集是否离线播放。 */
  private offline: boolean = false;
  /** 离线模式下「集数 → 本地清单路径」。 */
  private offlinePaths: Map<number, string> = new Map<number, string>();

  // ---- 播放历史（阶段五 §19 / §60） ----
  /** 本集剧集页地址（`lastWatchEpisodeName` 之外的 `episodePageUrl`）。 */
  private currentEpisodePageUrl: string = '';
  /** 上次写历史的时间：轮询 500ms 一次，不能每次都落盘。 */
  private lastHistoryReportMs: number = 0;
  /** 本集起播时的续播偏移（秒）；0 表示从头。 */
  private resumeOffsetSec: number = 0;

  // ---- 弹幕（阶段五 §43.1 / §61） ----
  /** 本集全部弹幕（已按来源 / 屏蔽 / 去重过滤）。 */
  private danmakuEntries: DanmakuEntry[] = [];
  /** 调度器（游标 + 轨道占用，纯逻辑）。 */
  private danmakuSchedule: DanmakuSchedule = new DanmakuSchedule();
  /** 开关（默认取 `danmakuEnabledByDefault`，也就是**上次离开时的状态**）。 */
  @State private danmakuOn: boolean = true;
  /** 在屏弹幕（驱动渲染）。 */
  @State private activeDanmakus: ActiveDanmaku[] = [];
  /** 弹幕状态提示（取弹幕中 / 无弹幕 / 取弹幕失败）。 */
  @State private danmakuHint: string = '';
  /**
   * 分集标题版本号（Bangumi / 哔哩哔哩补到的标题到达后 +1）。
   *
   * ArkUI 按属性粒度更新：`episodeLabel()` 里必须读到这个状态，
   * 异步结果到达才会重绘目录行与顶栏标题。
   */
  @State private episodeTitleRev: number = 0;
  /** 弹幕设置弹层（§61.1）/ 时间校准弹层（§61.2）。 */
  @State private showDanmakuSheet: boolean = false;
  @State private showDanmakuOffset: boolean = false;
  /** 弹幕设置弹层里的界面版本号：滑杆改动后 +1，让文案立刻刷新。 */
  @State private danmakuSettingsRev: number = 0;
  /** 底栏弹幕输入框的内容（源码 `danmakuTextField`）。 */
  @State private danmakuInputText: string = '';
  /**
   * 弹幕开关是否已经按「默认开启弹幕」初始化过。
   *
   * 只在**进入播放页的第一次**取设置值；此后切集一律保留用户当前的选择。
   * 以前每次切集都重新读默认值（默认 false），于是用户手动打开的弹幕
   * 切一集就被静默关掉——表现正是「有时候加载不出来」。
   */
  private danmakuToggleReady: boolean = false;
  /** 「本集暂无弹幕」的 toast 只提示一次，避免切集时反复弹。 */
  private danmakuEmptyToastShown: boolean = false;
  // ---- 投屏（§15） ----
  @State private showDlnaSheet: boolean = false;
  @State private dlnaDevices: DlnaDevice[] = [];
  @State private dlnaSearching: boolean = false;
  @State private dlnaMessage: string = '';
  @State private dlnaDirectAddress: string = '';
  @State private dlnaDirectConnecting: boolean = false;
  /** 防止切换集数后，上一集较慢的投屏准备结果覆盖当前状态。 */
  private dlnaCastToken: number = 0;

  // ---- 线路与剧集 ----
  @State private roads: Road[] = [];
  @State private currentRoad: number = 0;
  @State private currentEpisode: number = 1;
  /** 剧集面板里正在浏览的线路（点线路菜单切换，选集后才真正生效）。 */
  @State private visibleRoad: number = 0;
  @State private segmentGroup: number = 0;
  /** 目录是否按倒序显示。分段仍用真实段号，切换顺序时当前集保持可见。 */
  @State private episodeReversed: boolean = false;
  @State private episodeNames: string[] = [];
  private episodeScroller: Scroller = new Scroller();
  private segmentScroller: Scroller = new Scroller();
  /**
   * 分段条每个胶囊的 x 与宽度（`onAreaChange` 实测，单位 vp）与视口宽度。
   *
   * 用途：ArkUI 的 `scrollToIndex` 不支持自定义时长 / 曲线，
   * 而 §38.8 要求「分段滚入视野 260ms `easeOutCubic`」，
   * 所以按实测几何算偏移后用 `scrollTo({animation})` 精确复刻
   * （与收藏页胶囊居中的做法相同）。
   */
  private segmentX: number[] = [];
  private segmentWidth: number[] = [];
  private segmentViewport: number = 0;
  /** 剧集列表视口高度（vp），用于「居中 + 1.5 倍视口才走动画」的判定。 */
  private episodeViewport: number = 0;

  // ---- 取流 ----
  @State private loading: boolean = true;
  @State private loadingHint: string = '视频资源解析中';
  @State private errorMessage: string = '';
  @State private captureUrl: string = '';
  @State private reloadToken: number = 0;
  @State private sourceLogs: string[] = [];

  // ---- 播放器 ----
  private engine: PlayerEngine | null = null;
  private xController: XComponentController = new XComponentController();
  /** 防止页面销毁或连续 Surface 回调时，旧的延迟绑定任务覆盖新 Surface。 */
  private surfaceAttachRevision: number = 0;
  private pollTimer: number = -1;
  /** 已请求的窗口常亮状态；null 表示还没设过（或上次设置失败，等下一拍重试）。 */
  private keepScreenOnRequested: boolean | null = null;
  private hideTimer: number = -1;
  @State private engineAvailable: boolean = true;
  @State private playing: boolean = false;
  @State private positionMs: number = 0;
  @State private durationMs: number = 0;
  @State private speed: number = 1.0;
  @State private aspect: AspectRatioMode = AspectRatioMode.automatic;
  @State private panelVisible: boolean = true;
  /** 面板亮度 0–1。**不能叫 `brightness`**：与 ArkUI 内置组件属性同名会冲突。 */
  @State private panelBrightness: number = 0.5;
  @State private volume: number = 100;
  /** 系统媒体音量的量程（`AudioVolumeManager.getMaxVolume` 的返回值）。 */
  private mediaVolumeMax: number = 0;
  /** 系统音量管理器；为空表示这台设备/这次运行拿不到系统音量，回落播放器音量。 */
  private volumeManager: audio.AudioVolumeManager | null = null;
  /** 系统音量管理器（`setVolume` 在 `AudioManager` 上；与 `volumeManager` 同生共死）。 */
  private audioManager: audio.AudioManager | null = null;
  /**
   * **音量手势自己的累加值**。
   *
   * ⚠️ 手势里不要拿 `this.volume` 当基准：系统音量的 `streamVolumeChange`
   * 回调随时会把 `this.volume` 覆盖成系统当前值，一边拖一边被冲回去，
   * 真机表现就是「音量只能微小抖动、大动不了」（2026-09-16 实测：
   * 手指从 y=38 拖到 y=180vp，音量只在 71%–73% 之间抖）。
   */
  private volumeGestureTarget: number = 100;
  /**
   * 本次音量手势**开始时**的显示值（对手势结束时「系统到底动没动」的对账基准）。
   * -1 = 还没开始过音量手势。
   */
  private volumeGestureStartPercent: number = -1;
  /**
   * 手势结束对账的令牌：每开始一次新的音量手势就 +1，
   * 让上一次还没跑完的延时对账作废（否则它会把新手势的值改回去）。
   */
  private volumeVerifyToken: number = 0;
  /**
   * 最近一次**我们自己**写系统音量的时刻。
   *
   * 用途：`setVolume` 会回吐 `streamVolumeChange`，而且这些回调是**异步、可能迟到**
   * 的。手势结束后迟到的旧值回调如果被当成「外部音量键改了音量」写回 HUD，
   * 就又是一次回弹（2026-09-19 用户反馈的现象）。所以紧跟在自己写之后的
   * 那一段时间窗口里，回调一律当回声忽略。
   */
  private lastSelfVolumeWriteAt: number = 0;
  /** 系统音量是否真的写得动；置 false 后改由播放器音量接管。 */
  private sysVolumeWritable: boolean = true;

  // ---- HUD（§15.11） ----
  @State private showSeekHud: boolean = false;
  @State private hudSeekMs: number = 0;
  /**
   * 拖进度 HUD 的方向（§46.4：`fast_forward_rounded` → `fast_forward`、
   * `fast_rewind_rounded` → `fast_mirroring`）。
   */
  @State private hudSeekForward: boolean = true;
  @State private showSpeedHud: boolean = false;
  @State private showBrightnessHud: boolean = false;
  @State private showVolumeHud: boolean = false;

  // ---- 全屏 / 剧集面板 ----
  @State private fullscreen: boolean = false;
  /**
   * 「想要的全屏状态」。
   *
   * 与 `fullscreen`（**已经落地的**布局状态）分开：点全屏只改这个 + 请系统转屏，
   * 布局等旋转结束后由 `applyFullscreenState()` 一次性落地——旋转过程中画面
   * 不会先「跳」一下（用户 2026-09-18：「竖屏变全屏不够丝滑」）。
   */
  private fullscreenIntent: boolean = false;
  @State private showPanelInFullscreen: boolean = false;
  /** 正在按压的剧集号（-1 = 无）；弹簧按压见 `setEpisodePressed`。 */
  @State private pressedEpisode: number = -1;
  /**
   * 面板信息行的「上次看到 mm:ss」（空串 = 这一集没有观看记录）。
   *
   * 只在 `changeEpisode` 里更新：它来自历史记录、切集才变，
   * 不读 2Hz 轮询的 `positionMs`（原因见 `EPISODE_HEADER_HEIGHT` 的注释）。
   */
  @State private watchedLabel: string = '';
  /**
   * 目录里**当前集**的实时进度（0–1，0 = 还没起播 / 不画）。
   *
   * 用户 2026-09-22：「目录页上的集的时长进度条要不随时更新？」——要。
   * 由轮询每 `LIVE_PROGRESS_INTERVAL_MS` 拍一次写进来；
   * **只被当前那一行的进度线读取**（别的行读 `panelProgressRatio()` 的历史快照），
   * 所以重绘范围就是那一行。切集时清 0（见 `changeEpisode`）。
   */
  @State private liveProgressRatio: number = 0;
  /** 上一次写入 `liveProgressRatio` 的时刻（做 1 秒节流用）。 */
  private liveProgressTickAt: number = 0;
  /**
   * 分集标题「到达」时的淡入系数（0.35 → 1）。
   *
   * 标题是异步拉的：目录先显示「第 N 集」，标题到位后整列文字会**瞬间**
   * 换成真标题（用户看到的就是一次跳动）。这里让它在 180ms 里淡进来。
   * 挂在页面级 @State 上，所有行一起淡入，不额外增加节点。
   */
  @State private episodeTitleFade: number = 1;
  /** 右侧快速定位条的实测高度（vp，0 = 还没测到）。 */
  @State private scrubberHeight: number = 0;
  /** 拖动右侧定位条时的小气泡文案（空串 = 不显示）。 */
  @State private scrubberHint: string = '';
  /**
   * 剧集列表是否已经滚动（头部收缩用）。
   *
   * 只在「跨过阈值」时更新（见 `historyList` 同款写法）：`onDidScroll`
   * 每帧都来，无条件写状态会让常驻可见的目录每帧重排一次。
   */
  @State private episodeListScrolled: boolean = false;
  /**
   * 弹幕时间校准的当前值（秒）。
   *
   * 校准卡片里的数值文本读它、滑杆写它——用状态串起来，拖动时数字才会
   * 跟着手指变（读设置的话，父层不重渲染就一直是旧值）。
   * 进页面时按设置初始化，打开卡片时再同步一次，避免别处改过之后显示旧值。
   */
  @State private danmakuOffsetValue: number = 0;
  /** 截图反馈叠层的触发计数（每截图一次 +1，见 `ScreenshotFeedback`）。 */
  @State private screenshotToken: number = 0;
  /** 「弹幕轨道已满、省略了 N 条」日志的节流时间戳（5 秒一条，见 `emitDanmakus`）。 */
  private danmakuDropLogAt: number = 0;
  /**
   * 上一次采样到的播放位置（毫秒），用于累加**真实观看时长**。
   *
   * `-1` = 还没有基准（刚起播 / 刚切集 / 刚拖过进度），下一拍只记基准不计时长。
   */
  private lastWatchSampleMs: number = -1;
  /**
   * 亮度/音量 HUD 的收起定时器（-1 = 空闲）。
   *
   * 对应参照实现 `player_item.dart` 的 `_adjustmentHudHideTimer`：
   * 每次「显示调节条」先取消它、每次「结束调节」重新排一次，
   * 定时器到点就**无条件**收起两条。原来用的是「令牌 + 手势进行中就
   * 直接放弃」，漏了一种情况：拖完音量马上接着拖进度，收起回调看到
   * 还有手势在跑就 return，之后再没人排 → 音量条永远留在屏幕上。
   */
  private adjustHudHideTimer: number = -1;
  /** surface 尺寸去抖计时器（-1 = 空闲），见 `scheduleSyncSurfaceSize`。 */
  private surfaceSyncTimer: number = -1;
  /** 暂停旋转时专用的快速 surface 同步计时器。 */
  private pausedSurfaceTimer: number = -1;
  private lastPausedSurfaceWidthPx: number = 0;
  private lastPausedSurfaceHeightPx: number = 0;
  /**
   * 全屏布局落地的兜底定时器（-1 = 空闲）。
   *
   * 正常路径是「窗口一旋转就落地」（见 `onAreaChange` 里的宽度变化判断）；
   * 万一设备没转（模拟器 / 分屏 / 传感器禁用），靠它兜底把状态落下去，
   * 否则按钮点了没反应。
   */
  private fullscreenApplyTimer: number = -1;
  /**
   * 「**下一次** `onAreaChange` 必须立刻同步 surface 尺寸」。
   *
   * 全屏布局一落地，视频区矩形就会换一个长宽比（竖屏：整屏 360×800 →
   * 16:9 的 360×202，差了 4 倍）。mpv 的输出缓冲跟不上这一下，
   * 合成器会把旧缓冲硬压进新矩形——用户看到的就是「全屏退回竖屏时画面
   * 被压缩一下」（2026-09-18）。
   *
   * 不能在 `applyFullscreenState()` 里直接同步，**也不能在同一帧的
   * `onAreaChange` 里同步**：那两次拿到的 `viewportWidth/Height` 都还是
   * 「布局变化前」的矩形（布局刚改、还没量到），用它去开缓冲，画面照样被
   * 压（用户 2026-09-18：「旋转过程中会压缩，压缩的过大了」——就是我上一版
   * 在同一帧同步造成的）。
   *
   * 所以这里只打标记，由**紧随其后的那一次** `onAreaChange` 消费——
   * 那时回调里的尺寸已经是布局后的，立即同步才对得上。
   */
  private pendingImmediateSync: boolean = false;
  /**
   * 弹层正在播退场动画（逻辑上已关闭，但还留在树上等动画走完）。
   *
   * 为什么需要自己管：弹层整棵子树由外层 `if` 一次性移除，ArkUI 在这种场景下
   * **不播子树内部节点的退场 transition**（入场会播——节点是随新子树一起进来的）。
   * 所以「点旁边收起」原来一直是直接消失。
   *
   * 参数照源码：退场 200ms + 减速曲线（`adaptive_bottom_sheet.dart` 的
   * `reverseDuration: 200ms` / `reverseCurve: legacyDecelerate`），
   * 动画走完再真正移除——那时面板已在屏幕外，移除不可见。
   */
  @State private sheetExiting: boolean = false;
  private sheetExitTimer: number = -1;
  /**
   * 是否正在做竖屏 ↔ 全屏的旋转。
   *
   * 旋转期间只保留视频画面：弹幕层每帧都要按新容器尺寸重排 N 条飞行中的弹幕，
   * 叠在系统旋转动画上就是可感知的掉帧（用户 2026-09-18 反馈的「旋转卡顿」）。
   */
  @State private rotating: boolean = false;
  /** 旋转态复位计时器。 */
  private rotatingTimer: number = -1;
  /** 顶栏收藏按钮的重绘版本号（收藏状态存在 CollectStore 里，不是 @State）。 */
  @State private collectRev: number = 0;

  // ---- 菜单（HarmonyOS 原生菜单 `bindMenu`） ----
  /**
   * 六个选项菜单的展开态：倍速 / 画面比例 / 线路 / 更多 / 超分辨率 / 定时关闭。
   *
   * 用**布尔量 + `bindMenu(isShow, builder, options)` 三参重载**
   * （与 `SearchPage` 排序菜单、`ThemeSettingsPage` 深浅色菜单同一套写法），
   * 不用单参重载——三参重载能在 `onDisappear` 里把状态收回来，
   * 于是返回键（`onBackPress`）也能关菜单。
   *
   * 为什么不再自绘浮层：自绘版本只是「`bindMenu` 不展开」的将就方案
   * （见 `docs/02-工作计划.md` 阶段四记录）。后来追番按钮的六项菜单用
   * **内置容器 + `bindMenu`** 实测可用，观感就是 HarmonyOS 原生菜单；
   * 用户明确要求「选项弹窗照它重做」，故六个菜单全部改为原生承载：
   * 毛玻璃底、圆角、投影、出现动画、点击外部关闭、按键与读屏语义
   * 全部由系统给，比自绘更省事也更像系统。
   */
  @State private speedMenuOpen: boolean = false;
  @State private aspectMenuOpen: boolean = false;
  @State private roadMenuOpen: boolean = false;
  @State private moreMenuOpen: boolean = false;
  @State private srMenuOpen: boolean = false;
  @State private showVideoInfo: boolean = false;
  /** 播放器详情弹层的分段：0 参数 / 1 日志（§40.2）。 */
  @State private videoInfoTab: number = 0;

  // ---- 锁定 / 截图 / 超分辨率 / 定时关闭（§39.5.2、§39.7、§15.3） ----
  /** 锁定面板：锁上后只留解锁按钮，其它控件一律收起来。 */
  @State private locked: boolean = false;
  private skipTimeDialog: CustomDialogController | null = null;
  @State private superResolution: number = 1;
  /** 定时关闭菜单标题（有剩余时间时显示 mm:ss）。 */
  @StorageProp('timedShutdownRevision') @Watch('onShutdownTick')
  shutdownRevision: number = 0;
  @State private shutdownLabel: string = '';

  // ---- 手势 ----
  /**
   * **视频区容器**实测尺寸（vp，0 = 还没量到）。
   *
   * 用途：surface 尺寸、手势坐标、弹幕排布、进度条命中等——全都是「视频」的
   * 坐标系。⚠️ **不要拿它判横竖屏**，竖屏时它是 16:9 的扁矩形（见
   * `windowIsLandscape()` 的注释）。
   */
  @State private viewportWidth: number = 0;
  @State private viewportHeight: number = 0;
  /**
   * **根容器（= 窗口可见区）**实测尺寸（vp，0 = 还没量到）。
   *
   * 只用来判横竖屏（`windowIsLandscape`）。与视频区尺寸分开是因为竖屏时
   * 视频区按 16:9 定高，宽大于高——拿它判横竖会导致布局来回翻（见
   * `windowIsLandscape()` 的注释）。
   */
  @State private windowWidthVp: number = 0;
  @State private windowHeightVp: number = 0;
  /**
   * 进入全屏前的窗口方向。
   *
   * 不能再用 `deviceInfo.deviceType === 'phone'` 决定要不要恢复竖屏：
   * 折叠屏展开态可能被系统上报为 `tablet`，而 `deviceType` 描述的是设备
   * 类型，不是本次窗口是从什么方向进入全屏的。记录进入前方向再恢复，
   * 手机、平板、Pura X 这类宽折叠设备会走同一条可靠路径。
   */
  private orientationBeforeFullscreen: window.Orientation = window.Orientation.UNSPECIFIED;
  private hasOrientationBeforeFullscreen: boolean = false;
  /**
   * 原生窗口调用代次。
   *
   * 快速连点全屏时，上一次异步 `setPreferredOrientation()` 可能比新的操作
   * 更晚返回。每次进入/退出递增代次，旧任务在关键步骤前自动放弃，
   * 避免“刚退出回到竖屏，又被上一轮进入全屏改成横屏”。
   */
  private fullscreenNativeRevision: number = 0;
  /** 进行中的手势。**不能叫 `gesture`**：与 ArkUI 的 `.gesture()` 属性同名。 */
  private activeGesture: PlayerGesture = PlayerGesture.none;
  private gestureStartX: number = 0;
  private gestureStartY: number = 0;
  private lastMoveX: number = 0;
  private lastMoveY: number = 0;
  /** 本次手势是否从全屏顶栏区域开始；用于避开顶栏上的返回/快进/更多和状态栏下拉。 */
  private gestureInTopBar: boolean = false;
  /**
   * 上一次布局时窗口是不是横屏（宽 > 高）。
   *
   * 只用来判断「形态真的变了」：横竖切换时才决定右侧目录竖栏的默认显隐，
   * 自由窗口拉伸之类的尺寸变化不会反复把面板弹开。
   */
  private landscapeState: boolean = false;
  /**
   * 手指**按下**那一刻在视频区里的纵坐标（vp，-1 = 还没按下）。
   *
   * 只用来判「这次手势是不是落在全屏顶栏区域」。不能直接拿 `PanGesture`
   * 上报的起点：它有 5vp 的启动位移，手指按在顶栏标题上往下滑 5vp 时
   * 上报的 y 已经越过顶栏底边，于是被判成播放器手势——用户 2026-10-07
   * 反馈的「在上栏区域下滑会拖动进度条」就是它（真机是「往下滑、手指还带点
   * 横向漂移」时最容易触发，方向判定会把它认成 seek）。
   */
  private touchDownY: number = -1;
  /** 拖动进度条时暂停轮询回写，避免手指与定时器互相打架。 */
  private sliderDragging: boolean = false;
  /** 进度条在视频区里的横坐标范围（vp，根节点坐标系），由 `onAreaChange` 实测。 */
  @State private sliderLeft: number = 0;
  @State private sliderWidth: number = 0;
  /**
   * 进度条在视频区坐标系里的**实测**顶边（vp，-1 = 还没测到）。
   *
   * 底栏改成按内容自适应高度后，不能再拿 `视频区高 − 估算底栏高` 猜进度条位置，
   * 否则「拖到进度条那一行算不算拖进度」会判错。这里直接读 Slider 的
   * `onAreaChange` 实测值。
   */
  @State private sliderTopY: number = -1;
  /** 本次拖动是否落在底部控制条的进度条行上。 */
  private progressBarDragging: boolean = false;
  /**
   * 一次「调整类」手势（拖进度 / 亮度 / 音量）之后，吞掉紧随其后的那次单击。
   *
   * 用户 2026-09-18：「用手势调亮度音量包括进度条的时候不要唤起上栏和下栏」。
   * 上栏/下栏只由 `togglePanel()` 控制，而它挂在单击上——手指抬起时
   * 单击判定有可能一起成立，于是「调个亮度」顺带把控制层翻了出来。
   * 这里在识别出调整手势后立个标记，单击分支看到它就跳过，
   * 并在手势结束 700ms 后自动失效（单击判定在抬手后 ~300ms 内出结果），
   * 不会把下一次真正的单击吃掉。
   */
  private swallowTapAfterGesture: boolean = false;
  /**
   * 本集的「播完」是否已经处理过。
   *
   * 为什么需要：`keep-open=yes` 下 mpv 停在结尾时 `eof-reached` **会一直保持 yes**，
   * 而切集要重新取流（几秒），这段时间轮询仍会读到上一集的 eof——
   * 真机上实测一次播完连跳了 8 集（1 → 9 → 10）。
   * 因此加一个闩锁：处理过一次就不再处理，直到重新观测到「没在结尾」才复位。
   */
  private endedHandled: boolean = false;
  /** 长按前的倍速（§15.5）。 */
  private speedBeforeLongPress: number = 1.0;

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

  aboutToAppear(): void {
    /**
     * 播放页现在是**覆盖层**（压在详情覆盖层之上，见 `NavHost.pushInternal`），
     * 不是目的地：系统返回不会经过它的 `onBackPress`，所以改成登记一个
     * 「请开始退场」回调，由 `NavHost.handleBack` 转达。
     */
    NavHost.registerVideoExit(this.exitHook);
    // 弹幕时间校准卡片里的数值读 @State，进页面时先按设置初始化一次
    this.danmakuOffsetValue =
      SettingsStore.getNumber(SettingsKeys.danmakuTimeOffset);
    // 进页面保证系统栏是显示的（上一次可能是全屏离开、被恢复过，这里再确认一次）
    this.fullscreen = false;
    this.fullscreenIntent = false;
    this.applySystemBars();
    this.directHeaders = {};
    const args: VideoRouteArgs | null = VideoRouteArgs.pending;
    VideoRouteArgs.pending = null;
    if (args !== null) {
      this.item = args.bangumiItem;
      this.plugin = args.plugin;
      this.sourceTitle = args.title;
      this.roads = args.roads;
      this.infoSrc = args.src;
      this.setupOffline(args);
    }
    const storedSpeed: number = SettingsStore.getNumber(SettingsKeys.defaultPlaySpeed);
    this.speed = storedSpeed > 0 ? storedSpeed : 1.0;
    this.aspect = VideoPage.aspectOf(
      SettingsStore.getNumber(SettingsKeys.defaultAspectRatioType));
    const storedVolume: number = SettingsStore.getNumber(SettingsKeys.defaultVolume);
    this.volume = storedVolume >= 0 ? storedVolume : 100;
    // 音量与亮度都**跟手机同步**（对应源码 `syncVolumeToDevice` / 进入时读回
    // `ScreenBrightnessPlatform.instance.application`）：
    // 音量走系统媒体音量（这样音量键、系统面板与应用内手势是同一个值），
    // 亮度先读回手机当前亮度再接管。
    this.bindSystemVolume();
    this.syncBrightnessFromSystem();
   // 播放页状态栏：黑底 + 白图标（见 `applyStatusBar`）
   this.applyStatusBar(true);

    const preferredEpisode: number = args === null ? 0 : args.preferredEpisode;
    const preferredRoad: number = args === null ? 0 : args.preferredRoad;
    const startRoad: number = preferredRoad >= 0 && preferredRoad < this.roads.length
      ? preferredRoad : 0;
    this.changeEpisode(preferredEpisode > 0 ? preferredEpisode : 1, startRoad);
    // 分集标题（Bangumi → 哔哩哔哩兜底）：不阻塞起播，到了再重绘目录
    this.refreshEpisodeTitles();
    hilog.info(DOMAIN, TAG, '播放页打开：%{public}s（%{public}d 条线路）',
      this.sourceTitle, this.roads.length);
  }

  aboutToDisappear(): void {
    // 离开播放页：解除系统音量监听，并把窗口亮度交还系统（-1 = 跟随系统），
    // 否则应用接管过的亮度会一直留在窗口上（源码里也没有把亮度写进系统设置）。
    this.unbindSystemVolume();
    this.releaseWindowBrightness();
    // 离开播放页：状态栏图标还原成主题默认（见 `applyStatusBar`）
    this.applyStatusBar(false);
    // 离开播放页时补一次历史：轮询是每 3 秒一次，最后几秒的进度不能丢
    this.reportHistory(true);
    this.stopPolling();
    // 离开播放页必须交还常亮状态，否则系统熄屏会被一直压住
    this.updateKeepScreenOn(false);
    // 覆盖层：注销「请开始退场」回调（按引用注销，避免误删后注册的那个）
    NavHost.unregisterVideoExit(this.exitHook);
    this.clearHideTimer();
    // 清掉尺寸去抖 / 旋转态计时器，避免页面销毁后回调还打到已释放的引擎上
    if (this.surfaceSyncTimer >= 0) {
      clearTimeout(this.surfaceSyncTimer);
      this.surfaceSyncTimer = -1;
    }
    if (this.pausedSurfaceTimer >= 0) {
      clearTimeout(this.pausedSurfaceTimer);
      this.pausedSurfaceTimer = -1;
    }
    if (this.rotatingTimer >= 0) {
      clearTimeout(this.rotatingTimer);
      this.rotatingTimer = -1;
    }
    if (this.fullscreenApplyTimer >= 0) {
      clearTimeout(this.fullscreenApplyTimer);
      this.fullscreenApplyTimer = -1;
    }
    if (this.sheetExitTimer >= 0) {
      clearTimeout(this.sheetExitTimer);
      this.sheetExitTimer = -1;
    }
    const engine: PlayerEngine | null = this.engine;
    if (engine !== null) {
      this.surfaceAttachRevision += 1;
      engine.dispose();
      this.engine = null;
    }
    /**
     * 离开播放页时的全屏收尾**不能再走 `exitFullscreen()`**：
     * 那个入口会 `markRotating()` 起一个新定时器，而上面刚把定时器清掉了；
     * 更重要的是系统栏必须**立刻**恢复，否则下一个页面没有状态栏。
     * 所以这里直接调原生收尾，再就地复位布局状态。
     */
    if (this.fullscreen || this.fullscreenIntent) {
      this.exitFullscreenNative();
    }
    this.fullscreen = false;
    this.fullscreenIntent = false;
  }

  private static aspectOf(storageValue: number): AspectRatioMode {
    if (storageValue === 2) {
      return AspectRatioMode.crop;
    }
    if (storageValue === 3) {
      return AspectRatioMode.stretch;
    }
    if (storageValue === 4) {
      return AspectRatioMode.ratio4x3;
    }
    return AspectRatioMode.automatic;
  }

  // ============================================================
  // 切集 / 切线路
  // ============================================================

  private roadName(index: number): string {
    if (index < 0 || index >= this.roads.length) {
      return '暂无线路';
    }
    const name: string = this.roads[index].name.trim();
    return name.length > 0 ? name : `播放线路 ${index + 1}`;
  }

  /**
   * 把当前集滚进视野（§37.3 的 `revealCurrentEpisode` / `_revealActiveSegment`）。
   * 参照实现是 260ms easeOutCubic 的滚动定位，ArkUI 侧用 `scrollToIndex` 的平滑模式。
   */
  private revealCurrentEpisode(): void {
    const localIndex: number = this.episodeLocalIndex(this.currentEpisode);
    setTimeout(() => {
      try {
        this.scrollEpisodeToLocal(localIndex, false);
        this.revealSegment(this.segmentGroup);
        /**
         * 全屏目录是**插入式**的（前面那 60ms 只够它完成首次布局），
         * 这时 `episodeViewport` 可能还是 0，只能顶对齐。等一拍补一次，
         * 让它尽量和竖屏一样**居中**（用户 2026-09-22：「点出的目录弹窗
         * 能够定位到当前播放的集」）。
         */
        if (this.episodeViewport <= 0) {
          setTimeout(() => {
            try {
              this.scrollEpisodeToLocal(localIndex, false);
            } catch (e) {
              // 列表还没准备好，忽略
            }
          }, 120);
        }
      } catch (e) {
        // 列表尚未布局完成时忽略
      }
    }, 60);
  }

  private changeEpisode(episode: number, road: number): void {
    if (this.roads.length === 0 || road < 0 || road >= this.roads.length) {
      this.errorMessage = '集数解析失败';
      this.loading = false;
      return;
    }
    const data: string[] = this.roads[road].data;
    if (episode < 1 || episode > data.length) {
      this.errorMessage = '集数解析失败';
      this.loading = false;
      return;
    }
    /**
     * **先把上一集停掉**，再开始解析新一集（用户 2026-09-19：
     * 「切集切得很快的话，下一个集还没解析出来时会透出上一集的声音」）。
     *
     * 这一句必须放在改 `currentEpisode` **之前**：`reportHistory` 要按
     * 「还在看的那一集」记账，位置也不能被清掉。
     *
     * 参照实现每次换集都重建播放器（`player_controller.init` 里先
     * `_releasePlaybackResources()` → `playback.stop()`），所以旧的一定先停；
     * 本工程复用一个 mpv，就得自己在这一步停——否则从「点下一集」到
     * 「新地址解析出来」这段时间（几百毫秒到几秒）里，旧一集照常出声。
     */
    this.stopCurrentPlayback();
    this.currentRoad = road;
    this.visibleRoad = road;
    this.currentEpisode = episode;
    this.episodeNames = this.roads[road].identifier;
    this.segmentGroup = Math.floor((episode - 1) / EPISODE_GROUP_SIZE);
    this.errorMessage = '';
    this.loading = true;
    this.loadingHint = '视频资源解析中';
    this.positionMs = 0;
    // 换集 = 换一条时间轴：目录里那条实时进度线要从头长
    this.liveProgressRatio = 0;
    this.liveProgressTickAt = 0;
    // 换集 = 换了一条播放时间轴：观看时长的采样基准要重来
    this.lastWatchSampleMs = -1;
    this.durationMs = 0;
    this.sourceLogs = [];
    /**
     * 丢掉上一集「surface 还没就绪、先攒着等补播」的地址。
     *
     * 不清的话，用户在 surface 就绪前切集，`onLoad` 里的补播会把
     * **上一集**的地址播出去（同一类「过期状态盖当前状态」的问题）。
     */
    this.pendingSource = '';
    this.pendingAudioUrl = '';

    // 离线时 `data[集号-1]` 已经是**本地清单的绝对路径**，不能再走
    // `EpisodeUrl.normalize`（那是给网页地址补全用的，会把本地路径当成相对地址处理）
    const baseUrl: string = this.plugin === null ? '' : this.plugin.baseUrl;
    const pageUrl: string = this.offline
      ? data[episode - 1]
      : EpisodeUrl.normalize(baseUrl, data[episode - 1]);
    this.currentEpisodePageUrl = pageUrl;
    // 换集要把弹幕整批换掉：游标、轨道占用、在屏弹幕一起清
    this.loadDanmaku(episode);
    // 续播偏移要**在取流之前**算好：`onSourceResolved` 里 loadfile 时一次性带上，
    // 否则会先出一帧 0 秒画面再跳（参照实现也是把偏移塞进播放参数）。
    this.resumeOffsetSec = this.computeResumeOffset(episode, road);
    // 面板信息行的「上次看到」：只在这里算一次（切集时），不参与 2Hz 轮询，
    // 免得常驻可见的目录每 500ms 重排一次
    this.watchedLabel = this.resumeOffsetSec > 0
      ? VideoPage.formatTime(this.resumeOffsetSec * 1000) : '';
    // 离线：不进 WebView，直接播本地清单
    if (this.offline) {
      const localPath: string = data[episode - 1];
      if (localPath.length === 0) {
        this.errorMessage = '这一集还没有缓存';
        this.loading = false;
        return;
      }
      this.resumeOffsetSec = 0;
      hilog.info(DOMAIN, TAG, '切集 %{public}d（离线）→ %{public}s',
        episode, localPath);
      this.onSourceResolved(new VideoSourceResult(localPath, '离线缓存', 0));
      return;
    }
    hilog.info(DOMAIN, TAG, '切集 %{public}d（线路 %{public}d）%{public}s → %{public}s',
      episode, road,
      this.resumeOffsetSec > 0 ? `续播 ${Math.round(this.resumeOffsetSec)}s` : '从头播放',
      pageUrl);
    this.armResolver(pageUrl);
  }

  /**
   * 停掉当前正在播的这一集（换集 / 解析新地址之前调用）。
   *
   * 三件事，顺序不能反：
   *   1. `reportHistory(true)` —— 切集很快时轮询（3 秒一次）可能还没写这一集，
   *      先把进度落盘再停；
   *   2. `engine.stop()` —— mpv 卸载文件，声音与画面立刻停住；
   *   3. 收掉 `playing` 与轮询 —— 停掉之后不能再按旧引擎的读数刷新进度条，
   *      新地址解析好时 `onSourceResolved` 会重新 `startPolling()`。
   */
  private stopCurrentPlayback(): void {
    this.reportHistory(true);
    const engine: PlayerEngine | null = this.engine;
    if (engine !== null && engine.isAvailable) {
      engine.stop();
    }
    this.playing = false;
    this.updateKeepScreenOn(false);
    this.stopPolling();
  }

  /**
   * 本集的起始偏移（秒）。对应参照实现的 `playResume` 行为：
   * 开关关闭时永远从 0 开始；开启时取该集已记录的进度。
   */
  private computeResumeOffset(episode: number, road: number): number {
    if (!SettingsStore.getBool(SettingsKeys.playResume)) {
      return 0;
    }
    const adapterName: string = this.playbackAdapterName();
    if (adapterName.length === 0) {
      return 0;
    }
    const progress = HistoryRepository.findProgress(this.item,
      adapterName, episode, 'online');
    if (progress === undefined || progress.progressMs <= 0) {
      return 0;
    }
    // 历史里记的线路与本次不一致时仍按进度续播（进度属于「这一集」，
    // 线路只是当次拿到的源），但把线路信息写进日志便于排查。
    if (progress.road !== road) {
      hilog.info(DOMAIN, TAG, '续播：历史线路 %{public}d 与本次 %{public}d 不同',
        progress.road, road);
    }
    return progress.progressMs / 1000;
  }

  /**
   * 离线播放准备：把下载记录拼成「一条线路」。
   *
   * 离线时没有页面地址可解析，`road.data` 直接放本地清单路径，
   * `changeEpisode` 里会跳过取流直接播——这条分支与在线链路完全分开，
   * 免得把「本地文件」塞进 `VideoSourceResolver` 里被当成页面去加载。
   */
  private setupOffline(args: VideoRouteArgs): void {
    if (args.offlinePlaylistPath.length === 0 || args.offlineEpisodes.length === 0) {
      return;
    }
    this.offline = true;
    // 离线也要把规则找回来：历史写入与弹幕缓存都按规则名索引
    if (args.offlinePluginName.length > 0) {
      this.plugin = PluginManager.find(args.offlinePluginName);
    }
    const road = new Road();
    road.name = '离线缓存';
    const sorted: OfflineEpisode[] = args.offlineEpisodes.slice();
    sorted.sort((a: OfflineEpisode, b: OfflineEpisode) =>
      a.episodeNumber - b.episodeNumber);
    // **必须按集号对齐**：播放器取地址用的是 `data[集号 - 1]`（在线时 `data` 是
    // 「第 1 集、第 2 集…」的稠密列表）。离线时只缓存了其中几集，
    // 如果直接按顺序 push，缓存了第 3 集就会落在下标 0，`changeEpisode(3)` 找不到，
    // 页面会报「集数解析失败」——真机上就是这么栽的。
    let maxEpisode: number = 0;
    for (let i = 0; i < sorted.length; i++) {
      if (sorted[i].episodeNumber > maxEpisode) {
        maxEpisode = sorted[i].episodeNumber;
      }
    }
    for (let i = 0; i < maxEpisode; i++) {
      road.data.push('');
      road.identifier.push(`第${i + 1}集（未缓存）`);
    }
    for (let i = 0; i < sorted.length; i++) {
      const index: number = sorted[i].episodeNumber - 1;
      if (index >= 0 && index < road.data.length) {
        road.data[index] = sorted[i].playlistPath;
        road.identifier[index] = sorted[i].episodeName.length > 0
          ? sorted[i].episodeName : `第${sorted[i].episodeNumber}集`;
      }
      this.offlinePaths.set(sorted[i].episodeNumber, sorted[i].playlistPath);
    }
    this.roads = [road];
    this.sourceTitle = args.title;
    hilog.info(DOMAIN, TAG, '离线模式：%{public}d 集可用缓存', sorted.length);
  }

  /**
   * 先武装解析器，再让宿主加载页面。
   * 顺序不能反：注入脚本是「文档开始」时机，页面开跑之后再挂钩就晚了。
   *
   * ⚠️ **每次取流都要带序号**（见 `resolveToken` 的注释）：
   * `VideoSourceResolver` 是单槽的，新的一次会立刻把上一次还没结束的 Promise
   * 以 `null` 收敛，而「上一集那次被作废的回调」会把「解析超时」写到
   * **当前这一集**的状态上——用户 2026-09-18：「一集还在解析时点下一集，
   * 直接显示解析超时」。
   */
  private armResolver(pageUrl: string): void {
    const token: number = this.resolveToken + 1;
    this.resolveToken = token;
    this.directHeaders = {};
    this.pendingAudioUrl = '';
    /**
     * AGE 的「PC 端不给播」补救（见 `AgedmPlayback` 的类注释）。
     *
     * 这一步是**按需要改地址**：只有 `video.cpraid = 1` 的番（例：名侦探柯南）
     * 才换成官方 App 那套解析播放页，其余番拿到的还是原来的 PC 播放页。
     * 接口失败/字段变了会返回空串，落到同一条兜底路径上，不会比改之前更差。
     */
    const pluginName: string = this.plugin === null ? '' : this.plugin.name;
    AgedmPlayback.resolve(pluginName, pageUrl).then((resolved: string) => {
      if (token !== this.resolveToken) {
        return;
      }
      this.startCapture(token, resolved.length > 0 ? resolved : pageUrl);
    }, () => {
      if (token !== this.resolveToken) {
        return;
      }
      this.startCapture(token, pageUrl);
    });
  }

  /** 武装解析器并让宿主加载 `target`：`armResolver` 的第二步。 */
  private startCapture(token: number, target: string): void {
    const promise: Promise<VideoSourceResult | null> =
      VideoSourceResolver.resolve(target, 20000);
    // 地址变了走 `targetUrl`（@Watch 触发加载），地址没变只递增令牌强制重载——
    // 两者同时变会让宿主连着加载两次同一个页面。
    if (target === this.captureUrl) {
      this.reloadToken = this.reloadToken + 1;
    } else {
      this.captureUrl = target;
    }
    promise.then((result: VideoSourceResult | null) => {
      /**
       * 这一条回调属于哪一次取流？过期的一律丢弃。
       *
       * 迟到的**成功**结果更要丢：照单全收会把它当成当前这一集播出去
       * （画面是上一集的内容），比误报一次「解析超时」严重得多。
       */
      if (token !== this.resolveToken) {
        hilog.info(DOMAIN, TAG, '丢弃过期取流结果（第 %{public}d 次已作废）', token);
        return;
      }
      if (result === null) {
        this.loading = false;
        this.errorMessage = '视频解析超时，请重试';
        return;
      }
      this.onSourceResolved(result);
    });
  }

  /** 抓到播放地址 → 交给 mpv。 */
  private onSourceResolved(result: VideoSourceResult): void {
    hilog.info(DOMAIN, TAG, '命中播放源（%{public}s，%{public}dms）：%{public}s',
      result.channel, result.elapsedMs, result.url);
    this.currentVideoUrl = result.url;
    this.loading = false;
    this.loadingHint = '视频资源解析成功, 播放器加载中';
    const engine: PlayerEngine | null = this.engine;
    if (engine === null) {
      // surface 还没就绪：等 XComponent 的 onLoad 里补一次
      this.pendingSource = result.url;
      return;
    }
    if (!engine.isAvailable) {
      this.loadingHint = '已取到播放地址（当前设备无 libmpv，模拟器为桩实现）';
      return;
    }
    const params = new PlaybackParams();
    params.url = result.url;
    params.audioUrl = this.pendingAudioUrl;
    params.offset = this.resumeOffsetSec;
    params.headers = this.buildHeaders();
    engine.play(params);
    engine.applyAspectRatio(this.aspect, this.captureWidth(), this.captureHeight());
    engine.setSpeed(this.speed);
    engine.setVolume(this.engineVolume());
    this.startPolling();
    this.revealCurrentEpisode();
    this.pendingAudioUrl = '';
  }

  /** surface 就绪前抓到的地址，暂存在这里等 `onLoad` 补播。 */
  private pendingSource: string = '';
  /** 与 `pendingSource` 配对的 DASH 独立音轨。 */
  private pendingAudioUrl: string = '';
  /**
   * 取流尝试的序号（每次 `armResolver` +1）。
   *
   * `VideoSourceResolver.resolve()` 是**单槽**的：新的一次解析一开始，
   * 就会把上一次还挂着的 Promise 以 `null` 收敛（防回调泄漏）。原来的
   * `.then` 不区分「这是哪一次」，于是「上一集被作废的那次」会把
   * 「视频解析超时，请重试」写进当前状态——一集还在解析时点下一集，
   * 屏幕上立刻报超时（用户 2026-09-18）。用序号把过期结果全部拦掉。
   */
  private resolveToken: number = 0;
  /** 当前 B站媒体所需的 Referer/UA/Cookie；普通网页源时为空。 */
  private directHeaders: Record<string, string> = {};

  private buildHeaders(): Record<string, string> {
    if (Object.keys(this.directHeaders).length > 0) {
      return this.directHeaders;
    }
    const headers: Record<string, string> = {};
    const userAgent: string = this.plugin === null || this.plugin.userAgent.length === 0
      ? HttpHeaders.randomUserAgent() : this.plugin.userAgent;
    headers['user-agent'] = userAgent;
    if (this.plugin !== null && this.plugin.referer.length > 0) {
      headers['referer'] = this.plugin.referer;
    }
    return headers;
  }

  private captureWidth(): number {
    return Viewport.widthVp(this.viewportWidth);
  }

  /**
   * 窗口当前是不是横屏（宽 > 高）。
   *
   * ⚠️ **必须用根容器（= 窗口可见区）的实测尺寸**，不能用 `viewportWidth/Height`
   * ——那两个是**视频区容器**的尺寸（见 `onAreaChange`），竖屏时视频区是按 16:9
   * 定高的「扁矩形」（360×202），宽本来就大于高。拿它判横竖会得到
   * 「竖屏 = 横屏」的结论，于是 `videoFillsWindow()` 先变成 true（视频区改成
   * 铺满、右侧目录竖栏弹出），铺满后视频区又变成 360×741（高 > 宽）、结论翻回
   * 竖屏，布局再改回去……一帧一个来回，永远进不去。
   * 这就是用户 2026-10-08 反馈的「手机端进播放页在平板模式和手机模式之间
   * 反复横跳」。窗口尺寸只跟窗口走，不会被视频区自身的定高方式影响。
   *
   * 首帧还没量到尺寸时退回整屏尺寸（`Viewport` 那两个方法），够用。
   */
  private windowIsLandscape(): boolean {
    const w: number = this.windowWidthVp > 0 ? this.windowWidthVp : Viewport.widthVp(0);
    const h: number = this.windowHeightVp > 0 ? this.windowHeightVp : Viewport.heightVp();
    return w > h;
  }

  /**
   * 视频区是否**铺满窗口**。
   *
   * 对照参照实现的 `videoFillsWindow = isFullscreen || isLandscape || isPip`：
   * 只有「竖屏 + 非全屏」才是老式布局（16:9 视频 + 下面常驻目录）；
   * 横屏（含**平板横屏、没点全屏**）视频区就是整个可用高度，目录改右侧竖栏，
   * 否则按 16:9 算出来的 1440×810 会把下面的目录挤成一百来 vp 的一条。
   */
  /**
   * 是否处在「进/退全屏」的转场中。
   *
   * 判据是 `fullscreenIntent` 与 `fullscreen` 是否一致，**不是** `rotating`：
   * 后者点击后 460ms 就到期，而系统旋转要 600–900ms——到期后那半秒里
   * `rotating` 已经是 false，平板判据会误触发（右侧目录竖栏闪一下）。
   */
  private inFullscreenTransition(): boolean {
    return this.rotating || this.fullscreenIntent !== this.fullscreen;
  }

  private videoFillsWindow(): boolean {
    /**
     * 进入全屏时不能因为「正在转场」就提前铺满。
     *
     * 之前这里在转场期间无条件返回 true，结果点击全屏后、系统还没开始
     * 旋转，竖屏中的视频区就先从 16:9 拉成满屏；随后系统再转一次，
     * 整段转场就会出现明显的二次跳变。
     *
     * 现在只跟随**已经落地的窗口方向**：
     *   进入：窗口变横后铺满；
     *   退出：窗口仍横时保持铺满，回到竖屏后再恢复 16:9。
     */
    return this.fullscreen || this.windowIsLandscape();
  }

  private captureHeight(): number {
    const width: number = this.captureWidth();
    if (this.fullscreen) {
      return Viewport.heightVp();
    }
    if (this.windowIsLandscape()) {
      // 视频区铺满窗口：高度取**实测**值（容器就是 '100%'，见 build()），
      // 首帧还没量到时退回整屏高（下一帧 onAreaChange 就会纠正）。
      return this.viewportHeight > 0 ? this.viewportHeight : Viewport.heightVp();
    }
    return width * 9 / 16;
  }

  /**
   * 底栏实际占高 = 内容高度 + 系统底距。
   *
   * 参照实现的 `SafeArea(bottom: videoPageController.isFullscreen)`：
   * **竖屏不加系统底距**（底栏贴在视频区底边，下面就是剧集列表），
   * 只有全屏时才让出系统手势条。
   */
  private bottomBarHeight(): number {
    return BOTTOM_BAR_HEIGHT + (this.fullscreen ? this.bottomInset : 0);
  }

  /**
   * 全屏时底栏离屏幕底边的让位。
   *
   * 用户 2026-09-18：「把现在的下栏都调低一点（包括竖屏和全屏的）」。
   * 原来整条手势区（约 28vp）全让出去，底栏显得悬在半空；参考图实测
   * 全屏控制行底边距屏底只有约 20vp，所以这里只让一半（下限 12，别压到手势条上）。
   * 竖屏本来下沿就贴视频区底边，配合行高一起收（控制行 40→36、进度行 22→20）。
   */
  private fullscreenBarBottom(): number {
    return Math.max(12, Math.round(this.bottomInset / 2));
  }

  /** 控制层左内边距：统一档位 + 全屏时的左安全区。 */
  private controlInsetLeft(): number {
    return CONTROL_EDGE_INSET + (this.fullscreen ? this.leftInset : 0);
  }

  /** 控制层右内边距：统一档位 + 全屏时的右安全区。 */
  private controlInsetRight(): number {
    return CONTROL_EDGE_INSET + (this.fullscreen ? this.rightInset : 0);
  }

  /** 右侧竖排按钮（截图 / 锁定）整列高度；锁定时只剩一个按钮。 */
  private sideColumnHeight(): number {
    return this.locked ? SIDE_BUTTON_VP : SIDE_BUTTON_VP * 2;
  }

  /**
   * 把 surface 尺寸同步给 mpv。
   *
   * **必须换算成物理像素**：`ohos-surface-size` 是给 mpv 的渲染器用的，
   * 它按像素开输出缓冲。传 vp（361×203）会让画面缩在左上角一小块——
   * 真机上就是这个现象（1084×609 的 surface 里只画出 361×203 的画面）。
   */
  private syncSurfaceSize(): void {
    const engine: PlayerEngine | null = this.engine;
    if (engine === null || !engine.isAvailable) {
      return;
    }
    const context = this.getUIContext();
    // 容器用**实测尺寸**，不要用 `captureHeight()` 推算：横竖屏切换的那一帧，
    // `display` 还没转过来，推算值会把 surface 设成 1084×2412（转置的错误尺寸），
    // 实测值才是这一帧真正的容器大小。
    const containerW: number = this.viewportWidth > 0
      ? this.viewportWidth : this.captureWidth();
    const containerH: number = this.viewportHeight > 0
      ? this.viewportHeight : this.captureHeight();
    // 缓冲按**画面矩形**开（不是容器）：与节点 1:1，谁都不用再缩放
    const box: VideoBox = this.videoBox(containerW, containerH);
    const widthVp: number = box.w;
    const heightVp: number = box.h;
    const widthPx: number = Math.round(context.vp2px(widthVp));
    const heightPx: number = Math.round(context.vp2px(heightVp));
    if (!this.playing &&
      widthPx === this.lastPausedSurfaceWidthPx &&
      heightPx === this.lastPausedSurfaceHeightPx) {
      return;
    }
    engine.resize(widthPx, heightPx);
    hilog.info(DOMAIN, TAG, 'surface 尺寸同步 %{public}dx%{public}d px',
      widthPx, heightPx);
    /**
     * paused 时 mpv 不会因为 surface 尺寸变化自动提交新帧。播放中由后续
     * 视频帧自然覆盖；暂停时必须显式重绘，否则全屏/退出全屏后最后一帧
     * 仍按旧缓冲尺寸显示，看起来就是被拉伸或缩在角落。
     */
    if (!this.playing && this.currentVideoUrl.length > 0 &&
      this.positionMs >= 0) {
      this.lastPausedSurfaceWidthPx = widthPx;
      this.lastPausedSurfaceHeightPx = heightPx;
      const pausedAt: number = engine.position();
      engine.refreshPausedFrame(pausedAt >= 0
        ? pausedAt : this.positionMs / 1000);
    }
  }

  /**
   * 视频画面在容器里的实际矩形（vp）——**等价于源码的 `BoxFit.contain`**。
   *
   * 参照实现 `player_item_surface.dart` 里视频是 `Video(fit: aspectRatioMode.fit)`，
   * 也就是画面永远按**自身比例**摆放、由它自己留黑；容器比例怎么变都只是黑边变宽变窄。
   *
   * 本工程原来反过来：XComponent 铺满容器、由 mpv 在缓冲内部留黑。只要容器长宽比
   * 变了而缓冲还没重开（旋转那几百毫秒里每帧都在变），合成器就把整块缓冲**硬拉**
   * 到新矩形里——用户看到的就是「旋转中画面被压缩，而且压得过大」（2026-09-18）。
   * 让盒子自己保持画面比例之后，这条路径根本不存在：容器怎么变，画面都不动。
   *
   * 只有「自动」比例这么做：裁切 / 拉伸 / 4:3 是**有意**变形或裁切的，
   * 那几种模式由 mpv 按容器尺寸算（`applyAspectRatio` 要的就是容器大小）。
   */
  private videoBox(containerW: number, containerH: number): VideoBox {
    const box = new VideoBox();
    box.w = containerW;
    box.h = containerH;
    if (this.aspect !== AspectRatioMode.automatic ||
      containerW <= 0 || containerH <= 0) {
      return box;
    }
    const engine: PlayerEngine | null = this.engine;
    const videoAspect: number = engine === null ? 0 : engine.videoAspectRatio();
    if (videoAspect <= 0) {
      // 还没起播 / 读不到画面尺寸：先铺满容器（此时画面上本来也没有内容）
      return box;
    }
    const fitW: number = Math.min(containerW, containerH * videoAspect);
    box.w = fitW;
    box.h = fitW / videoAspect;
    return box;
  }

  /** 画面矩形宽度（vp），供 `surface()` 用。 */
  private videoBoxW(): number {
    return this.videoBox(this.captureWidth(), this.captureHeight()).w;
  }

  /** 画面矩形高度（vp），供 `surface()` 用。 */
  private videoBoxH(): number {
    return this.videoBox(this.captureWidth(), this.captureHeight()).h;
  }

  /**
   * 合并连续的 surface 尺寸变化后再同步给 mpv。
   *
   * 真机实测（用户 2026-09-18：「现在从竖屏到全屏有旋转卡顿」）：
   * 旋转过程中视频区容器每帧都会来一次 `onAreaChange`（361×203 → 804×361
   * 之间会报好几个中间尺寸），而每次 `syncSurfaceSize()` 都会走到
   * `PlayerEngine.resize()` → **mpv 重新分配输出缓冲**。一秒内十几次原生
   * 重分配正好压在系统旋转动画上，就是那一下卡顿的主要来源。
   *
   * 这里把 120ms 内的连续变化合并成一次；`immediate` 给「首帧」用——
   * 页面刚建立时容器还没有尺寸，必须立刻同步一次，否则画面会先按错误尺寸渲染。
   */
  private scheduleSyncSurfaceSize(immediate: boolean = false): void {
    if (this.surfaceSyncTimer >= 0) {
      clearTimeout(this.surfaceSyncTimer);
      this.surfaceSyncTimer = -1;
    }
    if (immediate) {
      this.syncSurfaceSize();
      return;
    }
    this.surfaceSyncTimer = setTimeout(() => {
      this.surfaceSyncTimer = -1;
      this.syncSurfaceSize();
    }, 120);
  }

  /**
   * 暂停旋转后的快速重绘。
   *
   * 播放中的旋转仍走原来的 460ms 兜底 + 120ms surface 去抖；暂停时没有
   * 视频帧掩盖延迟，因此只等尺寸短暂稳定就立即同步并重绘。
   */
  private schedulePausedSurfaceRefresh(): void {
    if (this.playing) {
      return;
    }
    if (this.pausedSurfaceTimer >= 0) {
      clearTimeout(this.pausedSurfaceTimer);
    }
    this.pausedSurfaceTimer = setTimeout(() => {
      this.pausedSurfaceTimer = -1;
      if (!this.inFullscreenTransition()) {
        this.applyFullscreenState();
        this.syncSurfaceSize();
      }
    }, 180);
  }

  /** 当前窗口方向是否已经到达本次全屏操作想要的方向。 */
  private fullscreenRotationReached(): boolean {
    return this.windowIsLandscape() === this.fullscreenIntent;
  }

  /**
   * 标记转场开始。
   *
   * 不再用 460ms 猜测系统旋转结束：真实机型可能耗时 600–900ms。
   * 这里只放一个很长的安全兜底，正常结束由 `onAreaChange` 在目标方向
   * 稳定后调用 `scheduleFullscreenRotationSettle()`。
   */
  private markRotating(): void {
    this.rotating = true;
    if (this.rotatingTimer >= 0) {
      clearTimeout(this.rotatingTimer);
    }
    this.rotatingTimer = setTimeout(() => {
      this.finishFullscreenRotation();
    }, 1800);
  }

  /** 目标方向稳定后，等布局补间结束再恢复控制层和 Surface。 */
  private scheduleFullscreenRotationSettle(): void {
    if (!this.rotating) {
      return;
    }
    if (this.rotatingTimer >= 0) {
      clearTimeout(this.rotatingTimer);
    }
    const settleDelay: number = Math.max(200, MotionRuntime.ms(Motion.normal) + 20);
    this.rotatingTimer = setTimeout(() => {
      this.finishFullscreenRotation();
    }, settleDelay);
  }

  /** 转场结束：落地状态、恢复控件，并在稳定尺寸上补一次同步。 */
  private finishFullscreenRotation(): void {
    if (this.rotatingTimer >= 0) {
      clearTimeout(this.rotatingTimer);
      this.rotatingTimer = -1;
    }
    this.applyFullscreenState();
    if (!this.rotating) {
      return;
    }
    this.rotating = false;
    /**
     * 旋转期间控制层只是临时收起，但转场结束后不能自己弹回来：
     * 保持隐藏，等用户再次单击画面时才由 `togglePanel()` 唤醒。
     */
    this.panelVisible = false;
    this.clearHideTimer();
    this.scheduleSyncSurfaceSize();
  }

  /**
   * 把「想要的全屏状态」落到布局上。
   *
   * 状态在系统开始转屏时落地，但布局补间不再散落在多个组件上：
   * 视频区、常驻目录和侧栏的显隐共用同一条短曲线，避免一半已经切换、
   * 另一半还在系统旋转里追赶。
   *
   * 系统栏的显隐交给 `enterFullscreenNative` / `exitFullscreenNative`，
   * 这里只负责布局与控制层。
   */
  private applyFullscreenState(): void {
    if (this.fullscreen === this.fullscreenIntent) {
      return;
    }
    if (this.fullscreenApplyTimer >= 0) {
      clearTimeout(this.fullscreenApplyTimer);
      this.fullscreenApplyTimer = -1;
    }
    const applyLayout: () => void = () => {
      this.fullscreen = this.fullscreenIntent;
      /**
       * 目录竖栏默认收起（对照参照实现进全屏时的 `_hideTabBodyImmediately()`）。
       * 横屏（含平板未点全屏）才由 `onAreaChange` 里的形态同步默认打开——
       * 那里只在**横竖真的变了**时才动，不会在退出全屏的旋转过程里闪一下。
       */
      this.showPanelInFullscreen = false;
    };
    if (MotionRuntime.isOff()) {
      applyLayout();
    } else {
      animateTo({
        duration: MotionRuntime.ms(Motion.normal),
        curve: AppCurves.easeOutCubic()
      }, applyLayout);
    }
    /**
     * 状态栏底色跟着「全屏 ↔ 竖屏」换一套：竖屏黑底、全屏透明底（图标两处
     * 都是白标，见 `applyStatusBar` 的注释）。这里必须在**布局真的落地**之后
     * 调，否则进全屏的那一瞬间状态栏还是竖屏那条黑底。
     */
    this.applyStatusBar(true);
    // 布局换了长宽比：让**下一次**尺寸回调立刻喂给 mpv（见字段注释）
    this.pendingImmediateSync = true;
    this.scheduleHide();
    hilog.info(DOMAIN, TAG, '全屏布局落地 → %{public}s',
      this.fullscreen ? '横屏全屏' : '竖屏');
  }

  /**
   * 全屏时隐藏状态栏与导航条（"真全屏"）。
   *
   * 工程本来就是 `setWindowLayoutFullScreen(true)` 的沉浸式，但状态栏和
   * 导航条仍然**存在**（只是透明）——横屏看视频时它们会一直干扰视觉。
   * 退出全屏、离开播放页时都要恢复。
   */
  private async applySystemBars(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      const show: boolean = !this.fullscreen;
      // ⚠️ 第三个参数 = **让系统带动画**地显隐，参照实现
      // （`ohos/.../MethodCall.ets:101/115`）传的就是 true。
      // 不传时状态栏是「瞬间消失/出现」，全屏切换里那一下闪跳就是它。
      win.setSpecificSystemBarEnabled('status', show, true);
      win.setSpecificSystemBarEnabled('navigationIndicator', show, true);
      hilog.info(DOMAIN, TAG, '系统栏 → %{public}s', show ? '显示' : '隐藏');
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '切换系统栏失败: %{public}s', err.message);
    }
  }

  /**
   * 进入全屏的原生调用。
   *
   * **逐条对照参照实现** `ohos/entry/src/main/ets/entryability/MethodCall.ets:99`
   * 的 `enterFullScreen()`——它在 HarmonyOS 上是把全屏整个交给原生的，
   * 我之前只做了「请求横屏」，漏了三件对「丝滑」影响最大的事：
   *
   * | 参照实现 | 作用 |
   * | --- | --- |
   * | `setSpecificSystemBarEnabled(..., false, **true**)` | 系统栏**带动画**隐藏，不是瞬间消失 |
   * | `setPreferredOrientation(**AUTO_ROTATION_LANDSCAPE**)` | 走系统自动旋转通道（跟机身姿态），比硬转一档顺 |
   * | `enableLandscapeMultiWindow()` | 允许横屏多窗口，窗口不必整体重建 |
   * | `maximize()` | 自由窗口（PC/2in1）下铺满 |
   *
   * 每条单独 try：任一条在当前设备上不支持，也不影响其它几条生效。
   */
  private async enterFullscreenNative(): Promise<void> {
    const revision: number = ++this.fullscreenNativeRevision;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      if (revision !== this.fullscreenNativeRevision) {
        return;
      }
      this.captureOrientationBeforeFullscreen(win);
      /**
       * **先硬转，再收系统栏**（2026-11-01 用户要求「直接旋转到位」）。
       *
       * `AUTO_ROTATION_LANDSCAPE` 的语义是「跟随机身姿态、只允许横屏」——手机
       * 拿在手里是竖的，系统要等姿态判定，实测点下去到真正开始转约 1.3 秒。
       * `LANDSCAPE` 是明确方向，系统立即执行，没有那一段等待。
       *
       * 顺序也反过来：方向请求放在**最前面**，系统栏带动画的隐藏排在它后面，
       * 否则旋转还要再等两次系统栏动画。
       */
      await this.tryWindowCall(
        () => win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE),
        '请求自动旋转到横屏');
      await this.tryWindowCall(
        () => win.setSpecificSystemBarEnabled('status', false, true), '隐藏状态栏');
      await this.tryWindowCall(
        () => win.setSpecificSystemBarEnabled('navigationIndicator', false, true), '隐藏导航条');
      await this.tryWindowCall(() => win.enableLandscapeMultiWindow(), '开启横屏多窗口');
      await this.tryWindowCall(() => win.maximize(), '最大化窗口');
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '进入全屏失败: %{public}s', err.message);
    }
  }

  /**
   * 退出全屏的原生调用（对照 `MethodCall.ets:113` 的 `exitFullScreen()`）。
   *
   * 参照实现按 `deviceType` / 折叠态决定是否锁竖屏，但折叠屏展开时经常被
   * 上报成 `tablet`，Pura X 在展开态会因此跳过整段恢复逻辑。这里改为
   * **恢复本次进入全屏前的方向**，不再按设备类型分支。
   *
   * 调用顺序也很重要：先撤销横屏多窗口和最大化，最后再设方向。反过来的话
   * `recover()` 恢复窗口几何时可能把刚设好的竖屏再次覆盖成横屏。
   */
  private async exitFullscreenNative(): Promise<void> {
    const revision: number = ++this.fullscreenNativeRevision;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      if (revision !== this.fullscreenNativeRevision) {
        return;
      }
      await this.tryWindowCall(
        () => win.setSpecificSystemBarEnabled('status', true, true), '恢复状态栏');
      await this.tryWindowCall(
        () => win.setSpecificSystemBarEnabled('navigationIndicator', true, true), '恢复导航条');
      await this.tryWindowCall(() => win.disableLandscapeMultiWindow(), '关闭横屏多窗口');
      await this.tryWindowCall(() => win.recover(), '退出最大化');
      if (revision !== this.fullscreenNativeRevision) {
        return;
      }
      const restoreOrientation: window.Orientation =
        this.orientationForFullscreenExit(win);
      await this.tryWindowCall(
        () => win.setPreferredOrientation(restoreOrientation), '恢复进入全屏前的方向');
      if (revision === this.fullscreenNativeRevision) {
        this.hasOrientationBeforeFullscreen = false;
      }
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '退出全屏失败: %{public}s', err.message);
    }
  }

  /**
   * 记录进入全屏前的方向。
   *
   * `getPreferredOrientation()` 可能返回 `UNSPECIFIED`、自动旋转或锁定模式，
   * 这些值不适合直接作为“退出后回到哪里”的目标，因此退化到当前窗口实测
   * 横竖状态。明确的方向配置则原样保留，包括反向横竖屏。
   */
  private captureOrientationBeforeFullscreen(win: window.Window): void {
    if (this.hasOrientationBeforeFullscreen) {
      return;
    }
    let preferred: window.Orientation = window.Orientation.UNSPECIFIED;
    try {
      preferred = win.getPreferredOrientation();
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '读取进入全屏前方向失败: %{public}s', err.message);
    }
    this.orientationBeforeFullscreen =
      this.restorableOrientation(preferred, this.windowIsLandscape());
    this.hasOrientationBeforeFullscreen = true;
    hilog.info(DOMAIN, TAG, '进入全屏前方向 → %{public}d', this.orientationBeforeFullscreen);
  }

  /** 退出时优先用进入前记录；理论上缺失时用当前窗口形状兜底。 */
  private orientationForFullscreenExit(win: window.Window): window.Orientation {
    if (!this.hasOrientationBeforeFullscreen) {
      this.captureOrientationBeforeFullscreen(win);
    }
    return this.orientationBeforeFullscreen;
  }

  /**
   * 把窗口方向配置转换为可恢复的明确方向。
   *
   * 自动旋转、未指定、锁定等模式本身不包含“上一帧是竖还是横”的信息，
   * 用实测横竖状态映射为 `USER_ROTATION_*`；该模式会先回到指定方向，
   * 之后仍允许系统继续自动旋转。
   */
  private restorableOrientation(preferred: window.Orientation,
    wasLandscape: boolean): window.Orientation {
    if (preferred === window.Orientation.PORTRAIT ||
      preferred === window.Orientation.PORTRAIT_INVERTED ||
      preferred === window.Orientation.USER_ROTATION_PORTRAIT ||
      preferred === window.Orientation.USER_ROTATION_PORTRAIT_INVERTED ||
      preferred === window.Orientation.LANDSCAPE ||
      preferred === window.Orientation.LANDSCAPE_INVERTED ||
      preferred === window.Orientation.USER_ROTATION_LANDSCAPE ||
      preferred === window.Orientation.USER_ROTATION_LANDSCAPE_INVERTED) {
      return preferred;
    }
    return wasLandscape ? window.Orientation.USER_ROTATION_LANDSCAPE
      : window.Orientation.USER_ROTATION_PORTRAIT;
  }

  /** 单条窗口调用：失败只记日志，不打断同一批里的其它调用。 */
  private async tryWindowCall(call: () => Promise<void>, label: string): Promise<void> {
    try {
      await call();
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '窗口调用「%{public}s」失败: %{public}s',
        label, err.message);
    }
  }

  /**
   * 播放中保持屏幕常亮。
   *
   * 对应 Flutter 版的 `wakelock_plus`：原生鸿蒙移植时漏掉了这一层，
   * 于是系统「休眠时间」到点就照常熄屏。鸿蒙上对应能力是
   * `Window.setWindowKeepScreenOn`，它是**窗口级**开关：播放时置 true，
   * 暂停 / 切集 / 离开播放页时置 false，交还系统休眠策略。
   */
  private updateKeepScreenOn(active: boolean): void {
    if (this.keepScreenOnRequested === active) {
      return;
    }
    this.keepScreenOnRequested = active;
    this.applyKeepScreenOn(active);
  }

  private async applyKeepScreenOn(active: boolean): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      await win.setWindowKeepScreenOn(active);
      hilog.info(DOMAIN, TAG, '屏幕常亮 → %{public}s', active ? '开' : '关');
    } catch (error) {
      // 置空以便下一拍轮询重试；单次失败不影响播放
      this.keepScreenOnRequested = null;
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '设置屏幕常亮失败: %{public}s', err.message);
    }
  }

  // ============================================================
  // 播放状态轮询
  // ============================================================

  private startPolling(): void {
    if (this.pollTimer >= 0) {
      return;
    }
    this.pollTimer = setInterval(() => {
      const engine: PlayerEngine | null = this.engine;
      if (engine === null || !engine.isAvailable) {
        return;
      }
      if (!this.sliderDragging) {
        const position: number = engine.position();
        if (position >= 0) {
          this.positionMs = position * 1000;
        }
      }
      const duration: number = engine.duration();
      if (duration > 0) {
        this.durationMs = duration * 1000;
      }
      // 目录里当前集那条进度线（用户 2026-09-22 要求实时）
      this.tickEpisodeProgress();
      this.playing = !engine.paused();
      this.updateKeepScreenOn(this.playing);
      this.maybeReportHistory();
      // 真实观看时长：只累加「位置正常向前推进」的那部分（见方法注释）
      this.accumulateWatchTime();
      this.emitDanmakus();
      if (!engine.ended()) {
        // 新的一集真正起播（或用户拖回中间）后，才允许再次处理「播完」
        this.endedHandled = false;
      } else if (!this.endedHandled) {
        this.endedHandled = true;
        this.onPlaybackEnded();
      }
    }, 500);
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    // 停轮询时把没落盘的那几秒写下去（切集、退出播放页都走这里）
    WatchTimeStore.flush();
  }

  /**
   * 累加**真实观看秒数**。
   *
   * 轮询每 500ms 采一次播放位置，这里只看「这一拍位置往前走了多少」：
   *   - `0 < delta ≤ 2s × 倍速` → 算看了这么久（正常播放、以及 ≤4 倍速都落在里面）；
   *   - `delta ≤ 0`（暂停、回拖）或 `delta` 过大（拖进度）→ 只更新基准，不计时长。
   *
   * 这样得到的才是「观看时长」，而不是历史里那个「看到哪儿」的 `progressMs`
   * （那个重看会被覆盖、往前拖又会虚高）。
   */
  private accumulateWatchTime(): void {
    if (!this.playing) {
      // 暂停期间没有增量可言，清掉基准，恢复播放时重新起算
      this.lastWatchSampleMs = -1;
      return;
    }
    const positionMs: number = this.positionMs;
    const previous: number = this.lastWatchSampleMs;
    this.lastWatchSampleMs = positionMs;
    if (previous < 0) {
      return;
    }
    const deltaMs: number = positionMs - previous;
    const limitMs: number = 2000 * (this.speed > 0 ? this.speed : 1);
    if (deltaMs <= 0 || deltaMs > limitMs) {
      return;
    }
    WatchTimeStore.addSeconds(deltaMs / 1000);
  }

  private onPlaybackEnded(): void {
    const autoPlayNext: boolean = SettingsStore.getBool(SettingsKeys.autoPlayNext);
    const count: number = this.roads.length > this.currentRoad
      ? this.roads[this.currentRoad].data.length : 0;
    if (!autoPlayNext || this.currentEpisode >= count) {
      return;
    }
    this.changeEpisode(this.currentEpisode + 1, this.currentRoad);
  }

  // ============================================================
  // 播放历史（阶段五 §19 / §60）
  // ============================================================

  /** 轮询里按 3 秒节流上报；进度还没走起来时不写。 */
  private maybeReportHistory(): void {
    if (Date.now() - this.lastHistoryReportMs < HISTORY_REPORT_INTERVAL_MS) {
      return;
    }
    this.reportHistory(false);
  }

  /**
   * 写一条观看历史。
   *
   * `force = true`（离开播放页）时会先向 mpv 取一次最新的位置与时长——
   * 轮询最快也滞后 500ms，不刷新会把「最后停在哪儿」记错。
   */
  private reportHistory(force: boolean): void {
    const adapterName: string = this.playbackAdapterName();
    if (adapterName.length === 0 || this.item.id === 0) {
      return;
    }
    if (force) {
      const engine: PlayerEngine | null = this.engine;
      if (engine !== null && engine.isAvailable) {
        const position: number = engine.position();
        if (position >= 0) {
          this.positionMs = position * 1000;
        }
        const duration: number = engine.duration();
        if (duration > 0) {
          this.durationMs = duration * 1000;
        }
      }
    }
    // 还没真正开播（解析中 / 桩实现）时不写：否则会出现「点进去就留一条 0 秒记录」
    if (!force && (this.durationMs <= 0 || this.positionMs <= 0)) {
      return;
    }
    if (force && this.positionMs <= 0) {
      return;
    }
    // 离线播放记成 offline 来源：历史页的「缓存」筛选与离线续播都靠这个标记
    const identity = this.offline
      ? PlaybackHistoryIdentity.offline(this.item, adapterName,
        this.currentEpisode, this.currentEpisodeTitle(), this.currentRoad,
        this.currentEpisodePageUrl)
      : PlaybackHistoryIdentity.online(this.item, adapterName,
        this.currentEpisode, this.currentEpisodeTitle(), this.currentRoad,
        this.infoSrc, this.currentEpisodePageUrl);
    HistoryRepository.updateHistory(identity, this.positionMs, this.durationMs);
    this.lastHistoryReportMs = Date.now();
  }

  /** 普通网页规则使用插件名。 */
  private playbackAdapterName(): string {
    return this.plugin === null ? '' : this.plugin.name;
  }

  /** 当前集的显示名（剧集列表里那一列，可能就是「第03集」这类文本）。 */
  private currentEpisodeTitle(): string {
    const index: number = this.currentEpisode - 1;
    if (index >= 0 && index < this.episodeNames.length) {
      return this.episodeNames[index];
    }
    return '';
  }

  // ============================================================
  // 弹幕（§43.1 / §61）
  // ============================================================

  /**
   * 取本集弹幕。
   *
   * 时序上刻意**不等取流成功**：弹幕与视频源是两条独立链路，
   * 并行取能让起播时弹幕已经就位（否则前几秒的弹幕会整批迟到）。
   */
  private async loadDanmaku(episode: number): Promise<void> {
    this.danmakuEntries = [];
    this.activeDanmakus = [];
    this.danmakuSchedule.reset();
    /**
     * 只在进页面时按设置初始化一次弹幕开关。
     *
     * 用户 2026-09-18：「弹幕有时候加载不出来」。原因之一就是这里每次切集
     * 都重新读「默认开启弹幕」，把人手动打开的弹幕悄悄关掉——
     * 用户看到的却是「这一集没弹幕」。切集保留当前选择才是符合预期的行为。
     *
     * 这个键现在记的是**上次离开时的开关状态**（`toggleDanmaku()` 每次都会写回），
     * 所以「开过一次就一直默认开、关过一次就一直默认关」是自动成立的。
     */
    if (!this.danmakuToggleReady) {
      this.danmakuOn =
        SettingsStore.getBool(SettingsKeys.danmakuEnabledByDefault);
      this.danmakuToggleReady = true;
    }
    if (this.plugin === null || this.item.id === 0) {
      this.danmakuHint = '';
      return;
    }
    const pluginName: string = this.plugin.name;
    const bgmId: number = this.item.id;
    this.danmakuHint = '弹幕加载中…';
    try {
      /**
       * 把「番剧名 + 本线路集数」一起交给弹幕服务：弹弹play 对长番的收录是
       * 截断的（柯南只到 1216 集），没有这两项就没法去哔哩哔哩补后段集数
       * （用户 2026-09-19：「柯南靠后的集数，B 站应该是有弹幕的」）。
       */
      const bili: DanmakuBiliContext = new DanmakuBiliContext();
      bili.title = this.item.displayName();
      bili.originTitle = this.item.name;
      bili.episodeCount = this.episodeCount();
      bili.airDate = this.item.airDate;
      const result: DanmakuLoadResult =
        await DanmakuService.load(pluginName, bgmId, episode, bili);
      // 期间可能又切集了：只认当前这一集的结果
      if (episode !== this.currentEpisode) {
        return;
      }
      this.applyLoadedDanmaku(result);
      hilog.info(DOMAIN, TAG, '弹幕就绪：%{public}d 条（%{public}s）',
        result.entries.length, this.danmakuHint);
    } catch (error) {
      const err = error as Error;
      this.danmakuHint = `弹幕获取失败：${err.message}`;
      this.toastMessage(this.danmakuHint);
    }
  }

  /** 把一次弹幕结果落到时间轴、提示文案与常驻状态行。 */
  private applyLoadedDanmaku(result: DanmakuLoadResult): void {
    this.danmakuEntries = result.entries;
    this.danmakuSchedule.setLaneCount(this.danmakuLaneCount());
    if (result.entries.length === 0) {
      this.danmakuHint = result.error.length > 0
        ? `弹幕不可用：${result.error}` : '本集暂无弹幕';
      if (!this.danmakuEmptyToastShown) {
        this.danmakuEmptyToastShown = true;
        this.toastMessage(this.danmakuHint);
      }
      return;
    }
    this.danmakuHint = `弹幕 ${result.entries.length} 条${result.fromCache ? '（缓存）' : ''}`;
  }

  /** 滚动轨道数：可用高度（区域比例）× 行高 → 条数（§43.1 的「弹幕区域」）。 */
  private danmakuLaneCount(): number {
    const area: number = SettingsStore.getNumber(SettingsKeys.danmakuArea);
    const lineHeight: number = SettingsStore.getNumber(SettingsKeys.danmakuLineHeight);
    const fontSize: number = SettingsStore.getNumber(SettingsKeys.danmakuFontSize);
    const effectiveLine: number = fontSize * (1 + (lineHeight > 0 ? lineHeight : 0));
    const usableHeight: number = this.captureHeight() * (area > 0 ? area : 1);
    const count: number = Math.floor(usableHeight / (effectiveLine > 0 ? effectiveLine : 24));
    return count < 1 ? 1 : count;
  }

  /** 单条弹幕的飞行 / 停留时长（毫秒）：`danmakuDuration` 秒，跟随倍速时按倍速折算。 */
  private danmakuDurationMs(): number {
    const seconds: number = SettingsStore.getNumber(SettingsKeys.danmakuDuration);
    const base: number = (seconds > 0 ? seconds : 8) * 1000;
    if (!SettingsStore.getBool(SettingsKeys.danmakuFollowSpeed)) {
      return base;
    }
    const speed: number = this.speed > 0 ? this.speed : 1;
    return Math.round(base / speed);
  }

  /** 轮询里发弹幕：取到期的、清过期的。 */
  private emitDanmakus(): void {
    if (this.danmakuEntries.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (this.danmakuOn && this.playing) {
      const durationMs: number = this.danmakuDurationMs();
      const offsetMs: number =
        SettingsStore.getNumber(SettingsKeys.danmakuTimeOffset) * 1000;
      const due: ActiveDanmaku[] = this.danmakuSchedule.take(
        this.danmakuEntries, this.positionMs, now, offsetMs, durationMs,
        SettingsStore.getBool(SettingsKeys.danmakuMassive));
      // 刚开弹幕 / 关了再开 / 向前拖过进度：游标会落后于播放位置，
      // 这一段**不补发**（参照实现同语义），只记一条日志便于排查
      if (this.danmakuSchedule.lastSkippedStale > 0) {
        hilog.info(DOMAIN, TAG, '弹幕跳过过期 %{public}d 条（不补发）',
          this.danmakuSchedule.lastSkippedStale);
      }
      if (due.length > 0) {
        for (let i = 0; i < due.length; i++) {
          due[i].fontSize =
            SettingsStore.getNumber(SettingsKeys.danmakuFontSize);
          due[i].fontWeight =
            SettingsStore.getNumber(SettingsKeys.danmakuFontWeight) * 100;
          due[i].borderWidth = SettingsStore.getBool(SettingsKeys.danmakuBorder)
            ? SettingsStore.getNumber(SettingsKeys.danmakuBorderSize) * 2 : 0;
          due[i].opacity = SettingsStore.getNumber(SettingsKeys.danmakuOpacity);
          if (!SettingsStore.getBool(SettingsKeys.danmakuColor)) {
            due[i].color = '#FFFFFF';
          }
          // 协议：4 底部 / 5 顶部 / 其余滚动；对应设置关掉就不发
          if (due[i].type === 5
            && !SettingsStore.getBool(SettingsKeys.danmakuTop)) {
            continue;
          }
          if (due[i].type === 4
            && !SettingsStore.getBool(SettingsKeys.danmakuBottom)) {
            continue;
          }
          if (due[i].type === 1
            && !SettingsStore.getBool(SettingsKeys.danmakuScroll)) {
            continue;
          }
          due[i].startedAtMs = now;
          this.activeDanmakus.push(due[i]);
        }
        /**
         * 轨道全忙被丢掉的那些：写日志（最多 5 秒一条，免得刷爆日志）。
         *
         * 这是「弹幕过多 + 显示区域小」时**有意为之**的行为——宁可少显示几条，
         * 也不让两条弹幕叠在同一行同一位置糊成一团。想全都看，打开
         * 弹幕设置里的「海量弹幕」（那一档允许叠加）。
         */
        if (this.danmakuSchedule.lastDroppedForLanes > 0
          && now - this.danmakuDropLogAt > 5000) {
          this.danmakuDropLogAt = now;
          hilog.info(DOMAIN, TAG,
            '弹幕轨道已满，本拍省略 %{public}d 条（显示区域 %{public}d%%，可用轨道 %{public}d）',
            this.danmakuSchedule.lastDroppedForLanes,
            Math.round(SettingsStore.getNumber(SettingsKeys.danmakuArea) * 100),
            this.danmakuLaneCount());
        }
      }
    }
    // 清掉已经飞完的（停留时长 + 200ms 余量）
    const alive: ActiveDanmaku[] = [];
    for (let i = 0; i < this.activeDanmakus.length; i++) {
      const item: ActiveDanmaku = this.activeDanmakus[i];
      if (now - item.startedAtMs < item.durationMs + 200) {
        alive.push(item);
      }
    }
    if (alive.length !== this.activeDanmakus.length) {
      this.activeDanmakus = alive;
    }
  }

  /**
   * 弹幕开关（顶栏按钮）。
   *
   * **开关状态会记下来**，下次进播放页沿用它：开过一次就一直默认开，
   * 关掉过一次就一直默认关。存的就是 `danmakuEnabledByDefault` 这个键
   * （`loadDanmaku()` 首次读它），所以这里写它 = 改「默认值」，
   * 不需要再多一个键，也不会出现「设置里写着默认开、进来却是关」的两套状态。
   */
  private toggleDanmaku(): void {
    this.danmakuOn = !this.danmakuOn;
    if (!this.danmakuOn) {
      this.activeDanmakus = [];
    }
    SettingsStore.put(SettingsKeys.danmakuEnabledByDefault, this.danmakuOn);
    this.getUIContext().getPromptAction().showToast({
      message: this.danmakuOn ? '弹幕已开启' : '弹幕已关闭'
    });
    hilog.info(DOMAIN, TAG, '弹幕开关 → %{public}s（已记住）',
      `${this.danmakuOn}`);
  }

  /**
   * 发送弹幕（源码 `danmakuTextField` 的 `_submitDanmakuText`）。
   *
   * ⚠️ 参照实现在「弹幕源」这条路上**不向服务器发送**，源码注释写得很清楚：
   *   `// This provider has no send API; display a local echo.`
   * 只往画布上补一条 `selfSend: true` 的弹幕（画布会给它描一圈边）。
   * 因此这里也不接任何发送接口，只做**本地回声**。
   *
   * 另一条「聊天室」分支属于「一起看」（SyncPlay），已确定不做，
   * 顺带省略了源码里的「目标选择」弹层（弹幕 / 聊天室）。
   */
  private submitDanmaku(): void {
    const message: string = this.danmakuInputText.trim();
    if (message.length === 0) {
      this.toastMessage('弹幕内容为空');
      return;
    }
    if (this.danmakuEntries.length === 0) {
      this.toastMessage('当前剧集不支持弹幕发送的说');
      return;
    }
    if (message.length > 100) {
      this.toastMessage('弹幕内容过长');
      return;
    }
    const now: number = Date.now();
    const echo: ActiveDanmaku =
      this.danmakuSchedule.selfEcho(message, now, this.danmakuDurationMs());
    echo.startedAtMs = now;
    echo.fontSize = SettingsStore.getNumber(SettingsKeys.danmakuFontSize);
    echo.fontWeight =
      SettingsStore.getNumber(SettingsKeys.danmakuFontWeight) * 100;
    // 自己发的加一圈描边（对应 canvas_danmaku 的 `selfSend` 高亮）
    echo.borderWidth = 2;
    echo.opacity = SettingsStore.getNumber(SettingsKeys.danmakuOpacity);
    this.activeDanmakus.push(echo);
    this.danmakuInputText = '';
    this.clearHideTimer();
    hilog.info(DOMAIN, TAG, '本地回声弹幕：%{public}s', message);
  }

  private toastMessage(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /**
   * 播放页状态栏（用户 2026-10-07 的两条要求）。
   *
   * 底色分两种，图标色只有一种（播放页恒为**白标**）：
   *   1. **竖屏**：黑底白标（`black` 分支）。底色显式铺满，不靠根容器透出——
   *      应用级 ColorMode 同步之后，系统**可能**用自己的底色接管状态栏
   *      （`setWindowLayoutFullScreen(true)` 下那一条本来是透出页面内容的），
   *      显式给值才稳定；`statusBarStrip()` 那条黑色底是同一件事的兜底
   *      （系统若忽略底色，露出来的仍是黑的那条）。
   *   2. **全屏**：系统栏是隐藏的，只有用户从顶部下拉、系统临时唤出时才看得到。
   *      这里回到 **9 月最后一版**的行为——**不铺底色**（透明，直接压在画面上），
   *      图标仍是白色的。之前 2026-10-07 早先那版在这里也铺了黑色，于是下拉时
   *      画面顶部会多出一条黑带，用户要求改回原版。
   *
   * 图标色为什么整页恒白：9 月那版就是 `isPlayer || AppColor.isDark`——播放页
   * 画面多为深色（全屏更是整屏视频），白标是唯一稳定看得清的选择；离开播放页
   * 按主题还原，否则别的页面状态栏图标会一直是白的。
   */
  private async applyStatusBar(isPlayer: boolean): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      const dark: boolean = AppColor.isDark;
      const light: boolean = isPlayer || dark;
      /**
       * ⚠️ **状态栏底色一律透明**（2026-10-09 更正）。
       *
       * 用户的原话：「我不是要这个状态栏单独变黑，而是状态栏融入这个页面一样」——
       * 之前竖屏给的是不透明黑（`#000000`），系统就在最外层单独铺了一条黑带：
       * 它和页面各画各的，压栈转场时页面还在滑、那条黑带已经先出现了，所以
       * 看着"提前变黑、不融入"。改成透明之后，那一条由**页面自己**画
       * （`statusBarStrip()` 的黑色底 + 页面本就铺满到顶部），于是它跟着页面
       * 一起滑进来、一起走 —— 就是参照实现（Flutter 里状态栏区域是路由自己的
       * 内容、系统栏只负责图标色）的那种融合观感；「竖屏黑底白标」这个要求
       * 仍然成立，只是那层黑底改由页面提供。
       *
       * 图标色不变：播放页恒为白标（见上面的注释）。
       */
      const black: boolean = false;
      await win.setWindowSystemBarProperties({
        statusBarColor: black ? '#000000' : '#00000000',
        statusBarContentColor: light ? '#FFFFFF' : '#000000',
        isStatusBarLightIcon: light
      });
      hilog.info(DOMAIN, TAG, '状态栏 → %{public}s / 图标 %{public}s',
        black ? '黑底' : '透明底',
        light ? '白' : '黑');
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '设置状态栏颜色失败: %{public}s', err.message);
    }
  }

  /**
   * 弹幕设置里的滑杆行（§61.1）。
   *
   * ⚠️ 已经换成独立组件 `DanmakuSliderRow`，**不要再写回带值参数的 @Builder**：
   * ArkUI 的 @Builder 带值参数时不会随状态刷新，拖动时滑块与右侧数值都会停在
   * 旧值上（用户 2026-09-18：「弹幕设置卡片中不能即时拖动修改条」）。
   */
  private pushDanmakuSetting(key: SettingKeyDef, value: number): void {
    SettingsStore.put(key, value);
    this.danmakuSettingsRev += 1;
    /**
     * **轨道数要跟着一起重算。**
     *
     * 「显示区域」「字体大小」「行间距」这三项都只影响**轨道数**
     * （`danmakuLaneCount()`：可用高度 ÷ 行高），而轨道数此前只在
     * `loadDanmaku()` 里设过一次——于是调完滑块当场没有任何变化，
     * 要等切集/重进播放页才生效（用户 2026-09-19：「弹幕设置好像调节不了，
     * 显示区域调了没有变化」）。
     *
     * 这里无条件重算：`setLaneCount` 只是改一个数字，代价可以忽略；
     * 已经在飞的弹幕保持原轨道（它们的 `lane` 在生成时就定了），
     * 之后新发的弹幕才会用新的轨道数。
     */
    this.danmakuSchedule.setLaneCount(this.danmakuLaneCount());
  }

  /** 弹幕设置弹层（§61.1：显示效果 / 速度 / 弹幕类型 + 两个入口）。 */
  @Builder
  danmakuSheet() {
    Scroll() {
      Column() {
        Text('弹幕设置')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.onSurface)
          .width('100%')
          .margin({ bottom: 8 })

        // 弹幕状态行（取弹幕中 / 本集暂无弹幕 / 弹幕源不可用 / 获取失败）。
        // 起播时还会额外弹一次 toast，这里留常驻的一行，事后也查得到原因。
        if (this.danmakuHint.length > 0) {
          Text(this.danmakuHint)
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ bottom: 10 })
        }

        Text('显示效果')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.primary)
          .width('100%')
          .margin({ top: 10 })
        DanmakuSliderRow({
          label: '字体大小',
          initial: SettingsStore.getNumber(SettingsKeys.danmakuFontSize),
          min: 10,
          max: 32,
          step: 1,
          onChanged: (value: number) => {
            this.pushDanmakuSetting(SettingsKeys.danmakuFontSize, value);
          }
        })
        DanmakuSliderRow({
          label: '不透明度',
          initial: SettingsStore.getNumber(SettingsKeys.danmakuOpacity),
          min: 0.1,
          max: 1,
          step: 0.05,
          displayScale: 100,
          suffix: '%',
          onChanged: (value: number) => {
            this.pushDanmakuSetting(SettingsKeys.danmakuOpacity, value);
          }
        })
        DanmakuSliderRow({
          label: '显示区域',
          initial: SettingsStore.getNumber(SettingsKeys.danmakuArea),
          min: 0,
          max: 1,
          step: 0.125,
          displayScale: 100,
          suffix: '%',
          onChanged: (value: number) => {
            this.pushDanmakuSetting(SettingsKeys.danmakuArea, value);
          }
        })
        DanmakuSliderRow({
          label: '行间距',
          initial: SettingsStore.getNumber(SettingsKeys.danmakuLineHeight),
          min: 0,
          max: 3,
          step: 0.1,
          decimals: 1,
          onChanged: (value: number) => {
            this.pushDanmakuSetting(SettingsKeys.danmakuLineHeight, value);
          }
        })

        Text('速度')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.primary)
          .width('100%')
          .margin({ top: 12 })
        DanmakuSliderRow({
          label: '停留时间',
          initial: SettingsStore.getNumber(SettingsKeys.danmakuDuration),
          min: 2,
          max: 16,
          step: 1,
          suffix: ' 秒',
          onChanged: (value: number) => {
            this.pushDanmakuSetting(SettingsKeys.danmakuDuration, value);
          }
        })
        Row() {
          Column() {
            Text('跟随视频倍速')
              .fontSize(15)
              .fontColor(AppColor.onSurface)
              .width('100%')
            Text('开启后弹幕速度会随视频倍速而改变')
              .fontSize(12)
              .fontColor(AppColor.onSurfaceVariant)
              .width('100%')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({
            type: ToggleType.Switch,
            isOn: SettingsStore.getBool(SettingsKeys.danmakuFollowSpeed)
          })
            .selectedColor(AppColor.primary)
            .onChange((on: boolean) => {
              SettingsStore.put(SettingsKeys.danmakuFollowSpeed, on);
            })
        }
        .width('100%')
        .margin({ top: 8 })

        Text('弹幕类型')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.primary)
          .width('100%')
          .margin({ top: 12 })
        this.danmakuToggleRow('顶部弹幕', SettingsKeys.danmakuTop);
        this.danmakuToggleRow('底部弹幕', SettingsKeys.danmakuBottom);
        this.danmakuToggleRow('滚动弹幕', SettingsKeys.danmakuScroll);
        this.danmakuToggleRow('海量弹幕', SettingsKeys.danmakuMassive);

        Row() {
          Text('屏蔽规则')
            .fontSize(15)
            .fontColor(AppColor.onSurface)
            .layoutWeight(1)
          Text(`${DanmakuShieldStore.count()} 条`)
            .fontSize(13)
            .fontColor(AppColor.onSurfaceVariant)
          SymbolGlyph($r('sys.symbol.arrow_right'))
            .fontSize(16)
            .fontColor([AppColor.onSurfaceVariant])
            .margin({ left: 6 })
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.showDanmakuSheet = false;
          RouteTable.push(RouteTable.danmakuShield);
        })

        // 时间校准（§61.2）：源码 `danmaku_settings_sheet.dart` 的弹层里
        // 除了「弹幕屏蔽」还有这个入口（`_DanmakuSettingsDestination.timeOffset`）。
        Row() {
          Text('时间校准')
            .fontSize(15)
            .fontColor(AppColor.onSurface)
            .layoutWeight(1)
          Text(VideoPage.formatDanmakuOffset(
            SettingsStore.getNumber(SettingsKeys.danmakuTimeOffset)))
            .fontSize(13)
            .fontColor(AppColor.onSurfaceVariant)
          SymbolGlyph($r('sys.symbol.arrow_right'))
            .fontSize(16)
            .fontColor([AppColor.onSurfaceVariant])
            .margin({ left: 6 })
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.showDanmakuSheet = false;
          // 打开校准卡片时同步一次：别处改过也能显示当前值
          this.danmakuOffsetValue =
            SettingsStore.getNumber(SettingsKeys.danmakuTimeOffset);
          this.showDanmakuOffset = true;
        })

        Blank().height(24)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16 })
    }
    .width('100%')
    .height('100%')
  }

  /** 弹幕开关行（弹层里用）。 */
  @Builder
  danmakuToggleRow(label: string, key: SettingKeyDef) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor(AppColor.onSurface)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: SettingsStore.getBool(key) })
        .selectedColor(AppColor.primary)
        .onChange((on: boolean) => {
          SettingsStore.put(key, on);
        })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  /**
   * 弹幕时间校准（§61.2）。
   *
   * 数值显示成「提前 mm:ss」/「延后 mm:ss」：正数表示**弹幕提前**出现
   * （渲染时 `到期时间 = 播放位置 + 偏移`）。滑杆两端是「提前 3 分钟 / 延后 3 分钟」，
   * 底部一个「恢复同步」把偏移清零。
   */
  @Builder
  danmakuOffsetSheet() {
    Column() {
      Text('弹幕时间校准')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.onSurface)
        .width('100%')
      // 读 @State 而不是直接读设置：滑杆改的是设置，而这个 Text 读的是状态，
      // 状态一变本组件就重绘 → 数值跟着手指走（用户 2026-09-18：
      // 「弹幕设置卡片中不能即时拖动修改条」）
      Text(VideoPage.formatDanmakuOffset(this.danmakuOffsetValue))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.primary)
        .width('100%')
        .margin({ top: 12 })

      // 弹幕时间校准：参照实现 `danmaku_time_offset_sheet.dart:128` 用的也是
      // 自绘的 `HarmonySlider`（−180…180，步长 1）
      HarmonySlider({
        value: this.danmakuOffsetValue,
        min: -180,
        max: 180,
        divisions: 360,
        onChanged: (value: number) => {
          this.danmakuOffsetValue = Math.round(value);
          SettingsStore.put(SettingsKeys.danmakuTimeOffset,
            this.danmakuOffsetValue);
          this.danmakuSettingsRev += 1;
        }
      })
        .width('100%')
        .margin({ top: 8 })
      Row() {
        Text('提前 3 分钟')
          .fontSize(11)
          .fontColor(AppColor.onSurfaceVariant)
        Blank().layoutWeight(1)
        Text('延后 3 分钟')
          .fontSize(11)
          .fontColor(AppColor.onSurfaceVariant)
      }
      .width('100%')

      Row() {
        Text('恢复同步')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.onPrimary)
      }
      .width('100%')
      .height(48)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(AppColor.primary)
      .borderRadius(24)
      .margin({ top: 20 })
      .onClick(() => {
        SettingsStore.put(SettingsKeys.danmakuTimeOffset, 0);
        this.danmakuOffsetValue = 0;
        this.danmakuSettingsRev += 1;
        this.toast('弹幕已恢复同步');
      })

      Blank().height(24)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16 })
    .height('100%')
  }

  /** 偏移文案：`提前 mm:ss` / `延后 mm:ss` / `已同步`。 */
  private static formatDanmakuOffset(seconds: number): string {
    const value: number = Math.round(seconds);
    if (value === 0) {
      return '已同步';
    }
    const absolute: number = Math.abs(value);
    const minutes: number = Math.floor(absolute / 60);
    const rest: number = absolute % 60;
    const mm: string = minutes < 10 ? `0${minutes}` : `${minutes}`;
    const ss: string = rest < 10 ? `0${rest}` : `${rest}`;
    return value > 0 ? `提前 ${mm}:${ss}` : `延后 ${mm}:${ss}`;
  }

  // ============================================================
  // 投屏（§15：DLNA）
  // ============================================================

  /** 搜索局域网里的 DLNA 设备（每次打开弹层都重搜一次）。 */
  private async searchDlnaDevices(): Promise<void> {
    if (this.dlnaSearching) {
      return;
    }
    this.dlnaSearching = true;
    this.dlnaDevices = [];
    this.dlnaMessage = '正在搜索同一网络下的投屏设备…';
    const devices: DlnaDevice[] = await DlnaCaster.discover(4000);
    this.dlnaDevices = devices;
    this.dlnaSearching = false;
    this.dlnaMessage = devices.length === 0
      ? '没有找到可投屏设备（确认手机与电视/盒子在同一局域网）' : '';
  }

  /**
   * 手机热点常常不转发 SSDP 组播。这里按设备描述 URL 直连，
   * 只绕过“发现”阶段，后续的 AVTransport 控制仍走标准 DLNA。
   */
  private async connectDlnaDirect(): Promise<void> {
    if (this.dlnaDirectConnecting) {
      return;
    }
    const address: string = this.dlnaDirectAddress.trim();
    if (address.length === 0) {
      this.toast('请输入设备描述地址');
      return;
    }
    this.dlnaDirectConnecting = true;
    this.dlnaMessage = '正在直连 DLNA 设备…';
    const device: DlnaDevice | null =
      await DlnaCaster.fromDescriptionUrl(address);
    this.dlnaDirectConnecting = false;
    if (device === null) {
      this.dlnaMessage = '该地址不是可控制的 DLNA MediaRenderer';
      this.toast(this.dlnaMessage);
      return;
    }
    const next: DlnaDevice[] = [];
    for (let i = 0; i < this.dlnaDevices.length; i++) {
      if (this.dlnaDevices[i].key() !== device.key()) {
        next.push(this.dlnaDevices[i]);
      }
    }
    next.push(device);
    this.dlnaDevices = next;
    this.dlnaMessage = `已添加「${device.name}」`;
    hilog.info(DOMAIN, TAG, 'DLNA 直连成功：%{public}s', device.location);
  }

  /**
   * 投到指定设备。
   *
   * 与源码一致：**先暂停本机播放**再投屏（避免两边同时出声）；
   * 投屏成功后本机保持暂停，需要继续看本地时手动点播放。
   */
  private async castTo(device: DlnaDevice): Promise<void> {
    if (this.currentVideoUrl.length === 0) {
      this.toast('还没取到播放地址');
      return;
    }
    const token: number = ++this.dlnaCastToken;
    let castUrl: string = this.currentVideoUrl;
    if (!castUrl.startsWith('http://') && !castUrl.startsWith('https://')) {
      this.dlnaMessage = '当前是本地缓存地址，DLNA 电视无法直接访问';
      this.toast(this.dlnaMessage);
      return;
    }
    const engine: PlayerEngine | null = this.engine;
    const wasPlaying: boolean = engine !== null && !engine.paused();
    if (engine !== null && wasPlaying) {
      engine.pause();
      this.playing = false;
      this.updateKeepScreenOn(false);
      hilog.info(DOMAIN, TAG, '投屏前已暂停本机播放');
    }
    this.dlnaMessage = `正在投屏到「${device.name}」…`;
    const result: DlnaCastResult = await DlnaCaster.cast(device,
      castUrl, this.titleForCast());
    if (token !== this.dlnaCastToken) {
      return;
    }
    if (!result.ok && wasPlaying && engine !== null) {
      engine.resume();
      this.playing = true;
      this.updateKeepScreenOn(true);
      result.message += '，已恢复本机播放';
    }
    this.dlnaMessage = result.message;
    this.toast(result.message);
  }

  /** 投屏元数据里的标题（剧集名优先）。 */
  private titleForCast(): string {
    const episode: string = this.currentEpisodeTitle();
    const name: string = this.item.displayName();
    return episode.length > 0 ? `${name} ${episode}` : name;
  }

  /** 投屏弹层：搜索状态 / 设备列表 / 点击投屏。 */
  @Builder
  dlnaSheet() {
    Scroll() {
      Column() {
        Text('投屏')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.onSurface)
          .width('100%')
        Text('把当前这一集投到电视或盒子上播放（DLNA）')
          .fontSize(12)
          .fontColor(AppColor.onSurfaceVariant)
          .width('100%')
          .margin({ top: 6 })

        Text('自动搜索不到时，输入电视或电脑的 IP 即可直连。Kodi 可在“设置 → 系统信息 → 网络”里查看 IPv4 地址。')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(AppColor.onSurfaceVariant)
          .width('100%')
          .margin({ top: 12, bottom: 8 })
        Row({ space: 8 }) {
          TextInput({
            text: this.dlnaDirectAddress,
            placeholder: '设备 IP，例如 192.168.43.11'
          })
            .layoutWeight(1)
            .height(44)
            .fontSize(13)
            .backgroundColor(AppColor.surfaceContainerLow)
            .borderRadius(14)
            .onChange((value: string) => {
              this.dlnaDirectAddress = value;
            })
            .onSubmit(() => {
              this.connectDlnaDirect();
            })
          Button(this.dlnaDirectConnecting ? '连接中…' : '直连')
            .height(44)
            .enabled(!this.dlnaDirectConnecting)
            .backgroundColor(AppColor.primary)
            .fontColor(AppColor.onPrimary)
            .borderRadius(14)
            .onClick(() => {
              this.connectDlnaDirect();
            })
        }
        .width('100%')

        if (this.dlnaSearching) {
          Row() {
            LoadingIndicator({ sizeVp: 20 })
            Text('正在搜索…')
              .fontSize(14)
              .fontColor(AppColor.onSurfaceVariant)
              .margin({ left: 10 })
          }
          .width('100%')
          .height(80)
          .justifyContent(FlexAlign.Center)
        } else if (this.dlnaDevices.length === 0) {
          Column() {
            Text(this.dlnaMessage.length > 0
              ? this.dlnaMessage : '没有找到可投屏设备')
              .fontSize(13)
              .fontColor(AppColor.onSurfaceVariant)
              .textAlign(TextAlign.Center)
            Text('重新搜索')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.onSecondaryContainer)
              .padding({ left: 20, right: 20, top: 10, bottom: 10 })
              .backgroundColor(AppColor.secondaryContainer)
              .borderRadius(20)
              .margin({ top: 14 })
              .onClick(() => {
                this.searchDlnaDevices();
              })
          }
          .width('100%')
          .height(200)
          .justifyContent(FlexAlign.Center)
        } else {
          ForEach(this.dlnaDevices, (device: DlnaDevice) => {
            Row() {
              // §46.4：DLNA 投屏设备行用 `cast_connected` → `airplayaudio`
              SymbolGlyph($r('sys.symbol.airplayaudio'))
                .fontSize(20)
                .fontColor([AppColor.onSecondaryContainer])
              Blank().width(12)
              Column() {
                Text(device.name)
                  .fontSize(16)
                  .fontColor(AppColor.onSurface)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(device.location)
                  .fontSize(11)
                  .fontColor(AppColor.onSurfaceVariant)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding(14)
            .borderRadius(18)
            .backgroundColor(AppColor.surfaceContainerLow)
            .margin({ top: 10 })
            .onClick(() => {
              this.castTo(device);
            })
          }, (device: DlnaDevice) => device.key())
        }

        if (this.dlnaMessage.length > 0 && this.dlnaDevices.length > 0) {
          Text(this.dlnaMessage)
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ top: 12 })
        }

        Blank().height(24)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16 })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 缓存本集（§18 / §66）。
   *
   * 用**当前已经在播的地址**入队：那一份地址是刚解析成功过的，
   * 直接拿它下载比让下载器再解析一次更稳（也更快）。
   * 离线播放状态下不再重复缓存。
   */
  private cacheCurrentEpisode(): void {
    if (this.offline) {
      this.toast('这一集已经是本地缓存');
      return;
    }
    if (this.plugin === null || this.currentVideoUrl.length === 0) {
      this.toast('还没取到播放地址，稍后再试');
      return;
    }
    if (this.item.id <= 0) {
      this.toast('缺少番剧信息，无法缓存（请从详情页进入）');
      return;
    }
    const request = new DownloadRequest();
    request.recordKey = `${this.plugin.name}_${this.item.id}`;
    request.bangumiId = this.item.id;
    request.bangumiName = this.item.displayName();
    request.bangumiCover = this.item.coverUrl();
    request.pluginName = this.plugin.name;
    request.episodeNumber = this.currentEpisode;
    request.episodeName = this.currentEpisodeTitle();
    request.road = this.currentRoad;
    request.episodePageUrl = this.currentEpisodePageUrl;
    request.m3u8Url = this.currentVideoUrl;
    request.adBlockerEnabled = SettingsStore.getBool(SettingsKeys.forceAdBlocker);
    const accepted: boolean = DownloadManager.enqueue(request);
    this.toast(accepted
      ? `已加入下载：第${this.currentEpisode}集`
      : '这一集已经在下载或已完成');
    hilog.info(DOMAIN, TAG, '缓存本集：%{public}s（%{public}s）',
      `${this.currentEpisode}`, accepted ? '已入队' : '已存在');
  }

  // ============================================================
  // 播放操作
  // ============================================================

  private togglePlay(): void {
    const engine: PlayerEngine | null = this.engine;
    if (engine === null || !engine.isAvailable) {
      return;
    }
    if (engine.paused()) {
      engine.resume();
      this.playing = true;
      this.updateKeepScreenOn(true);
      hilog.info(DOMAIN, TAG, '▶ 继续播放（position=%{public}dms）', Math.round(this.positionMs));
    } else {
      engine.pause();
      this.playing = false;
      this.updateKeepScreenOn(false);
      hilog.info(DOMAIN, TAG, '⏸ 暂停（position=%{public}dms）', Math.round(this.positionMs));
    }
    this.scheduleHide();
  }

  private applySpeed(value: number): void {
    this.speed = value;
    const engine: PlayerEngine | null = this.engine;
    if (engine !== null) {
      engine.setSpeed(value);
    }
    SettingsStore.put(SettingsKeys.defaultPlaySpeed, value);
    // 倍速 HUD 只服务于「长按临时倍速」；菜单里调整常驻倍速时不要弹。
    this.showSpeedHud = false;
    this.scheduleHide();
  }

  private applyAspect(mode: AspectRatioMode): void {
    this.aspect = mode;
    const engine: PlayerEngine | null = this.engine;
    if (engine !== null) {
      engine.applyAspectRatio(mode, this.captureWidth(), this.captureHeight());
    }
    SettingsStore.put(SettingsKeys.defaultAspectRatioType, Number(mode));
  }

  /** 跳 OP：快进 `buttonSkipTime` 秒（§39.5.1）。 */
  private skipForward(): void {
    const seconds: number = SettingsStore.getNumber(SettingsKeys.buttonSkipTime);
    hilog.info(DOMAIN, TAG, '跳 OP：快进 %{public}d 秒', seconds > 0 ? seconds : 80);
    const engine: PlayerEngine | null = this.engine;
    if (engine !== null) {
      engine.seekBy(seconds > 0 ? seconds : 80);
    }
  }

  /**
   * 顶栏「返回」（对应参照实现的 `onBackPressed`，并按用户要求调了一处）：
   *   - **全屏**：先退出全屏回到竖屏（源码 `video_page.dart:433-455` 同）；
   *   - **竖屏**：回详情页，并让详情页**重新打开「播放来源」弹层**，
   *     也就是回到「正准备进播放页、在选源」的那一步（这是本项目自己的调整，
   *     源码只是 pop 回详情页、弹层是关着的）。
   */
  private handleBack(): void {
    // 用「意图」判：正在转进全屏的那 460ms 里按返回，也该先退出全屏而不是离开页面
    if (this.fullscreen || this.fullscreenIntent) {
      this.exitFullscreen();
      return;
    }
    InfoRouteArgs.reopenSourceSheet = true;
    // 覆盖层：先滑出，滑完再由 `Index` 卸载（见 `exitHook`）
    NavHost.closeVideoOverlay();
  }

  /**
   * 登记给 `NavHost` 的退场回调（返回键 / 右滑都走它）。
   *
   * 存成字段是为了 `aboutToDisappear` 能按同一个引用注销。
   */
  private exitHook: () => void = () => {
    this.handleBack();
  };

  /**
   * 追番按钮（1:1 对齐源码 `bean/widget/collect_button.dart`）：
   * 按钮图标**随当前状态变**（0 未追 heart / 1 在看 heart_fill / 2 想看 star_fill /
   * 3 搁置 clock / 4 看过 checkmark / 5 抛弃 trash），
   * 点开是**六项菜单**（未追 / 在看 / 想看 / 搁置 / 看过 / 抛弃，当前项高亮且禁用），
   * 不是简单的开关。
   */
  private currentCollectType(): number {
    const entry: CollectEntry | null = CollectStore.find(this.item.id);
    return entry === null ? 0 : entry.collectType;
  }

  private static collectIconOf(type: number): Resource {
    // §46.4：favorite → heart_fill、favorite_border → heart、star_rounded → star_fill、
    // pending_actions → clock、delete_outline_rounded → trash；
    // 源码里「看过」用的是未映射的 `Icons.done`，取最接近的 checkmark。
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

  /** 选状态：0 = 取消追番（源码 `addCollect(item, 0)` 的语义）。 */
  private setCollectType(type: number): void {
    if (type === 0) {
      CollectStore.remove(this.item.id);
    } else {
      const existing: CollectEntry | null = CollectStore.find(this.item.id);
      const entry: CollectEntry = existing === null ? new CollectEntry() : existing;
      entry.id = this.item.id;
      entry.name = this.item.name;
      entry.nameCn = this.item.nameCn;
      entry.cover = this.item.coverUrl();
      // 与详情页 `toEntry` 保持一致：列表卡片要用的年 / 评分 / 总集数一起带上
      entry.airDate = this.item.airDate;
      entry.score = this.item.ratingScore;
      entry.epsTotal = this.item.episodeCount();
      entry.collectType = type;
      entry.updatedAt = Date.now();
      CollectStore.upsert(entry);
    }
    this.collectRev++;
    this.toast(`已设为「${VideoPage.collectLabelOf(type)}」`);
  }

  /** 追番菜单（六项，当前项禁用）。 */
  @Builder
  collectMenu() {
    Menu() {
      ForEach([0, 1, 2, 3, 4, 5], (type: number) => {
        MenuItem({
          content: VideoPage.collectLabelOf(type),
          startIcon: VideoPage.collectIconOf(type)
        })
          .enabled(type !== this.currentCollectType())
          .onClick(() => {
            this.setCollectType(type);
          })
      }, (type: number) => `collect-type-${type}`)
    }
  }

  // ============================================================
  // 锁定 / 截图 / 超分辨率 / 定时关闭 / 外部播放
  // ============================================================

  /** 打开「修改快进秒数」对话框（§39.5.1 的长按分支）。 */
  private openSkipTimeDialog(): void {
    const current: number = SettingsStore.getNumber(SettingsKeys.buttonSkipTime);
    this.skipTimeDialog = new CustomDialogController({
      builder: SkipTimeDialog({
        initial: current > 0 ? current : 80,
        onConfirm: (value: number) => {
          SettingsStore.put(SettingsKeys.buttonSkipTime, value);
          this.toast(`快进时间已改为 ${value} 秒`);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      backgroundColor: AppColor.surfaceContainerHigh,
      cornerRadius: 24
    });
    this.skipTimeDialog.open();
  }

  /**
   * 锁定面板：锁上后上下栏整层收起，**只留右侧那颗解锁按钮**
   * （§39.7，同参照实现的 `lockPanel`）。
   *
   * 用户 2026-10-07：「锁定的锁图案不要一直常驻，过一段时间也消失，
   * 再点画面才出现」。参照实现就是这个行为——锁定时左控制条（截图 + 锁）
   * 仍然挂在 `showVideoController` 那条上：面板自动收起时它跟着滑走，
   * 点画面时再滑回来（`player_item_panel.dart` 里它只判 `showVideoController`，
   * 不判 `lockPanel`；而上下栏判的是 `!lockPanel && showVideoController`）。
   *
   * 所以这里锁上之后**不能**取消自动收起定时器，反过来要重新排一次：
   * 到期后 `panelVisible` 落回 false，那颗解锁按钮一起消失；单击画面
   * （锁定时 `togglePanel` 只切这颗按钮的显隐，不切上下栏，见那里的注释）
   * 再把它请回来。
   */
  private toggleLock(): void {
    this.locked = !this.locked;
    hilog.info(DOMAIN, TAG, '锁定状态 → %{public}s', this.locked ? '已锁定' : '已解锁');
    if (this.locked) {
      this.closeMenus();
      this.toast('已锁定面板');
      // 解锁按钮同样按「控制层消失时间」自动收起（原来这里 clearHideTimer()，
      // 于是锁上之后那颗锁会一直挂在画面上）
      this.scheduleHide();
      return;
    }
    this.panelVisible = true;
    this.scheduleHide();
  }

  /**
   * 截图（§31）。
   *
   * 参照实现（`player_item.dart:733` 的 `handleScreenshot`）在移动端是
   * `SaverGallery.saveImage(...)`——**直接存进系统相册**，桌面端才提示不支持。
   *
   * 鸿蒙这边的约束（已核对 `PermissionDefinitions.json`）：
   *   - `createAsset` 需要 `ohos.permission.WRITE_IMAGEVIDEO`
   *   - `createAssetWithShortTermPermission` 需要 `SHORT_TERM_WRITE_IMAGEVIDEO`
   *   这两个权限的 `availableLevel` 都是 **system_basic**，普通应用申请不到；
   *   唯一的免权限通路是 `showAssetsCreationDialog`（系统保存弹窗，用户确认后
   *   把沙箱里的文件写进它返回的相册 uri）。
   *
   * 所以流程是：mpv 先写进沙箱 `files/screenshots/` → 拉起系统保存弹窗 →
   * 用户确认 → 把 PNG 拷进相册。**不再只留沙箱里**（用户反馈「相册里找不到」）。
   */
  private captureScreenshot(): void {
    hilog.info(DOMAIN, TAG, '点击截图');
    const engine: PlayerEngine | null = this.engine;
    if (engine === null || !engine.isAvailable) {
      this.toast('当前设备无法截图');
      return;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const dir: string = `${context.filesDir}/screenshots`;
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const stamp: number = Date.now();
      const path: string = `${dir}/kazumi_${stamp}.png`;
      // mpv 把当前帧写成 PNG
      const rc: number = engine.screenshotToFile(path);
      if (rc !== 0) {
        /**
         * mpv **当场拒了这条命令**（返回码负数）：最常见的两种是
         * `MPV_ERROR_COMMAND (-4)`（参数/时机不对）与
         * `MPV_ERROR_PROPERTY_UNAVAILABLE (-10)`（还没绑定 surface、vo 仍是
         * null）。把码报出来，用户在小窗里就能说清是哪一类，不用靠猜
         * （用户 2026-09-20：「截图按钮还是显示无效」）。
         */
        hilog.error(DOMAIN, TAG, '截图命令被 mpv 拒绝：rc=%{public}d', rc);
        this.toast(`截图失败：mpv 返回 ${rc}（${rc === -10
          ? '画面还没就绪' : '命令未被接受'}）`);
        return;
      }
      // 截图反馈动效（§38.3 / §38.14）：420ms 的压暗 + 取景框收拢
      this.screenshotToken++;
      /**
       * ⚠️ **不能马上拿去保存**：mpv 的 `screenshot-to-file` 是**异步**命令，
       * 它返回时文件往往还没落盘（解码器要先吐一帧）。原来这里紧接着调
       * `showAssetsCreationDialog` + `fileIo.openSync`，于是要么弹窗拿到一个
       * 不存在的路径、要么拷贝时 ENOENT —— 用户看到的就是「截图功能有问题」
       * （2026-09-19）。这里等文件出现、且大小连续两次一致，再走保存流程。
       */
      this.saveScreenshotWhenReady(path, stamp);
    } catch (error) {
      const err = error as Error;
      hilog.error(DOMAIN, TAG, '截图失败: %{public}s', err.message);
      this.toast(`截图失败：${err.message}`);
    }
  }

  /** 等 mpv 把截图写出来（最多 3 秒），再交给系统保存弹窗。 */
  private async saveScreenshotWhenReady(path: string,
    stamp: number): Promise<void> {
    let ready: boolean = await VideoPage.waitForStableFile(path, 1500);
    if (!ready) {
      /**
       * 等不到就**再下一次命令**：mpv 的 `screenshot-to-file` 在「刚起播 /
       * 刚切集、解码器还没吐帧」时会收下命令却写不出文件，隔一拍重发一次
       * 基本都能出（这条重试是 2026-09-20 加的）。
       */
      const engine: PlayerEngine | null = this.engine;
      if (engine !== null && engine.isAvailable) {
        hilog.warn(DOMAIN, TAG, '截图文件 1.5 秒未出现，重发一次截图命令');
        engine.screenshotToFile(path);
        ready = await VideoPage.waitForStableFile(path, 2000);
      }
    }
    if (!ready) {
      hilog.warn(DOMAIN, TAG, '截图文件 3 秒内没写出来：%{public}s', path);
      this.toast('截图写入超时：画面还没就绪，稍后再试');
      return;
    }
    hilog.info(DOMAIN, TAG, '截图已落盘：%{public}s', path);
    await this.saveScreenshotToGallery(path, stamp);
  }

  /**
   * 等文件出现且大小稳定（连续两次采样一致）——「存在」不等于「写完」。
   *
   * 120ms 一次、最多 `timeoutMs`；超时返回 false，由调用方给提示。
   */
  private static async waitForStableFile(path: string,
    timeoutMs: number): Promise<boolean> {
    const deadline: number = Date.now() + timeoutMs;
    let lastSize: number = -1;
    while (Date.now() < deadline) {
      let size: number = -1;
      try {
        size = fileIo.statSync(path).size;
      } catch (e) {
        size = -1;
      }
      if (size > 0 && size === lastSize) {
        return true;
      }
      lastSize = size;
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 120);
      });
    }
    return false;
  }

  /**
   * 把沙箱里的截图存进系统相册（免权限：走系统保存弹窗）。
   * 独立成方法是因为 `screenshotToFile` 是同步写、这里要等弹窗，属于异步尾巴。
   */
  private async saveScreenshotToGallery(path: string,
    stamp: number): Promise<void> {
    hilog.info(DOMAIN, TAG, '截图 → %{public}s', path);
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const helper: photoAccessHelper.PhotoAccessHelper =
        photoAccessHelper.getPhotoAccessHelper(context);
      const config: photoAccessHelper.PhotoCreationConfig = {
        title: `kazumi_${stamp}`,
        fileNameExtension: 'png',
        photoType: photoAccessHelper.PhotoType.IMAGE,
        // 官方示例里带 subtype；缺省在部分机型上会被媒体库判成非法配置
        subtype: photoAccessHelper.PhotoSubtype.DEFAULT
      };
      /**
       * 源 URI 试两种写法。
       *
       * 用户 2026-09-20 反馈截图弹窗报 **`Internal system error`**
       * （= 媒体库 `14000011`）：这条路要求媒体库**跨进程**读我们沙箱里的文件，
       * 权威段（authority）写不写、怎么写由实现决定，不同版本/机型并不一致：
       *   - `file:///data/storage/...`（官方示例那种，authority 为空）
       *   - `file://<bundleName>/data/storage/...`（带包名的权威段）
       * 两种都试，谁成谁算；**只有抛异常才换下一种**——用户点「取消」时
       * 不抛异常（返回空数组），那种情况必须立刻收手，不能又弹一个框。
       */
      const bundleName: string = context.abilityInfo.bundleName;
      const sources: string[] = [`file://${path}`];
      if (bundleName.length > 0) {
        sources.push(`file://${bundleName}${path}`);
      }
      let targets: string[] = [];
      let lastError: string = '';
      let failed: boolean = false;
      for (let i = 0; i < sources.length; i++) {
        try {
          targets = await helper.showAssetsCreationDialog([sources[i]], [config]);
          failed = false;
          break;
        } catch (error) {
          const err = error as Error;
          failed = true;
          lastError = err.message;
          hilog.warn(DOMAIN, TAG, '保存弹窗失败（第 %{public}d 种 URI）：%{public}s',
            i + 1, err.message);
        }
      }
      if (!failed && targets.length === 0) {
        // 用户在系统弹窗里取消：沙箱里那份留着，提示说清楚
        this.toast('已取消保存（截图仍在应用沙箱内）');
        return;
      }
      if (targets.length === 0) {
        this.toast(`保存到相册失败：${lastError}`);
        return;
      }
      const srcFd: fileIo.File =
        fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      // 目标是系统弹窗授权的媒体库 uri：用 READ_WRITE 打开（官方示例同款，
      // WRITE_ONLY 在部分机型上会 EACCES）
      const dstFd: fileIo.File =
        fileIo.openSync(targets[0], fileIo.OpenMode.READ_WRITE);
      await fileIo.copyFile(srcFd.fd, dstFd.fd);
      fileIo.closeSync(srcFd);
      fileIo.closeSync(dstFd);
      this.toast('截图已保存到相册');
      hilog.info(DOMAIN, TAG, '截图已写入相册：%{public}s', targets[0]);
    } catch (error) {
      const err = error as Error;
      hilog.error(DOMAIN, TAG, '保存到相册失败: %{public}s', err.message);
      this.toast(`保存到相册失败：${err.message}`);
    }
  }

  /** 超分辨率档位（§15.3）：关闭 / 效率档 / 质量档。 */
  private applySuperResolution(mode: number): void {
    this.superResolution = mode;
    const engine: PlayerEngine | null = this.engine;
    if (engine === null || !engine.isAvailable) {
      return;
    }
    if (mode <= 1) {
      engine.setShaders([]);
      this.toast('已关闭超分辨率');
      return;
    }
    const names: string[] = mode === 3 ? ANIME4K_QUALITY : ANIME4K_EFFICIENCY;
    const dir: string = this.deployShaders();
    if (dir.length === 0) {
      this.toast('超分辨率着色器部署失败');
      return;
    }
    const paths: string[] = [];
    for (let i = 0; i < names.length; i++) {
      paths.push(`${dir}/${names[i]}`);
    }
    engine.setShaders(paths);
    hilog.info(DOMAIN, TAG, '超分辨率档位 %{public}d（%{public}d 个着色器）',
      mode, names.length);
    this.toast(mode === 3 ? '已启用超分辨率（质量优先）' : '已启用超分辨率（效率优先）');
  }

  /** 把 Anime4K 着色器从 rawfile 释放到沙箱目录，返回目录（失败返回空串）。 */
  private deployShaders(): string {
    const context = getContext(this) as common.UIAbilityContext;
    const dir: string = `${context.filesDir}/anime_shaders`;
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const all: string[] = ANIME4K_QUALITY.concat(ANIME4K_EFFICIENCY);
      for (let i = 0; i < all.length; i++) {
        const target: string = `${dir}/${all[i]}`;
        if (fileIo.accessSync(target)) {
          continue;
        }
        const data: Uint8Array =
          context.resourceManager.getRawFileContentSync(`shaders/${all[i]}`);
        const file = fileIo.openSync(target,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
        fileIo.writeSync(file.fd, data.buffer as ArrayBuffer);
        fileIo.closeSync(file);
      }
      return dir;
    } catch (error) {
      const err = error as Error;
      hilog.error(DOMAIN, TAG, '着色器部署失败: %{public}s', err.message);
      return '';
    }
  }

  /** 定时关闭菜单项（§39.5.2）。 */
  private customTimerDialog: CustomDialogController | null = null;

  /** 自定义定时（§39.5.2 的「自定义」）。 */
  private openCustomTimerDialog(): void {
    this.customTimerDialog = new CustomDialogController({
      builder: CustomTimerDialog({
        onConfirm: (minutes: number) => {
          this.setTimedShutdown(minutes);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      backgroundColor: AppColor.surfaceContainerHigh,
      cornerRadius: 24
    });
    this.customTimerDialog.open();
  }

  private setTimedShutdown(minutes: number): void {
    if (minutes <= 0) {
      TimedShutdown.cancel();
      this.toast('已取消定时关闭');
      return;
    }
    TimedShutdown.start(minutes, () => {
      this.pauseForTimedShutdown();
    });
    this.toast(`已设置 ${TimedShutdown.formatMinutes(minutes)} 后定时关闭`);
  }

  private pauseForTimedShutdown(): void {
    const engine: PlayerEngine | null = this.engine;
    if (engine !== null && !engine.paused()) {
      engine.pause();
      this.playing = false;
    }
  }

  /** 定时关闭版本号变化：刷新标题，并在「刚到期」时弹提示。 */
  private onShutdownTick(): void {
    this.shutdownLabel = TimedShutdown.isActive()
      ? TimedShutdown.formatRemaining() : '';
    if (TimedShutdown.consumeExpired()) {
      hilog.info(DOMAIN, TAG, '定时关闭时间到，已暂停');
      this.toast('定时时间已到，视频已暂停');
    }
  }

  /**
   * 外部播放（§39.5.2）。
   * 用 `startAbility` 拉起能播 `video/mp4` 的应用，等效于参照实现里
   * Android 侧的 `openWithMime`。
   */
  private async launchExternalPlayer(): Promise<void> {
    const url: string = this.currentVideoUrl;
    if (url.length === 0) {
      this.toast('还没有可播放的地址');
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url,
      type: 'video/*'
    };
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await context.startAbility(want);
      this.toast('尝试唤起外部播放器');
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '唤起外部播放器失败: %{public}s', err.message);
      this.toast('唤起外部播放器失败');
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 提示失败不影响主流程
    }
  }

  private copyToClipboard(text: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data);
      this.toast('已复制');
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '复制失败: %{public}s', err.message);
    }
  }

  private seekTo(ms: number): void {
    const engine: PlayerEngine | null = this.engine;
    if (engine === null) {
      return;
    }
    // 拖进度不是「看了这么久」：把观看时长的采样基准清掉，下一拍重新起算
    this.lastWatchSampleMs = -1;
    hilog.info(DOMAIN, TAG, 'seek → %{public}s（来自 %{public}s）',
      VideoPage.formatTime(ms), VideoPage.formatTime(this.positionMs));
    /**
     * **向后拖要重排弹幕游标。**
     *
     * 游标只会前进：拖到 500s 时它已经吃过 0–500s 的条目，这时再把进度拖回
     * 100s，如果不重置，得等播放位置重新追过 500s 才会再出弹幕——中间几分钟
     * 一条都没有。参照实现在 seek 时做的是 `clearAndInvalidateScheduledDanmakus()`
     * （`player_seek_controller.dart:47`）。
     * 向前拖不用管：游标落后时 `take()` 会把过期段跳过（见 `DANMAKU_STALE_WINDOW_MS`）。
     */
    if (ms + 2000 < this.positionMs) {
      this.danmakuSchedule.reset();
      this.activeDanmakus = [];
    }
    engine.seekTo(ms / 1000);
    this.positionMs = ms;
  }

  // ============================================================
  // 控制层自动隐藏（§15.9 / §15.10）
  // ============================================================

  private scheduleHide(): void {
    this.clearHideTimer();
    /**
     * ⚠️ **不要**在这里判 `locked`：锁定状态下要收起的只是上下栏，那颗解锁
     * 按钮仍归 `panelVisible` 管，也得跟着定时器消失（用户 2026-10-07）。
     */
    if (this.anyMenuOpen() || this.showVideoInfo) {
      return;
    }
    const delay: number =
      SettingsStore.getNumber(SettingsKeys.playerControllerLayerDisappearTime);
    this.hideTimer = setTimeout(() => {
      this.panelVisible = false;
    }, delay > 0 ? delay : 4000);
  }

  private clearHideTimer(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  private anyMenuOpen(): boolean {
    return this.speedMenuOpen || this.aspectMenuOpen || this.roadMenuOpen
      || this.moreMenuOpen || this.srMenuOpen;
  }

  /** 关掉全部选项菜单（菜单项被点、返回键、锁定时调用）。 */
  private closeMenus(): void {
    this.speedMenuOpen = false;
    this.aspectMenuOpen = false;
    this.roadMenuOpen = false;
    this.moreMenuOpen = false;
    this.srMenuOpen = false;
  }

  /**
   * 剧集行的按压态（`episode_selection_panel.dart:984-1002`）。
   *
   * 源码用 `SpringSimulation(mass 1, stiffness 500, ratio 0.8)` 从**当前值**
   * 弹到目标值，并带上当前速度；ArkUI 的 `animateTo` 取不到「当前速度」，
   * 因此速度按 0 处理（`springPress(0)`），刚度与阻尼比逐项一致。
   */
  private setEpisodePressed(episode: number, pressed: boolean): void {
    const target: number = pressed ? episode : -1;
    if (MotionRuntime.isOff()) {
      this.pressedEpisode = target;
      return;
    }
    animateTo({ curve: AppCurves.springPress(0) }, () => {
      this.pressedEpisode = target;
    });
  }

  /** 剧集行按压进度（0 / 1；中间值由动画补）。 */
  private episodePressValue(episode: number): number {
    return this.pressedEpisode === episode ? 1 : 0;
  }

  /**
   * 右侧定位条拖动（`y` 是相对定位条的 vp）：把手指位置换算成段号并跳过去。
   *
   * 用 `Math.round(y / 高度 * (段数 - 1))` 而不是 `y / 高度 * 段数`：
   * 刻度是 `SpaceBetween` 排的，第一枚贴顶、最后一枚贴底，
   * 按后者算会在首尾各偏半格（表现为「拖到最下面跳不到最后一段」）。
   * 段号没变就什么都不做，避免拖动时反复触发滚动定位。
   */
  private jumpByScrubber(y: number): void {
    const count: number = this.segmentCount();
    if (count <= 1 || this.scrubberHeight <= 0) {
      return;
    }
    let displayIndex: number = Math.round(y / this.scrubberHeight * (count - 1));
    if (displayIndex < 0) {
      displayIndex = 0;
    }
    if (displayIndex >= count) {
      displayIndex = count - 1;
    }
    const group: number = this.segmentAtDisplayIndex(displayIndex);
    if (group === this.segmentGroup) {
      this.scrubberHint = VideoPage.segmentLabel(group, this.episodeCount());
      return;
    }
    this.segmentGroup = group;
    this.scrubberHint = VideoPage.segmentLabel(group, this.episodeCount());
    // 与点分段胶囊同一套动作：列表回到该段首行、胶囊滚进视野
    this.scrollEpisodeToLocal(0, true);
    this.revealSegment(group);
  }

  /**
   * 当前集的观看进度（0–1，0 = 不画）。
   *
   * 数据来自**历史记录**的续播偏移，切集时算一次——刻意不读 2Hz 的
   * `positionMs`：目录常驻可见，读它会让整页每 500ms 重排（工程里别处
   * 都在躲这件事）。所以这条线表达的是「上次看到哪」，不是实时进度条。
   */
  private panelProgressRatio(): number {
    if (this.durationMs <= 0 || this.resumeOffsetSec <= 0) {
      return 0;
    }
    const ratio: number = this.resumeOffsetSec * 1000 / this.durationMs;
    if (ratio <= 0) {
      return 0;
    }
    return ratio > 1 ? 1 : ratio;
  }

  /**
   * 目录里当前集那条进度线实际画多长（0–1）。
   *
   * 播放中用**实时值**（`liveProgressRatio`）；还没有实时值（刚进页面、
   * 刚切集、离线播放在起播前）就退回历史快照，也就是「上次看到哪」——
   * 这样进度线在起播前不会先消失一下。
   */
  private episodeProgressRatio(): number {
    return this.liveProgressRatio > 0
      ? this.liveProgressRatio : this.panelProgressRatio();
  }

  /**
   * 轮询里刷新 `liveProgressRatio`（1 秒节流）。
   *
   * 三条克制：**目录不在屏幕上就不算**（全屏时只有面板打开才有目录）；
   * **没有时长/位置就清零**（没起播不画）；**变化小于 0.1% 不写**
   * （暂停时 `positionMs` 不动，写了也只会白白重建那一行）。
   */
  private tickEpisodeProgress(): void {
    if (this.fullscreen && !this.showPanelInFullscreen) {
      return;
    }
    if (this.durationMs <= 0 || this.positionMs <= 0) {
      if (this.liveProgressRatio !== 0) {
        this.liveProgressRatio = 0;
      }
      return;
    }
    const now: number = Date.now();
    if (now - this.liveProgressTickAt < LIVE_PROGRESS_INTERVAL_MS) {
      return;
    }
    this.liveProgressTickAt = now;
    const raw: number = this.positionMs / this.durationMs;
    const clamped: number = raw > 1 ? 1 : raw;
    if (Math.abs(clamped - this.liveProgressRatio) < 0.001) {
      return;
    }
    this.liveProgressRatio = clamped;
  }

  /**
   * 分段胶囊滚入视野并居中：**260ms `easeOutCubic`**（§38.8）。
   *
   * 对应参照实现 `episode_selection_panel.dart:281-297` 的
   * `_segmentController.animateTo(target, 260ms, easeOutCubic)`。
   */
  private revealSegment(group: number): void {
    const x: number = this.segmentX[group];
    const width: number = this.segmentWidth[group];
    if (x === undefined || x < 0 || width <= 0 || this.segmentViewport <= 0) {
      try {
        this.segmentScroller.scrollToIndex(
          this.segmentDisplayIndex(group), true, ScrollAlign.CENTER);
      } catch (e) {
        // 尚未布局完成，忽略
      }
      return;
    }
    const target: number = x - (this.segmentViewport - width) / 2;
    this.segmentScroller.scrollTo({
      xOffset: Math.max(0, target),
      yOffset: 0,
      animation: {
        duration: MotionRuntime.ms(Motion.nav),
        curve: AppCurves.easeOutCubic()
      }
    });
  }

  /**
   * 剧集列表定位到某一行并居中。
   *
   * 对应参照实现 `episode_selection_panel.dart:299-313` 的 `_scrollToOffset`：
   * 距离在 **1.5 个视口以内**才用 280ms `easeOutCubic` 动画，
   * 更远则**直接跳**（§38.8 明确要求保留这种对照）。
   */
  private scrollEpisodeToLocal(localIndex: number, alignTop: boolean): void {
    const total: number = this.episodeRange().length;
    if (total <= 0 || localIndex < 0) {
      return;
    }
    const rowTotal: number = EPISODE_ROW_HEIGHT + EPISODE_ROW_DIVIDER;
    const rowTop: number = localIndex * rowTotal;
    const centered: boolean = !alignTop && this.episodeViewport > 0;
    const dest: number = centered
      ? rowTop - (this.episodeViewport - EPISODE_ROW_HEIGHT) / 2 : rowTop;
    const current: number = this.episodeScroller.currentOffset().yOffset;
    const distance: number = Math.abs(dest - current);
    if (!MotionRuntime.isOff() && distance <= this.episodeViewport * 1.5) {
      this.episodeScroller.scrollTo({
        xOffset: 0,
        yOffset: dest,
        animation: {
          duration: MotionRuntime.ms(Motion.segment),
          curve: AppCurves.easeOutCubic()
        }
      });
      return;
    }
    this.episodeScroller.scrollTo({ xOffset: 0, yOffset: dest });
  }

  /**
   * 单击画面：切控制层的显隐。
   *
   * 锁定时**不再直接 return**（用户 2026-10-07：「锁的图案不要一直常驻，
   * 过一段时间也消失，再点画面才出现」）：锁定状态下 `panelVisible` 只控制
   * 右侧那颗解锁按钮——上下栏在 `build()` 里另有 `!this.locked` 把关，
   * 锁着时无论 `panelVisible` 是什么都不会画出来，所以这里放开是安全的。
   * （参照实现同理：`_handleTap` → 切 `showVideoController`，上下的可见性是
   * `!lockPanel && showVideoController`，左边的解锁按钮只判 `showVideoController`。）
   */
  private togglePanel(): void {
    this.panelVisible = !this.panelVisible;
    hilog.info(DOMAIN, TAG, '控制层 → %{public}s', this.panelVisible ? '显示' : '隐藏');
    if (this.panelVisible) {
      this.scheduleHide();
    } else {
      this.clearHideTimer();
    }
  }

  // ============================================================
  // 手势（§15.4–15.7）
  // ============================================================

  private gestureBegin(x: number, y: number): void {
    this.activeGesture = PlayerGesture.none;
    this.progressBarDragging = false;
    /**
     * 用**按下点**判定顶栏区域（`touchDownY`），而不是 PanGesture 上报的当前位置：
     * 后者是「手指已经移动 5vp」之后的坐标，顶栏本身只有 48vp 高，按在标题上
     * 往下滑就已经越过了底边（见字段注释，用户 2026-10-07 反馈的就是这个）。
     */
    const downY: number = this.touchDownY >= 0 ? this.touchDownY : y;
    this.gestureInTopBar = this.fullscreen && this.panelVisible && !this.locked &&
      downY <= TOP_MASK_HEIGHT;
    this.gestureStartX = x;
    this.gestureStartY = y;
    this.lastMoveX = x;
    this.lastMoveY = y;
    this.hudSeekMs = this.positionMs;
    this.hudSeekForward = true;
    // 手势到底有没有收到、收在哪里：排查「非全屏调不动」时必须能区分
    // 「事件没进来」和「进来了但幅度被算法吃掉」（真机实测用）。
    hilog.info(DOMAIN, TAG, '手势开始 (%{public}d,%{public}d) 视频区 %{public}d×%{public}d',
      Math.round(x), Math.round(y),
      Math.round(this.captureWidth()), Math.round(this.captureHeight()));
    if (this.gestureInTopBar) {
      // 全屏控制层显示时，顶栏区域内交给顶栏/系统状态栏处理：
      // 这里不再把横扫识别成 seek，也不把纵向拖动识别成亮度/音量。
      this.clearHideTimer();
      hilog.info(DOMAIN, TAG, '手势落在全屏顶栏区域，跳过播放器手势');
      return;
    }
    // 落在进度条行上：这次拖动按「拖进度」处理。
    //
    // 为什么不用 Slider 自己的拖动：手势挂在视频区容器上（与参照实现的
    // GestureDetector 同构），父级的 PanGesture 会先一步吃掉纵向/横向拖动，
    // 真机实测滑进度条会变成「视频区横扫 = 相对 seek +116s」。
    // 因此这里按 Slider 的实测范围把 x 映射成绝对时间，效果与拖 Slider 一致。
    // 进度条那一行在底栏里的位置：时间行之下、控制行之上。
    // 行本身只有 20vp 高，手指落点给 ±6 的容差（否则很难「拖到」）。
    // 优先用 Slider 的**实测**顶边（底栏自适应高度后不能再靠估算），
    // 还没测到（首帧）时退回估算值。
    const barTop: number = this.sliderTopY >= 0
      ? this.sliderTopY : this.captureHeight() - this.bottomBarHeight();
    // 内容在底栏里是**顶部对齐**的（底部那段 padding 是系统底距），
    // 所以时间行就从 barTop 开始。
    // 时间码与进度条已经合成一行，进度条自己就占满这一行
    const sliderTop: number = barTop;
    /**
     * 只有**进度条真的在屏幕上**时，这一行才算「拖进度条」。
     *
     * 控制层隐藏时底栏并没有画出来（`if (this.panelVisible && !this.locked)`），
     * 那时手指落在同一片区域上却按「绝对定位」去 seek——用户只是想在视频区
     * 横扫快进，画面却直接跳到手指那一列对应的时间点。加上可见性判断之后，
     * 隐藏状态下统一走相对拖动（= 横扫 180 秒），与用户的直觉一致。
     */
    const barOnScreen: boolean = this.panelVisible && !this.locked;
    this.progressBarDragging = barOnScreen &&
      y >= sliderTop - 6 && y <= sliderTop + SLIDER_ROW_HEIGHT + 6;
    this.clearHideTimer();
  }

  private gestureMove(x: number, y: number): void {
    if (this.gestureInTopBar) {
      return;
    }
    if (this.progressBarDragging) {
      if (this.sliderWidth <= 0 || this.durationMs <= 0) {
        return;
      }
      // 拖进度条也算「调整手势」：抬手时不要顺带把控制层切出来
      this.swallowTapAfterGesture = true;
      let ratio: number = (x - this.sliderLeft) / this.sliderWidth;
      if (ratio < 0) {
        ratio = 0;
      }
      if (ratio > 1) {
        ratio = 1;
      }
      this.sliderDragging = true;
      this.hudSeekMs = this.durationMs * ratio;
      this.hudSeekForward = this.hudSeekMs >= this.positionMs;
      this.showSeekHud = true;
      return;
    }
    const dx: number = x - this.gestureStartX;
    const dy: number = y - this.gestureStartY;
    if (this.activeGesture === PlayerGesture.none) {
      // 方向判定的门槛与「占优倍数」：
      //   - 位移太小（<8vp）先不定向，免得手指一抖就锁死方向；
      //   - 必须有一轴**明显占优**（1.3 倍）才定向。
      // 真机踩过：纵向滑动因为首帧横向位移略大被判成「拖进度」，
      // 于是非全屏时「音量/亮度调不动」——实际是方向判错了。
      const adx: number = Math.abs(dx);
      const ady: number = Math.abs(dy);
      if (adx < 8 && ady < 8) {
        return;
      }
      if (adx < ady * GESTURE_AXIS_DOMINANCE && ady < adx * GESTURE_AXIS_DOMINANCE) {
        return; // 还不够明确，继续等下一帧
      }
      if (adx > ady) {
        this.activeGesture = PlayerGesture.seek;
      } else {
      const sectionWidth: number = this.captureWidth() / 2;
      // 常驻诊断（每次手势一条）：排查「音量/亮度调不动」时，先看这里
      // 是不是方向判错了（startX 与分界都在 vp）。
      Logger.info('AutumnPlayer',
        `手势定向: startX=${Math.round(this.gestureStartX)}vp / 分界 ${Math.round(sectionWidth)}vp`);
      this.activeGesture = this.gestureStartX < sectionWidth
          ? PlayerGesture.brightness : PlayerGesture.volume;
      if (this.activeGesture === PlayerGesture.volume) {
        // 音量手势的基准取「按下那一刻」的显示值，之后只用位移累加。
        this.volumeGestureTarget = this.volume;
        // 对账基准 + 作废上一次手势遗留的延时对账
        this.volumeGestureStartPercent = this.volume;
        this.volumeVerifyToken += 1;
      }
      }
      hilog.info(DOMAIN, TAG, '手势定向 dx=%{public}d dy=%{public}d → %{public}s',
        Math.round(dx), Math.round(dy), `${this.activeGesture}`);
      // 已经判定成拖进度 / 亮度 / 音量：这次拖动不许再触发单击切层
      this.swallowTapAfterGesture = true;
    }

    if (this.activeGesture === PlayerGesture.seek) {
      // 增量式：按每次移动的位移换算，整屏横扫 = 180 秒
      const scale: number = SEEK_SCALE_MS / Math.max(1, this.captureWidth());
      let next: number = this.hudSeekMs + (x - this.lastMoveX) * scale;
      this.lastMoveX = x;
      if (next < 0) {
        next = 0;
      }
      if (this.durationMs > 0 && next > this.durationMs) {
        next = this.durationMs;
      }
      this.hudSeekForward = next >= this.hudSeekMs;
      this.hudSeekMs = next;
      this.showSeekHud = true;
      return;
    }

    if (this.activeGesture === PlayerGesture.brightness) {
      const level: number = this.captureHeight() * BRIGHTNESS_LEVEL_FACTOR;
      let next: number = this.panelBrightness - (y - this.lastMoveY) / level;
      this.lastMoveY = y;
      if (next < 0) {
        next = 0;
      }
      if (next > 1) {
        next = 1;
      }
      this.panelBrightness = next;
      // 亮度 / 音量 HUD 互斥（§15.7）；HUD 面板按「最近一次展示的类型」渲染
      this.showBrightnessAdjustmentHud();
      this.applyWindowBrightness(next);
      return;
    }

    if (this.activeGesture === PlayerGesture.volume) {
      const level: number = this.captureHeight() * VOLUME_LEVEL_FACTOR;
      /**
       * 刻度 = `高度 × 0.03`：一次整屏纵向拖动 ≈ 33 个音量点
       * （刻度本身的口径与由来见 `VOLUME_LEVEL_FACTOR` 的注释）。
       *
       * **不要在这里乘 100**：音量刻度是 0–100，再乘一次就是把灵敏度放大 100 倍，
       * 手指一动就 0 / 100 跳变。
       *
       * 基准是 `volumeGestureTarget`（手势自己的累加值），**不是** `this.volume`：
       * 后者会被系统音量回调覆盖，导致拖不动（见字段注释）。
       */
      let next: number = this.volumeGestureTarget - (y - this.lastMoveY) / level;
      this.lastMoveY = y;
      if (next < 0) {
        next = 0;
      }
      if (next > 100) {
        next = 100;
      }
      this.volumeGestureTarget = next;
      this.volume = next;
      this.showVolumeAdjustmentHud();
      // 手机上改的是**系统媒体音量**（音量键 / 系统面板同步），
      // 拿不到系统音量能力时才回落到播放器自身音量。
      if (!this.applySystemVolume(next)) {
        const engine: PlayerEngine | null = this.engine;
        if (engine !== null) {
          engine.setVolume(next);
        }
      }
    }
  }

  /** 手势结束统一收尾（§15.7 的 `_finishAdjustmentGesture`）。 */
  private gestureEnd(): void {
    if (this.gestureInTopBar) {
      this.gestureInTopBar = false;
      this.activeGesture = PlayerGesture.none;
      this.progressBarDragging = false;
      this.scheduleHide();
      return;
    }
    /**
     * 给「吞掉抬起时的单击」这个标记上一道保险：单击判定在抬手后
     * ~300ms 内出结果，700ms 后这个标记必须失效，否则下一次**真正**的
     * 单击会被误吞（用户会觉得「点一下没反应」）。
     */
    if (this.swallowTapAfterGesture) {
      this.expireSwallowedTapLater();
    }
    if (this.progressBarDragging) {
      this.progressBarDragging = false;
      this.sliderDragging = false;
      this.seekTo(this.hudSeekMs);
      this.showSeekHud = false;
      this.scheduleHide();
      return;
    }
    const mode: PlayerGesture = this.activeGesture;
    this.activeGesture = PlayerGesture.none;
    if (mode === PlayerGesture.seek) {
      this.seekTo(this.hudSeekMs);
      this.showSeekHud = false;
    }
    if (mode === PlayerGesture.brightness) {
      hilog.info(DOMAIN, TAG, '亮度手势结束 → %{public}d%%',
        Math.round(this.panelBrightness * 100));
      this.hideAdjustmentHudLater();
    }
    if (mode === PlayerGesture.volume) {
      hilog.info(DOMAIN, TAG, '音量手势结束 → %{public}d%%',
        Math.round(this.volume));
      /**
       * **不要**在这里立刻读一次系统音量、无条件写回 HUD。
       *
       * 原来就是「收尾时读一次系统音量、无条件写回 HUD」：`setVolume` 是异步的，
       * 刚写完立刻读多半还是**旧值**（或者读到一条不相关的流），于是 HUD 弹回原位、
       * 下一次手势又从旧值起步——用户看到的就是「滑一下、弹回去、怎么都调不到
       * 100%」（2026-09-19）。现在改成延时对账 + 只在系统**真的跟上**时才采纳。
       */
      this.finishVolumeGesture();
      this.hideAdjustmentHudLater();
    }
    this.scheduleHide();
  }

  /**
   * 音量手势收尾：**先对账，再决定 HUD 归谁**（2026-09-19 修「松手回弹」）。
   *
   * 用户的描述是「滑动了音量条变化之后会反弹回去」，根因是收尾时无条件用
   * 系统读回值覆盖 HUD。判定改成三步：
   *   1. 等 160ms 让最后一次 `setVolume` 真正落地（系统服务是异步的，
   *      立刻读会读到旧值——这就是原来弹回去的主因）；
   *   2. 读回媒体流音量：和请求值在**一个档位容差**内（系统是整数档，15 档 = 6.67%/档）
   *      → 系统跟上了，**HUD 保持手势值**（不按系统档位对齐，见下面的注释）；
   *   3. 我们要求它动（≥1 个点）而它**一动没动** → 认定这台设备上系统音量写不进去
   *      （权限 / 策略 / 写的是另一条流）：置 `sysVolumeWritable = false`，改由播放器
   *      音量接管，并**保留手势值**——绝不回弹。
   *
   * 期间又开始了新的音量手势（令牌变了）就整段作废，避免旧对账改掉新值。
   */
  private finishVolumeGesture(): void {
    const requested: number = this.volumeGestureTarget;
    const start: number = this.volumeGestureStartPercent;
    const manager: audio.AudioVolumeManager | null = this.volumeManager;
    if (manager === null || this.mediaVolumeMax <= 0 || !this.sysVolumeWritable) {
      // 系统音量这条路本来就不可用：手势值直接落到播放器，HUD 保持手势值
      this.applyPlayerVolume(requested);
      return;
    }
    const token: number = this.volumeVerifyToken;
    setTimeout(() => {
      if (token !== this.volumeVerifyToken ||
        this.activeGesture === PlayerGesture.volume) {
        return;
      }
      let level: number = -1;
      try {
        level = manager.getVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
      } catch (error) {
        const err = error as Error;
        hilog.warn(DOMAIN, TAG, '读回系统音量失败: %{public}s', err.message);
      }
      if (level < 0) {
        this.applyPlayerVolume(requested);
        return;
      }
      const reported: number = VideoPage.toPercent(level, this.mediaVolumeMax);
      const wantedMove: boolean = start >= 0 && Math.abs(requested - start) >= 1;
      const moved: boolean = start >= 0 && Math.abs(reported - start) >= 1;
      // 一个档位容差（15 档时 ≈ 10 个百分点）：量化偏差不算「没跟上」
      const tolerance: number = Math.max(8, 150 / this.mediaVolumeMax);
      if (!wantedMove || moved || Math.abs(reported - requested) <= tolerance) {
        /**
         * 系统跟上了——但**不要把 HUD 对齐到 `reported`**。
         *
         * 系统音量是整数档位（本机 15 档 → 每档 6.67%），我们请求的百分比几乎
         * 不会正好落在档位上：例如请求 62%，系统落到 9 档 = 60%，一「对齐」
         * 松手时那条就往下跳 2 个点——用户 2026-09-19 反馈的「松手后回弹一点点」
         * 就是它。HUD 保留手势值即可：
         *   - 响度本来就是系统那个档位，差不到半档，看不出来；
         *   - 下一次手势从这个显示值起步，请求值再映射到最近的档位，
         *     误差**不会累积**（永远不超过半档）；
         *   - 用户按音量键时，回调会把 HUD 重新对齐到系统值（见下面的调用分支）。
         */
        return;
      }
      Logger.info('AutumnPlayer',
        `系统音量写入无效（请求 ${Math.round(requested)}% / 系统仍 ${reported}%）→ 改用播放器音量，保留手势值`);
      this.sysVolumeWritable = false;
      this.applyPlayerVolume(requested);
    }, 160);
  }

  /** 把音量落到**播放器自身**（系统音量写不动时的兜底），并让 HUD 停在给定值。 */
  private applyPlayerVolume(percent: number): void {
    const value: number = Math.min(100, Math.max(0, percent));
    this.volume = value;
    this.volumeGestureTarget = value;
    const engine: PlayerEngine | null = this.engine;
    if (engine !== null) {
      engine.setVolume(value);
    }
  }

  /** 取消待收起的定时器（对应 `_cancelAdjustmentHudHideTimer`）。 */
  private cancelAdjustmentHudHideTimer(): void {
    if (this.adjustHudHideTimer >= 0) {
      clearTimeout(this.adjustHudHideTimer);
      this.adjustHudHideTimer = -1;
    }
  }

  /**
   * 只显示「音量」那条（对应 `_showVolumeAdjustmentHud`）。
   *
   * 先取消收起定时器：一次调节过程中 `setVolume` 会回调、系统音量回调也会进来，
   * 每次都排一次收起的话，早先排的那次会在**拖动途中**把条收掉
   * （真机表现就是「亮度条能调、音量条根本看不见」）。
   */
  private showVolumeAdjustmentHud(): void {
    this.cancelAdjustmentHudHideTimer();
    this.showBrightnessHud = false;
    this.hudAdjustKind = 'volume';
    this.showVolumeHud = true;
  }

  /** 只显示「亮度」那条（对应 `_showBrightnessAdjustmentHud`）。 */
  private showBrightnessAdjustmentHud(): void {
    this.cancelAdjustmentHudHideTimer();
    this.showVolumeHud = false;
    this.hudAdjustKind = 'brightness';
    this.showBrightnessHud = true;
  }

  /**
   * 亮度 / 音量 HUD 在调节结束后 **650ms** 收起（§15.7 的
   * `_finishAdjustmentGesture()` → `_scheduleAdjustmentHudHide`）。
   *
   * 关键差异：定时器到点**无条件**收起，不再看「手势是否还在进行」。
   * 参照实现就是这么写的——`showSeekTime` 与 `showVolume` / `showBrightness`
   * 是三面独立的旗子，拖进度不会去动音量条，音量条只由这个定时器收。
   */
  private hideAdjustmentHudLater(): void {
    this.cancelAdjustmentHudHideTimer();
    this.adjustHudHideTimer = setTimeout(() => {
      this.adjustHudHideTimer = -1;
      this.showBrightnessHud = false;
      this.showVolumeHud = false;
    }, 650);
  }

  private async applyWindowBrightness(value: number): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      win.setWindowBrightness(value);
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '设置窗口亮度失败: %{public}s', err.message);
    }
  }

  /** 离开播放页时把窗口亮度交还系统（`-1` = 跟随系统设置）。 */
  private async releaseWindowBrightness(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      win.setWindowBrightness(-1);
      hilog.info(DOMAIN, TAG, '窗口亮度交还系统');
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '交还窗口亮度失败: %{public}s', err.message);
    }
  }

  /**
   * 进入播放页时读回**手机当前的亮度**作为 HUD 起点。
   *
   * 源码对应 `ScreenBrightnessPlatform.instance.application`（`:1107`）：
   * 进页面先把应用亮度对齐到系统值，再让手势在这个基础上加减。
   * 读不到就保持默认值——只影响 HUD 起点，不影响手势本身。
   */
  private syncBrightnessFromSystem(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      // 注意：`getValueSync` 的第三个参数与返回值都是**字符串**
      const raw: string = settings.getValueSync(
        context, settings.display.SCREEN_BRIGHTNESS_STATUS, '-1');
      const value: number = Number.parseInt(raw, 10);
      if (value >= 0) {
        // 系统设置里的亮度是 0–255
        this.panelBrightness = Math.min(1, Math.max(0, value / 255));
        hilog.info(DOMAIN, TAG, '读回系统亮度 %{public}d/255', value);
      }
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '读系统亮度失败（保持默认）: %{public}s', err.message);
    }
  }

  // ============================================================
  // 系统音量（音量键 / 系统面板与应用内手势同一个值）
  // ============================================================

  /**
   * 绑定系统媒体音量。
   *
   * 源码在移动端**只调系统音量**（`player_playback_controller.dart:567` 的
   * `syncVolumeToDevice`：手机走 `FlutterVolumeController.setVolume`，桌面才调播放器音量），
   * 并且监听外部变化（音量键 / 系统面板）回写 UI（`applyExternalVolume`）。
   * 这里同样：读一次当前值 → 订阅 `volumeChange` → 手势改的是系统音量。
   */
  private bindSystemVolume(): void {
    try {
      const manager: audio.AudioManager = audio.getAudioManager();
      const volume: audio.AudioVolumeManager = manager.getVolumeManager();
      this.audioManager = manager;
      this.volumeManager = volume;
      // 媒体流音量：`STREAM_USAGE_MUSIC` 就是音视频播放走的那条流
      const usage: audio.StreamUsage = audio.StreamUsage.STREAM_USAGE_MUSIC;
      // 这个 SDK 上同步读系统音量只有 `*ByStream` 这一组（`getVolumeSync` 属于
      // AudioVolumeGroupManager）；读不到就整体回落播放器音量，不做半吊子兼容。
      const max: number = volume.getMaxVolumeByStream(usage);
      const current: number = volume.getVolumeByStream(usage);
      if (max > 0) {
        this.mediaVolumeMax = max;
        this.volume = VideoPage.toPercent(current, max);
      }
      Logger.info('AutumnPlayer',
        `系统音量通道就绪：当前 ${current}/${max}（${Math.round(this.volume)}%）`);
      this.volumeGestureTarget = this.volume;
      volume.on('streamVolumeChange', usage,
        (event: audio.StreamVolumeEvent) => {
          // 外部（音量键 / 系统面板）改了音量：只回写 UI，不再打回系统，避免回环
          if (this.mediaVolumeMax <= 0) {
            return;
          }
          /**
           * ⚠️ 这里**不再**做「回调报的档位 ≠ 请求档位 ⇒ 判定写不动」的自检
           * （2026-09-19 删）。
           *
           * 一次拖动会连写几十次音量，而 `streamVolumeChange` 是异步、乱序的：
           * 「这次回调报的是上一档」在拖动中是常态，按失败计会**误判**成
           * 「系统音量写不动」，于是把好好的系统音量通道关掉、改走播放器音量
           * ——音量再乘一层，反而更小（用户看到的「调不到 100%」可能有它一份）。
           *
           * 真正的自检搬到了 `finishVolumeGesture()`：手势结束后等写入落地，
           * 直接对比「我们请求的」和「系统现在的」，不再依赖回调顺序。
           */
          // 音量手势进行中：数值以手势累加值为准，别让回调把它冲回去。
          if (this.activeGesture === PlayerGesture.volume) {
            return;
          }
          /**
           * **自己写出来的回声也要忽略**（2026-09-19 修「松手回弹」）。
           *
           * 一次拖动会连写几十次音量，`streamVolumeChange` 回调是异步的：
           * 手势结束后那些**旧档位**的回调才陆续回来，如果按「外部改了音量」
           * 处理，HUD 就会被拉回拖动中途的某个值——用户看到的就是「弹回去」。
           * 紧跟在自己写之后的 500ms 窗口里，这些回调一律当回声。
           * （真人按音量键不会恰好落在这个窗口里，误吞概率极低。）
           */
          if (Date.now() - this.lastSelfVolumeWriteAt < 500) {
            return;
          }
          this.volume = VideoPage.toPercent(event.volume, this.mediaVolumeMax);
          this.volumeGestureTarget = this.volume;
          this.showVolumeAdjustmentHud();
          // 按音量键 / 系统面板要自动收起（真机实测：不加这句 HUD 会一直挂在画面上）；
          // 手势那条路在 `gestureEnd` 里收（上面已经 `return` 掉了）。
          this.hideAdjustmentHudLater();
          hilog.info(DOMAIN, TAG, '系统音量变化 → %{public}d%%（音量键/系统面板）',
            this.volume);
        });
      hilog.info(DOMAIN, TAG, '已接入系统媒体音量：%{public}d/%{public}d',
        current, max);
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '接入系统音量失败，回落到播放器音量: %{public}s',
        err.message);
      this.volumeManager = null;
      this.audioManager = null;
    }
  }

  private unbindSystemVolume(): void {
    const manager: audio.AudioVolumeManager | null = this.volumeManager;
    if (manager === null) {
      return;
    }
    try {
      manager.off('streamVolumeChange');
    } catch (e) {
      // 解绑失败不影响退出
    }
    this.volumeManager = null;
    this.audioManager = null;
  }

  /**
   * 手势改音量：写系统媒体音量；没有系统音量能力时回落到播放器音量。
   * 返回是否已经由系统音量接管（接管后不再调 `engine.setVolume`，避免双重衰减）。
   */
  private applySystemVolume(percent: number): boolean {
    const manager: audio.AudioManager | null = this.audioManager;
    if (manager === null || this.mediaVolumeMax <= 0 || !this.sysVolumeWritable) {
      Logger.info('AutumnPlayer',
        `系统音量不可用（manager=${manager !== null} max=${this.mediaVolumeMax} writable=${this.sysVolumeWritable}），改用播放器音量`);
      return false;
    }
    const clamped: number = Math.min(100, Math.max(0, percent));
    const target: number = Math.round(clamped / 100 * this.mediaVolumeMax);
    // 记下「刚写过」的时刻：回调里据此区分「自己写出来的回声」和「音量键改的」
    this.lastSelfVolumeWriteAt = Date.now();
    // `setVolume` 是这里唯一能改系统音量的入口（只影响媒体流，不动铃声/闹钟）
    manager.setVolume(audio.AudioVolumeType.MEDIA, target)
      .then(() => {
        Logger.info('AutumnPlayer',
          `系统音量 → ${target}/${this.mediaVolumeMax}（${Math.round(clamped)}%）`);
      })
      .catch((error: Error) => {
        // **必须在这里回落**：以前是乐观返回 true，系统音量调用失败就什么都不改，
        // 真机表现就是「手势滑了半天音量毫无变化」。
        Logger.info('AutumnPlayer',
          `设置系统音量失败：${error.message}，回落播放器音量 ${Math.round(clamped)}%`);
        // 写不动就**永久**改走播放器音量（否则每一帧都要等一次失败的调用）
        this.sysVolumeWritable = false;
        this.applyPlayerVolume(clamped);
      });
    return true;
  }

  /** 系统音量级数 → 百分比（UI 与手势都用 0–100）。 */
  private static toPercent(level: number, max: number): number {
    if (max <= 0) {
      return 0;
    }
    return Math.round(Math.min(100, Math.max(0, level / max * 100)));
  }

  /**
   * 交给播放器的音量。
   *
   * 手机上响度由**系统媒体音量**负责（与源码一致：移动端只调系统音量，
   * `player_playback_controller.dart:567`），播放器自身保持满音量；
   * 否则系统 50% × 播放器 50% 会变成 25% 的双重衰减。
   * 拿不到系统音量能力时（模拟器 / 无音频服务）才由播放器音量接管。
   */
  private engineVolume(): number {
    // 系统音量写不动时（见 `sysVolumeWritable`）播放器音量得自己顶上，
    // 否则全屏切集重新 loadfile 之后又回到满音量。
    return this.volumeManager !== null && this.mediaVolumeMax > 0
      && this.sysVolumeWritable ? 100 : this.volume;
  }

  // ============================================================
  // 全屏
  // ============================================================


  private async toggleFullscreen(): Promise<void> {
    const next: boolean = !this.fullscreenIntent;
    this.fullscreenIntent = next;
    /**
     * 与参照实现同序（`player_item.dart:871`）：**先发原生调用，紧接着翻状态**。
     * 原生那一侧负责「系统栏带动画隐藏 + AUTO_ROTATION_LANDSCAPE +
     * 横屏多窗口」（见 `enterFullscreenNative`），状态这一侧负责布局，
     * 两边同时发生，那一下变化就被旋转动画盖住了。
     */
    this.markRotating();
    if (next) {
      this.enterFullscreenNative();
    } else {
      this.exitFullscreenNative();
    }
    if (this.fullscreenRotationReached()) {
      this.applyFullscreenState();
      this.scheduleFullscreenRotationSettle();
    } else {
      this.armFullscreenApply();
    }
  }

  private async exitFullscreen(): Promise<void> {
    if (!this.fullscreen && !this.fullscreenIntent) {
      return;
    }
    this.fullscreenIntent = false;
    this.markRotating();
    this.exitFullscreenNative();
    if (this.fullscreenRotationReached()) {
      this.applyFullscreenState();
      this.scheduleFullscreenRotationSettle();
    } else {
      this.armFullscreenApply();
    }
  }


  /**
   * 安排「全屏布局落地」。
   *
   * **不在这里立刻改布局**（2026-09-18 用户反馈：「竖屏会先变成满屏再旋转」——
   * 我们先铺满、系统再转，那一下就很扎眼）。而是等 `onAreaChange` 发现
   * **窗口宽度真的变了**（= 系统开始旋转）时再落地：跳变发生在旋转过程里，
   * 被旋转动画盖住——这也正是源码的观感（它发完 `AUTO_ROTATION_LANDSCAPE`
   * 就翻状态，两边几乎同时发生）。
   *
   * 另配一个 600ms 兜底：设备没转（模拟器 / 分屏）时照样把状态落下去。
   */
  private armFullscreenApply(): void {
    if (this.fullscreenApplyTimer >= 0) {
      clearTimeout(this.fullscreenApplyTimer);
    }
    /**
     * 兜底时长从 600ms 提到 **1400ms**。
     *
     * 600ms 时系统常常还没开始转（实测点击到真正转过去 600–900ms），
     * 于是「兜底先落地」把页面切成全屏布局、窗口还是竖的——用户看到的
     * 就是「竖屏居中、四周黑，停好一会才转」（2026-11-01）。
     * 1400ms 只在设备确实不转（模拟器 / 分屏）时才兜底，正常机型永远
     * 等得到 `onAreaChange`，不会再出现那段卡在中间的状态。
     */
    this.fullscreenApplyTimer = setTimeout(() => {
      this.fullscreenApplyTimer = -1;
      hilog.info(DOMAIN, TAG, '窗口未旋转，兜底落地全屏布局');
      this.applyFullscreenState();
      this.scheduleFullscreenRotationSettle();
    }, 1400);
  }

  onBackPress(): boolean {
    if (this.anyMenuOpen()) {
      this.closeMenus();
      return true;
    }
    if (this.fullscreen || this.fullscreenIntent) {
      this.exitFullscreen();
      return true;
    }
    // 与顶栏「返回」同一个入口：竖屏时回详情页并重开来源弹层
    this.handleBack();
    return true;
  }

  // ============================================================
  // 渲染
  // ============================================================

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Stack({ alignContent: Alignment.Center }) {
          this.surface()
          // 弹幕层贴在视频之上、控制层之下：不参与命中测试，手势与按钮不受影响
          // 旋转瞬间不挂弹幕层：它每帧按新容器尺寸重排飞行中的弹幕，
          // 与系统旋转动画叠在一起就是掉帧（见字段 `rotating` 的注释）
          if (!this.rotating && this.danmakuOn && this.activeDanmakus.length > 0) {
            DanmakuLayer({
              active: this.activeDanmakus,
              containerWidth: this.captureWidth(),
              containerHeight: this.captureHeight(),
              laneHeight: SettingsStore.getNumber(SettingsKeys.danmakuFontSize)
                * (1 + SettingsStore.getNumber(SettingsKeys.danmakuLineHeight))
            })
              /**
               * 旋转期间这一层会**被摘掉**（每帧按新尺寸重排飞行中的弹幕，
               * 与系统旋转动画叠在一起就是掉帧）。摘的时候加一条淡出、
               * 回来时淡入，避免原来那种「啪」地消失再「啪」地出现
               * （2026-09-18 美化：全屏切换的丝滑感）。
               */
              .transition(TransitionEffect.OPACITY.animation({
                duration: MotionRuntime.ms(Motion.quick),
                curve: AppCurves.easeOutCubic()
              }))
          }
          if (!this.rotating && (this.showSeekHud || this.showSpeedHud ||
            this.showBrightnessHud || this.showVolumeHud)) {
            // HUD 贴视频区顶部 25vp、水平居中，且不吃手势
            // （参照实现 `player_item_panel.dart:486`：`Positioned(top: 25)`）。
            Column() {
              this.hud()
            }
            .width('100%')
            .height('100%')
            .alignItems(HorizontalAlign.Center)
            .justifyContent(FlexAlign.Start)
            .padding({ top: HUD_TOP })
            .hitTestBehavior(HitTestMode.None)
          }
          if (this.panelVisible && !this.locked && !this.rotating) {
            // 两条渐隐遮罩比面板慢（1 秒，§39.4），且不参与命中测试
            this.masks()
            this.topBar()
            this.bottomBar()
            // 暂停时的**中央大播放键已去掉**（用户决定，2026-09-15）。
            // 规格 §10.1 记的是原版行为：未播放时视频区中央有 144×144 播放键。
            // 但原版那 144×144 是**容器**、里面的 `PlayPauseIcon` 默认 `iconSize = 25`
            // （`play_pause_icon.dart:9`）；本工程把字形写成了 56vp，等于放大 2.2 倍，
            // 暂停时屏幕上就是一个巨大的播放三角。与其留一个与原型不一致的大图标，
            // 不如去掉——暂停/播放的入口仍有底部控制栏那个按钮（与源码同为 25vp 级别）。
          }
          /**
           * 全屏时右侧竖排控制条（§39.7）：截图 + 锁定 / 解锁。
           *
           * 挂了 `panelVisible` 而不是 `panelVisible || locked`：锁定后这颗解锁
           * 按钮也要跟着控制层的自动收起一起消失、点画面再出现（用户 2026-10-07）。
           * 锁定时 `panelVisible` 只剩它在用（上下栏另有 `!this.locked` 把关）。
           */
          if (this.fullscreen && this.panelVisible && !this.rotating) {
            this.leftControlBar()
          }
          if (this.loading || this.errorMessage.length > 0) {
            this.statusOverlay()
          }
        }
        .width('100%')
        /**
         * 全屏 / 横屏（含平板未点全屏）视频区铺满可用高度；只有竖屏非全屏
         * 才按 16:9 定高，下面留给常驻目录（见 `videoFillsWindow`）。
         */
        .height(this.videoFillsWindow() ? '100%' : this.captureHeight())
        .backgroundColor(Color.Black)
        // 手势挂在**视频区容器**上（等价于参照实现里包住整个播放器的
        // GestureDetector）：按钮/进度条这些子节点优先响应，落在空白处的
        // 点击才冒泡到这里。单独铺一层手势层会与子节点的点击抢事件
        // （实测：点「倍速」会被手势层当成切控制层，菜单永远弹不出来）。
        .gesture(
          GestureGroup(GestureMode.Parallel,
            // 双击优先、单击兜底：互斥组按声明顺序给优先级
            GestureGroup(GestureMode.Exclusive,
              TapGesture({ count: 2 })
                .onAction(() => {
                  this.togglePlay();
                }),
              TapGesture({ count: 1 })
                .onAction(() => {
                  // 刚做完亮度/音量/进度手势：这次抬起不算「切换控制层」
                  if (this.swallowTapAfterGesture) {
                    this.swallowTapAfterGesture = false;
                    hilog.info(DOMAIN, TAG, '调整手势后的单击已忽略（不切控制层）');
                    return;
                  }
                  this.togglePanel();
                })
            ),
            // 长按临时倍速（§15.5）
            LongPressGesture({ repeat: false })
              .onAction(() => {
                this.beginLongPressSpeed();
              })
              .onActionEnd(() => {
                this.endLongPressSpeed();
              }),
            // 横向拖动 = 进度，纵向拖动 = 亮度 / 音量（§15.6 / §15.7）
            PanGesture({ fingers: 1, distance: 5 })
              .onActionStart((event: GestureEvent) => {
                this.gestureBegin(event.fingerList[0].localX, event.fingerList[0].localY);
              })
              .onActionUpdate((event: GestureEvent) => {
                this.gestureMove(event.fingerList[0].localX, event.fingerList[0].localY);
              })
              .onActionEnd(() => {
                this.gestureEnd();
              })
              .onActionCancel(() => {
                this.gestureEnd();
              })
          )
        )
        /**
         * 记住**手指按下**的位置：`PanGesture` 的起点要等手指移动 5vp 才上报，
         * 拿它判「这次手势落在全屏顶栏区域」会偏下（见 `touchDownY` 注释）。
         * 这里只记 y，不做别的；把按下点交给 `gestureBegin()`。
         */
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down && event.touches.length > 0) {
            this.touchDownY = event.touches[0].y;
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.touchDownY = -1;
          }
        })
        .onAreaChange((oldValue: Area, newValue: Area) => {
          // 首帧必须立刻同步（否则先按错误尺寸渲染），之后一律走去抖：
          // 旋转过程中这里每帧都会报一个新尺寸，逐次同步就是「卡顿」的来源
          const first: boolean = this.viewportWidth <= 0;
          const previousWidth: number = this.viewportWidth;
          this.viewportWidth = Number(newValue.width);
          this.viewportHeight = Number(newValue.height);
          /**
           * (a) 先消费**上一次布局变化留下的立即同步**。
           *
           * ⚠️ 顺序不能反：本次回调里的 `viewportWidth/Height` 是**变化前**的
           * 矩形；上一次打了标记、这一次才拿得到布局后的尺寸。同一帧就同步的话，
           * 缓冲还是按旧矩形开的，画面会被压扁——这正是上一版的毛病。
           */
          const immediate: boolean = first || this.pendingImmediateSync;
          this.pendingImmediateSync = false;
          /**
           * (b) 视频区宽度变化只用来触发暂停帧刷新。
           *
           * 全屏布局不再在这里抢先落地：`viewportWidth` 在竖屏下本来就是
           * 宽大于高，不能用它判断窗口是否已经转成横屏。最终方向由根容器
           * 的 `onAreaChange` 判断，避免布局比系统旋转提前一步。
           */
          if (!first && Math.abs(this.viewportWidth - previousWidth) > 1) {
            this.schedulePausedSurfaceRefresh();
          }
          /**
           * (c) 横竖形态变了就同步「右侧目录竖栏」。
           *
           * 对照参照实现：`_isSideTabLayout = _windowIsLandscape`，
           * 且 `showTabBody` 默认就是 true（进全屏时才收起来）。所以
           * 平板横屏一进来/一转过去，目录竖栏默认是打开着的——视频居左、
           * 目录居右，这正是平板该有的样子；转回竖屏则收起（竖屏的目录
           * 常驻在视频下方，用不上面板）。
           */
          // 判据用**窗口**尺寸，不是视频区尺寸（竖屏视频区是 16:9 扁矩形，
          // 拿它判会得到相反的结论 → 布局来回翻，见 `windowIsLandscape()`）。
          const landscapeNow: boolean = this.windowIsLandscape();
          if (landscapeNow !== this.landscapeState) {
            this.landscapeState = landscapeNow;
            /**
             * `!this.rotating`：进出全屏旋转到一半时，窗口已经是横的、
             * `fullscreen` 还没落地，这里会误判成「平板横屏、用户没点全屏」，
             * 于是把右侧目录竖栏弹出来——就是「莫名闪一下平板 UI」。
             */
            /**
             * `!this.fullscreen` 这一条**不能省**：全屏且横屏时，这里会把
             * 「平板横屏未全屏」的目录竖栏打开，于是全屏画面右侧多出一整块
             * 选集列表（2026-11-01 用户截图里的第二张）。
             */
            if (landscapeNow && !this.fullscreen && !this.inFullscreenTransition()) {
              this.showPanelInFullscreen = true;
            } else if (!landscapeNow) {
              this.showPanelInFullscreen = false;
            }
          }
          /**
           * 用实测尺寸（vp）重算，换算成像素后交给 mpv。
           *
           * **旋转过程中不跟着中间尺寸走**（2026-09-18 美化）：那些中间值
           * 只是系统旋转动画的过渡帧，按它们去重分配 mpv 的输出缓冲，
           * 画面会跟着抖一下甚至闪黑。全屏布局落地时 `applyFullscreenState()`
           * 会同步一次最终尺寸，这里只要保证首帧同步即可。
           *
           * 例外：**全屏布局落地后的那一次必须立刻同步**（`immediate`）——
           * 矩形长宽比变了，等 120ms 去抖的话中间几帧画面是被压缩的。
           */
          /**
 * 旋转/转场过程中**不做 surface 重建**。
 *
 * 给 mpv 重新分配输出缓冲是这一页最重的一步（实测会让系统旋转动画掉帧）。
 * 原来的判据只看 `rotating`（点击后 460ms 就到期），而真实旋转要 600–900ms，
 * 于是「布局刚落地、动画还在转」的那几帧正好赶上重建 → 卡顿。
 * 现在只要**转场还没结束**（`fullscreenIntent` 与 `fullscreen` 不一致）就先跳过，
 * 交给 `markRotating` 到期后的那一次同步兜住。
 */
if (!this.rotating && this.fullscreenIntent === this.fullscreen) {
  this.scheduleSyncSurfaceSize(immediate);
}
        })

        /**
         * 竖屏非全屏才在视频下方常驻目录；横屏（含平板未点全屏）时目录走
         * 右侧竖栏（`sidePanel()`），视频本身就铺满整屏。
         */
        if (!this.videoFillsWindow()) {
          this.episodePanel()
        }
      }
      .width('100%')
      .height('100%')
      /**
       * 根容器填**黑**：全屏时 16:9 画面之外的补边、以及剧集面板顶部那两个
       * 圆角**外面**露出来的底，都要是黑的（2026-09-18 的「与视频连成一体」）。
       *
       * ⚠️ 竖屏状态栏那一条**不再靠本层底色**（见下面那条 `statusBarStrip()`）：
       * 竖屏状态栏要的是黑底白标（2026-10-07），但不能靠改根容器的底色去凑——
       * 根容器一旦整体换色，剧集面板顶部圆角外面会跟着变，所以改成
       * 「根容器保持黑 + 单独铺一条竖屏状态栏底色」。
       */
      .backgroundColor(Color.Black)
      // 竖屏（非全屏）时视频区从**状态栏之下**开始，与参照实现的
      // `SafeArea(top: !isFullscreen)` 等价。不这样做的话，状态栏那 39vp
      // 会算进视频区，顶部控制条一垫高就把 16:9 的画面吃掉将近一半。
      .padding({ top: this.fullscreen ? 0 : this.topInset })




      /**
       * 竖屏状态栏那一条的底色（原版观感）——见 `statusBarStrip()` 的注释。
       */
      if (!this.fullscreen) {
        this.statusBarStrip()
      }

      if (this.videoFillsWindow() && this.showPanelInFullscreen) {
        this.sidePanel()
      }

      // 自绘弹层（视频详情 / 弹幕设置 / 时间校准 / 投屏）——
      // 见 `sheetLayer()` 注释：本页的 `bindSheet` 在真机上不显示。
      //
      // ⚠️ **跟着内容一起转**：全屏时整页被转了 90°，如果弹层还画在旋转层外面，
      // 它就会横躺在竖屏坐标系里（用户 2026-11-01：「按钮触发的位置还是竖屏」）。
      if (this.showVideoInfo || this.showDanmakuSheet ||
        this.showDanmakuOffset || this.showDlnaSheet) {
        this.sheetLayer()
      }

      // 截图反馈（§38.3：420ms 线性驱动，压暗 + 取景框收拢）
      if (this.screenshotToken > 0) {
        ScreenshotFeedback({ token: this.screenshotToken, durationMs: Motion.banner })
      }

      // 取流宿主：1×1、透明、不参与命中测试（与阶段 0 / 2 同款做法）
      VideoSourceWebHost({
        targetUrl: this.captureUrl,
        reloadToken: this.reloadToken,
        injectScripts: true,
        onLog: (message: string) => {
          this.sourceLogs = [message, ...this.sourceLogs].slice(0, 100);
        },
        onFinished: (result: VideoSourceResult | null) => {
          // 结果由 armResolver 的 Promise 收敛，这里只留日志位
        }
      })
    }
    .width('100%')
    .height('100%')
    /**
     * 根容器（= 窗口可见区）实测尺寸。
     *
     * 只喂 `windowWidthVp/HeightVp`（**横竖屏判据**）。视频区自己的
     * `onAreaChange` 在视频区容器上，量的是视频区——两者**不能混用**：
     * 竖屏时视频区按 16:9 定高，宽大于高，拿它判横竖会让布局在两个形态
     * 之间反复翻（见 `windowIsLandscape()` 的注释）。
     */
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const w: number = Number(newValue.width);
      const h: number = Number(newValue.height);
      if (w > 0 && Math.abs(w - this.windowWidthVp) > 0.5) {
        this.windowWidthVp = w;
      }
      if (h > 0 && Math.abs(h - this.windowHeightVp) > 0.5) {
        this.windowHeightVp = h;
      }
      /**
       * 根容器尺寸才是窗口方向的真值。到达目标方向后立刻落布局，
       * 再对后续尺寸变化做去抖；最后一条回调停止约 270ms 后才恢复控件。
       */
      if (this.rotating && this.fullscreenRotationReached()) {
        this.applyFullscreenState();
        this.scheduleFullscreenRotationSettle();
      }
    })
  }

  /**
   * 视频页的四个弹层（视频详情 / 弹幕设置 / 弹幕时间校准 / 投屏）。
   *
   * ⚠️ **不能用 `bindSheet`**：本页四个 `bindSheet` 在真机上**一个都不显示**
   * （2026-09-16 实测：从「更多」菜单点「视频详情」「弹幕设置」「投屏」
   * 都只关掉菜单、没有任何弹层出现，`uitest dumpLayout` 里连
   * `SheetWrapper` / `SheetPage` 节点都没有）。同工程的 `InfoPage` 用
   * `bindSheet` 是正常的，差别是本页 Stack 里有个 `XComponent` 原生表面。
   * 因此这四个弹层仍然自绘。
   *
   * 注意区分：**选项菜单**已经全部改回 HarmonyOS 原生 `bindMenu`
   * （2026-09-17，见 `moreMenu` / `speedMenu` 的注释），只有这四个
   * 「底部大弹层」因为上面那条 `XComponent` 限制保持自绘。
   * 两者不是同一个坑：`bindMenu` 的失败条件是「挂在自定义组件上 + 带空
   * `onClick`」，挂在 `Row` 上且 `onClick` 有实际动作时可用。
   */
  @Builder
  sheetLayer() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 遮罩：点空白处关闭。带淡入淡出——原来它是瞬间出现/消失的，
      // 关弹层时背景先「啪」地变亮、面板再往下滑，观感就是「退场很生硬」。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        // 退场跟着面板一起淡掉（`closeSheets` 驱动，参数照源码：200ms 减速）
        .opacity(this.sheetExiting ? 0 : 1)
        .animation({
          duration: MotionRuntime.ms(SHEET_EXIT_MS),
          curve: HS.decelerate()
        })
        .transition(TransitionEffect.OPACITY.animation({
          duration: MotionRuntime.ms(Motion.quick),
          curve: AppCurves.easeOutCubic()
        }))
        .onClick(() => {
          this.closeSheets();
          this.scheduleHide();
        })

      Column() {
        // 拖拽条（对应 `SheetOptions.dragBar: true`）：**纯装饰**，不接手势。
        // 用户 2026-09-18：「弹窗能不要手动下滑的功能嘛，改回去」——
        // 下拉跟手那一版会让弹层在松手时先弹回原位再消失，反而不干净；
        // 现在只保留这条视觉指示，关闭统一走淡出 + 整块下滑的退场动画。
        Column()
          .width(36)
          .height(4)
          .borderRadius(2)
          .backgroundColor('#33FFFFFF')
          .margin({ top: 8, bottom: 4 })

        if (this.showVideoInfo) {
          this.videoInfoSheet()
        } else if (this.showDanmakuSheet) {
          this.danmakuSheet()
        } else if (this.showDanmakuOffset) {
          this.danmakuOffsetSheet()
        } else {
          this.dlnaSheet()
        }
      }
      /**
       * 弹层宽度：
       *   - 竖屏：整宽（沿用原来的底部弹层形态）；
       *   - **全屏（横屏）：收窄到进度条长度的一半并水平居中**
       *     （用户 2026-09-18：「全屏下这两个的弹窗尺寸太大了，我希望高度不变，
       *      然后长度变窄一点，大概进度条的一半」）。
       * 高度完全不动（仍是下面那两档），只改长度。
       */
      .width(this.sheetWidth())
      /**
       * 高度：**四个弹层统一 88%**（≈ SheetSize.LARGE）。
       *
       * 用户 2026-09-18：「视频详情的弹窗高度调成跟弹幕设置的弹窗高度相同」
       * —— 原来视频详情/时间校准/投屏是 58%，只有弹幕设置 88%，两档摆在一起
       * 高度跳变很明显。统一到弹幕设置那一档。
       */
      .height('88%')
      /**
       * 弹层底色 = **系统默认白**（用户 2026-09-18：「颜色没有换成之前说过的
       * 系统默认白色」「弹幕设置页面颜色也换一下」）。
       *
       * 用 `sys.color.comp_background_primary`——本工程里 `CharacterSheet` /
       * `SourceSheet`（走系统 `bindSheet` 的两张卡）用的就是这个资源，
       * 它渲染出来和系统弹窗是同一个白。原来写死的 `AppColor.surfaceContainerLow`
       * 是主题派生出来的 M3 中性色，摆在一起就是「两种白」。
       */
      .backgroundColor($r('sys.color.comp_background_primary'))
      .borderRadius({ topLeft: 24, topRight: 24 })
      .clip(true)
      /**
       * 入场：淡入 + 从底部滑上来，带过冲（§38.4 第 1 处，
       * `adaptive_bottom_sheet.dart:117-127`：mass 1 / stiffness 380 / ratio 0.8）。
       * 曲线给弹簧时 ArkUI 会忽略 duration，时长由弹簧参数决定（与 `animateTo` 同）。
       *
       * 退场**不靠这个 transition**：弹层整棵子树是被外层 `if` 一次性移除的，
       * ArkUI 不播子树内部节点的退场 transition（所以原来是「直接消失」）。
       * 退场由下面的 `translate` / `opacity`（跟着 `sheetExiting` 走）负责，
       * 动画走完才真正移除——见 `sheetExiting` 与 `closeSheets` 的注释。
       */
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.animation({
          duration: MotionRuntime.ms(PANEL_ANIM_MS),
          curve: AppCurves.springSheet()
        }).combine(TransitionEffect.translate({ y: '100%' }).animation({
          duration: MotionRuntime.ms(PANEL_ANIM_MS),
          curve: AppCurves.springSheet()
        })),
        TransitionEffect.OPACITY.animation({
          duration: MotionRuntime.ms(PANEL_ANIM_MS),
          curve: AppCurves.springSheet()
        }).combine(TransitionEffect.translate({ y: '100%' }).animation({
          duration: MotionRuntime.ms(PANEL_ANIM_MS),
          curve: AppCurves.springSheet()
        }))
      ))
      /**
       * 退场：顺着原路滑下去 + 淡出。
       *
       * 参数**照源码**（`adaptive_bottom_sheet.dart` 的 `AnimationStyle`）：
       * 退场 200ms、减速曲线——比入场短、不用弹簧（入场才带过冲）。
       * 状态由 `sheetExiting` 驱动，动画走完才真正移除整棵子树。
       */
      .translate({ y: this.sheetExiting ? '100%' : 0 })
      .opacity(this.sheetExiting ? 0 : 1)
      .animation({
        duration: MotionRuntime.ms(SHEET_EXIT_MS),
        curve: HS.decelerate()
      })
    }
    .width('100%')
    .height('100%')
  }

  /** 关掉所有视频页弹层。 */
  private closeSheets(): void {
    const anyOpen: boolean = this.showVideoInfo || this.showDanmakuSheet ||
      this.showDanmakuOffset || this.showDlnaSheet;
    if (!anyOpen || this.sheetExiting) {
      return;
    }
    /**
     * 两段式退场（见 `sheetExiting` 的注释）：先播退场，再移除子树。
     * `sheetExiting` 的复位放在清标志之前——保证下一次打开弹层时它一定是
     * false，不会出现「新弹层一进来就在屏幕外」。
     */
    this.sheetExiting = true;
    if (this.sheetExitTimer >= 0) {
      clearTimeout(this.sheetExitTimer);
    }
    this.sheetExitTimer = setTimeout(() => {
      this.sheetExitTimer = -1;
      this.sheetExiting = false;
      this.showVideoInfo = false;
      this.showDanmakuSheet = false;
      this.showDanmakuOffset = false;
      this.showDlnaSheet = false;
    }, SHEET_EXIT_MS);
  }

  /**
   * 底栏进度条的实际长度（vp）。
   *
   * 和 `bottomBar()` 那一行的构成一一对应：整宽 − 左右安全区/控制边距 −
   * 两侧滑块边距 20 − 两端时间码各 `SHEET_TIME_LABEL_VP`。
   * 全屏 2412px 宽（804vp）时算出来 ≈ 664vp —— 与 `播放页美化/` 参考图里
   * 实测的轨道长度（x 230→2224 ≈ 1994px ≈ 664vp）一致。
   */
  private sheetBarLength(): number {
    const length: number = this.captureWidth()
      - this.controlInsetLeft() - this.controlInsetRight()
      - SHEET_TIME_LABEL_VP * 2 - 20;
    return length > 0 ? length : this.captureWidth();
  }

  /**
   * 弹层宽度：竖屏整宽；**全屏取进度条长度的一半**（用户 2026-09-18 的口径）。
   */
  private sheetWidth(): number {
    if (!this.fullscreen) {
      return this.captureWidth();
    }
    /**
     * 0.75 × 进度条长度（用户 2026-09-18：先按「一半」做，实测反馈
     * 「弹窗的宽度加长一点吧，现在太窄了」，于是按比例放大到 3/4）。
     * 全屏 804vp 宽时 ≈ 500vp。
     */
    return Math.round(this.sheetBarLength() * 0.75);
  }

  @Builder
  surface() {
    XComponent({
      id: 'videoSurface',
      type: XComponentType.SURFACE,
      libraryname: 'mpv_bridge',
      controller: this.xController
    })
      /**
       * 尺寸 = **画面矩形**（不是容器）：等价源码 `Video(fit: ...)` 的
       * `BoxFit.contain`——画面永远按自身比例摆放，容器比例怎么变都只影响
       * 留黑，不会把画面拉扁（见 `videoBox` 的注释）。
       *
       * 外层 Stack 是 `alignContent: Center`，所以这块盒子在容器里居中。
       */
      .width(this.videoBoxW())
      .height(this.videoBoxH())
      .onLoad(() => {
        /**
         * XComponent 在全屏旋转时可能重新创建 Surface。这里必须复用已有
         * PlayerEngine，否则新引擎没有当前媒体地址，画面会保持黑色。
         */
        const engine: PlayerEngine = this.engine === null
          ? new PlayerEngine() : this.engine;
        this.engine = engine;
        this.engineAvailable = engine.isAvailable;
        const hardwareDecode: boolean = SettingsStore.getBool(SettingsKeys.hAenable);
        const revision: number = ++this.surfaceAttachRevision;
        // surface 晚于组件创建就绪，稍等一拍再绑定（阶段 0 实测的有效做法）
        setTimeout(() => {
          if (revision !== this.surfaceAttachRevision || this.engine !== engine) {
            return;
          }
          const surfaceId: string = this.xController.getXComponentSurfaceId();
          if (surfaceId.length === 0) {
            hilog.warn(DOMAIN, TAG, 'SurfaceId 为空，跳过本次绑定');
            return;
          }
          engine.attach(surfaceId, hardwareDecode);
          this.syncSurfaceSize();
          engine.setSpeed(this.speed);
          engine.setVolume(this.engineVolume());
          if (!engine.isAvailable) {
            this.loadingHint = '当前设备无 libmpv（模拟器为桩实现）：取流已成功，播放不可用';
          } else if (this.pendingSource.length > 0) {
            const params = new PlaybackParams();
            params.url = this.pendingSource;
            params.audioUrl = this.pendingAudioUrl;
            params.offset = this.resumeOffsetSec;
            params.headers = this.buildHeaders();
            this.pendingSource = '';
            this.pendingAudioUrl = '';
            engine.play(params);
            engine.applyAspectRatio(this.aspect, this.captureWidth(), this.captureHeight());
            this.startPolling();
          } else if (this.currentVideoUrl.length > 0) {
            // Surface 重建时播放器继续持有原媒体；重新挂载后恢复画面比例，
            // 暂停态再强制重绘当前帧，避免保留旧 Surface 的空白画面。
            engine.applyAspectRatio(this.aspect, this.captureWidth(), this.captureHeight());
            if (!this.playing) {
              const pausedAt: number = engine.position();
              engine.refreshPausedFrame(pausedAt >= 0
                ? pausedAt : this.positionMs / 1000);
            }
            this.startPolling();
          }
        }, 300);
      })
  }

  /** 长按临时倍速：按下切快放，抬起还原（§15.5）。 */
  private beginLongPressSpeed(): void {
    // 长按倍速抬起时，Exclusive 组里的单击手势也可能成立；
    // 标记一次吞掉它，避免松手顺带把上下栏切出来。
    this.swallowTapAfterGesture = true;
    this.speedBeforeLongPress = this.speed;
    const boost: number =
      SettingsStore.getNumber(SettingsKeys.defaultShortcutForwardPlaySpeed);
    const target: number = boost > 0 ? boost : 2.0;
    const engine: PlayerEngine | null = this.engine;
    if (engine !== null) {
      engine.setSpeed(target);
    }
    /**
     * **必须同时改 `this.speed`**：倍速 HUD（`speedHud`）和底栏那个「倍速」
     * 文案读的都是它，只改引擎的话屏幕上还显示原档位——用户看到的就是
     * 「长按倍速显示错误」（2026-09-18）。
     *
     * 这里**不走 `applySpeed()`**：那个方法会把 `defaultPlaySpeed` 落盘，
     * 临时长按倍速不该改用户的默认档位；抬手时 `endLongPressSpeed` 负责还原。
     */
    this.speed = target;
    this.showSpeedHud = true;
    this.clearHideTimer();
    hilog.info(DOMAIN, TAG, '长按倍速 → %{public}sx（原 %{public}sx）',
      VideoPage.trimSpeed(target),
      VideoPage.trimSpeed(this.speedBeforeLongPress));
  }

  private endLongPressSpeed(): void {
    const engine: PlayerEngine | null = this.engine;
    if (engine !== null) {
      engine.setSpeed(this.speedBeforeLongPress);
    }
    // HUD / 底栏文案一起还原（它们读的就是 `this.speed`）
    this.speed = this.speedBeforeLongPress;
    this.showSpeedHud = false;
    this.expireSwallowedTapLater();
    this.scheduleHide();
    hilog.info(DOMAIN, TAG, '长按结束 → 还原 %{public}sx',
      VideoPage.trimSpeed(this.speedBeforeLongPress));
  }

  /**
   * 让「长按/调整手势后的这次单击」在合理时间内失效。
   *
   * 单击判定通常发生在抬手后 300ms 内；这里留 700ms 保险。
   * 真正的下一次点击如果晚于这个窗口，不会被误吞。
   */
  private expireSwallowedTapLater(): void {
    setTimeout(() => {
      this.swallowTapAfterGesture = false;
    }, 700);
  }

  /**
   * 竖屏状态栏那一条的底色：**黑**（用户 2026-10-07：「把竖屏状态栏换成
   * 黑底白标」）。
   *
   * 与 `applyStatusBar()` 里的 `statusBarColor: '#000000'` 是同一件事的两手：
   * 系统若照做，这条被系统栏盖住；系统若忽略底色，露出来的仍是这条黑底，
   * 配上白色的时间/图标，观感不变。
   *
   * ⚠️ 单独铺一层、**不要**改根容器的底色：剧集面板顶部那两个圆角露出来的
   * 是根容器的黑，根容器一改颜色，圆角就跟着散了（见 `build()` 里的注释）。
   *
   * 不参与命中测试：这只是底色，手指落在状态栏区域时不该被它吃掉（全屏时
   * 这一条根本不画，所以「全屏顶部下拉唤出系统状态栏」不受影响——全屏那条
   * 走的是 `applyStatusBar()` 里的透明底 + 白色图标，即 9 月最后一版的样子）。
   */
  @Builder
  statusBarStrip() {
    Column()
      .width('100%')
      .height(this.topInset)
      .backgroundColor(Color.Black)
      .hitTestBehavior(HitTestMode.None)
      .transition(TransitionEffect.OPACITY.animation({
        duration: MotionRuntime.ms(Motion.quick),
        curve: AppCurves.easeOutCubic()
      }))
  }


  @Builder
  masks() {
    Column() {
      // 顶部：黑 45% → 透明，高 50（§39.4 第 1 层）
      Column()
        .width('100%')
        .height(TOP_MASK_HEIGHT)
        // 遮罩内层也要显式不吃触摸：容器上设 None 只作用于容器自身，
        // 子节点仍然按默认（自身+子节点响应）参与命中测试——
        // 真机实测就是它在顶端那 50vp 里把「返回 / 快进 / 更多」的点击吃掉了。
        .hitTestBehavior(HitTestMode.None)
        .linearGradient({
          angle: 180,
          colors: [['#73000000', 0.0], ['#00000000', 1.0]]
        })
      Blank()
      // 底部：透明 → 黑 45%，高 100（§39.4 第 2 层）
      Column()
        .width('100%')
        .height(BOTTOM_MASK_HEIGHT)
        .hitTestBehavior(HitTestMode.None)
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], ['#73000000', 1.0]]
        })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    // 遮罩跟着控制层显隐，但节奏更慢：1 秒（§39.4 的 AnimatedPositioned）
    .transition(TransitionEffect.OPACITY.animation({
      duration: MotionRuntime.ms(MASK_ANIM_MS),
      curve: AppCurves.easeInOut()
    }))
  }

  /**
   * 全屏右侧竖排控制条（§39.7）。
   * 自下而上：截图（锁定时隐藏）、锁定 / 解锁。
   */
  @Builder
  leftControlBar() {
    Column() {
      if (!this.locked) {
        Row() {
          SymbolGlyph($r('sys.symbol.camera'))
            .fontSize(20)
            .fontColor(['#FFFFFF'])
        }
        .padding(10)
        .onClick(() => {
          this.captureScreenshot();
          this.scheduleHide();
        })
      }
      // §46.4：`lock_outline` → `lock`、`lock_open` → `lock_open`（没有 fill 变体）
      Row() {
        SymbolGlyph($r(this.locked ? 'sys.symbol.lock' : 'sys.symbol.lock_open'))
          .fontSize(20)
          .fontColor(['#FFFFFF'])
      }
      .padding(10)
      .onClick(() => {
        this.toggleLock();
      })
    }
    .width(44)
    // **不要铺满整列**：ArkUI 的容器会按自身 bounds 命中测试，
    // 竖排控制条一旦拉满高度就会把右上角的「更多」按钮罩住
    // （真机实测：全屏时点「更多」没反应，普通竖屏却正常）。
    //
    // 位置对齐参照实现 `leftControlWidget`：
    //   `Positioned(right: 0, top: 0, bottom: 0)` + 内部 `Column([Spacer, …, Spacer])`
    //   → 它其实是**在右边栏里垂直居中**（不是贴底），左右再让开系统安全区。
    // 之前钉在 `captureHeight - (locked ? 84 : 124)`，全屏时这组按钮会压在
    // 底栏那排按钮的同一高度带上，既不对齐也不好按（用户 2026-09-16 反馈）。
    // 这里用「知道自身高度、算居中 y」代替 Spacer —— 因为容器不能铺满整列。
    .padding({ left: 4, right: 4 })
    .position({
      // 右边缘与底栏最右按钮对齐（同一档 CONTROL_EDGE_INSET + 全屏右安全区）
      x: this.captureWidth() - this.controlInsetRight() - 44,
      y: (this.captureHeight() - this.sideColumnHeight()) / 2
    })
    .transition(TransitionEffect.OPACITY.animation({
      duration: MotionRuntime.ms(PANEL_ANIM_MS),
      curve: AppCurves.easeInOut()
    }))
  }

  @Builder
  statusOverlay() {
    Column({ space: 10 }) {
      if (this.errorMessage.length > 0) {
        SymbolGlyph($r('sys.symbol.arrow_2_circlepath'))
          .fontSize(36)
          .fontColor(['#FFFFFF'])
        Text('暂时无法播放').fontSize(16).fontColor('#FFFFFF')
        Text(this.errorMessage).fontSize(13).fontColor('#B3FFFFFF')
        Button('重试')
          .fontSize(13)
          .height(34)
          .margin({ top: 6 })
          .onClick(() => {
            this.changeEpisode(this.currentEpisode, this.currentRoad);
          })
      } else {
        /**
         * 取流/起播时的转圈：**纯白**（用户 2026-09-18：「视频的加载图标
         * 那个转圈圈换成白色」）。
         *
         * 原来是主题的 `tertiaryContainer`——浅色主题下它偏暖黄，
         * 压在纯黑的取流遮罩上既不像加载指示，也跟旁边的白色文案（`#FFFFFF`）
         * 不同色。这一层背景恒为纯黑，白色是唯一稳定的选择。
         */
        LoadingIndicator({ sizeVp: 32, colorHex: '#FFFFFF' })
        Text(this.loadingHint).fontSize(13).fontColor('#FFFFFF')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .justifyContent(FlexAlign.Center)
  }

  // ---------- 顶部控制条（§39.5） ----------

  @Builder
  topBar() {
    // 1:1 对齐参照实现 `player_item_panel.dart` 的 `topControlWidget`：
    //   IconButton（48×48，图标 24）+ 标题（titleMedium 16）+ 跳OP + **收藏** + 更多。
    // 我们的按钮一律写成「48×48 容器 + 内部图标」：既对齐尺寸，
    // 也顺带避开「onClick 直接挂叶节点会被视频区手势吃掉」那个坑。
    Row() {
      Row() {
        SymbolGlyph($r('sys.symbol.arrow_left'))
          .fontSize(24)
          .fontColor(['#FFFFFF'])
      }
      .width(48)
      .height(48)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        Logger.info('AutumnPlayer', '点击 返回');
        this.handleBack();
      })
      /**
       * 顶栏 = `标题 [集名]`，集名**直接取目录（剧集列表）里那一行显示的名字**
       * （用户 2026-09-18：「顶栏只用标题，主要是播放页的目录上的集名」）。
       *
       * 复用 `episodeLabel(episode)`——它正是 `episodeRow()` 用的同一个函数：
       * 插件给了 `identifier` 就用它，否则回退 `第N集`。这样顶栏和目录永远一致，
       * 不会再出现「顶栏写线路名、目录写集名」两套文案。
       * （对齐参照实现 `player_item_panel.dart:961` 的
       *  `' ${title} [${roadList[road].identifier[episode - 1]}]'`。）
       *
       * 2026-09-19：整行（剧名 + 集名）过一遍**繁 → 简**。集名来自 Bangumi /
       * 哔哩哔哩 / 插件，繁体线路给的就是繁体；剧名同理。转在显示层做，
       * 落库、历史、下载里的原始串都不动。
       */
      Text(` ${toSimplifiedChinese(this.sourceTitle)}` +
        ` [${this.episodeLabel(this.currentEpisode)}]`)
        .fontSize(16)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      /**
       * 跳 OP（§39.5.1）：单击快进、长按改秒数。参照实现用的是
       * `assets/images/forward_80.png`（高 24），这里沿用最接近的 `fast_forward`。
       *
       * 顶栏右侧三颗按钮做成**悬浮圆钮**（用户 2026-09-18：「右上角的按钮
       * 可以参考一样做成悬浮按钮」）：36vp 圆 + 半透明白底 + 细描边，
       * 和 HUD 用同一套深色玻璃令牌；外层的 48×48 只作触控热区，尺寸没变。
       */
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.fast_forward'))
            .fontSize(24)
            .fontColor(['#FFFFFF'])
        }
        .width(TOP_FLOAT_BUTTON)
        .height(TOP_FLOAT_BUTTON)
        .borderRadius(TOP_FLOAT_BUTTON / 2)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(HUD_GLASS_CHIP)
        .border({ width: 1, color: HUD_GLASS_BORDER })
      }
      .width(48)
      .height(48)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        Logger.info('AutumnPlayer', '点击 跳OP');
        this.skipForward();
      })
      .gesture(LongPressGesture({ repeat: false })
        .onAction(() => {
          this.openSkipTimeDialog();
        }))
      // 收藏（对应参照实现的 `PlayerPanelHoldCollectButton`）
      Row() {
        Row() {
          SymbolGlyph(VideoPage.collectIconOf(this.currentCollectType()))
            .fontSize(24)
            .fontColor(['#FFFFFF'])
        }
        .width(TOP_FLOAT_BUTTON)
        .height(TOP_FLOAT_BUTTON)
        .borderRadius(TOP_FLOAT_BUTTON / 2)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(HUD_GLASS_CHIP)
        .border({ width: 1, color: HUD_GLASS_BORDER })
      }
      .width(48)
      .height(48)
      .justifyContent(FlexAlign.Center)
      // 菜单挂在按钮上：**不要再挂 onClick**（两者同时存在会互相干扰，菜单弹不出来）
      .bindMenu(this.collectMenu(), {
        placement: Placement.BottomRight
      })
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(24)
            .fontColor(['#FFFFFF'])
        }
        .width(TOP_FLOAT_BUTTON)
        .height(TOP_FLOAT_BUTTON)
        .borderRadius(TOP_FLOAT_BUTTON / 2)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(HUD_GLASS_CHIP)
        .border({ width: 1, color: HUD_GLASS_BORDER })
      }
      .width(48)
      .height(48)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        Logger.info('AutumnPlayer', '点击 更多');
        // 菜单开着时不许自动收起控制层（`scheduleHide` 也会读 anyMenuOpen 再兜一次）
        this.clearHideTimer();
        this.moreMenuOpen = true;
      })
      // 原生菜单：挂在内置容器（Row）上、且不写空 onClick，是本工程实测可用的组合
      .bindMenu(this.moreMenuOpen, this.moreMenu, {
        placement: Placement.BottomRight,
        onDisappear: () => {
          this.moreMenuOpen = false;
          this.scheduleHide();
        }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 与底栏共用同一条水平基准线（CONTROL_EDGE_INSET + 全屏安全区）：
    // 之前顶栏贴边 0、底栏内缩 20，全屏时两组按钮明显不在一条线上。
    .padding({ left: this.controlInsetLeft(), right: this.controlInsetRight() })
    .position({ x: 0, y: 0 })
    // 三层滑入动画里的顶栏：从上方滑入 / 收回，300ms easeInOut（§39.3）
    .transition(TransitionEffect.OPACITY.animation({
      duration: MotionRuntime.ms(PANEL_ANIM_MS),
      curve: AppCurves.easeInOut()
    }).combine(TransitionEffect.translate({ y: '-100%' }).animation({
      duration: MotionRuntime.ms(PANEL_ANIM_MS),
      curve: AppCurves.easeInOut()
    })))
  }

  // ---------- 底部控制条（§39.6） ----------

  @Builder
  bottomBar() {
    Column() {
      Column() {
      /**
       * 时间码 + 进度条：**当前时间在左、总时长在右，进度条夹在中间**
       * （用户 2026-09-18：「进度条参考 `播放页美化/` 的图」）。
       *
       * 参照实现是把 `Text("当前 / 总长", 12)` 单独放在进度条上一行；
       * 用户给的参考图两侧分列，因此这里合成一行——行高仍然取
       * `TIME_ROW_HEIGHT + SLIDER_ROW_HEIGHT`，`BOTTOM_BAR_HEIGHT` 不变，
       * 底栏顶边（`y = 视频区高 − bottomBarHeight()`）与全屏排版都不受影响。
       */
      Row() {
        Text(VideoPage.formatTime(this.positionMs))
          .fontSize(12)
          .fontColor('#FFFFFF')
          .maxLines(1)
        Slider({
          value: this.durationMs > 0 ? this.positionMs : 0,
          min: 0,
          max: this.durationMs > 0 ? this.durationMs : 1,
          step: 100
        })
          .layoutWeight(1)
          .margin({ left: 10, right: 10 })
          // 已播段走**主题色**（用户 2026-09-18：「进度条的颜色可以接主题色嘛」）。
          // 用 `playerAccent` 而不是 `primary`：后者在浅色主题下是深琥珀，
          // 压在底栏黑遮罩上几乎看不出颜色；前者是主色按主题提亮一档。
          .selectedColor(AppColor.playerAccent)
          .trackColor(HUD_TRACK_IDLE)
          .blockColor('#FFFFFF')
          .trackThickness(4)
          // 滑块 16vp：参考图实测滑块直径 ≈47px ≈ 16vp（官方进度条很细）
          .blockSize({ width: 16, height: 16 })
          // 关掉 ArkUI Slider 自带的数值气泡：它按**原始毫秒**显示
          // （真机实测冒出一串 `6173.122070`），参照实现没有这个东西。
          .showTips(false)
          // 压到 20vp（源码 16vp）——Slider 默认 40vp 是底栏过高的主因
          .height(SLIDER_ROW_HEIGHT)
          .onAreaChange((oldValue: Area, newValue: Area) => {
            // 记录进度条在视频区坐标系里的位置：拖动进度要按它把 x 映射成时间
            this.sliderLeft = Number(newValue.position.x);
            this.sliderWidth = Number(newValue.width);
            this.sliderTopY = Number(newValue.position.y);
          })
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin) {
              this.sliderDragging = true;
              this.clearHideTimer();
            } else if (mode === SliderChangeMode.Moving) {
              this.hudSeekForward = value >= this.hudSeekMs;
              this.hudSeekMs = value;
              this.showSeekHud = true;
            } else {
              this.sliderDragging = false;
              this.seekTo(value);
              this.showSeekHud = false;
              this.scheduleHide();
            }
          })
        Text(VideoPage.formatTime(this.durationMs))
          .fontSize(12)
          .fontColor('#B3FFFFFF')
          .maxLines(1)
      }
      .width('100%')
      .height(TIME_ROW_HEIGHT + SLIDER_ROW_HEIGHT)
      .alignItems(VerticalAlign.Center)

      // 控制行（对齐参照实现 `bottomControlWidget` 里那一行 IconButton/TextButton，
      // 水平内边距 10）：
      //   播放/暂停 40×40（图标 25）
      //   [仅全屏] 下一集
      //   弹幕开关（图标按钮，24）
      //   超分辨率 / 倍速（**纯文字按钮**，无胶囊底色，高 40）
      //   视频比例（图标按钮）
      //   [仅全屏] 选集面板
      //   全屏 / 退出全屏
      Row() {
        // 播放 / 暂停：300ms 形变（§38.3 的 `play_pause_icon.dart`），
        // ArkUI 没有字形插值，由 `PlayPauseIcon` 用 Canvas 复刻。
        Row() {
          PlayPauseIcon({ playing: this.playing, sizeVp: 25, colorHex: '#FFFFFF' })
        }
        .width(CONTROL_ROW_HEIGHT)
        .height(CONTROL_ROW_HEIGHT)
        .justifyContent(FlexAlign.Center)
          .onClick(() => {
            Logger.info('AutumnPlayer', '点击 播放/暂停');
            this.togglePlay();
          })
        // 下一集：源码里只有「全屏 / 平板 / 桌面」才出现（手机竖屏没有）
        if (this.fullscreen) {
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_forward'))
              .fontSize(24)
              .fontColor(['#FFFFFF'])
          }
          .width(CONTROL_ROW_HEIGHT)
          .height(CONTROL_ROW_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            const count: number = this.roads.length > this.currentRoad
              ? this.roads[this.currentRoad].data.length : 0;
            if (this.currentEpisode < count) {
              this.changeEpisode(this.currentEpisode + 1, this.currentRoad);
            }
          })
        }

        Blank()

        // 弹幕开关（图标按钮；§46.4：`subtitles_rounded` → `text_bubble_left_2`）
        Row() {
          SymbolGlyph($r('sys.symbol.text_bubble_left_2'))
            .fontSize(24)
            .fontColor([this.danmakuOn ? '#FFFFFF' : '#99FFFFFF'])
        }
        .width(CONTROL_ROW_HEIGHT)
        .height(CONTROL_ROW_HEIGHT)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          Logger.info('AutumnPlayer', '点击 弹幕开关');
          this.toggleDanmaku();
        })
        // 弹幕设置（§39.8）：源码 `player_item_panel.dart` 的底栏在**弹幕开启时**
        // 才多出这个按钮（`if (playerController.danmaku.danmakuOn) ...`），
        // 图标是 `assets/images/danmaku_setting.svg`（弹幕气泡 + 齿轮）。
        // ArkUI 里没有同款字形，取最接近的系统符号 `message_badge_gearshape`。
        // 弹幕关闭时按源码隐藏——那时入口在「我的 → 弹幕设置」。
        if (this.danmakuOn) {
          Row() {
            SymbolGlyph($r('sys.symbol.message_badge_gearshape'))
              .fontSize(24)
              .fontColor(['#FFFFFF'])
          }
          .width(CONTROL_ROW_HEIGHT)
          .height(CONTROL_ROW_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            Logger.info('AutumnPlayer', '点击 弹幕设置');
            this.showDanmakuSheet = true;
            this.clearHideTimer();
          })
        }
        // 弹幕输入框（源码 `danmakuTextField`）：只在**空间够**的时候出现。
        // 源码在手机竖屏也把它塞进这一行，但那一行本来就被按钮占满，
        // `Expanded` 会被挤成 0 宽（Flutter 此时会直接报 overflow）——
        // 这里按源码桌面端那句 `isSpaceEnough`（宽 > 600）的判据处理：
        // 竖屏隐藏、全屏/平板/桌面显示。
        if (this.danmakuOn && this.captureWidth() > 600) {
          TextInput({
            text: this.danmakuInputText,
            placeholder: '发个友善的弹幕见证当下'
          })
            .fontSize(13)
            .fontColor(Color.White)
            .placeholderColor('#99FFFFFF')
            .backgroundColor('#61FFFFFF')
            .borderRadius(20)
            .height(33)
            .padding({ left: 12, right: 12 })
            .layoutWeight(1)
            .margin({ left: 8 })
            .onChange((value: string) => {
              this.danmakuInputText = value;
              // 正在输入时控制层不许自动收起（源码 `_holdDanmakuTextFieldPanel`）
              this.clearHideTimer();
            })
            .onSubmit(() => {
              this.submitDanmaku();
            })
          Row() {
            Text('发送')
              .fontSize(13)
              .fontColor(AppColor.onPrimaryContainer)
          }
          .height(33)
          .padding({ left: 14, right: 14 })
          .borderRadius(20)
          .backgroundColor(AppColor.primaryContainer)
          .margin({ left: 6 })
          .onClick(() => {
            this.submitDanmaku();
          })
        }
        // 超分辨率（TextButton：纯文字、高 48、无底色）
        Row() {
          Text(this.superResolution <= 1
            ? '超分辨率' : `超分·${SUPER_RESOLUTION_LABELS[this.superResolution - 1]}`)
            .fontSize(14)
            .fontColor(this.superResolution > 1 ? AppColor.primary : '#FFFFFF')
        }
        .height(CONTROL_ROW_HEIGHT)
        // 文字按钮左右各 8（源码 TextButton 是 8）；多出的弹幕设置按钮要占位，
        // 竖屏这一行本来就只够 361vp，12 会把它挤爆。
        .padding({ left: 8, right: 8 })
        .onClick(() => {
          Logger.info('AutumnPlayer', '点击 超分辨率');
          this.clearHideTimer();
          this.srMenuOpen = true;
        })
        .bindMenu(this.srMenuOpen, this.srMenu, {
          placement: Placement.Top,
          onDisappear: () => {
            this.srMenuOpen = false;
            this.scheduleHide();
          }
        })
        // 倍速（同样 TextButton）
        Row() {
          Text(this.speed === 1.0 ? '倍速' : `${VideoPage.trimSpeed(this.speed)}x`)
            .fontSize(14)
            .fontColor('#FFFFFF')
        }
        .height(CONTROL_ROW_HEIGHT)
        .padding({ left: 8, right: 8 })
        .onClick(() => {
          Logger.info('AutumnPlayer', '点击 倍速');
          this.clearHideTimer();
          this.speedMenuOpen = true;
        })
        .bindMenu(this.speedMenuOpen, this.speedMenu, {
          placement: Placement.Top,
          onDisappear: () => {
            this.speedMenuOpen = false;
            this.scheduleHide();
          }
        })
        // 视频比例
        Row() {
          SymbolGlyph($r('sys.symbol.aspect_ratio'))
            .fontSize(24)
            .fontColor(['#FFFFFF'])
        }
        .width(CONTROL_ROW_HEIGHT)
        .height(CONTROL_ROW_HEIGHT)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          Logger.info('AutumnPlayer', '点击 视频比例');
          this.clearHideTimer();
          this.aspectMenuOpen = true;
        })
        .bindMenu(this.aspectMenuOpen, this.aspectMenu, {
          placement: Placement.Top,
          onDisappear: () => {
            this.aspectMenuOpen = false;
            this.scheduleHide();
          }
        })
        /**
         * 选集面板按钮：源码里是「全屏 / 平板 / 桌面」才有。
         * 这里用 `videoFillsWindow()`——全屏、以及**平板横屏（未点全屏）**
         * 都在这个分支里，两种形态下目录都是一块右侧竖栏。
         */
        if (this.videoFillsWindow()) {
          Row() {
            SymbolGlyph($r('sys.symbol.list_bullet'))
              .fontSize(24)
              .fontColor(['#FFFFFF'])
          }
          .width(CONTROL_ROW_HEIGHT)
          .height(CONTROL_ROW_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.showPanelInFullscreen = !this.showPanelInFullscreen;
            /**
             * **打开全屏目录时定位到当前集**（用户 2026-09-22）。
             *
             * 竖屏目录是常驻的，`revealCurrentEpisode()` 在起播时已经跑过一次；
             * 但全屏目录是**按需插入**的：插入之前那些行还没布局，滚动无从谈起，
             * 所以每次打开都得再定位一次，否则长番打开目录永远停在第一集。
             * 面板本身有 120ms 的淡入，这里复用 `revealCurrentEpisode()` 自带的
             * 60ms 延迟（等列表完成首次布局）。
             */
            if (this.showPanelInFullscreen) {
              this.revealCurrentEpisode();
            }
          })
        }
        // §46.4：`fullscreen_exit_rounded` → `exit_full_screen`、
        // `fullscreen_rounded` → `fullscreen`
        Row() {
          SymbolGlyph($r(this.fullscreen
            ? 'sys.symbol.exit_full_screen'
            : 'sys.symbol.fullscreen'))
            .fontSize(24)
            .fontColor(['#FFFFFF'])
        }
        .width(CONTROL_ROW_HEIGHT)
        .height(CONTROL_ROW_HEIGHT)
        .justifyContent(FlexAlign.Center)
          .onClick(() => {
            Logger.info('AutumnPlayer', '点击 全屏');
            this.toggleFullscreen();
          })
      }
      .width('100%')
      .height(CONTROL_ROW_HEIGHT)
      .alignItems(VerticalAlign.Center)
      }
      /**
       * 内层：**不写高度**，按内容自适应（合并行 22 + 控制行 40）。
       *
       * 以前这里写的是 `.height(this.bottomBarHeight())` + `.position(y = 视频区高 − 估算高)`：
       * 一旦实际内容比估算高一点，多出来的部分就落到视频区底边之外被裁掉——
       * 真机竖屏就是这个现象（用户 2026-09-18：「现在竖屏的下栏不大对」：
       * 播放键、超分辨率、倍速、全屏几个按钮的下半截全没了，
       * 实测视频区底边在 y=714px，控制行内容一直到 766px）。
       * 改成由外层铺满容器 + `justifyContent(End)` 贴底，高度就不再依赖估算。
       */
      .width('100%')
      .padding({
        left: this.controlInsetLeft(),
        right: this.controlInsetRight(),
        bottom: this.fullscreen ? this.fullscreenBarBottom() : 0
      })
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .hitTestBehavior(HitTestMode.Transparent)
    // 底栏从下方滑入 / 收回，300ms easeInOut（§39.3）
    .transition(TransitionEffect.OPACITY.animation({
      duration: MotionRuntime.ms(PANEL_ANIM_MS),
      curve: AppCurves.easeInOut()
    }).combine(TransitionEffect.translate({ y: '100%' }).animation({
      duration: MotionRuntime.ms(PANEL_ANIM_MS),
      curve: AppCurves.easeInOut()
    })))
  }

  // ---------- HUD（§15.11 / §30.1） ----------

  /**
   * 亮度 / 音量 HUD 当前展示的是哪一档。
   *
   * 参照实现的 `_displayType` **只在可见时更新**——手势结束后 HUD 还要
   * 淡出 200ms，这期间不能因为 `showVolume/showBrightness` 归零就切回另一档。
   */
  @State private hudAdjustKind: string = 'brightness';

  /** 亮度 / 音量 HUD 的进度（0–1）。 */
  private hudAdjustProgress(): number {
    const value: number = this.hudAdjustKind === 'volume'
      ? this.volume / 100 : this.panelBrightness;
    return Math.max(0, Math.min(1, value));
  }

  /** 亮度 / 音量 HUD 的图标（按 §46.4 的映射表取，三档亮度是同一个符号）。 */
  private hudAdjustIcon(): Resource {
    if (this.hudAdjustKind === 'volume') {
      const percent: number = Math.round(this.hudAdjustProgress() * 100);
      if (percent <= 0) {
        return $r('sys.symbol.speaker_slash');
      }
      if (percent < 45) {
        return $r('sys.symbol.speaker_minus');
      }
      return $r('sys.symbol.speaker_wave_2');
    }
    return $r('sys.symbol.brightness');
  }

  /** 滑块中心 x（对应 `_HudSliderTrackShape` 的 `thumbX`）。 */
  private hudThumbX(progress: number): number {
    const p: number = Math.max(0, Math.min(1, progress));
    const x: number = HUD_TRACK_EDGE + p * (HUD_TRACK_WIDTH - HUD_TRACK_EDGE * 2);
    return Math.max(0, Math.min(HUD_TRACK_WIDTH, x));
  }

  /** 滑块两侧的缺口一半（靠近两端时会被压缩，与源码一致）。 */
  private hudHalfGap(progress: number): number {
    const x: number = this.hudThumbX(progress);
    return Math.max(0,
      Math.min(HUD_THUMB_HALF_GAP, x, HUD_TRACK_WIDTH - x));
  }

  /** 已填充段宽度。 */
  private hudLeftWidth(progress: number): number {
    return Math.max(0, this.hudThumbX(progress) - this.hudHalfGap(progress));
  }

  /** 未填充段起点。 */
  private hudRightX(progress: number): number {
    return Math.min(HUD_TRACK_WIDTH,
      this.hudThumbX(progress) + this.hudHalfGap(progress));
  }

  /** 未填充段宽度。 */
  private hudRightWidth(progress: number): number {
    return Math.max(0, HUD_TRACK_WIDTH - this.hudRightX(progress));
  }

  /**
   * HUD 滑杆轨道（`_HudSliderTrackShape` + `_HudSliderThumbShape` 的等价实现）。
   *
   * 自绘的内容「一个两端圆角 12 的 32 高轨道，在滑块处断开 12 的缺口，
   * 滑块是 4×40 圆角 2 的竖条」用三个带各自圆角的方块拼出来，
   * 避免整段自绘；数值变化 **180ms `easeOutCubic`**（§15.11 的「数值变化」档）。
   *
   * ⚠️ **不要给它加参数**：ArkUI 的 `@Builder` 带**值参数**时不会随组件状态刷新
   * （本项目第 5 类坑，之前也踩过）。这里所有值都在 Builder 内部从 `this.*` 读，
   * 否则真机上会出现「亮度确实在变、HUD 的条纹丝不动」。
   */
  @Builder
  hudTrack() {
    Stack() {
      // 整条轨道：4vp 细线（参考图实测粗细），未填充段白 30%
      Row()
        .width(HUD_TRACK_WIDTH)
        .height(HUD_LINE_HEIGHT)
        .borderRadius(HUD_LINE_HEIGHT / 2)
        .backgroundColor(HUD_TRACK_IDLE)
        .position({ x: 0, y: (HUD_TRACK_HEIGHT - HUD_LINE_HEIGHT) / 2 })
      // 已填充段：白色（参考图里亮度/音量那条线是白的）
      Row()
        .width(this.hudThumbX(this.hudAdjustProgress()))
        .height(HUD_LINE_HEIGHT)
        .borderRadius(HUD_LINE_HEIGHT / 2)
        // 音量条走**主题色**（用户 2026-09-18：「音量条的颜色可以接主题色嘛」），
        // 亮度条保持白色（参考图里就是白的）
        .backgroundColor(this.hudAdjustKind === 'volume'
          ? AppColor.playerAccent : '#FFFFFF')
        .position({ x: 0, y: (HUD_TRACK_HEIGHT - HUD_LINE_HEIGHT) / 2 })
    }
    .width(HUD_TRACK_WIDTH)
    .height(HUD_TRACK_HEIGHT)
    .animation({
      duration: MotionRuntime.ms(Motion.quick),
      curve: AppCurves.easeOutCubic()
    })
  }

  /** 亮度 / 音量 HUD（§30.1：宽 200、图标胶囊 32×32、竖向进度条宽 4 高 40）。 */
  @Builder
  adjustmentHud() {
    Row() {
      /**
       * 图标：**白色、无胶囊底**（参考图里就是一颗白色太阳/喇叭挂在最左边，
       * 没有参照实现那层 32×32 的色块）。
       */
      SymbolGlyph(this.hudAdjustIcon())
        .fontSize(20)
        .fontColor([this.hudAdjustKind === 'volume'
          ? AppColor.playerAccent : '#FFFFFF'])
        // 图标切换：进 `easeOutBack` / 出 `easeInCubic`（§30.1）
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.OPACITY.animation({
            duration: MotionRuntime.ms(HUD_ANIM_MS),
            curve: AppCurves.easeOutBack()
          }).combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }).animation({
            duration: MotionRuntime.ms(HUD_ANIM_MS),
            curve: AppCurves.easeOutBack()
          })),
          TransitionEffect.OPACITY.animation({
            duration: MotionRuntime.ms(HUD_ANIM_MS),
            curve: AppCurves.easeInCubic()
          })
        ))
        .width(20)
        .height(20)

      Blank().width(8)

      this.hudTrack()
    }
    .width(HUD_ADJUST_WIDTH)
    .height(HUD_TRACK_HEIGHT)
    .padding({ left: 8, right: 8 })
    .borderRadius(HUD_TRACK_HEIGHT / 2)
    // 深色玻璃底：与参考图一致（半透明黑 + 白描边），不再跟随浅色主题的 surface
    .backgroundColor(HUD_GLASS_BG)
    .border({
      width: 1,
      color: HUD_GLASS_BORDER
    })
    .scale({
      x: (this.showBrightnessHud || this.showVolumeHud) ? 1 : 0.92,
      y: (this.showBrightnessHud || this.showVolumeHud) ? 1 : 0.92
    })
    // 缩放用的是 `easeOutBack`（保留过冲），淡入用 `easeOutCubic`（§15.11）
    .animation({
      duration: MotionRuntime.ms(HUD_ANIM_MS),
      curve: AppCurves.easeOutBack()
    })
    .opacity((this.showBrightnessHud || this.showVolumeHud) ? 1 : 0)
    .translate({
      y: (this.showBrightnessHud || this.showVolumeHud) ? 0 : '-18%'
    })
    .animation({
      duration: MotionRuntime.ms(HUD_ANIM_MS),
      curve: AppCurves.easeOutCubic()
    })
  }

  /** 进度 HUD（§30.1：宽 248、图标 36×36、图标与文字间距 10）。 */
  @Builder
  seekHud() {
    Stack() {
      // 进度底衬：暖橙 20% 从左铺到当前进度（`_SeekProgressBackground` 的等价物）。
      // 深色玻璃上不再用 secondaryContainer —— 那是跟随主题的实色，
      // 浅色主题下会在黑底上糊出一块浅色，与参考图（黑底 + 细线）不符。
      Row()
        .width(`${Math.max(0, Math.min(1, this.hudSeekProgress())) * 100}%`)
        .height('100%')
        .backgroundColor(AppColor.withAlpha(AppColor.playerAccent, 0.2))
        .position({ x: 0, y: 0 })
        .animation({
          duration: MotionRuntime.ms(Motion.quick),
          curve: AppCurves.easeOutCubic()
        })

      Row() {
        Stack() {
          SymbolGlyph($r(this.hudSeekForward
            ? 'sys.symbol.fast_forward' : 'sys.symbol.fast_mirroring'))
            .fontSize(22)
            .fontColor(['#FFFFFF'])
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.animation({
                duration: MotionRuntime.ms(HUD_ANIM_MS),
                curve: AppCurves.easeOutBack()
              }).combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }).animation({
                duration: MotionRuntime.ms(HUD_ANIM_MS),
                curve: AppCurves.easeOutBack()
              })),
              TransitionEffect.OPACITY.animation({
                duration: MotionRuntime.ms(HUD_ANIM_MS),
                curve: AppCurves.easeInCubic()
              })
            ))
        }
        .width(36)
        .height(36)
        .borderRadius(20)
        .clip(true)
        .backgroundColor(HUD_GLASS_CHIP)

        Blank().width(10)

        Column() {
          Text(this.hudSeekOffsetText())
            .fontSize(14)
            .lineHeight(20)
            .fontWeight(600)
            .fontColor('#FFFFFF')
            .maxLines(1)
          Text(`${VideoPage.formatTime(this.hudSeekMs)} / ${VideoPage.formatTime(this.durationMs)}`)
            .fontSize(12)
            .lineHeight(17)
            .fontColor('#B3FFFFFF')
            .maxLines(1)
            .margin({ top: 1 })
          /**
           * 细进度线（参考图 `播放页美化/c88619…`：时间下方一条极简细线，
           * 已播段暖橙、剩余段浅白）。宽 100%、高 3，两段各占比例宽度。
           */
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(HUD_LINE_HEIGHT)
              .borderRadius(HUD_LINE_HEIGHT / 2)
              .backgroundColor(HUD_TRACK_IDLE)
            Row()
              .width(`${Math.max(0, Math.min(1, this.hudSeekProgress())) * 100}%`)
              .height(HUD_LINE_HEIGHT)
              .borderRadius(HUD_LINE_HEIGHT / 2)
              // 已播段同样是主题色（进度条一族颜色统一接主题）
              .backgroundColor(AppColor.playerAccent)
          }
          .width('100%')
          .height(HUD_LINE_HEIGHT)
          .margin({ top: 6 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    }
    .width(HUD_SEEK_WIDTH)
    /**
     * **必须给固定高度**：这个 HUD 挂在 `height('100%')` 的 HUD 列里，
     * 不写高度时 `Stack` 会被拉满剩余高度，屏幕上就是一块**竖长条黑色浮层**
     * （用户 2026-09-18：「调整进度条时，中间那个东西太高了太大了」）。
     * 内容 = 图标 36 + 上下内距 16，即 52；取 52。
     */
    .height(HUD_SEEK_HEIGHT)
    .borderRadius(30)
    .clip(true)
    .backgroundColor(HUD_GLASS_BG)
    .border({
      width: 1,
      color: HUD_GLASS_BORDER
    })
    .scale({ x: this.showSeekHud ? 1 : 0.92, y: this.showSeekHud ? 1 : 0.92 })
    .animation({
      duration: MotionRuntime.ms(HUD_ANIM_MS),
      curve: AppCurves.easeOutBack()
    })
    .opacity(this.showSeekHud ? 1 : 0)
    .translate({ y: this.showSeekHud ? 0 : '-18%' })
    .animation({
      duration: MotionRuntime.ms(HUD_ANIM_MS),
      curve: AppCurves.easeOutCubic()
    })
  }

  /** 进度 HUD 的进度（0–1）。 */
  private hudSeekProgress(): number {
    if (this.durationMs <= 0) {
      return 0;
    }
    return this.hudSeekMs / this.durationMs;
  }

  /** 进度 HUD 第一行：`+mm:ss` / `-mm:ss`。 */
  private hudSeekOffsetText(): string {
    const offset: number = Math.abs(this.hudSeekMs - this.positionMs);
    return `${this.hudSeekForward ? '+' : '-'}${VideoPage.formatTime(offset)}`;
  }

  /**
   * 倍速 HUD（`PlayerSpeedHud`：宽 94、图标胶囊 22、圆角 18，进出 **160ms**）。
   *
   * 图标：参照实现用的是 `AppIcons.speed_rounded`，而它在本工程里是
   * **未映射的 Material 回退**（`app_icons.dart:197` 是 `Icons.speed_rounded`），
   * 鸿蒙符号库里没有 speedometer，取最接近的仪表盘符号
   * `gauge_with_dots_needle_33percent`（同「最近搜索」那条偏差的处理方式）。
   */
  @Builder
  speedHud() {
    Row() {
      Stack() {
        SymbolGlyph($r('sys.symbol.gauge_with_dots_needle_33percent'))
          .fontSize(15)
          .fontColor([AppColor.onInverseSurface])
      }
      .width(22)
      .height(22)
      .borderRadius(12)
      .clip(true)
      .backgroundColor(AppColor.inverseSurface)

      Blank().width(6)

      Text(`${VideoPage.trimSpeed(this.speed)}x`)
        .fontSize(12)
        .lineHeight(17)
        .fontWeight(700)
        // 倍速 HUD 的底始终是深色玻璃；浅色主题下 onSurface 是深色，2.0x 会看不清。
        .fontColor('#FFFFFF')
        .maxLines(1)
        .layoutWeight(1)
    }
    .width(HUD_SPEED_WIDTH)
    // 同进度 HUD：不写高度会被 HUD 列拉成竖长条，这里钉死 36（图标胶囊 22 + 内距）
    .height(36)
    .padding({ left: 8, right: 8 })
    .borderRadius(18)
    // 深色玻璃，与音量/亮度/进度 HUD 同一套
    .backgroundColor(HUD_GLASS_BG)
    .border({
      width: 1,
      color: AppColor.withAlpha(AppColor.outlineVariant, 0.22)
    })
    .scale({ x: this.showSpeedHud ? 1 : 0.96, y: this.showSpeedHud ? 1 : 0.96 })
    .opacity(this.showSpeedHud ? 1 : 0)
    .translate({ y: this.showSpeedHud ? 0 : '-12%' })
    .animation({
      duration: MotionRuntime.ms(Motion.muteStep),
      curve: AppCurves.easeOutCubic()
    })
  }

  @Builder
  hud() {
    Column({ space: 8 }) {
      // 三套 HUD 彼此独立，各自带进出动画（参照实现也是三个并列组件）
      if (this.showSeekHud) {
        this.seekHud()
      }
      if (this.showSpeedHud) {
        this.speedHud()
      }
      if (this.showBrightnessHud || this.showVolumeHud) {
        this.adjustmentHud()
      }
    }
    .alignItems(HorizontalAlign.Center)
  }

  // ---------- 剧集面板（§37.3） ----------

  @Builder
  episodePanel() {
    Column() {
      /**
       * 面板头部（2026-09-18 美化）：
       *   行 1（≥52）：剧名 + 线路胶囊；
       *   行 2（22）：第 N 集 / 共 M 集 · 上次看到 mm:ss。
       *
       * 行 2 是这次美化里信息量最大的一处——目录原先只说得出「有哪些集」，
       * 说不出「我看到哪了」，长番用户得靠翻历史页才知道。
       */
      Row({ space: 8 }) {
        /**
         * 剧名同样过一遍**繁 → 简**（2026-09-19 用户：「希望视频页的目录里的
         * 繁体能转化成简体」）。集名那一侧在 `episodeLabel()` 里转，两处合起来
         * 目录里就不会再出现「一半繁体、一半简体」。转的是显示层的拷贝，
         * `this.sourceTitle` / `this.item` 本身不动。
         */
        Text(toSimplifiedChinese(this.sourceTitle.length > 0
          ? this.sourceTitle : this.item.displayName()))
          // 列表一滚动就收一档：头部让出高度给剧集（17 → 15）
          .fontSize(this.episodeListScrolled ? 15 : EPISODE_TITLE_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.onSurface)
          /**
           * **给两行**（原来写死 1 行）：
           * 全屏时面板只有屏宽的三分之一（最窄 266vp），长剧名一行放不下，
           * 原本就只剩一截省略号（用户 2026-09-18：「全屏打开目录，有的标题
           * 是两行的，但显示不全」）。这里允许折到两行，配合下面
           * `constraintSize({ minHeight })` 让行高跟着长。
           */
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Row({ space: 4 }) {
          Text(this.roadName(this.visibleRoad))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.roadMenuOpen
              ? AppColor.onSecondaryContainer : AppColor.onSurfaceVariant)
            // 线路名也限一行：窄面板里它会折行，而被胶囊的 32 高裁成半截字
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(16)
            .fontColor([this.roadMenuOpen
              ? AppColor.onSecondaryContainer : AppColor.onSurfaceVariant])
        }
        /**
         * 线路胶囊按 M3 **Assist chip** 规格：高 32、圆角 16、
         * 描边 + `surfaceContainerHighest` 底，展开时切 `secondaryContainer`。
         *
         * 原来是 `surfaceContainerHigh` 底 + `primary` 字，和列表选中行的
         * 主色底是两套「胶囊语言」；改成中性色之后，主色只出现在
         * 「当前集」上，层级不再互相抢。
         */
        .height(32)
        .padding({ left: 12, right: 12 })
        .borderRadius(16)
        .backgroundColor(this.roadMenuOpen
          ? AppColor.secondaryContainer : AppColor.surfaceContainerHighest)
        .border({ width: 1, color: AppColor.outlineVariant })
        .onClick(() => {
          this.clearHideTimer();
          this.roadMenuOpen = true;
        })
        .bindMenu(this.roadMenuOpen, this.roadMenu, {
          placement: Placement.BottomLeft,
          onDisappear: () => {
            this.roadMenuOpen = false;
            this.scheduleHide();
          }
        })
      }
      .width('100%')
      // 行高跟着内容长：一行时 52，两行标题时自动更高（不写死 height，
      // 否则两行标题会被裁掉下半截）
      // 滚动后收到 42（与标题 15 配套）
      .constraintSize({
        minHeight: this.episodeListScrolled ? 42 : EPISODE_HEADER_HEIGHT
      })
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .alignItems(VerticalAlign.Center)
      // 高度变化走同一条曲线，滚动时是「收」而不是「跳」
      .animation({
        duration: MotionRuntime.ms(Motion.quick),
        curve: AppCurves.easeOutCubic()
      })

      // 用 Row 包一层是为了**垂直居中**：Text 自己没有垂直对齐属性，
      // 固定高度下容易贴着上边（11sp 的文字在 22vp 的盒子里偏上很明显）
      Row() {
        Text(this.watchedLabel.length > 0
          ? `第 ${this.currentEpisode} 集 / 共 ${this.episodeCount()} 集` +
            ` · 上次看到 ${this.watchedLabel}`
          : `第 ${this.currentEpisode} 集 / 共 ${this.episodeCount()} 集`)
          .fontSize(11)
          .fontColor(AppColor.onSurfaceVariant)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        /**
         * 倒序入口常驻在信息行里，不随目录滚动收起。
         * 长番往往一打开就需要切换顺序，如果按钮跟状态文字一起淡出，
         * 用户还得先把列表滚回顶部才能找到它。
         */
        if (this.episodeCount() > 1) {
          Button(this.episodeReversed ? '正序' : '倒序')
            .height(28)
            .padding({ left: 10, right: 10 })
            .borderRadius(14)
            .fontSize(11)
            .fontColor(this.episodeReversed
              ? AppColor.onPrimaryContainer : AppColor.onSurfaceVariant)
            .backgroundColor(this.episodeReversed
              ? AppColor.primaryContainer : AppColor.surfaceContainerHighest)
            .margin({ left: 8 })
            .onClick(() => {
              this.toggleEpisodeOrder();
            })
        }
        /**
         * ⚠️ **原来这里有一行「集标题 x/y · ↻」的状态指示，已按用户要求去掉**
         * （2026-09-20 晚：「把目录页上的显示的集标题取消掉」「是指取消掉
         * 集标题 28/39 这个指示项」）。
         *
         * 它的来历：集标题来自 Bangumi + 哔哩哔哩两条链路，失败时目录里只是
         * 「第N集」，界面上看不出是**上游没有**还是**链路没跑成**，所以摊开
         * 覆盖数并给一个原地重试入口（`EpisodeTitleService.forget` 清那次缓存）。
         * 实际用下来这个「28/39」更像一条报错信息，常驻在目录标题下面碍眼，
         * 用户选择不要它。
         *
         * 诊断能力没丢：`episodeTitleStatus()` / `retryEpisodeTitles()` 都还在，
         * 每次解析的明细也照旧写 hilog（`[集标题] 明细：…`）。
         * 哪天要恢复，把这段注释换回一个 `if (this.episodeTitleStatus().length > 0)`
         * 的 `Row`（Text + `arrow_2_circlepath`，点击 `retryEpisodeTitles()`）即可。
         */
      }
      .width('100%')
      // 信息行保留倒序入口，目录滚动后也不收起。
      .height(EPISODE_INFO_HEIGHT)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      // 分段条：剧集超过一组（100 集）才出现（§37.3）
      if (this.segmentCount() > 1) {
        List({ space: 8, scroller: this.segmentScroller }) {
          ForEach(this.segments(), (group: number) => {
            ListItem() {
              Text(VideoPage.segmentLabel(group, this.episodeCount()))
                .fontSize(14)
                .fontWeight(group === this.segmentGroup ? FontWeight.Bold : FontWeight.Medium)
                .fontColor(group === this.segmentGroup
                  ? AppColor.onPrimaryContainer : AppColor.onSurface)
                .padding({ left: 16, right: 16 })
            }
            .height(40)
            .borderRadius(20)
            .backgroundColor(group === this.segmentGroup
              ? AppColor.primaryContainer : AppColor.surfaceContainer)
            // 记录几何，供 260ms 分段滚入视野用（见 revealSegment）
            .onAreaChange((oldValue: Area, newValue: Area) => {
              this.segmentX[group] = Number(newValue.position.x);
              this.segmentWidth[group] = Number(newValue.width);
            })
            .onClick(() => {
              this.segmentGroup = group;
              // 分段切换：剧集列表回到该段首行（§38.8 的「定位滚动」）
              this.scrollEpisodeToLocal(0, true);
            })
          }, (group: number) => `segment-${group}-${group === this.segmentGroup ? 1 : 0}`)
        }
        .listDirection(Axis.Horizontal)
        .width('100%')
        .height(58)
        .padding({ left: 16, right: 16, top: 6, bottom: 12 })
        .scrollBar(BarState.Off)
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.segmentViewport = Number(newValue.width) - 32;
        })
      }

      Stack({ alignContent: Alignment.End }) {
        List({ scroller: this.episodeScroller }) {
          ForEach(this.episodeRange(), (episode: number) => {
            ListItem() {
              this.episodeRow(episode)
            }
            // key 带上选中 / 播放态：ArkUI 只重建 key 变化的 item，
            // 不带的话切集后旧行的选中底色与播放图标不会跟着走。
          }, (episode: number) =>
            `ep-${this.visibleRoad}-${episode}-${this.isSelected(episode) ? 1 : 0}` +
              `${this.isPlayingEpisode(episode) ? 'p' : ''}` +
              /**
               * 带上当前集的进度（**实时**，2026-09-22 起）。
               *
               * ArkUI 的 ForEach **按 key 复用子树**：key 不变就不会重跑
               * itemGenerator，行内那条进度线（`panelProgressRatio`）在
               * 时长就绪后就永远画不出来——**这就是为什么实时进度必须进 key**：
               * 只改 `liveProgressRatio` 这个 @State，itemGenerator 不会重跑，
               * 宽度表达式也就永远停在建行那一刻的值。
               *
               * 取到 **0.1%**（千分之一）：原来取整到 1%，在 24 分钟的剧集上
               * 要十几秒才跳一格；0.1% 在约 300vp 长的线上是 **0.3vp** 的步进，
               * 已经在亚像素级别，看着就是连续的。节流由 `tickEpisodeProgress`
               * 的 1 秒负责，所以重建频率上限 ≈ 每秒一行（其余行恒为 0，不受影响）。
               */
              `${this.isSelected(episode)
                ? Math.round(this.episodeProgressRatio() * 1000) : 0}` +
              /**
               * ⚠️ **必须带 `episodeTitleRev`**。
               *
               * 分集标题是异步到的：`refreshEpisodeTitles()` 回来后只把
               * `episodeTitleRev` 加一。而 ArkUI 的 ForEach 对 key 没变的项
               * **不会重跑 itemGenerator**——`episodeLabel` 里那句读 rev 也就
               * 永远不会被求值。结果是：**打开目录时已经建好的那一段永远显示
               * 「第 N 集」**，只有标题到达之后才建出来的行（切段/滚动新建）
               * 才有标题（2026-09-18：柯南「后面几百集没有解析出标题」）。
               */
              `-t${this.episodeTitleRev}`)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        // 不再画满宽分割线：选中行是圆角卡片，线会从卡片圆角下穿过去，
        // 真机截图里看着就是「没闭合的框」（2026-09-18 美化）
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.episodeViewport = Number(newValue.height);
        })
        /**
         * 滚动 → 头部收缩（2026-09-18 美化）。
         *
         * 跨过 24vp 才切一次状态：`onDidScroll` 每帧都回调，无条件写 @State
         * 会让这块常驻可见的目录每帧重排（同 `showBackToTop` 的写法）。
         */
        .onDidScroll(() => {
          const off: number = this.episodeScroller.currentOffset().yOffset;
          const next: boolean = off > 24;
          if (next !== this.episodeListScrolled) {
            this.episodeListScrolled = next;
          }
        })

        /**
         * 右侧快速定位条（2026-09-18 美化，仅分段数 > 1 时出现）。
         *
         * 上面那条分段胶囊只能一屏屏点：柯南 1340 集 = 14 段，横着滑过去再点
         * 一次，跳一次要两步。这里再给一条竖向刻度，**按住往下一拉就是几十集**。
         * 刻度数与分段数一一对应，当前段用主色且更长，读起来就是「我在第几段」。
         *
         * `hitTestBehavior(Block)`：压在列表上，必须把触摸吃掉，
         * 否则拖动会同时被 List 当成滚动。
         */
        if (this.segmentCount() > 1) {
          Column() {
            ForEach(this.segments(), (group: number) => {
              Row()
                .width(group === this.segmentGroup ? 16 : 10)
                .height(3)
                .borderRadius(1.5)
                .backgroundColor(group === this.segmentGroup
                  ? AppColor.primary : AppColor.outlineVariant)
            }, (group: number) =>
              `scrub-${group}-${group === this.segmentGroup ? 1 : 0}`)
          }
          .width(EPISODE_SCRUBBER_WIDTH)
          .height('100%')
          .padding({ top: 14, bottom: 14, right: 6 })
          .alignItems(HorizontalAlign.End)
          .justifyContent(FlexAlign.SpaceBetween)
          .hitTestBehavior(HitTestMode.Block)
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.scrubberHeight = Number(newValue.height) - 28;
          })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down || event.type === TouchType.Move) {
              this.jumpByScrubber(event.touches[0].y);
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              // 松手收起气泡
              this.scrubberHint = '';
            }
          })
        }

        /**
         * 拖动定位条时的小气泡（2026-09-18 美化）。
         *
         * 只有刻度没有文字时，用户不知道「我现在拉到第几段了」——
         * 1340 集的番尤其明显。这里在定位条左侧弹一个 `1-100` 式的段标签。
         */
        if (this.scrubberHint.length > 0) {
          Row() {
            Text(this.scrubberHint)
              .fontSize(12)
              .fontColor(AppColor.onInverseSurface)
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(14)
          .backgroundColor(AppColor.inverseSurface)
          .margin({ right: EPISODE_SCRUBBER_WIDTH + 6 })
          .transition(TransitionEffect.OPACITY.animation({
            duration: MotionRuntime.ms(Motion.instant),
            curve: AppCurves.easeOutCubic()
          }))
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor(AppColor.surface)
    /**
     * 与视频区的衔接（2026-09-18 美化）：面板顶部收 20 圆角。
     *
     * 视频区是纯黑、面板是浅色 `surface`，原来两段之间是一条硬直边；
     * 顶部圆角让黑色从面板两角露出来，面板读起来就是「压在视频下方的一张卡」，
     * 而不是「页面被切成两半」。
     *
     * 全屏时**不加**：那一份由 `fullscreenPanel()` 的外层容器负责
     * （它已经有 28 的左上/左下圆角 + clip），这里再加一层会在面板内部留缺口。
     */
    .borderRadius({
      topLeft: this.fullscreen ? 0 : 20,
      topRight: this.fullscreen ? 0 : 20
    })
    .clip(!this.fullscreen)
    /**
     * 进出场（2026-09-18 美化）。
     *
     * 进全屏时这块面板是被 `if (!this.fullscreen)` 摘掉的，原来就是**硬切**；
     * 给它一条「淡出 + 轻微下移」，退出全屏时反过来淡入，观感上它是
     * 「让位」而不是「消失」。全屏切换的丝滑感有一半来自这里。
     */
    .transition(TransitionEffect.OPACITY.animation({
      duration: MotionRuntime.ms(Motion.quick),
      curve: AppCurves.easeOutCubic()
    }).combine(TransitionEffect.translate({ y: 24 }).animation({
      duration: MotionRuntime.ms(Motion.quick),
      curve: AppCurves.easeOutCubic()
    })))
  }

  /**
   * 剧集行（§37.3 的收敛版，2026-09-18 美化）。
   *
   * 原来「3px 左竖条 + 12% 主色底 + 集号圆换色 + 右侧『正在播放』文字」
   * 四重编码同时在喊「这是当前集」，左竖条还和行圆角互相打架
   * ——真机截图里看就是一个没闭合的框。现在收敛成两重：
   *   - **行底色**：选中 = 主色 10%（按压时最多 16%），行本身是 12 圆角卡片；
   *   - **集号圆**：选中 = `primaryContainer`，否则 `surfaceContainerHigh`。
   *
   * 播放态改成 `play_fill` 图标：11sp 的「正在播放」文字在窄屏 + 大字体下
   * 会把集标题挤到只剩省略号。
   */
  @Builder
  episodeRow(episode: number) {
    // 用 Stack 包一层：底部那条「上次看到」的进度线要压在行卡片上，
    // 而 Row 放不下叠层。其余样式（圆角/底色/按压缩放/手势）都留在 Stack 上。
    Stack({ alignContent: Alignment.BottomStart }) {
      Row() {
        Text(`${episode}`)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isSelected(episode)
          ? AppColor.onPrimaryContainer : AppColor.onSurfaceVariant)
        // 集号位数越多圆越宽：柯南那种四位数（1340）在 30 圆里会被挤到贴边
        .width(VideoPage.episodeChipWidth(episode))
        .height(30)
        .textAlign(TextAlign.Center)
        .borderRadius(15)
        .backgroundColor(this.isSelected(episode)
          ? AppColor.primaryContainer : AppColor.surfaceContainerHigh)
        Text(this.episodeLabel(episode))
          .fontSize(14)
          .fontWeight(this.isSelected(episode) ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(AppColor.onSurface)
          /**
           * **全屏给两行、竖屏仍是一行**（2026-09-19 用户：「在视频页全屏下，目录的
           * 弹窗显示不了两行的标题」，随后又明确「竖屏……还原回原来的尺寸，
           * 全屏……单独做，改成随行数变化的」）。
           *
           * 集名来自 Bangumi / 哔哩哔哩，长起来能到二十几个字（「葬送のフリーレン
           * ～ トークの魔法 ～ 特別版」那一类）。全屏时面板只有屏宽的三分之一
           * （最窄 266vp），扣掉集号圆与内距一行只剩十来个字，得折两行；
           * 竖屏整屏宽，一行放得下，保持原样（一行 + 行高 56）。
           *
           * 全屏这一档也对齐了参照实现（`episode_selection_panel.dart:822` 的
           * `Text(_name(index), maxLines: 2, overflow: TextOverflow.ellipsis)`）。
           */
          .maxLines(this.fullscreen ? 2 : 1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 标题是异步到的：到位后整列文字 180ms 淡入（见 `episodeTitleFade`）
          .opacity(this.episodeTitleFade)
          .layoutWeight(1)
          .margin({ left: 14 })
        if (this.isPlayingEpisode(episode)) {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(14)
            .fontColor([AppColor.primary])
            .margin({ left: 8 })
            // 图标替代了文字，无障碍语义不能跟着丢
            .accessibilityText('正在播放')
        }
      }
      .width('100%')
      /**
       * ⚠️ **这里原来写 `height('100%')`，2026-09-19 删掉**。
       *
       * 这一行是 `List` 的 item，父级（Stack / ListItem）**没有确定高度**，
       * 百分比高度会挂到「List 的视口高度」上——真机表现就是**一行长成一整屏**
       * （用户：「竖屏状态下的播放目录页尺寸……全屏状态下的播放目录弹窗……现在
       * 尺寸也很大」）。
       *
       * 现在行高 = 内容（集号圆 30 / 集名 1–2 行）+ 上下内距，见 `episodeRowPadding()`：
       * 竖屏恒 56（与原实现一致）、全屏随集名行数变化。
       */
      .padding({
        left: 10,
        right: 16,
        top: this.episodeRowPadding(),
        bottom: this.episodeRowPadding()
      })
      .alignItems(VerticalAlign.Center)

      /**
       * 当前集的进度线（2026-09-18 美化，2026-09-22 改成**实时**）。
       *
       * 只看当前集：它是用户唯一需要「接着看」的那一行。播放中读
       * `liveProgressRatio`（1 秒一拍），还没起播时退回历史快照。
       * 宽度用**两位小数**：整数百分比在 24 分钟的剧集上要十几秒才跳一格，
       * 配 900ms 线性动画就完全看不出台阶了。
       */
      if (this.isSelected(episode) && this.episodeProgressRatio() > 0) {
        Row() {
          Row()
            .width(`${(this.episodeProgressRatio() * 100).toFixed(2)}%`)
            .height(2)
            .borderRadius(1)
            .backgroundColor(AppColor.primary)
            /**
             * 宽度变化时的隐式动画。
             *
             * ⚠️ **实际生效的场景很窄**：这条线所在的 `ListItem` 是被 ForEach
             * 按 key 重建的（key 里带了进度千分比，见上面的 key 生成器），
             * 重建出来的节点带着初始宽度、没有「从旧值过渡」这一步。
             * 真正让它看着连续的是**步长足够小**（0.1% ≈ 0.3vp，亚像素）。
             * 留着这段是为了万一以后改成属性级更新（只改宽度不重建行），
             * 那时它会立刻接上 1 秒一拍的节奏平滑滑过去。
             * 「禁用动画」开关打开时给 0。
             */
            .animation({
              duration: MotionRuntime.isOff() ? 0 : LIVE_PROGRESS_ANIM_MS,
              curve: Curve.Linear
            })
        }
        .width('100%')
        .height(2)
        .padding({ left: 10, right: 16 })
        .margin({ bottom: 5 })
        .justifyContent(FlexAlign.Start)
      }
    }
    .width('100%')
    /**
     * **不再写死行高**（2026-09-19）。
     *
     * 行高完全由上面那层 Row 的**内容 + 内距**决定（竖屏恒 56、全屏随集名行数
     * 在 46 / ≈55 之间），Stack 跟着子节点长，底部那条「上次看到」的进度线仍然
     * 贴在行底。
     *
     * `EPISODE_ROW_HEIGHT` 只剩 `scrollEpisodeToLocal` 做换算用：竖屏每行都是 56，
     * 换算精确；全屏是 46 / 55 混排，定位滚动会有一点偏差（可接受）。
     */
    // 左右各留 8：行是一张卡片，不是一条通栏
    .margin({ left: 8, right: 8 })
    .borderRadius(12)
    // 按压反馈：`episode_selection_panel.dart:993-1002` 的 `SpringSimulation`
    // （mass 1 / stiffness 500 / ratio 0.8），驱动的是**底色透明度**
    // 10% → 16%（未选中行则是 onSurface 8% 的叠加层），没有缩放。
    .backgroundColor(this.isSelected(episode)
      ? withAlpha(AppColor.primary, 0.10 + this.episodePressValue(episode) * 0.06)
      : (this.pressedEpisode === episode
        ? withAlpha(AppColor.onSurface, 0.08) : '#00000000'))
    /**
     * 按压反馈再加一档「轻微缩小」。
     *
     * 只改底色在中性色的行上几乎看不出来（未选中行是 onSurface 8% 的叠加），
     * 缩小 1.2% 才有一按就回应的手感。系数取 0.012 而不是 0.02：
     * 行是通栏卡片，缩太多会在两侧露出底色缝隙。
     * 值来自 `episodePressValue`（由 `animateTo` + 弹簧驱动），不是硬编码时长。
     */
    .scale({
      x: 1 - this.episodePressValue(episode) * 0.012,
      y: 1 - this.episodePressValue(episode) * 0.012
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.setEpisodePressed(episode, true);
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.setEpisodePressed(episode, false);
      }
    })
    .onClick(() => {
      if (this.isSelected(episode)) {
        return;
      }
      this.changeEpisode(episode, this.visibleRoad);
    })
  }

  /**
   * 右侧目录竖栏（原来叫 `fullscreenPanel`）。
   *
   * 两种布局共用同一块面板：
   *   - **全屏**（横屏沉浸）：点底栏「选集」滑出，宽 `min(420, 页面宽/3)`；
   *   - **平板横屏但没点全屏**：这一栏默认就是打开的（对照参照实现的
   *     `showTabBody` 默认 true + `_isSideTabLayout = _windowIsLandscape`），
   *     视频居左铺满、目录居右，点底栏「选集」收起。
   * 左半边那层压暗遮罩点一下同样收起。
   */
  @Builder
  sidePanel() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [['#80000000', 0.0], ['#00000000', 1.0]]
        })
        .onClick(() => {
          this.showPanelInFullscreen = false;
        })
      Column() {
        this.episodePanel()
      }
      .width(Math.min(420, Viewport.widthVp(this.viewportWidth) / 3))
      .height('100%')
      .backgroundColor(AppColor.surface)
      .borderRadius({ topLeft: 28, bottomLeft: 28 })
      .clip(true)
      .transition(TransitionEffect.OPACITY.animation({
        duration: 120,
        curve: AppCurves.easeOut()
      }))
    }
    .width('100%')
    .height('100%')
  }

  // ---------- 选项菜单（HarmonyOS 原生菜单） ----------

  /**
   * 六个选项菜单统一用 `Menu()` + `MenuItem()` 承载 —— 与播放页顶栏
   * 「收藏」菜单同一套组件，也就是用户点名「做得很华为化」的那一个。
   *
   * 约定：
   *   - **选中项打勾**（`endIcon: sys.symbol.checkmark`），不加粗、不换色——
   *     原生菜单里「勾」就是选中语义，再加一层颜色等于同义反复；
   *   - 长菜单（更多）用 `MenuItemGroup({ header })` 分三段；
   *   - 每项点击先 `closeMenus()` 再执行动作，避免菜单残留一帧。
   */
  @Builder
  menuOption(label: string, selected: boolean, action: () => void) {
    if (selected) {
      MenuItem({ content: label, endIcon: $r('sys.symbol.checkmark') })
        .onClick(() => {
          this.closeMenus();
          action();
        })
    } else {
      MenuItem({ content: label })
        .onClick(() => {
          this.closeMenus();
          action();
        })
    }
  }

  /** 带图标的菜单项（「更多」菜单用）。 */
  @Builder
  menuOptionWithIcon(label: string, icon: Resource, action: () => void) {
    MenuItem({ content: label, startIcon: icon })
      .onClick(() => {
        this.closeMenus();
        action();
      })
  }

  /**
   * 带**右侧说明文字**的菜单项（线路菜单用）。
   *
   * ArkUI 的 `MenuItem` 有 `labelInfo`：主文案右侧的次要说明。
   * 用它显示「已解析 / 总集数」，比把数字塞进主文案里更好读。
   */
  @Builder
  menuOptionWithInfo(label: string, info: string, selected: boolean,
    action: () => void) {
    if (selected) {
      MenuItem({ content: label, labelInfo: info, endIcon: $r('sys.symbol.checkmark') })
        .onClick(() => {
          this.closeMenus();
          action();
        })
    } else {
      MenuItem({ content: label, labelInfo: info })
        .onClick(() => {
          this.closeMenus();
          action();
        })
    }
  }

  /**
   * 某条线路的集数文案：**已解析 / 总集数**。
   *
   * 用户 2026-09-18：「播放线路展开后的弹窗可以显示一下解析了多少集（总集数）吗」。
   *   - 已解析 = 这条线路实际拿到的剧集数（`road.data.length`）；
   *   - 总集数 = 条目信息里的 `total_episodes`（拿不到就用 `eps`）。
   *
   * 两个数不同时写 `12 / 24 集`——一眼就能看出这条线路缺了几集；
   * 相同时（或总集数未知）只写 `24 集`，不啰嗦。
   */
  private roadEpisodeInfo(road: Road): string {
    const parsed: number = road.data.length;
    const total: number = this.item.totalEpisodes !== undefined &&
      this.item.totalEpisodes > 0
      ? this.item.totalEpisodes
      : (this.item.eps !== undefined ? this.item.eps : 0);
    if (total > 0 && total !== parsed) {
      return `${parsed} / ${total} 集`;
    }
    return `${parsed} 集`;
  }

  /** 倍速菜单（`PLAY_SPEEDS` 全档位，当前档打勾）。 */
  @Builder
  speedMenu() {
    Menu() {
      ForEach(PLAY_SPEEDS, (value: number) => {
        this.menuOption(`${VideoPage.trimSpeed(value)}x`, value === this.speed, () => {
          this.applySpeed(value);
        })
      }, (value: number) => `speed-${value}`)
    }
  }

  /** 画面比例菜单。 */
  @Builder
  aspectMenu() {
    Menu() {
      ForEach(ASPECT_LABELS, (label: string, index: number) => {
        this.menuOption(label, VideoPage.aspectOf(index + 1) === this.aspect, () => {
          this.applyAspect(VideoPage.aspectOf(index + 1));
        })
      }, (label: string) => `aspect-${label}`)
    }
  }

  /** 线路菜单（贴在剧集面板的线路胶囊下方）。 */
  @Builder
  roadMenu() {
    Menu() {
      ForEach(this.roads, (road: Road, index: number) => {
        // 右侧带上「已解析 / 总集数」——切线路时先看清这条线路全不全
        this.menuOptionWithInfo(this.roadName(index),
          this.roadEpisodeInfo(road), index === this.visibleRoad, () => {
            this.visibleRoad = index;
          })
      }, (road: Road, index: number) => `road-${index}`)
    }
  }

  /** 超分辨率菜单（§15.3）。 */
  @Builder
  srMenu() {
    Menu() {
      ForEach(SUPER_RESOLUTION_LABELS, (label: string, index: number) => {
        this.menuOption(label, index + 1 === this.superResolution, () => {
          this.applySuperResolution(index + 1);
        })
      }, (label: string) => `sr-${label}`)
    }
  }

  /**
   * 「更多」菜单（§39.5.2）。
   *
   * 分组：**播放 / 弹幕与投屏 / 定时关闭**。
   *
   * 与自绘版本的两点差异：
   *   1. 「定时关闭」原来是二级浮层（kind 6），原生菜单不做二级菜单，
   *      这里展开成一组——少一次点击，也不会出现「菜单里再弹菜单」；
   *   2. 每项配图标（§46.4 映射），与系统菜单的「图标 + 文案」一致。
   */
  @Builder
  moreMenu() {
    Menu() {
      MenuItemGroup({ header: '播放' }) {
        this.menuOptionWithIcon('视频详情', $r('sys.symbol.info_circle'), () => {
          this.showVideoInfo = true;
          this.clearHideTimer();
        })
        this.menuOptionWithIcon('外部播放', $r('sys.symbol.arrow_up_left'), () => {
          this.launchExternalPlayer();
        })
        // 缓存本集（§18）：用**已经解析好的地址**入队，不再重新取流
        this.menuOptionWithIcon('缓存本集', $r('sys.symbol.download'), () => {
          this.cacheCurrentEpisode();
        })
        this.menuOptionWithIcon('重新解析', $r('sys.symbol.arrow_2_circlepath'), () => {
          this.changeEpisode(this.currentEpisode, this.currentRoad);
        })
      }

      MenuItemGroup({ header: '弹幕与投屏' }) {
        this.menuOptionWithIcon('弹幕设置', $r('sys.symbol.text_bubble_left_2'), () => {
          this.showDanmakuSheet = true;
          this.clearHideTimer();
        })
        this.menuOptionWithIcon('弹幕时间校准', $r('sys.symbol.clock_arrow_2_circlepath'), () => {
          this.danmakuOffsetValue =
            SettingsStore.getNumber(SettingsKeys.danmakuTimeOffset);
          this.showDanmakuOffset = true;
          this.clearHideTimer();
        })
        this.menuOptionWithIcon('投屏', $r('sys.symbol.airplayaudio'), () => {
          this.showDlnaSheet = true;
          this.clearHideTimer();
          this.searchDlnaDevices();
        })
      }

      MenuItemGroup({ header: this.shutdownLabel.length > 0
        ? `定时关闭 · ${this.shutdownLabel}` : '定时关闭' }) {
        this.menuOption('不开启', !TimedShutdown.isActive(), () => {
          this.setTimedShutdown(0);
        })
        ForEach([15, 30, 60], (minutes: number) => {
          this.menuOption(`${minutes} 分钟`,
            TimedShutdown.isActive() && TimedShutdown.setMinutes() === minutes,
            () => {
              this.setTimedShutdown(minutes);
            })
        }, (minutes: number) => `more-timer-${minutes}`)
        this.menuOption('自定义…', false, () => {
          this.openCustomTimerDialog();
        })
      }
    }
  }

  @Builder
  videoInfoSheet() {
    Column({ space: 10 }) {
      Text('视频详情')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.onSurface)
        .width('100%')
      // 两个 Tab（§40.2）：视频 / 音频参数、日志
      Row() {
        this.videoInfoTabItem(0, '视频 / 音频参数')
        this.videoInfoTabItem(1, '日志')
      }
      .width('100%')
      .height(40)

      if (this.videoInfoTab === 0) {
        /**
         * 「视频 / 音频参数」这一屏的内容比一屏高，**必须可上下滑动**
         * （用户 2026-09-18：「视频详情的卡片不能上下滑动」）。
         *
         * 以前这里是一串裸的 `infoRow` 直接排在 Column 里：超出部分既不滚动
         * 也没有任何提示，底下的「视频地址 / 复制地址」等于看不到。
         * 现在放进 `Scroll` 并 `layoutWeight(1)` 占满 tab 栏以下的剩余高度。
         */
        Scroll() {
          Column({ space: 10 }) {
        this.infoRow('标题', this.sourceTitle)
        this.infoRow('线路', this.roadName(this.currentRoad))
        this.infoRow('集数', `第 ${this.currentEpisode} 集`)
        this.infoRow('播放时长', VideoPage.formatTime(this.durationMs))
        this.infoRow('分辨率', this.engine === null ? '' : this.engine.videoSize())
        /**
         * 码率（用户 2026-09-18：「视频详情标明视频码率，分辨率，声音码率」）。
         *
         * 分辨率本来就有；码率两项之前漏了。mpv 的 `video-bitrate` /
         * `audio-bitrate` 单位是**比特/秒**，由 `formatBitrate` 换成 kbps/Mbps。
         * 画面/声音还没起时这两个属性读出来是空串，`infoRow` 会显示「—」。
         */
        this.infoRow('视频码率', VideoPage.formatBitrate(
          this.engine === null ? '' : this.engine.property('video-bitrate')))
        this.infoRow('音频码率', VideoPage.formatBitrate(
          this.engine === null ? '' : this.engine.property('audio-bitrate')))
        this.infoRow('视频编码', this.engine === null ? ''
          : this.engine.property('video-codec'))
        this.infoRow('音频编码', this.engine === null ? ''
          : this.engine.property('audio-codec-name'))
        this.infoRow('帧率', this.engine === null ? ''
          : this.engine.property('container-fps'))
        this.infoRow('硬件解码', this.engine === null ? ''
          : this.engine.property('hwdec-current'))
        this.infoRow('视频地址', this.currentVideoUrl)
        Row({ space: 8 }) {
          Button('复制地址')
            .fontSize(13)
            .height(34)
            .onClick(() => {
              this.copyToClipboard(this.currentVideoUrl);
            })
        }
        .width('100%')
        .margin({ top: 6 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      } else {
        Row({ space: 8 }) {
          Text(`${this.sourceLogs.length} 条记录`)
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .layoutWeight(1)
          Button('复制全部')
            .fontSize(12)
            .height(30)
            .onClick(() => {
              this.copyToClipboard(this.sourceLogs.join('\n'));
            })
        }
        .width('100%')
        List() {
          ForEach(this.sourceLogs, (line: string, index: number) => {
            ListItem() {
              Text(line)
                .fontSize(11)
                .lineHeight(15)
                // 问题行上色：与参照实现的 `isProblem` 同一判据
                .fontColor(VideoPage.isProblemLog(line)
                  ? AppColor.error : AppColor.onSurfaceVariant)
                .width('100%')
            }
            .onClick(() => {
              this.copyToClipboard(line);
            })
          }, (line: string, index: number) => `log-${index}`)
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 20 })
  }

  @Builder
  videoInfoTabItem(index: number, label: string) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(13)
        .fontWeight(this.videoInfoTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.videoInfoTab === index
          ? AppColor.primary : AppColor.onSurfaceVariant)
      Column()
        .width(24)
        .height(2)
        .borderRadius(1)
        .backgroundColor(this.videoInfoTab === index ? AppColor.primary : '#00000000')
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.videoInfoTab = index;
    })
  }

  /** 日志行是否算「问题」（§40.2 的 `isProblem`）。 */
  static isProblemLog(line: string): boolean {
    return line.includes('fatal') || line.includes('error') || line.includes('warn');
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(AppColor.onSurfaceVariant)
        .width(80)
      Text(value.length > 0 ? value : '—')
        .fontSize(13)
        .fontColor(AppColor.onSurface)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
  }

  // ---------- 剧集数据辅助 ----------

  private episodeCount(): number {
    if (this.visibleRoad < 0 || this.visibleRoad >= this.roads.length) {
      return 0;
    }
    return this.roads[this.visibleRoad].data.length;
  }

  private segmentCount(): number {
    return Math.ceil(this.episodeCount() / EPISODE_GROUP_SIZE);
  }

  private segments(): number[] {
    const count: number = this.segmentCount();
    const list: number[] = [];
    for (let i = 0; i < count; i++) {
      list.push(this.segmentAtDisplayIndex(i));
    }
    return list;
  }

  /** 分段条 / 定位条里的显示位置 → 真实段号。 */
  private segmentAtDisplayIndex(displayIndex: number): number {
    const count: number = this.segmentCount();
    return this.episodeReversed ? count - 1 - displayIndex : displayIndex;
  }

  /** 真实段号 → 分段条 / 定位条里的显示位置。 */
  private segmentDisplayIndex(group: number): number {
    const count: number = this.segmentCount();
    return this.episodeReversed ? count - 1 - group : group;
  }

  private static segmentLabel(group: number, total: number): string {
    const start: number = group * EPISODE_GROUP_SIZE + 1;
    let end: number = start + EPISODE_GROUP_SIZE - 1;
    if (end > total) {
      end = total;
    }
    return `${start}-${end}`;
  }

  /**
   * 集号圆的最小宽度：1–2 位 30、3 位 38、4 位及以上 46。
   *
   * 长番（《名侦探柯南》1340 集）在固定 30 宽的圆里，四位数字会顶到圆边；
   * 位数决定宽度既省横向空间，又不会让数字看起来「挤在球里」。
   */
  private static episodeChipWidth(episode: number): number {
    const digits: number = `${episode}`.length;
    if (digits <= 2) {
      return 30;
    }
    return digits === 3 ? 38 : 46;
  }

  /**
   * 剧集行的上下内距（vp）——**竖屏与全屏各一套**。
   *
   * 行高不再写死，而是「内容 + 上下内距」，所以内距就是行高的唯一旋钮：
   *   - 竖屏 13：集号圆 30 + 13×2 = **56**，与原实现逐像素一致
   *     （行高一致是 `scrollEpisodeToLocal` 按 `EPISODE_ROW_HEIGHT` 换算的前提）；
   *   - 全屏 8：一行 46、两行 ≈ 55，**行高随集名行数变化**，窄抽屉里也放得下长集名。
   *
   * 2026-09-19 用户：「竖屏状态下的播放目录页尺寸还原回原来的尺寸，全屏状态下的
   * 播放目录弹窗单独做，现在尺寸也很大，改成随行数变化的」。
   */
  private episodeRowPadding(): number {
    return this.fullscreen ? 8 : 13;
  }

  private episodeRange(): number[] {
    const total: number = this.episodeCount();
    const start: number = this.segmentGroup * EPISODE_GROUP_SIZE + 1;
    const end: number = Math.min(start + EPISODE_GROUP_SIZE - 1, total);
    const list: number[] = [];
    if (this.episodeReversed) {
      for (let i = end; i >= start; i--) {
        list.push(i);
      }
    } else {
      for (let i = start; i <= end; i++) {
        list.push(i);
      }
    }
    return list;
  }

  /** 当前分段内某一集在列表里的局部下标（正序 / 倒序共用）。 */
  private episodeLocalIndex(episode: number): number {
    const start: number = this.segmentGroup * EPISODE_GROUP_SIZE + 1;
    const end: number = Math.min(start + EPISODE_GROUP_SIZE - 1, this.episodeCount());
    if (episode < start || episode > end) {
      return 0;
    }
    return this.episodeReversed ? end - episode : episode - start;
  }

  /**
   * 切换目录顺序。
   *
   * 保持当前分段与正在看的集不变；排序完成后重新定位当前集，
   * 避免长番倒序后画面停在一段无关的剧集上。
   */
  private toggleEpisodeOrder(): void {
    this.episodeReversed = !this.episodeReversed;
    this.revealCurrentEpisode();
  }

  /**
   * 目录信息行右侧那行「集标题 x/y · ↻」。
   *
   * 只在**没拿全**时才返回非空：
   *   - 表没到、或已经确定拿不到 → 「集标题未取到」；
  *   - 表到了但覆盖不满本线路 → 「集标题 x/y」。
   *
   * ⚠️ **当前 UI 不再展示**（2026-09-20 晚用户要求去掉那行指示，见
   * `episodeInfoRow` 里的注释）。方法保留：一是 hilog 明细要继续用，
   * 二是哪天要把那行加回来直接调它即可。
   * 拿全就返回空串——正常情况不打扰。
   */
  private episodeTitleStatus(): string {
    const rev: number = this.episodeTitleRev;
    if (rev < 0) {
      return '';
    }
    const count: number = this.episodeCount();
    if (count <= 0) {
      return '';
    }
    const titles: Map<number, string> | undefined =
      EpisodeTitleService.cached(this.item.id);
    if (titles === undefined) {
      return EpisodeTitleService.isUnavailable(this.item.id) ? '集标题未取到' : '';
    }
    const covered: number = EpisodeTitleService.coveredWithin(titles, count);
    return covered >= count ? '' : `集标题 ${covered}/${count}`;
  }

  /** 点那行状态 → 忘掉这次结果、当场重取一次（撞上风控/断网时的原地重试）。 */
  private retryEpisodeTitles(): void {
    const detail: string = EpisodeTitleService.lastReport();
    if (detail.length > 0) {
      // 先把上一次的明细说出来（哪个源给了几条、季选的是哪一个），再重试
      this.toast(`上次：${detail}`);
    }
    // 重试连哔哩哔哩会话 cookie 一起换新，撞风控时才有意义
    EpisodeTitleService.forget(this.item.id, true);
    this.episodeTitleRev += 1;
    this.toast('正在重新获取集标题…');
    this.refreshEpisodeTitles();
  }

  private episodeLabel(episode: number): string {
    /**
     * 集标题优先级：**Bangumi → 哔哩哔哩 → 插件给的 identifier → 第N集**
     * （用户 2026-09-18：「标题从 bangumi 取，然后取不到从哔哩哔哩取，
     *  你看一下源码呀」，对应参照实现 `episode_title_service.dart`）。
     *
     * 读 `episodeTitleRev` 是为了让异步结果到达后本行（以及目录行、顶栏）
     * 重新求值——ArkUI 只重绘“build 里读过”的状态。
     *
     * **返回值统一过繁 → 简**（2026-09-19 用户：「希望视频页的目录里的繁体能
     * 转化成简体（这个源码好像实现过）」）。参照实现在
     * `episode_selection_panel.dart:650` 就是这么做的——三条来源（下载名 /
     * Bangumi / 哔哩哔哩）与插件给的 `identifier` 都会先择一再
     * `toSimplifiedChinese()`，注释写着「分集名可能来自繁体线路或 B站 的繁体季，
     * 统一转成简体，避免标题简繁混排」。这里转的是最终展示串，缓存里的原始
     * 标题不动。
     */
    const rev: number = this.episodeTitleRev;
    if (rev >= 0) {
      const titles: Map<number, string> | undefined =
        EpisodeTitleService.cached(this.item.id);
      if (titles !== undefined) {
        const hit: string | undefined = titles.get(episode);
        if (hit !== undefined && hit.trim().length > 0) {
          return toSimplifiedChinese(hit.trim());
        }
      }
    }
    if (episode - 1 < this.episodeNames.length) {
      const name: string = this.episodeNames[episode - 1].trim();
      if (name.length > 0) {
        return toSimplifiedChinese(name);
      }
    }
    return `第${episode}集`;
  }

  /**
   * 拉一次分集标题（Bangumi 优先，哔哩哔哩兜底），到了就 bump 版本号重绘。
   *
   * 失败/没匹配到不弹窗——目录里仍然显示插件给的名字或「第 N 集」，
   * 与源码「宁可不填也不要填错」一致。
   */
  private async refreshEpisodeTitles(): Promise<void> {
    const id: number = this.item.id;
    const count: number = this.episodeCount();
    if (id <= 0 || count <= 0) {
      // 条目没有 Bangumi id（或线路集数为 0）时**根本不会去取**，
      // 以前这里静默 return，界面上看不出是「没取」还是「取不到」
      Logger.info('EpisodeTitle',
        `[集标题] 跳过：条目 id=${id} 本线路集数=${count}`);
      return;
    }
    if (EpisodeTitleService.cached(id) !== undefined
      || EpisodeTitleService.isUnavailable(id)) {
      return;
    }
    const titles: Map<number, string> = await EpisodeTitleService.resolve(
      id, this.item.displayName(), this.item.name,
      count, this.item.airDate);
    if (titles.size > 0) {
      hilog.info(DOMAIN, TAG, '分集标题就绪：%{public}d 条', titles.size);
      /**
       * 把「覆盖到第几集 / 本线路有多少集」写成一行日志。
       *
       * 长番（柯南 1200+ 集）经常出现「后面几百集没有标题」——那多半是
       * **上游就没有那么多标题**（实测：Bangumi 899 的正片只到 1220，
       * 哔哩哔哩柯南季 1272 集），不是链路断了。这一行让用户不用猜：
       * 覆盖数明显小于线路集数 → 数据边界；覆盖数为 0 → 链路问题。
       *
       * ⚠️ 用 `coveredWithin` 而不是 `titles.size`：表**不按线路集数截断**
       * （见 `EpisodeTitleService.pickForLocal`），所以表里可能有
       * 超出本线路集数的条目（例如先落在 381 集的线路上、表里却有 1272 条）。
       */
      const covered: number = EpisodeTitleService.coveredWithin(titles, count);
      if (covered < count) {
        Logger.info('EpisodeTitle',
          `[集标题] 覆盖 ${covered} / 本线路 ${count} 集` +
            `（第 ${covered + 1} 集之后没有上游标题，退化成「第N集」）`);
      }
      this.episodeTitleRev += 1;
      /**
       * 让整列文字淡进来，而不是「啪」地一下从「第 N 集」换成真标题。
       * 关掉动画时（`MotionRuntime.isOff()`）直接给 1，不做无意义的一次赋值动画。
       */
      if (MotionRuntime.isOff()) {
        this.episodeTitleFade = 1;
      } else {
        this.episodeTitleFade = 0.35;
        animateTo({
          duration: MotionRuntime.ms(Motion.quick),
          curve: AppCurves.easeOutCubic()
        }, () => {
          this.episodeTitleFade = 1;
        });
      }
    } else {
      // 取不到也要留痕：日志页能看到「是哪一步空的」，排查不用再猜
      Logger.info('EpisodeTitle',
        `[集标题] 未取到：条目 ${id} 本线路 ${count} 集，目录退回「第N集」`);
    }
  }

  private isSelected(episode: number): boolean {
    return this.visibleRoad === this.currentRoad && episode === this.currentEpisode;
  }

  private isPlayingEpisode(episode: number): boolean {
    return this.playing && this.isSelected(episode);
  }

  // ---------- 时间与倍速格式 ----------

  static formatTime(ms: number): string {
    if (ms <= 0) {
      return '00:00';
    }
    const totalSeconds: number = Math.floor(ms / 1000);
    const seconds: number = totalSeconds % 60;
    const minutes: number = Math.floor(totalSeconds / 60) % 60;
    const hours: number = Math.floor(totalSeconds / 3600);
    const two = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    if (hours > 0) {
      return `${two(hours)}:${two(minutes)}:${two(seconds)}`;
    }
    return `${two(minutes)}:${two(seconds)}`;
  }

  /**
   * mpv 的 `video-bitrate` / `audio-bitrate` → 人类可读码率。
   *
   * mpv 这两个属性给的是**比特/秒**（整数，可能带小数）；读不到（空串）
   * 或还没起播时返回空串，由 `infoRow` 统一显示「—」。
   */
  static formatBitrate(raw: string): string {
    const value: number = Number.parseFloat(raw);
    if (raw.length === 0 || Number.isNaN(value) || value <= 0) {
      return '';
    }
    if (value >= 1000000) {
      return `${(value / 1000000).toFixed(2)} Mbps`;
    }
    return `${Math.round(value / 1000)} kbps`;
  }

  static trimSpeed(value: number): string {
    return Number.isInteger(value) ? `${value}.0` : `${value}`;
  }
}

/**
 * 「修改快进秒数」对话框（§39.5.1 的长按分支）。
 *
 * 参照实现弹的是 AlertDialog + 「取消 / 确定」；原生侧同样是两按钮 +
 * 一个数字输入框（手机上比数字微调器更好按）。
 */
@CustomDialog
struct SkipTimeDialog {
  controller: CustomDialogController = new CustomDialogController({
    builder: SkipTimeDialog({
      initial: 80,
      onConfirm: (value: number) => {
      }
    })
  });
  initial: number = 80;
  onConfirm: (value: number) => void = () => {
  };
  @State private text: string = '80';

  aboutToAppear(): void {
    this.text = `${this.initial}`;
  }

  build() {
    Column({ space: 16 }) {
      Text('修改快进时间')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.onSurface)
        .width('100%')
      Text('长按跳 OP 按钮时使用；单位为秒。')
        .fontSize(12)
        .fontColor(AppColor.onSurfaceVariant)
        .width('100%')
      TextInput({ text: this.text, placeholder: '秒' })
        .type(InputType.Number)
        .fontSize(15)
        .onChange((value: string) => {
          this.text = value;
        })
      Row({ space: 12 }) {
        Button('取消')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .fontColor(AppColor.onSurfaceVariant)
          .onClick(() => {
            this.controller.close();
          })
        Button('确定')
          .fontSize(14)
          .layoutWeight(1)
          .onClick(() => {
            const value: number = Number.parseInt(this.text, 10);
            if (Number.isNaN(value) || value <= 0) {
              return;
            }
            this.onConfirm(value);
            this.controller.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(24)
  }
}

/**
 * 「自定义定时」对话框（§39.5.2）。
 *
 * 参照实现是「时 : 分」两个 CupertinoPicker（0–24 时 / 0–59 分）；
 * 原生侧换成分钟输入 + 常用档位快捷按钮——同样能表达「任意分钟数」，
 * 手机键盘输入比滚轮更好按。
 */
@CustomDialog
struct CustomTimerDialog {
  controller: CustomDialogController = new CustomDialogController({
    builder: CustomTimerDialog({
      onConfirm: (minutes: number) => {
      }
    })
  });
  onConfirm: (minutes: number) => void = () => {
  };
  @State private text: string = '45';

  build() {
    Column({ space: 16 }) {
      Text('自定义定时')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.onSurface)
        .width('100%')
      Text('单位：分钟。到点后自动暂停播放。')
        .fontSize(12)
        .fontColor(AppColor.onSurfaceVariant)
        .width('100%')
      TextInput({ text: this.text, placeholder: '分钟' })
        .type(InputType.Number)
        .fontSize(15)
        .onChange((value: string) => {
          this.text = value;
        })
      Row({ space: 8 }) {
        ForEach([10, 45, 90], (preset: number) => {
          Text(`${preset}`)
            .fontSize(13)
            .fontColor(AppColor.primary)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .backgroundColor(AppColor.surfaceContainerHighest)
            .onClick(() => {
              this.text = `${preset}`;
            })
        }, (preset: number) => `preset-${preset}`)
      }
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
        Button('确定')
          .fontSize(14)
          .layoutWeight(1)
          .onClick(() => {
            const value: number = Number.parseInt(this.text, 10);
            if (Number.isNaN(value) || value <= 0) {
              return;
            }
            this.onConfirm(value);
            this.controller.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(24)
  }
}
