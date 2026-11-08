import { hilog } from '@kit.PerformanceAnalysisKit';
import { RuleMode } from '../../plugins/ApiRuleConfig';
import { Plugin, pluginNameKey } from '../../plugins/Plugin';
import { Logger } from '../Logger';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnPluginPatch';

/**
 * 内置规则补丁。
 *
 * 规则是从仓库（KazumiRules）下载的，仓库那边修好之前，站点改版会让一条规则
 * 完全用不了。这里在**规则载入 / 导入之后**打补丁，改的是本地规则表。
 *
 * 两条纪律：
 *   1. **只在「仍然是坏的那一版」时才打**——判据用坏版本的标志字段
 *      （例如 7sefun 的 `searchList`）。上游哪天修好了，字段一变，
 *      补丁自动失效，不会把新规则盖回去；
 *   2. 每次打补丁都写进应用日志（`我的 → 日志` 可读），
 *      免得以后有人对着一份「看起来是仓库原版」的规则查半天。
 *
 * 7sefun 的三个选择器是 2026-09 真机 + 浏览器实测的结果
 * （搜索页 2 个 `div.video.anim`、详情页 2 个 `div.chat`、20 个 `/vodplay/` 链接），
 * 与 `tools/fetch-probe-url.mjs` / `PluginChainProbe.sevenFun()` 用的是同一套。
 */
export class PluginPatches {
  /** 对一条规则打补丁；返回是否发生了修改。 */
  static apply(plugin: Plugin): boolean {
    const key: string = pluginNameKey(plugin.name);
    if (key === '7sefun') {
      return PluginPatches.patchSevenFun(plugin);
    }
    if (key === 'age') {
      return PluginPatches.patchAge(plugin);
    }
    if (key === 'dalvdm') {
      return PluginPatches.patchDalvdm(plugin);
    }
    if (key === 'mgnacg') {
      return PluginPatches.patchMgnacg(plugin);
    }
    return false;
  }

  /** 逐条打补丁，返回修改条数。 */
  static applyAll(plugins: Plugin[]): number {
    let changed: number = 0;
    for (let i = 0; i < plugins.length; i++) {
      if (PluginPatches.apply(plugins[i])) {
        changed += 1;
      }
    }
    return changed;
  }

  /**
   * 7sefun：仓库 v1.3 的选择器是站点改版**之前**的位置型 XPath
   * （`//div[2]/div[2]/div[2]/div[2]/div`），现在一个结果都解析不出来，
   * 规则测试页直接报 `NoResultException: 7sefun returned no search results`。
   * 换成当前结构的选择器后，端到端能取到
   * `https://www.7sefun.top/vodplay/26976-2-1.html`。
   */
  private static patchSevenFun(plugin: Plugin): boolean {
    // 已经不是「坏版本」了就不动它（上游修好 / 用户自己改过）
    if (plugin.searchList !== PluginPatches.SEVENFUN_STALE_SEARCH_LIST) {
      return false;
    }
    plugin.baseUrl = 'https://www.7sefun.top';
    plugin.searchURL =
      'https://www.7sefun.top/vodsearch/-------------.html?wd=@keyword';
    plugin.searchList = "//div[@class='video anim']";
    plugin.searchName = "//div[@class='video-by']";
    plugin.searchResult = "//a[@class='video-wrapper']";
    plugin.chapterRoads = "//div[@class='chat']";
    plugin.chapterResult = "//a[contains(@href,'/vodplay/')]";
    const message: string =
      '[规则补丁] 7sefun 选择器已更新到当前站点结构（原 v1.3 规则已失效）';
    hilog.info(DOMAIN, TAG, '%{public}s', message);
    Logger.info('PluginPatch', message);
    return true;
  }

  /** 仓库 v1.3 的 searchList，用来识别「还没打过补丁」的那一版。 */
  private static readonly SEVENFUN_STALE_SEARCH_LIST: string =
    '//div[2]/div[2]/div[2]/div[2]/div';

  /**
   * AGE（`agedm.io`）：仓库 v1.5 的选择器全是**位置型** XPath
   * （`//div[2]/div/section/div/div/div/div` 这种），站点改版后对不上。
   *
   * 2026-09-19 实测（关键字「名侦探柯南」）：
   *   - 搜索页：13 张卡，结构 `div.card.cata_video_item` +
   *     `h5.card-title > a[href=/detail/{id}]`（标题文本就在这个 a 里）；
   *   - 详情页：8 条线路，每条是 `ul.video_detail_episode`，
   *     集链接 `li > a[href=/play/{id}/{线路}/{集}]`（柯南 9807 个链接）。
   * 所以这里换成**按 class 取**，站点再改版也不会因为层级挪动而整条失效。
   */
  private static patchAge(plugin: Plugin): boolean {
    if (plugin.searchList !== PluginPatches.AGE_STALE_SEARCH_LIST) {
      return false;
    }
    plugin.searchList = "//div[contains(@class,'cata_video_item')]";
    plugin.searchName = ".//h5[contains(@class,'card-title')]/a";
    plugin.searchResult = ".//h5[contains(@class,'card-title')]/a";
    plugin.chapterRoads = "//ul[@class='video_detail_episode']";
    plugin.chapterResult = './/li/a';
    const message: string =
      '[规则补丁] AGE 选择器已换成按 class 取（原 v1.5 位置型路径已失效）';
    hilog.info(DOMAIN, TAG, '%{public}s', message);
    Logger.info('PluginPatch', message);
    return true;
  }

  /** 仓库 v1.5 的 searchList，用来识别「还没打过补丁」的那一版。 */
  private static readonly AGE_STALE_SEARCH_LIST: string =
    '//div[2]/div/section/div/div/div/div';

  /**
   * dalvdm：**整个站点都换了**，旧规则从「验证码选择器抄错」升级成「完全对不上」。
   *
   * 2026-09-19 实测：
   *   - `www.dalvdm.cc` 现在 **301 → `www.sbdl.cc`**（同一个站，换了域名）；
   *   - 前端也整套换了（MyTheme，不再是旧 macCMS 模板）：旧规则要的
   *     `ul.anthology-list-play` / `div.vod-detail.style-detail.cor4.search-list`
   *     在新站里**一个都不存在**；
   *   - 更要命的是：验证会话（`PHPSESSID`）是签发在 `www.sbdl.cc` 上的，
   *     而规则/验证页地址还是 `www.dalvdm.cc`——Cookie 按 host 存取，跨域后
   *     一个都带不回去，于是「验证过了也还是要求验证」。
   *
   * 新站的可取之处：搜索有**不需要过验证码**的接口
   * `/index.php/ajax/suggest?mid=1&wd=@keyword&limit=24`（实测按关键词过滤、
   * `limit` 生效），只是每条只回 `{id, name, en, pic}`，详情地址得自己拼——
   * 所以 `sourcePath` 写成模板 `/index.php/vod/detail/id/@id.html`
   * （模板这条能力见 `ApiRuleStrategy.searchSource`）。
   *
   * 章节页面地址（detail_link）与剧集地址都实测过：
   *   - 线路：`//div[contains(@class,'lists-box')]`（即 `#playlist1/2/3`）
   *   - 剧集：`.//div[contains(@class,'listitem')]/a`
   *     → `/index.php/vod/play/id/{id}/sid/{sid}/nid/{nid}.html`
   * 验证脚本见 `tools/verify-dalvdm.mjs`（对着真实响应跑工程自己的引擎）。
   */
  private static patchDalvdm(plugin: Plugin): boolean {
    const stale: boolean = plugin.baseUrl.indexOf(PluginPatches.DALVDM_STALE_HOST) >= 0 ||
      plugin.searchURL.indexOf(PluginPatches.DALVDM_STALE_HOST) >= 0;
    if (!stale) {
      return false;
    }
    plugin.baseUrl = 'https://www.sbdl.cc/';
    plugin.searchURL = 'https://www.sbdl.cc/index.php/vod/search.html?wd=@keyword';
    // 搜索走 JSON 接口：不但免验证码，也不会再撞上「验证会话在另一个域」那件事
    plugin.searchMode = RuleMode.api;
    const search = plugin.searchApiConfig;
    search.request.method = 'GET';
    search.request.url =
      'https://www.sbdl.cc/index.php/ajax/suggest?mid=1&wd=@keyword&limit=24';
    search.request.headers = {};
    search.request.query = {};
    search.listPath = '$.list[*]';
    search.namePath = '$.name';
    search.sourcePath = '/index.php/vod/detail/id/@id.html';
    /**
     * XPath 侧也一并写上：按**同一套主题的列表组件**推的
     * （`/index.php/vod/type/id/20.html` 实测就是 `a.myui-vodbox-content` +
     * 里面 `div.title`），`tools/verify-dalvdm.mjs` 会拿它对着该页面跑一遍。
     * 但搜索页要过验证码、抓不到，所以这条**不是**主路径——
     * 只在用户手动把规则改回 XPath 模式时才用到。
     */
    plugin.searchList = "//div[contains(@class,'myui-vodbox-content')]";
    plugin.searchName = ".//div[contains(@class,'title')]";
    plugin.searchResult = './/a';
    plugin.chapterMode = RuleMode.xpath;
    plugin.chapterRoads = "//div[contains(@class,'lists-box')]";
    plugin.chapterResult = ".//div[contains(@class,'listitem')]/a";
    // 搜索不再过验证码；选择器留着，用户切回 XPath 模式时仍然是对的
    plugin.antiCrawlerConfig.enabled = false;
    plugin.antiCrawlerConfig.captchaImage = "//img[contains(@class,'mac_verify_img')]";
    plugin.antiCrawlerConfig.captchaInput = "//input[@name='verify']";
    plugin.antiCrawlerConfig.captchaButton = "//input[contains(@class,'verify_submit')]";
    plugin.version = '2.0';
    const message: string =
      '[规则补丁] dalvdm 已改到新站 www.sbdl.cc（搜索走免验证码的 ajax/suggest）';
    hilog.info(DOMAIN, TAG, '%{public}s', message);
    Logger.info('PluginPatch', message);
    return true;
  }

  /** 仓库 v1.0 的域名，用来识别「还没打过补丁」的那一版。 */
  private static readonly DALVDM_STALE_HOST: string = 'dalvdm.cc';

  /**
   * mgnacg（`mgnacg.com`）：验证弹窗的图片选择器还对得上
   * （`img.ds-verify-img`，`src=/verify/index.html` 实测返回 `image/png`），
   * 但输入框/按钮是位置型路径（`//div[3]/div[2]/div/div/input`、
   * `//div[3]/div[2]/p/input`），层级一动就抓不到 →
   * 用户看到的「验证不行」。
   *
   * 2026-09-19 实测的真实结构：
   *   `<input type="text" class="… ds-verify" name="verify">`
   *   `<input type="button" class="… verify-submit" value="提交验证">`
   */
  private static patchMgnacg(plugin: Plugin): boolean {
    const anti = plugin.antiCrawlerConfig;
    if (anti.captchaInput !== '//div[3]/div[2]/div/div/input') {
      return false;
    }
    anti.captchaInput = "//input[@name='verify']";
    anti.captchaButton = "//input[contains(@class,'verify-submit')]";
    const message: string =
      '[规则补丁] mgnacg 验证码输入框/按钮已换成按属性取（原位置型路径已失效）';
    hilog.info(DOMAIN, TAG, '%{public}s', message);
    Logger.info('PluginPatch', message);
    return true;
  }
}
