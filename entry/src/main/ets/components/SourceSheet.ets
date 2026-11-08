import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { BangumiItem } from '../model/BangumiItem';
import { PluginSearchResponse, PluginSearchStatus, Road, SearchItem }
  from '../model/SearchModels';
import { Plugin } from '../plugins/Plugin';
import { CaptchaType } from '../plugins/AntiCrawlerConfig';
import { PluginManager } from '../services/plugin/PluginManager';
import { PluginSearchService, PluginSearchStore } from '../services/plugin/PluginSearchService';
import { UnavailablePlugins } from '../services/plugin/UnavailablePlugins';
import { RuleChapterTrace, RuleEngine } from '../services/plugin/RuleEngine';
import { CaptchaOutcome, CaptchaVerificationService } from '../services/plugin/CaptchaVerificationService';
import { CaptchaHostBridge } from '../webview/CaptchaWebHost';
import { CaptchaPhase, CaptchaVerifyDialog } from './CaptchaDialog';
import { LoadingIndicator } from './LoadingIndicator';
import { AppColor } from '../theme/AppColors';
import { VideoRouteArgs } from '../router/RouteArgs';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnSource';

/** 一个来源（插件）在弹层里的展示状态。 */
class SourceGroupState {
  name: string = '';
  keyword: string = '';
  status: PluginSearchStatus = PluginSearchStatus.pending;
  /** 是否展开（默认折叠；首个有结果的来源自动展开）。 */
  expanded: boolean = false;
  /** 是否「已展开全部」（否则只显示第一条结果）。 */
  showAll: boolean = false;
  results: SearchItem[] = [];
}

/**
 * 「播放来源」弹层。
 *
 * 对应参照实现 `lib/pages/info/source_sheet.dart` + `source_sheet_view.dart`：
 *   - 头部：标题 + 「N 个来源 · M 个结果」+ 关闭
 *   - 每个来源一行：名称 + 状态（检索中 / N 个结果 / 无结果 / 需要验证 / 检索失败）
 *   - 展开后：结果行（默认预览 1 条，可展开全部）、无结果时的「修改检索词 / 使用别名」
 *   - 点结果 → 拉线路与剧集 → 进播放页
 *
 * 与源码的差异（有意）：
 *   - 别名编辑（`source_alias_dialog`）随收藏/别名服务一起留到阶段五，
 *     这里先提供「修改检索词」；
 *   - 验证走与搜索页同一套 `CaptchaVerificationService`。
 */
@Component
export struct SourceSheet {
  /** 当前番剧（取中文名优先作为检索词）。 */
  item: BangumiItem = new BangumiItem();
  /**
   * 续播偏好（§9.2 的「继续观看 第N集」）：详情页从历史里取出来带进来。
   * 0 表示从头看。
   */
  preferredEpisode: number = 0;
  preferredRoad: number = 0;
  /** 拿到线路后交给页面压栈。 */
  onPlay: (args: VideoRouteArgs) => void = () => {
  };
  onClose: () => void = () => {
  };
  /**
   * 大屏（平板 / 横屏）自绘弹层：面板宽到 `min(屏宽 × 0.72, 640)`，字号、
   * 行高、图标都跟着放大一档（用户 2026-10-07：「播放来源的卡片的比例也
   * 适配一下平板」）。手机仍是 1.0，逐字不变。
   */
  wide: boolean = false;

  /** 大屏放大系数（手机 = 1）。 */
  private ws(base: number): number {
    return this.wide ? Math.round(base * 1.25) : base;
  }

  /** 订阅插件搜索版本号：任何一个插件写回结果都会让本组件重跑 build。 */
  @StorageProp('pluginSearchRevision') @Watch('onSearchRevisionChanged')
  searchRevision: number = 0;

  @State private groups: SourceGroupState[] = [];
  @State private keyword: string = '';
  /** 正在拉线路时的提示（空串表示空闲）。 */
  @State private busyHint: string = '';
  /** 检索词输入框（改检索词用）。 */
  @State private editingPlugin: string = '';
  @State private editingText: string = '';
  @State private showKeywordEditor: boolean = false;
  // ---- 验证（与搜索页同一套服务） ----
  @State private showCaptcha: boolean = false;
  /**
   * 验证页地址。**必须在 `showCaptcha = true` 之前写好**：
   * `Web` 的 `src` 只在创建时生效，之后再 `loadUrl` 会被组件重绘重新下发的
   * `src` 顶掉（阶段四实测，验证页就是被这个坑住的）。
   */
  @State private captchaUrl: string = '';
  /** 验证码图落盘后的路径（解码成 PixelMap 用）。 */
  private captchaImagePath: string = '';
  /**
   * 验证码图的 PixelMap。
   *
   * 为什么绕这一圈：`Image()` 传 `data:image/png;base64,…` 与传沙箱绝对路径
   * 在本工程上实测都渲染成空白；PixelMap 由我们自己解码，绕开路径解析与
   * dataURI 支持的问题。
   */
  @State private captchaPixel: image.PixelMap | undefined = undefined;
  @State private captchaCode: string = '';
  /** 对话框阶段（`CaptchaPhase`：loading / image / verifying / auto / passed）。 */
  @State private captchaPhase: string = CaptchaPhase.loading;
  /** 对话框里的错误文案（图片加载失败 / 验证码不正确 / 未能提交）。 */
  @State private captchaError: string = '';
  private captchaImageXpath: string = '';
  private captchaInputXpath: string = '';
  private captchaButtonXpath: string = '';
  @State private captchaPlugin: string = '';
  private captchaBridge: CaptchaHostBridge = new CaptchaHostBridge();
  private captchaService: CaptchaVerificationService = new CaptchaVerificationService();
  /**
   * 用户手动展开 / 折叠过的来源名。
   *
   * 展开态不再用「只自动展开一次」的布尔量：搜索是**并发**的，
   * 哪个来源先写回结果是随机的，用一次性标志会在「第一个有结果的来源
   * 恰好是最后返回的那个」时漏掉展开（实测出现过：状态写着 1 个结果，
   * 行却是折的）。改成每次重算都与当前结果集对齐。
   */
  private manualExpanded: string[] = [];
  private manualCollapsed: string[] = [];

  aboutToAppear(): void {
    const name: string = this.item.nameCn.length > 0 ? this.item.nameCn : this.item.name;
    this.keyword = name;
    this.rebuildGroups();
    if (PluginManager.pluginList.length > 0) {
      PluginSearchService.queryAllSource(name);
    }
  }

  aboutToDisappear(): void {
    PluginSearchService.cancel();
    this.captchaService.dispose();
  }

  private onSearchRevisionChanged(): void {
    this.rebuildGroups();
  }

  /**
   * 把「插件顺序 + 搜索状态 + 结果」拼成可渲染的行。
   *
   * 关键点（与源码注释一致）：结果按**完成顺序**写回，
   * 展示顺序必须按**规则表配置顺序**，因此这里以 `PluginManager.pluginList`
   * 为骨架，再把已写回的结果填进去；同一来源内按 `src` 去重。
   */
  private rebuildGroups(): void {
    const plugins: Plugin[] = PluginManager.pluginList;
    const next: SourceGroupState[] = [];
    let firstWithResults: string = '';
    for (let i = 0; i < plugins.length; i++) {
      const plugin: Plugin = plugins[i];
      // 已失效的规则不出现在来源列表里（名单见 `UnavailablePlugins`）
      if (UnavailablePlugins.isUnavailable(plugin.name)) {
        continue;
      }
      const group = new SourceGroupState();
      group.name = plugin.name;
      const previous: SourceGroupState | undefined = this.findGroup(this.groups, plugin.name);
      group.keyword = previous === undefined ? this.keyword : previous.keyword;
      group.expanded = false;
      group.showAll = previous === undefined ? false : previous.showAll;
      const status: PluginSearchStatus | undefined = PluginSearchStore.statusOf(plugin.name);
      group.status = status === undefined ? PluginSearchStatus.pending : status;

      const seen: Set<string> = new Set<string>();
      const responses: PluginSearchResponse[] = PluginSearchStore.responses;
      for (let r = 0; r < responses.length; r++) {
        if (responses[r].pluginName !== plugin.name) {
          continue;
        }
        const data: SearchItem[] = responses[r].data;
        for (let d = 0; d < data.length; d++) {
          if (!seen.has(data[d].src)) {
            seen.add(data[d].src);
            group.results.push(data[d]);
          }
        }
      }
      if (firstWithResults.length === 0 && group.results.length > 0) {
        firstWithResults = group.name;
      }
      next.push(group);
    }

    // 展开态：手动操作优先，其余情况「首个有结果的来源」默认展开。
    for (let i = 0; i < next.length; i++) {
      const name: string = next[i].name;
      if (this.manualExpanded.indexOf(name) >= 0) {
        next[i].expanded = true;
      } else if (this.manualCollapsed.indexOf(name) >= 0) {
        next[i].expanded = false;
      } else {
        next[i].expanded = name === firstWithResults;
      }
    }
    this.groups = next;
  }

  private orderedSourceNames(): string[] {
    const names: string[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      names.push(this.groups[i].name);
    }
    return names;
  }

  private groupByName(name: string): SourceGroupState {
    const group: SourceGroupState | undefined = this.findGroup(this.groups, name);
    return group === undefined ? new SourceGroupState() : group;
  }

  private sourceKey(name: string): string {
    const group: SourceGroupState = this.groupByName(name);
    return `src-${group.name}-${group.status}-${group.results.length}-` +
      `${group.expanded}-${group.showAll}`;
  }

  @Builder
  sourceListItem(name: string) {
    this.groupRow(this.groupByName(name))
  }

  private findGroup(list: SourceGroupState[], name: string): SourceGroupState | undefined {
    for (let i = 0; i < list.length; i++) {
      if (list[i].name === name) {
        return list[i];
      }
    }
    return undefined;
  }

  private totalResults(): number {
    let total: number = 0;
    for (let i = 0; i < this.groups.length; i++) {
      total += this.groups[i].results.length;
    }
    return total;
  }

  private pendingCount(): number {
    let pending: number = 0;
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].status === PluginSearchStatus.pending) {
        pending++;
      }
    }
    return pending;
  }

  private statusLabel(group: SourceGroupState): string {
    if (group.status === PluginSearchStatus.pending) {
      return '检索中…';
    }
    if (group.status === PluginSearchStatus.success) {
      return group.results.length === 0 ? '无结果' : `${group.results.length} 个结果`;
    }
    if (group.status === PluginSearchStatus.noResult) {
      return '无结果';
    }
    if (group.status === PluginSearchStatus.captcha) {
      return '需要验证';
    }
    return '检索失败';
  }

  private toggle(group: SourceGroupState): void {
    const expanded: boolean = !group.expanded;
    hilog.info(DOMAIN, TAG, '切换来源分组 %{public}s → %{public}s',
      group.name, expanded ? '展开' : '折叠');
    this.manualExpanded = this.manualExpanded.filter((name: string) => name !== group.name);
    this.manualCollapsed = this.manualCollapsed.filter((name: string) => name !== group.name);
    if (expanded) {
      this.manualExpanded.push(group.name);
    } else {
      this.manualCollapsed.push(group.name);
    }
    this.groups = this.replaceGroup(group.name, expanded, false);
  }

  /**
   * 用**新对象**替换某个来源的状态。
   *
   * 为什么不能原地改 + `slice()`：ArkUI 的 `ForEach` 按**对象身份**复用 item，
   * 同一个对象即使字段变了也不会重建（实测：日志已经打出「切换来源分组
   * aafun → 折叠」，界面上的结果行纹丝不动）。换成新对象才会走重建。
   */
  private replaceGroup(name: string, expanded: boolean,
    showAll: boolean): SourceGroupState[] {
    const next: SourceGroupState[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      const current: SourceGroupState = this.groups[i];
      if (current.name !== name) {
        next.push(current);
        continue;
      }
      const copy = new SourceGroupState();
      copy.name = current.name;
      copy.keyword = current.keyword;
      copy.status = current.status;
      copy.results = current.results;
      copy.expanded = expanded;
      copy.showAll = showAll;
      next.push(copy);
    }
    return next;
  }

  private retry(pluginName: string): void {
    const group: SourceGroupState | undefined = this.findGroup(this.groups, pluginName);
    const keyword: string = group === undefined || group.keyword.length === 0
      ? this.keyword : group.keyword;
    PluginSearchService.querySource(keyword, pluginName);
  }

  private submitKeyword(): void {
    const name: string = this.editingPlugin;
    const keyword: string = this.editingText.trim();
    if (name.length === 0 || keyword.length === 0) {
      return;
    }
    const group: SourceGroupState | undefined = this.findGroup(this.groups, name);
    if (group !== undefined) {
      const next: SourceGroupState[] = [];
      for (let i = 0; i < this.groups.length; i++) {
        const current: SourceGroupState = this.groups[i];
        if (current.name !== name) {
          next.push(current);
          continue;
        }
        const copy = new SourceGroupState();
        copy.name = current.name;
        copy.keyword = keyword;
        copy.status = current.status;
        copy.results = current.results;
        copy.expanded = true;
        copy.showAll = false;
        next.push(copy);
      }
      this.groups = next;
      this.manualExpanded = this.manualExpanded.filter((value: string) => value !== name);
      this.manualExpanded.push(name);
    }
    this.editingPlugin = '';
    this.editingText = '';
    this.showKeywordEditor = false;
    PluginSearchService.querySource(keyword, name);
  }

  /** 点结果：拉线路与剧集，成功后交给页面压栈。 */
  private async play(pluginName: string, result: SearchItem): Promise<void> {
    if (this.busyHint.length > 0) {
      return;
    }
    const plugin: Plugin | null = PluginManager.find(pluginName);
    if (plugin === null) {
      this.toast('规则不存在，请先在规则管理里安装');
      return;
    }
    this.busyHint = '正在获取播放列表…';
    try {
      const trace: RuleChapterTrace =
        await RuleEngine.queryChapters(plugin.executionConfig(), result.src);
      const roads: Road[] = trace.roads;
      if (roads.length === 0) {
        this.busyHint = '';
        this.toast('未能获取播放列表，请重试或选择其他结果');
        return;
      }
      hilog.info(DOMAIN, TAG, '取到 %{public}d 条线路（%{public}s）', roads.length, result.name);
      const args = new VideoRouteArgs();
      args.bangumiItem = this.item;
      args.plugin = plugin;
      args.title = result.name;
      args.src = result.src;
      args.roads = roads;
      // 续播偏好透传给播放页：详情页点「继续观看 第N集」时，
      // 从选源开始就带着这一集，避免进播放页后又跳一次。
      args.preferredEpisode = this.preferredEpisode;
      args.preferredRoad = this.preferredRoad;
      this.busyHint = '';
      this.onPlay(args);
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '获取播放列表失败: %{public}s', err.message);
      this.busyHint = '';
      this.toast('未能获取播放列表，请重试或选择其他结果');
    }
  }

  /**
   * 去验证。
   *
   * 与搜索页同一套流程（`SearchPage.startCaptcha` → `CaptchaVerificationService`）：
   *   - 打开的是**搜索 URL**（验证码是在搜索请求上触发的，首页通常没有验证入口）；
   *   - 按规则里配的反爬类型分派：1 图片验证码 / 2 自动点击 / 3 自定义脚本；
   *   - 图片验证码：抓图 → 落盘 → 解码成 PixelMap → 交给 `CaptchaVerifyDialog`。
   */
  private async startCaptcha(pluginName: string): Promise<void> {
    const plugin: Plugin | null = PluginManager.find(pluginName);
    if (plugin === null) {
      return;
    }
    this.captchaPlugin = pluginName;
    const target: string = CaptchaVerificationService.pageUrlFor(plugin, this.keyword);
    this.captchaUrl = target;
    this.showCaptcha = true;
    // 对话框三态复位（对应参照实现 `_CaptchaDialogState.initState`）
    this.captchaPhase = CaptchaPhase.loading;
    this.captchaError = '';
    this.captchaCode = '';
    this.captchaPixel = undefined;
    this.captchaImagePath = '';
    try {
      this.captchaService.attachHost(this.captchaBridge);
      this.captchaBridge.attachContext(getContext(this) as common.UIAbilityContext);
      await this.runCaptchaFlow(pluginName, plugin, target);
      // 验证页自己的脚本跑成什么样（有没有报错、按钮有没有绑处理器），
      // 决定了后面「提交验证码」是否真的会发请求——先把现场记下来。
      hilog.info(DOMAIN, TAG, '验证页探针（加载后）：%{public}s',
        await this.captchaBridge.readDiagnostics());
    } catch (error) {
      const err = error as Error;
      this.captchaError = `验证码加载失败：${err.message}`;
      this.captchaPhase = CaptchaPhase.image;
      hilog.warn(DOMAIN, TAG, '验证页加载失败：%{public}s', err.message);
    }
  }

  /**
   * 按规则里配置的反爬类型分派（对应源码 `CaptchaType`）：
   *   1 图片验证码 → 加载页面并抓一次验证码图
   *   2 自动点击   → 用规则里的「验证按钮 XPath」自动点
   *   3 自定义脚本 → 跑规则里的验证脚本
   * XPath 为空时才回落到通用选择器。
   */
  private async runCaptchaFlow(pluginName: string, plugin: Plugin,
    target: string): Promise<void> {
    const anti = plugin.antiCrawlerConfig;
    const fallbackButton: string = "//button|//input[@type='submit']";
    if (!anti.enabled) {
      // 规则没开反爬：保持「加载页面让用户手动过」的兜底行为
      await this.captchaService.loadForButtonClick(pluginName, target, fallbackButton);
      this.captchaPhase = CaptchaPhase.auto;
      return;
    }
    if (anti.captchaType === CaptchaType.imageCaptcha) {
      // 规则没配验证码图 XPath 时不瞎抓（`//img` 很可能抓到海报）
      if (anti.captchaImage.length === 0) {
        await this.captchaService.loadForButtonClick(pluginName, target,
          anti.captchaButton.length > 0 ? anti.captchaButton : fallbackButton);
        this.captchaPhase = CaptchaPhase.auto;
        return;
      }
      this.captchaImageXpath = anti.captchaImage;
      this.captchaInputXpath = anti.captchaInput;
      this.captchaButtonXpath = anti.captchaButton;
      const captured: string = await this.captchaService.loadForCaptcha(pluginName,
        target, anti.captchaImage);
      if (captured.length === 0) {
        // 页面里没有验证码元素 → 这个 WebView 会话其实已经验证过，
        // 直接把 Cookie + UA 收下去重搜，而不是报「图片无法显示」。
        const src: string = await this.captchaBridge.imageSrc(anti.captchaImage);
        if (src === 'MISSING') {
          hilog.info(DOMAIN, TAG,
            '%{public}s 页面里没有验证码，按「已通过验证」收尾并重试', pluginName);
          await this.finishCaptcha();
          return;
        }
      }
      await this.refreshCaptchaImage(anti.captchaImage);
      return;
    }
    if (anti.captchaType === CaptchaType.autoClickButton) {
      await this.captchaService.loadForButtonClick(pluginName, target,
        anti.captchaButton.length > 0 ? anti.captchaButton : fallbackButton);
      this.captchaPhase = CaptchaPhase.auto;
      return;
    }
    await this.captchaService.loadForCustomScript(pluginName, target,
      anti.captchaScript);
    this.captchaPhase = CaptchaPhase.auto;
  }

  /**
   * 把当前页面的验证码图抓下来、落盘、解码成 `PixelMap`
   * （对应参照实现 `_CaptchaDialogState._receiveImage`）。
   *
   * 15 秒拿不到 → 「暂时没有获取到验证码」（原版同一个计时器）；
   * 解码失败 → 「验证码图片无法显示」——两者都带「重新加载」。
   */
  private async refreshCaptchaImage(xpath: string): Promise<void> {
    this.captchaPhase = CaptchaPhase.loading;
    this.captchaError = '';
    const startedAt: number = Date.now();
    this.captchaImagePath = await this.captchaBridge.captureImageFile(xpath);
    this.captchaPixel = await this.decodeCaptcha(this.captchaImagePath);
    this.captchaPhase = CaptchaPhase.image;
    if (this.captchaPixel !== undefined) {
      hilog.info(DOMAIN, TAG, '验证码图已就绪（%{public}d ms）', Date.now() - startedAt);
      return;
    }
    this.captchaError = Date.now() - startedAt >= 15000
      ? '暂时没有获取到验证码' : '验证码图片无法显示';
    hilog.warn(DOMAIN, TAG, '验证码图不可用：%{public}s', this.captchaError);
  }

  /** 「换一张」：刷新验证页拿一张新图（对应原版 `onReload` → `loadForCaptcha`）。 */
  private async reloadCaptcha(): Promise<void> {
    if (this.captchaImageXpath.length === 0) {
      return;
    }
    this.captchaCode = '';
    await this.captchaBridge.reload();
    await this.captchaBridge.waitForPageLoad(15000);
    await this.refreshCaptchaImage(this.captchaImageXpath);
  }

  /** 收尾：Cookie + UA 落库 → 只重搜这个来源（与搜索页同一套）。 */
  private async finishCaptcha(): Promise<void> {
    const pluginName: string = this.captchaPlugin;
    if (pluginName.length === 0) {
      return;
    }
    let outcome: CaptchaOutcome | null = null;
    try {
      outcome = await this.captchaService.finish(pluginName);
    } catch (error) {
      const err = error as Error;
      this.captchaError = `验证未完成：${err.message}`;
      return;
    }
    this.showCaptcha = false;
    // 弹层一关 `Web` 就被销毁：把宿主的「已关联」状态复位，否则下一次验证
    // 会误判成已关联并直接调 `loadUrl`（见 `markDetached` 的注释）。
    this.captchaBridge.markDetached();
    this.captchaService.dispose();
    if (outcome === null) {
      this.toast('收尾未成功（可能已收过）');
      return;
    }
    hilog.info(DOMAIN, TAG, '验证结果已保存（页面 %{public}d 字节）', outcome.html.length);
    this.retry(pluginName);
    this.toast(`已对 ${pluginName} 完成验证并重试`);
  }

  private cancelCaptcha(): void {
    if (this.captchaPlugin.length > 0) {
      this.captchaService.cancelAndSave(this.captchaPlugin);
      this.captchaService.dispose();
    }
    this.showCaptcha = false;
    this.captchaBridge.markDetached();
  }

  /**
   * 提交用户输入的验证码（对应源码类型 1 的 `submitCaptchaInteract`）：
   * 往输入框填值 → 点提交按钮 → 等页面反应。
   *
   * 判定用「图的变化」而不是「还能不能抓到图」：
   *   gone（图消失，站点整页重载）→ 通过；changed（换了一张）→ 码不对；
   *   same（12 秒没动）→ 这次没提交成功。
   */
  private async submitCaptchaCode(code: string): Promise<void> {
    if (code.length === 0) {
      return;
    }
    this.captchaPhase = CaptchaPhase.verifying;
    this.captchaError = '';
    const before: string = await this.captchaBridge.imageSrc(this.captchaImageXpath);
    await this.captchaService.submitCaptcha(this.captchaInputXpath,
      this.captchaButtonXpath, code);
    // 提交之后马上读一次探针：请求有没有真的发出去、应答是什么，全在这一行里
    hilog.info(DOMAIN, TAG, '验证页探针（提交后）：%{public}s',
      await this.captchaBridge.readDiagnostics());
    const result: string = await this.captchaBridge.waitForCaptchaChange(
      this.captchaImageXpath, before, 12000);
    if (result === 'gone') {
      // 通过态由对话框展示（主色圆 + 勾），3 秒后自动收尾并继续检索
      this.captchaPhase = CaptchaPhase.passed;
      hilog.info(DOMAIN, TAG, '验证码图已消失，判定验证通过');
      setTimeout(() => {
        this.finishCaptcha();
      }, 3000);
      return;
    }
    if (result === 'changed') {
      this.captchaCode = '';
      await this.refreshCaptchaImage(this.captchaImageXpath);
      this.captchaError = '验证码不正确，请重试';
      hilog.info(DOMAIN, TAG, '验证码被服务端重新下发（码不对），已刷新验证码图');
      return;
    }
    this.captchaPhase = CaptchaPhase.image;
    this.captchaError = '未能提交，请重试';
    hilog.warn(DOMAIN, TAG, '提交验证码后 12 秒内页面无变化');
  }

  /** 把落盘的验证码 PNG 解码成 PixelMap（失败返回 undefined，界面显示错误文案）。 */
  private async decodeCaptcha(path: string): Promise<image.PixelMap | undefined> {
    if (path.length === 0) {
      return undefined;
    }
    try {
      const source: image.ImageSource = image.createImageSource(`file://${path}`);
      const pixel: image.PixelMap = await source.createPixelMap();
      source.release();
      return pixel;
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '验证码图解码失败：%{public}s', err.message);
      return undefined;
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 提示失败不影响主流程
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        this.header()
        List({ space: this.ws(4) }) {
          if (this.orderedSourceNames().length === 0) {
            ListItem() {
              Column() {
                Text('暂无其他已安装的番剧站点规则')
                  .fontSize(this.ws(13))
                  .fontColor(AppColor.onSurfaceVariant)
              }
              .width('100%')
              .height(this.ws(110))
              .justifyContent(FlexAlign.Center)
            }
          } else {
            ForEach(this.orderedSourceNames(), (name: string) => {
              ListItem() {
                this.sourceListItem(name)
              }
              // key 里带上展开态 / 展开全部：ArkUI 只重建 key 变化的 item，
              // 而 `@Builder` 的参数是**按值**传入的（本项目阶段三踩过的坑），
              // 不带这两项就会出现「点了箭头、箭头不动」。
            }, (name: string) => this.sourceKey(name))
          }
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        if (this.busyHint.length > 0) {
          Row({ space: this.ws(8) }) {
            LoadingIndicator({ sizeVp: this.ws(18) })
            Text(this.busyHint).fontSize(this.ws(13)).fontColor(AppColor.onSurfaceVariant)
          }
          .width('100%')
          .padding({
            left: this.ws(24),
            right: this.ws(24),
            top: this.ws(8),
            bottom: this.ws(16)
          })
        }
      }
      .width('100%')
      .height('100%')

      // ---- 反爬验证对话框（与搜索页同一套；模态覆盖在弹层之上） ----
      if (this.showCaptcha) {
        this.captchaOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showKeywordEditor, this.keywordEditor(), {
      height: 220,
      dragBar: false,
      // 与「播放来源」主弹层一致：不设底色，交给系统画（用户要求跟系统一致）
      onDisappear: () => {
        this.editingPlugin = '';
        this.showKeywordEditor = false;
      }
    })
  }

  /** 修改单个来源的检索词（对应 `_showCustomKeywordDialog`）。 */
  @Builder
  keywordEditor() {
    Column({ space: 12 }) {
      Text(`修改「${this.editingPlugin}」的检索词`)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.onSurface)
        .width('100%')
      TextInput({ text: this.editingText, placeholder: '检索关键词' })
        .fontSize(15)
        .onChange((value: string) => {
          this.editingText = value;
        })
        .onSubmit(() => {
          this.submitKeyword();
        })
      Row({ space: 12 }) {
        Button('取消')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .fontColor(AppColor.onSurfaceVariant)
          .onClick(() => {
            this.editingPlugin = '';
            this.showKeywordEditor = false;
          })
        Button('检索')
          .fontSize(14)
          .layoutWeight(1)
          .onClick(() => {
            this.submitKeyword();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 20, bottom: 20 })
  }

  @Builder
  header() {
    Column({ space: 2 }) {
      Row() {
        Text('播放来源')
          .fontSize(this.ws(18))
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.onSurface)
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(this.ws(18))
          .fontColor([AppColor.onSurfaceVariant])
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')

      Text(this.pendingCount() > 0
        ? `检索中 ${this.groups.length - this.pendingCount()}/${this.groups.length} 个规则 · ${this.totalResults()} 个结果`
        : `${this.groups.length} 个来源 · ${this.totalResults()} 个结果`)
        .fontSize(this.ws(12))
        .fontColor(AppColor.onSurfaceVariant)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: this.ws(24),
      right: this.ws(24),
      top: this.ws(16),
      bottom: this.ws(12)
    })
  }

  @Builder
  emptyHint(text: string) {
    Column() {
      Text(text)
        .fontSize(14)
        .fontColor(AppColor.onSurfaceVariant)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  captchaOverlay() {
    Column() {
      CaptchaVerifyDialog({
        pluginName: this.captchaPlugin,
        phase: this.captchaPhase,
        errorText: this.captchaError,
        code: this.captchaCode,
        pixel: this.captchaPixel,
        onSubmit: (value: string) => {
          this.submitCaptchaCode(value);
        },
        onReload: () => {
          this.reloadCaptcha();
        },
        onCancel: () => {
          this.cancelCaptcha();
        }
      })
      // 无头宿主：**必须常挂**（与搜索页同一处注释同一原因）。参照实现用的是
      // 1×1 的 headless WebView；这里同样收成 1×1（对齐 `VideoSourceWebHost`）。
      Stack() {
        Web({ src: this.captchaUrl, controller: this.captchaBridge.controller })
          .width(1)
          .height(1)
          .domStorageAccess(true)
          .runJavaScriptOnDocumentStart([
            { script: CaptchaHostBridge.startupProbeScript(), scriptRules: ['*'] }
          ])
          .onControllerAttached(() => {
            this.captchaBridge.markAttached();
          })
          .onPageEnd(() => {
            this.captchaBridge.markPageEnded();
          })
      }
      .width(1)
      .height(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  @Builder
  groupRow(group: SourceGroupState) {
    Column() {
      Row() {
        Text(group.name)
          .fontSize(this.ws(14))
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.onSurfaceVariant)
          .layoutWeight(1)
        Text(this.statusLabel(group))
          .fontSize(this.ws(12))
          .fontColor(AppColor.onSurfaceVariant)
        SymbolGlyph($r(group.expanded ? 'sys.symbol.chevron_up' : 'sys.symbol.chevron_down'))
          .fontSize(this.ws(16))
          .fontColor([AppColor.onSurfaceVariant])
          .margin({ left: this.ws(8) })
      }
      .width('100%')
      .height(this.ws(48))
      .padding({ left: this.ws(12), right: this.ws(4) })
      .onClick(() => {
        this.toggle(group);
      })

      if (group.expanded && group.keyword !== this.keyword) {
        Text(`检索词：${group.keyword}`)
          .fontSize(this.ws(12))
          .fontColor(AppColor.onSurfaceVariant)
          .width('100%')
          .padding({ left: this.ws(12), bottom: this.ws(8) })
      }

      if (group.expanded) {
        this.groupBody(group)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: this.ws(12) })
    // 来源分组卡：用系统组件底色，和系统弹窗同一套色（原来是 M3 的中性色）
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(this.ws(16))
    .padding({ bottom: group.expanded ? this.ws(4) : 0 })
  }

  @Builder
  groupBody(group: SourceGroupState) {
    if (group.status === PluginSearchStatus.pending) {
      Row({ space: this.ws(12) }) {
        LoadingIndicator({ sizeVp: this.ws(18) })
        Text('正在检索…').fontSize(this.ws(13)).fontColor(AppColor.onSurface)
      }
      .width('100%')
      .height(this.ws(56))
      .padding({ left: this.ws(16), right: this.ws(16) })
    } else if (group.results.length === 0) {
      this.issueBlock(group)
    } else {
      Column() {
        ForEach(this.visibleResults(group), (result: SearchItem) => {
          Row() {
            Text(result.name)
              .fontSize(this.ws(15))
              .fontColor(AppColor.onSurface)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.play_circle_fill'))
              .fontSize(this.ws(20))
              .fontColor([AppColor.primary])
              .margin({ left: this.ws(12) })
          }
          .width('100%')
          .constraintSize({ minHeight: this.ws(56) })
          .padding({
            left: this.ws(16),
            right: this.ws(16),
            top: this.ws(10),
            bottom: this.ws(10)
          })
          .onClick(() => {
            this.play(group.name, result);
          })
        }, (result: SearchItem) => `res-${group.name}-${result.src}`)

        if (group.results.length > 1) {
          Row({ space: this.ws(8) }) {
            Text(group.showAll ? '收起全部条目' : `展开全部 ${group.results.length} 个结果`)
              .fontSize(this.ws(13))
              .fontColor(AppColor.primary)
            SymbolGlyph($r(group.showAll
              ? 'sys.symbol.arrow_down_to_line' : 'sys.symbol.chevron_down'))
              .fontSize(this.ws(16))
              .fontColor([AppColor.primary])
          }
          .width('100%')
          .height(this.ws(44))
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            // 同 `toggle`：必须换新对象，否则 ForEach 不会重建这一行。
            this.groups = this.replaceGroup(group.name, true, !group.showAll);
          })
        }
      }
      .width('100%')
    }
  }

  private visibleResults(group: SourceGroupState): SearchItem[] {
    if (group.showAll || group.results.length <= 1) {
      return group.results;
    }
    return group.results.slice(0, 1);
  }

  /** 无结果 / 需要验证 / 检索失败三态的说明块。 */
  @Builder
  issueBlock(group: SourceGroupState) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r(group.status === PluginSearchStatus.captcha
          ? 'sys.symbol.checkmark_circle_fill' : 'sys.symbol.arrow_2_circlepath'))
          .fontSize(18)
          .fontColor([group.status === PluginSearchStatus.captcha
            ? AppColor.onSurfaceVariant : AppColor.error])
        Text(group.status === PluginSearchStatus.captcha ? '需要验证'
          : (group.status === PluginSearchStatus.error ? '检索失败' : '没有找到匹配结果'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.onSurface)
          .layoutWeight(1)
      }
      .width('100%')

      Text(group.status === PluginSearchStatus.captcha
        ? '完成网站验证后继续检索。'
        : (group.status === PluginSearchStatus.error
          ? '可以重试，或修改检索词后再试。' : '换个检索词试试。'))
        .fontSize(12)
        .fontColor(AppColor.onSurfaceVariant)
        .width('100%')

      Row({ space: 8 }) {
        Button(group.status === PluginSearchStatus.captcha ? '进行验证'
          : (group.status === PluginSearchStatus.error ? '重试' : '修改检索词'))
          .fontSize(13)
          .height(34)
          .onClick(() => {
            if (group.status === PluginSearchStatus.captcha) {
              this.startCaptcha(group.name);
            } else if (group.status === PluginSearchStatus.error) {
              this.retry(group.name);
            } else {
              this.editingPlugin = group.name;
              this.editingText = group.keyword.length > 0 ? group.keyword : this.keyword;
              this.showKeywordEditor = true;
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
  }
}
