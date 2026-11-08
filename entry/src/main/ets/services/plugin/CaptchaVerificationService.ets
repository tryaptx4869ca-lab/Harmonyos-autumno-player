import { hilog } from '@kit.PerformanceAnalysisKit';
import { CaptchaType } from '../../plugins/AntiCrawlerConfig';
import { Plugin } from '../../plugins/Plugin';
import { RuleMode } from '../../plugins/ApiRuleConfig';
import { Logger } from '../Logger';
import { PluginCookieManager } from './PluginCookieManager';
import { XPathRuleStrategy } from './XPathRuleStrategy';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnCaptcha';

/**
 * 验证页宿主接口。
 *
 * 反爬必须真的把页面跑起来（验证码是图片、验证按钮要点击、脚本要执行），
 * 因此这里把「宿主」抽象出来：由 UI 层用 ArkWeb 的 `Web` 组件实现，
 * 服务层只负责编排（加载 → 检测 → 动作 → 收 Cookie → 收尾）。
 * 这样服务逻辑可单独测试，UI 只做绑定。
 */
export interface CaptchaWebviewHost {
  /** 加载页面（首次创建与后续跳转都用它）。 */
  loadUrl(url: string): Promise<void>;
  /**
   * 等页面加载完成（`onPageEnd` 或超时）。
   *
   * **为什么接口里必须有这个**：验证码是页面里的元素，页面没加载完时
   * `document.evaluate` 什么也找不到——之前的实现是 `loadUrl` 之后立刻抓图/点按钮，
   * 结果永远是空图、也点不到按钮（真机上表现为「验证码加载不出来」）。
   */
  waitForPageLoad(timeoutMs: number): Promise<boolean>;
  /** 取当前页面 HTML（用于验证后直接解析搜索结果）。 */
  pageHtml(): Promise<string>;
  /** 取 `document.cookie`。 */
  documentCookie(): Promise<string>;
  /** 取当前 WebView 的 User-Agent（验证 Cookie 与它绑定）。 */
  userAgent(): Promise<string>;
  /** 用 XPath 抓取验证码图片的 base64（对应源码的 Canvas 抓取）。 */
  captureImage(xpath: string): Promise<string>;
  /** 取验证码图当前的 `src`；节点不存在时返回 `MISSING`（用于区分「通过」与「换图」）。 */
  imageSrc(xpath: string): Promise<string>;
  /** 等验证码图变化：`gone`（消失，多半通过）/ `changed`（换图，码错了）/ `same`（超时）。 */
  waitForCaptchaChange(xpath: string, previousSrc: string,
    timeoutMs: number): Promise<string>;
  /** 往 XPath 命中的输入框填值并派发 input 事件。 */
  fillInput(xpath: string, value: string): Promise<void>;
  /** 点击 XPath 命中的元素。 */
  /** 返回 JS 侧结果串（`clicked` / `no-node` / `err:…`），见 `CaptchaWebHost.click`。 */
  click(xpath: string): Promise<string>;
  /** 执行自定义验证脚本。 */
  runScript(script: string): Promise<void>;
  /** 卸载页面（收尾时调用）。 */
  unload(): Promise<void>;
}

/** 一次验证的收尾结果。 */
export class CaptchaOutcome {
  readonly pluginName: string;
  readonly pageUrl: string;
  readonly html: string;

  constructor(pluginName: string, pageUrl: string, html: string) {
    this.pluginName = pluginName;
    this.pageUrl = pageUrl;
    this.html = html;
  }
}

/**
 * 反爬验证编排。
 * 对应参照实现 `lib/services/plugin/captcha_verification_service.dart`。
 *
 * 三种验证类型（与源码 `CaptchaType` 一致）：
 *   1 imageCaptcha      抓验证码图片 → 用户输入 → 提交
 *   2 autoClickButton   检测到验证按钮后自动点击
 *   3 customJavaScript  执行规则提供的验证脚本
 *
 * 两条关键约束都照搬了源码：
 *   - **收尾只执行一次**（`_claimOutcome` + `finalize` 单飞），
 *     避免"用户点取消"和"验证成功"同时到达时写出两份 Cookie；
 *   - 收尾时把 Cookie 与当时的 UA 一起存进 `PluginCookieManager`。
 */
export class CaptchaVerificationService {
  private host: CaptchaWebviewHost | null = null;
  private initialized: boolean = false;
  private disposed: boolean = false;
  private pageUrl: string = '';
  private outcomeClaimed: boolean = false;
  private finalizing: Promise<CaptchaOutcome | null> | null = null;

  /** 注入宿主（由 UI 层在 Web 组件就绪后调用）。 */
  attachHost(host: CaptchaWebviewHost): void {
    this.host = host;
    this.initialized = true;
  }

  /**
   * 验证页**应该打开哪个地址**。
   *
   * 结论来自实测：反爬验证是在**搜索请求**上触发的，
   * 打开站点首页往往看不到任何验证（用户反馈「只有这个网站页面」就是这个原因）。
   * 因此这里复用搜索请求的构造逻辑，把「关键词已替换好的搜索 URL」算出来给 Web 用。
   *
   * API 模式或 URL 构造失败时回落到站点首页——至少让用户能看到站点状态。
   */
  static pageUrlFor(plugin: Plugin, keyword: string): string {
    try {
      const config = plugin.executionConfig();
      if (config.searchMode !== RuleMode.xpath || keyword.length === 0) {
        return plugin.baseUrl;
      }
      const request = XPathRuleStrategy.prepareSearchRequest(config, keyword);
      return request.url.length > 0 ? request.url : plugin.baseUrl;
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '计算验证页地址失败，回落到首页：%{public}s', err.message);
      return plugin.baseUrl;
    }
  }

  /** 类型 1：加载验证码页。 */
  async loadForCaptcha(pluginName: string, url: string, captchaXpath: string): Promise<string> {
    const host: CaptchaWebviewHost = this.requireHost();
    if (!this.initialized) {
      throw new Error('CaptchaVerificationService 未初始化');
    }
    this.pageUrl = url;
    await host.loadUrl(url);
    await host.waitForPageLoad(15000);
    const image: string = await host.captureImage(captchaXpath);
    hilog.info(DOMAIN, TAG, '%{public}s 验证码已抓取（%{public}d 字节）',
      pluginName, image.length);
    return image;
  }

  /** 类型 1：提交用户输入的验证码。 */
  async submitCaptcha(inputXpath: string, buttonXpath: string, code: string): Promise<void> {
    const host: CaptchaWebviewHost = this.requireHost();
    await host.fillInput(inputXpath, code);
    await host.click(buttonXpath);
  }

  /**
   * 类型 2：加载页面并自动点击验证按钮。
   *
   * ## 按钮不存在是**正常情况**（用户 2026-09-19：「LMM 验证不行」）
   *
   * 实测 LMM（`lmm85.com`）：搜索请求返回的是标题「身份验证」的页面，
   * 验证逻辑全在站点自己的混淆脚本里（`/template/jable/statics/js/search.js`，
   * 跑完 XHR 后 `location.reload()`），页面上**没有**规则里配的那个
   * 「立即验证」按钮。以前这里点不到就静默返回，用户看到的是「验证页卡住」；
   * 现在按「自动验证页」处理：
   *   1. 先等 1.5s 再点一次（有些站点脚本后注入按钮）；
   *   2. 还是没有 → 再等 2.5s，**给挑战脚本跑完、写 Cookie 的时间**，
   *      然后再交给用户点「完成」（收尾会读 `document.cookie`）。
   */
  async loadForButtonClick(pluginName: string, url: string, buttonXpath: string): Promise<void> {
    const host: CaptchaWebviewHost = this.requireHost();
    this.pageUrl = url;
    await host.loadUrl(url);
    await host.waitForPageLoad(15000);
    let result: string = await host.click(buttonXpath);
    if (result !== 'clicked') {
      await CaptchaVerificationService.delay(1500);
      result = await host.click(buttonXpath);
    }
    if (result === 'clicked') {
      hilog.info(DOMAIN, TAG, '%{public}s 已自动点击验证按钮', pluginName);
      return;
    }
    await CaptchaVerificationService.delay(2500);
    hilog.info(DOMAIN, TAG,
      '%{public}s 页面没有验证按钮（自动验证页）：已等待挑战脚本执行，' +
        '点「完成」会带着新 Cookie 重试', pluginName);
    Logger.info('AutumnCaptcha',
      `${pluginName} 自动验证页（无按钮）：等待挑战脚本后收尾`);
  }

  /** 计时等待（不影响 UI 线程的简单实现）。 */
  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 类型 3：加载页面并执行自定义脚本。 */
  async loadForCustomScript(pluginName: string, url: string, script: string): Promise<void> {
    const host: CaptchaWebviewHost = this.requireHost();
    this.pageUrl = url;
    await host.loadUrl(url);
    await host.waitForPageLoad(15000);
    await host.runScript(script);
    hilog.info(DOMAIN, TAG, '%{public}s 已执行自定义验证脚本', pluginName);
  }

  /** 用户取消，但仍要把已拿到的 Cookie 存下来（源码 `cancelAndSave`）。 */
  async cancelAndSave(pluginName: string): Promise<void> {
    await this.saveCookies(pluginName);
    this.outcomeClaimed = true;
    await this.unload();
  }

  /**
   * 验证流程结束：取 Cookie + 页面 HTML 作为收尾结果。
   * 只会真正执行一次（后续调用返回同一次的结果或 null）。
   */
  async finish(pluginName: string): Promise<CaptchaOutcome | null> {
    if (this.outcomeClaimed) {
      return null;
    }
    if (this.finalizing !== null) {
      return await this.finalizing;
    }
    this.finalizing = this.finalize(pluginName);
    return await this.finalizing;
  }

  private async finalize(pluginName: string): Promise<CaptchaOutcome | null> {
    const url: string = this.pageUrl;
    try {
      await this.saveCookies(pluginName);
      const host: CaptchaWebviewHost = this.requireHost();
      const html: string = await host.pageHtml();
      this.outcomeClaimed = true;
      return new CaptchaOutcome(pluginName, url, html);
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '验证收尾失败: %{public}s', err.message);
      return null;
    } finally {
      await this.unload();
    }
  }

  private async saveCookies(pluginName: string): Promise<void> {
    if (this.host === null) {
      return;
    }
    try {
      const cookie: string = await this.host.documentCookie();
      const userAgent: string = await this.host.userAgent();
      // UA 必须记下来：站点把「已验证」绑在 User-Agent 上（主机侧对照实验：
      // 换 UA 重放同一会话会被打回验证页，并把原验证状态一起作废），
      // 只有拿到当时那个 UA 才能在重搜时复现同一个身份。
      hilog.info(DOMAIN, TAG, '%{public}s 验证收尾：Cookie %{public}d 字节，UA %{public}d 字节（%{public}s）',
        pluginName, cookie.length, userAgent.length,
        userAgent.length > 60 ? userAgent.substring(0, 60) : userAgent);
      if (userAgent.length === 0) {
        hilog.warn(DOMAIN, TAG, '取不到验证时的 UA，重搜会被站点判回验证页');
      }
      PluginCookieManager.saveFromWebView(pluginName, this.pageUrl, cookie, userAgent);
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '取 Cookie 失败: %{public}s', err.message);
    }
  }

  private async unload(): Promise<void> {
    if (this.host !== null) {
      try {
        await this.host.unload();
      } catch (e) {
        // 卸载失败不影响流程
      }
    }
  }

  private requireHost(): CaptchaWebviewHost {
    if (this.host === null) {
      throw new Error('验证页宿主未注入（UI 层需先 attachHost）');
    }
    return this.host;
  }

  /** 释放（对应源码 `dispose`）。 */
  dispose(): void {
    this.disposed = true;
    this.host = null;
    this.initialized = false;
    this.outcomeClaimed = false;
    this.finalizing = null;
  }

  get isDisposed(): boolean {
    return this.disposed;
  }
}
