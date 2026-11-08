import { HtmlNode, HtmlParser } from '../../plugins/dom/HtmlDom';
import { XPath } from '../../plugins/dom/XPathSelector';
import { AntiCrawlerConfig, CaptchaDetectType } from '../../plugins/AntiCrawlerConfig';
import { ApiBodyType } from '../../plugins/ApiRuleConfig';
import { Road, SearchItem } from '../../model/SearchModels';
import { normalizeEpisodeUrl } from '../../utils/EpisodeUrl';
import { CaptchaRequiredException, PreparedRuleRequest, RuleChapterParseResult, RuleExecutionConfig, RuleSearchParseResult } from './RuleEngineModels';

/**
 * XPath 模式的规则策略。
 * 逐行对应参照实现 `lib/services/plugin/xpath_rule_strategy.dart`。
 */
export class XPathRuleStrategy {
  /** 搜索请求：关键词替换 + GET/POST 判定。 */
  static prepareSearchRequest(config: RuleExecutionConfig,
    keyword: string): PreparedRuleRequest {
    const queryUrl: string =
      config.searchUrl.split('@keyword').join(encodeURIComponent(keyword));
    if (!XPathRuleStrategy.isValidUrl(queryUrl)) {
      throw new Error(`搜索 URL 无效: ${queryUrl}`);
    }
    if (!config.usePost) {
      return PreparedRuleRequest.get(queryUrl, true);
    }
    // POST：URL 去掉 query，query 当表单体（与源码一致）
    const questionIndex: number = queryUrl.indexOf('?');
    const bodyUrl: string = questionIndex < 0
      ? queryUrl : queryUrl.substring(0, questionIndex);
    const body: Record<string, Object> = XPathRuleStrategy.parseQuery(
      questionIndex < 0 ? '' : queryUrl.substring(questionIndex + 1));
    const headers: Record<string, string> = {};
    const query: Record<string, Object> = {};
    return new PreparedRuleRequest('POST', bodyUrl, headers, query,
      ApiBodyType.form, body, true);
  }

  /** 章节请求：只做 URL 归一化；**不带 Cookie**（与源码历史行为一致）。 */
  static prepareChapterRequest(config: RuleExecutionConfig,
    source: string): PreparedRuleRequest {
    const url: string = normalizeEpisodeUrl(config.baseUrl, source);
    if (!XPathRuleStrategy.isValidUrl(url)) {
      throw new Error(`章节 URL 无效: ${url}`);
    }
    return PreparedRuleRequest.get(url, false);
  }

  /** 解析搜索结果。 */
  static parseSearch(raw: string, config: RuleExecutionConfig): RuleSearchParseResult {
    const root: HtmlNode = XPathRuleStrategy.documentElement(raw);
    if (XPathRuleStrategy.detectsCaptchaChallenge(raw, config.antiCrawlerConfig, root)) {
      throw new CaptchaRequiredException(config.pluginName);
    }
    const items: SearchItem[] = [];
    const fragments: string[] = [];
    const diagnostics: string[] = [];

    const nodes: HtmlNode[] = XPathRuleStrategy.runSelector(config.searchList,
      () => XPath.nodes(root, config.searchList));
    for (let index = 0; index < nodes.length; index++) {
      const node: HtmlNode = nodes[index];
      try {
        const nameNode: HtmlNode | null = XPathRuleStrategy.runSelector(
          config.searchName,
          () => XPath.query(node, config.searchName).node());
        const name: string = nameNode === null ? '' : nameNode.textContent().trim();
        const srcNode: HtmlNode | null = XPathRuleStrategy.runSelector(
          config.searchResult,
          () => XPath.query(node, config.searchResult).node());
        const href: string | null = srcNode === null ? null : srcNode.attr('href');
        const source: string = href === null ? '' : href.trim();
        if (name.length === 0 || source.length === 0) {
          diagnostics.push(`搜索节点 ${index} 缺少名称或来源，已跳过`);
          continue;
        }
        const item = new SearchItem();
        item.name = name;
        item.src = source;
        items.push(item);
        fragments.push(node.outerHtml());
      } catch (error) {
        const err = error as Error;
        diagnostics.push(`搜索节点 ${index} 解析失败: ${err.message}`);
      }
    }
    return new RuleSearchParseResult(items, fragments, diagnostics);
  }

  /** 解析线路与剧集。 */
  static parseChapters(raw: string, config: RuleExecutionConfig): RuleChapterParseResult {
    const root: HtmlNode = XPathRuleStrategy.documentElement(raw);
    const roads: Road[] = [];
    const diagnostics: string[] = [];
    const roadNodes: HtmlNode[] = XPathRuleStrategy.runSelector(config.chapterRoads,
      () => XPath.nodes(root, config.chapterRoads));

    for (let roadIndex = 0; roadIndex < roadNodes.length; roadIndex++) {
      const roadNode: HtmlNode = roadNodes[roadIndex];
      try {
        const urls: string[] = [];
        const names: string[] = [];
        const episodeNodes: HtmlNode[] = XPathRuleStrategy.runSelector(
          config.chapterResult,
          () => XPath.nodes(roadNode, config.chapterResult));
        for (let episodeIndex = 0; episodeIndex < episodeNodes.length; episodeIndex++) {
          const episode: HtmlNode = episodeNodes[episodeIndex];
          const href: string | null = episode.attr('href');
          const source: string = href === null ? '' : href.trim();
          if (source.length === 0) {
            diagnostics.push(`线路 ${roadIndex} 的剧集节点 ${episodeIndex} 缺少 URL，已跳过`);
            continue;
          }
          // 集名：节点文本并把空白折叠掉（源码 `\s+` → 空）
          const name: string = episode.textContent().replace(/\s+/g, '');
          urls.push(normalizeEpisodeUrl(config.baseUrl, source));
          names.push(name.length === 0 ? `第${episodeIndex + 1}集` : name);
        }
        if (urls.length === 0) {
          diagnostics.push(`线路 ${roadIndex} 没有有效剧集，已跳过`);
          continue;
        }
        const road = new Road();
        road.name = `播放线路${roads.length + 1}`;
        road.data = urls;
        road.identifier = names;
        roads.push(road);
      } catch (error) {
        const err = error as Error;
        diagnostics.push(`线路节点 ${roadIndex} 解析失败: ${err.message}`);
      }
    }
    return new RuleChapterParseResult(roads, diagnostics);
  }

  /** 验证页检测（三种检测方式 + fallback 选择器）。 */
  static detectsCaptchaChallenge(raw: string, config: AntiCrawlerConfig,
    htmlElement: HtmlNode | null): boolean {
    if (!config.enabled) {
      return false;
    }
    const detectValue: string = config.captchaDetectValue.trim();
    if (detectValue.length > 0) {
      if (config.captchaDetectType === CaptchaDetectType.text) {
        return raw.indexOf(detectValue) >= 0;
      }
      if (config.captchaDetectType === CaptchaDetectType.regex) {
        try {
          return new RegExp(detectValue, 'is').test(raw);
        } catch (e) {
          return false;
        }
      }
      const root: HtmlNode = htmlElement === null
        ? XPathRuleStrategy.documentElement(raw) : htmlElement;
      return XPathRuleStrategy.runSelector(detectValue,
        () => XPath.query(root, detectValue).node()) !== null;
    }
    const root: HtmlNode = htmlElement === null
      ? XPathRuleStrategy.documentElement(raw) : htmlElement;
    const fallbacks: string[] = [config.captchaImage, config.captchaButton];
    for (let i = 0; i < fallbacks.length; i++) {
      const expression: string = fallbacks[i];
      if (expression.trim().length === 0) {
        continue;
      }
      const node: HtmlNode | null = XPathRuleStrategy.runSelector(expression,
        () => XPath.query(root, expression).node());
      if (node !== null) {
        return true;
      }
    }
    return false;
  }

  /** HTML → documentElement（对应源码 `_documentElement`）。 */
  private static documentElement(raw: string): HtmlNode {
    return HtmlParser.parseDocumentElement(raw);
  }

  /** 空选择器直接报错（对应 `_runSelector`）。 */
  private static runSelector<T>(expression: string, query: () => T): T {
    if (expression.trim().length === 0) {
      throw new Error('XPath 不能为空');
    }
    return query();
  }

  private static isValidUrl(url: string): boolean {
    const schemeEnd: number = url.indexOf('://');
    if (schemeEnd <= 0) {
      return false;
    }
    const rest: string = url.substring(schemeEnd + 3);
    const slash: number = rest.indexOf('/');
    const host: string = slash < 0 ? rest : rest.substring(0, slash);
    return host.length > 0;
  }

  /** `a=1&b=2` → 键值表。 */
  private static parseQuery(query: string): Record<string, Object> {
    const out: Record<string, Object> = {};
    if (query.length === 0) {
      return out;
    }
    const pairs: string[] = query.split('&');
    for (let i = 0; i < pairs.length; i++) {
      const pair: string = pairs[i];
      if (pair.length === 0) {
        continue;
      }
      const eq: number = pair.indexOf('=');
      if (eq < 0) {
        out[decodeURIComponent(pair)] = '';
      } else {
        out[decodeURIComponent(pair.substring(0, eq))] =
          decodeURIComponent(pair.substring(eq + 1));
      }
    }
    return out;
  }
}
