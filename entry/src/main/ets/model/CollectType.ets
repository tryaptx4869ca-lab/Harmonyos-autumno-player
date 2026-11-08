/** 收藏类型。对应参照实现 lib/modules/collect/collect_type.dart。 */
export class CollectType {
  /** -1 表示「全部」；其余与 Bangumi 的收藏值一致 */
  value: number;
  label: string;
  icon: string;

  constructor(value: number, label: string, icon: string) {
    this.value = value;
    this.label = label;
    this.icon = icon;
  }
}
