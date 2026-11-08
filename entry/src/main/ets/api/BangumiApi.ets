import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { BangumiItem, parseBangumiItem, parseBangumiList } from '../model/BangumiItem';
import { BangumiRelation, CharacterFullItem, CharacterItem, StaffItem, resolveRelatedAnimeChain }
  from '../model/InfoModels';
import { JsonUtils } from '../model/JsonUtils';
import { ApiClient, ApiResponse } from '../request/core/ApiClient';
import { BangumiMirrorInterceptor } from '../request/core/MirrorInterceptors';
import { ApiEndpoints } from '../request/config/ApiEndpoints';
import {
  SearchDateRange,
  SearchDoubleRange,
  SearchFilterState,
  SearchIntRange
} from '../utils/SearchParser';
import { AnimeSeasonRange } from '../utils/SearchDates';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnArkUI';

/** /v0/search/subjects 的请求体。ArkTS 要求字面量对应显式声明的类型。 */
interface RankSearchFilter {
  type: number[];
  tag: string[];
  rank: string[];
  nsfw: boolean;
}

interface RankSearchBody {
  keyword: string;
  sort: string;
  filter: RankSearchFilter;
}

/** 带条件的过滤体：在基础过滤体上追加日期 / 评分 / 周几。 */
interface SubjectSearchFilter {
  type: number[];
  tag: string[];
  rank: string[];
  nsfw: boolean;
  air_date?: string[];
  rating?: string[];
  air_weekday?: number[];
}

interface SubjectSearchBody {
  keyword: string;
  sort: string;
  filter: SubjectSearchFilter;
}

/** 一页检索结果。对应源码 `BangumiSearchPage`（条目 + 原始条数）。 */
export class BangumiSearchPage {
  readonly items: BangumiItem[];
  /** 服务端返回的原始条数，用于判断是否还有下一页。 */
  readonly rawCount: number;

  constructor(items: BangumiItem[], rawCount: number) {
    this.items = items;
    this.rawCount = rawCount;
  }
}

/**
 * Bangumi 数据源。
 *
 * 端点取自参照实现 lib/request/config/api_endpoints.dart：
 *   - 趋势榜   https://next.bgm.tv/p1/trending/subjects
 *   - 镜像榜单 https://api.kazumi.fyi/kazumi/v1/popular/subjects
 *   - 排名检索 https://api.bgm.tv/v0/search/subjects
 *
 * 请求统一走 `ApiClient.apiDio()`，它带 `_BangumiMirrorInterceptor` 的等价实现：
 * 开启「Bangumi 镜像」后 api.bgm.tv / next.bgm.tv 会被改写到 api.kazumi.fyi；
 * 没有镜像私钥时搜索与评论回落到 api.bgmapi.com。
 */
export class BangumiApi {
  /**
   * 取字符串响应；失败时记日志并返回空串（由调用方决定兜底）。
   *
   * **带镜像降级**：主镜像（api.kazumi.fyi）如果对这条路由整条返回
   * 404 / 403 / 5xx，就换兼容镜像（api.bgmapi.com）再试一次。
   * 起因见 `BangumiMirrorInterceptor.fallbackUrl` 的注释——主镜像的
   * `/v0/subjects` 曾整条 404，而详情页的「连载中 / 已完结」全靠它。
   */
  private static async getText(url: string): Promise<string> {
    const response: ApiResponse = await ApiClient.apiDio().get(url);
    if (response.ok) {
      return response.body;
    }
    const retried: string = await BangumiApi.retryWithCompatibleMirror(
      url, response.statusCode, false);
    if (retried.length > 0) {
      return retried;
    }
    hilog.warn(DOMAIN, TAG, '请求失败 %{public}d %{public}s', response.statusCode, url);
    return '';
  }

  private static async postText(url: string, body: string): Promise<string> {
    const response: ApiResponse = await ApiClient.apiDio().post(url, body);
    if (response.ok) {
      return response.body;
    }
    const retried: string = await BangumiApi.retryWithCompatibleMirror(
      url, response.statusCode, true, body);
    if (retried.length > 0) {
      return retried;
    }
    hilog.warn(DOMAIN, TAG, '请求失败 %{public}d %{public}s', response.statusCode, url);
    return '';
  }

  /** 可选封面来源不参与 Bangumi 数据解析，只在一批条目返回给界面前补全。 */
  private static async decorateDomesticCovers(
    items: BangumiItem[]): Promise<BangumiItem[]> {
    return items;
  }

  private static async decorateCalendarCovers(
    days: BangumiItem[][]): Promise<BangumiItem[][]> {
    const all: BangumiItem[] = [];
    for (let i = 0; i < days.length; i++) {
      for (let j = 0; j < days[i].length; j++) {
        all.push(days[i][j]);
      }
    }
    return days;
  }

  private static async decoratePageCovers(
    page: BangumiSearchPage): Promise<BangumiSearchPage> {
    return page;
  }

  /**
   * 两跳兜底：兼容镜像 → 官方直连。
   *
   * 1. **兼容镜像**（`api.bgmapi.com`，无需凭据）：主镜像 404 / 403 / 5xx 时换过去。
   * 2. **官方直连**（`api.bgm.tv`，`ApiClient.apiDirectDio()` 绕过镜像改写）：
   *    兼容镜像也失败时用。
   *
   * 为什么要有第 2 跳（2026-09-19 用户：「现在搜索搜不到东西了」）：
   * 搜索是**受保护路径**，本工程没有镜像私钥，于是 `BangumiMirrorInterceptor`
   * 一律把它改写到 `api.bgmapi.com`——而那天它整站返回 502。两个域名
   * （`api.bgmapi.com` 与 `api.bgm.tv`）在改写后落到**同一个挂掉的站**，
   * 搜索自然一条都搜不到。加上官方直连之后，最后一跳永远还有一条活路
   * （官方搜索接口不需要凭据，只需要 User-Agent，我们本来就带）。
   *
   * 成功返回响应体，否则空串（调用方按原来的失败路径处理）。
   */
  private static async retryWithCompatibleMirror(url: string, status: number,
    isPost: boolean, body: string = ''): Promise<string> {
    /**
     * **连接层失败**（`statusCode === 0`，DNS/连不上/TLS 握手失败）先**原址重试一次**。
     *
     * 2026-09-22 实测：镜像的边缘节点会**交替性**连接失败——同一秒连发两次，
     * 一次 `Failed to connect … after 25 ms`、下一次 200 正常返回（GET / POST 都一样）。
     * 原来的逻辑只对 404/403/5xx 做降级，连接失败直接放弃，于是用户看到
     * 「搜索半天、搜不出来」，其实再连一次就好了。
     *
     * 为什么**不**顺手跳到官方直连：本网络下 `api.bgm.tv` / `next.bgm.tv`
     * 是 DNS 不可解析的（实测 `curl (6) Could not resolve host`，一次要耗 5 秒），
     * 网络本身不通时那一跳纯属白等。降级链仍然只对「服务端明确回错」生效。
     */
    if (status === 0) {
      hilog.info(DOMAIN, TAG, '连接失败，原址重试 %{public}s', url);
      const client = ApiClient.apiDio();
      const again: ApiResponse = isPost
        ? await client.post(url, body) : await client.get(url);
      if (again.ok) {
        hilog.info(DOMAIN, TAG, '原址重试命中 %{public}s', url);
        return again.body;
      }
      hilog.warn(DOMAIN, TAG, '原址重试仍失败 %{public}d %{public}s',
        again.statusCode, url);
      status = again.statusCode;
    }
    if (!BangumiMirrorInterceptor.shouldFallback(status)) {
      return '';
    }
    const alt: string | null = BangumiMirrorInterceptor.fallbackUrl(url);
    if (alt !== null) {
      hilog.info(DOMAIN, TAG, '主镜像 %{public}d，降级重试 %{public}s', status, alt);
      const client = ApiClient.apiDio();
      const retry: ApiResponse = isPost
        ? await client.post(alt, body)
        : await client.get(alt);
      if (retry.ok) {
        hilog.info(DOMAIN, TAG, '兼容镜像命中 %{public}s', alt);
        return retry.body;
      }
      hilog.warn(DOMAIN, TAG, '兼容镜像同样失败 %{public}d %{public}s',
        retry.statusCode, alt);
      status = retry.statusCode;
    }
    // 第二跳：官方直连（不做镜像改写）
    const direct: string | null = BangumiMirrorInterceptor.officialUrl(url);
    if (direct === null) {
      return '';
    }
    hilog.info(DOMAIN, TAG, '镜像链路失败，官方直连重试 %{public}s', direct);
    const directClient: ApiClient = ApiClient.apiDirectDio();
    const last: ApiResponse = isPost
      ? await directClient.post(direct, body)
      : await directClient.get(direct);
    if (!last.ok) {
      hilog.warn(DOMAIN, TAG, '官方直连同样失败 %{public}d %{public}s',
        last.statusCode, direct);
      return '';
    }
    hilog.info(DOMAIN, TAG, '官方直连命中 %{public}s', direct);
    return last.body;
  }

  /** 趋势榜：推荐页「热门番组」与 Banner 的数据源。 */
  static async trending(limit: number, offset: number): Promise<BangumiItem[]> {
    const url: string =
      `${ApiEndpoints.bangumiAPINextDomain}${ApiEndpoints.bangumiTrendsNext}` +
        `?type=2&limit=${limit}&offset=${offset}`;
    const text: string = await BangumiApi.getText(url);
    if (text.length === 0) {
      return [];
    }
    return await BangumiApi.decorateDomesticCovers(parseBangumiList(text));
  }

  /** 镜像榜单，可按标签过滤。 */
  static async popular(tag: string, limit: number, offset: number): Promise<BangumiItem[]> {
    let url: string =
      `${ApiEndpoints.bangumiMirrorDomain}${ApiEndpoints.bangumiMirrorPopularSubjects}` +
        `?limit=${limit}&offset=${offset}`;
    if (tag.length > 0) {
      url += `&tag=${encodeURIComponent(tag)}`;
    }
    const text: string = await BangumiApi.getText(url);
    if (text.length === 0) {
      return [];
    }
    return await BangumiApi.decorateDomesticCovers(parseBangumiList(text));
  }

  /** 排名检索。 */
  static async rankSearch(tag: string, limit: number, offset: number): Promise<BangumiItem[]> {
    const url: string =
      `${ApiEndpoints.bangumiAPIDomain}/v0/search/subjects?limit=${limit}&offset=${offset}`;
    const tagFilter: string[] = tag.length > 0 ? [tag] : ['日本'];
    const filter: RankSearchFilter = {
      type: [2],
      tag: tagFilter,
      rank: ['>2', '<=1050'],
      nsfw: false
    };
    const payload: RankSearchBody = {
      keyword: '',
      sort: 'rank',
      filter: filter
    };
    const body: string = JSON.stringify(payload);
    const text: string = await BangumiApi.postText(url, body);
    if (text.length === 0) {
      return [];
    }
    return await BangumiApi.decorateDomesticCovers(parseBangumiList(text));
  }

  /**
   * 单品详情。
   *
   * 端点必须用 **next.bgm.tv 的 `/p1/subjects/{id}`**，与源码
   * `getBangumiInfoByID` 一致；实测 api.kazumi.fyi 只代理 `/p1/*`，
   * `/v0/subjects/{id}` 一律 404（阶段 2 若新增 v0 接口要留意这点）。
   */
  static async getBangumiInfoByID(id: number): Promise<BangumiItem | null> {
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPINextDomain}${ApiEndpoints.bangumiInfoByIDNext}`,
      [`${id}`]);
    const text: string = await BangumiApi.getText(url);
    if (text.length === 0) {
      return null;
    }
    try {
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const item: BangumiItem = parseBangumiItem(root);
      return item;
    } catch (e) {
      return null;
    }
  }

  // ============================================================
  // 按 §64 方法表补齐。端点 / 参数逐条对应源码。
  // 评论、角色、制作人员在源码里会解析成具名模型（CommentItem 等），
  // 原生版模型层尚未覆盖，这里先返回原始 JSON；端点与请求头已对齐，
  // 阶段 3 做详情页时只需补解析。
  // ============================================================

  /**
   * 每日放送。返回 **7 个列表**，下标 0..6 对应周一..周日
   * （源码 `getCalendar` 同样是 `List<List<BangumiItem>>`）。
   *
   * 结构：`{ "1": [ { "subject": {...BangumiItem 字段} }, ... ], ... "7": [...] }`；
   * 单条坏数据跳过（源码在这里也是 `catch (_) {}`），整包失败返回空表。
   */
  static async getCalendar(): Promise<BangumiItem[][]> {
    const url: string =
      `${ApiEndpoints.bangumiAPINextDomain}${ApiEndpoints.bangumiCalendar}`;
    return await BangumiApi.decorateCalendarCovers(
      BangumiApi.parseCalendar(await BangumiApi.getText(url)));
  }

  /** 日历兜底：改用排名检索。 */
  static async getCalendarBySearch(tag: string, limit: number,
    offset: number): Promise<BangumiItem[]> {
    return await BangumiApi.rankSearch(tag, limit, offset);
  }

  /**
   * 镜像季番日历路径（源码 `buildBangumiMirrorSeasonCalendarPath`）。
   *
   * 注意参数名是 **start / end**（`List<String> dateRange`），不是 `date`——
   * 之前那版按 `?date=` 拼串，镜像端会忽略参数并按当前季返回，
   * 表现出来就是「切了季度但数据没变」。
   */
  static buildBangumiMirrorSeasonCalendarPath(dateRange: AnimeSeasonRange): string {
    const query: string = `?start=${encodeURIComponent(dateRange.start)}` +
      `&end=${encodeURIComponent(dateRange.end)}`;
    return `${ApiEndpoints.bangumiMirrorDomain}` +
      `${ApiEndpoints.bangumiMirrorSeasonCalendar}${query}`;
  }

  /**
   * 镜像季番日历（源码 `getBangumiMirrorSeasonCalendar`）。
   *
   * 返回 7 个列表，下标 0..6 对应周一..周日；结构同为 `{"1": [{"subject": …}]}`。
   */
  static async getBangumiMirrorSeasonCalendar(dateRange: AnimeSeasonRange):
    Promise<BangumiItem[][]> {
    return await BangumiApi.decorateCalendarCovers(BangumiApi.parseCalendar(
      await BangumiApi.getText(
        BangumiApi.buildBangumiMirrorSeasonCalendarPath(dateRange))));
  }

  /** 解析 `{"1": [{"subject": …}]}` 形式的日历响应。 */
  private static parseCalendar(text: string): BangumiItem[][] {
    const days: BangumiItem[][] = [];
    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(text) as Object;
    } catch (e) {
      // 整包不是 JSON：返回空的 7 天
      return days;
    }
    if (parsed === null || parsed === undefined) {
      return days;
    }
    const root: Record<string, Object> = parsed as Record<string, Object>;
    /**
     * 接口**报错**时要抛出去，不能和「这一季本来就没番」混为一谈。
     *
     * 镜像遇到非法参数会回 `{"error":{"code":"invalid_request","message":…}}`
     * ——它不是日历结构，几天全都是空的，以前的写法会把它静默解析成「7 天没番」，
     * 于是用户看到的是「该季度暂无数据」这种像是正常空态的文案。
     * 2026-09-18 的「10 月番全都没有数据」就是这么被掩盖了整整几轮：
     * 真因是我们把 `end` 拼成了 `2025-13-01`（见 `formatDateParts`）。
     * 现在报错会走到 `loadSeason` 的 catch，状态行显示「加载失败：…」，
     * 不再假装是空数据。
     */
    const errorField: Object | undefined = root['error'];
    if (errorField !== undefined && errorField !== null) {
      const errorRecord: Record<string, Object> = errorField as Record<string, Object>;
      const message: Object | undefined = errorRecord['message'];
      const code: Object | undefined = errorRecord['code'];
      const detail: string = message === undefined || message === null
        ? `${code}` : `${code}: ${message}`;
      throw new Error(`日历接口返回错误（${detail}）`);
    }
    for (let day = 1; day <= 7; day++) {
      const list: BangumiItem[] = [];
      const bucket: Object | undefined = root[`${day}`];
      if (bucket !== undefined && bucket !== null && Array.isArray(bucket)) {
        const array: Object[] = bucket as Object[];
        for (let i = 0; i < array.length; i++) {
          const entry: Object = array[i];
          if (entry === null || entry === undefined) {
            continue;
          }
          const record: Record<string, Object> = entry as Record<string, Object>;
          const subject: Object | undefined = record['subject'];
          if (subject === undefined || subject === null) {
            continue;
          }
          try {
            list.push(parseBangumiItem(subject as Record<string, Object>));
          } catch (e) {
            // 单条坏数据跳过
          }
        }
      }
      days.push(list);
    }
    return days;
  }

  /** 官方排名检索（`getBangumiList`）。 */
  static async getBangumiList(rank: string, tag: string,
    limit: number): Promise<BangumiItem[]> {
    return await BangumiApi.rankSearch(tag, limit, 0);
  }

  /** 趋势榜（`getBangumiTrendsList`）。 */
  static async getBangumiTrendsList(type: number, limit: number,
    offset: number): Promise<BangumiItem[]> {
    const url: string =
      `${ApiEndpoints.bangumiAPINextDomain}${ApiEndpoints.bangumiTrendsNext}` +
        `?type=${type}&limit=${limit}&offset=${offset}`;
    const text: string = await BangumiApi.getText(url);
    return text.length === 0 ? [] :
      await BangumiApi.decorateDomesticCovers(parseBangumiList(text));
  }

  /** 镜像榜单（`getBangumiMirrorPopularSubjects`）。 */
  static async getBangumiMirrorPopularSubjects(tag: string, limit: number,
    offset: number): Promise<BangumiItem[]> {
    return await BangumiApi.popular(tag, limit, offset);
  }

  /**
   * 多域名依次尝试的搜索（源码 `bangumiSearch` / `_searchSubjectsOn`）：
   * 先试无需凭据的兼容镜像，失败再试官方。
   */
  static async bangumiSearch(keyword: string, limit: number,
    offset: number): Promise<BangumiItem[]> {
    // 旧版路由优先（不需要凭据，兼容镜像 + 官方都还活着；见 `searchLegacyOn`）
    const legacy: BangumiItem[] | null = await BangumiApi.searchLegacyOn(
      ApiEndpoints.bangumiCompatibleDomain, keyword, limit, offset);
    if (legacy !== null) {
      return await BangumiApi.decorateDomesticCovers(legacy);
    }
    const domains: string[] = [
      ApiEndpoints.bangumiCompatibleDomain,
      ApiEndpoints.bangumiAPIDomain
    ];
    for (let i = 0; i < domains.length; i++) {
      const items: BangumiItem[] =
        await BangumiApi.searchSubjectsOn(domains[i], keyword, limit, offset);
      if (items.length > 0) {
        return await BangumiApi.decorateDomesticCovers(items);
      }
    }
    return [];
  }

  /**
   * 带条件的番剧检索（源码 `bangumiSearch` 的重载形态）。
   *
   * 过滤体逐字段对齐 `BangumiApi.buildBangumiSearchParams`：
   *   rank  → `['>=min','<=max']`；未限定且按排名排序时用 `['>0','<=99999']`
   *   air_date   → `['>=start','<end']`（左闭右开，来自季度或自定义日期）
   *   rating     → 评分区间
   *   air_weekday→ 周几（1=周一）
   * 域名顺序同 `bangumiSearch`：先无凭据兼容镜像，再官方站点。
   */
  static async bangumiSearchFiltered(keyword: string, state: SearchFilterState,
    limit: number, offset: number): Promise<BangumiSearchPage | null> {
    const filter: SubjectSearchFilter = {
      type: [2],
      tag: state.tags,
      rank: BangumiApi.rankFilter(state),
      nsfw: false
    };
    const dateRange: SearchDateRange | null = state.effectiveDateRange();
    if (dateRange !== null && dateRange.isValid()) {
      filter.air_date = [`>=${dateRange.start}`, `<${dateRange.end}`];
    }
    if (state.scoreRange !== null && state.scoreRange.isValid()) {
      filter.rating = BangumiApi.numberFilter(
        state.scoreRange.hasMin ? state.scoreRange.min : null,
        state.scoreRange.hasMax ? state.scoreRange.max : null);
    }
    if (state.weekdays.length > 0) {
      filter.air_weekday = state.weekdays.slice().sort((a: number, b: number) => a - b);
    }
    const payload: SubjectSearchBody = {
      keyword: keyword,
      sort: state.sort,
      filter: filter
    };
    const domains: string[] = [
      ApiEndpoints.bangumiCompatibleDomain,
      ApiEndpoints.bangumiAPIDomain
    ];
    /**
     * 走旧版还是走 v0，先看**这次检索旧版到底能不能表达**。
     *
     * 背景（2026-09-19）：v0 的 `POST /v0/search/subjects` 在没有镜像私钥时会被
     * 改写到兼容镜像，而那条路由当时整条 **502**，而旧版 `/search/subject/…`
     * 仍然 200 + 结果，所以那会儿把旧版提到了前面。
     *
     * 但旧版**只认关键词**——它没有 tag / 排序 / 日期 / 评分 / 周几这些参数，
     * 只能在拿回来的那一页上做本地筛（`applyLocalFilters`），而且
     *
     *   1. **tag 根本筛不了**（旧版响应里没有 tags 字段）；
     *   2. 关键词为空时旧版返回的是**空列表**（2026-09-22 实测：
     *      `/search/subject/?type=2&responseGroup=large` → 200 但 `list: []`），
     *      于是「只用条件筛选」＝把空列表再筛一遍 ＝ **一条都没有**
     *      （用户 2026-09-22：「用条件筛选即 tag 搜索无法搜索到」）；
     *   3. 本地筛只作用于**已取回的那一页**，翻页/命中数都不对。
     *
     * 所以：**只有「纯关键词、且没有其它条件」才允许走旧版**；带 tag / 排序 /
     * 时间 / 评分 / 周几，或者关键词为空，一律交给 v0。
     * （2026-09-22 复测：`POST /v0/search/subjects` 带 `tag:["日常"]` 已经
     * **200 + 15 KB** 正常返回，不再 502。）
     */
    const keywordEmpty: boolean = keyword.trim().length === 0;
    const legacyUsable: boolean = !keywordEmpty && !state.hasAdvancedFilters();
    if (legacyUsable) {
      const legacy: BangumiItem[] | null = await BangumiApi.searchLegacyOn(
        ApiEndpoints.bangumiCompatibleDomain, keyword, limit, offset);
      if (legacy !== null) {
        const filtered: BangumiItem[] = BangumiApi.applyLocalFilters(legacy, state);
        return await BangumiApi.decoratePageCovers(
          new BangumiSearchPage(filtered, filtered.length));
      }
    }
    /**
     * v0：**先记住第一个能用的响应**（哪怕它一条都没有），
     * 再继续试下一个域名看有没有非空的。这样「服务端确实没有结果」不会被
     * 误判成「这个域名挂了」而绕回去走旧版。
     */
    let usable: BangumiSearchPage | null = null;
    for (let i = 0; i < domains.length; i++) {
      const page: BangumiSearchPage | null = await BangumiApi.searchSubjectsWithOn(
        domains[i], payload, limit, offset);
      if (page === null) {
        continue;
      }
      if (page.items.length > 0) {
        return await BangumiApi.decoratePageCovers(page);
      }
      if (usable === null) {
        usable = page;
      }
    }
    if (usable !== null) {
      return await BangumiApi.decoratePageCovers(usable);
    }
    /**
     * 兜底：v0 两条域名都不可用（镜像与官方同时挂），且有关键词时，
     * 退回旧版 + 本地筛——标签档这时仍然筛不了，只记日志（见 `applyLocalFilters`）。
     */
    if (keywordEmpty) {
      return null;
    }
    const fallback: BangumiItem[] | null = await BangumiApi.searchLegacyOn(
      ApiEndpoints.bangumiCompatibleDomain, keyword, limit, offset);
    if (fallback === null) {
      return null;
    }
    const filtered: BangumiItem[] = BangumiApi.applyLocalFilters(fallback, state);
    return await BangumiApi.decoratePageCovers(
      new BangumiSearchPage(filtered, filtered.length));
  }

  private static rankFilter(state: SearchFilterState): string[] {
    if (state.rankRange !== null && state.rankRange.isValid()) {
      return BangumiApi.numberFilter(
        state.rankRange.hasMin ? state.rankRange.min : null,
        state.rankRange.hasMax ? state.rankRange.max : null);
    }
    return state.sort === 'rank' ? ['>0', '<=99999'] : ['>=0', '<=99999'];
  }

  private static numberFilter(min: number | null, max: number | null): string[] {
    const out: string[] = [];
    if (min !== null) {
      out.push(`>=${min}`);
    }
    if (max !== null) {
      out.push(`<=${max}`);
    }
    return out;
  }

  /** 单域名检索；返回 `null` 表示该域名不可用（与源码 `_searchSubjectsOn` 一致）。 */
  private static async searchSubjectsWithOn(domain: string, payload: SubjectSearchBody,
    limit: number, offset: number): Promise<BangumiSearchPage | null> {
    const url: string =
      `${domain}/v0/search/subjects?limit=${limit}&offset=${offset}`;
    const text: string = await BangumiApi.postText(url, JSON.stringify(payload));
    if (text.length === 0) {
      return null;
    }
    return new BangumiSearchPage(parseBangumiList(text), BangumiApi.rawCount(text));
  }

  /** 响应体里的原始条数（用于判断是否还有下一页）。 */
  private static rawCount(text: string): number {
    try {
      const parsed: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const data: Object = parsed['data'];
      if (Array.isArray(data)) {
        return (data as Object[]).length;
      }
    } catch (e) {
      // 解析失败按 0 处理
    }
    return 0;
  }

  private static async searchSubjectsOn(domain: string, keyword: string,
    limit: number, offset: number): Promise<BangumiItem[]> {
    const url: string = `${domain}/v0/search/subjects?limit=${limit}&offset=${offset}`;
    const filter: RankSearchFilter = { type: [2], tag: [], rank: [], nsfw: false };
    const payload: Record<string, Object> = {};
    payload['keyword'] = keyword;
    payload['sort'] = 'match';
    payload['filter'] = filter;
    const text: string = await BangumiApi.postText(url, JSON.stringify(payload));
    return text.length === 0 ? [] : parseBangumiList(text);
  }

  /**
   * **旧版搜索**：`GET {domain}/search/subject/{keyword}?type=2&responseGroup=large`。
   *
   * 为什么必须有它（2026-09-19 用户：「搜索一直加载、搜不出来」）：
   *   - 本工程没有镜像私钥，`POST /v0/search/subjects` 会被
   *     `BangumiMirrorInterceptor` 改写到免凭据兼容镜像 `api.bgmapi.com`；
   *   - 而该站的 v0 搜索路由现在**整条 502**（实测 2026-09-19）；
   *   - 同一天实测：**同一台机器**的旧版路由
   *     `https://api.bgmapi.com/search/subject/葬送的芙莉莲?type=2&responseGroup=large`
   *     仍然 **200 + 8 条结果**，字段（id / name / name_cn / images / rating /
   *     rank / air_date / eps / collection）与 v0 基本一致，`parseBangumiItem`
   *     直接能解析。
   *
   * 所以搜索改成「旧版优先」：一次请求、不要凭据、也不要镜像私钥。
   * 返回 `null` = 这条路由本身不可用（调用方再走 v0 链路）；
   * 返回空数组 = 请求成功但确实没有结果（**不要**再打别的接口，否则就是
   * 「一直加载」——原来是 v0 的两跳兜底各等一次超时）。
   */
  private static async searchLegacyOn(domain: string, keyword: string,
    limit: number, offset: number): Promise<BangumiItem[] | null> {
    const url: string = `${domain}/search/subject/${encodeURIComponent(keyword)}` +
      `?type=2&responseGroup=large&max_results=${Math.max(1, limit + offset)}`;
    const text: string = await BangumiApi.getText(url);
    if (text.length === 0) {
      hilog.warn(DOMAIN, TAG, '旧版搜索不可用 %{public}s', url);
      return null;
    }
    const all: BangumiItem[] = BangumiApi.parseLegacySearch(text);
    hilog.info(DOMAIN, TAG, '旧版搜索命中 %{public}d 条（offset %{public}d）',
      all.length, offset);
    // `max_results` 从 1 开始算，翻页用切片实现（旧版没有稳定的 offset 语义）
    return all.slice(offset, offset + limit);
  }

  /** 旧版搜索的响应体是 `{results:N, list:[...]}`（与 v0 的 `{data:[...]}` 不同）。 */
  private static parseLegacySearch(text: string): BangumiItem[] {
    const out: BangumiItem[] = [];
    try {
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const list: Object | undefined = root['list'];
      if (list === undefined || list === null || !Array.isArray(list)) {
        return out;
      }
      const arr: Object[] = list as Object[];
      for (let i = 0; i < arr.length; i++) {
        out.push(parseBangumiItem(arr[i]));
      }
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '旧版搜索结果解析失败: %{public}s', err.message);
    }
    return out;
  }

  /**
   * 旧版结果上的**本地条件过滤**。
   *
   * 旧版接口不接受 v0 那套 filter（tag / rank / air_date / rating / air_weekday），
   * 但它返回的条目自带 `rank` / `rating.score` / `air_date` / 由 air_date 推出的
   * 星期，所以这几档可以在本地筛。**tag 档筛不了**（旧版响应里没有 tags 字段），
   * 这时只记一条日志、不丢结果——宁可多给几条，也别让用户看到「一条都没有」。
   */
  private static applyLocalFilters(items: BangumiItem[],
    state: SearchFilterState): BangumiItem[] {
    const dateRange: SearchDateRange | null = state.effectiveDateRange();
    const rankRange: SearchIntRange | null =
      state.rankRange !== null && state.rankRange.isValid() ? state.rankRange : null;
    const scoreRange: SearchDoubleRange | null =
      state.scoreRange !== null && state.scoreRange.isValid() ? state.scoreRange : null;
    if (dateRange === null && rankRange === null && scoreRange === null &&
      state.weekdays.length === 0) {
      return items;
    }
    const out: BangumiItem[] = [];
    for (let i = 0; i < items.length; i++) {
      const item: BangumiItem = items[i];
      if (dateRange !== null && dateRange.isValid()) {
        const date: string = item.airDate;
        if (date.length === 0 || date < dateRange.start || date >= dateRange.end) {
          continue;
        }
      }
      if (rankRange !== null) {
        const rank: number = item.rank;
        if (rank <= 0 ||
          (rankRange.hasMin && rank < rankRange.min) ||
          (rankRange.hasMax && rank > rankRange.max)) {
          continue;
        }
      }
      if (scoreRange !== null) {
        const score: number = item.score;
        if (score <= 0 ||
          (scoreRange.hasMin && score < scoreRange.min) ||
          (scoreRange.hasMax && score > scoreRange.max)) {
          continue;
        }
      }
      if (state.weekdays.length > 0 && state.weekdays.indexOf(item.airWeekday) < 0) {
        continue;
      }
      out.push(item);
    }
    if (state.tags.length > 0) {
      hilog.warn(DOMAIN, TAG,
        '旧版搜索响应不含 tags，标签条件 %{public}d 项无法在本地筛选（结果未按标签过滤）',
        state.tags.length);
    }
    return out;
  }

  /** 关联条目（`getBangumiRelationsByID`）。 */
  static async getBangumiRelationsByID(id: number): Promise<Object | null> {
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPIDomain}${ApiEndpoints.bangumiRelationsByID}`,
      [`${id}`]);
    return BangumiApi.parseJson(await BangumiApi.getText(url));
  }

  /**
   * 剧集列表（`getBangumiEpisodesByID`）。
   *
   * `limit` / `offset` 默认 0 表示**不拼进 URL**（保持原有调用行为）。
   * 需要分页时必须显式传：接口不传 `limit` 时只返回 100 条
   * （实测《名侦探柯南》`total=1340`、默认只给 100）。
   */
  static async getBangumiEpisodesByID(id: number,
    episodeType: number, limit: number = 0,
    offset: number = 0): Promise<Object | null> {
    let url: string =
      `${ApiEndpoints.bangumiAPIDomain}${ApiEndpoints.bangumiEpisodeByID}` +
        `?subject_id=${id}`;
    /**
     * `episodeType < 0` 表示**不带 `type` 参数**（拿全部条目，正片/SP 一起），
     * 与参照实现 `bangumi_api.dart:481` 的取法一致——它只传
     * `subject_id / offset / limit`，正片与 SP 的区分在客户端按 `type` 做。
     */
    if (episodeType >= 0) {
      url += `&type=${episodeType}`;
    }
    if (limit > 0) {
      url += `&limit=${limit}`;
    }
    if (offset > 0) {
      url += `&offset=${offset}`;
    }
    return BangumiApi.parseJson(await BangumiApi.getText(url));
  }

  /**
   * 分页拉全某条目的分集（长番必须用这个）。
   *
   * 返回 `null` 表示**请求失败**（与「成功但没有分集」区分开：后者是空数组）。
   *
   * 先按单页 1000 条翻（镜像实测接受 `limit=1000`，柯南 1340 集两次就够）。
   * 如果上游对 `limit=1000` 报错，再退回文档默认的 100 条重翻一遍——
   * 宁可多几次请求，也不能因为一个可选参数让整条链路拿不到数据。
   */
  static async getAllBangumiEpisodesByID(id: number,
    episodeType: number = -1): Promise<Object[] | null> {
    const big: Object[] | null =
      await BangumiApi.pageEpisodes(id, episodeType, 1000);
    if (big !== null) {
      return big;
    }
    hilog.warn(DOMAIN, TAG, 'limit=1000 失败，退回 limit=100 重翻');
    return await BangumiApi.pageEpisodes(id, episodeType, 100);
  }

  /** 按固定页大小翻完为止；请求失败返回 `null`。 */
  private static async pageEpisodes(id: number, episodeType: number,
    pageSize: number): Promise<Object[] | null> {
    const out: Object[] = [];
    const maxEpisodes: number = 20000;
    let offset: number = 0;
    while (offset < maxEpisodes) {
      const json: Object | null =
        await BangumiApi.getBangumiEpisodesByID(id, episodeType, pageSize, offset);
      const rec: Record<string, Object> | null = BangumiApi.asObject(json);
      if (rec === null) {
        return out.length > 0 ? out : null;
      }
      const data: Object | undefined = rec['data'];
      if (data === undefined || !Array.isArray(data)) {
        return out.length > 0 ? out : null;
      }
      const page: Object[] = data as Object[];
      if (page.length === 0) {
        break;
      }
      for (let i = 0; i < page.length; i++) {
        out.push(page[i]);
      }
      offset += page.length;
      const total: number = Number.parseFloat(`${rec['total']}`);
      if (!Number.isNaN(total) && total > 0 && out.length >= total) {
        break;
      }
      /**
       * `total` 才是权威的结束条件。
       *
       * 只有「上游没给 total」时才用「这一页不满」来判断翻完了——
       * 否则上游把 `limit=1000` 悄悄夹到 100 时，第一页就会因为
       * 「100 < 1000」被判成翻完，柯南那种长番又只剩前 100 条。
       */
      if (page.length < pageSize && (Number.isNaN(total) || total <= 0)) {
        break;
      }
    }
    return out;
  }

  /** 单集详情（`getBangumiEpisodeByID`）：在剧集列表里按 sort 匹配。 */
  static async getBangumiEpisodeByID(id: number, episode: number): Promise<Object | null> {
    const list: Object | null = await BangumiApi.getBangumiEpisodesByID(id, 0);
    const rec: Record<string, Object> | null = BangumiApi.asObject(list);
    if (rec === null) {
      return null;
    }
    const data: Object | undefined = rec['data'];
    if (data === undefined || !Array.isArray(data)) {
      return null;
    }
    const array: Object[] = data as Object[];
    for (let i = 0; i < array.length; i++) {
      const item: Record<string, Object> | null = BangumiApi.asObject(array[i]);
      if (item !== null && Number(item['sort']) === episode) {
        return item;
      }
    }
    return null;
  }

  /** 条目评论（`getBangumiCommentsByID`）。 */
  static async getBangumiCommentsByID(id: number, limit: number,
    offset: number): Promise<Object | null> {
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPINextDomain}${ApiEndpoints.bangumiCommentsByIDNext}`,
      [`${id}`, `${limit}`, `${offset}`]);
    return BangumiApi.parseJson(await BangumiApi.getText(url));
  }

  /** 剧集评论（`getBangumiCommentsByEpisodeID`）。 */
  static async getBangumiCommentsByEpisodeID(id: number, limit: number,
    offset: number): Promise<Object | null> {
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPINextDomain}` +
        `${ApiEndpoints.bangumiEpisodeCommentsByIDNext}`, [`${id}`]) +
      `?limit=${limit}&offset=${offset}`;
    return BangumiApi.parseJson(await BangumiApi.getText(url));
  }

  /** 角色评论（`getCharacterCommentsByCharacterID`）。 */
  static async getCharacterCommentsByCharacterID(id: number, limit: number,
    offset: number): Promise<Object | null> {
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPINextDomain}` +
        `${ApiEndpoints.bangumiCharacterCommentsByIDNext}`, [`${id}`]) +
      `?limit=${limit}&offset=${offset}`;
    return BangumiApi.parseJson(await BangumiApi.getText(url));
  }

  /** 制作人员（`getBangumiStaffByID`）。 */
  static async getBangumiStaffByID(id: number): Promise<Object | null> {
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPIDomain}${ApiEndpoints.bangumiStaffByID}`,
      [`${id}`]);
    return BangumiApi.parseJson(await BangumiApi.getText(url));
  }

  /** 角色列表。方法名与源码一致：`getCharatersByBangumiID`（少一个 c）。 */
  static async getCharatersByBangumiID(id: number): Promise<Object | null> {
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPIDomain}${ApiEndpoints.bangumiCharacterByID}`,
      [`${id}`]);
    return BangumiApi.parseJson(await BangumiApi.getText(url));
  }

  /** 单个角色详情（next）。 */
  static async getCharacterByCharacterID(id: number): Promise<Object | null> {
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPINextDomain}` +
        `${ApiEndpoints.bangumiCharacterInfoByCharacterIDNext}`, [`${id}`]);
    return BangumiApi.parseJson(await BangumiApi.getText(url));
  }

  /**
   * 角色详情，解析成模型（对应参照实现的
   * `getCharacterByCharacterID` + `CharacterFullItem.fromJson`）。
   *
   * 返回 `null` 表示请求/解析失败，调用方据此显示「加载失败 + 重试」；
   * 返回 `id === 0` 的实例表示拿到的是空壳（源码里用 `CharacterFullItem.fromTemplate()`）。
   */
  static async getCharacterFullByID(id: number): Promise<CharacterFullItem | null> {
    const raw: Object | null = await BangumiApi.getCharacterByCharacterID(id);
    if (raw === null) {
      return null;
    }
    return CharacterFullItem.fromRaw(raw);
  }

  /** 当前 Token 对应用户（`getCurrentUser`）。 */
  static async getCurrentUser(accessToken: string): Promise<Object | null> {
    if (accessToken.length === 0) {
      return null;
    }
    const url: string =
      `${ApiEndpoints.bangumiAPIDomain}${ApiEndpoints.bangumiUsernameByToken}`;
    return BangumiApi.parseJson(await BangumiApi.getTextWithToken(url, accessToken));
  }

  /** 全部收藏（`getBangumiCollectibles`，分页）。 */
  static async getBangumiCollectibles(username: string, limit: number,
    offset: number, accessToken: string): Promise<Object | null> {
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPIDomain}${ApiEndpoints.bangumiGetAllCollections}`,
      [username, `${limit}`, `${offset}`]);
    return BangumiApi.parseJson(
      await BangumiApi.getTextWithToken(url, accessToken));
  }

  /** 写入收藏状态（`updateBangumiById` / `updateBangumiByType` 共用）。 */
  static async updateBangumiByType(id: number, localType: number,
    accessToken: string): Promise<boolean> {
    if (accessToken.length === 0) {
      return false;
    }
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPIDomain}${ApiEndpoints.bangumiSetCollection}`,
      [`${id}`]);
    const payload: Record<string, Object> = {};
    payload['type'] = localType;
    const text: string = await BangumiApi.postTextWithToken(
      url, JSON.stringify(payload), accessToken);
    return text.length > 0;
  }

  /** 写入评分 / 评价（`addOrUpdateBangumiEvaluationBySubjectID`）。 */
  static async addOrUpdateBangumiEvaluationBySubjectID(id: number, rate: number,
    comment: string, tags: string[], accessToken: string): Promise<boolean> {
    if (accessToken.length === 0) {
      return false;
    }
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPIDomain}${ApiEndpoints.bangumiSetCollection}`,
      [`${id}`]);
    const payload: Record<string, Object> = {};
    payload['rating'] = rate;
    payload['comment'] = comment;
    payload['tags'] = tags;
    const text: string = await BangumiApi.postTextWithToken(
      url, JSON.stringify(payload), accessToken);
    return text.length > 0;
  }

  // ============================================================
  // 详情页（阶段 4）：在原始 JSON 之上补模型解析。
  // ============================================================

  /**
   * 关联条目（解析版）。
   *
   * 端点返回一个**扁平数组**（每个元素带自己的 `relation`），
   * 单条坏数据跳过（与源码 `BangumiApi` 的 try/catch 一致）。
   */
  static async getParsedRelationsByID(id: number): Promise<BangumiRelation[]> {
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPIDomain}${ApiEndpoints.bangumiRelationsByID}`,
      [`${id}`]);
    const text: string = await BangumiApi.getText(url);
    if (text.length === 0) {
      return [];
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(text) as Object;
    } catch (e) {
      return [];
    }
    if (!Array.isArray(parsed)) {
      hilog.warn(DOMAIN, TAG, '关联条目响应不是数组');
      return [];
    }
    const array: Object[] = parsed as Object[];
    const relations: BangumiRelation[] = [];
    for (let i = 0; i < array.length; i++) {
      const rec: Record<string, Object> | null = JsonUtils.asObj(array[i]);
      if (rec === null) {
        continue;
      }
      const relation: BangumiRelation | null = BangumiRelation.fromJson(rec);
      if (relation !== null) {
        relations.push(relation);
      }
    }
    const relationItems: BangumiItem[] = [];
    for (let i = 0; i < relations.length; i++) {
      relationItems.push(relations[i].bangumiItem);
    }
    return relations;
  }

  /**
   * 关联条目（沿前传 / 续集展开成主线顺序）。
   * 对应源码 `InfoController.queryBangumiRelationsByID`。
   */
  static async getRelatedAnimeByID(id: number): Promise<BangumiRelation[]> {
    return resolveRelatedAnimeChain(id,
      (subjectId: number) => BangumiApi.getParsedRelationsByID(subjectId));
  }

  /** 角色列表（解析版）。端点直接返回数组。 */
  static async getCharacterListByID(id: number): Promise<CharacterItem[]> {
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPIDomain}${ApiEndpoints.bangumiCharacterByID}`,
      [`${id}`]);
    const text: string = await BangumiApi.getText(url);
    if (text.length === 0) {
      return [];
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(text) as Object;
    } catch (e) {
      return [];
    }
    if (!Array.isArray(parsed)) {
      return [];
    }
    const array: Object[] = parsed as Object[];
    const list: CharacterItem[] = [];
    for (let i = 0; i < array.length; i++) {
      const rec: Record<string, Object> | null = JsonUtils.asObj(array[i]);
      if (rec !== null) {
        list.push(CharacterItem.fromJson(rec));
      }
    }
    // 源码按「主角 → 配角 → 客串 → 其它」排序。
    const priority: Map<string, number> = new Map<string, number>();
    priority.set('主角', 1);
    priority.set('配角', 2);
    priority.set('客串', 3);
    list.sort((a: CharacterItem, b: CharacterItem) => {
      const valueA: number | undefined = priority.get(a.relation);
      const valueB: number | undefined = priority.get(b.relation);
      return (valueA === undefined ? 4 : valueA) - (valueB === undefined ? 4 : valueB);
    });
    return list;
  }

  /**
   * 制作人员（解析版）。
   *
   * 端点是一个「人员 × 职务」的扁平数组，因此先按人员 id 合并，
   * 再按职务优先级排序（与 `StaffResponse.fromJson` 一致）。
   */
  static async getStaffListByID(id: number): Promise<StaffItem[]> {
    const url: string = ApiEndpoints.formatUrl(
      `${ApiEndpoints.bangumiAPIDomain}${ApiEndpoints.bangumiStaffByID}`,
      [`${id}`]);
    const text: string = await BangumiApi.getText(url);
    if (text.length === 0) {
      return [];
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(text) as Object;
    } catch (e) {
      return [];
    }
    if (!Array.isArray(parsed)) {
      return [];
    }
    const array: Object[] = parsed as Object[];
    const staffById: Map<number, StaffItem> = new Map<number, StaffItem>();
    const order: number[] = [];
    for (let i = 0; i < array.length; i++) {
      const rec: Record<string, Object> | null = JsonUtils.asObj(array[i]);
      if (rec === null) {
        continue;
      }
      const item: StaffItem = StaffItem.fromJson(rec);
      if (item.id <= 0) {
        continue;
      }
      let existing: StaffItem | undefined = staffById.get(item.id);
      if (existing === undefined) {
        existing = item;
        staffById.set(item.id, existing);
        order.push(item.id);
      }
      const relation: string = JsonUtils.str(rec, 'relation').trim();
      if (relation.length > 0 && !existing.relations.includes(relation)) {
        existing.relations.push(relation);
      }
    }
    const list: StaffItem[] = [];
    for (let i = 0; i < order.length; i++) {
      const item: StaffItem | undefined = staffById.get(order[i]);
      if (item === undefined) {
        continue;
      }
      item.relations.sort((a: string, b: string) => BangumiApi.staffPriorityOf(a) -
        BangumiApi.staffPriorityOf(b));
      list.push(item);
    }
    list.sort((a: StaffItem, b: StaffItem) => {
      const valueA: number = a.relations.length > 0
        ? BangumiApi.staffPriorityOf(a.relations[0]) : Number.MAX_SAFE_INTEGER;
      const valueB: number = b.relations.length > 0
        ? BangumiApi.staffPriorityOf(b.relations[0]) : Number.MAX_SAFE_INTEGER;
      return valueA - valueB;
    });
    return list;
  }

  /** 职务优先级（`StaffResponse._staffRelationPriority`）。 */
  private static staffPriorityOf(relation: string): number {
    const index: number = BangumiApi.staffRelationPriority.indexOf(relation);
    return index < 0 ? BangumiApi.staffRelationPriority.length : index;
  }

  private static readonly staffRelationPriority: string[] = [
    '动画制作', '原作', '总导演', '导演', '系列构成', '脚本', '人物设定',
    '总作画监督', '作画监督', '美术监督', '色彩设计', '音乐', '音响监督', '摄影监督'
  ];

  // ------------------------------------------------------------ 内部工具

  private static async getTextWithToken(url: string, token: string): Promise<string> {
    const response: ApiResponse = await ApiClient.apiDio().requestWith(url,
      http.RequestMethod.GET, undefined, BangumiApi.tokenHeaders(token));
    return response.ok ? response.body : '';
  }

  private static async postTextWithToken(url: string, body: string,
    token: string): Promise<string> {
    const response: ApiResponse = await ApiClient.apiDio().requestWith(url,
      http.RequestMethod.POST, body, BangumiApi.tokenHeaders(token));
    return response.ok ? response.body : '';
  }

  private static tokenHeaders(token: string): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['authorization'] = `Bearer ${token}`;
    headers['user-agent'] =
      'Predidit/Kazumi/1145.1.4 (Android) (https://github.com/Predidit/Kazumi)';
    return headers;
  }

  private static parseJson(text: string): Object | null {
    if (text.length === 0) {
      return null;
    }
    try {
      return JSON.parse(text) as Object;
    } catch (e) {
      return null;
    }
  }

  private static asObject(value: Object | null): Record<string, Object> | null {
    if (value === null || value === undefined || typeof value !== 'object' ||
      Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }
}
