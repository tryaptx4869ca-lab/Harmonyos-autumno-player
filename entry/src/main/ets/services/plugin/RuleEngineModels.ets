import { AntiCrawlerConfig } from '../../plugins/AntiCrawlerConfig';
import { ApiBodyType, ApiChapterConfig, ApiSearchConfig } from '../../plugins/ApiRuleConfig';
import { Road, SearchItem } from '../../model/SearchModels';

/**
 * 规则引擎的运行时模型。
 * 逐字段移植自 `lib/services/plugin/rule_engine_models.dart`。
 */

/** 需要验证码时抛出（调用方据此拉起 WebView 验证流程）。 */
export class CaptchaRequiredException extends Error {
  readonly pluginName: string;

  constructor(pluginName: string) {
    super(`CaptchaRequiredException: ${pluginName} requires captcha verification`);
    this.pluginName = pluginName;
  }
}

/** 搜索无结果。 */
export class NoResultException extends Error {
  readonly pluginName: string;

  constructor(pluginName: string) {
    super(`NoResultException: ${pluginName} returned no search results`);
    this.pluginName = pluginName;
  }
}

/** 搜索失败。 */
export class SearchErrorException extends Error {
  readonly pluginName: string;
  readonly cause: string;

  constructor(pluginName: string, cause: string = '') {
    super(`SearchErrorException: ${pluginName} search failed${cause.length > 0 ? ` (${cause})` : ''}`);
    this.pluginName = pluginName;
    this.cause = cause;
  }
}

/** 章节查询失败。 */
export class ChapterErrorException extends Error {
  readonly pluginName: string;
  readonly cause: string;

  constructor(pluginName: string, cause: string = '') {
    super(`ChapterErrorException: ${pluginName} chapter query failed${cause.length > 0 ? ` (${cause})` : ''}`);
    this.pluginName = pluginName;
    this.cause = cause;
  }
}

/**
 * 规则执行配置（由 Plugin 构建的快照）。
 *
 * 注意：**不含**规则自己的 User-Agent / Referer——
 * 那两个只在播放链路用（`Plugin.buildHttpHeaders`）。
 */
export class RuleExecutionConfig {
  readonly pluginName: string;
  readonly baseUrl: string;
  readonly usePost: boolean;
  readonly searchMode: string;
  readonly chapterMode: string;
  readonly searchUrl: string;
  readonly searchList: string;
  readonly searchName: string;
  readonly searchResult: string;
  readonly chapterRoads: string;
  readonly chapterResult: string;
  readonly searchApiConfig: ApiSearchConfig;
  readonly chapterApiConfig: ApiChapterConfig;
  readonly antiCrawlerConfig: AntiCrawlerConfig;

  constructor(pluginName: string, baseUrl: string, usePost: boolean,
    searchMode: string, chapterMode: string, searchUrl: string,
    searchList: string, searchName: string, searchResult: string,
    chapterRoads: string, chapterResult: string,
    searchApiConfig: ApiSearchConfig, chapterApiConfig: ApiChapterConfig,
    antiCrawlerConfig: AntiCrawlerConfig) {
    this.pluginName = pluginName;
    this.baseUrl = baseUrl;
    this.usePost = usePost;
    this.searchMode = searchMode;
    this.chapterMode = chapterMode;
    this.searchUrl = searchUrl;
    this.searchList = searchList;
    this.searchName = searchName;
    this.searchResult = searchResult;
    this.chapterRoads = chapterRoads;
    this.chapterResult = chapterResult;
    this.searchApiConfig = searchApiConfig;
    this.chapterApiConfig = chapterApiConfig;
    this.antiCrawlerConfig = antiCrawlerConfig;
  }
}

/** 待执行的请求。 */
export class PreparedRuleRequest {
  readonly method: string;
  readonly url: string;
  readonly headers: Record<string, string>;
  readonly query: Record<string, Object>;
  readonly bodyType: string;
  readonly body: Object | undefined;
  /**
   * 是否附带已保存的插件 Cookie。
   * 历史行为：只有搜索与 API 请求带；XPath 章节请求不带。
   */
  readonly includeCookies: boolean;

  constructor(method: string, url: string, headers: Record<string, string>,
    query: Record<string, Object>, bodyType: string,
    body: Object | undefined, includeCookies: boolean) {
    this.method = method;
    this.url = url;
    this.headers = headers;
    this.query = query;
    this.bodyType = bodyType;
    this.body = body;
    this.includeCookies = includeCookies;
  }

  /** 便捷构造：GET。 */
  static get(url: string, includeCookies: boolean): PreparedRuleRequest {
    const headers: Record<string, string> = {};
    const query: Record<string, Object> = {};
    return new PreparedRuleRequest('GET', url, headers, query,
      ApiBodyType.none, undefined, includeCookies);
  }
}

/** 搜索结果解析产物。 */
export class RuleSearchParseResult {
  readonly items: SearchItem[];
  readonly matchedFragments: string[];
  readonly diagnostics: string[];

  constructor(items: SearchItem[], matchedFragments: string[],
    diagnostics: string[]) {
    this.items = items;
    this.matchedFragments = matchedFragments;
    this.diagnostics = diagnostics;
  }
}

/** 章节解析产物。 */
export class RuleChapterParseResult {
  readonly roads: Road[];
  readonly diagnostics: string[];

  constructor(roads: Road[], diagnostics: string[]) {
    this.roads = roads;
    this.diagnostics = diagnostics;
  }
}
