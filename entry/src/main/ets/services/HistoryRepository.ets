import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BangumiItem } from '../model/BangumiItem';
import {
  HistoryEntry,
  HistoryEntryKind,
  HistoryProgress,
  PlaybackHistoryIdentity,
  historyFromJson,
  historyToJson
} from '../model/HistoryModels';
import { SettingsKeys } from './storage/SettingsKeys';
import { SettingsStore } from './storage/SettingsStore';
import { Logger } from './Logger';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnHistory';

/**
 * 播放历史仓储。对应参照实现 `lib/repositories/history_repository.dart`。
 *
 * 落盘：`${filesDir}/history/histories.json`（整表一个文件）。
 * 上游用 Hive 盒子，原生版沿用 `CollectStore` / `SearchHistoryStore`
 * 同一套做法：整表读写、按 key 覆盖。语义保持一致，只是存储介质不同。
 *
 * 与源码逐条对齐的行为：
 *   1. `getAllHistories()`：按 key 去重、保留 `lastWatchTime` 更晚的那条、
 *      按时间降序；任何异常只记日志并返回空列表（不向上抛）。
 *   2. `updateHistory()`：距结尾 5 秒以内视为已看完，**进度归零**
 *      （`nearEndWatchedThreshold`），而不是保存「快看完了」。
 *   3. 隐私模式（`privateMode`）下不写入。
 *   4. 在线记录会顺手清掉旧版键（`规则名+id`），避免新旧两条并存的脏数据。
 */
export class HistoryRepository {
  /** 源码 `nearEndWatchedThreshold = Duration(seconds: 5)`。 */
  static readonly nearEndWatchedThresholdMs: number = 5000;

  private static entries: HistoryEntry[] = [];
  private static dir: string = '';
  private static loaded: boolean = false;
  /** 变更版本号：页面订阅 `AppStorage.historyRevision` 刷新，与主题同一套机制。 */
  private static changeCount: number = 0;

  static init(context: common.UIAbilityContext): void {
    HistoryRepository.dir = `${context.filesDir}/history`;
    if (!fileIo.accessSync(HistoryRepository.dir)) {
      fileIo.mkdirSync(HistoryRepository.dir, true);
    }
    HistoryRepository.load();
  }

  static revision(): number {
    return HistoryRepository.changeCount;
  }

  private static bump(): void {
    HistoryRepository.changeCount += 1;
    AppStorage.setOrCreate('historyRevision', HistoryRepository.changeCount);
  }

  /** 读取整表。顺序与去重规则见 §60.1。 */
  static load(): void {
    HistoryRepository.entries = [];
    const path: string = `${HistoryRepository.dir}/histories.json`;
    if (fileIo.accessSync(path)) {
      try {
        const stat = fileIo.statSync(path);
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
        let text: string = '';
        try {
          const read: number = fileIo.readSync(file.fd, buffer);
          text = new util.TextDecoder().decodeToString(
            new Uint8Array(buffer, 0, read));
        } finally {
          fileIo.closeSync(file);
        }
        const parsed: Object = JSON.parse(text) as Object;
        if (Array.isArray(parsed)) {
          const list: Object[] = parsed as Object[];
          for (let i = 0; i < list.length; i++) {
            const raw: Object = list[i];
            if (raw === undefined || raw === null || Array.isArray(raw)) {
              continue;
            }
            HistoryRepository.entries.push(
              historyFromJson(raw as Record<string, Object>));
          }
        }
      } catch (e) {
        const err = e as Error;
        hilog.error(DOMAIN, TAG, '历史读取失败: %{public}s', err.message);
        HistoryRepository.entries = [];
      }
    }
    HistoryRepository.dedupe();
    HistoryRepository.loaded = true;
    hilog.info(DOMAIN, TAG, '历史载入 %{public}d 条',
      HistoryRepository.entries.length);
  }

  static isLoaded(): boolean {
    return HistoryRepository.loaded;
  }

  /** 全部记录：去重后按时间倒序。 */
  static getAll(): HistoryEntry[] {
    HistoryRepository.dedupe();
    return HistoryRepository.entries.slice();
  }

  /** 查一条记录（先按新键，再回落旧键，与源码 `_findHistory` 一致）。 */
  static getHistory(adapterName: string, item: BangumiItem,
    entryKind: string): HistoryEntry | undefined {
    const kind: string = HistoryEntryKind.normalize(entryKind);
    for (let i = 0; i < HistoryRepository.entries.length; i++) {
      const entry: HistoryEntry = HistoryRepository.entries[i];
      if (entry.adapterName === adapterName && entry.bangumiItem.id === item.id
        && HistoryEntryKind.normalize(entry.entryKind) === kind) {
        return entry;
      }
    }
    if (kind === HistoryEntryKind.online) {
      // 旧版键（不含来源后缀）落在哪条记录上，直接返回它
      for (let i = 0; i < HistoryRepository.entries.length; i++) {
        const entry: HistoryEntry = HistoryRepository.entries[i];
        if (entry.adapterName === adapterName && entry.bangumiItem.id === item.id) {
          return entry;
        }
      }
    }
    return undefined;
  }

  /**
   * 写入（或更新）一条观看记录。
   *
   * @param progressMs 当前进度；`durationMs` 为 0 表示时长未知，不做「快看完归零」判断。
   */
  static updateHistory(identity: PlaybackHistoryIdentity, progressMs: number,
    durationMs: number): void {
    if (!identity.canRecord()) {
      return;
    }
    // 没有 Bangumi 条目 id 的播放（例如从「多插件并发搜索」直接进播放页）不入库：
    // 那种记录会共用 `id=0` 的键，把不同番剧的进度混成一条，
    // 「继续观看」也就指不回正确的条目。
    if (identity.bangumiItem.id <= 0) {
      return;
    }
    if (HistoryRepository.privateMode()) {
      return;
    }
    let effectiveProgress: number = progressMs < 0 ? 0 : progressMs;
    if (durationMs > 0
      && effectiveProgress >= durationMs - HistoryRepository.nearEndWatchedThresholdMs) {
      effectiveProgress = 0;
    }

    const kind: string = HistoryEntryKind.normalize(identity.entryKind);
    const now: number = Date.now();
    let entry: HistoryEntry | undefined = HistoryRepository.getHistory(
      identity.pluginName, identity.bangumiItem, kind);
    if (entry === undefined) {
      entry = new HistoryEntry();
      entry.bangumiItem = identity.bangumiItem;
      entry.adapterName = identity.pluginName;
      entry.lastWatchTime = now;
      entry.lastSrc = identity.onlineBangumiSrc;
      entry.lastWatchEpisodeName = identity.episodeTitle;
      entry.entryKind = kind;
      entry.episodePageUrl = identity.episodePageUrl;
      HistoryRepository.entries.push(entry);
    }

    entry.bangumiItem = identity.bangumiItem;
    entry.lastWatchEpisode = identity.episodeNumber;
    entry.lastWatchTime = now;
    entry.entryKind = kind;
    if (identity.onlineBangumiSrc.length > 0) {
      entry.lastSrc = identity.onlineBangumiSrc;
    }
    if (identity.episodeTitle.length > 0) {
      entry.lastWatchEpisodeName = identity.episodeTitle;
    }
    if (identity.episodePageUrl.length > 0) {
      entry.episodePageUrl = identity.episodePageUrl;
    }

    const existing: HistoryProgress | undefined =
      entry.progresses.get(identity.episodeNumber);
    if (existing === undefined) {
      entry.progresses.set(identity.episodeNumber, new HistoryProgress(
        identity.episodeNumber, identity.road, effectiveProgress, now));
    } else {
      existing.road = identity.road;
      existing.progressMs = effectiveProgress;
      existing.updatedAtMs = now;
    }

    HistoryRepository.dedupe();
    HistoryRepository.persist();
    HistoryRepository.bump();
    hilog.info(DOMAIN, TAG,
      '记录观看: %{public}s 第%{public}d集 进度%{public}dms',
      identity.bangumiItem.displayName(), identity.episodeNumber,
      Math.round(effectiveProgress));
    Logger.info(TAG, `记录观看：${identity.bangumiItem.displayName()} 第${identity.episodeNumber}集 ` +
      `进度 ${Math.round(effectiveProgress / 1000)}s（${identity.pluginName}）`);
  }

  /** 上次观看的进度（`getLastWatchingProgress`）。 */
  static getLastWatchingProgress(item: BangumiItem, adapterName: string,
    entryKind: string): HistoryProgress | undefined {
    const entry: HistoryEntry | undefined =
      HistoryRepository.getHistory(adapterName, item, entryKind);
    if (entry === undefined) {
      return undefined;
    }
    return entry.progresses.get(entry.lastWatchEpisode);
  }

  /** 指定集数的进度（`findProgress`，详情页「继续观看」用）。 */
  static findProgress(item: BangumiItem, adapterName: string, episode: number,
    entryKind: string): HistoryProgress | undefined {
    const entry: HistoryEntry | undefined =
      HistoryRepository.getHistory(adapterName, item, entryKind);
    if (entry === undefined) {
      return undefined;
    }
    return entry.progresses.get(episode);
  }

  /** 删除一条（在线记录顺带清掉旧版键）。 */
  static deleteHistory(entry: HistoryEntry): void {
    const key: string = entry.key();
    const legacy: string = entry.legacyKey();
    HistoryRepository.entries = HistoryRepository.entries.filter(
      (item: HistoryEntry) => {
        if (item.key() === key) {
          return false;
        }
        return !(HistoryEntryKind.normalize(item.entryKind) === HistoryEntryKind.online
          && item.legacyKey() === legacy);
      });
    HistoryRepository.persist();
    HistoryRepository.bump();
    hilog.info(DOMAIN, TAG, '删除历史: %{public}s', entry.displayName());
    Logger.info(TAG, `删除历史：${entry.displayName()}（${entry.adapterName}）`);
  }

  /**
   * 原样写入一条记录（不重写 `lastWatchTime`）。
   *
   * 两个用途：
   *   1. 同步（§19）合并快照时，必须保留事件里的时间戳与来源标记，
   *      不能像 `updateHistory` 那样把时间改成「现在」；
   *   2. 自检 / 演示数据需要构造「昨天」「三天前」这类记录。
   */
  static upsert(entry: HistoryEntry): void {
    if (entry.adapterName.length === 0 || entry.bangumiItem.id === 0) {
      return;
    }
    const key: string = entry.key();
    let replaced: boolean = false;
    for (let i = 0; i < HistoryRepository.entries.length; i++) {
      if (HistoryRepository.entries[i].key() === key) {
        HistoryRepository.entries[i] = entry;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      HistoryRepository.entries.push(entry);
    }
    HistoryRepository.dedupe();
    HistoryRepository.persist();
    HistoryRepository.bump();
  }

  static clearAll(): void {
    HistoryRepository.entries = [];
    HistoryRepository.persist();
    HistoryRepository.bump();
    hilog.info(DOMAIN, TAG, '已清空全部历史');
    Logger.info(TAG, '已清空全部历史记录');
  }

  /**
   * 用云同步合并后的结果一次性替换全部历史。
   *
   * 与历史逐条写入不同，这里保留记录内部的原始时间戳，不做「接近结尾归零」
   * 等播放期规则；这些规则在播放页写入时已经执行过。
   */
  static replaceAll(entries: HistoryEntry[]): void {
    HistoryRepository.entries = entries.slice();
    HistoryRepository.dedupe();
    HistoryRepository.persist();
    HistoryRepository.bump();
  }

  /** 「最近在看」行（§4.x）：取时间最新的一条。 */
  static latest(): HistoryEntry | undefined {
    const all: HistoryEntry[] = HistoryRepository.getAll();
    if (all.length === 0) {
      return undefined;
    }
    return all[0];
  }

  private static dedupe(): void {
    const byKey: Map<string, HistoryEntry> = new Map<string, HistoryEntry>();
    for (let i = 0; i < HistoryRepository.entries.length; i++) {
      const entry: HistoryEntry = HistoryRepository.entries[i];
      entry.entryKind = HistoryEntryKind.normalize(entry.entryKind);
      const key: string = entry.key();
      const existing: HistoryEntry | undefined = byKey.get(key);
      if (existing === undefined || existing.lastWatchTime < entry.lastWatchTime) {
        byKey.set(key, entry);
      }
    }
    const out: HistoryEntry[] = [];
    byKey.forEach((entry: HistoryEntry) => {
      out.push(entry);
    });
    out.sort((a: HistoryEntry, b: HistoryEntry) =>
      b.lastWatchTime - a.lastWatchTime);
    HistoryRepository.entries = out;
  }

  private static privateMode(): boolean {
    try {
      return SettingsStore.getBool(SettingsKeys.privateMode);
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '读取隐私模式失败: %{public}s', err.message);
      return false;
    }
  }

  private static persist(): void {
    const array: Object[] = [];
    for (let i = 0; i < HistoryRepository.entries.length; i++) {
      array.push(historyToJson(HistoryRepository.entries[i]) as Object);
    }
    const path: string = `${HistoryRepository.dir}/histories.json`;
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(array));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '历史保存失败: %{public}s', err.message);
    }
  }
}
