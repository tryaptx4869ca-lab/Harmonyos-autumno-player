import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BangumiItem } from '../model/BangumiItem';
import { Road } from '../model/SearchModels';
import { Plugin } from '../plugins/Plugin';
import { NavHost, RouteTable } from './RouteTable';

/** 离线播放用的一集（只带播放页必需的信息）。 */
export class OfflineEpisode {
  episodeNumber: number = 0;
  episodeName: string = '';
  road: number = 0;
  /** 本地清单路径 */
  playlistPath: string = '';

  static of(episodeNumber: number, episodeName: string, road: number,
    playlistPath: string): OfflineEpisode {
    const episode = new OfflineEpisode();
    episode.episodeNumber = episodeNumber;
    episode.episodeName = episodeName;
    episode.road = road;
    episode.playlistPath = playlistPath;
    return episode;
  }
}

/**
 * 路由参数载体。
 *
 * 参照实现用 `context.pushNamed(route, arguments: ...)` 传对象
 * （`InfoRouteData` / `VideoPlaybackArgs`）。ArkUI 的 `router.pushUrl`
 * 也能带 params，但那是「跨页面 JSON 化」的语义——这里承载的是带方法的
 * 类实例（`BangumiItem.coverUrl()`、`Plugin.executionConfig()`），
 * 因此改成**静态槽位**：压栈前写入，目标页 `aboutToAppear` 取出后清空。
 *
 * 附加好处是「谁传了什么」在一处可见，排查「详情页打开的是上一个条目」
 * 这类问题时不用翻两个页面。
 */
export class InfoRouteArgs {
  static pending: BangumiItem | null = null;
  /**
   * **当前详情页**（覆盖层还开着时一直有效）。
   *
   * `pending` 是「一次性」的（详情页在 `aboutToAppear` 里消费掉就清空），
   * 但覆盖层**可能在别处被重建**：真机上从播放页返回就会出现一次
   * （2026-10-08 日志：弹栈后 20ms 又来一条 `详情页打开 id=0 name=`）——
   * 重建出来的实例拿不到数据，页面就是空的，用户看到的就是「回不到详情页」。
   * 所以另存一份当前参数：`aboutToAppear` 里 `pending` 为空时退回它，
   * 重建也能还原成同一部番（封面 tag 同理）。
   */
  static current: BangumiItem | null = null;
  static currentHeroTag: string = '';
  /**
   * 源页传过来的共享元素 id（`HeroFlight.tag(...)`）。
   *
   * 对应参照实现的 `InfoRouteData.heroTag`：同一个番剧可能同时出现在
   * Banner / 网格 / 搜索结果里，详情页必须知道**是哪一处**点进来的，
   * 否则 id 对不上（一个 id 绑两个组件是不允许的），共享元素就不会飞。
   */
  static pendingHeroTag: string = '';

  /**
   * 从播放页返回时，是否要**重新打开「播放来源」弹层**。
   *
   * 参照实现（`video_page.dart:433-455` 的 `onBackPressed`）只是 pop 回详情页、
   * 弹层是关着的；本项目按用户要求改成「回到准备选源的那一步」：
   * 播放页返回前置位，详情页 `onPageShow` 消费并重开弹层。
   */
  static reopenSourceSheet: boolean = false;

  /** 打开详情页。`origin` 只用于日志，方便对照是从哪个入口进的。 */
  static open(item: BangumiItem, origin: string, heroTag: string = ''): void {
    InfoRouteArgs.pending = item;
    InfoRouteArgs.pendingHeroTag = heroTag;
    // 另存一份「当前详情页」：覆盖层被重建时（见 `current` 的注释）靠它还原
    InfoRouteArgs.current = item;
    InfoRouteArgs.currentHeroTag = heroTag;
    hilog.info(0x0000, 'AutumnRoute', '打开详情页 id=%{public}d（来源 %{public}s）',
      item.id, origin);
    /**
     * 按**有没有共享元素**选转场方式：
     *   - 从海报卡片点进来的（`heroTag` 非空）：走 `pushWithHero`，
     *     关掉系统转场，让封面自己飞过去；
     *   - 没有海报来源的（例如「今日一句」那条入口）：走普通跳转，
     *     用系统的导航转场（鸿蒙的压栈动效）。
     * 2026-09-18 之前两者都走「关掉系统转场」那条路，所以后者点进去
     * 是「啪」地出现，没有任何页面动画。
     */
    if (heroTag.length > 0) {
      NavHost.pushWithHero(RouteTable.info);
    } else {
      RouteTable.push(RouteTable.info);
    }
  }
}

/** 播放页参数（对应 `OnlineVideoPlaybackArgs`）。 */
export class VideoRouteArgs {
  bangumiItem: BangumiItem = new BangumiItem();
  plugin: Plugin | null = null;
  /** 视频源给出的标题（可能与条目名不同）。 */
  title: string = '';
  /** 播放页地址（搜索结果里的 `src`）。 */
  src: string = '';
  roads: Road[] = [];
  /** 从详情页带过来的续播偏好（历史服务随阶段五，先留字段）。 */
  preferredEpisode: number = 0;
  preferredRoad: number = 0;
  /**
   * 离线播放：已完成下载的本地清单路径（`index.m3u8`）。
   * 非空时播放页**跳过取流**直接播本地文件（§18 的离线播放）。
   */
  offlinePlaylistPath: string = '';
  /** 离线播放时的线路：来自下载记录（每集的号码 + 剧集页地址）。 */
  offlineEpisodes: OfflineEpisode[] = [];
  /**
   * 离线播放的来源规则名。
   *
   * 为什么离线也要带它：播放历史按「规则名 + 条目 id + 来源」建键（§60），
   * 弹幕缓存也是按规则名索引的；不带规则名就既写不了历史、也读不到弹幕缓存。
   */
  offlinePluginName: string = '';
  /** 离线播放：由 `DownloadManager` 的记录拼出来（对应源码 `OfflineVideoPlaybackArgs`）。 */
  static offline(item: BangumiItem, pluginName: string, playlistPath: string,
    episodes: OfflineEpisode[]): VideoRouteArgs {
    const args = new VideoRouteArgs();
    args.bangumiItem = item;
    args.offlinePluginName = pluginName;
    args.title = item.nameCn.length > 0 ? item.nameCn : item.name;
    args.offlinePlaylistPath = playlistPath;
    args.offlineEpisodes = episodes;
    return args;
  }

  static pending: VideoRouteArgs | null = null;

  static open(args: VideoRouteArgs): void {
    VideoRouteArgs.pending = args;
    hilog.info(0x0000, 'AutumnRoute', '打开播放页：%{public}s', args.src);
    RouteTable.push(RouteTable.video);
  }
}

/**
 * 搜索页的预填关键词（详情页标签卡点进去时用）。
 * 空串表示按空状态打开。
 */
export class SearchRouteArgs {
  static pendingKeyword: string = '';
  /** 详情页标签入口：标签作为结构化条件，而不是普通文字关键词。 */
  static pendingTag: string = '';

  static open(keyword: string): void {
    SearchRouteArgs.pendingKeyword = keyword;
    SearchRouteArgs.pendingTag = '';
    RouteTable.push(RouteTable.search);
  }

  static openTag(tag: string): void {
    SearchRouteArgs.pendingKeyword = '';
    SearchRouteArgs.pendingTag = tag;
    RouteTable.push(RouteTable.search);
  }
}
