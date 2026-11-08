/**
 * Bangumi 标签。
 * 逐字移植自参照实现 `lib/modules/bangumi/bangumi_tag.dart`。
 *
 * Hive 编号：typeId 4，字段 0/1/2 —— 原生版落库时沿用同样的编号，
 * 方便日后做数据迁移或与 Flutter 版对照。
 */
export class BangumiTag {
  /** @HiveField(0) */
  name: string = '';
  /** @HiveField(1) */
  count: number = 0;
  /** @HiveField(2) */
  totalCount: number = 0;

  static fromJson(json: Record<string, Object>): BangumiTag {
    const tag = new BangumiTag();
    tag.name = BangumiTag.str(json, 'name');
    tag.count = BangumiTag.num(json, 'count');
    // 注意上游拼写就是 total_cont（不是 total_count），不能"顺手修正"
    tag.totalCount = BangumiTag.num(json, 'total_cont');
    return tag;
  }

  toJson(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['name'] = this.name;
    out['count'] = this.count;
    out['total_cont'] = this.totalCount;
    return out;
  }

  private static str(json: Record<string, Object>, key: string): string {
    const v: Object | undefined = json[key];
    return v === undefined || v === null ? '' : v.toString();
  }

  private static num(json: Record<string, Object>, key: string): number {
    const v: Object | undefined = json[key];
    if (v === undefined || v === null) {
      return 0;
    }
    const n: number = Number(v);
    return Number.isNaN(n) ? 0 : Math.trunc(n);
  }
}
