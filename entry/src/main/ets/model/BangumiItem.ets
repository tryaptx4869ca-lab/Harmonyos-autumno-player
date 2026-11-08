import { BangumiImageUrlRewriter } from '../services/BangumiImageUrlRewriter';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';
import { DateTimeUtils } from '../utils/DateTimeUtils';
import { BangumiInterest } from './BangumiInterest';
import { BangumiTag } from './BangumiTag';
import { JsonUtils } from './JsonUtils';

/**
 * Bangumi 条目模型。
 *
 * 逐字段移植自参照实现 `lib/modules/bangumi/bangumi_item.dart`。
 *
 * 字段分成两组，**注释里的 Hive 编号必须保留**：
 *   1. `@HiveField(n)` —— 参与持久化，编号是 Flutter 版写进 Hive 的顺序，
 *      改动会导致老数据读不出来；
 *   2. 其余字段 —— 只在内存里用（来自 v0 接口或 infobox 派生）。
 */
export class BangumiItem {
  // ---------- Hive 持久化字段 ----------
  /** @HiveField(0) */
  id: number = 0;
  /** @HiveField(1) */
  type: number = 2;
  /** @HiveField(2) 原名 */
  name: string = '';
  /** @HiveField(3) 中文名 */
  nameCn: string = '';
  /** @HiveField(4) */
  summary: string = '';
  /** @HiveField(5) 首播日期，形如 2026-07-04 */
  airDate: string = '';
  /** @HiveField(6) 星期（1=周一 … 7=周日） */
  airWeekday: number = 1;
  /** @HiveField(7) 排名 */
  rank: number = 0;
  /** @HiveField(8) 五种尺寸的封面地址 */
  images: Map<string, string> = new Map<string, string>();
  /** @HiveField(9) */
  tags: BangumiTag[] = [];
  /** @HiveField(10) 别名列表（来自 infobox「别名」） */
  alias: string[] = [];
  /** @HiveField(11) 平均分（一位小数） */
  ratingScore: number = 0;
  /** @HiveField(12) 评分人数 */
  votes: number = 0;
  /** @HiveField(13) 各分档票数，长度 10 */
  votesCount: number[] = [];
  /** @HiveField(14) wiki 原文 */
  info: string = '';

  // ---------- 不参与持久化的字段 ----------
  /** 已播放/已有话数（v0 搜索的 `eps`）。 */
  eps: number | undefined = undefined;
  /** 计划总话数（v0 搜索的 `total_episodes`）。 */
  totalEpisodes: number | undefined = undefined;
  /** 放送平台（TV / WEB / 剧场版 …）。 */
  platform: string = '';
  /** infobox 的放送结束日期；**空字符串表示明确「未播完」**。 */
  endDate: string | undefined = undefined;
  /** infobox 里是否出现过放送结束字段（区分「字段缺失」与「字段为空」）。 */
  hasEndField: boolean = false;
  /** infobox 的话数文本，`*` 代表长期连载。 */
  episodeCountText: string = '';
  /** 日历来源的元标签，不计入用户标签，也不持久化。 */
  metaTags: string[] = [];
  /** 当前用户的收藏状态。 */
  interest: BangumiInterest | undefined = undefined;
  /** 可选 GiriGiri 封面；仅在对应设置开启时由封面服务写入。 */
  domesticCover: string = '';

  // ---------- 便捷访问 ----------

  /**
   * 首选封面。
   * 参照实现的卡片按 `images['large']` 取图，
   * 这里保持同样优先级，取不到时依次回落到 common / medium / grid。
   */
  get cover(): string {
    const order: string[] = ['large', 'common', 'medium', 'grid', 'small'];
    for (let i = 0; i < order.length; i++) {
      const v: string | undefined = this.images.get(order[i]);
      if (v !== undefined && v.length > 0) {
        return v;
      }
    }
    return '';
  }

  /** 兼容旧调用点：`ratingScore` 的别名。 */
  get score(): number {
    return this.ratingScore;
  }

  /** 兼容旧调用点：`votes` 的别名。 */
  get rankTotal(): number {
    return this.votes;
  }

  /** 兼容旧调用点：`airDate` 的别名。 */
  get date(): string {
    return this.airDate;
  }

  /** 展示名：中文名优先，回落到原名。 */
  displayName(): string {
    return this.nameCn.length > 0 ? this.nameCn : this.name;
  }

  /**
   * 封面地址。
   * 参照实现里图片一律经 `BangumiImageUrlRewriter` 改写
   * （lain.bgm.tv → wsrv.nl 代理），开关取 `enableBangumiProxy`。
   */
  coverUrl(): string {
    return BangumiImageUrlRewriter.rewrite(this.cover,
      SettingsStore.getBool(SettingsKeys.enableBangumiProxy));
  }

  /**
   * 元信息行。参照实现的卡片副标题形如
   * 「12 话 · TV · 日本」或「喜剧 · 校园 · TV」，
   * 由「话数 + 平台 + 首个标签」拼装，缺项跳过。
   */
  metaLine(): string {
    const parts: string[] = [];
    const count: number = this.episodeCount();
    if (count > 0) {
      parts.push(`${count} 话`);
    }
    if (this.platform.length > 0) {
      parts.push(this.platform);
    }
    if (this.tags.length > 0) {
      parts.push(this.tags[0].name);
    }
    return parts.join(' · ');
  }

  /** 已知话数：优先 `eps`，其次 infobox 的「话数」文本。 */
  episodeCount(): number {
    if (this.eps !== undefined && this.eps > 0) {
      return this.eps;
    }
    if (this.totalEpisodes !== undefined && this.totalEpisodes > 0) {
      return this.totalEpisodes;
    }
    const text: string = this.episodeCountText.trim();
    if (text.length === 0) {
      return 0;
    }
    const n: number = Number.parseInt(text, 10);
    return Number.isNaN(n) ? 0 : n;
  }

  /** 标签名列表（旧调用点用字符串数组）。 */
  tagNames(): string[] {
    const names: string[] = [];
    for (let i = 0; i < this.tags.length; i++) {
      names.push(this.tags[i].name);
    }
    return names;
  }
}

/** 从 info 文本里取 wiki 字段，形如 `|key=value`（源码 `_wikiFieldValue`）。 */
function wikiFieldValue(info: string, key: string): string | null {
  const pattern: string = '\\|\\s*' + escapeRegExp(key) + '\\s*=\\s*([^|}]*)';
  const match: RegExpExecArray | null = new RegExp(pattern).exec(info);
  if (match === null) {
    return null;
  }
  return match[1].replace(/\s+/g, ' ').trim();
}

/** 正则元字符转义（对应 Dart `RegExp.escape`）。 */
function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * infobox 值展平（源码 `_infoboxValueText`）：
 * 数组元素若含 `v` 键则取其值，过滤空项后用 ' / ' 连接。
 */
function infoboxValueText(raw: Object | undefined): string {
  if (raw === undefined || raw === null) {
    return '';
  }
  if (Array.isArray(raw)) {
    const arr: Object[] = raw as Object[];
    const parts: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      const element: Object = arr[i];
      const rec: Record<string, Object> | null = JsonUtils.asObj(element);
      let text: string;
      if (rec !== null && rec['v'] !== undefined && rec['v'] !== null) {
        text = rec['v'].toString();
      } else {
        text = element === null || element === undefined ? '' : element.toString();
      }
      if (text.trim().length > 0) {
        parts.push(text);
      }
    }
    return parts.join(' / ').trim();
  }
  return raw.toString().trim();
}

/**
 * 从 Bangumi 原始 JSON 构造条目。
 * 逐行对应源码 `BangumiItem.fromJson`，兼容两种上游形态：
 *   1. /v0/subjects、镜像榜单：字段直接平铺
 *   2. /p1/trending/subjects：外层是 { subject: {...}, count: n }
 */
export function parseBangumiItem(raw: Object): BangumiItem {
  let rec: Record<string, Object> | null = JsonUtils.asObj(raw);
  if (rec === null) {
    return new BangumiItem();
  }
  // trending 外层包装
  const inner: Record<string, Object> | null = JsonUtils.obj(rec, 'subject');
  if (inner !== null) {
    rec = inner;
  }

  const item = new BangumiItem();
  const airDateStr: string = resolveAirDateString(rec);
  item.id = JsonUtils.intOf(rec, 'id');
  item.type = JsonUtils.intOf(rec, 'type', 2);
  item.name = JsonUtils.str(rec, 'name');
  // 源码：name_cn 为空时依次回落到 nameCN、name
  const nameCnRaw: string = JsonUtils.str(rec, 'name_cn');
  const nameCNRaw: string = JsonUtils.str(rec, 'nameCN');
  item.nameCn = nameCnRaw.length > 0
    ? nameCnRaw
    : (nameCNRaw.length > 0 ? nameCNRaw : item.name);
  item.summary = JsonUtils.str(rec, 'summary');
  item.airDate = airDateStr;
  item.airWeekday = DateTimeUtils.dateStringToWeekday(
    airDateStr.length === 0 ? '2000-11-11' : airDateStr);

  const rating: Record<string, Object> | null = JsonUtils.obj(rec, 'rating');
  /**
   * 排名有**两个出处**，都要认：
   *   - v0（`/v0/subjects/{id}`、v0 搜索、镜像榜单）：`rating.rank`；
   *   - 旧版（`/search/subject/{关键字}?responseGroup=large`）：`rank` 在**顶层**，
   *     `rating` 里只有 `total` / `score` / `count`。
   *
   * 只读 `rating.rank` 的后果就是「从搜索页点进详情，排名永远显示 0」
   * （用户 2026-09-19）。旧版响应实测：`rank = 42`、`rating = {total, count, score}`。
   */
  const ratingRank: number = rating === null ? 0 : JsonUtils.intOf(rating, 'rank');
  item.rank = ratingRank > 0 ? ratingRank : JsonUtils.intOf(rec, 'rank');
  item.ratingScore = round1(rating === null ? 0 : JsonUtils.num(rating, 'score'));
  item.votes = rating === null ? 0 : JsonUtils.intOf(rating, 'total');
  item.votesCount = parseVoteCount(rec);

  const images: Record<string, Object> | null = JsonUtils.obj(rec, 'images');
  if (images !== null) {
    const sizes: string[] = ['large', 'common', 'medium', 'small', 'grid'];
    for (let i = 0; i < sizes.length; i++) {
      item.images.set(sizes[i], JsonUtils.str(images, sizes[i]));
    }
  } else {
    // 源码的兜底：只有单张 image 时，large 取它，其余为空
    item.images.set('large', JsonUtils.str(rec, 'image'));
    item.images.set('common', '');
    item.images.set('medium', '');
    item.images.set('small', '');
    item.images.set('grid', '');
  }

  const rawTags: Object[] = JsonUtils.arr(rec, 'tags');
  for (let i = 0; i < rawTags.length; i++) {
    const tag: Record<string, Object> | null = JsonUtils.asObj(rawTags[i]);
    if (tag !== null) {
      item.tags.push(BangumiTag.fromJson(tag));
    }
  }
  item.alias = parseAliases(rec);
  item.info = JsonUtils.str(rec, 'info');

  const epsRaw: Object | undefined = rec['eps'];
  if (epsRaw !== undefined && epsRaw !== null) {
    item.eps = Math.trunc(Number(epsRaw));
  }
  const totalRaw: Object | undefined = rec['total_episodes'];
  if (totalRaw !== undefined && totalRaw !== null) {
    item.totalEpisodes = Math.trunc(Number(totalRaw));
  }

  item.platform = JsonUtils.str(rec, 'platform');
  item.endDate = undefined;
  item.hasEndField = false;
  item.episodeCountText = '';
  const rawInfobox: Object[] = JsonUtils.arr(rec, 'infobox');
  for (let i = 0; i < rawInfobox.length; i++) {
    const entry: Record<string, Object> | null = JsonUtils.asObj(rawInfobox[i]);
    if (entry === null) {
      continue;
    }
    const key: string = JsonUtils.str(entry, 'key');
    const value: Object | undefined =
      entry['values'] !== undefined && entry['values'] !== null
        ? entry['values'] : entry['value'];
    if (key === '播放结束' || key === '放送结束') {
      item.hasEndField = true;
      item.endDate = infoboxValueText(value);
    } else if (key === '话数') {
      item.episodeCountText = infoboxValueText(value);
    }
  }

  const infoText: string = item.info;
  if (item.platform.length === 0 && infoText.indexOf('Infobox animanga/TVAnime') >= 0) {
    item.platform = 'TV';
  }
  if (infoText.length > 0) {
    /**
     * wiki 文本里的**结束日期**。
     *
     * ⚠️ 键名有两种写法，**必须都认**（2026-09-20 实测《恋爱FLOPS》id 375735）：
     *   - 详情接口 `/p1/subjects/{id}`（next，工程实际用的那个）不返回 `infobox`，
     *     只给一段 wiki 文本，里面写的是 **`|播放结束= 2022年12月28日`**；
     *   - 而 `/v0/subjects/{id}` 的 `infobox` 里同样是 `播放结束`。
     * 以前这里只找 `放送结束`，于是 `hasEndField` 永远为 false、`endDate` 永远拿不到，
     * 详情页就把**已完结的番显示成「连载中」**（用户 2026-09-20 反馈）。
     * （`放送结束` 留着不删：日文原名条目里确实会出现这种写法。）
     */
    let wikiEnd: string | null = wikiFieldValue(infoText, '播放结束');
    if (wikiEnd === null) {
      wikiEnd = wikiFieldValue(infoText, '放送结束');
    }
    if (wikiEnd !== null) {
      item.hasEndField = true;
      if (item.endDate === undefined) {
        item.endDate = wikiEnd;
      }
    }
    const wikiEpisodes: string | null = wikiFieldValue(infoText, '话数');
    if (item.episodeCountText.length === 0 && wikiEpisodes !== null) {
      item.episodeCountText = wikiEpisodes;
    }
  }

  /**
   * metaTags：去空白、去重（Dart 的 toSet 保序，这里同样保序）。
   *
   * 两个上游的键名不一样，都要认：镜像榜单用驼峰 `metaTags`，
   * 而 `v0/search/subjects`、`v0/subjects` 这类官方响应是下划线
   * `meta_tags`（2026-09-18 实测）。以前只读驼峰，从搜索页进来的条目
   * 这一项永远是空的。
   */
  let rawMetaTags: Object[] = JsonUtils.arr(rec, 'metaTags');
  if (rawMetaTags.length === 0) {
    rawMetaTags = JsonUtils.arr(rec, 'meta_tags');
  }
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < rawMetaTags.length; i++) {
    const value: Object = rawMetaTags[i];
    if (typeof value !== 'string') {
      continue;
    }
    const name: string = (value as string).trim();
    if (name.length > 0) {
      seen.add(name);
    }
  }
  item.metaTags = Array.from(seen);

  const interestRaw: Record<string, Object> | null = JsonUtils.obj(rec, 'interest');
  if (interestRaw !== null) {
    item.interest = BangumiInterest.fromJson(interestRaw);
  }
  // 历史记录会额外落盘这个非 Bangumi 字段；缺省时不影响上游解析。
  item.domesticCover = JsonUtils.str(rec, 'girigiri_cover');
  return item;
}

/** 保留一位小数（对应 `toStringAsFixed(1)` 后重新 parse）。 */
function round1(value: number): number {
  return Math.round(value * 10) / 10;
}

/** 源码 `resolveAirDateString`：顶层 date 优先，其次 airtime.date。 */
function resolveAirDateString(rec: Record<string, Object>): string {
  const fromTop: string = JsonUtils.str(rec, 'date').trim();
  if (fromTop.length > 0) {
    return fromTop;
  }
  const airtime: Record<string, Object> | null = JsonUtils.obj(rec, 'airtime');
  if (airtime !== null) {
    const fromAir: string = JsonUtils.str(airtime, 'date').trim();
    if (fromAir.length > 0) {
      return fromAir;
    }
  }
  return '';
}

/**
 * 源码 `parseBangumiAliases`：只认 infobox 里 key 为「别名」的那一项，
 * 值优先取 `values`（next.bgm.tv），其次 `value`（api.bgm.tv）。
 */
function parseAliases(rec: Record<string, Object>): string[] {
  const infobox: Object[] = JsonUtils.arr(rec, 'infobox');
  for (let i = 0; i < infobox.length; i++) {
    const entry: Record<string, Object> | null = JsonUtils.asObj(infobox[i]);
    if (entry === null || JsonUtils.str(entry, 'key') !== '别名') {
      continue;
    }
    const raw: Object | undefined =
      entry['values'] !== undefined && entry['values'] !== null
        ? entry['values'] : entry['value'];
    if (raw === undefined || raw === null) {
      return [];
    }
    if (Array.isArray(raw)) {
      const arr: Object[] = raw as Object[];
      const out: string[] = [];
      for (let j = 0; j < arr.length; j++) {
        const element: Object = arr[j];
        const elementRec: Record<string, Object> | null = JsonUtils.asObj(element);
        let text: string;
        if (elementRec !== null && elementRec['v'] !== undefined && elementRec['v'] !== null) {
          text = elementRec['v'].toString();
        } else {
          text = element.toString().trim();
        }
        if (text.length > 0) {
          out.push(text);
        }
      }
      return out;
    }
    const text: string = raw.toString().trim();
    return text.length === 0 ? [] : [text];
  }
  return [];
}

/**
 * 源码 `parseBangumiVoteCount`：rating.count 既可能是
 * `{"1": n, ... "10": n}`，也可能是长度 10 的数组。
 */
function parseVoteCount(rec: Record<string, Object>): number[] {
  const rating: Record<string, Object> | null = JsonUtils.obj(rec, 'rating');
  if (rating === null) {
    return [];
  }
  const count: Object | undefined = rating['count'];
  if (Array.isArray(count)) {
    const arr: Object[] = count as Object[];
    const out: number[] = [];
    for (let i = 0; i < arr.length; i++) {
      out.push(Math.trunc(Number(arr[i])));
    }
    return out;
  }
  const countRec: Record<string, Object> | null = JsonUtils.obj(rating, 'count');
  if (countRec !== null) {
    const out: number[] = [];
    for (let i = 1; i <= 10; i++) {
      out.push(JsonUtils.intOf(countRec, `${i}`));
    }
    return out;
  }
  return [];
}

/** 从 JSON 文本解析条目数组。 */
export function parseBangumiList(text: string): BangumiItem[] {
  const out: BangumiItem[] = [];
  try {
    const parsed: Object = JSON.parse(text);
    let arr: Object[] | null = null;
    // 顶部直接是数组（镜像榜单接口即为此形态）
    if (Array.isArray(parsed)) {
      arr = parsed as Object[];
    } else {
      const root: Record<string, Object> = parsed as Record<string, Object>;
      const data: Object | undefined = root['data'];
      if (data !== undefined && data !== null) {
        if (Array.isArray(data)) {
          arr = data as Object[];
        } else {
          const dataRec: Record<string, Object> | null = JsonUtils.asObj(data);
          const inner: Object | undefined = dataRec === null ? undefined : dataRec['data'];
          if (inner !== undefined && inner !== null && Array.isArray(inner)) {
            arr = inner as Object[];
          }
        }
      }
    }
    if (arr !== null) {
      for (let i = 0; i < arr.length; i++) {
        out.push(parseBangumiItem(arr[i]));
      }
    }
  } catch (e) {
    // 解析失败返回空列表，由调用方决定重试或兜底
  }
  return out;
}
