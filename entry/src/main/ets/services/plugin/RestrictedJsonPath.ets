/**
 * 受限 JSONPath。
 * 逐行等价移植参照实现 `lib/services/plugin/api_rule_strategy.dart` 的
 * `RestrictedJsonPath`（上游基于 `json_path` 包，但**只允许**下面这些语法）。
 *
 * 为什么要「受限」：规则是用户可编辑的文本，放开完整 JSONPath
 * （递归下降、过滤器、脚本表达式）等于把任意求值交给规则文件。
 * 这里与源码一样只支持：
 *   `$.a.b`、`$[0]`、`$[*]`、`$['key']`、`$["key"]`，以及它们的组合。
 */

/** 一个路径片段。 */
enum StepKind {
  name = 0,
  index = 1,
  wildcard = 2
}

class JsonPathStep {
  readonly kind: StepKind;
  readonly name: string;
  readonly index: number;

  constructor(kind: StepKind, name: string, index: number) {
    this.kind = kind;
    this.name = name;
    this.index = index;
  }
}

export class ApiRuleFormatException extends Error {
  constructor(message: string) {
    super(`ApiRuleFormatException: ${message}`);
  }
}

export class RestrictedJsonPath {
  /** 校验表达式；不合法直接抛（插件编辑器保存前也会调用）。 */
  static validate(expression: string): void {
    RestrictedJsonPath.parse(expression);
  }

  /** 读取所有匹配值（对应 `JsonPath(expr).readValues(document)`）。 */
  static read(document: Object | undefined, expression: string): (Object | undefined)[] {
    const steps: JsonPathStep[] = RestrictedJsonPath.parse(expression);
    let current: (Object | undefined)[] = [document];
    for (let s = 0; s < steps.length; s++) {
      const step: JsonPathStep = steps[s];
      const next: (Object | undefined)[] = [];
      for (let i = 0; i < current.length; i++) {
        const value: Object | undefined = current[i];
        if (value === undefined || value === null) {
          continue;
        }
        if (step.kind === StepKind.name) {
          const rec: Record<string, Object> | null = RestrictedJsonPath.asObject(value);
          if (rec !== null) {
            const child: Object | undefined = rec[step.name];
            if (child !== undefined) {
              next.push(child);
            }
          }
        } else if (step.kind === StepKind.index) {
          if (Array.isArray(value)) {
            const arr: Object[] = value as Object[];
            if (step.index >= 0 && step.index < arr.length) {
              next.push(arr[step.index]);
            }
          }
        } else {
          if (Array.isArray(value)) {
            const arr: Object[] = value as Object[];
            for (let j = 0; j < arr.length; j++) {
              next.push(arr[j]);
            }
          } else {
            // `[*]` 作用于对象时取全部值（与 json_path 一致）
            const rec: Record<string, Object> | null = RestrictedJsonPath.asObject(value);
            if (rec !== null) {
              const keys: string[] = Object.keys(rec);
              for (let j = 0; j < keys.length; j++) {
                next.push(rec[keys[j]]);
              }
            }
          }
        }
      }
      current = next;
    }
    return current;
  }

  /** 第一个匹配值；没有则返回 undefined。 */
  static readFirst(document: Object | undefined, expression: string): Object | undefined {
    const values: (Object | undefined)[] = RestrictedJsonPath.read(document, expression);
    return values.length === 0 ? undefined : values[0];
  }

  private static asObject(value: Object | undefined): Record<string, Object> | null {
    if (value === undefined || value === null || typeof value !== 'object' ||
      Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }

  /** 解析并校验（validate 与 read 共用，保证两边语法完全一致）。 */
  private static parse(expression: string): JsonPathStep[] {
    if (expression.length === 0 || !expression.startsWith('$')) {
      throw new ApiRuleFormatException(`JSONPath 必须以 $ 开头: ${expression}`);
    }
    const steps: JsonPathStep[] = [];
    let index: number = 1;
    while (index < expression.length) {
      const char: string = expression.charAt(index);
      if (char === '.') {
        index++;
        const start: number = index;
        while (index < expression.length &&
          /[A-Za-z0-9_$-]/.test(expression.charAt(index))) {
          index++;
        }
        if (index === start) {
          throw new ApiRuleFormatException(`不支持的 JSONPath: ${expression}`);
        }
        steps.push(new JsonPathStep(StepKind.name,
          expression.substring(start, index), -1));
        continue;
      }
      if (char === '[') {
        const end: number = RestrictedJsonPath.findBracketEnd(expression, index);
        const content: string = expression.substring(index + 1, end).trim();
        if (/^\d+$/.test(content)) {
          steps.push(new JsonPathStep(StepKind.index, '',
            Number.parseInt(content, 10)));
        } else if (content === '*') {
          steps.push(new JsonPathStep(StepKind.wildcard, '', -1));
        } else if (content.length >= 2 &&
          ((content.startsWith("'") && content.endsWith("'")) ||
            (content.startsWith('"') && content.endsWith('"')))) {
          steps.push(new JsonPathStep(StepKind.name,
            content.substring(1, content.length - 1), -1));
        } else {
          throw new ApiRuleFormatException(`不支持的 JSONPath 片段: [${content}]`);
        }
        index = end + 1;
        continue;
      }
      throw new ApiRuleFormatException(`不支持的 JSONPath: ${expression}`);
    }
    return steps;
  }

  /** 找到配对的 `]`，正确处理引号与转义。 */
  private static findBracketEnd(expression: string, start: number): number {
    let quote: string = '';
    let escaped: boolean = false;
    for (let i = start + 1; i < expression.length; i++) {
      const char: string = expression.charAt(i);
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char === '\\') {
        escaped = true;
        continue;
      }
      if (quote.length > 0) {
        if (char === quote) {
          quote = '';
        }
        continue;
      }
      if (char === "'" || char === '"') {
        quote = char;
        continue;
      }
      if (char === ']') {
        return i;
      }
    }
    throw new ApiRuleFormatException(`JSONPath 缺少 ]: ${expression}`);
  }
}
