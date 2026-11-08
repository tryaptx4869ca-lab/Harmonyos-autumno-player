/**
 * 搜索 / 时间表共用的日期与季度工具。
 *
 * 对应参照实现的 `lib/utils/anime_season.dart` 与 `lib/utils/date_time.dart`
 * 中与季度、格式化相关的部分。
 */

/** `1` → `一`（周几的中文写法）。 */
export function weekdayName(day: number): string {
  const names: string[] = ['一', '二', '三', '四', '五', '六', '日'];
  return day >= 1 && day <= 7 ? names[day - 1] : '';
}

/** 月份 → 季度名（参照实现 `getSeasonStringByMonth`）。 */
export function seasonNameByMonth(month: number): string {
  if (month <= 3) {
    return '冬';
  }
  if (month <= 6) {
    return '春';
  }
  if (month <= 9) {
    return '夏';
  }
  return '秋';
}

/**
 * `YYYY-MM-DD`（与参照实现的 `formatDateTime` 对齐，用于接口参数）。
 *
 * **月份允许越界，并会归一化到相邻年份**（13 → 次年 1 月、0 → 上一年 12 月）。
 *
 * 这不是锦上添花，是参照实现的语义：Kazumi 那边用的是 Dart 的
 * `DateTime(year, month, day)`，越界月份由 Dart 自动归一化——
 * `DateTime(2025, 13, 1)` 就是 2026-01-01。原来这里直接 `pad(month)` 拼串，
 * 于是**每个「10 月季」都拼出 `2025-13-01`**：镜像端直接回
 * `{"error":{"code":"invalid_request","message":"invalid season end date"}}`，
 * 解析出来 7 天全空，表现就是「10 月番全都没有数据」——2025 年、2024 年……
 * 往前每一年的秋季都中招（用户 2026-09-18：「主要是 2025 年包括前几年的
 * 10 月好像也没有数据」）。
 *
 * 用纯算数归一化，不走 `Date`，免得受时区/夏令时影响：
 *   normalizedYear  = year + floor((month - 1) / 12)
 *   normalizedMonth = ((month - 1) mod 12 + 12) mod 12 + 1
 */
export function formatDateParts(year: number, month: number, day: number): string {
  const normalizedYear: number = year + Math.floor((month - 1) / 12);
  const normalizedMonth: number = ((month - 1) % 12 + 12) % 12 + 1;
  return `${pad(normalizedYear, 4)}-${pad(normalizedMonth, 2)}-${pad(day, 2)}`;
}

/**
 * `2026年7月`——**季度起点月份**。
 *
 * 用户 2026-09-18：「秋季是不是没有番剧，要不去掉？变成 2026年1月 / 4月 / 7月
 * 这种？」——先说明事实：**秋季有番**（10–12 月是番剧大季），只是**2026 秋季
 * 还没到**，所以菜单里不列（未来的季度没有数据，见
 * `TimetablePage.seasonDatesOfYear` 的 `now > start` 判断）。
 *
 * 「冬季 / 秋季」这种季名表达不出「这个季度从几月开始、有没有到」，换成起点
 * 月份之后一眼就能看出来，也不再有「秋季是不是没番」的疑问。1/4/7/10 月与四个
 * 季度一一对应，**只是换了个说法，数据口径完全没变**。
 */
export function seasonLabel(date: Date): string {
  return `${date.getFullYear()}年${date.getMonth() + 1}月`;
}

/** `2026Q3` 形式的季度键（搜索面板与季度下拉共用）。 */
export function seasonKey(date: Date): string {
  return `${date.getFullYear()}Q${Math.floor(date.getMonth() / 3) + 1}`;
}

/** `2026-07` 形式的季度起点键（时间表季度下拉用）。 */
export function seasonMonthKey(date: Date): string {
  return `${date.getFullYear()}-${date.getMonth() + 1}`;
}

/**
 * 时间表季度区间。
 *
 * 对应 `AnimeSeason.toSeasonStartAndEnd()`：取「上一个季度起点 → 本季度起点」，
 * 因为放送日通常比季度首日早几天。起止都用 `DateTime.toString()` 的完整格式
 * （`2024-06-01 00:00:00.000`），镜像接口按这个格式解析。
 */
export class AnimeSeasonRange {
  readonly start: string;
  readonly end: string;

  constructor(start: string, end: string) {
    this.start = start;
    this.end = end;
  }

  static of(date: Date): AnimeSeasonRange {
    const year: number = date.getFullYear();
    const month: number = date.getMonth() + 1;
    const season: number = Math.floor((month - 1) / 3);
    const endMonth: number = (season + 1) * 3 + 1;
    // startMonth = 0（冬季）交给 `formatDateParts` 归一化成「上一年 12 月」，
    // 与 Dart 的 DateTime(year, 0, 1) 完全一致；endMonth 到 13（秋季）同理
    // 归一化成「次年 1 月」——这一条就是上面那个「10 月季没有数据」的修复。
    const startMonth: number = season * 3;
    return new AnimeSeasonRange(
      `${formatDateParts(year, startMonth, 1)} 00:00:00.000`,
      `${formatDateParts(year, endMonth, 1)} 00:00:00.000`);
  }
}

/** 两个日期是否落在同一季。 */
export function isSameSeason(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() &&
    Math.floor(a.getMonth() / 3) === Math.floor(b.getMonth() / 3);
}

function pad(value: number, width: number): string {
  return `${value}`.padStart(width, '0');
}
