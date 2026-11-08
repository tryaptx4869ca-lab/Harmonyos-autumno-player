import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsKeys } from '../storage/SettingsKeys';
import { SettingsStore } from '../storage/SettingsStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnSearch';

/** 一条搜索历史（参照实现 `modules/search/search_history_module.dart`）。 */
export class SearchHistoryEntry {
  keyword: string = '';
  /** 毫秒时间戳，同时充当记录的主键（参照实现用 `timestamp.toString()`）。 */
  timestamp: number = 0;

  constructor(keyword: string = '', timestamp: number = 0) {
    this.keyword = keyword;
    this.timestamp = timestamp;
  }
}

/**
 * 搜索历史存储。
 *
 * 参照实现把历史放在 Hive 的 `search_history` 盒子里，原生版沿用
 * `CollectStore` 的落盘方式：`${filesDir}/search/search_history.json`。
 * 语义与 `SearchHistoryRepository` 一致：
 *   - 按时间戳倒序读取
 *   - 上限 10 条，写满先删最旧
 *   - 同关键词先清重再写，保证「最近一次」排在最前
 *   - 隐私模式（`privateMode`）下不记录
 */
export class SearchHistoryStore {
  /** 上限：参照实现 `isHistoryFull(10)`。 */
  private static readonly maxCount: number = 10;
  private static entries: SearchHistoryEntry[] = [];
  private static dir: string = '';

  static init(context: common.UIAbilityContext): void {
    SearchHistoryStore.dir = `${context.filesDir}/search`;
    if (!fileIo.accessSync(SearchHistoryStore.dir)) {
      fileIo.mkdirSync(SearchHistoryStore.dir, true);
    }
    SearchHistoryStore.load();
  }

  /** 全部历史，按时间倒序。 */
  static getAll(): SearchHistoryEntry[] {
    return SearchHistoryStore.entries.slice();
  }

  static isEmpty(): boolean {
    return SearchHistoryStore.entries.length === 0;
  }

  /** 记录一次搜索（隐私模式直接跳过）。 */
  static save(keyword: string): void {
    const value: string = keyword.trim();
    if (value.length === 0 || SettingsStore.getBool(SettingsKeys.privateMode)) {
      return;
    }
    while (SearchHistoryStore.entries.length >= SearchHistoryStore.maxCount) {
      SearchHistoryStore.entries.pop();
    }
    SearchHistoryStore.entries =
      SearchHistoryStore.entries.filter((item: SearchHistoryEntry) =>
        item.keyword !== value);
    SearchHistoryStore.entries.unshift(
      new SearchHistoryEntry(value, Date.now()));
    SearchHistoryStore.persist();
  }

  /** 删除一条（按时间戳定位，与参照实现的 `deleteHistory` 对应）。 */
  static remove(timestamp: number): void {
    SearchHistoryStore.entries =
      SearchHistoryStore.entries.filter((item: SearchHistoryEntry) =>
        item.timestamp !== timestamp);
    SearchHistoryStore.persist();
  }

  static clear(): void {
    SearchHistoryStore.entries = [];
    SearchHistoryStore.persist();
  }

  private static load(): void {
    const path: string = `${SearchHistoryStore.dir}/search_history.json`;
    if (!fileIo.accessSync(path)) {
      return;
    }
    try {
      const stat = fileIo.statSync(path);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const read: number = fileIo.readSync(file.fd, buffer);
        text = new util.TextDecoder().decodeToString(new Uint8Array(buffer, 0, read));
      } finally {
        fileIo.closeSync(file);
      }
      const parsed: Object = JSON.parse(text) as Object;
      const out: SearchHistoryEntry[] = [];
      if (Array.isArray(parsed)) {
        const array: Object[] = parsed as Object[];
        for (let i = 0; i < array.length; i++) {
          const record: Record<string, Object> = array[i] as Record<string, Object>;
          const keyword: string = `${record['keyword']}`;
          if (keyword.length > 0) {
            out.push(new SearchHistoryEntry(keyword, Number(record['timestamp'])));
          }
        }
      }
      out.sort((a: SearchHistoryEntry, b: SearchHistoryEntry) =>
        b.timestamp - a.timestamp);
      SearchHistoryStore.entries = out.slice(0, SearchHistoryStore.maxCount);
      hilog.info(DOMAIN, TAG, '搜索历史载入 %{public}d 条',
        SearchHistoryStore.entries.length);
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '搜索历史读取失败: %{public}s', err.message);
    }
  }

  private static persist(): void {
    const array: Object[] = [];
    for (let i = 0; i < SearchHistoryStore.entries.length; i++) {
      const entry: SearchHistoryEntry = SearchHistoryStore.entries[i];
      const record: Record<string, Object> = {};
      record['keyword'] = entry.keyword;
      record['timestamp'] = entry.timestamp;
      array.push(record);
    }
    const path: string = `${SearchHistoryStore.dir}/search_history.json`;
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
      hilog.error(DOMAIN, TAG, '搜索历史保存失败: %{public}s', err.message);
    }
  }
}
