import { hilog } from '@kit.PerformanceAnalysisKit';
import { Plugin, pluginNameKey } from '../../plugins/Plugin';
import { PluginSearchResponse, PluginSearchStatus } from '../../model/SearchModels';
import { AsyncSession, AsyncSessionOwner } from '../../utils/AsyncSession';
import { PluginManager } from './PluginManager';
import { RuleEngine, RuleSearchTrace } from './RuleEngine';
import { CaptchaRequiredException, NoResultException, SearchErrorException } from './RuleEngineModels';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnSearch';

/**
 * 多插件搜索结果状态。
 *
 * 对应源码里 `InfoController` 上挂着的
 * `pluginSearchResponseList` + `pluginSearchStatus`。
 * 视图通过 `AppStorage` 的版本号订阅（与主题同一套做法）。
 */
export class PluginSearchStore {
  static readonly REVISION_KEY: string = 'pluginSearchRevision';

  /** 各插件的搜索结果（顺序即插件顺序）。 */
  static readonly responses: PluginSearchResponse[] = [];
  /** 各插件的搜索状态，键为 `pluginNameKey(name)`。 */
  static readonly status: Map<string, PluginSearchStatus> =
    new Map<string, PluginSearchStatus>();

  static clear(): void {
    PluginSearchStore.responses.length = 0;
    PluginSearchStore.status.clear();
    PluginSearchStore.bump();
  }

  static removeByPlugin(pluginName: string): void {
    const key: string = pluginNameKey(pluginName);
    for (let i = PluginSearchStore.responses.length - 1; i >= 0; i--) {
      if (pluginNameKey(PluginSearchStore.responses[i].pluginName) === key) {
        PluginSearchStore.responses.splice(i, 1);
      }
    }
  }

  static add(response: PluginSearchResponse): void {
    PluginSearchStore.responses.push(response);
    PluginSearchStore.bump();
  }

  static setStatus(pluginName: string, status: PluginSearchStatus): void {
    PluginSearchStore.status.set(pluginNameKey(pluginName), status);
    PluginSearchStore.bump();
  }

  static statusOf(pluginName: string): PluginSearchStatus | undefined {
    return PluginSearchStore.status.get(pluginNameKey(pluginName));
  }

  static bump(): void {
    const current: number | undefined =
      AppStorage.get<number>(PluginSearchStore.REVISION_KEY);
    AppStorage.setOrCreate(PluginSearchStore.REVISION_KEY,
      (current === undefined ? 0 : current) + 1);
  }
}

/**
 * 插件搜索编排。
 * 对应参照实现 `lib/services/plugin/plugin_search_service.dart`。
 *
 * 关键点：
 *   - **每个插件一个会话**：同一插件重新搜索时，旧的那次写回会被判定为过期而丢弃
 *   - 搜索错误按类型分流成 captcha / noResult / error 三种状态
 *   - `cancel()` 之后所有在途结果都不再写回
 */
export class PluginSearchService {
  private static querySessions: Map<string, AsyncSessionOwner> =
    new Map<string, AsyncSessionOwner>();
  private static cancelled: boolean = false;

  /** 单个插件搜索（对应 `querySource`）。 */
  static async querySource(keyword: string, pluginName: string): Promise<void> {
    const plugin: Plugin | null = PluginManager.find(pluginName);
    if (plugin === null) {
      return;
    }
    PluginSearchStore.removeByPlugin(pluginName);
    PluginSearchStore.setStatus(pluginName, PluginSearchStatus.pending);
    await PluginSearchService.queryPlugin(plugin, keyword);
  }

  /** 全部插件并发搜索（对应 `queryAllSource`）。 */
  static async queryAllSource(keyword: string): Promise<void> {
    PluginSearchService.cancelled = false;
    PluginSearchStore.clear();
    const plugins: Plugin[] = PluginManager.pluginList.slice();
    const tasks: Promise<void>[] = [];
    for (let i = 0; i < plugins.length; i++) {
      PluginSearchStore.setStatus(plugins[i].name, PluginSearchStatus.pending);
      tasks.push(PluginSearchService.queryPlugin(plugins[i], keyword));
    }
    await Promise.all(tasks);
  }

  /**
   * 用验证码 WebView 抓到的 HTML 直接当搜索结果写回（省一次网络往返）。
   * 返回 false 表示不适用，调用方应回退到 `querySource` 重新搜索。
   */
  static applyHarvestedSearchResult(pluginName: string, html: string): boolean {
    if (PluginSearchService.cancelled) {
      return false;
    }
    const plugin: Plugin | null = PluginManager.find(pluginName);
    if (plugin === null) {
      return false;
    }
    const result: PluginSearchResponse | null =
      RuleEngine.tryParseHarvestedSearch(plugin.executionConfig(), html);
    if (result === null) {
      return false;
    }
    PluginSearchStore.removeByPlugin(pluginName);
    PluginSearchStore.setStatus(pluginName, PluginSearchStatus.success);
    PluginSearchStore.add(result);
    return true;
  }

  /** 取消本次全部搜索。 */
  static cancel(): void {
    PluginSearchService.cancelled = true;
    PluginSearchService.querySessions.forEach((owner: AsyncSessionOwner) => {
      owner.cancel();
    });
  }

  private static async queryPlugin(plugin: Plugin, keyword: string): Promise<void> {
    if (PluginSearchService.cancelled) {
      return;
    }
    let owner: AsyncSessionOwner | undefined =
      PluginSearchService.querySessions.get(plugin.name);
    if (owner === undefined) {
      owner = new AsyncSessionOwner();
      PluginSearchService.querySessions.set(plugin.name, owner);
    }
    const session: AsyncSession = owner.begin();
    try {
      const trace: RuleSearchTrace =
        await RuleEngine.search(plugin.executionConfig(), keyword);
      if (PluginSearchService.cancelled || session.isStale) {
        return;
      }
      PluginSearchStore.setStatus(plugin.name, PluginSearchStatus.success);
      PluginSearchStore.add(trace.response);
    } catch (error) {
      if (PluginSearchService.cancelled || session.isStale) {
        return;
      }
      PluginSearchService.handleError(plugin, error as Error);
    }
  }

  /** 错误分流（与源码 `_handleSearchError` 一致）。 */
  private static handleError(plugin: Plugin, error: Error): void {
    if (error instanceof CaptchaRequiredException) {
      hilog.info(DOMAIN, TAG, '%{public}s 需要验证码', error.pluginName);
      PluginSearchStore.setStatus(error.pluginName, PluginSearchStatus.captcha);
      return;
    }
    if (error instanceof NoResultException) {
      hilog.info(DOMAIN, TAG, '%{public}s 无结果', error.pluginName);
      PluginSearchStore.setStatus(error.pluginName, PluginSearchStatus.noResult);
      return;
    }
    const name: string = error instanceof SearchErrorException
      ? (error as SearchErrorException).pluginName : plugin.name;
    hilog.warn(DOMAIN, TAG, '%{public}s 搜索失败: %{public}s', name, error.message);
    PluginSearchStore.setStatus(name, PluginSearchStatus.error);
  }
}
