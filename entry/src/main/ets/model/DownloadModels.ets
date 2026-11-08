import { JsonUtils } from './JsonUtils';

/**
 * 下载数据模型。逐字段对应参照实现：
 *   - `lib/modules/download/download_module.dart`（`DownloadRecord` / `DownloadEpisode`）
 *
 * Hive 编号保留在注释里：原生版落盘为 JSON，但字段语义必须一致，
 * 否则「下载页显示的状态」与「引擎里的状态」会对不上。
 */

/** 单集下载状态（源码注释：0 pending / 1 resolving / 2 downloading / 3 completed / 4 failed / 5 paused）。 */
export class DownloadStatus {
  static readonly pending: number = 0;
  static readonly resolving: number = 1;
  static readonly downloading: number = 2;
  static readonly completed: number = 3;
  static readonly failed: number = 4;
  static readonly paused: number = 5;

  /** 状态文案（下载页角标用）。 */
  static label(status: number): string {
    if (status === DownloadStatus.resolving) {
      return '解析中';
    }
    if (status === DownloadStatus.downloading) {
      return '下载中';
    }
    if (status === DownloadStatus.completed) {
      return '已完成';
    }
    if (status === DownloadStatus.failed) {
      return '失败';
    }
    return status === DownloadStatus.paused ? '已暂停' : '等待中';
  }
}

/** 一集的下载记录。 */
export class DownloadEpisode {
  /** @HiveField(0) */
  episodeNumber: number = 0;
  /** @HiveField(1) */
  episodeName: string = '';
  /** @HiveField(2) 线路序号 */
  road: number = 0;
  /** @HiveField(3) 见 `DownloadStatus` */
  status: number = DownloadStatus.pending;
  /** @HiveField(4) 0–100 */
  progressPercent: number = 0;
  /** @HiveField(5) */
  totalSegments: number = 0;
  /** @HiveField(6) */
  downloadedSegments: number = 0;
  /** @HiveField(7) 本地清单路径（离线播放用） */
  localM3u8Path: string = '';
  /** @HiveField(8) 本集文件所在目录 */
  downloadDirectory: string = '';
  /** @HiveField(9) 远端清单地址 */
  networkM3u8Url: string = '';
  /** @HiveField(10) 完成时间（毫秒时间戳，0 表示未完成） */
  completedAt: number = 0;
  /** @HiveField(11) */
  errorMessage: string = '';
  /** @HiveField(12) 已下载字节数 */
  totalBytes: number = 0;
  /** @HiveField(13) 剧集页地址（离线播放与历史定位用） */
  episodePageUrl: string = '';
  /** @HiveField(14) 缓存的弹幕 JSON（设置「缓存弹幕」开启时写） */
  danmakuData: string = '';
  /** @HiveField(15) 弹弹play 番剧 id */
  danDanBangumiID: number = 0;
}

/** 一部番剧的下载记录。 */
export class DownloadRecord {
  /** @HiveField(0) */
  bangumiId: number = 0;
  /** @HiveField(1) */
  bangumiName: string = '';
  /** @HiveField(2) */
  bangumiCover: string = '';
  /** @HiveField(3) */
  pluginName: string = '';
  /** @HiveField(4) */
  episodes: DownloadEpisode[] = [];
  /** @HiveField(5) */
  createdAt: number = 0;

  /** 去重键（源码 `'${pluginName}_$bangumiId'`）。 */
  key(): string {
    return `${this.pluginName}_${this.bangumiId}`;
  }

  findEpisode(episodeNumber: number): DownloadEpisode | null {
    for (let i = 0; i < this.episodes.length; i++) {
      if (this.episodes[i].episodeNumber === episodeNumber) {
        return this.episodes[i];
      }
    }
    return null;
  }
}

/** 一次下载请求（源码 `DownloadRequest`）。 */
export class DownloadRequest {
  recordKey: string = '';
  bangumiId: number = 0;
  bangumiName: string = '';
  bangumiCover: string = '';
  pluginName: string = '';
  episodeNumber: number = 0;
  episodeName: string = '';
  road: number = 0;
  episodePageUrl: string = '';
  /** 已解析好的 m3u8 地址 */
  m3u8Url: string = '';
  /** 是否对该集启用去广告（对应 `forceAdBlocker` 或规则里的 `adBlocker`） */
  adBlockerEnabled: boolean = false;
}

/** 存储与进度统计。 */
export class DownloadStats {
  /** 记录条数 */
  recordCount: number = 0;
  /** 全部集数 */
  episodeCount: number = 0;
  /** 已完成集数 */
  completedCount: number = 0;
  /** 正在下载 / 解析的集数 */
  runningCount: number = 0;
  /** 已完成集占用的字节数 */
  totalBytes: number = 0;
}

// ---------------- 序列化 ----------------

export function downloadEpisodeToJson(episode: DownloadEpisode): Record<string, Object> {
  const out: Record<string, Object> = {};
  out['episodeNumber'] = episode.episodeNumber;
  out['episodeName'] = episode.episodeName;
  out['road'] = episode.road;
  out['status'] = episode.status;
  out['progressPercent'] = episode.progressPercent;
  out['totalSegments'] = episode.totalSegments;
  out['downloadedSegments'] = episode.downloadedSegments;
  out['localM3u8Path'] = episode.localM3u8Path;
  out['downloadDirectory'] = episode.downloadDirectory;
  out['networkM3u8Url'] = episode.networkM3u8Url;
  out['completedAt'] = episode.completedAt;
  out['errorMessage'] = episode.errorMessage;
  out['totalBytes'] = episode.totalBytes;
  out['episodePageUrl'] = episode.episodePageUrl;
  out['danmakuData'] = episode.danmakuData;
  out['danDanBangumiID'] = episode.danDanBangumiID;
  return out;
}

export function downloadEpisodeFromJson(rec: Record<string, Object>): DownloadEpisode {
  const episode = new DownloadEpisode();
  episode.episodeNumber = JsonUtils.intOf(rec, 'episodeNumber');
  episode.episodeName = JsonUtils.str(rec, 'episodeName');
  episode.road = JsonUtils.intOf(rec, 'road');
  episode.status = JsonUtils.intOf(rec, 'status', DownloadStatus.pending);
  episode.progressPercent = JsonUtils.num(rec, 'progressPercent');
  episode.totalSegments = JsonUtils.intOf(rec, 'totalSegments');
  episode.downloadedSegments = JsonUtils.intOf(rec, 'downloadedSegments');
  episode.localM3u8Path = JsonUtils.str(rec, 'localM3u8Path');
  episode.downloadDirectory = JsonUtils.str(rec, 'downloadDirectory');
  episode.networkM3u8Url = JsonUtils.str(rec, 'networkM3u8Url');
  episode.completedAt = JsonUtils.intOf(rec, 'completedAt');
  episode.errorMessage = JsonUtils.str(rec, 'errorMessage');
  episode.totalBytes = JsonUtils.intOf(rec, 'totalBytes');
  episode.episodePageUrl = JsonUtils.str(rec, 'episodePageUrl');
  episode.danmakuData = JsonUtils.str(rec, 'danmakuData');
  episode.danDanBangumiID = JsonUtils.intOf(rec, 'danDanBangumiID');
  return episode;
}

export function downloadRecordToJson(record: DownloadRecord): Record<string, Object> {
  const out: Record<string, Object> = {};
  out['bangumiId'] = record.bangumiId;
  out['bangumiName'] = record.bangumiName;
  out['bangumiCover'] = record.bangumiCover;
  out['pluginName'] = record.pluginName;
  out['createdAt'] = record.createdAt;
  const episodes: Object[] = [];
  for (let i = 0; i < record.episodes.length; i++) {
    episodes.push(downloadEpisodeToJson(record.episodes[i]));
  }
  out['episodes'] = episodes as Object;
  return out;
}

export function downloadRecordFromJson(rec: Record<string, Object>): DownloadRecord {
  const record = new DownloadRecord();
  record.bangumiId = JsonUtils.intOf(rec, 'bangumiId');
  record.bangumiName = JsonUtils.str(rec, 'bangumiName');
  record.bangumiCover = JsonUtils.str(rec, 'bangumiCover');
  record.pluginName = JsonUtils.str(rec, 'pluginName');
  record.createdAt = JsonUtils.intOf(rec, 'createdAt');
  const list: Object[] = JsonUtils.arr(rec, 'episodes');
  for (let i = 0; i < list.length; i++) {
    const item: Record<string, Object> | null = JsonUtils.asObj(list[i]);
    if (item !== null) {
      record.episodes.push(downloadEpisodeFromJson(item));
    }
  }
  return record;
}
