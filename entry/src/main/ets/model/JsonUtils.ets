/**
 * JSON 取值小工具。
 *
 * ArkTS 没有 `dynamic`，读 JSON 只能逐字段转型，因此把「安全取值」
 * 收在一处，避免每个模型里重复写转型代码。
 * 所有函数都按参照实现的默认值语义返回：取不到就给默认值，绝不抛异常。
 */
export class JsonUtils {
  /** 取对象；不是对象返回 null。 */
  static obj(json: Record<string, Object>, key: string): Record<string, Object> | null {
    const v: Object | undefined = json[key];
    if (v === undefined || v === null || typeof v !== 'object' || Array.isArray(v)) {
      return null;
    }
    return v as Record<string, Object>;
  }

  /** 取字符串；null/undefined → ''。 */
  static str(json: Record<string, Object>, key: string, fallback: string = ''): string {
    const v: Object | undefined = json[key];
    if (v === undefined || v === null) {
      return fallback;
    }
    return v.toString();
  }

  /** 取数字；非数字 → 0。 */
  static num(json: Record<string, Object>, key: string, fallback: number = 0): number {
    const v: Object | undefined = json[key];
    if (v === undefined || v === null) {
      return fallback;
    }
    const n: number = Number(v);
    return Number.isNaN(n) ? fallback : n;
  }

  /** 取整数（Dart `(json['x'] as num?)?.toInt()`）。 */
  static intOf(json: Record<string, Object>, key: string, fallback: number = 0): number {
    const v: Object | undefined = json[key];
    if (v === undefined || v === null) {
      return fallback;
    }
    const n: number = Number(v);
    return Number.isNaN(n) ? fallback : Math.trunc(n);
  }

  /** 取布尔；非布尔按 false。 */
  static boolOf(json: Record<string, Object>, key: string, fallback: boolean = false): boolean {
    const v: Object | undefined = json[key];
    if (v === undefined || v === null) {
      return fallback;
    }
    if (typeof v === 'boolean') {
      return v as boolean;
    }
    return `${v}` === 'true';
  }

  /** 取数组；不是数组返回空数组。 */
  static arr(json: Record<string, Object>, key: string): Object[] {
    const v: Object | undefined = json[key];
    if (v === undefined || v === null || !Array.isArray(v)) {
      return [];
    }
    return v as Object[];
  }

  /** 元素当作对象读；不是对象返回 null。 */
  static asObj(value: Object): Record<string, Object> | null {
    if (value === null || value === undefined || typeof value !== 'object' ||
      Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }
}
