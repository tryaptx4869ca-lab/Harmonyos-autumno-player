import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnCollect';

/**
 * 一条收藏记录。
 *
 * 只存列表页真正要用的字段（海报、标题、类型），不整包存 BangumiItem——
 * 详情页要的字段在阶段四从远端重新拉，避免本地冗余出不一致。
 */
export class CollectEntry {
  id: number = 0;
  name: string = '';
  nameCn: string = '';
  cover: string = '';
  airDate: string = '';
  score: number = 0;
  /**
   * 总集数（0 = 未知）。
   *
   * 列表卡片的「共 N 集」用它；来源是写入时那一份 `BangumiItem.episodeCount()`
   * （`total_episodes` → `eps` → infobox「话数」）。之前这条记录只存了
   * 海报/标题/类型，所以卡片副标题一直是空的——详情页写进来的时候手上明明
   * 有 `airDate` / `rating` / 集数，却没往下传。
   */
  epsTotal: number = 0;
  /** `CollectType`：1 在看 / 2 想看 / 3 搁置 / 4 看过 / 5 抛弃。 */
  collectType: number = 1;
  updatedAt: number = 0;

  displayName(): string {
    return this.nameCn.length > 0 ? this.nameCn : this.name;
  }
}

/**
 * 收藏存储。对应参照实现里 Hive 保存的收藏列表（`collect_module`）。
 *
 * 落盘：`${filesDir}/collect/collect.json`（整表一个文件，与规则表同款做法）。
 * 与上游的差异：上游用盒子（Hive box）存，原生版用 JSON 文件——
 * 语义等价（整表读写、按 id 覆盖），且不引入额外依赖。
 */
export class CollectStore {
  static readonly entries: CollectEntry[] = [];
  private static dir: string = '';
  /**
   * 变更版本号。
   *
   * 页面用 `@StorageProp('collectRevision') @Watch(...)` 订阅它——与
   * `HistoryRepository` 的 `historyRevision` 同一套机制。
   *
   * 为什么必须有：详情页 / 追番页 / 时间表**常驻在导航栈或标签页里**，
   * 在播放页点「在看」之后它们不会重建，光把文件改了界面不动
   * （用户 2026-09-19：「在播放页设置该番剧为在看，回到详情页不能第一时间显示」）。
   */
  private static changeCount: number = 0;

  static init(context: common.UIAbilityContext): void {
    CollectStore.dir = `${context.filesDir}/collect`;
    if (!fileIo.accessSync(CollectStore.dir)) {
      fileIo.mkdirSync(CollectStore.dir, true);
    }
    CollectStore.loadAll();
  }

  static loadAll(): void {
    CollectStore.entries.length = 0;
    const path: string = `${CollectStore.dir}/collect.json`;
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
      if (Array.isArray(parsed)) {
        const array: Object[] = parsed as Object[];
        for (let i = 0; i < array.length; i++) {
          const record: Record<string, Object> = array[i] as Record<string, Object>;
          CollectStore.entries.push(CollectStore.fromRecord(record));
        }
      }
      hilog.info(DOMAIN, TAG, '收藏载入 %{public}d 条', CollectStore.entries.length);
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '收藏读取失败: %{public}s', err.message);
    }
  }

  static save(): void {
    const array: Object[] = [];
    for (let i = 0; i < CollectStore.entries.length; i++) {
      array.push(CollectStore.toRecord(CollectStore.entries[i]));
    }
    const path: string = `${CollectStore.dir}/collect.json`;
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
      hilog.error(DOMAIN, TAG, '收藏保存失败: %{public}s', err.message);
    }
  }

  /** 按类型取（`type <= 0` 表示「全部」）。 */
  static listByType(type: number): CollectEntry[] {
    const out: CollectEntry[] = [];
    for (let i = 0; i < CollectStore.entries.length; i++) {
      const entry: CollectEntry = CollectStore.entries[i];
      if (type <= 0 || entry.collectType === type) {
        out.push(entry);
      }
    }
    return out;
  }

  static countAll(): number {
    return CollectStore.entries.length;
  }

  /** 当前版本号（诊断 / 自检用）。 */
  static revision(): number {
    return CollectStore.changeCount;
  }

  /**
   * 通知订阅者：收藏表变了。
   *
   * 只在**真的写成功之后**调用（见各个写方法的落点）；`loadAll()` 是启动装载，
   * 不算变更，不触发。
   */
  private static bump(): void {
    CollectStore.changeCount += 1;
    AppStorage.setOrCreate('collectRevision', CollectStore.changeCount);
  }

  /** 新增或覆盖（按 id 去重，与上游「同一部番只有一条收藏」一致）。 */
  static upsert(entry: CollectEntry): void {
    entry.updatedAt = Date.now();
    for (let i = 0; i < CollectStore.entries.length; i++) {
      if (CollectStore.entries[i].id === entry.id) {
        CollectStore.entries[i] = entry;
        CollectStore.save();
        CollectStore.bump();
        return;
      }
    }
    CollectStore.entries.push(entry);
    CollectStore.save();
    CollectStore.bump();
  }

  static remove(id: number): void {
    let changed: boolean = false;
    for (let i = CollectStore.entries.length - 1; i >= 0; i--) {
      if (CollectStore.entries[i].id === id) {
        CollectStore.entries.splice(i, 1);
        changed = true;
      }
    }
    // 没删到东西就既不落盘也不通知：否则「取消追番」点两下会白写一次文件、
    // 顺带把订阅页面全刷一遍
    if (!changed) {
      return;
    }
    CollectStore.save();
    CollectStore.bump();
  }

  /** 批量改分类（追番页多选：一次落盘，不逐条写文件）。 */
  static setTypes(ids: number[], type: number): void {
    let changed: boolean = false;
    for (let i = 0; i < CollectStore.entries.length; i++) {
      const entry: CollectEntry = CollectStore.entries[i];
      if (entry.collectType !== type && ids.indexOf(entry.id) >= 0) {
        entry.collectType = type;
        entry.updatedAt = Date.now();
        changed = true;
      }
    }
    if (changed) {
      CollectStore.save();
      CollectStore.bump();
    }
  }

  /** 批量移除（追番页多选「取消收藏」）。 */
  static removeAll(ids: number[]): void {
    let changed: boolean = false;
    for (let i = CollectStore.entries.length - 1; i >= 0; i--) {
      if (ids.indexOf(CollectStore.entries[i].id) >= 0) {
        CollectStore.entries.splice(i, 1);
        changed = true;
      }
    }
    if (changed) {
      CollectStore.save();
      CollectStore.bump();
    }
  }

  /**
   * 用云同步合并后的结果一次性覆盖本地收藏。
   *
   * 云同步不应该逐条调用 `upsert` / `remove`：那会把整表重复写盘，
   * 并让收藏页在合并过程中反复刷新。这里只落盘和通知一次。
   */
  static replaceAll(entries: CollectEntry[]): void {
    CollectStore.entries.length = 0;
    for (let i = 0; i < entries.length; i++) {
      CollectStore.entries.push(entries[i]);
    }
    CollectStore.save();
    CollectStore.bump();
  }

  /** 改分类（详情页的收藏按钮用）。 */
  static setType(id: number, type: number): void {
    for (let i = 0; i < CollectStore.entries.length; i++) {
      if (CollectStore.entries[i].id === id) {
        CollectStore.entries[i].collectType = type;
        CollectStore.entries[i].updatedAt = Date.now();
        CollectStore.save();
        CollectStore.bump();
        return;
      }
    }
  }

  static find(id: number): CollectEntry | null {
    for (let i = 0; i < CollectStore.entries.length; i++) {
      if (CollectStore.entries[i].id === id) {
        return CollectStore.entries[i];
      }
    }
    return null;
  }

  private static toRecord(entry: CollectEntry): Record<string, Object> {
    const record: Record<string, Object> = {};
    record['id'] = entry.id;
    record['name'] = entry.name;
    record['nameCn'] = entry.nameCn;
    record['cover'] = entry.cover;
    record['airDate'] = entry.airDate;
    record['score'] = entry.score;
    record['epsTotal'] = entry.epsTotal;
    record['collectType'] = entry.collectType;
    record['updatedAt'] = entry.updatedAt;
    return record;
  }

  private static fromRecord(record: Record<string, Object>): CollectEntry {
    const entry = new CollectEntry();
    entry.id = Number(record['id']);
    entry.name = `${record['name']}`;
    entry.nameCn = `${record['nameCn']}`;
    entry.cover = `${record['cover']}`;
    entry.airDate = `${record['airDate']}`;
    entry.score = Number(record['score']);
    // 老记录里没有这个字段：缺了按 0（未知）算，别让 `Number(undefined)` 变成 NaN
    const epsRaw: Object | undefined = record['epsTotal'];
    entry.epsTotal = epsRaw === undefined || epsRaw === null ? 0 : Number(epsRaw);
    entry.collectType = Number(record['collectType']);
    entry.updatedAt = Number(record['updatedAt']);
    return entry;
  }
}
