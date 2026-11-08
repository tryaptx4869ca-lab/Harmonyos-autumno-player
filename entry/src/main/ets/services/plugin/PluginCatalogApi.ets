import { hilog } from '@kit.PerformanceAnalysisKit';
import { PluginHttpItem } from '../../model/PluginHttpItem';
import { Plugin } from '../../plugins/Plugin';
import { ApiEndpoints } from '../../request/config/ApiEndpoints';
import { ApiClient, ApiResponse } from '../../request/core/ApiClient';
import { RulesMirrorInterceptor } from '../../request/core/MirrorInterceptors';
import { SettingsKeys } from '../storage/SettingsKeys';
import { SettingsStore } from '../storage/SettingsStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnPlugin';

/** 目录解析结果。 */
export class PluginCatalogParseResult {
  readonly items: PluginHttpItem[];
  readonly skippedItems: number;

  constructor(items: PluginHttpItem[], skippedItems: number) {
    this.items = items;
    this.skippedItems = skippedItems;
  }
}

/**
 * 规则仓库目录。
 * 对应参照实现 `lib/request/apis/plugin_catalog_api.dart`。
 *
 * 请求走 `ApiClient.rulesRepoDio()`，但仓库候选由本类逐跳尝试：
 * 自定义 Gitee 仓库 → GitCode → gh-proxy → GitHub 直连。
 * 这样任一镜像路由调整或突发 429 时，不会让整个规则仓库一直转圈。
 */
export class PluginCatalogApi {
  /** 拉取目录并解析。 */
  static async getPluginList(): Promise<PluginHttpItem[]> {
    const raw: string = await PluginCatalogApi.getText('index.json');
    const result: PluginCatalogParseResult = PluginCatalogApi.parsePluginList(raw);
    if (result.skippedItems > 0) {
      hilog.warn(DOMAIN, TAG, '规则目录跳过 %{public}d 条无效条目', result.skippedItems);
    }
    return result.items;
  }

  /** 解析目录 JSON（根必须是数组；坏条目跳过，全坏则抛错）。 */
  static parsePluginList(raw: string): PluginCatalogParseResult {
    const parsed: Object = JSON.parse(raw) as Object;
    if (!Array.isArray(parsed)) {
      throw new Error('Rule catalog root must be a JSON array');
    }
    const array: Object[] = parsed as Object[];
    const items: PluginHttpItem[] = [];
    let skipped: number = 0;
    for (let i = 0; i < array.length; i++) {
      const rec: Record<string, Object> | null = PluginCatalogApi.asObject(array[i]);
      if (rec === null) {
        skipped++;
        continue;
      }
      try {
        items.push(PluginHttpItem.fromJson(rec));
      } catch (e) {
        skipped++;
      }
    }
    if (array.length > 0 && items.length === 0) {
      throw new Error('Rule catalog contains no valid items');
    }
    return new PluginCatalogParseResult(items, skipped);
  }

  /** 按名字拉取单条规则。 */
  static async getPlugin(name: string): Promise<Plugin> {
    const raw: string = await PluginCatalogApi.getText(`${name}.json`);
    const parsed: Object = JSON.parse(raw) as Object;
    const rec: Record<string, Object> | null = PluginCatalogApi.asObject(parsed);
    if (rec === null) {
      throw new Error(`Rule ${name} must be a JSON object`);
    }
    return Plugin.fromJson(rec);
  }

  /**
   * 规范化用户填写的 raw 仓库目录。
   *
   * 接受 Gitee「原始数据」地址，如：
   *   https://gitee.com/<user>/<repo>/raw/master/
   * 若误粘贴到 `index.json`，会自动去掉文件名。
   */
  static normalizeRepositoryBase(raw: string): string {
    let base: string = raw.trim();
    if (base.length === 0) {
      return '';
    }
    if (!base.toLowerCase().startsWith('https://')) {
      return '';
    }
    if (base.endsWith('/index.json')) {
      base = base.substring(0, base.length - '/index.json'.length);
    }
    if (!base.endsWith('/')) {
      base += '/';
    }
    return base;
  }

  private static async getText(relativePath: string): Promise<string> {
    const canonical: string = ApiEndpoints.pluginShop + relativePath;
    const enableMirror: boolean = SettingsStore.getBool(SettingsKeys.enableGitProxy);
    const builtIn: string[] =
      RulesMirrorInterceptor.candidates(canonical, enableMirror);
    const custom: string = PluginCatalogApi.normalizeRepositoryBase(
      SettingsStore.getString(SettingsKeys.ruleRepositoryBase));
    const candidates: string[] = [];
    if (custom.length > 0) {
      candidates.push(custom + relativePath);
    }
    for (let i = 0; i < builtIn.length; i++) {
      if (candidates.indexOf(builtIn[i]) < 0) {
        candidates.push(builtIn[i]);
      }
    }

    let lastUrl: string = '';
    let lastDetail: string = '';
    for (let i = 0; i < candidates.length; i++) {
      const url: string = candidates[i];
      const response: ApiResponse = await ApiClient.rulesRepoDio().get(url);
      if (response.ok && response.body.trim().length > 0) {
        if (i > 0) {
          hilog.info(DOMAIN, TAG, '规则仓库切换到备用地址 %{public}s', url);
        }
        return response.body;
      }
      lastUrl = response.requestUrl.length > 0 ? response.requestUrl : url;
      lastDetail = response.statusCode > 0
        ? `HTTP ${response.statusCode}`
        : (response.error === null ? '空响应' : response.error.message);
      hilog.warn(DOMAIN, TAG, '规则仓库候选失败 %{public}s: %{public}s',
        lastUrl, lastDetail);
    }
    throw new Error(`规则仓库不可用：${lastDetail} ${lastUrl}`);
  }

  private static asObject(value: Object | undefined): Record<string, Object> | null {
    if (value === undefined || value === null || typeof value !== 'object' ||
      Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }
}
