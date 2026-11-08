import { hilog } from '@kit.PerformanceAnalysisKit';
import { HtmlNode, HtmlParser } from '../../plugins/dom/HtmlDom';
import { XPath } from '../../plugins/dom/XPathSelector';
import { ApiBodyType, ApiChapterConfig, ApiChapterFormat, ApiRequestConfig, ApiSearchConfig } from '../../plugins/ApiRuleConfig';
import { Plugin, pluginNameKey } from '../../plugins/Plugin';
import { PluginHttpItem } from '../../model/PluginHttpItem';
import { PluginSearchResponse, PluginSearchStatus, Road, SearchItem } from '../../model/SearchModels';
import { BangumiItem } from '../../model/BangumiItem';
import { BangumiApi } from '../../api/BangumiApi';
import { VideoSourceScripts } from '../../webview/VideoSourceScripts';
import { needUpdate, remoteIsNewer } from '../../utils/VersionUtils';
import { PreparedRuleRequest } from './RuleEngineModels';
import { RestrictedJsonPath } from './RestrictedJsonPath';
import { ApiRuleStrategy } from './ApiRuleStrategy';
import { PluginCatalogApi, PluginCatalogParseResult } from './PluginCatalogApi';
import { PluginChainProbe } from './PluginChainProbe';
import { CaptchaOutcome, CaptchaVerificationService, CaptchaWebviewHost } from './CaptchaVerificationService';
import { PluginCookieManager } from './PluginCookieManager';
import { PluginManager } from './PluginManager';
import { PluginSearchService, PluginSearchStore } from './PluginSearchService';
import { PluginUpdateAvailability, PluginUpdateResult, PluginUpdateService } from './PluginUpdateService';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnSelf';

/** XPath 对拍用例。期望值按 `xpath_selector` 语义给（不是浏览器 XPath）。 */
class XPathCase {
  readonly expr: string;
  readonly expected: number;

  constructor(expr: string, expected: number) {
    this.expr = expr;
    this.expected = expected;
  }
}

/** ArkTS 不允许无类型对象字面量，这里显式造一个 Record。 */
function recordOf(key: string, value: Object): Record<string, Object> {
  const out: Record<string, Object> = {};
  out[key] = value;
  return out;
}

/** 验证码宿主桩：验证编排逻辑用，不碰真 WebView。 */
class StubCaptchaHost implements CaptchaWebviewHost {
  loads: number = 0;
  unloads: number = 0;
  private ua: string = 'SelfCheckUA/1.0';

  async loadUrl(url: string): Promise<void> {
    this.loads = this.loads + 1;
  }

  /** 桩里页面总是「已加载完」：自检只关心编排顺序，不等真实加载。 */
  async waitForPageLoad(timeoutMs: number): Promise<boolean> {
    return true;
  }

  async pageHtml(): Promise<string> {
    return '<html><body><div class="video anim">ok</div></body></html>';
  }

  async documentCookie(): Promise<string> {
    return 'cf_clearance=selfcheck; sid=42';
  }

  async userAgent(): Promise<string> {
    return this.ua;
  }

  async captureImage(xpath: string): Promise<string> {
    return 'AAAA';
  }

  /** 桩：第一次问「还在不在」答 still-there，之后答 MISSING（模拟验证通过后图消失）。 */
  private srcQueries: number = 0;

  async imageSrc(xpath: string): Promise<string> {
    this.srcQueries = this.srcQueries + 1;
    return this.srcQueries <= 1 ? 'https://a.example.com/captcha.png' : 'MISSING';
  }

  async waitForCaptchaChange(xpath: string, previousSrc: string,
    timeoutMs: number): Promise<string> {
    return (await this.imageSrc(xpath)) === 'MISSING' ? 'gone' : 'same';
  }

  async fillInput(xpath: string, value: string): Promise<void> {
  }

  /** 桩：恒当「点到了」，自检只验编排顺序（真实返回值见 `CaptchaWebHost.click`）。 */
  async click(xpath: string): Promise<string> {
    return 'clicked';
  }

  async runScript(script: string): Promise<void> {
  }

  async unload(): Promise<void> {
    this.unloads = this.unloads + 1;
  }
}

/**
 * 阶段 2 的设备端自检。
 *
 * 为什么需要它：阶段 2 的服务层（规则引擎 / 目录 / 更新 / 搜索编排 / Cookie /
 * 反爬编排）此前只在本机 Node 侧跑过，且大部分文件因为不可达而**从未被编译**过。
 * 这里把它们全部拉进可达图，并在真机上跑一遍真实行为，
 * 日志前缀统一为 `AutumnSelf`，一眼能看出通过 / 失败。
 *
 * 用法：ProtoPage 上的「阶段2 自检」按钮（不放在启动流程里——
 * 自检包含网络请求，会拖长冷启动）。
 */
export class Stage2SelfCheck {
  private static passed: number = 0;
  private static failed: number = 0;
  private static running: boolean = false;

  static async run(): Promise<void> {
    if (Stage2SelfCheck.running) {
      hilog.warn(DOMAIN, TAG, '自检已在进行中，忽略重复调用');
      return;
    }
    Stage2SelfCheck.running = true;
    Stage2SelfCheck.passed = 0;
    Stage2SelfCheck.failed = 0;
    // 规则表的快照/还原：自检会临时写入探针规则，跑完必须恢复原样
    const rulesBefore: string[] = Stage2SelfCheck.snapshotRuleNames();
    const startedAt: number = Date.now();
    hilog.info(DOMAIN, TAG, '=== 阶段 2 自检开始 ===');
    try {
      Stage2SelfCheck.checkXPathEngine();
      Stage2SelfCheck.checkJsonPath();
      Stage2SelfCheck.checkApiStrategies();
      Stage2SelfCheck.checkVersionCompare();
      Stage2SelfCheck.checkPluginStorage();
      Stage2SelfCheck.checkCookieIsolation();
      Stage2SelfCheck.checkCatalogParse();
      Stage2SelfCheck.checkInjectionScripts();
      await Stage2SelfCheck.checkSearchOrchestration();
      await Stage2SelfCheck.checkCaptchaOrchestration();
      await Stage2SelfCheck.checkCatalogLive();
      await Stage2SelfCheck.checkUpdateChain();
      await Stage2SelfCheck.checkBangumiApi();
    } catch (e) {
      const err = e as Error;
      Stage2SelfCheck.failed++;
      hilog.error(DOMAIN, TAG, '自检异常中断: %{public}s', err.message);
    } finally {
      Stage2SelfCheck.restoreRuleNames(rulesBefore);
    }
    hilog.info(DOMAIN, TAG,
      '=== 阶段 2 自检结束：通过 %{public}d，失败 %{public}d，耗时 %{public}dms ===',
      Stage2SelfCheck.passed, Stage2SelfCheck.failed, Date.now() - startedAt);
    Stage2SelfCheck.running = false;
  }

  private static snapshotRuleNames(): string[] {
    const names: string[] = [];
    for (let i = 0; i < PluginManager.pluginList.length; i++) {
      names.push(PluginManager.pluginList[i].name);
    }
    return names;
  }

  /** 删掉自检期间新增的规则（原有的一条都不动）。 */
  private static restoreRuleNames(before: string[]): void {
    for (let i = PluginManager.pluginList.length - 1; i >= 0; i--) {
      const name: string = PluginManager.pluginList[i].name;
      let existed: boolean = false;
      for (let j = 0; j < before.length; j++) {
        if (pluginNameKey(before[j]) === pluginNameKey(name)) {
          existed = true;
          break;
        }
      }
      if (!existed) {
        hilog.info(DOMAIN, TAG, '清理自检写入的规则：%{public}s', name);
        PluginManager.remove(name);
      }
    }
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 带一次重试的单条更新。
   * 规则仓库镜像（raw.gitcode.com）会限流，突发请求可能返回 429；
   * 重试一次能把「外部限流」与「链路坏了」区分开。
   */
  private static async tryUpdateWithRetry(name: string): Promise<PluginUpdateResult> {
    const first: PluginUpdateResult = await PluginUpdateService.tryUpdateByName(name);
    if (first !== PluginUpdateResult.failed) {
      return first;
    }
    hilog.warn(DOMAIN, TAG, '更新下载失败，3s 后重试一次（镜像可能限流）');
    await Stage2SelfCheck.delay(3000);
    return await PluginUpdateService.tryUpdateByName(name);
  }

  // ------------------------------------------------------------ XPath 引擎

  /** 与 `tools/verify-xpath.mjs` 同一组用例（本机 19/19，这里在设备上再跑一遍）。 */
  private static checkXPathEngine(): void {
    const html: string = '<html><body>'
      + '<div class="list">'
      + '<div class="item"><a href="/a/1.html" class="t">第一集</a><span>1</span></div>'
      + '<div class="item"><a href="/a/2.html" class="t">第二集</a><span>2</span></div>'
      + '<div class="item"><a href="/a/3.html" class="t">第三集</a><span>3</span></div>'
      + '</div><ul id="roads"><li>线路一</li><li>线路二</li></ul>'
      + '</body></html>';
    const root: HtmlNode = HtmlParser.parseDocumentElement(html);
    const cases: XPathCase[] = [
      new XPathCase("//div[@class='item']", 3),
      new XPathCase("//div[@class='item']/a[@class='t']", 3),
      new XPathCase("//a[contains(@href,'/a/2')]", 1),
      new XPathCase("//a[starts-with(@href,'/a/')]", 3),
      new XPathCase("//a[contains(@class,'t')]", 3),
      new XPathCase("//a[@class='t'][2]", 0),
      new XPathCase("//a[@class='t'][last()]", 3),
      new XPathCase("//a[@class='t'][last()-1]", 0),
      new XPathCase("//a[@class='t'][position()<3]", 3),
      new XPathCase("//div[@class='item'][span>1]", 2),
      new XPathCase("//div[@class='item'][not(@class='nope')]", 3),
      new XPathCase("//div[@class='item'][contains(@class,'i') and @class='item']", 3),
      new XPathCase("//div[@class='item'][@class='item' or @class='x']", 3),
      new XPathCase('//ul/li', 2),
      new XPathCase('//ul/li[1]', 1),
      new XPathCase('//li/text()', 2),
      new XPathCase('//a/@href', 3),
      new XPathCase("//div[@class='item']/@class", 3),
      new XPathCase("//div[@class='item'][1]/a", 1)
    ];
    for (let i = 0; i < cases.length; i++) {
      const expr: string = cases[i].expr;
      let got: number = -1;
      try {
        const nodes: HtmlNode[] = XPath.nodes(root, expr);
        got = nodes.length > 0 ? nodes.length : XPath.query(root, expr).attrs.length;
      } catch (e) {
        got = -1;
      }
      Stage2SelfCheck.expect(got === cases[i].expected,
        `XPath ${expr}`, `引擎=${got} 期望=${cases[i].expected}`);
    }
  }

  // ------------------------------------------------------------ 受限 JSONPath

  private static checkJsonPath(): void {
    const raw: string = '{"n":{"k":7},"a":[{"x":1},{"x":2}]}';
    const document: Object = JSON.parse(raw) as Object;
    Stage2SelfCheck.expect(RestrictedJsonPath.read(document, '$.n.k').length === 1,
      'JSONPath $.n.k', '');
    Stage2SelfCheck.expect(RestrictedJsonPath.read(document, "$['n']['k']").length === 1,
      "JSONPath $['n']['k']", '');
    Stage2SelfCheck.expect(RestrictedJsonPath.read(document, '$["n"]["k"]').length === 1,
      'JSONPath $["n"]["k"]', '');
    Stage2SelfCheck.expect(RestrictedJsonPath.read(document, '$.a[*]').length === 2,
      'JSONPath $.a[*]', '');
    Stage2SelfCheck.expect(RestrictedJsonPath.read(document, '$.a[0]').length === 1,
      'JSONPath $.a[0]', '');
    Stage2SelfCheck.expect(RestrictedJsonPath.read(document, '$.a[9]').length === 0,
      'JSONPath $.a[9] 越界', '');
    const illegal: string[] = [
      'data[*]', '$..data', '$.a[?(@.x)]', '$.a[0', '$.', '$[abc]'
    ];
    for (let i = 0; i < illegal.length; i++) {
      let rejected: boolean = false;
      try {
        RestrictedJsonPath.validate(illegal[i]);
      } catch (e) {
        rejected = true;
      }
      Stage2SelfCheck.expect(rejected, `JSONPath 拒绝 ${illegal[i]}`, '');
    }
  }

  // ------------------------------------------------------------ API 模式

  private static checkApiStrategies(): void {
    const searchConfig = new ApiSearchConfig();
    searchConfig.listPath = '$.data[*]';
    searchConfig.namePath = '$.name';
    searchConfig.sourcePath = '$.url';
    const searchRaw: string =
      '{"data":[{"name":"A","url":"/a"},{"name":"B","url":"/b"}]}';
    const searchItems: SearchItem[] =
      ApiRuleStrategy.parseSearch(searchRaw, searchConfig).items;
    Stage2SelfCheck.expect(searchItems.length === 2 && searchItems[0].name === 'A',
      'API 搜索解析', `条数=${searchItems.length}`);

    const templateConfig = new ApiSearchConfig();
    templateConfig.sourcePath = '$.id';
    templateConfig.sourceTemplate = 'https://s.com/GV@source';
    const templateItems: SearchItem[] = ApiRuleStrategy.parseSearch(
      '{"data":[{"name":"A","id":"88 88"}]}', templateConfig).items;
    Stage2SelfCheck.expect(templateItems.length === 1 &&
      templateItems[0].src === 'https://s.com/GV88%2088',
      'API 搜索详情页模板', templateItems.length > 0 ? templateItems[0].src : '');
    let templateRejected: boolean = false;
    const badTemplate = new ApiSearchConfig();
    badTemplate.sourceTemplate = 'https://s.com/detail';
    try {
      ApiRuleStrategy.validateSearchConfig(badTemplate);
    } catch (e) {
      templateRejected = true;
    }
    Stage2SelfCheck.expect(templateRejected,
      '详情页模板缺少 @source 时拒收', '');

    const nested = new ApiChapterConfig();
    nested.format = ApiChapterFormat.nested;
    nested.roadsPath = '$.data.roads[*]';
    nested.roadNamePath = '$.name';
    nested.episodesPath = '$.episodes[*]';
    nested.episodeNamePath = '$.name';
    nested.episodeUrlPath = '$.url';
    const nestedRaw: string =
      '{"data":{"roads":[{"name":"线路1","episodes":[{"name":"第1集","url":"/p/1"}]}]}}';
    const nestedRoads: Road[] =
      ApiRuleStrategy.parseChapters(nestedRaw, nested, 'https://s.com/1', 'https://s.com')
        .roads;
    Stage2SelfCheck.expect(nestedRoads.length === 1 && nestedRoads[0].data.length === 1,
      'API 章节（嵌套）',
      `线路=${nestedRoads.length} 集=${nestedRoads.length > 0 ? nestedRoads[0].data.length : 0}`);

    const delimited = new ApiChapterConfig();
    delimited.format = ApiChapterFormat.delimited;
    delimited.roadNamesPath = '$.data.roadNames';
    delimited.roadEpisodesPath = '$.data.roadEpisodes';
    delimited.roadSeparator = '$$$';
    delimited.episodeSeparator = '#';
    delimited.fieldSeparator = '$';
    const delimitedRaw: string =
      '{"data":{"roadNames":"线路1$$$线路2",'
      + '"roadEpisodes":"第1集$/p/x1#第2集$/p/x2$$$第1集$/p/y1"}}';
    const delimitedRoads: Road[] =
      ApiRuleStrategy.parseChapters(delimitedRaw, delimited, 'https://s.com/1', 'https://s.com')
        .roads;
    Stage2SelfCheck.expect(delimitedRoads.length === 2,
      'API 章节（分隔符）', `线路=${delimitedRoads.length}`);

    const request = new ApiRequestConfig();
    request.method = 'GET';
    request.url = 'https://s.com/search/@keyword';
    request.query = recordOf('page', 1);
    const variables: Map<string, Object | undefined> =
      new Map<string, Object | undefined>();
    variables.set('keyword', '葬送的芙莉莲');
    const prepared: PreparedRuleRequest = ApiRuleStrategy.prepareRequest(request, variables);
    Stage2SelfCheck.expect(prepared.method === 'GET' &&
      prepared.url.indexOf('search/%E8%91%AC') > 0 &&
      prepared.query['page'] !== undefined,
      'API 请求模板', prepared.url);

    const post = new ApiRequestConfig();
    post.method = 'post';
    post.url = 'https://s.com/api';
    post.bodyType = ApiBodyType.form;
    post.body = recordOf('wd', '@keyword');
    const preparedPost: PreparedRuleRequest =
      ApiRuleStrategy.prepareRequest(post, variables);
    Stage2SelfCheck.expect(preparedPost.method === 'POST' &&
      preparedPost.bodyType === ApiBodyType.form &&
      JSON.stringify(preparedPost.body).indexOf('葬送的芙莉莲') > 0,
      'API POST 模板', JSON.stringify(preparedPost.body));
  }

  // ------------------------------------------------------------ 版本比较

  private static checkVersionCompare(): void {
    Stage2SelfCheck.expect(needUpdate('1.3', '1.4'), 'needUpdate 1.3→1.4', '');
    Stage2SelfCheck.expect(!needUpdate('1.4', '1.3'), 'needUpdate 1.4↛1.3', '');
    Stage2SelfCheck.expect(!needUpdate('1.3', '1.3'), 'needUpdate 同版本', '');
    Stage2SelfCheck.expect(needUpdate('1.3', '1.3.1'), 'needUpdate 缺段补 0', '');
    Stage2SelfCheck.expect(remoteIsNewer('1.3b', '1.3c'), 'remoteIsNewer 非数字段兜底', '');
    Stage2SelfCheck.expect(!remoteIsNewer('1.3b', '1.3b'), 'remoteIsNewer 相同', '');
  }

  // ------------------------------------------------------------ 存储

  private static checkPluginStorage(): void {
    const probe = new Plugin();
    probe.name = '自检探针(Stage2)';
    probe.version = '0.0.1';
    probe.baseUrl = 'https://example.com';
    try {
      PluginManager.upsert(probe);
      const found: Plugin | null = PluginManager.find(probe.name);
      Stage2SelfCheck.expect(found !== null && found.version === '0.0.1',
        '规则存储 upsert/find', found === null ? 'null' : found.version);

      PluginManager.loadAll();
      const reloaded: Plugin | null = PluginManager.find(probe.name);
      Stage2SelfCheck.expect(reloaded !== null && reloaded.baseUrl === 'https://example.com',
        '规则存储落盘重读',
        reloaded === null ? 'null' : reloaded.baseUrl);

      PluginManager.remove(probe.name);
      Stage2SelfCheck.expect(PluginManager.find(probe.name) === null,
        '规则存储 remove', '');
    } catch (e) {
      const err = e as Error;
      Stage2SelfCheck.expect(false, '规则存储', err.message);
    }
  }

  // ------------------------------------------------------------ Cookie 隔离

  private static checkCookieIsolation(): void {
    const a: string = '自检Cookie.A';
    const b: string = '自检Cookie.B';
    PluginCookieManager.clear(a);
    PluginCookieManager.clear(b);
    PluginCookieManager.saveFromWebView(a, 'https://a.example.com/search',
      'cf_clearance=abc; sid=1', 'UA/1');
    const headerA: string =
      PluginCookieManager.cookieHeaderFor(a, 'https://a.example.com/vod/1');
    const headerB: string =
      PluginCookieManager.cookieHeaderFor(b, 'https://a.example.com/vod/1');
    Stage2SelfCheck.expect(headerA.indexOf('cf_clearance=abc') >= 0 && headerB.length === 0,
      'Cookie 按插件隔离', `A="${headerA}" B="${headerB}"`);
    Stage2SelfCheck.expect(PluginCookieManager.userAgentFor(a) === 'UA/1',
      '验证 UA 绑定', PluginCookieManager.userAgentFor(a));
    PluginCookieManager.clear(a);
    PluginCookieManager.clear(b);
  }

  // ------------------------------------------------------------ 目录解析

  private static checkCatalogParse(): void {
    const raw: string = '[{"name":"X","version":"1.0","author":"a",'
      + '"useNativePlayer":true},{"name":"broken"}]';
    const parsed: PluginCatalogParseResult = PluginCatalogApi.parsePluginList(raw);
    Stage2SelfCheck.expect(parsed.items.length === 1 && parsed.skippedItems === 1,
      '目录解析（坏条目跳过）',
      `有效=${parsed.items.length} 跳过=${parsed.skippedItems}`);
    const item: PluginHttpItem = parsed.items[0];
    Stage2SelfCheck.expect(item.name === 'X' && item.useNativePlayer,
      '目录条目字段', `${item.name}/${item.version}/${item.author}`);

    let threw: boolean = false;
    try {
      PluginCatalogApi.parsePluginList('[{"name":"broken"}]');
    } catch (e) {
      threw = true;
    }
    Stage2SelfCheck.expect(threw, '目录全坏应抛错', '');
  }


  // ------------------------------------------------------------ 注入脚本

  private static checkInjectionScripts(): void {
    const start: string = VideoSourceScripts.blobParserScript();
    const end: string = VideoSourceScripts.videoTagParserScript();
    Stage2SelfCheck.expect(start.indexOf('AutumnBridge.hit') >= 0 &&
      start.indexOf('#EXTM3U') >= 0 && start.indexOf('XMLHttpRequest') >= 0,
      '注入脚本（文档开始）', `${start.length} 字节`);
    Stage2SelfCheck.expect(end.indexOf('MutationObserver') >= 0 &&
      end.indexOf('video') >= 0, '注入脚本（文档结束兜底）', `${end.length} 字节`);
  }

  // ------------------------------------------------------------ 搜索编排（真机联网）

  private static async checkSearchOrchestration(): Promise<void> {
    const plugin: Plugin = PluginChainProbe.sevenFun();
    const installedBefore: boolean = PluginManager.find(plugin.name) !== null;
    PluginManager.upsert(plugin);
    try {
      await PluginSearchService.queryAllSource(PluginChainProbe.defaultKeyword);
      const status: PluginSearchStatus | undefined =
        PluginSearchStore.statusOf(plugin.name);
      let hits: number = -1;
      for (let i = 0; i < PluginSearchStore.responses.length; i++) {
        const response: PluginSearchResponse = PluginSearchStore.responses[i];
        if (pluginNameKey(response.pluginName) === pluginNameKey(plugin.name)) {
          hits = response.data.length;
        }
      }
      Stage2SelfCheck.expect(status === PluginSearchStatus.success && hits === 2,
        '搜索编排（多插件并发）',
        `状态=${status === undefined ? 'undefined' : status} 命中=${hits}`);
      Stage2SelfCheck.expect(PluginSearchStore.responses.length >= 1,
        '搜索编排 结果写回', `响应组=${PluginSearchStore.responses.length}`);
    } catch (e) {
      const err = e as Error;
      Stage2SelfCheck.expect(false, '搜索编排', err.message);
    } finally {
      if (!installedBefore) {
        PluginManager.remove(plugin.name);
      }
      PluginSearchStore.clear();
    }
  }

  // ------------------------------------------------------------ 反爬编排

  private static async checkCaptchaOrchestration(): Promise<void> {
    const pluginName: string = '自检Captcha';
    const pageUrl: string = 'https://captcha.example.com/verify';
    PluginCookieManager.clear(pluginName);
    const host = new StubCaptchaHost();
    const service = new CaptchaVerificationService();
    try {
      service.attachHost(host);
      await service.loadForButtonClick(pluginName, pageUrl, "//button[@id='go']");
      const first: CaptchaOutcome | null = await service.finish(pluginName);
      const second: CaptchaOutcome | null = await service.finish(pluginName);
      const cookieHeader: string =
        PluginCookieManager.cookieHeaderFor(pluginName, pageUrl);
      Stage2SelfCheck.expect(first !== null && second === null,
        '验证收尾单飞',
        `第一次=${first === null ? 'null' : 'ok'} 第二次=${second === null ? 'null' : 'ok'}`);
      Stage2SelfCheck.expect(host.loads === 1 && host.unloads === 1,
        '验证宿主调用次数', `load=${host.loads} unload=${host.unloads}`);
      Stage2SelfCheck.expect(cookieHeader.indexOf('cf_clearance=selfcheck') >= 0,
        '验证 Cookie 落库', cookieHeader);
      Stage2SelfCheck.expect(PluginCookieManager.userAgentFor(pluginName) === 'SelfCheckUA/1.0',
        '验证 UA 记录', PluginCookieManager.userAgentFor(pluginName));
    } catch (e) {
      const err = e as Error;
      Stage2SelfCheck.expect(false, '反爬编排', err.message);
    } finally {
      service.dispose();
      PluginCookieManager.clear(pluginName);
    }
  }

  // ------------------------------------------------------------ 规则目录（真机联网）

  private static async checkCatalogLive(): Promise<void> {
    try {
      const first: Promise<PluginHttpItem[]> = PluginUpdateService.refreshCatalog();
      const second: Promise<PluginHttpItem[]> = PluginUpdateService.refreshCatalog();
      const items: PluginHttpItem[] = await first;
      await second;
      Stage2SelfCheck.expect(first === second && items.length > 0,
        '规则目录刷新（单飞）',
        `条数=${items.length} 单飞=${first === second}`);
      Stage2SelfCheck.expect(PluginUpdateService.catalogIsFresh(),
        '目录缓存有效期', `age=${PluginUpdateService.catalogAgeMs()}ms`);
      if (items.length > 0) {
        Stage2SelfCheck.expect(items[0].name.length > 0 && items[0].version.length > 0,
          '目录首条字段', `${items[0].name}@${items[0].version}`);
      }
    } catch (e) {
      const err = e as Error;
      Stage2SelfCheck.expect(false, '规则目录刷新', err.message);
    }
  }

  /** 目录 → 下载 → 校验 → 落盘 的完整更新链路。 */
  private static async checkUpdateChain(): Promise<void> {
    const items: PluginHttpItem[] = PluginUpdateService.catalog;
    if (items.length === 0) {
      Stage2SelfCheck.expect(false, '更新链路', '目录为空，无法验证');
      return;
    }
    const target: PluginHttpItem = items[0];
    const existedBefore: boolean = PluginManager.find(target.name) !== null;
    const fake = new Plugin();
    fake.name = target.name;
    fake.version = '0.0.1';
    fake.baseUrl = 'https://example.invalid';
    try {
      PluginManager.upsert(fake);
      const availability: PluginUpdateAvailability =
        PluginUpdateService.updateAvailability(fake);
      Stage2SelfCheck.expect(availability === PluginUpdateAvailability.updatable,
        '更新可用性判定', `availability=${availability} 本地=0.0.1 目录=${target.version}`);

      const result: PluginUpdateResult =
        await Stage2SelfCheck.tryUpdateWithRetry(target.name);
      const installed: Plugin | null = PluginManager.find(target.name);
      const ok: boolean =
        (result === PluginUpdateResult.updated && installed !== null &&
          installed.version === target.version)
        || result === PluginUpdateResult.requiresNewerClient;
      Stage2SelfCheck.expect(ok, '单条更新（下载+校验+落盘）',
        `结果=${result} 更新后版本=${installed === null ? 'null' : installed.version} 目录=${target.version}`);

      const stale = new Plugin();
      stale.name = target.name;
      stale.version = '99.0.0';
      PluginManager.upsert(stale);
      const downgrade: PluginUpdateResult =
        await Stage2SelfCheck.tryUpdateWithRetry(target.name);
      Stage2SelfCheck.expect(downgrade === PluginUpdateResult.notNewer,
        '不降级（本地 99.0.0）', `结果=${downgrade}`);
    } catch (e) {
      const err = e as Error;
      Stage2SelfCheck.expect(false, '更新链路', err.message);
    } finally {
      if (!existedBefore) {
        PluginManager.remove(target.name);
      }
    }
  }

  // ------------------------------------------------------------ Bangumi API（真机联网）

  private static async checkBangumiApi(): Promise<void> {
    try {
      const list: BangumiItem[] = await BangumiApi.popular('', 1, 0);
      const name: string = list.length > 0 ? list[0].nameCn : '';
      Stage2SelfCheck.expect(list.length >= 1,
        'Bangumi 榜单', `条数=${list.length} 首条=${name}`);
    } catch (e) {
      const err = e as Error;
      Stage2SelfCheck.expect(false, 'Bangumi 榜单', err.message);
    }
    /**
     * 搜索结果的**排名**：旧版搜索路由把 `rank` 放在**顶层**（不是
     * `rating.rank`），详情页的「#排名」直接读 `item.rank`，
     * 解析漏了就会显示 0（用户 2026-09-19：「搜索结果点进去详情页 rank 都是 0」）。
     * 这里拿真实搜索断言一次。
     */
    try {
      const found: BangumiItem[] = await BangumiApi.bangumiSearch('葬送的芙莉莲', 8, 0);
      let withRank: number = 0;
      let sample: string = '';
      for (let i = 0; i < found.length; i++) {
        if (found[i].rank > 0) {
          withRank += 1;
          if (sample.length === 0) {
            sample = `${found[i].nameCn}#${found[i].rank}`;
          }
        }
      }
      Stage2SelfCheck.expect(found.length > 0 && withRank > 0,
        '搜索结果带排名', `条数=${found.length} 有排名=${withRank} 例=${sample}`);
      /**
       * 旧版搜索**不带 `tags`**，详情页要靠 `/p1/subjects/{id}` 补
       * （用户 2026-09-19：「搜索得到的结果的详情页标签无法显示」）。
       * 这条断言同时验证「搜索条目缺的字段，详情接口能补上」。
       */
      if (found.length > 0) {
        const detail: BangumiItem | null =
          await BangumiApi.getBangumiInfoByID(found[0].id);
        const tagCount: number = detail === null ? 0 : detail.tags.length;
        Stage2SelfCheck.expect(detail !== null && tagCount > 0,
          '详情接口带标签', `id=${found[0].id} 标签数=${tagCount}`);
      }
    } catch (e) {
      const err = e as Error;
      Stage2SelfCheck.expect(false, '搜索排名 / 详情标签', err.message);
    }
  }

  // ------------------------------------------------------------ 统计

  private static expect(ok: boolean, name: string, detail: string): void {
    if (ok) {
      Stage2SelfCheck.passed++;
      hilog.info(DOMAIN, TAG, '  PASS %{public}s %{public}s', name, detail);
    } else {
      Stage2SelfCheck.failed++;
      hilog.error(DOMAIN, TAG, '  FAIL %{public}s %{public}s', name, detail);
    }
  }
}
