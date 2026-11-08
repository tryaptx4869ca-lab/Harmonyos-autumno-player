import { JsonUtils } from '../model/JsonUtils';

/** 规则模式。 */
export class RuleMode {
  static readonly xpath: string = 'xpath';
  static readonly api: string = 'api';

  /** 取值兜底：非 `api` 一律回落 `xpath`。 */
  static normalize(value: Object | undefined): string {
    return value !== undefined && value !== null && `${value}` === RuleMode.api
      ? RuleMode.api : RuleMode.xpath;
  }
}

/** 请求体类型。 */
export class ApiBodyType {
  static readonly none: string = 'none';
  static readonly json: string = 'json';
  static readonly form: string = 'form';

  static normalize(value: Object | undefined): string {
    const text: string = value === undefined || value === null ? '' : `${value}`;
    if (text === ApiBodyType.json) {
      return ApiBodyType.json;
    }
    if (text === ApiBodyType.form) {
      return ApiBodyType.form;
    }
    return ApiBodyType.none;
  }
}

/** 章节响应格式。 */
export class ApiChapterFormat {
  static readonly nested: string = 'nested';
  static readonly delimited: string = 'delimited';

  static normalize(value: Object | undefined): string {
    const text: string = value === undefined || value === null ? '' : `${value}`;
    return text === ApiChapterFormat.delimited
      ? ApiChapterFormat.delimited : ApiChapterFormat.nested;
  }
}

/** 把任意 JSON 对象读成「字符串 → 值」的表（对应源码 `_asStringMap`）。 */
export function asStringMap(value: Object | undefined): Record<string, Object> {
  const out: Record<string, Object> = {};
  if (value === undefined || value === null) {
    return out;
  }
  const rec: Record<string, Object> | null = JsonUtils.asObj(value);
  if (rec === null) {
    return out;
  }
  const keys: string[] = Object.keys(rec);
  for (let i = 0; i < keys.length; i++) {
    out[keys[i]] = rec[keys[i]];
  }
  return out;
}

/** API 请求配置。 */
export class ApiRequestConfig {
  method: string = 'GET';
  url: string = '';
  headers: Record<string, Object> = {};
  query: Record<string, Object> = {};
  bodyType: string = ApiBodyType.none;
  body: Object | undefined = undefined;

  static fromJson(json: Record<string, Object>): ApiRequestConfig {
    const config = new ApiRequestConfig();
    config.method = JsonUtils.str(json, 'method', 'GET').toUpperCase();
    config.url = JsonUtils.str(json, 'url');
    config.headers = asStringMap(json['headers']);
    config.query = asStringMap(json['query']);
    config.bodyType = ApiBodyType.normalize(json['bodyType']);
    config.body = json['body'];
    return config;
  }

  toJson(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['method'] = this.method.toUpperCase();
    out['url'] = this.url;
    if (Object.keys(this.headers).length > 0) {
      out['headers'] = this.headers;
    }
    if (Object.keys(this.query).length > 0) {
      out['query'] = this.query;
    }
    if (this.bodyType !== ApiBodyType.none) {
      out['bodyType'] = this.bodyType;
      if (this.body !== undefined && this.body !== null) {
        out['body'] = this.body;
      }
    }
    return out;
  }
}

/** API 搜索配置。 */
export class ApiSearchConfig {
  request: ApiRequestConfig = new ApiRequestConfig();
  listPath: string = '$.data[*]';
  namePath: string = '$.name';
  sourcePath: string = '$.url';
  /**
   * 详情页地址模板（api 9）。
   * 非空时用 `@source` 拼出条目链接；为空则原样使用 `sourcePath` 的值。
   */
  sourceTemplate: string = '';

  static fromJson(json: Record<string, Object>): ApiSearchConfig {
    const config = new ApiSearchConfig();
    const request: Record<string, Object> | null = JsonUtils.obj(json, 'request');
    config.request = request === null ? new ApiRequestConfig() : ApiRequestConfig.fromJson(request);
    config.listPath = JsonUtils.str(json, 'listPath', '$.data[*]');
    config.namePath = JsonUtils.str(json, 'namePath', '$.name');
    config.sourcePath = JsonUtils.str(json, 'sourcePath', '$.url');
    config.sourceTemplate = JsonUtils.str(json, 'sourceTemplate').trim();
    return config;
  }

  toJson(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['request'] = this.request.toJson();
    out['listPath'] = this.listPath;
    out['namePath'] = this.namePath;
    out['sourcePath'] = this.sourcePath;
    if (this.sourceTemplate.length > 0) {
      out['sourceTemplate'] = this.sourceTemplate;
    }
    return out;
  }
}

/** 最终播放页模板配置。 */
export class ApiEpisodePageConfig {
  url: string = '';
  query: Record<string, Object> = {};

  static fromJson(json: Record<string, Object>): ApiEpisodePageConfig {
    const config = new ApiEpisodePageConfig();
    config.url = JsonUtils.str(json, 'url');
    config.query = asStringMap(json['query']);
    return config;
  }

  toJson(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['url'] = this.url;
    out['query'] = this.query;
    return out;
  }
}

/** API 章节配置（嵌套 / 分隔符两种格式）。 */
export class ApiChapterConfig {
  request: ApiRequestConfig = new ApiRequestConfig();
  format: string = ApiChapterFormat.nested;
  roadsPath: string = '$.data.roads[*]';
  roadNamePath: string = '$.name';
  episodesPath: string = '$.episodes[*]';
  episodeNamePath: string = '$.name';
  episodeUrlPath: string = '$.url';
  roadNamesPath: string = '';
  roadEpisodesPath: string = '';
  roadSeparator: string = '$$$';
  episodeSeparator: string = '#';
  fieldSeparator: string = '$';
  variables: Record<string, string> = {};
  episodePage: ApiEpisodePageConfig | undefined = undefined;

  static fromJson(json: Record<string, Object>): ApiChapterConfig {
    const config = new ApiChapterConfig();
    const request: Record<string, Object> | null = JsonUtils.obj(json, 'request');
    config.request = request === null ? new ApiRequestConfig() : ApiRequestConfig.fromJson(request);
    config.format = ApiChapterFormat.normalize(json['format']);
    config.roadsPath = JsonUtils.str(json, 'roadsPath', '$.data.roads[*]');
    config.roadNamePath = JsonUtils.str(json, 'roadNamePath', '$.name');
    config.episodesPath = JsonUtils.str(json, 'episodesPath', '$.episodes[*]');
    config.episodeNamePath = JsonUtils.str(json, 'episodeNamePath', '$.name');
    config.episodeUrlPath = JsonUtils.str(json, 'episodeUrlPath', '$.url');
    config.roadNamesPath = JsonUtils.str(json, 'roadNamesPath');
    config.roadEpisodesPath = JsonUtils.str(json, 'roadEpisodesPath');
    config.roadSeparator = JsonUtils.str(json, 'roadSeparator', '$$$');
    config.episodeSeparator = JsonUtils.str(json, 'episodeSeparator', '#');
    config.fieldSeparator = JsonUtils.str(json, 'fieldSeparator', '$');
    const rawVariables: Record<string, Object> = asStringMap(json['variables']);
    const variableKeys: string[] = Object.keys(rawVariables);
    for (let i = 0; i < variableKeys.length; i++) {
      config.variables[variableKeys[i]] = `${rawVariables[variableKeys[i]]}`;
    }
    const episodePage: Record<string, Object> | null = JsonUtils.obj(json, 'episodePage');
    config.episodePage = episodePage === null
      ? undefined : ApiEpisodePageConfig.fromJson(episodePage);
    return config;
  }

  /** 嵌套侧是否有非默认配置。 */
  private hasNestedConfig(): boolean {
    return this.roadsPath !== '$.data.roads[*]' ||
      this.roadNamePath !== '$.name' ||
      this.episodesPath !== '$.episodes[*]' ||
      this.episodeNamePath !== '$.name' ||
      this.episodeUrlPath !== '$.url';
  }

  /** 分隔符侧是否有非默认配置。 */
  private hasDelimitedConfig(): boolean {
    return this.roadNamesPath.length > 0 || this.roadEpisodesPath.length > 0;
  }

  /**
   * 序列化：写出当前 format 的字段，另一侧只要带了非默认配置也一并写出。
   * 原因见源码注释：持久化会重新序列化整个插件列表，
   * 不能因为 format 指向另一侧就把已配置的那一侧丢掉。
   */
  toJson(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['request'] = this.request.toJson();
    out['format'] = this.format;
    if (this.format === ApiChapterFormat.nested || this.hasNestedConfig()) {
      out['roadsPath'] = this.roadsPath;
      out['roadNamePath'] = this.roadNamePath;
      out['episodesPath'] = this.episodesPath;
      out['episodeNamePath'] = this.episodeNamePath;
      out['episodeUrlPath'] = this.episodeUrlPath;
    }
    if (this.format === ApiChapterFormat.delimited || this.hasDelimitedConfig()) {
      out['roadNamesPath'] = this.roadNamesPath;
      out['roadEpisodesPath'] = this.roadEpisodesPath;
      out['roadSeparator'] = this.roadSeparator;
      out['episodeSeparator'] = this.episodeSeparator;
      out['fieldSeparator'] = this.fieldSeparator;
    }
    if (Object.keys(this.variables).length > 0) {
      out['variables'] = this.variables;
    }
    if (this.episodePage !== undefined) {
      out['episodePage'] = this.episodePage.toJson();
    }
    return out;
  }
}
