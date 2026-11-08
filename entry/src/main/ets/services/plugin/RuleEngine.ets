import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiRequestConfig, RuleMode } from '../../plugins/ApiRuleConfig';
import { PluginSearchResponse, Road } from '../../model/SearchModels';
import { PluginSiteClient } from './PluginSiteClient';
import {
  CaptchaRequiredException,
  ChapterErrorException,
  NoResultException,
  PreparedRuleRequest,
  RuleChapterParseResult,
  RuleExecutionConfig,
  RuleSearchParseResult,
  SearchErrorException
} from './RuleEngineModels';
import { XPathRuleStrategy } from './XPathRuleStrategy';
import { ApiRuleStrategy } from './ApiRuleStrategy';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnRule';

/** 搜索轨迹（含原始响应，便于排查规则问题）。 */
export class RuleSearchTrace {
  readonly rawResponse: string;
  readonly response: PluginSearchResponse;
  readonly matchedFragments: string[];
  readonly diagnostics: string[];

  constructor(rawResponse: string, response: PluginSearchResponse,
    matchedFragments: string[], diagnostics: string[]) {
    this.rawResponse = rawResponse;
    this.response = response;
    this.matchedFragments = matchedFragments;
    this.diagnostics = diagnostics;
  }
}

/** 章节轨迹。 */
export class RuleChapterTrace {
  readonly rawResponse: string;
  readonly roads: Road[];
  readonly diagnostics: string[];

  constructor(rawResponse: string, roads: Road[], diagnostics: string[]) {
    this.rawResponse = rawResponse;
    this.roads = roads;
    this.diagnostics = diagnostics;
  }
}

/**
 * 规则引擎：按 `searchMode` / `chapterMode` 分派到 XPath 或 API 策略。
 * 对应参照实现 `lib/services/plugin/rule_engine.dart`。
 *
 * 异常语义与源码一致：
 *   CaptchaRequiredException / NoResultException 直接向上抛（调用方要分别处理），
 *   其它解析异常统一包成 SearchErrorException / ChapterErrorException。
 */
export class RuleEngine {
  /** 搜索。 */
  static async search(config: RuleExecutionConfig,
    keyword: string): Promise<RuleSearchTrace> {
    let request: PreparedRuleRequest;
    try {
      request = config.searchMode === RuleMode.api
        ? RuleEngine.prepareApiRequest(config.searchApiConfig.request,
          RuleEngine.variablesOf('keyword', keyword))
        : XPathRuleStrategy.prepareSearchRequest(config, keyword);
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '%{public}s search request preparation failed: %{public}s',
        config.pluginName, err.message);
      throw new SearchErrorException(config.pluginName, err.message);
    }

    const raw: string = await RuleEngine.runRequest(request, config, 'search request',
      (message: string) => new SearchErrorException(config.pluginName, message));
    try {
      const parsed: RuleSearchParseResult = config.searchMode === RuleMode.api
        ? ApiRuleStrategy.parseSearch(raw, config.searchApiConfig)
        : XPathRuleStrategy.parseSearch(raw, config);
      if (parsed.items.length === 0) {
        throw new NoResultException(config.pluginName);
      }
      RuleEngine.logDiagnostics(config, 'search', parsed.diagnostics);
      const response = new PluginSearchResponse();
      response.pluginName = config.pluginName;
      response.data = parsed.items;
      return new RuleSearchTrace(raw, response, parsed.matchedFragments,
        parsed.diagnostics);
    } catch (error) {
      if (error instanceof CaptchaRequiredException ||
        error instanceof NoResultException) {
        // ArkTS 的 `arkts-limited-throw`：只能抛 Error 子类
        throw error as Error;
      }
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '%{public}s search parsing failed: %{public}s',
        config.pluginName, err.message);
      throw new SearchErrorException(config.pluginName, err.message);
    }
  }

  /**
   * 用验证码 WebView 抓到的 HTML 直接当搜索结果解析，
   * 省掉一次网络往返。不适用（API 模式 / POST 规则 / 仍解析不出结果）时返回 null。
   */
  static tryParseHarvestedSearch(config: RuleExecutionConfig,
    raw: string): PluginSearchResponse | null {
    if (raw.trim().length === 0) {
      return null;
    }
    if (config.searchMode === RuleMode.api || config.usePost) {
      return null;
    }
    try {
      const parsed: RuleSearchParseResult = XPathRuleStrategy.parseSearch(raw, config);
      if (parsed.items.length === 0) {
        return null;
      }
      RuleEngine.logDiagnostics(config, 'harvested search', parsed.diagnostics);
      const response = new PluginSearchResponse();
      response.pluginName = config.pluginName;
      response.data = parsed.items;
      return response;
    } catch (error) {
      const err = error as Error;
      hilog.info(DOMAIN, TAG,
        '%{public}s harvested page not parseable, falling back to re-search (%{public}s)',
        config.pluginName, err.message);
      return null;
    }
  }

  /** 查询线路与剧集。 */
  static async queryChapters(config: RuleExecutionConfig,
    source: string): Promise<RuleChapterTrace> {
    let request: PreparedRuleRequest;
    try {
      request = config.chapterMode === RuleMode.api
        ? RuleEngine.prepareApiRequest(config.chapterApiConfig.request,
          RuleEngine.variablesOf('source', source))
        : XPathRuleStrategy.prepareChapterRequest(config, source);
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '%{public}s chapter request preparation failed: %{public}s',
        config.pluginName, err.message);
      throw new ChapterErrorException(config.pluginName, err.message);
    }

    const raw: string = await RuleEngine.runRequest(request, config, 'chapter request',
      (message: string) => new ChapterErrorException(config.pluginName, message));
    try {
      const parsed: RuleChapterParseResult = config.chapterMode === RuleMode.api
        ? ApiRuleStrategy.parseChapters(raw, config.chapterApiConfig, source, config.baseUrl)
        : XPathRuleStrategy.parseChapters(raw, config);
      if (parsed.roads.length === 0) {
        throw new ChapterErrorException(config.pluginName);
      }
      RuleEngine.logDiagnostics(config, 'chapter', parsed.diagnostics);
      return new RuleChapterTrace(raw, parsed.roads, parsed.diagnostics);
    } catch (error) {
      if (error instanceof ChapterErrorException) {
        throw error;
      }
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '%{public}s chapter parsing failed: %{public}s',
        config.pluginName, err.message);
      throw new ChapterErrorException(config.pluginName, err.message);
    }
  }

  private static async runRequest(request: PreparedRuleRequest,
    config: RuleExecutionConfig, phase: string,
    wrap: (message: string) => Error): Promise<string> {
    try {
      return await PluginSiteClient.execute(request, config.pluginName, config.baseUrl);
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '%{public}s %{public}s failed: %{public}s',
        config.pluginName, phase, err.message);
      throw wrap(err.message);
    }
  }

  /** 跳过节点的诊断（最多打前 3 条，与源码一致）。 */
  private static logDiagnostics(config: RuleExecutionConfig, phase: string,
    diagnostics: string[]): void {
    if (diagnostics.length === 0) {
      return;
    }
    const preview: string = diagnostics.slice(0, 3).join('; ');
    hilog.warn(DOMAIN, TAG, '%{public}s %{public}s skipped %{public}d node(s): %{public}s',
      config.pluginName, phase, diagnostics.length, preview);
  }

  // ------------------------------------------------------------ API 模式

  /** 构造模板变量表。搜索只有 `keyword`，章节只有 `source`（其余由规则声明捕获）。 */
  private static variablesOf(name: string, value: string): Map<string, Object | undefined> {
    const variables: Map<string, Object | undefined> = new Map<string, Object | undefined>();
    variables.set(name, value);
    return variables;
  }

  private static prepareApiRequest(requestConfig: ApiRequestConfig,
    variables: Map<string, Object | undefined>): PreparedRuleRequest {
    return ApiRuleStrategy.prepareRequest(requestConfig, variables);
  }
}
