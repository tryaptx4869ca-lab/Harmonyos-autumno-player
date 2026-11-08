import { formatDateParts, weekdayName } from './SearchDates';

/**
 * 搜索过滤状态与查询串解析。
 *
 * 对应参照实现 `lib/utils/search_parser.dart`：搜索页的「按条件查找」面板
 * 与搜索框共用同一种查询语法——
 *
 *   `葬送的芙莉莲 tag:奇幻 season:2024Q3 score:7..10 weekday:1,4`
 *
 * 面板编辑结构化 `SearchFilterState`，落到搜索框时序列化成上面这串 token，
 * 反过来再把用户手输的 token 解析回结构体；两边共用一份实现才不会各说各话。
 */

/** 排序选项（参照实现 `_searchSortLabels`，顺序一致）。 */
export class SearchSortOption {
  readonly key: string;
  readonly label: string;

  constructor(key: string, label: string) {
    this.key = key;
    this.label = label;
  }
}

export const searchSortOptions: SearchSortOption[] = [
  new SearchSortOption('heat', '热度'),
  new SearchSortOption('rank', '排名'),
  new SearchSortOption('score', '评分'),
  new SearchSortOption('match', '匹配')
];

export function searchSortLabel(key: string): string {
  for (let i = 0; i < searchSortOptions.length; i++) {
    if (searchSortOptions[i].key === key) {
      return searchSortOptions[i].label;
    }
  }
  return '热度';
}

/** 默认题材标签（参照实现 `utils/constants.dart` 的 `defaultAnimeTags`）。 */
export const defaultAnimeTags: string[] = [
  '日常',
  '原创',
  '校园',
  '搞笑',
  '奇幻',
  '百合',
  '恋爱',
  '悬疑',
  '热血',
  '后宫',
  '机战',
  '轻改',
  '偶像',
  '治愈',
  '异世界'
];

/** 日期区间（`YYYY-MM-DD`）。 */
export class SearchDateRange {
  start: string = '';
  end: string = '';

  constructor(start: string = '', end: string = '') {
    this.start = start;
    this.end = end;
  }

  isValid(): boolean {
    return this.start.length > 0 && this.end.length > 0;
  }
}

/** 整数区间，`toToken()` 输出 `min..max`（缺省一侧留空）。 */
export class SearchIntRange {
  min: number = 0;
  max: number = 0;
  hasMin: boolean = false;
  hasMax: boolean = false;

  constructor(min: number = 0, max: number = 0, hasMin: boolean = true,
    hasMax: boolean = true) {
    this.min = min;
    this.max = max;
    this.hasMin = hasMin;
    this.hasMax = hasMax;
  }

  isValid(): boolean {
    return this.hasMin || this.hasMax;
  }

  toToken(): string {
    const minText: string = this.hasMin ? `${this.min}` : '';
    const maxText: string = this.hasMax ? `${this.max}` : '';
    return `${minText}..${maxText}`;
  }
}

/** 浮点区间，`toToken()` 按参照实现去掉多余的 `.0`。 */
export class SearchDoubleRange {
  min: number = 0;
  max: number = 0;
  hasMin: boolean = false;
  hasMax: boolean = false;

  constructor(min: number = 0, max: number = 0, hasMin: boolean = true,
    hasMax: boolean = true) {
    this.min = min;
    this.max = max;
    this.hasMin = hasMin;
    this.hasMax = hasMax;
  }

  isValid(): boolean {
    return this.hasMin || this.hasMax;
  }

  toToken(): string {
    const minText: string = this.hasMin ? SearchDoubleRange.format(this.min) : '';
    const maxText: string = this.hasMax ? SearchDoubleRange.format(this.max) : '';
    return `${minText}..${maxText}`;
  }

  static format(value: number): string {
    const fixed: string = value.toFixed(1);
    return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
  }
}

/** 结构化过滤条件。字段与参照实现的 `SearchFilterState` 一一对应。 */
export class SearchFilterState {
  id: string = '';
  keyword: string = '';
  tags: string[] = [];
  sort: string = 'heat';
  season: string = '';
  dateRange: SearchDateRange | null = null;
  rankRange: SearchIntRange | null = null;
  scoreRange: SearchDoubleRange | null = null;
  weekdays: number[] = [];

  isIdSearch(): boolean {
    return this.id.length > 0;
  }

  /** 是否带「非默认」的条件（结果区据此显示筛选小圆点）。 */
  hasAdvancedFilters(): boolean {
    return this.tags.length > 0 || this.sort !== 'heat' || this.season.length > 0 ||
      this.dateRange !== null ||
      (this.rankRange !== null && this.rankRange.isValid()) ||
      (this.scoreRange !== null && this.scoreRange.isValid()) ||
      this.weekdays.length > 0;
  }

  /** 生效的日期区间：手选日期优先，其次季度。 */
  effectiveDateRange(): SearchDateRange | null {
    if (this.dateRange !== null) {
      return this.dateRange;
    }
    if (this.season.length === 0) {
      return null;
    }
    return SearchParser.seasonToDateRange(this.season);
  }

  clone(): SearchFilterState {
    const copy = new SearchFilterState();
    copy.id = this.id;
    copy.keyword = this.keyword;
    copy.tags = this.tags.slice();
    copy.sort = this.sort;
    copy.season = this.season;
    copy.dateRange = this.dateRange === null
      ? null : new SearchDateRange(this.dateRange.start, this.dateRange.end);
    copy.rankRange = this.rankRange === null ? null
      : new SearchIntRange(this.rankRange.min, this.rankRange.max,
        this.rankRange.hasMin, this.rankRange.hasMax);
    copy.scoreRange = this.scoreRange === null ? null
      : new SearchDoubleRange(this.scoreRange.min, this.scoreRange.max,
        this.scoreRange.hasMin, this.scoreRange.hasMax);
    copy.weekdays = this.weekdays.slice();
    return copy;
  }
}

export class SearchParser {
  /** token 字段名，与参照实现的 `_fieldNames` 一致。 */
  private static readonly fieldNames: string =
    'id|tag|sort|season|date|rank|score|weekday|nsfw';

  static toFilterState(query: string): SearchFilterState {
    const state = new SearchFilterState();
    state.id = SearchParser.parseId(query);
    state.keyword = SearchParser.parseKeywords(query);
    state.tags = SearchParser.parseTags(query);
    state.sort = SearchParser.parseSort(query);
    state.season = SearchParser.parseSeason(query);
    state.dateRange = SearchParser.parseDateRange(query);
    state.rankRange = SearchParser.parseRankRange(query);
    state.scoreRange = SearchParser.parseScoreRange(query);
    state.weekdays = SearchParser.parseWeekdays(query);
    return state;
  }

  /** 结构体序列化成查询串；全为默认时返回空串。 */
  static fromFilterState(state: SearchFilterState): string {
    if (state.id.length > 0) {
      return `id:${state.id}`;
    }
    const tokens: string[] = [];
    const keyword: string = state.keyword.trim();
    if (keyword.length > 0) {
      tokens.push(keyword);
    }
    for (let i = 0; i < state.tags.length; i++) {
      const tag: string = state.tags[i].trim();
      if (tag.length > 0) {
        tokens.push(`tag:${tag}`);
      }
    }
    if (state.sort.length > 0 && state.sort !== 'heat') {
      tokens.push(`sort:${state.sort}`);
    }
    if (state.season.length > 0) {
      tokens.push(`season:${state.season}`);
    } else if (state.dateRange !== null && state.dateRange.isValid()) {
      tokens.push(`date:${state.dateRange.start}..${state.dateRange.end}`);
    }
    if (state.rankRange !== null && state.rankRange.isValid()) {
      tokens.push(`rank:${state.rankRange.toToken()}`);
    }
    if (state.scoreRange !== null && state.scoreRange.isValid()) {
      tokens.push(`score:${state.scoreRange.toToken()}`);
    }
    if (state.weekdays.length > 0) {
      tokens.push(`weekday:${SearchParser.uniqueSorted(state.weekdays).join(',')}`);
    }
    return tokens.join(' ').trim();
  }

  /** `2024Q3` → 2024-07-01 ~ 2024-10-01（左闭右开）。 */
  static seasonToDateRange(season: string): SearchDateRange | null {
    const match: RegExpExecArray | null =
      new RegExp('^(\\d{4})Q([1-4])$', 'i').exec(season.trim());
    if (match === null) {
      return null;
    }
    const year: number = Number.parseInt(match[1], 10);
    const quarter: number = Number.parseInt(match[2], 10);
    const startMonth: number = (quarter - 1) * 3 + 1;
    return new SearchDateRange(
      formatDateParts(year, startMonth, 1),
      formatDateParts(year, startMonth + 3, 1));
  }

  /** 最近 20 年 × 4 季的季度键（新 → 旧），仅保留已经开始的季度。 */
  static seasonKeys(): string[] {
    const now: Date = new Date();
    const keys: string[] = [];
    for (let year = now.getFullYear(); year >= now.getFullYear() - 19; year--) {
      for (let quarter = 4; quarter >= 1; quarter--) {
        const start = new Date(year, (quarter - 1) * 3, 1);
        if (now.getTime() > start.getTime()) {
          keys.push(`${year}Q${quarter}`);
        }
      }
    }
    return keys;
  }

  /** 季度键 → `2026 3季` 的展示文案（搜索面板用）。 */
  static seasonDescription(key: string): string {
    const match: RegExpExecArray | null =
      new RegExp('^(\\d{4})Q([1-4])$').exec(key);
    if (match === null) {
      return key;
    }
    const names: string[] = ['冬季', '春季', '夏季', '秋季'];
    return `${match[1]} ${names[Number.parseInt(match[2], 10) - 1]}`;
  }

  /** 季度键 → `2026年夏季`（时间表标题用）。 */
  static seasonLabelFromKey(key: string): string {
    const match: RegExpExecArray | null =
      new RegExp('^(\\d{4})Q([1-4])$').exec(key);
    if (match === null) {
      return key;
    }
    const names: string[] = ['冬', '春', '夏', '秋'];
    return `${match[1]}年${names[Number.parseInt(match[2], 10) - 1]}季`;
  }

  static parseId(query: string): string {
    const match: RegExpExecArray | null = new RegExp('id:(\\d+)', 'i').exec(query);
    return match === null ? '' : match[1];
  }

  static parseTags(query: string): string[] {
    const out: string[] = [];
    const regex: RegExp = new RegExp(
      '(?:^|\\s)tag:([^\\s]+?)(?=(?:id|tag|sort|season|date|rank|score|weekday|nsfw):|\\s|$)',
      'ig');
    let match: RegExpExecArray | null = regex.exec(query);
    while (match !== null) {
      const value: string = match[1].trim();
      if (value.length > 0 && out.indexOf(value) < 0) {
        out.push(value);
      }
      match = regex.exec(query);
    }
    return out;
  }

  static parseSort(query: string): string {
    const match: RegExpExecArray | null =
      new RegExp('sort:([\\w\\-]+)', 'i').exec(query);
    return match === null ? 'heat' : match[1];
  }

  static parseSeason(query: string): string {
    const match: RegExpExecArray | null =
      new RegExp('season:(\\d{4}Q[1-4])', 'i').exec(query);
    return match === null ? '' : match[1].toUpperCase();
  }

  static parseDateRange(query: string): SearchDateRange | null {
    const match: RegExpExecArray | null =
      new RegExp('date:(\\d{4}-\\d{2}-\\d{2})\\.\\.(\\d{4}-\\d{2}-\\d{2})', 'i')
        .exec(query);
    if (match === null) {
      return null;
    }
    return new SearchDateRange(match[1], match[2]);
  }

  static parseRankRange(query: string): SearchIntRange | null {
    const match: RegExpExecArray | null =
      new RegExp('rank:(\\d*)\\.\\.(\\d*)', 'i').exec(query);
    if (match === null) {
      return null;
    }
    const minText: string = match[1];
    const maxText: string = match[2];
    const range: SearchIntRange = new SearchIntRange(
      minText.length > 0 ? Number.parseInt(minText, 10) : 0,
      maxText.length > 0 ? Number.parseInt(maxText, 10) : 0,
      minText.length > 0, maxText.length > 0);
    return range.isValid() ? range : null;
  }

  static parseScoreRange(query: string): SearchDoubleRange | null {
    const match: RegExpExecArray | null =
      new RegExp('score:(\\d+(?:\\.\\d+)?)?\\.\\.(\\d+(?:\\.\\d+)?)?', 'i').exec(query);
    if (match === null) {
      return null;
    }
    const minText: string = match[1] === undefined ? '' : match[1];
    const maxText: string = match[2] === undefined ? '' : match[2];
    const range: SearchDoubleRange = new SearchDoubleRange(
      minText.length > 0 ? Number.parseFloat(minText) : 0,
      maxText.length > 0 ? Number.parseFloat(maxText) : 0,
      minText.length > 0, maxText.length > 0);
    return range.isValid() ? range : null;
  }

  static parseWeekdays(query: string): number[] {
    const match: RegExpExecArray | null =
      new RegExp('weekday:([1-7](?:,[1-7])*)', 'i').exec(query);
    if (match === null) {
      return [];
    }
    const parts: string[] = match[1].split(',');
    const days: number[] = [];
    for (let i = 0; i < parts.length; i++) {
      const value: number = Number.parseInt(parts[i], 10);
      if (!Number.isNaN(value) && value >= 1 && value <= 7 && days.indexOf(value) < 0) {
        days.push(value);
      }
    }
    return days.sort((a: number, b: number) => a - b);
  }

  /** 关键词部分：去掉所有 token 后的剩余文本。 */
  static parseKeywords(query: string): string {
    const regex: RegExp = new RegExp(
      '(?:^|\\s)?(?:' + SearchParser.fieldNames +
      '):[^\\s]*?(?=(?:\\s|$)|(?:' + SearchParser.fieldNames + '):)',
      'gi');
    return query.replace(regex, ' ').replace(new RegExp('\\s+', 'g'), ' ').trim();
  }

  private static uniqueSorted(days: number[]): number[] {
    const out: number[] = [];
    for (let i = 0; i < days.length; i++) {
      if (out.indexOf(days[i]) < 0) {
        out.push(days[i]);
      }
    }
    return out.sort((a: number, b: number) => a - b);
  }
}

/** 结果区条件摘要（参照实现 `_filterSummary`）。 */
export function filterSummary(state: SearchFilterState): string {
  const parts: string[] = [];
  for (let i = 0; i < state.tags.length; i++) {
    parts.push(state.tags[i]);
  }
  if (state.season.length > 0) {
    parts.push(state.season);
  }
  if (state.season.length === 0 && state.dateRange !== null) {
    parts.push(`${state.dateRange.start} 至 ${state.dateRange.end}`);
  }
  if (state.scoreRange !== null && state.scoreRange.isValid()) {
    parts.push(`评分 ${state.scoreRange.toToken()}`);
  }
  if (state.rankRange !== null && state.rankRange.isValid()) {
    parts.push(`排名 ${state.rankRange.toToken()}`);
  }
  if (state.weekdays.length > 0) {
    const names: string[] = [];
    for (let i = 0; i < state.weekdays.length; i++) {
      names.push(weekdayName(state.weekdays[i]));
    }
    parts.push(`周${names.join('、')}`);
  }
  return parts.join(' · ');
}

/** 最近搜索条目的可读文案（参照实现 `_readableQuery`）。 */
export function readableQuery(query: string): string {
  const state: SearchFilterState = SearchParser.toFilterState(query);
  const parts: string[] = [];
  if (state.keyword.length > 0) {
    parts.push(state.keyword);
  }
  if (state.id.length > 0) {
    parts.push(`条目 ${state.id}`);
  }
  const summary: string = filterSummary(state);
  if (summary.length > 0) {
    parts.push(summary);
  }
  if (state.sort !== 'heat') {
    parts.push(`${searchSortLabel(state.sort)}排序`);
  }
  return parts.join(' · ');
}
