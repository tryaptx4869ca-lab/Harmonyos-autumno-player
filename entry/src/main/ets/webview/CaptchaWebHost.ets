import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CaptchaWebviewHost } from '../services/plugin/CaptchaVerificationService';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnCaptchaHost';

/**
 * 反爬验证宿主的 ArkWeb 实现（服务层只认 `CaptchaWebviewHost` 接口）。
 *
 * 为什么把宿主做成「普通类 + 组件壳」而不是让 `@Component struct` 直接实现接口：
 * ArkUI 的组件实例由框架创建，父组件拿不到它的引用；而服务层需要 `attachHost(host)`。
 * 因此由父组件持有本类的实例、再把它交给 `CaptchaWebHostView` 去挂 `Web`——
 * 控制器、注入、取值都在本类里，组件只负责渲染。
 *
 * 取页面数据统一走 `runJavaScript`（ArkWeb 的文档级注入已在阶段 0 验过时机），
 * XPath 求值放在页面上下文里做，与服务层的编排逻辑解耦。
 */
export class CaptchaHostBridge implements CaptchaWebviewHost {
  controller: webview.WebviewController = new webview.WebviewController();
  /** 用于把验证码图落盘（`Image` 渲染 base64 实测是空白的，走文件最稳）。 */
  private context: common.UIAbilityContext | null = null;

  /**
   * 文档开始注入的探针脚本。
   *
   * 必须在**文档开始**就挂钩子：验证页的「提交验证」是站点自己的
   * `$(function(){ EC.Verify.Init(); ... })` 里绑的，等到 `onPageEnd` 再注入
   * 就看不到页面脚本早先的报错，也看不到按钮上到底有没有绑定处理器。
   *
   * 记三件事：
   *   1. 页面脚本抛了什么错（`error` / `unhandledrejection`）——
   *      站点 JS 一旦在前面某一步抛错，后面 `EC.Verify.Init()` 就不会执行，
   *      此时点「提交验证」**不会有任何反应**（不报错、不发请求），
   *      从外部看就是「验证码过不了」；
   *   2. 所有 XHR / fetch 的请求与应答；
   *   3. 供 `readDiagnostics` 读取的关键对象是否存在（`EC`、`maccms`、`jQuery`）。
   */
  static startupProbeScript(): string {
    return `(function(){try{window.__autumnLog=[];
window.addEventListener('error',function(e){try{window.__autumnLog.push('error: '+String(e.message)+' @'+String(e.filename)+':'+String(e.lineno));}catch(x){}});
window.addEventListener('unhandledrejection',function(e){try{window.__autumnLog.push('reject: '+String(e.reason));}catch(x){}});
var op=XMLHttpRequest.prototype.open,se=XMLHttpRequest.prototype.send;
XMLHttpRequest.prototype.open=function(m,u){try{this.__am=m;this.__au=String(u);}catch(x){}return op.apply(this,arguments);};
XMLHttpRequest.prototype.send=function(){var s=this;try{s.addEventListener('loadend',function(){try{window.__autumnLog.push('xhr '+String(s.status)+' '+String(s.__am)+' '+String(s.__au)+' => '+String(s.responseText).slice(0,160));}catch(x){}});}catch(x){}return se.apply(this,arguments);};
var of=window.fetch;if(of){window.fetch=function(){try{window.__autumnLog.push('fetch '+String(arguments[0]));}catch(x){}return of.apply(this,arguments);};}
}catch(e){}})()`;
  }

  /**
   * 读探针结果：关键对象是否存在、按钮上绑了哪些事件、页面脚本报过什么错、发过哪些请求。
   * 一行日志就能把「点了没反应」的几种原因区分开。
   */
  async readDiagnostics(): Promise<string> {
    const script: string = `(function(){try{var out=[];
out.push('EC='+(typeof EC)+' maccms='+(typeof maccms)+' jquery='+(typeof jQuery));
var b=document.querySelector('.verify-submit');
var ev='';
try{var d=jQuery&&jQuery._data?jQuery._data(b,'events'):null;ev=d?Object.keys(d).join(','):'(none)';}catch(x){ev='?';}
out.push('button='+(b?'found':'missing')+' handlers='+ev);
var lg=window.__autumnLog||[];
out.push('log['+lg.length+']='+lg.slice(-8).join(' | '));
return out.join(' ;; ');}catch(e){return 'probe-error:'+e.message;}})()`;
    return await this.evalJs(script);
  }

  attachContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /**
   * 首帧要绑给 `Web` 的地址。
   *
   * **必须由组件把它当 `src` 用**，不能只靠 `controller.loadUrl`：
   * 固定 `about:blank` 再 loadUrl 会被组件重绘时重新下发的 `src` 顶掉
   * （阶段四在取流宿主上实测过，日志是 `loadUrl(目标)` 紧跟着
   * `onPageBegin url=about:blank`，页面永远停在空白页）。
   * 验证页同样栽在这上面——表现就是「验证码加载不出来」。
   */
  initialSrc: string = '';

  /** 控制器是否已与 `Web` 关联（未关联时 loadUrl 会直接抛异常）。 */
  private attached: boolean = false;
  /** 当前地址（用于避免对同一个地址重复加载）。 */
  private currentUrl: string = '';
  /** 页面是否已加载完（`onPageEnd`）。 */
  private pageLoaded: boolean = false;
  private loadWaiters: (() => void)[] = [];

  /** 组件在 `onControllerAttached` 里调用。 */
  markAttached(): void {
    this.attached = true;
    // 首帧的地址已经通过 `src` 交给组件了，这里只记下来
    if (this.initialSrc.length > 0 && this.currentUrl.length === 0) {
      this.currentUrl = this.initialSrc;
    }
  }

  /** 组件在 `onPageEnd` 里调用。 */
  markPageEnded(): void {
    this.pageLoaded = true;
    const waiters: (() => void)[] = this.loadWaiters;
    this.loadWaiters = [];
    for (let i = 0; i < waiters.length; i++) {
      waiters[i]();
    }
  }

  /**
   * 组件卸载时调用（弹层关闭）。
   *
   * 必须显式复位 `attached`：它只在 `onControllerAttached` 里被置 true，
   * 组件销毁后没有任何回调会把它改回来，下一次会话就会误判成「已关联」，
   * 于是跳过 `src` 加载、直接调用 `loadUrl` 抛异常（mgnacg 就是这么挂的）。
   */
  markDetached(): void {
    this.attached = false;
    this.pageLoaded = false;
    this.currentUrl = '';
    this.initialSrc = '';
  }

  /** 求值 XPath 并返回首个命中节点（页面上下文）。 */
  private static xpathNode(expr: string): string {
    return `(function(){try{var r=document.evaluate(${JSON.stringify(expr)},document,null,`
      + `XPathResult.FIRST_ORDERED_NODE_TYPE,null);return r.singleNodeValue;}catch(e){return null;}})()`;
  }

  /**
   * 剥掉 ArkWeb `runJavaScript` 给字符串结果加的 JSON 引号。
   *
   * 真机实测（2026-09-15）：同一个 XPath 在 `waitForElement` 里永远等不到，
   * 而紧接着的抓图脚本又能拿到节点；同时 base64 串喂给 `decodeSync` 报
   * 「The input string contains unsupported characters」。两个症状同源——
   * 回调拿到的其实是 `"……"`（带引号）而不是裸值：
   *   - `found === '1'` 永不成立 → 每次都白等满 8 秒；
   *   - base64 末尾多一个 `"` → 解码直接抛错 → 验证码图落不了盘、界面显示空白。
   *
   * 只在**首尾都是引号**时才当 JSON 字符串解一次，其余情况原样返回。
   */
  private static unwrap(raw: string): string {
    if (raw.length < 2) {
      return raw;
    }
    if (raw.charAt(0) !== '"' || raw.charAt(raw.length - 1) !== '"') {
      return raw;
    }
    try {
      const parsed = JSON.parse(raw) as string;
      return typeof parsed === 'string' ? parsed : raw;
    } catch (e) {
      return raw;
    }
  }

  /** 跑一段 JS 并取字符串结果（失败一律返回空串，由编排层决定重试或超时）。 */
  private evalJs(script: string): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      try {
        this.controller.runJavaScript(script, (err: BusinessError, value: string) => {
          if (err) {
            hilog.warn(DOMAIN, TAG, 'runJavaScript 失败: %{public}s', err.message);
            resolve('');
            return;
          }
          resolve(value === undefined || value === null ? ''
            : CaptchaHostBridge.unwrap(String(value)));
        });
      } catch (e) {
        const error = e as Error;
        hilog.warn(DOMAIN, TAG, 'runJavaScript 抛异常: %{public}s', error.message);
        resolve('');
      }
    });
  }

  async loadUrl(url: string): Promise<void> {
    this.initialSrc = url;
    if (url === this.currentUrl && this.pageLoaded) {
      // 同一个地址已经在页面上（首帧 `src` 已经加载过它），别再加载一次：
      // 重复加载会把用户已经填了一半的验证码刷掉。
      hilog.info(DOMAIN, TAG, '验证页已是目标地址，跳过重复加载');
      return;
    }
    this.pageLoaded = false;
    this.currentUrl = url;
    if (!this.attached) {
      // 还没关联：地址已写进 `initialSrc`，等组件创建时用 `src` 加载
      hilog.info(DOMAIN, TAG, '控制器未就绪，等待组件以 src 加载 %{public}s', url);
      return;
    }
    try {
      hilog.info(DOMAIN, TAG, '加载验证页 %{public}s', url);
      this.controller.loadUrl(url);
    } catch (e) {
      // 组件已经卸载（弹层关闭）时控制器会脱离 Web 组件，`loadUrl` 抛
      // `Init error. The WebviewController must be associated with a Web component`。
      // 真机踩过：`attached` 只在 `onControllerAttached` 里置 true、从不复位，
      // 于是下一次验证带着陈旧状态直接抛异常，**页面根本没加载**，
      // 后面抓图自然什么都找不到（表现为「验证码图片无法显示」）。
      const error = e as Error;
      this.attached = false;
      hilog.warn(DOMAIN, TAG, '控制器已脱离，改由组件以 src 加载：%{public}s',
        error.message);
    }
  }

  /**
   * 等页面加载完成。
   *
   * 三条退出路径：`onPageEnd` 触发、超时、以及「文档已经是 complete」
   * （有些页面在组件创建时就完成了，不会再发一次 onPageEnd）。
   */
  async waitForPageLoad(timeoutMs: number): Promise<boolean> {
    if (this.pageLoaded || await this.documentComplete()) {
      return true;
    }
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      let settled: boolean = false;
      const done = (value: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(value);
      };
      const timer = setTimeout(() => {
        hilog.warn(DOMAIN, TAG, '等待页面加载超时');
        done(false);
      }, timeoutMs);
      this.loadWaiters.push(() => {
        done(true);
      });
    });
  }

  /** `document.readyState === 'complete'`。 */
  private async documentComplete(): Promise<boolean> {
    if (!this.attached) {
      // 控制器还没与组件关联时 runJavaScript 会抛
      // `Init error. The WebviewController must be associated with a Web component`；
      // 这时直接当作「还没加载完」，等 `onPageEnd` 即可。
      return false;
    }
    const state: string = await this.evalJs('document.readyState');
    // 用 includes 而不是全等：返回串可能带引号或前后空白（见 `unwrap` 的注释）。
    return state.indexOf('complete') >= 0;
  }

  /**
   * 等某个 XPath 元素出现（默认 8 秒）。
   *
   * 为什么需要：`onPageEnd` 只保证文档加载完，验证码图片可能是异步插进来的
   * （`img` 的 `src` 后到）。抓图/点按钮之前先等元素，比固定 sleep 稳。
   */
  private async waitForElement(xpath: string, timeoutMs: number): Promise<boolean> {
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const found: string = await this.evalJs(
        `(function(){try{var r=document.evaluate(${JSON.stringify(xpath)},document,null,`
        + `XPathResult.FIRST_ORDERED_NODE_TYPE,null);return r.singleNodeValue?'1':'';}`
        + `catch(e){return '';}})()`);
      if (found.indexOf('1') >= 0) {
        return true;
      }
      await CaptchaHostBridge.sleep(200);
    }
    hilog.warn(DOMAIN, TAG, '等待元素超时：%{public}s', xpath);
    return false;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /** 取整页 HTML：验证通过后可以直接当搜索结果解析，省一次网络往返。 */
  async pageHtml(): Promise<string> {
    return await this.evalJs('document.documentElement.outerHTML');
  }

  async documentCookie(): Promise<string> {
    // **必须从平台的 Cookie 管理器取，不能用 `document.cookie`**：
    // 反爬站点发的清除凭据（Cloudflare 的 `cf_clearance`、各类 `*_verify`）
    // 基本都是 **HttpOnly**，JS 读不到——只取 `document.cookie` 会漏掉最关键的那条，
    // 于是「验证完成」后重试仍然被判需要验证（真机上实测过：流程全绿、结果不变）。
    // `fetchCookie` 返回的是该地址的完整 Cookie 头字符串（含 HttpOnly）。
    try {
      const cookie: string = await webview.WebCookieManager.fetchCookie(
        this.currentUrl);
      if (cookie.length > 0) {
        hilog.info(DOMAIN, TAG, '从 Cookie 管理器取到 %{public}d 字节 Cookie',
          cookie.length);
        return cookie;
      }
    } catch (e) {
      const error = e as Error;
      hilog.warn(DOMAIN, TAG, 'fetchCookie 失败，回落到 document.cookie：%{public}s',
        error.message);
    }
    return await this.evalJs('document.cookie');
  }

  async userAgent(): Promise<string> {
    return await this.evalJs('navigator.userAgent');
  }

  /**
   * 抓验证码图片：取 XPath 命中的 `<img>`，画到 canvas 上导出 dataURL
   * （对应源码用 Canvas `toDataURL` 的做法）。
   * 跨域图片会污染画布导致 `toDataURL` 抛错，此时返回空串。
   */
  async captureImage(xpath: string): Promise<string> {
    // 抓图前先等元素（图片常常是异步插进来的）
    await this.waitForElement(xpath, 8000);
    // 再等它**真正解码完成**——元素在 ≠ 图能画。
    // 参照实现 `_captureAsBase64` 就是等 `img.complete && naturalWidth > 0`（否则挂
    // `load` 监听）。真机实测（mutefun / www.2kdm.com）：元素早就有了，但
    // `natural=0x0 complete=false`，此时 drawImage 只能得到空白画布，
    // 用户看到的就是「验证码图片无法显示」。
    await this.waitForImageDecoded(xpath, 12000);
    await this.logImageState(xpath);
    const script: string = `(function(){try{var n=${CaptchaHostBridge.xpathNode(xpath)};`
      + `if(!n||!n.src)return '';var c=document.createElement('canvas');`
      + `c.width=n.naturalWidth||n.width;c.height=n.naturalHeight||n.height;`
      // 0×0 画布在 Chromium 里会返回 `data:,`（不含 `base64,`），
      // 上层会当「抓不到」处理，但日志里看不出原因，所以这里直接给出结论。
      + `if(!c.width||!c.height)return 'EMPTY';`
      + `c.getContext('2d').drawImage(n,0,0);return c.toDataURL('image/png');}catch(e){return '';}})()`;
    const result: string = await this.evalJs(script);
    if (result === 'EMPTY') {
      hilog.warn(DOMAIN, TAG, '验证码图尺寸为 0（图片未真正解码），无法抓图');
      return '';
    }
    hilog.info(DOMAIN, TAG, '抓图返回 %{public}d 字符，前缀=%{public}s',
      result.length, result.length > 40 ? result.substring(0, 40) : result);
    return result;
  }

  /**
   * 等验证码 `<img>` 解码完成（`complete && naturalWidth > 0`）。
   * 超时返回 false，由调用方按「拿不到图」处理（对话框会给出「重新加载」）。
   */
  private async waitForImageDecoded(xpath: string, timeoutMs: number): Promise<boolean> {
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const ready: string = await this.evalJs(
        `(function(){try{var n=${CaptchaHostBridge.xpathNode(xpath)};`
        + `if(!n)return '0';return (n.complete&&n.naturalWidth>0)?'1':'0';}`
        + `catch(e){return '0';}})()`);
      if (ready.indexOf('1') >= 0) {
        return true;
      }
      await CaptchaHostBridge.sleep(200);
    }
    hilog.warn(DOMAIN, TAG, '等待验证码图解码超时：%{public}s', xpath);
    return false;
  }

  /**
   * 把验证码 `<img>` 的真实状态写进日志（对应源码里「等图片 load 事件」那一步）。
   *
   * 为什么必须记录：真机上页面里的验证码图看着是**纯黑一块**，究竟是没有
   * `src`、还是加载失败、还是解码尺寸为 0，只看界面无法区分——这三者的修法完全不同。
   */
  private async logImageState(xpath: string): Promise<void> {
    const script: string = `(function(){try{var n=${CaptchaHostBridge.xpathNode(xpath)};`
      + `if(!n)return 'node=null';return 'src='+String(n.src||'').slice(0,80)`
      + `+' natural='+n.naturalWidth+'x'+n.naturalHeight+' wh='+n.width+'x'+n.height`
      + `+' complete='+n.complete+' crossOrigin='+String(n.crossOrigin)`
      + `+' display='+getComputedStyle(n).display+' vis='+getComputedStyle(n).visibility;`
      + `}catch(e){return 'probe-err:'+e.message;}})()`;
    hilog.info(DOMAIN, TAG, '验证码图状态 %{public}s', await this.evalJs(script));
  }

  /**
   * 取验证码图当前的 `src`；节点不存在时返回 `MISSING`。
   *
   * 用来区分提交验证码之后的两种结果：图**消失**（多半是通过）与
   * 图**换了一张**（服务端判定验证码错误，重新下发）。原先只看「还能不能抓到图」，
   * 这两种情况都表现为「图还在」，用户看到的永远是「似乎没有通过」。
   */
  async imageSrc(xpath: string): Promise<string> {
    const script: string = `(function(){try{var n=${CaptchaHostBridge.xpathNode(xpath)};`
      + `if(!n)return 'MISSING';return String(n.src||'');}catch(e){return 'MISSING';}})()`;
    return await this.evalJs(script);
  }

  /**
   * 等验证码图的状态变化：`gone`（节点消失）/ `changed`（换了一张）/ `same`（超时未变）。
   */
  async waitForCaptchaChange(xpath: string, previousSrc: string,
    timeoutMs: number): Promise<string> {
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const now: string = await this.imageSrc(xpath);
      if (now === 'MISSING') {
        return 'gone';
      }
      if (now.length > 0 && now !== previousSrc) {
        return 'changed';
      }
      await CaptchaHostBridge.sleep(500);
    }
    return 'same';
  }

  /**
   * 抓验证码图并**落盘成 PNG**，返回文件绝对路径。
   *
   * 为什么要多这一步：`Image()` 直接渲染 `data:image/png;base64,...` 在本工程
   * 实测是**空白**（截图里只有图片框的浅灰底色，验证码看不见）。
   * 落成文件后用路径渲染是 ArkUI 上最稳的方式，顺带也让「抓到的到底是什么」
   * 可以直接从沙箱里取出来核对。
   */
  async captureImageFile(xpath: string): Promise<string> {
    const dataUrl: string = await this.captureImage(xpath);
    if (dataUrl.length === 0 || this.context === null) {
      return '';
    }
    const marker: string = 'base64,';
    const at: number = dataUrl.indexOf(marker);
    if (at < 0) {
      hilog.warn(DOMAIN, TAG, '抓图结果里没有 base64 标记（长度 %{public}d）',
        dataUrl.length);
      return '';
    }
    try {
      const payload: string = dataUrl.substring(at + marker.length);
      // 只保留 base64 字母表内的字符：真机上这里曾经混进过引号之类的杂字符，
      // `decodeSync` 会直接抛「The input string contains unsupported characters」，
      // 表现为「验证码图永远加载不出来」。丢掉的字符记进日志，方便回溯来源。
      const base64: string = payload.replace(/[^A-Za-z0-9+/=]/g, '');
      if (base64.length !== payload.length) {
        hilog.warn(DOMAIN, TAG,
          'base64 串含 %{public}d 个非字母表字符，已剔除（原长 %{public}d，尾 12 字符=%{public}s）',
          payload.length - base64.length, payload.length,
          payload.length > 12 ? payload.substring(payload.length - 12) : payload);
      }
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(base64);
      if (bytes.length === 0) {
        return '';
      }
      const path: string = `${this.context.cacheDir}/captcha.png`;
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      } finally {
        fileIo.closeSync(file);
      }
      hilog.info(DOMAIN, TAG, '验证码图已落盘 %{public}s（%{public}d 字节）',
        path, bytes.length);
      return path;
    } catch (e) {
      const error = e as Error;
      hilog.warn(DOMAIN, TAG, '验证码图落盘失败：%{public}s', error.message);
      return '';
    }
  }

  /**
   * 填输入框并派发 input/change 事件。
   *
   * **必须走原生 value setter**：直接 `n.value = 值` 会被 React/Vue 这类
   * 受控组件的内部 setter 覆盖回去，页面收到的仍是空串——站点于是重新下发验证码，
   * 用户怎么看都是「验证码过不了」。参照实现
   * （`captcha_webview_ohos_impl.dart` 的 `submitCaptchaInteract`）也是这么做的：
   * `Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(...)`。
   *
   * 填完回读一次 `value` 长度写日志：页面到底收到没收到，日志里必须能看见。
   */
  async fillInput(xpath: string, value: string): Promise<void> {
    await this.waitForElement(xpath, 5000);
    const script: string = `(function(){try{var n=${CaptchaHostBridge.xpathNode(xpath)};`
      + `if(!n)return 'no-node';`
      + `try{n.focus();}catch(e){}`
      + `var desc=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');`
      + `if(desc&&desc.set){desc.set.call(n,${JSON.stringify(value)});}else{n.value=${JSON.stringify(value)};}`
      + `n.dispatchEvent(new Event('input',{bubbles:true}));`
      + `n.dispatchEvent(new Event('change',{bubbles:true}));`
      + `return 'filled='+String(n.value).length;`
      + `}catch(e){return 'err:'+e.message;}})()`;
    hilog.info(DOMAIN, TAG, '填写验证码输入框：%{public}s', await this.evalJs(script));
  }

  /**
   * 点击命中的节点；返回 JS 侧的结果串（`clicked` / `no-node` / `err:…`）。
   *
   * 返回结果而不再是 `void`：**有些站点的验证页根本没有按钮**
   * （实测 LMM 2026-09-19：搜索请求返回的是标题「身份验证」的自动验证页，
   * 逻辑全在站点自己的混淆脚本里，规则配的「立即验证」按钮不存在）。
   * 编排层拿到 `no-node` 才能按「自动验证页」处理，而不是静默当成点过了。
   */
  async click(xpath: string): Promise<string> {
    await this.waitForElement(xpath, 5000);
    const script: string = `(function(){try{var n=${CaptchaHostBridge.xpathNode(xpath)};`
      + `if(!n)return 'no-node';if(n.click)n.click();return 'clicked';`
      + `}catch(e){return 'err:'+e.message;}})()`;
    const result: string = await this.evalJs(script);
    hilog.info(DOMAIN, TAG, '点击验证按钮：%{public}s', result);
    return result;
  }

  async runScript(script: string): Promise<void> {
    await this.evalJs(script);
  }

  /** 收尾：把页面卸掉，避免验证页继续跑脚本。 */
  async unload(): Promise<void> {
    try {
      this.pageLoaded = false;
      this.currentUrl = '';
      this.controller.loadUrl('about:blank');
    } catch (e) {
      // 卸载失败不影响流程
    }
  }

  /**
   * 重新加载当前验证页（「换一张」用）。
   *
   * 站点自己的「换一张」是点那张图（`this.src += '?'`），但应用里那张图是
   * 抓到本地显示的，点它不会碰到站点——所以直接整页刷新：
   * 服务端会重新下发一枚验证码，比只改 img 的 src 更接近「换一张」的语义。
   */
  async reload(): Promise<void> {
    if (!this.attached) {
      return;
    }
    try {
      this.pageLoaded = false;
      hilog.info(DOMAIN, TAG, '刷新验证页（换一张）');
      this.controller.refresh();
    } catch (e) {
      const error = e as Error;
      hilog.warn(DOMAIN, TAG, '刷新验证页失败：%{public}s', error.message);
    }
  }
}
