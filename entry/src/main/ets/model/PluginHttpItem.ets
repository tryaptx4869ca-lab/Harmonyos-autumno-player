import { JsonUtils } from './JsonUtils';

/**
 * 规则仓库目录条目。
 * 逐字段移植自 `lib/modules/plugin/plugin_http_module.dart`。
 *
 * 注意：源码里 `name / version / useNativePlayer / author` 是**非空**字段，
 * 缺任意一个都会抛错（进而被目录解析计为「跳过」）。
 * 这里保持同样行为——目录里的坏条目必须被跳过而不是当成空值。
 */
export class PluginHttpItem {
  name: string = '';
  version: string = '';
  useNativePlayer: boolean = true;
  author: string = '';
  lastUpdate: number = 0;
  antiCrawlerEnabled: boolean = false;

  static fromJson(json: Record<string, Object>): PluginHttpItem {
    const item = new PluginHttpItem();
    item.name = PluginHttpItem.requiredString(json, 'name');
    item.version = PluginHttpItem.requiredString(json, 'version');
    item.author = PluginHttpItem.requiredString(json, 'author');
    const useNative: Object | undefined = json['useNativePlayer'];
    if (useNative === undefined || useNative === null) {
      throw new Error('useNativePlayer 缺失');
    }
    item.useNativePlayer = useNative === true || `${useNative}` === 'true';
    item.lastUpdate = JsonUtils.intOf(json, 'lastUpdate');
    // antiCrawlerConfig.enabled 优先，其次顶层 antiCrawlerEnabled
    const rawConfig: Record<string, Object> | null = JsonUtils.obj(json, 'antiCrawlerConfig');
    item.antiCrawlerEnabled = rawConfig !== null
      ? JsonUtils.boolOf(rawConfig, 'enabled')
      : JsonUtils.boolOf(json, 'antiCrawlerEnabled');
    return item;
  }

  /** 写入规则目录离线缓存。字段与仓库 `index.json` 保持一致。 */
  toJson(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['name'] = this.name;
    out['version'] = this.version;
    out['author'] = this.author;
    out['useNativePlayer'] = this.useNativePlayer;
    out['lastUpdate'] = this.lastUpdate;
    out['antiCrawlerEnabled'] = this.antiCrawlerEnabled;
    return out;
  }

  private static requiredString(json: Record<string, Object>, key: string): string {
    const value: Object | undefined = json[key];
    if (value === undefined || value === null) {
      throw new Error(`${key} 缺失`);
    }
    return `${value}`;
  }
}
