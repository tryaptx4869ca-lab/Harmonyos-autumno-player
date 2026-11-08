import { BangumiItem, parseBangumiItem } from './BangumiItem';
import { BangumiTag } from './BangumiTag';

/**
 * 播放历史的数据模型。
 *
 * 逐条对应参照实现：
 *   - `lib/modules/history/history_module.dart`（`HistoryEntryKind` /
 *     `PlaybackHistoryIdentity` / `History` / `Progress`）
 *   - `lib/pages/history/history_list_query.dart`（分组与筛选）
 *   - `lib/repositories/history_repository.dart`（key 规则）
 *
 * Hive 编号保留在注释里：原生版落盘为 JSON，但**键规则与字段语义**
 * 必须与源码一致，否则「同名番剧的两条记录会不会互相覆盖」这类行为会对不上。
 */

/** 历史来源标记。源码 `HistoryEntryKind`。 */
export class HistoryEntryKind {
  static readonly online: string = 'online';
  static readonly offline: string = 'offline';

  /** 归一化：未知值一律当在线（源码同款兜底）。 */
  static normalize(value: string): string {
    return value === HistoryEntryKind.offline
      ? HistoryEntryKind.offline : HistoryEntryKind.online;
  }
}

/**
 * 一条观看进度。
 *
 * `updatedAtMs` 是同步用的版本位：事件溯源合并时按它取新，
 * 所以写入时必须带上（源码 `Progress.effectiveUpdatedAtMs`）。
 */
export class HistoryProgress {
  /** @HiveField(0) 集数 */
  episode: number = 0;
  /** @HiveField(1) 线路序号 */
  road: number = 0;
  /** @HiveField(2) 进度毫秒（源码 `_progressInMilli`） */
  progressMs: number = 0;
  /** @HiveField(3) 写入时间；为 0 时回落到记录时间 */
  updatedAtMs: number = 0;

  constructor(episode: number = 0, road: number = 0, progressMs: number = 0,
    updatedAtMs: number = 0) {
    this.episode = episode;
    this.road = road;
    this.progressMs = progressMs;
    this.updatedAtMs = updatedAtMs;
  }

  effectiveUpdatedAtMs(fallback: number): number {
    return this.updatedAtMs > 0 ? this.updatedAtMs : fallback;
  }
}

/**
 * 写入历史时描述「哪一集、哪条线路、来自哪条规则」。
 *
 * 参照实现用 `PlaybackHistoryIdentity.online(...)` / `.offline(...)`
 * 两个具名工厂构造，原生版同样保留这两个入口（避免调用方直接 new 之后
 * 漏填 `entryKind`，那是「在线记录被写成离线」的根源）。
 */
export class PlaybackHistoryIdentity {
  bangumiItem: BangumiItem = new BangumiItem();
  pluginName: string = '';
  episodeNumber: number = 0;
  episodeTitle: string = '';
  road: number = 0;
  entryKind: string = HistoryEntryKind.online;
  onlineBangumiSrc: string = '';
  episodePageUrl: string = '';

  /** 源码 `identity.canRecord`：规则名与集数都有效才写库。 */
  canRecord(): boolean {
    return this.pluginName.length > 0 && this.episodeNumber > 0;
  }

  static online(item: BangumiItem, pluginName: string, episodeNumber: number,
    episodeTitle: string, road: number, onlineBangumiSrc: string,
    episodePageUrl: string): PlaybackHistoryIdentity {
    const identity = new PlaybackHistoryIdentity();
    identity.bangumiItem = item;
    identity.pluginName = pluginName;
    identity.episodeNumber = episodeNumber;
    identity.episodeTitle = episodeTitle;
    identity.road = road;
    identity.entryKind = HistoryEntryKind.online;
    identity.onlineBangumiSrc = onlineBangumiSrc;
    identity.episodePageUrl = episodePageUrl;
    return identity;
  }

  static offline(item: BangumiItem, pluginName: string, episodeNumber: number,
    episodeTitle: string, road: number,
    episodePageUrl: string): PlaybackHistoryIdentity {
    const identity = new PlaybackHistoryIdentity();
    identity.bangumiItem = item;
    identity.pluginName = pluginName;
    identity.episodeNumber = episodeNumber;
    identity.episodeTitle = episodeTitle;
    identity.road = road;
    identity.entryKind = HistoryEntryKind.offline;
    identity.episodePageUrl = episodePageUrl;
    return identity;
  }
}

/**
 * 一条番剧的观看历史（源码 `History`）。
 *
 * 去重键是「规则名 + 番剧 id + 来源」：
 * 同一部番从两个规则看过，会留下两条记录——这是参照实现的既定语义
 * （`History.scopedKey`），不要「顺手」按 id 合并。
 */
export class HistoryEntry {
  /** @HiveField(0) 集数 -> 进度 */
  progresses: Map<number, HistoryProgress> = new Map<number, HistoryProgress>();
  /** @HiveField(1) 最后观看的集数 */
  lastWatchEpisode: number = 0;
  /** @HiveField(2) 规则名（源码字段名即 adapterName） */
  adapterName: string = '';
  /** @HiveField(3) 番剧条目 */
  bangumiItem: BangumiItem = new BangumiItem();
  /** @HiveField(4) 最后观看时间（毫秒时间戳） */
  lastWatchTime: number = 0;
  /** @HiveField(5) 最后观看时的番剧页地址 */
  lastSrc: string = '';
  /** @HiveField(6) 最后观看的剧集名 */
  lastWatchEpisodeName: string = '';
  /** @HiveField(7) 来源标记 */
  entryKind: string = HistoryEntryKind.online;
  /** @HiveField(8) 剧集页地址（离线记录靠它精确指认某一集） */
  episodePageUrl: string = '';

  /** 去重键（§60.1）：规则名 + id + 来源。 */
  key(): string {
    return HistoryEntry.scopedKey(this.adapterName, this.bangumiItem,
      this.entryKind);
  }

  /** 旧版键（不含来源），用于迁移与删除时一并清理。 */
  legacyKey(): string {
    return HistoryEntry.legacyKeyOf(this.adapterName, this.bangumiItem);
  }

  static legacyKeyOf(adapterName: string, item: BangumiItem): string {
    return `${adapterName}${item.id}`;
  }

  static scopedKey(adapterName: string, item: BangumiItem,
    entryKind: string): string {
    return `${HistoryEntry.legacyKeyOf(adapterName, item)}::${HistoryEntryKind.normalize(entryKind)}`;
  }

  static getKey(adapterName: string, item: BangumiItem,
    entryKind: string): string {
    return HistoryEntry.scopedKey(adapterName, item, entryKind);
  }

  /** 展示名：中文名优先。 */
  displayName(): string {
    return this.bangumiItem.nameCn.length > 0
      ? this.bangumiItem.nameCn : this.bangumiItem.name;
  }
}

// ---------------- 序列化 ----------------

/**
 * `BangumiItem` -> 上游 JSON 形态。
 *
 * 为什么要「回到上游形态」而不是自定义一套字段：
 * 读回时直接用 `parseBangumiItem`（阶段 1 逐行对齐 `BangumiItem.fromJson`），
 * 别名解析、票数分布、infobox 派生全部复用同一份代码，不会出现
 * 「详情页显示正常、历史页缺别名」这类两份解析器漂移。
 */
export function bangumiItemToJson(item: BangumiItem): Record<string, Object> {
  const rec: Record<string, Object> = {};
  rec['id'] = item.id;
  rec['type'] = item.type;
  rec['name'] = item.name;
  rec['name_cn'] = item.nameCn;
  rec['summary'] = item.summary;
  rec['date'] = item.airDate;
  rec['info'] = item.info;
  if (item.domesticCover.length > 0) {
    rec['girigiri_cover'] = item.domesticCover;
  }

  const images: Record<string, Object> = {};
  const sizes: string[] = ['large', 'common', 'medium', 'small', 'grid'];
  for (let i = 0; i < sizes.length; i++) {
    const value: string | undefined = item.images.get(sizes[i]);
    images[sizes[i]] = value === undefined ? '' : value;
  }
  rec['images'] = images;

  const tags: Object[] = [];
  for (let i = 0; i < item.tags.length; i++) {
    tags.push(item.tags[i].toJson());
  }
  rec['tags'] = tags as Object;

  const alias: Object[] = [];
  for (let i = 0; i < item.alias.length; i++) {
    alias.push(item.alias[i]);
  }
  rec['alias'] = alias as Object;

  const rating: Record<string, Object> = {};
  rating['rank'] = item.rank;
  rating['score'] = item.ratingScore;
  rating['total'] = item.votes;
  const count: Record<string, Object> = {};
  for (let i = 1; i <= 10; i++) {
    const value: number = i <= item.votesCount.length ? item.votesCount[i - 1] : 0;
    count[`${i}`] = value;
  }
  rating['count'] = count;
  rec['rating'] = rating;

  if (item.eps !== undefined) {
    rec['eps'] = item.eps;
  }
  /**
   * ---- 以下字段以前没落盘，代价是「重启后连载状态消失」----
   *
   * 模型里 `eps` / `total_episodes` / `platform` / `metaTags` 被标成
   * 「不参与持久化」，于是历史记录只留下 id/标题/封面那一档。详情页的
   * `airingStatus()` 判定「连载中 / 已完结」要的正是 `platform`（或
   * `info` 里的 `Infobox animanga/TVAnime`）与 `hasEndField` / `endDate`，
   * 而**搜索接口（v0 search）不返回 `info`**，所以从搜索页进来的条目一旦
   * 落盘就什么都不剩——真机表现就是「从搜索页加的番，退出应用再进来，
   * 完结状态没了」（用户 2026-09-18）。
   *
   * 读回来的那一侧（`parseBangumiItem`）本来就认这些键：`platform`、
   * `eps`、`total_episodes`、`infobox`、`metaTags`，
   * 所以这里只需要把值写出去，两边就能对齐。
   */
  if (item.totalEpisodes !== undefined) {
    rec['total_episodes'] = item.totalEpisodes;
  }
  if (item.platform.length > 0) {
    rec['platform'] = item.platform;
  }
  if (item.metaTags.length > 0) {
    const metaTags: Object[] = [];
    for (let i = 0; i < item.metaTags.length; i++) {
      metaTags.push(item.metaTags[i]);
    }
    rec['metaTags'] = metaTags as Object;
  }
  /**
   * infobox：`endDate` / `hasEndField` / `episodeCountText` 是从 infobox
   * 或 wiki 原文**派生**出来的，本身不落盘。这里把派生结果写回成两条
   * infobox（`播放结束` / `话数`），读回时 `parseBangumiItem` 会把它们
   * 重新派生出来——「明确有结束日期」与「字段缺失」的区别也一并保住
   * （`hasEndField` 决定的是「完结」还是「连载中」）。
   */
  const infobox: Object[] = [];
  if (item.hasEndField && item.endDate !== undefined &&
    item.endDate.length > 0) {
    const endEntry: Record<string, Object> = {};
    endEntry['key'] = '播放结束';
    endEntry['value'] = item.endDate;
    infobox.push(endEntry as Object);
  }
  if (item.episodeCountText.length > 0) {
    const countEntry: Record<string, Object> = {};
    countEntry['key'] = '话数';
    countEntry['value'] = item.episodeCountText;
    infobox.push(countEntry as Object);
  }
  if (infobox.length > 0) {
    rec['infobox'] = infobox as Object;
  }
  return rec;
}

/** 一条记录 -> JSON 对象。 */
export function historyToJson(entry: HistoryEntry): Record<string, Object> {
  const rec: Record<string, Object> = {};
  rec['entryKind'] = HistoryEntryKind.normalize(entry.entryKind);
  rec['adapterName'] = entry.adapterName;
  rec['lastWatchEpisode'] = entry.lastWatchEpisode;
  rec['lastWatchTime'] = entry.lastWatchTime;
  rec['lastSrc'] = entry.lastSrc;
  rec['lastWatchEpisodeName'] = entry.lastWatchEpisodeName;
  rec['episodePageUrl'] = entry.episodePageUrl;
  rec['bangumiItem'] = bangumiItemToJson(entry.bangumiItem) as Object;

  const progresses: Object[] = [];
  entry.progresses.forEach((progress: HistoryProgress, episode: number) => {
    const item: Record<string, Object> = {};
    item['episode'] = episode;
    item['road'] = progress.road;
    item['progressMs'] = progress.progressMs;
    item['updatedAtMs'] = progress.updatedAtMs;
    progresses.push(item as Object);
  });
  rec['progresses'] = progresses as Object;
  return rec;
}

function readString(rec: Record<string, Object>, key: string): string {
  const value: Object | undefined = rec[key];
  return value === undefined || value === null ? '' : value.toString();
}

function readNumber(rec: Record<string, Object>, key: string): number {
  const value: Object | undefined = rec[key];
  if (value === undefined || value === null) {
    return 0;
  }
  const parsed: number = Number(value);
  return Number.isNaN(parsed) ? 0 : parsed;
}

/** JSON 对象 -> 一条记录。缺字段一律回落默认值，坏记录不抛异常。 */
export function historyFromJson(rec: Record<string, Object>): HistoryEntry {
  const entry = new HistoryEntry();
  entry.entryKind = HistoryEntryKind.normalize(readString(rec, 'entryKind'));
  entry.adapterName = readString(rec, 'adapterName');
  entry.lastWatchEpisode = readNumber(rec, 'lastWatchEpisode');
  entry.lastWatchTime = readNumber(rec, 'lastWatchTime');
  entry.lastSrc = readString(rec, 'lastSrc');
  entry.lastWatchEpisodeName = readString(rec, 'lastWatchEpisodeName');
  entry.episodePageUrl = readString(rec, 'episodePageUrl');

  const rawItem: Object | undefined = rec['bangumiItem'];
  if (rawItem !== undefined && rawItem !== null) {
    entry.bangumiItem = parseBangumiItem(rawItem);
  }

  const rawProgresses: Object | undefined = rec['progresses'];
  if (rawProgresses !== undefined && rawProgresses !== null
    && Array.isArray(rawProgresses)) {
    const list: Object[] = rawProgresses as Object[];
    for (let i = 0; i < list.length; i++) {
      const raw: Object = list[i];
      if (raw === undefined || raw === null || Array.isArray(raw)) {
        continue;
      }
      const progressRec: Record<string, Object> = raw as Record<string, Object>;
      const progress = new HistoryProgress(
        readNumber(progressRec, 'episode'),
        readNumber(progressRec, 'road'),
        readNumber(progressRec, 'progressMs'),
        readNumber(progressRec, 'updatedAtMs'));
      if (progress.episode > 0) {
        entry.progresses.set(progress.episode, progress);
      }
    }
  }
  return entry;
}

// ---------------- 列表筛选与分组（§51.2） ----------------

/** 来源筛选胶囊。 */
export enum HistorySourceFilter {
  all = 0,
  online = 1,
  offline = 2
}

export class HistorySourceFilters {
  static label(filter: HistorySourceFilter): string {
    if (filter === HistorySourceFilter.online) {
      return '在线';
    }
    return filter === HistorySourceFilter.offline ? '缓存' : '全部';
  }
}

/** 一组同一天的记录。 */
export class HistoryDateGroup {
  /** 当天 0 点（本地时区）的毫秒时间戳 */
  dayStartMs: number = 0;
  label: string = '';
  entries: HistoryEntry[] = [];
}

function matchesSource(entry: HistoryEntry, filter: HistorySourceFilter): boolean {
  if (filter === HistorySourceFilter.all) {
    return true;
  }
  const kind: string = HistoryEntryKind.normalize(entry.entryKind);
  return filter === HistorySourceFilter.online
    ? kind === HistoryEntryKind.online : kind === HistoryEntryKind.offline;
}

function dayStartOf(timestampMs: number): number {
  const date = new Date(timestampMs);
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

/**
 * 按关键词（番剧名 / 中文名 / 别名 / 规则名）与来源筛选，时间倒序。
 * 对应源码 `groupHistoryEntries` 的过滤段。
 */
export function filterHistoryEntries(entries: HistoryEntry[], query: string,
  source: HistorySourceFilter): HistoryEntry[] {
  const keyword: string = query.trim().toLowerCase();
  const out: HistoryEntry[] = [];
  for (let i = 0; i < entries.length; i++) {
    const entry: HistoryEntry = entries[i];
    if (!matchesSource(entry, source)) {
      continue;
    }
    if (keyword.length > 0 && !historyMatchesKeyword(entry, keyword)) {
      continue;
    }
    out.push(entry);
  }
  out.sort((a: HistoryEntry, b: HistoryEntry) => b.lastWatchTime - a.lastWatchTime);
  return out;
}

function historyMatchesKeyword(entry: HistoryEntry, keyword: string): boolean {
  const item: BangumiItem = entry.bangumiItem;
  const candidates: string[] = [item.name, item.nameCn, entry.adapterName];
  for (let i = 0; i < item.alias.length; i++) {
    candidates.push(item.alias[i]);
  }
  for (let i = 0; i < candidates.length; i++) {
    if (candidates[i].toLowerCase().indexOf(keyword) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 按日分组。标签规则与源码一致：今天 / 昨天 / 「M月D日」（跨年补年份）。
 */
export function groupHistoryEntries(entries: HistoryEntry[],
  nowMs: number): HistoryDateGroup[] {
  const today: number = dayStartOf(nowMs);
  const yesterday: number = dayStartOf(today - 86400000);
  const groups: HistoryDateGroup[] = [];
  for (let i = 0; i < entries.length; i++) {
    const entry: HistoryEntry = entries[i];
    const day: number = dayStartOf(entry.lastWatchTime);
    let group: HistoryDateGroup | undefined = undefined;
    if (groups.length > 0 && groups[groups.length - 1].dayStartMs === day) {
      group = groups[groups.length - 1];
    }
    if (group === undefined) {
      const created = new HistoryDateGroup();
      created.dayStartMs = day;
      created.label = historyDateLabel(day, today, yesterday);
      groups.push(created);
      group = groups[groups.length - 1];
    }
    group.entries.push(entry);
  }
  return groups;
}

function historyDateLabel(day: number, today: number, yesterday: number): string {
  if (day === today) {
    return '今天';
  }
  if (day === yesterday) {
    return '昨天';
  }
  const date = new Date(day);
  const thisYear: number = new Date(today).getFullYear();
  const prefix: string = date.getFullYear() === thisYear
    ? '' : `${date.getFullYear()}年`;
  return `${prefix}${date.getMonth() + 1}月${date.getDate()}日`;
}
