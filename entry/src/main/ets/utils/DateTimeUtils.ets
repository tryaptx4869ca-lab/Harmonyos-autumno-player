/**
 * 日期工具。
 * 移植自参照实现 `lib/utils/date_time.dart` 中数据模型用到的部分。
 */
export class DateTimeUtils {
  /**
   * 把 `YYYY-MM-DD` 转成星期序号（1=周一 … 7=周日）。
   * 解析失败返回 1——与源码一致（源码 `catch` 后返回 1）。
   *
   * 注意：源码用 Dart `DateTime.parse`，它按本地时区解析纯日期；
   * 这里用 `Date.UTC` 再取 UTC 星期，避免鸿蒙时区/夏令时把日期挪一天。
   */
  static dateStringToWeekday(dateString: string): number {
    const parts: string[] = DateTimeUtils.parseDateParts(dateString);
    if (parts.length !== 3) {
      return 1;
    }
    const year: number = Number.parseInt(parts[0], 10);
    const month: number = Number.parseInt(parts[1], 10);
    const day: number = Number.parseInt(parts[2], 10);
    if (Number.isNaN(year) || Number.isNaN(month) || Number.isNaN(day)) {
      return 1;
    }
    const weekday: number = new Date(Date.UTC(year, month - 1, day)).getUTCDay();
    // JS: 0=周日 … 6=周六；Dart: 1=周一 … 7=周日
    return weekday === 0 ? 7 : weekday;
  }

  /** 规范化成 `YYYY-MM-DD`；无法解析时原样返回（源码 `formatDate`）。 */
  static formatDate(dateString: string): string {
    const parts: string[] = DateTimeUtils.parseDateParts(dateString);
    if (parts.length !== 3) {
      return dateString;
    }
    return DateTimeUtils.padDate(parts[0], parts[1], parts[2]);
  }

  /** 取日期中的年 / 月 / 日文本，非日期返回空数组。 */
  private static parseDateParts(dateString: string): string[] {
    const trimmed: string = dateString.trim();
    if (trimmed.length < 10) {
      return [];
    }
    const y: string = trimmed.substring(0, 4);
    const m: string = trimmed.substring(5, 7);
    const d: string = trimmed.substring(8, 10);
    if (trimmed.charAt(4) !== '-' || trimmed.charAt(7) !== '-') {
      return [];
    }
    return [y, m, d];
  }

  private static padDate(y: string, m: string, d: string): string {
    const year: number = Number.parseInt(y, 10);
    const month: number = Number.parseInt(m, 10);
    const day: number = Number.parseInt(d, 10);
    if (Number.isNaN(year) || Number.isNaN(month) || Number.isNaN(day)) {
      return `${y}-${m}-${d}`;
    }
    return `${year.toString().padStart(4, '0')}-` +
      `${month.toString().padStart(2, '0')}-` +
      `${day.toString().padStart(2, '0')}`;
  }
}
