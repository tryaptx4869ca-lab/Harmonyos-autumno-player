import { JsonUtils } from '../model/JsonUtils';
import { HttpHeaders } from '../request/core/HttpHeaders';
import { RuleExecutionConfig } from '../services/plugin/RuleEngineModels';
import { ApiChapterConfig, ApiSearchConfig, RuleMode } from './ApiRuleConfig';
import { AntiCrawlerConfig } from './AntiCrawlerConfig';

/**
 * 插件（规则）模型。
 * 逐字段移植自参照实现 `lib/plugins/plugins.dart`。
 *
 * 字段名与原 JSON **必须逐字一致**，包括上游的拼写 `muliSources`
 * （它不是笔误，改成 `multiSources` 会让老规则读不出来）。
 */

/** 插件名归一化键（源码 `pluginNameKey`）。 */
export function pluginNameKey(name: string): string {
  return name.toLowerCase();
}

export class Plugin {
  api: string = '1';
  type: string = 'anime';
  name: string = '';
  version: string = '';
  muliSources: boolean = true;
  /** 遗留字段，仅为导入导出兼容保留。 */
  useWebview: boolean = true;
  /** 遗留字段。 */
  useNativePlayer: boolean = true;
  usePost: boolean = false;
  useLegacyParser: boolean = false;
  adBlocker: boolean = false;
  userAgent: string = '';
  baseUrl: string = '';
  searchURL: string = '';
  searchList: string = '';
  searchName: string = '';
  searchResult: string = '';
  chapterRoads: string = '';
  chapterResult: string = '';
  referer: string = '';
  searchMode: string = RuleMode.xpath;
  chapterMode: string = RuleMode.xpath;
  searchApiConfig: ApiSearchConfig = new ApiSearchConfig();
  chapterApiConfig: ApiChapterConfig = new ApiChapterConfig();
  antiCrawlerConfig: AntiCrawlerConfig = new AntiCrawlerConfig();

  static fromJson(json: Record<string, Object>): Plugin {
    const plugin = new Plugin();
    plugin.api = JsonUtils.str(json, 'api', '1');
    plugin.type = JsonUtils.str(json, 'type', 'anime');
    plugin.name = JsonUtils.str(json, 'name');
    plugin.version = JsonUtils.str(json, 'version');
    plugin.muliSources = JsonUtils.boolOf(json, 'muliSources', true);
    plugin.useWebview = JsonUtils.boolOf(json, 'useWebview', true);
    plugin.useNativePlayer = JsonUtils.boolOf(json, 'useNativePlayer', true);
    plugin.usePost = JsonUtils.boolOf(json, 'usePost');
    plugin.useLegacyParser = JsonUtils.boolOf(json, 'useLegacyParser');
    plugin.adBlocker = JsonUtils.boolOf(json, 'adBlocker');
    plugin.userAgent = JsonUtils.str(json, 'userAgent');
    plugin.baseUrl = JsonUtils.str(json, 'baseURL');
    plugin.searchURL = JsonUtils.str(json, 'searchURL');
    plugin.searchList = JsonUtils.str(json, 'searchList');
    plugin.searchName = JsonUtils.str(json, 'searchName');
    plugin.searchResult = JsonUtils.str(json, 'searchResult');
    plugin.chapterRoads = JsonUtils.str(json, 'chapterRoads');
    plugin.chapterResult = JsonUtils.str(json, 'chapterResult');
    plugin.referer = JsonUtils.str(json, 'referer');
    plugin.searchMode = RuleMode.normalize(json['searchMode']);
    plugin.chapterMode = RuleMode.normalize(json['chapterMode']);
    const searchApi: Record<string, Object> | null = JsonUtils.obj(json, 'searchApiConfig');
    plugin.searchApiConfig = searchApi === null
      ? new ApiSearchConfig() : ApiSearchConfig.fromJson(searchApi);
    const chapterApi: Record<string, Object> | null = JsonUtils.obj(json, 'chapterApiConfig');
    plugin.chapterApiConfig = chapterApi === null
      ? new ApiChapterConfig() : ApiChapterConfig.fromJson(chapterApi);
    const antiCrawler: Record<string, Object> | null = JsonUtils.obj(json, 'antiCrawlerConfig');
    plugin.antiCrawlerConfig = antiCrawler === null
      ? new AntiCrawlerConfig() : AntiCrawlerConfig.fromJson(antiCrawler);
    return plugin;
  }

  /** 新建规则模板（源码 `Plugin.fromTemplate`）。 */
  static fromTemplate(apiLevel: string): Plugin {
    const plugin = new Plugin();
    plugin.api = apiLevel;
    plugin.type = 'anime';
    plugin.searchMode = RuleMode.xpath;
    plugin.chapterMode = RuleMode.xpath;
    return plugin;
  }

  toJson(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['api'] = this.api;
    out['type'] = this.type;
    out['name'] = this.name;
    out['version'] = this.version;
    out['muliSources'] = this.muliSources;
    out['useWebview'] = this.useWebview;
    out['useNativePlayer'] = this.useNativePlayer;
    out['usePost'] = this.usePost;
    out['useLegacyParser'] = this.useLegacyParser;
    out['adBlocker'] = this.adBlocker;
    out['userAgent'] = this.userAgent;
    out['baseURL'] = this.baseUrl;
    out['searchURL'] = this.searchURL;
    out['searchList'] = this.searchList;
    out['searchName'] = this.searchName;
    out['searchResult'] = this.searchResult;
    out['chapterRoads'] = this.chapterRoads;
    out['chapterResult'] = this.chapterResult;
    out['referer'] = this.referer;
    out['searchMode'] = this.searchMode;
    out['chapterMode'] = this.chapterMode;
    // 持久化会重新序列化整个插件列表：即使当前模式指向 XPath，
    // 已配置好的 API 规则也必须保留下来。
    if (this.searchMode === RuleMode.api ||
      this.searchApiConfig.request.url.length > 0) {
      out['searchApiConfig'] = this.searchApiConfig.toJson();
    }
    if (this.chapterMode === RuleMode.api ||
      this.chapterApiConfig.request.url.length > 0) {
      out['chapterApiConfig'] = this.chapterApiConfig.toJson();
    }
    out['antiCrawlerConfig'] = this.antiCrawlerConfig.toJson();
    return out;
  }

  get usesApiSearch(): boolean {
    return this.searchMode === RuleMode.api;
  }

  /** 规则要求的 api 级别高于客户端（源码 `requiresNewerClient`）。 */
  requiresNewerClient(apiLevel: number): boolean {
    const required: number = Number.parseInt(this.api, 10);
    return !Number.isNaN(required) && required > apiLevel;
  }

  /** 构建规则执行配置。 */
  executionConfig(): RuleExecutionConfig {
    return new RuleExecutionConfig(this.name, this.baseUrl, this.usePost,
      this.searchMode, this.chapterMode, this.searchURL, this.searchList,
      this.searchName, this.searchResult, this.chapterRoads,
      this.chapterResult, this.searchApiConfig, this.chapterApiConfig,
      this.antiCrawlerConfig);
  }

  /** 播放/下载最终媒体资源时的请求头。 */
  buildHttpHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['user-agent'] = this.userAgent.length === 0
      ? HttpHeaders.randomUserAgent() : this.userAgent;
    if (this.referer.length > 0) {
      headers['referer'] = this.referer;
    }
    return headers;
  }
}
