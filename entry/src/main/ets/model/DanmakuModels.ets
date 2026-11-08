import { JsonUtils } from './JsonUtils';

/**
 * 弹幕数据模型。逐条对应参照实现：
 *   - `lib/modules/danmaku/danmaku_module.dart`（`DanmakuEntry`）
 *   - `lib/modules/danmaku/danmaku_search_response.dart`
 *   - `lib/modules/danmaku/danmaku_episode_response.dart`
 *   - `lib/utils/danmaku.dart`（颜色解析 + 同内容合并）
 *
 * 弹幕类型 `type`：**1 普通（滚动）/ 4 底部 / 5 顶部**。这个编号来自弹弹play
 * 的 `p` 字段（`时间,类型,颜色,来源`），是上游约定，不要改。
 */
export class DanmakuEntry {
  /** 弹幕内容 */
  message: string = '';
  /** 出现时间（秒，可带小数） */
  time: number = 0;
  /** 1 普通 / 4 底部 / 5 顶部 */
  type: number = 1;
  /** 颜色（`#RRGGBB`） */
  color: string = '#FFFFFF';
  /** 来源（BiliBili / Gamer / DanDan 等） */
  source: string = '';

  /**
   * 从弹弹play 的评论对象构造。
   * `p` 形如 `12.345,1,16777215,DanDan`（时间,类型,颜色,来源）。
   */
  static fromJson(json: Record<string, Object>): DanmakuEntry {
    const entry = new DanmakuEntry();
    entry.message = JsonUtils.str(json, 'm');
    const parts: string[] = JsonUtils.str(json, 'p').split(',');
    if (parts.length > 0) {
      const time: number = Number.parseFloat(parts[0]);
      entry.time = Number.isNaN(time) ? 0 : time;
    }
    if (parts.length > 1) {
      const type: number = Number.parseInt(parts[1], 10);
      entry.type = Number.isNaN(type) ? 1 : type;
    }
    if (parts.length > 2) {
      const value: number = Number.parseInt(parts[2], 10);
      entry.color = Number.isNaN(value) ? '#FFFFFF' : rgbHex(value);
    }
    if (parts.length > 3) {
      entry.source = parts[3];
    }
    return entry;
  }

  toJson(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['m'] = this.message;
    out['p'] = `${this.time},${this.type},${hexToRgb(this.color)},${this.source}`;
    return out;
  }
}

/** 0xRRGGBB → `#RRGGBB`（对应 `generateDanmakuColor`）。 */
export function rgbHex(value: number): string {
  const safe: number = value < 0 ? 0 : value;
  const hex: string = (safe & 0xFFFFFF).toString(16).toUpperCase();
  return `#${'000000'.substring(hex.length)}${hex}`;
}

/** `#RRGGBB` → 0xRRGGBB（写回 `p` 字段用，与上游格式一致）。 */
export function hexToRgb(color: string): number {
  const text: string = color.startsWith('#') ? color.substring(1) : color;
  const value: number = Number.parseInt(text, 16);
  return Number.isNaN(value) ? 0xFFFFFF : value;
}

/**
 * 同内容弹幕合并（对应 `mergeDuplicateDanmakus`）。
 *
 * 归一化很讲究，逐条照源码来：全角空格转半角、全角字符（U+FF01–FF5E）转半角、
 * 去掉所有空白、只保留字母数字和下划线 / 中日文假名、把连续 3 个以上相同字符
 * 压成 3 个。归一化后同键的弹幕若在 `timeWindowSeconds` 内，合并成
 * `内容 xN` 一条（类型改为 5 顶部、白色），避免刷屏重复。
 */
export function mergeDuplicateDanmakus(danmakus: DanmakuEntry[],
  timeWindowSeconds: number): DanmakuEntry[] {
  const keys: string[] = [];
  const groups: DanmakuEntry[][] = [];
  for (let i = 0; i < danmakus.length; i++) {
    const key: string = normalizeMessage(danmakus[i].message);
    let at: number = keys.indexOf(key);
    if (at < 0) {
      keys.push(key);
      groups.push([]);
      at = keys.length - 1;
    }
    groups[at].push(danmakus[i]);
  }

  const result: DanmakuEntry[] = [];
  for (let g = 0; g < groups.length; g++) {
    const list: DanmakuEntry[] = groups[g];
    if (list.length === 0) {
      continue;
    }
    if (timeWindowSeconds <= 0) {
      mergeGroup(result, list);
      continue;
    }
    list.sort((a: DanmakuEntry, b: DanmakuEntry) => a.time - b.time);
    let current: DanmakuEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      if (current.length === 0) {
        current.push(list[i]);
        continue;
      }
      const last: DanmakuEntry = current[current.length - 1];
      if (list[i].time - last.time <= timeWindowSeconds) {
        current.push(list[i]);
      } else {
        mergeGroup(result, current);
        current = [list[i]];
      }
    }
    if (current.length > 0) {
      mergeGroup(result, current);
    }
  }
  return result;
}

/** 一组同内容弹幕 → 一条结果（多条时写成 `内容 xN`）。 */
function mergeGroup(result: DanmakuEntry[], group: DanmakuEntry[]): void {
  if (group.length === 1) {
    result.push(group[0]);
    return;
  }
  const merged = new DanmakuEntry();
  merged.message = `${group[0].message} x${group.length}`;
  merged.time = group[0].time;
  merged.type = 5;
  merged.color = '#FFFFFF';
  merged.source = group[0].source;
  result.push(merged);
}

/** 归一化一条弹幕文本（用于「同内容」判定）。 */
export function normalizeMessage(message: string): string {
  const lowered: string = message.trim().toLowerCase();
  let buffer: string = '';
  for (let i = 0; i < lowered.length; i++) {
    const code: number = lowered.charCodeAt(i);
    if (code === 0x3000) {
      buffer += ' ';
    } else if (code >= 0xFF01 && code <= 0xFF5E) {
      buffer += String.fromCharCode(code - 0xFEE0);
    } else {
      buffer += String.fromCharCode(code);
    }
  }
  // 去空白
  buffer = buffer.split(' ').join('').split('\n').join('')
    .split('\r').join('').split('\t').join('');
  // 只保留字母数字下划线、中日文与假名
  let kept: string = '';
  for (let i = 0; i < buffer.length; i++) {
    if (isKeptChar(buffer.charCodeAt(i))) {
      kept += buffer.charAt(i);
    }
  }
  // 连续 3 个以上相同字符压成 3 个
  let out: string = '';
  for (let i = 0; i < kept.length; i++) {
    const ch: string = kept.charAt(i);
    const run: number = trailingRun(out, ch);
    if (run < 3) {
      out += ch;
    }
  }
  return out;
}

function isKeptChar(code: number): boolean {
  const isDigit: boolean = code >= 0x30 && code <= 0x39;
  const isUpper: boolean = code >= 0x41 && code <= 0x5A;
  const isLower: boolean = code >= 0x61 && code <= 0x7A;
  const isUnderscore: boolean = code === 0x5F;
  const isCjk: boolean = code >= 0x4E00 && code <= 0x9FFF;
  const isKana: boolean = (code >= 0x3040 && code <= 0x309F)
    || (code >= 0x30A0 && code <= 0x30FF)
    || (code >= 0x31F0 && code <= 0x31FF)
    || (code >= 0xFF65 && code <= 0xFF9F);
  return isDigit || isUpper || isLower || isUnderscore || isCjk || isKana;
}

function trailingRun(text: string, ch: string): number {
  let count: number = 0;
  for (let i = text.length - 1; i >= 0; i--) {
    if (text.charAt(i) === ch) {
      count += 1;
    } else {
      break;
    }
  }
  return count;
}

// ---------------- 接口响应 ----------------

/** `/api/v2/search/episodes` 的番剧条目。 */
export class DanmakuSearchAnime {
  animeId: number = 0;
  animeTitle: string = '';
  typeDescription: string = '';

  static fromJson(json: Record<string, Object>): DanmakuSearchAnime {
    const item = new DanmakuSearchAnime();
    item.animeId = JsonUtils.intOf(json, 'animeId');
    item.animeTitle = JsonUtils.str(json, 'animeTitle');
    item.typeDescription = JsonUtils.str(json, 'typeDescription');
    return item;
  }
}

/** 弹弹play 分集。 */
export class DanmakuEpisode {
  episodeId: number = 0;
  episodeTitle: string = '';
  /**
   * 上游的集号字符串。
   *
   * 用它把**本地集号**映射到**真实 episodeId**：上游的分集编号并不总是
   * 从 1 连续排（RE0 第二季里就有 `episodeNumber = "C2"`、
   * `episodeId = 147929102` 这种特典），靠 `番剧id * 10000 + 集号` 猜
   * 会在这些条目上整集取不到弹幕。
   */
  episodeNumber: string = '';

  static fromJson(json: Record<string, Object>): DanmakuEpisode {
    const episode = new DanmakuEpisode();
    episode.episodeId = JsonUtils.intOf(json, 'episodeId');
    episode.episodeTitle = JsonUtils.str(json, 'episodeTitle');
    episode.episodeNumber = JsonUtils.str(json, 'episodeNumber');
    return episode;
  }

  toJson(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['episodeId'] = this.episodeId;
    out['episodeTitle'] = this.episodeTitle;
    out['episodeNumber'] = this.episodeNumber;
    return out;
  }
}

/** `/api/v2/bangumi/{id}` 与 `/bgmtv/{bgmId}` 的响应。 */
export class DanmakuEpisodeResponse {
  bangumiId: number = 0;
  episodes: DanmakuEpisode[] = [];
  errorCode: number = 0;
  success: boolean = false;
  errorMessage: string = '';

  static fromJson(json: Record<string, Object>): DanmakuEpisodeResponse {
    const response = new DanmakuEpisodeResponse();
    const bangumi: Record<string, Object> | null = JsonUtils.obj(json, 'bangumi');
    if (bangumi !== null) {
      response.bangumiId = JsonUtils.intOf(bangumi, 'animeId');
      const list: Object[] = JsonUtils.arr(bangumi, 'episodes');
      for (let i = 0; i < list.length; i++) {
        const rec: Record<string, Object> | null = JsonUtils.asObj(list[i]);
        if (rec !== null) {
          response.episodes.push(DanmakuEpisode.fromJson(rec));
        }
      }
    }
    response.errorCode = JsonUtils.intOf(json, 'errorCode');
    response.success = JsonUtils.boolOf(json, 'success');
    response.errorMessage = JsonUtils.str(json, 'errorMessage');
    return response;
  }
}
