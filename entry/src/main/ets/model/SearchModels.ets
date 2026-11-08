import { JsonUtils } from './JsonUtils';

/** 线路。对应 `lib/modules/roads/road_module.dart`。 */
export class Road {
  name: string = '';
  data: string[] = [];
  identifier: string[] = [];
}

/** 单个插件的搜索状态（`plugin_search_module.dart`）。 */
export enum PluginSearchStatus {
  pending = 0,
  success = 1,
  error = 2,
  noResult = 3,
  captcha = 4
}

/** 一条搜索结果。 */
export class SearchItem {
  name: string = '';
  src: string = '';

  static fromJson(json: Record<string, Object>): SearchItem {
    const item = new SearchItem();
    item.name = JsonUtils.str(json, 'name');
    item.src = JsonUtils.str(json, 'src');
    return item;
  }
}

/** 单个插件的整包搜索结果。 */
export class PluginSearchResponse {
  pluginName: string = '';
  data: SearchItem[] = [];

  static fromJson(json: Record<string, Object>): PluginSearchResponse {
    const response = new PluginSearchResponse();
    response.pluginName = JsonUtils.str(json, 'pluginName');
    const list: Object[] = JsonUtils.arr(json, 'data');
    for (let i = 0; i < list.length; i++) {
      const rec: Record<string, Object> | null = JsonUtils.asObj(list[i]);
      if (rec !== null) {
        response.data.push(SearchItem.fromJson(rec));
      }
    }
    return response;
  }
}

/** 搜索历史。key 为时间戳字符串（`search_history_module.dart`）。 */
export class SearchHistory {
  keyword: string = '';
  timestamp: number = 0;

  constructor(keyword: string, timestamp: number) {
    this.keyword = keyword;
    this.timestamp = timestamp;
  }

  get key(): string {
    return `${this.timestamp}`;
  }
}

/** 剧集信息。对应 `lib/modules/bangumi/episode_item.dart`。 */
export class EpisodeInfo {
  id: number = 0;
  /** Dart 里是 `num`，可能带小数（如 1.5 话） */
  episode: number = 0;
  /** 0=ep 1=sp 2=op 3=ed */
  type: number = 0;
  name: string = '';
  nameCn: string = '';

  static fromJson(json: Record<string, Object>): EpisodeInfo {
    const info = new EpisodeInfo();
    info.id = JsonUtils.intOf(json, 'id');
    info.episode = JsonUtils.num(json, 'sort');
    info.type = JsonUtils.intOf(json, 'type');
    info.name = JsonUtils.str(json, 'name');
    info.nameCn = JsonUtils.str(json, 'name_cn');
    return info;
  }

  /** 源码 `readType()`。 */
  readType(): string {
    switch (this.type) {
      case 0:
        return 'ep';
      case 1:
        return 'sp';
      case 2:
        return 'op';
      case 3:
        return 'ed';
      default:
        return '';
    }
  }

  reset(): void {
    this.id = 0;
    this.episode = 0;
    this.type = 0;
    this.name = '';
    this.nameCn = '';
  }
}
