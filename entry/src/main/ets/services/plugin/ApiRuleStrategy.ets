import { ApiBodyType, ApiChapterConfig, ApiChapterFormat, ApiEpisodePageConfig, ApiRequestConfig, ApiSearchConfig } from '../../plugins/ApiRuleConfig';
import { JsonUtils } from '../../model/JsonUtils';
import { Road, SearchItem } from '../../model/SearchModels';
import { normalizeEpisodeUrl } from '../../utils/EpisodeUrl';
import { ApiRuleFormatException, RestrictedJsonPath } from './RestrictedJsonPath';
import { PreparedRuleRequest, RuleChapterParseResult, RuleSearchParseResult } from './RuleEngineModels';

/**
 * API 模式的规则策略。
 * 逐行对应参照实现 `lib/services/plugin/api_rule_strategy.dart`。
 *
 * 模板语法（与源码一致）：
 *   - 普通占位：`@name`，替换为变量值（可按需 URI 编码）
 *   - 整值占位：值**整体**等于 `@name` 时返回原始变量（不做字符串化）
 *   - 变量来源：搜索是 `keyword`；章节是 `source` + 规则声明的具名捕获
 *     + 播放页模板的 `episodeUrl / roadIndex / roadNumber / episodeIndex / episodeNumber`
 */
export class ApiRuleStrategy {
  /** 解析响应 JSON。 */
  static decodeResponse(raw: string): Object {
    try {
      return JSON.parse(raw) as Object;
    } catch (error) {
      const err = error as Error;
      throw new ApiRuleFormatException(`API 响应不是有效 JSON: ${err.message}`);
    }
  }

  /** 构造请求（渲染 URL / 头 / 查询 / 体）。 */
  static prepareRequest(config: ApiRequestConfig,
    variables: Map<string, Object | undefined>): PreparedRuleRequest {
    const method: string = config.method.toUpperCase();
    if (method !== 'GET' && method !== 'POST') {
      throw new ApiRuleFormatException(`仅支持 GET/POST，当前为 ${method}`);
    }
    if (config.url.trim().length === 0) {
      throw new ApiRuleFormatException('API 请求 URL 不能为空');
    }
    const url: string = ApiRuleStrategy.renderTemplate(config.url.trim(), variables, true);
    if (!ApiRuleStrategy.isValidUrl(url)) {
      throw new ApiRuleFormatException(`API 请求 URL 无效: ${url}`);
    }
    const hasBody: boolean = method === 'POST' && config.bodyType !== ApiBodyType.none;
    const headers: Record<string, string> = {};
    ApiRuleStrategy.renderMap(config.headers, variables, headers);
    const query: Record<string, Object> = {};
    ApiRuleStrategy.renderValueMap(config.query, variables, query);
    return new PreparedRuleRequest(method, url, headers, query, config.bodyType,
      hasBody ? ApiRuleStrategy.renderValue(config.body, variables) : undefined, true);
  }

  /** 校验搜索配置里的全部 JSONPath（插件编辑器保存前也会用）。 */
  static validateSearchConfig(config: ApiSearchConfig): void {
    RestrictedJsonPath.validate(config.listPath);
    RestrictedJsonPath.validate(config.namePath);
    // `sourcePath` 可以写成模板（见 `searchSource`），模板不做 JSONPath 校验
    if (config.sourcePath.trim().startsWith('$')) {
      RestrictedJsonPath.validate(config.sourcePath);
    }
    const template: string = config.sourceTemplate.trim();
    if (template.length > 0 && template.indexOf('@source') < 0) {
      throw new ApiRuleFormatException('详情页地址模板必须引用 @source');
    }
  }

  static parseSearch(raw: string, config: ApiSearchConfig): RuleSearchParseResult {
    ApiRuleStrategy.validateSearchConfig(config);
    const document: Object = ApiRuleStrategy.decodeResponse(raw);
    const nodes: (Object | undefined)[] = RestrictedJsonPath.read(document, config.listPath);
    const template: string = config.sourceTemplate.trim();
    const items: SearchItem[] = [];
    const fragments: string[] = [];
    const diagnostics: string[] = [];
    for (let index = 0; index < nodes.length; index++) {
      const node: Object | undefined = nodes[index];
      try {
        const name: string = ApiRuleStrategy.stringValue(
          RestrictedJsonPath.readFirst(node, config.namePath));
        const source: string = ApiRuleStrategy.searchSource(config.sourcePath, node);
        if (name.length === 0 || source.length === 0) {
          diagnostics.push(`搜索节点 ${index} 缺少名称或来源，已跳过`);
          continue;
        }
        // 与上游 api 9 一致：模板里的 `@source` 可紧跟字母（如 `/GV@source`），
        // 因此这里是普通字符串替换，不走 `@变量` 模板语法。
        const src: string = template.length === 0
          ? source : template.replaceAll('@source', encodeURIComponent(source));
        const item = new SearchItem();
        item.name = name;
        item.src = src;
        items.push(item);
        fragments.push(JSON.stringify(node));
      } catch (error) {
        if (error instanceof ApiRuleFormatException) {
          throw error;
        }
        const err = error as Error;
        diagnostics.push(`搜索节点 ${index} 解析失败: ${err.message}`);
      }
    }
    return new RuleSearchParseResult(items, fragments, diagnostics);
  }

  /**
   * 搜索结果的**来源地址**。
   *
   * `sourcePath` 与参照实现一样支持 JSONPath（例：`$.detail_link`）；
   * **本工程另加一条**：值不以 `$` 开头时按模板处理，变量取当前节点自己的字段，
   * 例：`/index.php/vod/detail/id/@id.html`。
   *
   * 为什么要加：有些站点的搜索接口只回 id、不回链接。实测 dalvdm 的新站
   * （`www.sbdl.cc`）：`/index.php/ajax/suggest` 只给 `{id, name, en, pic}`，
   * 详情地址得自己拼。没有这条就只能退回「搜索页要过验证码」那条路。
   *
   * 变量**只从当前搜索结果节点取**，不引入任何全局求值——规则文件依旧不能执行代码；
   * 渲染失败（缺变量等）按「这一条没有来源」处理，由调用方记进诊断，不整条搜索失败。
   */
  private static searchSource(sourcePath: string, node: Object | undefined): string {
    const path: string = sourcePath.trim();
    if (path.length === 0) {
      return '';
    }
    if (path.startsWith('$')) {
      return ApiRuleStrategy.stringValue(RestrictedJsonPath.readFirst(node, path));
    }
    const variables: Map<string, Object | undefined> = new Map<string, Object | undefined>();
    const record: Record<string, Object> | null =
      node === undefined || node === null ? null : JsonUtils.asObj(node);
    if (record !== null) {
      const keys: string[] = Object.keys(record);
      for (let i = 0; i < keys.length; i++) {
        variables.set(keys[i], record[keys[i]]);
      }
    }
    try {
      return ApiRuleStrategy.renderTemplate(path, variables, false);
    } catch (error) {
      return '';
    }
  }

  static parseChapters(raw: string, config: ApiChapterConfig, source: string,
    baseUrl: string): RuleChapterParseResult {
    ApiRuleStrategy.validateChapterConfig(config);
    const document: Object = ApiRuleStrategy.decodeResponse(raw);
    const rootVariables: Map<string, Object | undefined> =
      new Map<string, Object | undefined>();
    rootVariables.set('source', source);
    const variableKeys: string[] = Object.keys(config.variables);
    for (let i = 0; i < variableKeys.length; i++) {
      const name: string = variableKeys[i];
      const expression: string = config.variables[name];
      const value: Object | undefined =
        RestrictedJsonPath.readFirst(document, expression);
      if (value === undefined || value === null) {
        throw new ApiRuleFormatException(
          `章节响应变量 ${name} 未匹配到值: ${expression}`);
      }
      rootVariables.set(name, value);
    }
    const diagnostics: string[] = [];
    const roads: Road[] = config.format === ApiChapterFormat.delimited
      ? ApiRuleStrategy.parseDelimited(document, config, rootVariables, baseUrl, diagnostics)
      : ApiRuleStrategy.parseNested(document, config, rootVariables, baseUrl, diagnostics);
    return new RuleChapterParseResult(roads, diagnostics);
  }

  /** 校验章节配置（JSONPath + 两种格式的必填项）。 */
  static validateChapterConfig(config: ApiChapterConfig): void {
    const variableKeys: string[] = Object.keys(config.variables);
    for (let i = 0; i < variableKeys.length; i++) {
      RestrictedJsonPath.validate(config.variables[variableKeys[i]]);
    }
    if (config.format === ApiChapterFormat.delimited) {
      RestrictedJsonPath.validate(config.roadNamesPath);
      RestrictedJsonPath.validate(config.roadEpisodesPath);
      if (config.roadSeparator.length === 0 ||
        config.episodeSeparator.length === 0 ||
        config.fieldSeparator.length === 0) {
        throw new ApiRuleFormatException('章节分隔符不能为空');
      }
      return;
    }
    if (config.roadsPath.trim().length > 0) {
      RestrictedJsonPath.validate(config.roadsPath);
    }
    if (config.roadNamePath.trim().length > 0) {
      RestrictedJsonPath.validate(config.roadNamePath);
    }
    RestrictedJsonPath.validate(config.episodesPath);
    RestrictedJsonPath.validate(config.episodeNamePath);
    if (config.episodeUrlPath.trim().length > 0) {
      RestrictedJsonPath.validate(config.episodeUrlPath);
    } else if (config.episodePage === undefined) {
      throw new ApiRuleFormatException('必须配置播放入口地址路径或播放页地址模板');
    }
    if (config.episodePage !== undefined &&
      config.episodePage.url.trim().length === 0) {
      throw new ApiRuleFormatException('播放页地址模板不能为空');
    }
  }

  // ------------------------------------------------------------ 内部实现

  private static parseNested(document: Object, config: ApiChapterConfig,
    rootVariables: Map<string, Object | undefined>, baseUrl: string,
    diagnostics: string[]): Road[] {
    const hasRoads: boolean = config.roadsPath.trim().length > 0;
    const roadNodes: (Object | undefined)[] = hasRoads
      ? RestrictedJsonPath.read(document, config.roadsPath)
      : [document];
    const roads: Road[] = [];
    for (let roadIndex = 0; roadIndex < roadNodes.length; roadIndex++) {
      const roadNode: Object | undefined = roadNodes[roadIndex];
      try {
        const roadName: string = hasRoads && config.roadNamePath.trim().length > 0
          ? ApiRuleStrategy.stringValue(
            RestrictedJsonPath.readFirst(roadNode, config.roadNamePath)) : '';
        const episodeNodes: (Object | undefined)[] =
          RestrictedJsonPath.read(roadNode, config.episodesPath);
        const urls: string[] = [];
        const names: string[] = [];
        for (let episodeIndex = 0; episodeIndex < episodeNodes.length; episodeIndex++) {
          try {
            const episodeNode: Object | undefined = episodeNodes[episodeIndex];
            const episodeName: string = ApiRuleStrategy.stringValue(
              RestrictedJsonPath.readFirst(episodeNode, config.episodeNamePath));
            const rawUrl: string = config.episodeUrlPath.trim().length === 0
              ? '' : ApiRuleStrategy.stringValue(
                RestrictedJsonPath.readFirst(episodeNode, config.episodeUrlPath));
            const pageUrl: string = ApiRuleStrategy.resolveEpisodeUrl(config,
              rootVariables, rawUrl, roadIndex, episodeIndex, baseUrl);
            if (pageUrl.length === 0) {
              diagnostics.push(`线路 ${roadIndex} 的剧集节点 ${episodeIndex} 缺少 URL，已跳过`);
              continue;
            }
            urls.push(pageUrl);
            names.push(episodeName.length === 0 ? `第${episodeIndex + 1}集` : episodeName);
          } catch (error) {
            if (error instanceof ApiRuleFormatException) {
              throw error;
            }
            const err = error as Error;
            diagnostics.push(`线路 ${roadIndex} 的剧集节点 ${episodeIndex} 解析失败: ${err.message}`);
          }
        }
        if (urls.length === 0) {
          diagnostics.push(`线路节点 ${roadIndex} 没有有效剧集，已跳过`);
          continue;
        }
        const road = new Road();
        road.name = roadName.length === 0 ? `播放线路${roads.length + 1}` : roadName;
        road.data = urls;
        road.identifier = names;
        roads.push(road);
      } catch (error) {
        if (error instanceof ApiRuleFormatException) {
          throw error;
        }
        const err = error as Error;
        diagnostics.push(`线路节点 ${roadIndex} 解析失败: ${err.message}`);
      }
    }
    return roads;
  }

  private static parseDelimited(document: Object, config: ApiChapterConfig,
    rootVariables: Map<string, Object | undefined>, baseUrl: string,
    diagnostics: string[]): Road[] {
    const namesValue: string = ApiRuleStrategy.stringValue(
      RestrictedJsonPath.readFirst(document, config.roadNamesPath));
    const episodesValue: string = ApiRuleStrategy.stringValue(
      RestrictedJsonPath.readFirst(document, config.roadEpisodesPath));
    if (episodesValue.length === 0) {
      return [];
    }
    const roadNames: string[] = namesValue.split(config.roadSeparator);
    const roadGroups: string[] = episodesValue.split(config.roadSeparator);
    const roads: Road[] = [];
    for (let roadIndex = 0; roadIndex < roadGroups.length; roadIndex++) {
      const urls: string[] = [];
      const names: string[] = [];
      const entries: string[] = roadGroups[roadIndex].split(config.episodeSeparator);
      for (let episodeIndex = 0; episodeIndex < entries.length; episodeIndex++) {
        const entry: string = entries[episodeIndex].trim();
        if (entry.length === 0) {
          continue;
        }
        const separatorIndex: number = entry.indexOf(config.fieldSeparator);
        if (separatorIndex < 0) {
          diagnostics.push(`线路 ${roadIndex} 的剧集条目 ${episodeIndex} 缺少字段分隔符，已跳过`);
          continue;
        }
        const name: string = entry.substring(0, separatorIndex).trim();
        const rawUrl: string = entry
          .substring(separatorIndex + config.fieldSeparator.length).trim();
        try {
          const pageUrl: string = ApiRuleStrategy.resolveEpisodeUrl(config,
            rootVariables, rawUrl, roadIndex, episodeIndex, baseUrl);
          if (pageUrl.length === 0) {
            diagnostics.push(`线路 ${roadIndex} 的剧集条目 ${episodeIndex} 缺少 URL，已跳过`);
            continue;
          }
          urls.push(pageUrl);
          names.push(name.length === 0 ? `第${episodeIndex + 1}集` : name);
        } catch (error) {
          if (error instanceof ApiRuleFormatException) {
            throw error;
          }
          const err = error as Error;
          diagnostics.push(`线路 ${roadIndex} 的剧集条目 ${episodeIndex} 解析失败: ${err.message}`);
        }
      }
      if (urls.length === 0) {
        diagnostics.push(`线路 ${roadIndex} 没有有效剧集，已跳过`);
        continue;
      }
      const configuredName: string =
        roadIndex < roadNames.length ? roadNames[roadIndex].trim() : '';
      const road = new Road();
      road.name = configuredName.length === 0
        ? `播放线路${roads.length + 1}` : configuredName;
      road.data = urls;
      road.identifier = names;
      roads.push(road);
    }
    return roads;
  }

  /** 解析单集地址：无模板时直接归一化；有模板时渲染模板并合并 query。 */
  private static resolveEpisodeUrl(config: ApiChapterConfig,
    rootVariables: Map<string, Object | undefined>, rawUrl: string,
    roadIndex: number, episodeIndex: number, baseUrl: string): string {
    const page: ApiEpisodePageConfig | undefined = config.episodePage;
    if (page === undefined) {
      return normalizeEpisodeUrl(baseUrl, rawUrl);
    }
    if (page.url.trim().length === 0) {
      throw new ApiRuleFormatException('播放页地址模板不能为空');
    }
    // 模板语言没有算术，因此 0 基与 1 基下标都要提供；
    // @episodeUrl 是 episodeUrlPath 抓到的原始值，没有替代品。
    const variables: Map<string, Object | undefined> =
      new Map<string, Object | undefined>();
    rootVariables.forEach((value: Object | undefined, key: string) => {
      variables.set(key, value);
    });
    variables.set('episodeUrl', rawUrl);
    variables.set('roadIndex', roadIndex);
    variables.set('roadNumber', roadIndex + 1);
    variables.set('episodeIndex', episodeIndex);
    variables.set('episodeNumber', episodeIndex + 1);

    const path: string = ApiRuleStrategy.renderTemplate(page.url, variables, true);
    const parsed: ParsedTemplateUrl | null = ApiRuleStrategy.parseUrl(path);
    if (parsed === null) {
      throw new ApiRuleFormatException(`剧集页面 URL 无效: ${path}`);
    }
    const renderedQuery: Record<string, Object> = {};
    ApiRuleStrategy.renderValueMap(page.query, variables, renderedQuery);
    const merged: Map<string, string> = new Map<string, string>();
    const baseKeys: string[] = Object.keys(parsed.query);
    for (let i = 0; i < baseKeys.length; i++) {
      merged.set(baseKeys[i], `${parsed.query[baseKeys[i]]}`);
    }
    const renderedKeys: string[] = Object.keys(renderedQuery);
    for (let i = 0; i < renderedKeys.length; i++) {
      merged.set(renderedKeys[i], `${renderedQuery[renderedKeys[i]]}`);
    }
    let mergedUrl: string = `${parsed.scheme}://${parsed.host}${parsed.path}`;
    if (merged.size > 0) {
      const parts: string[] = [];
      merged.forEach((value: string, key: string) => {
        parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
      });
      mergedUrl += `?${parts.join('&')}`;
    }
    return normalizeEpisodeUrl(baseUrl, mergedUrl);
  }

  private static renderMap(input: Record<string, Object>,
    variables: Map<string, Object | undefined>, out: Record<string, string>): void {
    const keys: string[] = Object.keys(input);
    for (let i = 0; i < keys.length; i++) {
      const key: string = ApiRuleStrategy.renderTemplate(keys[i], variables, false);
      out[key] = `${ApiRuleStrategy.renderValue(input[keys[i]], variables)}`;
    }
  }

  private static renderValueMap(input: Record<string, Object>,
    variables: Map<string, Object | undefined>, out: Record<string, Object>): void {
    const keys: string[] = Object.keys(input);
    for (let i = 0; i < keys.length; i++) {
      const key: string = ApiRuleStrategy.renderTemplate(keys[i], variables, false);
      const value: Object | undefined =
        ApiRuleStrategy.renderValue(input[keys[i]], variables);
      out[key] = value === undefined ? '' : value;
    }
  }

  /** 渲染单个值：整体 `@name` 返回原始变量，其它情况按模板替换。 */
  private static renderValue(value: Object | undefined,
    variables: Map<string, Object | undefined>): Object | undefined {
    if (value === undefined || value === null) {
      return value;
    }
    if (typeof value === 'string') {
      const text: string = value as string;
      const exact: RegExpMatchArray | null = text.match(/^@([A-Za-z_][A-Za-z0-9_]*)$/);
      if (exact !== null) {
        const name: string = exact[1];
        if (!variables.has(name)) {
          throw new ApiRuleFormatException(`缺少模板变量 @${name}`);
        }
        return variables.get(name);
      }
      return ApiRuleStrategy.renderTemplate(text, variables, false);
    }
    if (Array.isArray(value)) {
      const arr: Object[] = value as Object[];
      const out: Object[] = [];
      for (let i = 0; i < arr.length; i++) {
        const rendered: Object | undefined =
          ApiRuleStrategy.renderValue(arr[i], variables);
        out.push(rendered === undefined ? '' : rendered);
      }
      return out;
    }
    const rec: Record<string, Object> | null =
      typeof value === 'object' ? value as Record<string, Object> : null;
    if (rec === null) {
      return value;
    }
    const out: Record<string, Object> = {};
    const keys: string[] = Object.keys(rec);
    for (let i = 0; i < keys.length; i++) {
      const rendered: Object | undefined =
        ApiRuleStrategy.renderValue(rec[keys[i]], variables);
      out[keys[i]] = rendered === undefined ? '' : rendered;
    }
    return out;
  }

  /** `@name` 模板替换；`encode` 为真时按 URI 组件编码。 */
  private static renderTemplate(template: string,
    variables: Map<string, Object | undefined>, encode: boolean): string {
    return template.replace(/(?<![A-Za-z0-9_])@([A-Za-z_][A-Za-z0-9_]*)/g,
      (match: string, name: string): string => {
        if (!variables.has(name)) {
          throw new ApiRuleFormatException(`缺少模板变量 @${name}`);
        }
        const value: Object | undefined = variables.get(name);
        const text: string = value === undefined || value === null ? '' : `${value}`;
        return encode ? encodeURIComponent(text) : text;
      });
  }

  /**
   * 字符串化。
   *
   * 源码是 Dart 的 `value.toString()`：字符串取 trim，其它直接 toString。
   * 对象/数组在 Dart 与 JS 的 toString 结果不同，这里用 JSON 序列化，
   * 语义上更贴近规则作者的意图（只在 name/source 不是标量时才会走到）。
   */
  private static stringValue(value: Object | undefined): string {
    if (value === undefined || value === null) {
      return '';
    }
    if (typeof value === 'string') {
      return (value as string).trim();
    }
    if (typeof value === 'object') {
      return JSON.stringify(value);
    }
    return `${value}`;
  }

  private static isValidUrl(url: string): boolean {
    const parsed: ParsedTemplateUrl | null = ApiRuleStrategy.parseUrl(url);
    return parsed !== null;
  }

  private static parseUrl(url: string): ParsedTemplateUrl | null {
    const schemeEnd: number = url.indexOf('://');
    if (schemeEnd <= 0) {
      return null;
    }
    const parsed = new ParsedTemplateUrl();
    parsed.scheme = url.substring(0, schemeEnd).toLowerCase();
    const rest: string = url.substring(schemeEnd + 3);
    let cut: number = rest.length;
    for (let i = 0; i < rest.length; i++) {
      const c: string = rest.charAt(i);
      if (c === '/' || c === '?' || c === '#') {
        cut = i;
        break;
      }
    }
    parsed.host = rest.substring(0, cut);
    if (parsed.host.length === 0) {
      return null;
    }
    let remainder: string = rest.substring(cut);
    const hashIndex: number = remainder.indexOf('#');
    if (hashIndex >= 0) {
      remainder = remainder.substring(0, hashIndex);
    }
    const queryIndex: number = remainder.indexOf('?');
    if (queryIndex >= 0) {
      const queryText: string = remainder.substring(queryIndex + 1);
      remainder = remainder.substring(0, queryIndex);
      const pairs: string[] = queryText.split('&');
      for (let i = 0; i < pairs.length; i++) {
        const pair: string = pairs[i];
        if (pair.length === 0) {
          continue;
        }
        const eq: number = pair.indexOf('=');
        if (eq < 0) {
          parsed.query[decodeURIComponent(pair)] = '';
        } else {
          parsed.query[decodeURIComponent(pair.substring(0, eq))] =
            decodeURIComponent(pair.substring(eq + 1));
        }
      }
    }
    parsed.path = remainder.length === 0 ? '/' : remainder;
    return parsed;
  }
}

/** 模板 URL 的轻量拆解。 */
class ParsedTemplateUrl {
  scheme: string = '';
  host: string = '';
  path: string = '';
  query: Record<string, string> = {};
}
