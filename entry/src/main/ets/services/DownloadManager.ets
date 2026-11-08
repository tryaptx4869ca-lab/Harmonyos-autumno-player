import { common } from '@kit.AbilityKit';
import { fileIo, statfs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import {
  DownloadEpisode,
  DownloadRecord,
  DownloadRequest,
  DownloadStats,
  DownloadStatus,
  downloadRecordFromJson,
  downloadRecordToJson
} from '../model/DownloadModels';
import { M3u8AdFilter } from './M3u8AdFilter';
import {
  M3u8MasterPlaylist,
  M3u8MediaPlaylist,
  M3u8ParseResult,
  M3u8Parser,
  M3u8Segment,
  M3u8Variant
} from './M3u8Parser';
import { Logger } from './Logger';
import { NetworkConfig, ProxyAddress } from '../request/core/NetworkConfig';
import { UrlParts } from '../request/core/UrlParts';
import { SettingsKeys } from './storage/SettingsKeys';
import { SettingsStore } from './storage/SettingsStore';

const TAG: string = 'AutumnDownload';

/** 默认并发（可被设置覆盖，与 §66.1 一致）。 */
const DEFAULT_MAX_PARALLEL_EPISODES: number = 2;
const DEFAULT_MAX_PARALLEL_SEGMENTS: number = 3;
/** 开始下载前要求的最小剩余空间（源码 `_minRequiredSpace` = 100MB）。 */
const MIN_REQUIRED_SPACE_BYTES: number = 100 * 1024 * 1024;
/** 下载用的超时（§47：下载 15s / 30s）。 */
const DOWNLOAD_CONNECT_TIMEOUT_MS: number = 15000;
const DOWNLOAD_RECEIVE_TIMEOUT_MS: number = 30000;
/**
 * 单文件（直链 mp4 这类）的读超时。
 *
 * 实测教训：30 秒的读超时对**流式大文件**是致命的——一集 284 MB 的直链
 * 在手机上要十几分钟，30 秒时直接被判 `Operation timeout` 掐断（文件停在 17 MB）。
 * 因此这里给到 30 分钟；m3u8 的清单与分片仍用上面的 30 秒（单个请求本来就小）。
 */
const SINGLE_FILE_READ_TIMEOUT_MS: number = 30 * 60 * 1000;

/** 一次下载任务在队列里的形态。 */
class QueuedTask {
  request: DownloadRequest = new DownloadRequest();
  /** 是否优先（对应 `enqueuePriority`）。 */
  priority: boolean = false;
}

/**
 * 下载管理器。对应参照实现 `lib/services/download/download_manager.dart`。
 *
 * 与源码一致的几条硬约束：
 *   1. 并发上限：同时下载 **2 集**、每集 **3 个分片**（可用设置覆盖）
 *   2. 分片文件名 `seg_N.ts`（**断点续传就是靠扫这个模式**）
 *   3. 非 m3u8 源直接判失败（源码 `_NotM3u8Exception`）
 *   4. 开始前检查剩余空间 ≥ **100 MB**
 *   5. 去广告在**下载时**做（`adBlockerEnabled`），不是播放时
 *
 * 落盘布局：
 * ```
 * ${filesDir}/download/
 *   records.json                      整表（记录 + 每集状态/进度）
 *   {规则名}_{条目id}/{集数}/
 *     seg_00000.ts ...                分片（可断点续传）
 *     index.m3u8                      指向本地分片的清单（离线播放用）
 *     segments.json                   解析结果（续传时不用重新解析）
 * ```
 *
 * 请求头与代理沿用播放链路的设置：`user-agent` / `referer` 由调用方给出，
 * 代理走 `NetworkConfig.fromSettings()`（与其它接口同一份配置）。
 */
export class DownloadManager {
  private static dir: string = '';
  private static records: DownloadRecord[] = [];
  private static queue: QueuedTask[] = [];
  /** 正在跑的集（键 `${recordKey}_${episodeNumber}`）。 */
  private static running: string[] = [];
  /** 被用户取消的集：跑完当前分片就退出。 */
  private static cancelled: string[] = [];
  private static changeCount: number = 0;
  private static speedBytesPerSecond: number = 0;
  private static lastSpeedSampleAt: number = 0;
  private static lastSpeedSampleBytes: number = 0;

  static init(context: common.UIAbilityContext): void {
    DownloadManager.dir = `${context.filesDir}/download`;
    if (!fileIo.accessSync(DownloadManager.dir)) {
      fileIo.mkdirSync(DownloadManager.dir, true);
    }
    DownloadManager.load();
  }

  // ============================================================
  // 记录读写
  // ============================================================

  static all(): DownloadRecord[] {
    return DownloadManager.records.slice();
  }

  /**
   * 下载根目录（**实际路径**，给设置页只读展示用）。
   *
   * 鸿蒙上这是应用私有目录（`context.filesDir`），文件管理里看不到；
   * 目录结构见类注释：`{根}/{规则名}_{条目id}/{集数}/`。
   */
  static directory(): string {
    return DownloadManager.dir;
  }

  static find(recordKey: string): DownloadRecord | null {
    for (let i = 0; i < DownloadManager.records.length; i++) {
      if (DownloadManager.records[i].key() === recordKey) {
        return DownloadManager.records[i];
      }
    }
    return null;
  }

  static revision(): number {
    return DownloadManager.changeCount;
  }

  static speed(): number {
    return DownloadManager.speedBytesPerSecond;
  }

  /** 下载页顶部的统计。 */
  static stats(): DownloadStats {
    const stats = new DownloadStats();
    stats.recordCount = DownloadManager.records.length;
    for (let i = 0; i < DownloadManager.records.length; i++) {
      const record: DownloadRecord = DownloadManager.records[i];
      for (let j = 0; j < record.episodes.length; j++) {
        const episode: DownloadEpisode = record.episodes[j];
        stats.episodeCount += 1;
        if (episode.status === DownloadStatus.completed) {
          stats.completedCount += 1;
          stats.totalBytes += episode.totalBytes;
        }
        if (episode.status === DownloadStatus.downloading
          || episode.status === DownloadStatus.resolving) {
          stats.runningCount += 1;
        }
      }
    }
    return stats;
  }

  static isDownloading(recordKey: string, episodeNumber: number): boolean {
    const episode: DownloadEpisode | null =
      DownloadManager.episodeOf(recordKey, episodeNumber);
    if (episode === null) {
      return false;
    }
    return episode.status === DownloadStatus.downloading
      || episode.status === DownloadStatus.resolving
      || episode.status === DownloadStatus.pending;
  }

  static episodeOf(recordKey: string, episodeNumber: number): DownloadEpisode | null {
    const record: DownloadRecord | null = DownloadManager.find(recordKey);
    return record === null ? null : record.findEpisode(episodeNumber);
  }

  // ============================================================
  // 入队 / 暂停 / 恢复 / 取消 / 删除
  // ============================================================

  /** 入队（普通）。返回 false 表示这条已经在队列里或已完成。 */
  static enqueue(request: DownloadRequest): boolean {
    return DownloadManager.push(request, false);
  }

  /** 入队（优先，插到队首）。 */
  static enqueuePriority(request: DownloadRequest): boolean {
    return DownloadManager.push(request, true);
  }

  private static push(request: DownloadRequest, priority: boolean): boolean {
    if (request.m3u8Url.length === 0) {
      Logger.warn(TAG, '入队失败：没有解析到 m3u8 地址');
      return false;
    }
    const existing: DownloadEpisode | null =
      DownloadManager.episodeOf(request.recordKey, request.episodeNumber);
    if (existing !== null && existing.status === DownloadStatus.completed) {
      return false;
    }
    const queued: QueuedTask = new QueuedTask();
    queued.request = request;
    queued.priority = priority;
    if (priority) {
      DownloadManager.queue.unshift(queued);
    } else {
      DownloadManager.queue.push(queued);
    }
    // 先落一条 pending 记录，下载页立刻能看到
    const episode: DownloadEpisode = DownloadManager.ensureEpisode(request);
    episode.status = DownloadStatus.pending;
    episode.errorMessage = '';
    episode.networkM3u8Url = request.m3u8Url;
    DownloadManager.persistAndNotify();
    DownloadManager.pump();
    return true;
  }

  /** 暂停：在跑的直接取消当前这轮的循环，状态置为 paused。 */
  static pause(recordKey: string, episodeNumber: number): void {
    const episode: DownloadEpisode | null =
      DownloadManager.episodeOf(recordKey, episodeNumber);
    if (episode === null) {
      return;
    }
    DownloadManager.cancelled.push(`${recordKey}_${episodeNumber}`);
    DownloadManager.removeQueued(recordKey, episodeNumber);
    episode.status = DownloadStatus.paused;
    DownloadManager.persistAndNotify();
    Logger.info(TAG, `暂停下载：${recordKey} 第${episodeNumber}集`);
  }

  /** 恢复：把 paused/failed 的集重新排队（分片已存在的会跳过，即断点续传）。 */
  static resume(recordKey: string, episodeNumber: number): boolean {
    const record: DownloadRecord | null = DownloadManager.find(recordKey);
    if (record === null) {
      return false;
    }
    const episode: DownloadEpisode | null = record.findEpisode(episodeNumber);
    if (episode === null) {
      return false;
    }
    const request = new DownloadRequest();
    request.recordKey = recordKey;
    request.bangumiId = record.bangumiId;
    request.bangumiName = record.bangumiName;
    request.bangumiCover = record.bangumiCover;
    request.pluginName = record.pluginName;
    request.episodeNumber = episodeNumber;
    request.episodeName = episode.episodeName;
    request.road = episode.road;
    request.episodePageUrl = episode.episodePageUrl;
    request.m3u8Url = episode.networkM3u8Url;
    request.adBlockerEnabled = DownloadManager.adBlockerEnabled();
    return DownloadManager.enqueue(request);
  }

  /** 取消：停止并删掉已下载的分片（源码 `cancel` 会清文件）。 */
  static cancel(recordKey: string, episodeNumber: number): void {
    DownloadManager.cancelled.push(`${recordKey}_${episodeNumber}`);
    DownloadManager.removeQueued(recordKey, episodeNumber);
    DownloadManager.deleteEpisodeFiles(recordKey, episodeNumber);
  }

  static pauseAll(): void {
    const keys: string[] = DownloadManager.runningKeys();
    for (let i = 0; i < keys.length; i++) {
      const parts: string[] = keys[i].split('_');
      const episodeNumber: number = Number.parseInt(parts[parts.length - 1], 10);
      const recordKey: string = keys[i].substring(0,
        keys[i].length - `${episodeNumber}`.length - 1);
      DownloadManager.pause(recordKey, episodeNumber);
    }
  }

  static resumeAll(): void {
    for (let i = 0; i < DownloadManager.records.length; i++) {
      const record: DownloadRecord = DownloadManager.records[i];
      for (let j = 0; j < record.episodes.length; j++) {
        const episode: DownloadEpisode = record.episodes[j];
        if (episode.status === DownloadStatus.paused
          || episode.status === DownloadStatus.failed) {
          DownloadManager.resume(record.key(), episode.episodeNumber);
        }
      }
    }
  }

  /** 删除一集的分片目录与记录。 */
  static deleteEpisodeFiles(recordKey: string, episodeNumber: number): void {
    const episodeDir: string =
      DownloadManager.episodeDir(recordKey, episodeNumber);
    DownloadManager.removeDirectory(episodeDir);
    const record: DownloadRecord | null = DownloadManager.find(recordKey);
    if (record === null) {
      return;
    }
    const kept: DownloadEpisode[] = [];
    for (let i = 0; i < record.episodes.length; i++) {
      if (record.episodes[i].episodeNumber !== episodeNumber) {
        kept.push(record.episodes[i]);
      }
    }
    record.episodes = kept;
    if (record.episodes.length === 0) {
      DownloadManager.removeRecord(recordKey);
      return;
    }
    DownloadManager.persistAndNotify();
    Logger.info(TAG, `删除下载：${recordKey} 第${episodeNumber}集`);
  }

  /** 删除整部作品（记录 + 目录）。 */
  static deleteRecordFiles(recordKey: string): void {
    DownloadManager.removeDirectory(`${DownloadManager.dir}/${recordKey}`);
    DownloadManager.removeRecord(recordKey);
    Logger.info(TAG, `删除下载记录：${recordKey}`);
  }

  /** 已完成集的本地清单路径（离线播放用）。 */
  static localPlaylistPath(recordKey: string, episodeNumber: number): string {
    const episode: DownloadEpisode | null =
      DownloadManager.episodeOf(recordKey, episodeNumber);
    if (episode === null || episode.status !== DownloadStatus.completed) {
      return '';
    }
    return episode.localM3u8Path;
  }

  // ============================================================
  // 调度与执行
  // ============================================================

  private static maxParallelEpisodes(): number {
    const value: number =
      SettingsStore.getNumber(SettingsKeys.downloadParallelEpisodes);
    return value > 0 ? Math.round(value) : DEFAULT_MAX_PARALLEL_EPISODES;
  }

  private static maxParallelSegments(): number {
    const value: number =
      SettingsStore.getNumber(SettingsKeys.downloadParallelSegments);
    return value > 0 ? Math.round(value) : DEFAULT_MAX_PARALLEL_SEGMENTS;
  }

  private static adBlockerEnabled(): boolean {
    return SettingsStore.getBool(SettingsKeys.forceAdBlocker);
  }

  /** 有空位就取任务开跑（源码 `_runningCount` + `_queue` 的调度）。 */
  private static pump(): void {
    while (DownloadManager.running.length < DownloadManager.maxParallelEpisodes()
      && DownloadManager.queue.length > 0) {
      const task: QueuedTask | undefined = DownloadManager.queue.shift();
      if (task === undefined) {
        return;
      }
      const key: string =
        `${task.request.recordKey}_${task.request.episodeNumber}`;
      if (DownloadManager.running.indexOf(key) >= 0) {
        continue;
      }
      DownloadManager.running.push(key);
      DownloadManager.runTask(task.request).then(() => {
        DownloadManager.finish(key);
      }).catch((error: Error) => {
        Logger.error(TAG, `下载任务异常：${error.message}`);
        DownloadManager.finish(key);
      });
    }
  }

  private static finish(key: string): void {
    const index: number = DownloadManager.running.indexOf(key);
    if (index >= 0) {
      DownloadManager.running.splice(index, 1);
    }
    const cancelIndex: number = DownloadManager.cancelled.indexOf(key);
    if (cancelIndex >= 0) {
      DownloadManager.cancelled.splice(cancelIndex, 1);
    }
    DownloadManager.pump();
  }

  /** 一集的实际下载：取清单 → 去广告 → 下分片（断点续传）→ 写本地清单。 */
  private static async runTask(request: DownloadRequest): Promise<void> {
    const episode: DownloadEpisode = DownloadManager.ensureEpisode(request);
    const key: string = `${request.recordKey}_${request.episodeNumber}`;
    const episodeDir: string =
      DownloadManager.episodeDir(request.recordKey, request.episodeNumber);

    // 1. 空间检查（源码 `_checkStorageSpace`）
    const free: number = DownloadManager.freeBytes(episodeDir);
    if (free >= 0 && free < MIN_REQUIRED_SPACE_BYTES) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage = '存储空间不足';
      DownloadManager.persistAndNotify();
      return;
    }

    episode.status = DownloadStatus.resolving;
    episode.errorMessage = '';
    DownloadManager.persistAndNotify();

    const headers: Record<string, string> = DownloadManager.defaultHeaders(request);
    try {
      // 0. 不是 m3u8（例如直链 mp4）→ 走单文件下载分支
      if (!M3u8Parser.isM3u8Url(request.m3u8Url)) {
        await DownloadManager.downloadSingleFile(request, episode, episodeDir,
          headers);
        return;
      }
      // 2. 取清单：master 就挑码率最高的一路
      const firstText: string = await DownloadManager.fetchText(request.m3u8Url, headers);
      let mediaUrl: string = request.m3u8Url;
      let mediaText: string = firstText;
      if (M3u8Parser.detectType(firstText) === 0) {
        const master: M3u8MasterPlaylist =
          M3u8Parser.parseMasterPlaylist(firstText, request.m3u8Url);
        const best: M3u8Variant | null = master.bestVariant();
        if (best === null) {
          throw new Error('主清单里没有可用码率');
        }
        mediaUrl = best.uri;
        mediaText = await DownloadManager.fetchText(mediaUrl, headers);
      }

      // 3. 解析切片 + 去广告 + 展开嵌套
      const playlist: M3u8MediaPlaylist =
        M3u8Parser.parseMediaPlaylist(mediaText, mediaUrl);
      if (playlist.segments.length === 0) {
        throw new Error('清单里没有切片（可能不是 m3u8 源）');
      }
      let segments: M3u8Segment[] = playlist.segments;
      if (request.adBlockerEnabled) {
        const before: number = segments.length;
        segments = M3u8AdFilter.filterAds(segments);
        if (segments.length !== before) {
          Logger.info(TAG, `去广告：${before} → ${segments.length} 个切片`);
        }
      }
      segments = await M3u8Parser.resolveNestedSegments(segments,
        (url: string) => DownloadManager.fetchText(url, headers), 3);

      // 4. 建目录 + 落解析结果（续传时直接用，不必重新解析）
      DownloadManager.ensureDirectory(episodeDir);
      DownloadManager.writeSegmentsCache(episodeDir, segments);
      episode.totalSegments = segments.length;
      episode.downloadedSegments = 0;
      episode.status = DownloadStatus.downloading;
      DownloadManager.persistAndNotify();

      // 5. 下分片（并发 = downloadParallelSegments，已存在的跳过）
      const total: number = segments.length;
      let nextIndex: number = 0;
      let done: number = 0;
      DownloadManager.resetSpeedSample();
      const worker = async (): Promise<void> => {
        while (true) {
          if (DownloadManager.cancelled.indexOf(key) >= 0) {
            return;
          }
          const index: number = nextIndex;
          nextIndex += 1;
          if (index >= total) {
            return;
          }
          const path: string = `${episodeDir}/${M3u8Parser.segmentFileName(index)}`;
          try {
            if (!DownloadManager.fileHasContent(path)) {
              const bytes: ArrayBuffer =
                await DownloadManager.fetchBytes(segments[index].uri, headers);
              DownloadManager.writeBytes(path, bytes);
              episode.totalBytes += bytes.byteLength;
            } else {
              episode.totalBytes += DownloadManager.fileSize(path);
            }
            done += 1;
            episode.downloadedSegments = done;
            episode.progressPercent = Math.floor(done * 100 / total);
            DownloadManager.updateSpeed(episode.totalBytes);
            DownloadManager.notify();
          } catch (error) {
            const err = error as Error;
            // 单个分片失败不整集失败：记下来，用户点「继续」时会重试缺失的分片
            Logger.warn(TAG, `分片失败 ${index}：${err.message}`);
            episode.errorMessage = `第 ${index + 1} 个分片失败，可继续重试`;
          }
        }
      };
      const workers: Promise<void>[] = [];
      const parallel: number = DownloadManager.maxParallelSegments();
      for (let i = 0; i < parallel; i++) {
        workers.push(worker());
      }
      for (let i = 0; i < workers.length; i++) {
        await workers[i];
      }

      if (DownloadManager.cancelled.indexOf(key) >= 0) {
        return;
      }

      // 6. 写本地清单；只有分片齐了才算完成
      if (done >= total) {
        const manifest: string = M3u8Parser.buildLocalM3u8(segments,
          M3u8AdFilter.calculateTargetDuration(segments), new Map<string, string>());
        DownloadManager.writeText(`${episodeDir}/index.m3u8`, manifest);
        episode.localM3u8Path = `${episodeDir}/index.m3u8`;
        episode.downloadDirectory = episodeDir;
        episode.status = DownloadStatus.completed;
        episode.progressPercent = 100;
        episode.completedAt = Date.now();
        episode.errorMessage = '';
        Logger.info(TAG,
          `下载完成：${request.recordKey} 第${request.episodeNumber}集 · ${total} 个切片 · ${episode.totalBytes} 字节`);
      } else {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = `有 ${total - done} 个分片没下完，点「继续」可断点续传`;
      }
      DownloadManager.persistAndNotify();
    } catch (error) {
      const err = error as Error;
      episode.status = DownloadStatus.failed;
      episode.errorMessage = err.message;
      DownloadManager.persistAndNotify();
      Logger.error(TAG, `下载失败：${err.message}`);
    }
  }

  /**
   * 单文件源（直链 mp4 / flv 等）的下载。
   *
   * 为什么需要它：真实源里有一大类是**直链视频文件**而不是 HLS 切片
   * （实测 aafun 的「与奔驰于透明之夜的你…」第 3 集就是
   * `https://apn.moedot.net/d/wo/2607/奔驰03.mp4`）。参照实现在这里会抛
   * `_NotM3u8Exception` 直接判失败，但既然我们已经在播这个地址，
   * 把它下下来才是用户预期的「缓存本集」。因此这里用**流式**写入，
   * 边收边落盘（不把整部视频读进内存），进度按字节算。
   *
   * 完成后 `localM3u8Path` 指向这个文件本身——离线播放只需要一个
   * mpv 能打开的本地路径，mp4 与本地 m3u8 对它没有区别。
   */
  private static async downloadSingleFile(request: DownloadRequest,
    episode: DownloadEpisode, episodeDir: string,
    headers: Record<string, string>): Promise<void> {
    const key: string = `${request.recordKey}_${request.episodeNumber}`;
    DownloadManager.ensureDirectory(episodeDir);
    const filePath: string = `${episodeDir}/video${DownloadManager.extensionOf(request.m3u8Url)}`;

    // 断点续传的**可信条件**：磁盘上的字节数必须等于记录里记的已下字节数。
    //
    // 为什么不能只看「文件存在且非空」：上一次失败可能在磁盘上留下的是
    // **错误响应体**（实测防盗链回 12 字节），把它当半成品续传，
    // 下出来的文件会缺开头一段——看起来下完了，其实播不了。
    // 只有「正常取消/暂停」才会让磁盘字节数与记录的 totalBytes 相等；
    // 不相等就从头下（OpenMode.TRUNC 会覆盖旧文件）。
    const existingBytes: number = DownloadManager.fileSize(filePath);
    const resumeFrom: number = (existingBytes > 0
      && existingBytes === episode.totalBytes) ? existingBytes : 0;
    if (existingBytes > 0 && resumeFrom === 0) {
      Logger.warn(TAG, `磁盘上的 ${existingBytes} 字节与记录不符，改为重新下载`);
    }

    episode.status = DownloadStatus.downloading;
    episode.totalSegments = 1;
    episode.downloadedSegments = 0;
    episode.errorMessage = '';
    DownloadManager.persistAndNotify();
    DownloadManager.resetSpeedSample();

    const url: string = DownloadManager.encodeUrl(request.m3u8Url);
    const client = http.createHttp();
    let handle: fileIo.File | null = null;
    try {
      // 先按「续写」打开；如果服务器忽略了 Range（没回 content-range），
      // 第一个数据块到了以后立刻改成「从头写」，避免把两个版本拼坏。
      const mode: number = resumeFrom > 0
        ? (fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND)
        : (fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      handle = fileIo.openSync(filePath, mode);
      let received: number = resumeFrom;
      let contentLength: number = 0;
      let ranged: boolean = false;
      let truncated: boolean = resumeFrom === 0;
      client.on('headersReceive', (header: Object) => {
        const rec: Record<string, Object> | null = asRecord(header);
        if (rec === null) {
          return;
        }
        if (rec['content-length'] !== undefined) {
          const value: number = Number(rec['content-length']);
          contentLength = Number.isNaN(value) ? 0 : value;
        }
        if (rec['content-range'] !== undefined) {
          ranged = true;
        }
      });
      client.on('dataReceive', (data: ArrayBuffer) => {
        if (!truncated && !ranged) {
          // 服务器把整个文件重发了：丢掉半成品，从头写
          const old: fileIo.File | null = handle;
          try {
            if (old !== null) {
              fileIo.closeSync(old);
            }
          } catch (error) {
            // 关不上就忽略，下面会重新打开覆盖
          }
          try {
            handle = fileIo.openSync(filePath,
              fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
          } catch (error) {
            const err = error as Error;
            Logger.warn(TAG, `重开文件失败：${err.message}`);
          }
          received = 0;
          truncated = true;
        }
        const writer: fileIo.File | null = handle;
        if (writer !== null) {
          try {
            fileIo.writeSync(writer.fd, data);
          } catch (error) {
            const err = error as Error;
            Logger.warn(TAG, `写入分片失败：${err.message}`);
          }
        }
        received += data.byteLength;
        episode.totalBytes = received;
        episode.progressPercent = contentLength > 0
          ? Math.min(99, Math.floor(received * 100 / contentLength)) : 0;
        DownloadManager.updateSpeed(received);
        DownloadManager.notify();
      });

      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: DOWNLOAD_CONNECT_TIMEOUT_MS,
        // 单文件要长超时：见 `SINGLE_FILE_READ_TIMEOUT_MS` 的注释
        readTimeout: SINGLE_FILE_READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      };
      if (resumeFrom > 0) {
        (options.header as Record<string, string>)['range'] =
          `bytes=${resumeFrom}-`;
      }
      const proxy: http.HttpProxy | undefined = DownloadManager.proxyOptions();
      if (proxy !== undefined) {
        options.usingProxy = proxy;
      }
      const code: number = await client.requestInStream(url, options);
      if (DownloadManager.cancelled.indexOf(key) >= 0) {
        return;
      }
      if ((code === 200 || code === 206) && received > 0) {
        episode.localM3u8Path = filePath;
        episode.downloadDirectory = episodeDir;
        episode.status = DownloadStatus.completed;
        episode.progressPercent = 100;
        episode.downloadedSegments = 1;
        episode.completedAt = Date.now();
        episode.errorMessage = '';
        Logger.info(TAG,
          `下载完成（单文件）：第${request.episodeNumber}集 · ${received} 字节`);
      } else {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = received > 0
          ? `只收到 ${received} 字节（HTTP ${code}）` : `HTTP ${code}`;
        // 失败时留下的文件**不可信**（可能是错误响应体，例如防盗链回的 12 字节），
        // 留着会被下次的 Range 续传当成「已下部分」拼进正片，所以直接删掉。
        try {
          if (handle !== null) {
            fileIo.closeSync(handle);
            handle = null;
          }
          fileIo.unlinkSync(filePath);
        } catch (error) {
          // 删不掉就交给下次的 TRUNC 覆盖
        }
        Logger.error(TAG, `单文件下载失败：HTTP ${code}`);
      }
      DownloadManager.persistAndNotify();
    } catch (error) {
      const err = error as Error;
      episode.status = DownloadStatus.failed;
      episode.errorMessage = err.message;
      DownloadManager.persistAndNotify();
      Logger.error(TAG, `单文件下载异常：${err.message}`);
    } finally {
      try {
        client.off('dataReceive');
        client.off('headersReceive');
      } catch (error) {
        // 取消监听失败不影响结果
      }
      client.destroy();
      if (handle !== null) {
        try {
          fileIo.closeSync(handle);
        } catch (error) {
          // 已经关过就忽略
        }
      }
    }
  }

  /** 从地址里取扩展名（默认 .mp4）。 */
  private static extensionOf(url: string): string {
    const query: number = url.indexOf('?');
    const clean: string = query < 0 ? url : url.substring(0, query);
    const slash: number = clean.lastIndexOf('/');
    const name: string = slash < 0 ? clean : clean.substring(slash + 1);
    const dot: number = name.lastIndexOf('.');
    if (dot < 0 || dot === name.length - 1) {
      return '.mp4';
    }
    const ext: string = name.substring(dot).toLowerCase();
    return ext.length > 6 ? '.mp4' : ext;
  }

  /**
   * 规范化请求地址。
   *
   * 真实源里常见**路径带中文**的直链（实测 `…/2607/奔驰03.mp4`），
   * 未编码地交给网络库会直接失败。`encodeURI` 只编码非 ASCII 与空格，
   * 保留 `:/?&=#` 这些结构字符，正是这里需要的。
   */
  private static encodeUrl(url: string): string {
    try {
      return encodeURI(url);
    } catch (error) {
      return url;
    }
  }

  // ============================================================
  // 网络
  // ============================================================

  /**
   * 下载请求头。
   *
   * **referer 只在同源时才带**——这是实测出来的硬规矩：
   * aafun 那一集的媒体在第三方 CDN（`apn.moedot.net`），而剧集页在
   * `www.moonci.com`，带上跨站 referer 会被防盗链直接判 **400**（响应体只有 12 字节）；
   * 不带 referer 同一个地址是 **200**（284 MB 正常下载）。
   * 反过来，媒体与剧集页同源时（多数规则站点就是这种）带上 referer 才是对的，
   * 所以这里按「host 相同才带」处理，而不是一刀切地删掉。
   *
   * user-agent 沿用播放链路的做法：调用方没给就用内置的浏览器 UA。
   */
  private static defaultHeaders(request: DownloadRequest): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['user-agent'] = 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36';
    if (request.episodePageUrl.length > 0
      && DownloadManager.sameHost(request.episodePageUrl, request.m3u8Url)) {
      headers['referer'] = request.episodePageUrl;
    }
    return headers;
  }

  /** 两个地址是否同 host（下载要不要带 referer 靠它判断）。 */
  private static sameHost(a: string, b: string): boolean {
    const left: UrlParts | null = UrlParts.parse(a);
    const right: UrlParts | null = UrlParts.parse(b);
    if (left === null || right === null) {
      return false;
    }
    return left.host.toLowerCase() === right.host.toLowerCase();
  }

  private static proxyOptions(): http.HttpProxy | undefined {
    const config: NetworkConfig = NetworkConfig.fromSettings();
    if (!config.hasProxy) {
      return undefined;
    }
    const proxy: http.HttpProxy = {
      host: config.proxyHost,
      port: config.proxyPort,
      exclusionList: []
    };
    return proxy;
  }

  private static async fetchText(url: string,
    headers: Record<string, string>): Promise<string> {
    const client = http.createHttp();
    try {
      const target: string = DownloadManager.encodeUrl(url);
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: DOWNLOAD_CONNECT_TIMEOUT_MS,
        readTimeout: DOWNLOAD_RECEIVE_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      };
      const proxy: http.HttpProxy | undefined = DownloadManager.proxyOptions();
      if (proxy !== undefined) {
        options.usingProxy = proxy;
      }
      const response: http.HttpResponse = await client.request(target, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      return `${response.result}`;
    } finally {
      client.destroy();
    }
  }

  private static async fetchBytes(url: string,
    headers: Record<string, string>): Promise<ArrayBuffer> {
    const client = http.createHttp();
    try {
      const target: string = DownloadManager.encodeUrl(url);
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: DOWNLOAD_CONNECT_TIMEOUT_MS,
        readTimeout: DOWNLOAD_RECEIVE_TIMEOUT_MS,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      };
      const proxy: http.HttpProxy | undefined = DownloadManager.proxyOptions();
      if (proxy !== undefined) {
        options.usingProxy = proxy;
      }
      const response: http.HttpResponse = await client.request(target, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      const result: Object = response.result;
      if (result instanceof ArrayBuffer) {
        return result as ArrayBuffer;
      }
      // 有的源对分片回了文本（重定向页等），这里直接判失败而不是写坏文件
      throw new Error('分片返回的不是二进制内容');
    } finally {
      client.destroy();
    }
  }

  // ============================================================
  // 文件
  // ============================================================

  private static episodeDir(recordKey: string, episodeNumber: number): string {
    return `${DownloadManager.dir}/${recordKey}/${episodeNumber}`;
  }

  private static ensureDirectory(path: string): void {
    if (!fileIo.accessSync(path)) {
      fileIo.mkdirSync(path, true);
    }
  }

  private static fileHasContent(path: string): boolean {
    if (!fileIo.accessSync(path)) {
      return false;
    }
    try {
      return fileIo.statSync(path).size > 0;
    } catch (error) {
      return false;
    }
  }

  private static fileSize(path: string): number {
    try {
      return fileIo.statSync(path).size;
    } catch (error) {
      return 0;
    }
  }

  private static writeBytes(path: string, bytes: ArrayBuffer): void {
    const file = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, bytes);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static writeText(path: string, text: string): void {
    const file = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static readText(path: string): string {
    if (!fileIo.accessSync(path)) {
      return '';
    }
    const stat = fileIo.statSync(path);
    const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const read: number = fileIo.readSync(file.fd, buffer);
      return new util.TextDecoder().decodeToString(
        new Uint8Array(buffer, 0, read));
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static removeDirectory(path: string): void {
    if (!fileIo.accessSync(path)) {
      return;
    }
    try {
      fileIo.rmdirSync(path);
    } catch (error) {
      // 目录里还有文件时 rmdirSync 会失败：逐个删掉再删目录
      try {
        const names: string[] = fileIo.listFileSync(path);
        for (let i = 0; i < names.length; i++) {
          fileIo.unlinkSync(`${path}/${names[i]}`);
        }
        fileIo.rmdirSync(path);
      } catch (inner) {
        Logger.warn(TAG, `删除目录失败：${path}`);
      }
    }
  }

  private static freeBytes(path: string): number {
    try {
      DownloadManager.ensureDirectory(path);
      return statfs.getFreeSizeSync(path);
    } catch (error) {
      const err = error as Error;
      Logger.warn(TAG, `剩余空间查询失败：${err.message}`);
      return -1;
    }
  }

  private static writeSegmentsCache(episodeDir: string,
    segments: M3u8Segment[]): void {
    const list: Object[] = [];
    for (let i = 0; i < segments.length; i++) {
      const rec: Record<string, Object> = {};
      rec['uri'] = segments[i].uri;
      rec['duration'] = segments[i].duration;
      rec['group'] = segments[i].discontinuityGroup;
      list.push(rec);
    }
    DownloadManager.writeText(`${episodeDir}/segments.json`, JSON.stringify(list));
  }

  // ============================================================
  // 速度 / 通知 / 持久化
  // ============================================================

  private static resetSpeedSample(): void {
    DownloadManager.lastSpeedSampleAt = Date.now();
    DownloadManager.lastSpeedSampleBytes = 0;
    DownloadManager.speedBytesPerSecond = 0;
  }

  /** 每 3 秒按已下字节差算一次速度（源码 `_SpeedTracker` 的作用）。 */
  private static updateSpeed(totalBytes: number): void {
    const now: number = Date.now();
    const elapsed: number = now - DownloadManager.lastSpeedSampleAt;
    if (elapsed < 3000) {
      return;
    }
    const delta: number = totalBytes - DownloadManager.lastSpeedSampleBytes;
    DownloadManager.speedBytesPerSecond = Math.round(delta * 1000 / elapsed);
    DownloadManager.lastSpeedSampleAt = now;
    DownloadManager.lastSpeedSampleBytes = totalBytes;
  }

  private static ensureEpisode(request: DownloadRequest): DownloadEpisode {
    let record: DownloadRecord | null = DownloadManager.find(request.recordKey);
    if (record === null) {
      record = new DownloadRecord();
      record.bangumiId = request.bangumiId;
      record.bangumiName = request.bangumiName;
      record.bangumiCover = request.bangumiCover;
      record.pluginName = request.pluginName;
      record.createdAt = Date.now();
      DownloadManager.records.push(record);
    }
    let episode: DownloadEpisode | null = record.findEpisode(request.episodeNumber);
    if (episode === null) {
      episode = new DownloadEpisode();
      episode.episodeNumber = request.episodeNumber;
      episode.episodeName = request.episodeName;
      episode.road = request.road;
      episode.episodePageUrl = request.episodePageUrl;
      record.episodes.push(episode);
    }
    return episode;
  }

  private static removeQueued(recordKey: string, episodeNumber: number): void {
    const kept: QueuedTask[] = [];
    for (let i = 0; i < DownloadManager.queue.length; i++) {
      const task: QueuedTask = DownloadManager.queue[i];
      if (task.request.recordKey !== recordKey
        || task.request.episodeNumber !== episodeNumber) {
        kept.push(task);
      }
    }
    DownloadManager.queue = kept;
  }

  private static removeRecord(recordKey: string): void {
    const kept: DownloadRecord[] = [];
    for (let i = 0; i < DownloadManager.records.length; i++) {
      if (DownloadManager.records[i].key() !== recordKey) {
        kept.push(DownloadManager.records[i]);
      }
    }
    DownloadManager.records = kept;
    DownloadManager.persistAndNotify();
  }

  private static runningKeys(): string[] {
    return DownloadManager.running.slice();
  }

  private static load(): void {
    DownloadManager.records = [];
    const path: string = `${DownloadManager.dir}/records.json`;
    const text: string = DownloadManager.readText(path);
    if (text.length === 0) {
      Logger.info(TAG, '下载记录为空');
      return;
    }
    try {
      const parsed: Object = JSON.parse(text) as Object;
      if (!Array.isArray(parsed)) {
        return;
      }
      const list: Object[] = parsed as Object[];
      for (let i = 0; i < list.length; i++) {
        const rec: Record<string, Object> | null = asRecord(list[i]);
        if (rec !== null) {
          DownloadManager.records.push(downloadRecordFromJson(rec));
        }
      }
      Logger.info(TAG, `下载记录载入 ${DownloadManager.records.length} 条`);
    } catch (error) {
      const err = error as Error;
      Logger.error(TAG, `下载记录读取失败：${err.message}`);
    }
  }

  private static persist(): void {
    const list: Object[] = [];
    for (let i = 0; i < DownloadManager.records.length; i++) {
      list.push(downloadRecordToJson(DownloadManager.records[i]));
    }
    try {
      DownloadManager.writeText(`${DownloadManager.dir}/records.json`,
        JSON.stringify(list));
    } catch (error) {
      const err = error as Error;
      Logger.error(TAG, `下载记录保存失败：${err.message}`);
    }
  }

  private static persistAndNotify(): void {
    DownloadManager.persist();
    DownloadManager.notify();
  }

  /** 变更版本号：下载页订阅 `AppStorage.downloadRevision` 刷新。 */
  private static notify(): void {
    DownloadManager.changeCount += 1;
    AppStorage.setOrCreate('downloadRevision', DownloadManager.changeCount);
  }
}

/** 本地的小工具：把 JSON 值收成表。 */
function asRecord(value: Object): Record<string, Object> | null {
  if (value === null || value === undefined || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, Object>;
}
