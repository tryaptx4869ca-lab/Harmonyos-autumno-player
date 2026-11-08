import { ApiEndpoints } from '../request/config/ApiEndpoints';
import { ApiClient, ApiResponse } from '../request/core/ApiClient';
import { JsonUtils } from '../model/JsonUtils';
import { DanmakuEntry, DanmakuEpisodeResponse } from '../model/DanmakuModels';
import { DanmakuSearchAnime } from '../model/DanmakuModels';
import { Logger } from './Logger';
import { SettingsStore } from './storage/SettingsStore';
import { SettingsKeys } from './storage/SettingsKeys';
import { DanmakuCredentials } from './DanmakuCredentials';
import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const TAG: string = 'AutumnDanmakuApi';

/**
 * 弹幕接口。对应参照实现 `lib/request/apis/danmaku_api.dart`。
 *
 * 上游只实现了**弹弹play**这一条取弹幕的链路（BiliBili / Gamer 两个开关在
 * `player_item.dart` 里只用于**按来源过滤**，并不单独发请求），这里保持同样的边界。
 *
 * 请求走 `ApiClient.apiDio()`：它与其它接口共用代理与超时设置，
 * 且不会命中 Bangumi 镜像改写（那个拦截器只认 bgm 域名）。
 *
 * 与源码的差异：上游会用 `dandan_credentials`（CI 注入的 AppId/AppSecret）
 * 加鉴权头。原生工程没有这份凭据（也不该硬编码别人的），
 * 因此默认按「无凭据」分支发请求——而**无凭据现在会被服务器直接 403**
 * （2026-09-22 实测，官方文档也写明要 AppId/AppSecret，需向弹弹play 开发方申请）。
 * 凭据留了设置项（`danmakuDanDanAppId` / `danmakuDanDanAppSecret`），
 * 填上之后 `authHeaders()` 会自动带上，无需改代码。
 */
export class DanmakuApi {
  /** 「已知答案」签名自检是否已经跑过（每个进程只跑一次）。 */
  private static signerChecked: boolean = false;

  /**
   * GET + 解析。
   *
   * 上游会偶发抖动（实测同一个弹幕 URL 几分钟内先返回 200 + 2858 条、
   * 随后又返回 404），所以这里**失败重试一次**再放弃；
   * 否则用户看到的就是「有时候能加载、有时候加载不出来」。
   */
  private static async getJson(url: string): Promise<Object | null> {
    let lastStatus: number = 0;
    for (let attempt = 0; attempt < 2; attempt++) {
      const response: ApiResponse = await ApiClient.apiDio()
        .request(url, http.RequestMethod.GET, undefined,
          await DanmakuApi.authHeaders(url, attempt > 0));
      if (response.ok && response.body.length > 0) {
        return JSON.parse(response.body) as Object;
      }
      lastStatus = response.statusCode;
      if (attempt === 0) {
        await DanmakuApi.delay(400);
      }
    }
    throw new Error(`HTTP ${lastStatus}`);
  }

  /** 重试前的短暂等待（不占用事件循环的忙等）。 */
  private static async delay(ms: number): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /**
   * 弹弹play 鉴权请求头。
   *
   * 官方文档（`https://doc.dandanplay.com/open/`）给了两种模式，并**推荐签名模式**：
   *
   *   - **签名验证模式**（默认用这个）：
   *     `X-AppId` + `X-Timestamp` + `X-Signature`，
   *     其中 `X-Signature = base64(sha256(AppId + Timestamp + Path + AppSecret))`；
   *   - **凭证模式**（`useCredentialMode` 打开时用）：
   *     `X-AppId` + `X-AppSecret`，不需要算签名。
   *
   * 文档对三个细节说得很死，实现里逐条对齐：
   *   - `Timestamp` 是 **UTC 的 Unix 秒**（设备时间对不上就会验证失败）；
   *   - `Path` 是 **API 路径**，以 `/` 开头，**不含协议/域名，也不含 `?` 之后的查询串**
   *     （例子：`https://api.dandanplay.net/api/v2/comment/123450001?withRelated=true`
   *     → `/api/v2/comment/123450001`）；
   *   - 拼接顺序是 `AppId + Timestamp + Path + AppSecret`，区分大小写。
   *
   * 没配 AppId 时返回空对象——注意**空着请求必然 403**，所以调用方
   * （`DanmakuService`）在没有凭据时根本不会调到这儿。
   * 签名模式万一被拒（403 多来自时间戳漂移或密钥用错），
   * 重试那一轮会换成凭证模式，见 `getJson` 的 `attempt > 0`。
   */
  private static async authHeaders(url: string,
    useCredentialMode: boolean): Promise<Record<string, string>> {
    const headers: Record<string, string> = {};
    if (!DanmakuCredentials.usable()) {
      return headers;
    }
    const appId: string = DanmakuCredentials.appId();
    /**
     * 第一次带着凭据发请求时，跑一次「已知答案」自检（只跑一次）。
     * 结果会写进 hilog：`签名自检通过` / `签名自检失败 …`。
     */
    if (!DanmakuApi.signerChecked) {
      DanmakuApi.signerChecked = true;
      await DanmakuApi.verifySigner();
    }
    /**
     * 重试那一轮不仅换「凭证模式」，还会换成**备用密钥**（内置的两个之一）。
     * 万一主密钥被停用、而备用密钥还在，这一轮就能救回来。
     */
    const secret: string = useCredentialMode &&
      DanmakuCredentials.alternateSecret().length > 0
      ? DanmakuCredentials.alternateSecret()
      : DanmakuCredentials.primarySecret();
    headers['X-AppId'] = appId;
    if (useCredentialMode) {
      headers['X-AppSecret'] = secret;
      return headers;
    }
    const timestamp: string = `${Math.floor(Date.now() / 1000)}`;
    headers['X-Timestamp'] = timestamp;
    headers['X-Signature'] = await DanmakuApi.sign(
      appId, timestamp, DanmakuApi.pathOf(url), secret);
    return headers;
  }

  /**
   * 取 URL 的 **API 路径**（官方签名规则要的那一段）。
   *
   * `https://api.dandanplay.net/api/v2/comment/1?withRelated=true` → `/api/v2/comment/1`
   */
  private static pathOf(url: string): string {
    const schemeEnd: number = url.indexOf('://');
    const from: number = schemeEnd < 0 ? 0 : url.indexOf('/', schemeEnd + 3);
    if (from < 0) {
      return '/';
    }
    const query: number = url.indexOf('?', from);
    return query < 0 ? url.substring(from) : url.substring(from, query);
  }

  /** `base64(sha256(AppId + Timestamp + Path + AppSecret))`。 */
  private static async sign(appId: string, timestamp: string, path: string,
    secret: string): Promise<string> {
    const plain: string = `${appId}${timestamp}${path}${secret}`;
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new util.TextEncoder().encodeInto(plain) });
    const digest: cryptoFramework.DataBlob = await md.digest();
    return new util.Base64Helper().encodeToStringSync(digest.data);
  }

  // ---------------- 签名实现的「已知答案」自检 ----------------

  /**
   * 自检用的**假**样例（不是任何真实应用的凭据）。
   *
   * 期望值是用 Node 的标准 crypto 按官方公式算出来的：
   *   sha256('selftest' + '1700000000' + '/api/v2/comment/123450001' + 'selftest-secret')
   *     → base64 = `jjb9OxSFHSoNm3HP/D5AbMikmdgbFuZULQ6RBC0EqNk=`
   *
   * 为什么需要它：主机侧的探针（`tools/probe-dandan-auth.mjs`）用的是 Node 的
   * crypto，而设备上跑的是 `@kit.CryptoArchitectureKit` + `@kit.ArkTS` 的 Base64。
   * 这两条路只要有一条对不上（编码、摘要原始字节、大小写…），表现就是「凭据明明
   * 有效却一直 403」，而日志里看不出差别。跑一次这个自检就能把「实现问题」和
   * 「网络/凭据问题」分开——2026-09-24 加。
   */
  private static readonly SELF_TEST_APP_ID: string = 'selftest';
  private static readonly SELF_TEST_SECRET: string = 'selftest-secret';
  private static readonly SELF_TEST_TS: string = '1700000000';
  private static readonly SELF_TEST_PATH: string = '/api/v2/comment/123450001';
  private static readonly SELF_TEST_EXPECT: string =
    'jjb9OxSFHSoNm3HP/D5AbMikmdgbFuZULQ6RBC0EqNk=';

  /** 跑一次已知答案自检；返回是否与预期一致（同时写 hilog）。 */
  static async verifySigner(): Promise<boolean> {
    try {
      const actual: string = await DanmakuApi.sign(
        DanmakuApi.SELF_TEST_APP_ID, DanmakuApi.SELF_TEST_TS,
        DanmakuApi.SELF_TEST_PATH, DanmakuApi.SELF_TEST_SECRET);
      const ok: boolean = actual === DanmakuApi.SELF_TEST_EXPECT;
      Logger.info(TAG,
        `签名自检${ok ? '通过' : '失败'}：${actual}` +
          (ok ? '' : `（期望 ${DanmakuApi.SELF_TEST_EXPECT}）`));
      /**
       * 顺手验一下**内置凭据的解码**：base64 → UTF-8 要是坏了，
       * 表现同样是「签名一直不对」。这里只打长度与字符集，**不打密钥本身**。
       */
      const secret: string = DanmakuCredentials.primarySecret();
      const secretOk: boolean = /^[A-Za-z0-9]{32}$/.test(secret);
      Logger.info(TAG,
        `凭据自检${secretOk ? '通过' : '失败'}（长度 ${secret.length}，` +
          `来源 ${DanmakuCredentials.customized() ? '自定义' : '内置'}）`);
      return ok;
    } catch (error) {
      const err = error as Error;
      Logger.error(TAG, `签名自检异常：${err.message}`);
      return false;
    }
  }

  /** Bangumi 条目 id → 弹弹play 番剧 id（对应 `getDanDanBangumiIDByBgmBangumiID`）。 */
  static async bangumiIdByBgmId(bgmBangumiID: number): Promise<number> {
    const path: string = ApiEndpoints.formatUrl(
      ApiEndpoints.dandanAPIInfoByBgmBangumiId, [`${bgmBangumiID}`]);
    const url: string = `${ApiEndpoints.dandanAPIDomain}${path}`;
    const json: Object | null = await DanmakuApi.getJson(url);
    if (json === null) {
      return 0;
    }
    const rec: Record<string, Object> | null = JsonUtils.asObj(json);
    if (rec === null) {
      return 0;
    }
    const response: DanmakuEpisodeResponse = DanmakuEpisodeResponse.fromJson(rec);
    return response.bangumiId;
  }

  /** 番剧 id → 分集列表（对应 `getDanDanEpisodesByDanDanBangumiID`）。 */
  static async episodes(bangumiID: number): Promise<DanmakuEpisodeResponse> {
    const path: string = `${ApiEndpoints.dandanAPIInfo}${bangumiID}`;
    const url: string = `${ApiEndpoints.dandanAPIDomain}${path}`;
    const json: Object | null = await DanmakuApi.getJson(url);
    if (json === null) {
      return new DanmakuEpisodeResponse();
    }
    const rec: Record<string, Object> | null = JsonUtils.asObj(json);
    return rec === null ? new DanmakuEpisodeResponse()
      : DanmakuEpisodeResponse.fromJson(rec);
  }

  /**
   * 按作品标题搜弹弹play 的条目（**新版搜索引擎**）。
   *
   * 官方 2026-07-13 的 API 改动：`/api/v2/search/anime`、`/search/episodes`、
   * `/search/adv` 传 `?v2=true` 即切到新版引擎——官方原话是「更高质量的搜索结果、
   * 更好的分词效果以及响应速度」，默认 `false`，等稳定后会改默认开启。
   * （`/search/anime`、`/search/adv` 我们没用到，要用时同样带上 `v2=true`。）
   *
   * 用途：`bangumiIdByBgmId` 走的是「弹弹play 自己收录过的条目」那套映射，
   * 没收录就返回 0；这时用剧名搜一次能补上一部分缺口，
   * 调用方（`DanmakuService.searchDanDanIdByTitle`）会按标题相似度把关。
   */
  static async searchAnime(keyword: string): Promise<DanmakuSearchAnime[]> {
    const out: DanmakuSearchAnime[] = [];
    const trimmed: string = keyword.trim();
    if (trimmed.length < 2) {
      return out;
    }
    const url: string = `${ApiEndpoints.dandanAPIDomain}${ApiEndpoints.dandanAPISearchEpisodes}` +
      `?anime=${encodeURIComponent(trimmed)}&v2=true`;
    Logger.info(TAG, `搜索弹弹play 条目：${url}`);
    const body: Object | null = await DanmakuApi.getJson(url);
    if (body === null) {
      return out;
    }
    const rec: Record<string, Object> | null = JsonUtils.asObj(body);
    if (rec === null) {
      return out;
    }
    const animes: Object[] = JsonUtils.arr(rec, 'animes');
    for (let i = 0; i < animes.length; i++) {
      const item: Record<string, Object> | null = JsonUtils.asObj(animes[i]);
      if (item !== null) {
        out.push(DanmakuSearchAnime.fromJson(item));
      }
    }
    Logger.info(TAG, `搜索到 ${out.length} 个候选条目`);
    return out;
  }

  /**
   * 取某一集的弹幕（对应 `getDanDanmaku`）。
   *
   * 分集 id 的拼法是「番剧 id + 4 位补零的集数」（源码注释说明这是**推测**的规则，
   * 所以另外保留了按 episodeId 精确取的入口）。
   */
  static async danmaku(bangumiID: number, episode: number): Promise<DanmakuEntry[]> {
    if (bangumiID === 0) {
      return [];
    }
    const padded: string = DanmakuApi.pad4(episode);
    const path: string = `${ApiEndpoints.dandanAPIComment}${bangumiID}${padded}`;
    const url: string = `${ApiEndpoints.dandanAPIDomain}${path}?withRelated=true`;
    Logger.info(TAG, `请求弹幕：${url}`);
    return DanmakuApi.parseComments(await DanmakuApi.getJson(url));
  }

  /** 按分集 id 精确取弹幕（对应 `getDanDanmakuByEpisodeID`）。 */
  static async danmakuByEpisodeId(episodeID: number): Promise<DanmakuEntry[]> {
    const path: string = `${ApiEndpoints.dandanAPIComment}${episodeID}`;
    const url: string = `${ApiEndpoints.dandanAPIDomain}${path}?withRelated=true`;
    Logger.info(TAG, `请求弹幕（按分集 id）：${url}`);
    return DanmakuApi.parseComments(await DanmakuApi.getJson(url));
  }

  private static parseComments(json: Object | null): DanmakuEntry[] {
    const out: DanmakuEntry[] = [];
    if (json === null) {
      return out;
    }
    const rec: Record<string, Object> | null = JsonUtils.asObj(json);
    if (rec === null) {
      return out;
    }
    const comments: Object[] = JsonUtils.arr(rec, 'comments');
    for (let i = 0; i < comments.length; i++) {
      const item: Record<string, Object> | null = JsonUtils.asObj(comments[i]);
      if (item !== null) {
        out.push(DanmakuEntry.fromJson(item));
      }
    }
    return out;
  }

  /** 集数补零到 4 位（`episode.toString().padLeft(4, '0')`）。 */
  private static pad4(episode: number): string {
    const text: string = `${episode}`;
    return '0000'.substring(text.length) + text;
  }
}
