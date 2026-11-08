/**
 * 接口端点表。
 * 逐条移植自参照实现 `lib/request/config/api_endpoints.dart`。
 *
 * 说明：`version` 在 Flutter 侧来自 `--dart-define=KAZUMI_VERSION`，
 * 默认 `1145.1.4`；原生版先固定为同一默认值，阶段二接入构建期变量。
 */
export class ApiEndpoints {
  /** 当前版本。 */
  static readonly version: string = '1145.1.4';
  /** 规则 API 级别。 */
  static readonly apiLevel: number = 9;
  /** 项目主页。 */
  static readonly projectUrl: string = 'https://kazumi.app/';
  /** Github 项目主页。 */
  static readonly sourceUrl: string = 'https://github.com/ErBWs/Kazumi';
  /** 图标作者。 */
  static readonly iconUrl: string = 'https://www.pixiv.net/users/66219277';

  /** 规则仓库。 */
  static readonly pluginShop: string =
    'https://raw.githubusercontent.com/Predidit/KazumiRules/main/';
  /** 规则仓库镜像。 */
  static readonly pluginShopMirror: string =
    'https://gitcode.com/gh_mirrors/ka/KazumiRules/-/raw/main/';
  /**
   * 规则仓库备用镜像。
   *
   * GitCode 偶发 429 / 路由调整，GitHub raw 在部分大陆网络又会超时，
   * 因此保留一个能转发 raw 文件的备用入口；它只负责传输，规则内容仍来自
   * `Predidit/KazumiRules`。用户可以把自己的 Gitee 仓库填到网络设置里，
   * 自定义地址会排在所有内置地址之前。
   */
  static readonly pluginShopFallbackMirror: string =
    'https://gh-proxy.com/https://raw.githubusercontent.com/Predidit/KazumiRules/main/';

  /** 在线升级。 */
  static readonly latestApp: string =
    'https://api.github.com/repos/ErBWs/Kazumi/releases/latest';

  /** Bangumi 镜像测试后端。 */
  static readonly bangumiMirrorDomain: string = 'https://api.kazumi.fyi';
  /** Kazumi 镜像后端应用更新。 */
  static readonly latestAppMirror: string =
    'https://api.kazumi.fyi/kazumi/v1/app/latest?channel=ohos';

  /** 弹弹官网。 */
  static readonly dandanIndex: string = 'https://www.dandanplay.com/';
  /** Bangumi 官网。 */
  static readonly bangumiIndex: string = 'https://bangumi.tv/';
  /** bangumi API。 */
  static readonly bangumiAPIDomain: string = 'https://api.bgm.tv';
  /**
   * Bangumi 兼容镜像。没有 Kazumi 私钥时，评论 / 条目 / 搜索等接口
   * 从官方或 api.kazumi.fyi 回退到这里，避免 401 / DNS 不可达。
   */
  static readonly bangumiCompatibleDomain: string = 'https://api.bgmapi.com';
  /** Bangumi 鉴权 API。 */
  static readonly bangumiAuthAPIMirrorDomain: string = 'https://api.bgmapi.com';

  /** Telegram 群组。 */
  static readonly telegramGroup: string = 'https://t.me/kazumi_app';

  /** 番剧信息。 */
  static readonly bangumiInfoByID: string = '/v0/subjects/{0}';
  /** 条目关联信息。 */
  static readonly bangumiRelationsByID: string = '/v0/subjects/{0}/subjects';
  /** 条目搜索。 */
  static readonly bangumiRankSearch: string =
    '/v0/search/subjects?limit={0}&offset={1}';
  /** 从条目 ID 获取角色信息。 */
  static readonly bangumiCharacterByID: string = '/v0/subjects/{0}/characters';
  /** 从条目 ID 获取工作人员信息。 */
  static readonly bangumiStaffByID: string = '/v0/subjects/{0}/persons';
  /** 从条目 ID 获取剧集 ID。 */
  static readonly bangumiEpisodeByID: string = '/v0/episodes';
  /** 返回当前 Access Token 对应的用户信息。 */
  static readonly bangumiUsernameByToken: string = '/v0/me';
  /** 新增或修改用户单个条目收藏。 */
  static readonly bangumiSetCollection: string = '/v0/users/-/collections/{0}';
  /** 获取用户全部收藏（不限类型）。 */
  static readonly bangumiGetAllCollections: string =
    '/v0/users/{0}/collections?subject_type=2&limit={1}&offset={2}';

  /** Bangumi Next API Domain。 */
  static readonly bangumiAPINextDomain: string = 'https://next.bgm.tv';
  /** 每日放送。 */
  static readonly bangumiCalendar: string = '/p1/calendar';
  /** 番剧趋势。 */
  static readonly bangumiTrendsNext: string = '/p1/trending/subjects';
  /** Kazumi Bangumi 镜像缓存榜单。 */
  static readonly bangumiMirrorPopularSubjects: string =
    '/kazumi/v1/popular/subjects';
  /** Kazumi Bangumi 镜像季节时间表。 */
  static readonly bangumiMirrorSeasonCalendar: string = '/kazumi/v1/calendar/season';
  /** 番剧信息（next）。 */
  static readonly bangumiInfoByIDNext: string = '/p1/subjects/{0}';
  /** 番剧评论。 */
  static readonly bangumiCommentsByIDNext: string =
    '/p1/subjects/{0}/comments?limit={1}&offset={2}';
  /** 番剧剧集评论。 */
  static readonly bangumiEpisodeCommentsByIDNext: string =
    '/p1/episodes/{0}/comments';
  /** 番剧角色信息。 */
  static readonly bangumiCharacterInfoByCharacterIDNext: string =
    '/p1/characters/{0}';
  /** 番剧角色评论。 */
  static readonly bangumiCharacterCommentsByIDNext: string =
    '/p1/characters/{0}/comments';

  /** DanDanPlay API Domain。 */
  static readonly dandanAPIDomain: string = 'https://api.dandanplay.net';
  /** 获取弹幕。 */
  static readonly dandanAPIComment: string = '/api/v2/comment/';
  /** 检索弹弹番剧元数据。 */
  static readonly dandanAPISearchEpisodes: string = '/api/v2/search/episodes';
  /** 获取弹弹番剧元数据。 */
  static readonly dandanAPIInfo: string = '/api/v2/bangumi/';
  /** 获取弹弹番剧元数据（通过 BGM 番剧 ID）。 */
  static readonly dandanAPIInfoByBgmBangumiId: string = '/api/v2/bangumi/bgmtv/{0}';

  /** BiliBili API Domain。 */
  static readonly bilibiliAPIDomain: string = 'https://api.bilibili.com';
  /** BiliBili 网页域名，用来先取 buvid3 之类的会话 cookie。 */
  static readonly bilibiliWebDomain: string = 'https://www.bilibili.com';
  /**
   * BiliBili 设备指纹（返回 JSON 里的 `b_3` 就是 `buvid3`）。
   *
   * 为什么不用「先请求首页再读 Set-Cookie」：本工程的 `ApiResponse`
   * 不带响应头，拿不到 `Set-Cookie`。这个接口把同一个值放在 body 里，
   * 效果等价——实测没有 cookie 时搜索接口会被风控拦成 `HTTP 412`
   * （返回 HTML），补上 `buvid3` 后立刻是 `200 + code 0`。
   */
  static readonly bilibiliFingerSpi: string = '/x/frontend/finger/spi';
  /** BiliBili 番剧搜索。 */
  static readonly bilibiliSearchBangumi: string =
    '/x/web-interface/search/type?search_type=media_bangumi&keyword={0}';
  /**
   * BiliBili **影视**搜索（`media_ft`）。
   *
   * 剧场版 / 电影在哔哩哔哩属于「影视」而不是「番剧」，只搜 `media_bangumi`
   * 永远找不到它们 —— 实测《通往夏天的隧道，再见的出口》在 `media_ft` 里是
   * season 99556（`ep_size = 2`），而 `media_bangumi` 返回 0 条。
   * 找不到季就没有分集 `cid`，弹幕与集标题两条链路一起断（用户 2026-09-19：
   * 「通往夏天的隧道，B站上有原片，但弹幕只解析出 345 条」）。
   */
  static readonly bilibiliSearchMovie: string =
    '/x/web-interface/search/type?search_type=media_ft&keyword={0}';
  /** BiliBili 番剧季详情（包含分集列表）。 */
  static readonly bilibiliSeasonDetail: string =
    '/pgc/view/web/season?season_id={0}';
  /**
   * BiliBili 视频弹幕（XML，`{0}` = 分集 `cid`）。
   *
   * 响应体是**裸 DEFLATE 压缩**的 XML（见 `InflateRaw`），
   * 不能用普通 STRING 请求拿。
   */
  static readonly bilibiliDanmakuList: string =
    '/x/v1/dm/list.so?oid={0}';

  /** 图片识别番剧。 */
  static readonly traceApi: string = 'https://api.trace.moe/search';

  /** 把 `{0}` `{1}` 这类占位符替换成参数（源码 `formatUrl`）。 */
  static formatUrl(url: string, params: string[]): string {
    let out: string = url;
    for (let i = 0; i < params.length; i++) {
      out = out.replaceAll(`{${i}}`, params[i]);
    }
    return out;
  }
}
