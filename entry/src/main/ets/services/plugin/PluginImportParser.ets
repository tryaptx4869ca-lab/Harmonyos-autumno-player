import { util } from '@kit.ArkTS';
import { Plugin, pluginNameKey } from '../../plugins/Plugin';
import { JsonUtils } from '../../model/JsonUtils';
import { ApiEndpoints } from '../../request/config/ApiEndpoints';

/**
 * 规则导入解析。移植自参照实现
 * `lib/services/plugin/plugin_import_parser.dart` + `lib/utils/encoding.dart`。
 *
 * 支持三种输入：
 *   1. 单个 JSON object
 *   2. JSON 数组（逐条解析，坏的记进 `failures`）
 *   3. 夹在聊天文本里的 `kazumi://` 分享链接（可能被 percent-encode，
 *      后面还可能跟着一段说明文字——所以按空白从后往前试更短的前缀）
 *
 * 三条与源码一致的硬约束：
 *   - 规则名不能为空
 *   - `api` 级别高于客户端的规则拒收（`requiresNewerClient`）
 *   - 同名规则**后者覆盖前者**，并计入 `duplicateCount`
 *
 * ## es2abc 触发点（2026-09-14 定位）
 *
 * 这份文件此前一直编译不过：`assembleHap` 报 `Failed to execute es2abc` →
 * `Type expected`，行号随改动平移但指向无关语句。**真正的触发点**经逐段重建
 * 定位为：
 *
 * ```
 * for (let i = 0; ...) {
 *   for (let j = 0; j < unique.length; j++) {
 *     unique[j] = current;      // ← 嵌套 for 里给数组元素下标赋值
 *   }
 * }
 * ```
 *
 * 把这段改成「查下标（独立方法）+ `splice` / `push`」后，同一个文件立刻编译通过；
 * 反过来，把这段原样抄到别的文件里，es2abc 会在**那个文件**上以同样的报错失败。
 * 因此同名去重这里一律走 `indexOfPluginName` 助手，不要写 `arr[i] = x`。
 */
export class PluginImportParseResult {
  readonly plugins: Plugin[];
  readonly failures: string[];
  readonly duplicateCount: number;

  constructor(plugins: Plugin[], failures: string[], duplicateCount: number) {
    this.plugins = plugins;
    this.failures = failures;
    this.duplicateCount = duplicateCount;
  }

  failureCount(): number {
    return this.failures.length;
  }
}

/** 一段 `kazumi://` 链接（scheme + 载荷）。 */
class RuleLinkSegment {
  readonly scheme: string;
  readonly rawPayload: string;

  constructor(scheme: string, rawPayload: string) {
    this.scheme = scheme;
    this.rawPayload = rawPayload;
  }
}

export class PluginImportParser {
  static parse(input: string): PluginImportParseResult {
    const value: string = input.trim();
    if (value.length === 0) {
      return new PluginImportParseResult([], ['导入内容为空'], 0);
    }
    const parsed: Plugin[] = [];
    const failures: string[] = [];

    let jsonValue: Object | null = null;
    let decodedAsJson: boolean = false;
    try {
      jsonValue = JSON.parse(value) as Object;
      decodedAsJson = true;
    } catch (e) {
      // 不是 JSON：下面按 kazumi:// 链接处理
      decodedAsJson = false;
    }

    if (decodedAsJson) {
      if (Array.isArray(jsonValue)) {
        const array: Object[] = jsonValue as Object[];
        for (let i = 0; i < array.length; i++) {
          PluginImportParser.parseEntry(array[i], i + 1, parsed, failures);
        }
      } else {
        PluginImportParser.parseEntry(jsonValue, 1, parsed, failures);
      }
    } else {
      const segments: RuleLinkSegment[] =
        PluginImportParser.findLinkSegments(value);
      if (segments.length === 0) {
        failures.push('未找到有效的 JSON 或 kazumi:// 规则链接');
      } else {
        for (let i = 0; i < segments.length; i++) {
          try {
            const entry: Record<string, Object> =
              PluginImportParser.decodeRuleEntry(segments[i].scheme,
                segments[i].rawPayload);
            PluginImportParser.parseEntry(entry, i + 1, parsed, failures);
          } catch (e) {
            const err = e as Error;
            failures.push(`第 ${i + 1} 条：${err.message}`);
          }
        }
      }
    }
    return PluginImportParser.dedupe(parsed, failures);
  }

  /**
   * 同名去重：保留首次出现的位置，值用后出现的那条。
   *
   * 刻意不写成 `unique[j] = parsed[i]`——那种「嵌套 for + 下标赋值」
   * 会让 es2abc 崩（见文件头注释）。
   */
  private static dedupe(parsed: Plugin[],
    failures: string[]): PluginImportParseResult {
    const unique: Plugin[] = [];
    let duplicateCount: number = 0;
    for (let i = 0; i < parsed.length; i++) {
      const current: Plugin = parsed[i];
      const at: number = PluginImportParser.indexOfPluginName(unique,
        pluginNameKey(current.name));
      if (at >= 0) {
        unique.splice(at, 1);
        unique.push(current);
        duplicateCount += 1;
      } else {
        unique.push(current);
      }
    }
    return new PluginImportParseResult(unique, failures, duplicateCount);
  }

  /** 按归一化后的规则名查下标（`pluginNameKey` 去重语义与源码一致）。 */
  private static indexOfPluginName(plugins: Plugin[], key: string): number {
    for (let i = 0; i < plugins.length; i++) {
      if (pluginNameKey(plugins[i].name) === key) {
        return i;
      }
    }
    return -1;
  }

  /** JSON 文本 → `kazumi://` 分享链接（源码 `jsonToKazumiBase64`）。 */
  static jsonToKazumiBase64(json: string): string {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(json);
    const base64: string = new util.Base64Helper().encodeToStringSync(bytes);
    return `kazumi://${base64}`;
  }

  /** `kazumi://` 链接 → JSON 文本（源码 `kazumiBase64ToJson`）。 */
  static kazumiBase64ToJson(link: string): string {
    const input: string = link.trim();
    const schemeMatch: RegExpMatchArray | null =
      input.match(new RegExp('^kazumi:(?://)?', 'i'));
    if (schemeMatch === null) {
      throw new Error('不是 kazumi 规则链接');
    }
    let payload: string = input.substring(schemeMatch[0].length);
    try {
      payload = decodeURIComponent(payload);
    } catch (e) {
      throw new Error('规则链接编码无效');
    }
    payload = PluginImportParser.stripWhitespace(payload);
    if (payload.length === 0) {
      throw new Error('规则链接为空');
    }
    // 兼容标准与 URL-safe Base64、允许缺 padding
    let normalized: string = payload.split('-').join('+').split('_').join('/');
    const remainder: number = normalized.length % 4;
    if (remainder === 2) {
      normalized += '==';
    } else if (remainder === 3) {
      normalized += '=';
    } else if (remainder === 1) {
      throw new Error('规则链接载荷无效');
    }
    try {
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(normalized);
      return new util.TextDecoder().decodeToString(bytes);
    } catch (e) {
      throw new Error('规则链接载荷无效');
    }
  }

  /** 去掉所有空白（不用全局正则的 `replace`，行为等价、更直观）。 */
  private static stripWhitespace(text: string): string {
    return text.split(' ').join('').split('\n').join('')
      .split('\r').join('').split('\t').join('');
  }

  /** 找出文本里所有 `kazumi:` / `kazumi://` 段（源码 `findKazumiRuleLinkSegments`）。 */
  private static findLinkSegments(input: string): RuleLinkSegment[] {
    const segments: RuleLinkSegment[] = [];
    const pattern = new RegExp('kazumi:(?://)?', 'gi');
    const starts: number[] = [];
    const ends: number[] = [];
    const schemes: string[] = [];
    let match: RegExpExecArray | null = pattern.exec(input);
    while (match !== null) {
      starts.push(match.index);
      ends.push(match.index + match[0].length);
      schemes.push(match[0]);
      match = pattern.exec(input);
    }
    for (let i = 0; i < starts.length; i++) {
      const end: number = i + 1 < starts.length ? starts[i + 1] : input.length;
      segments.push(new RuleLinkSegment(schemes[i],
        input.substring(ends[i], end)));
    }
    return segments;
  }

  /** 链接段 → JSON object；按空白从后往前试短前缀，兼容链接后跟说明文字。 */
  private static decodeRuleEntry(scheme: string,
    rawPayload: string): Record<string, Object> {
    const prefix: RegExpMatchArray | null = rawPayload.match(
      PluginImportParser.linkPayloadPrefix());
    const payload: string = prefix === null ? '' : prefix[0].trim();
    if (payload.length === 0) {
      throw new Error('规则链接缺少载荷');
    }
    const candidates: string[] = [payload];
    const cuts: number[] = [];
    for (let i = 0; i < payload.length; i++) {
      const ch: string = payload.substring(i, i + 1);
      if (ch === ' ' || ch === '\n' || ch === '\r' || ch === '\t') {
        cuts.push(i);
      }
    }
    for (let i = cuts.length - 1; i >= 0; i--) {
      const candidate: string = payload.substring(0, cuts[i]).trim();
      if (candidate.length > 0
        && candidate !== candidates[candidates.length - 1]) {
        candidates.push(candidate);
      }
    }

    let firstError: string = '';
    for (let i = 0; i < candidates.length; i++) {
      try {
        const decoded: Object =
          JSON.parse(PluginImportParser.kazumiBase64ToJson(
            `${scheme}${candidates[i]}`)) as Object;
        const rec: Record<string, Object> | null = JsonUtils.asObj(decoded);
        if (rec !== null) {
          return rec;
        }
        if (firstError.length === 0) {
          firstError = '规则链接内容必须是 JSON object';
        }
      } catch (e) {
        const err = e as Error;
        if (firstError.length === 0) {
          firstError = err.message;
        }
      }
    }
    throw new Error(firstError.length === 0 ? '无效的规则链接' : firstError);
  }

  /** 链接载荷允许的字符前缀（源码 `_ruleLinkPayloadPrefixPattern`）。 */
  private static linkPayloadPrefix(): RegExp {
    return new RegExp('^[A-Za-z0-9+/_=%\\-\\s]+');
  }

  /**
   * 完整性校验：一条能用的规则至少要有站点根地址 + 一条搜索通路。
   *
   * 判据（两边任一模式通过即可）：
   *   - 搜索：`searchURL` + `searchList`（XPath 模式），或 `searchApiConfig.request.url`（API 模式）；
   *   - 章节：`chapterRoads` + `chapterResult`，或 `chapterApiConfig.request.url`。
   *
   * 只报**缺了什么**，不改数据：调用方决定是跳过还是回头提示用户。
   */
  private static assertComplete(plugin: Plugin): void {
    const missing: string[] = [];
    if (plugin.baseUrl.trim().length === 0) {
      missing.push('baseURL（站点根地址）');
    }
    const xpathSearch: boolean = plugin.searchURL.trim().length > 0
      && plugin.searchList.trim().length > 0;
    const apiSearch: boolean = plugin.searchApiConfig.request.url.trim().length > 0;
    if (!xpathSearch && !apiSearch) {
      missing.push('searchURL / searchList（或 searchApiConfig）');
    }
    const xpathChapter: boolean = plugin.chapterRoads.trim().length > 0
      && plugin.chapterResult.trim().length > 0;
    const apiChapter: boolean = plugin.chapterApiConfig.request.url.trim().length > 0;
    if (!xpathChapter && !apiChapter) {
      missing.push('chapterRoads / chapterResult（或 chapterApiConfig）');
    }
    if (missing.length > 0) {
      throw new Error(`不是完整规则，缺少 ${missing.join('、')}`);
    }
  }

  /**
   * 解析一条条目。
   *
   * `entry` 为 `Object | null`：能当 object 用的走 `Plugin.fromJson`，
   * 否则按「文本形式的规则」处理（`kazumi://` 链接）。
   */
  private static parseEntry(entry: Object | null, index: number,
    plugins: Plugin[], failures: string[]): void {
    try {
      let plugin: Plugin | null = null;
      const rec: Record<string, Object> | null =
        entry === null ? null : JsonUtils.asObj(entry);
      if (rec !== null) {
        plugin = Plugin.fromJson(rec);
      } else {
        const text: string = entry === null ? '' : `${entry}`.trim();
        if (text.length === 0) {
          throw new Error('规则必须是 JSON object 或 kazumi:// 链接');
        }
        const decoded: Object =
          JSON.parse(PluginImportParser.kazumiBase64ToJson(text)) as Object;
        const fromText: Record<string, Object> | null = JsonUtils.asObj(decoded);
        if (fromText === null) {
          throw new Error('规则链接内容必须是 JSON object');
        }
        plugin = Plugin.fromJson(fromText);
      }
      if (plugin === null) {
        throw new Error('规则解析失败');
      }
      if (plugin.name.trim().length === 0) {
        throw new Error('规则名称不能为空');
      }
      if (plugin.requiresNewerClient(ApiEndpoints.apiLevel)) {
        throw new Error('规则需要更高版本客户端');
      }
      /**
       * 完整性校验：只有 `name` 的「规则」不许入库。
       *
       * 起因（2026-10-31）：用户在别处拿到一批 `kazumi://` 链接，解出来是
       * `{"name":"1AN","url":"https://www.1ani.com","rules":[]}`——那是**站点清单**
       * 条目，不是 Kazumi 规则（真规则用 `baseURL` + 各 xpath）。`url`/`rules`
       * 我们都不读，于是导入“成功”，列表里却是一条点开空空、搜不出东西的规则。
       *
       * 现在缺关键字段就报清楚缺什么，宁可不导入。
       */
      PluginImportParser.assertComplete(plugin);
      plugins.push(plugin);
    } catch (e) {
      const err = e as Error;
      failures.push(`第 ${index} 条：${err.message}`);
    }
  }
}
