import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { JsonUtils } from '../../model/JsonUtils';
import { ApiClient, ApiResponse } from '../../request/core/ApiClient';
import { Logger } from '../Logger';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnAge';
/** 官方 App 的详情接口：里面有 `playlists`（每集一个解析 token）与 `player_jx`。 */
const DETAIL_API: string = 'https://api.agedm.io/v2/detail/';
/**
 * 详情缓存时长。
 *
 * 一次播放会话里连着切集不该把详情接口打爆；而 token 本身是**会过期**的
 * （解析页里带 `var Time = ...`），所以缓存不能太久——五分钟是个折中：
 * 正常追番节奏里切十集只请求一次，放一晚上再回来会重新取。
 */
const CACHE_TTL_MS: number = 5 * 60 * 1000;
/** 详情接口要求的 UA：它认移动端（PC 端 UA 拿到的是另一套字段语义）。 */
const MOBILE_UA: string =
  'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) '
    + 'Chrome/114.0.0.0 Mobile Safari/537.36';

/** 从 `/play/{aid}/{线路}/{集}` 里拆出来的定位信息。 */
class AgedmEpisodeRef {
  aid: string = '';
  line: number = 0;
  episode: number = 0;
}

/** 详情接口里「播放」需要的那部分。 */
class AgedmDetail {
  /**
   * 1 = 站点不给 PC 端播放（PC 播放页里只有「请下载APP」的占位）。
   * 实测：名侦探柯南 = 1、葬送的芙莉莲 = 0，与 PC 页面有没有播放器完全一致。
   */
  cpraid: number = 0;
  /** VIP 解析前缀（`player_jx.vip`）与普通解析前缀（`player_jx.zj`）。 */
  jxVip: string = '';
  jxZj: string = '';
  /** 线路 key（`qiyi` / `ffm3u8` …），顺序与 PC 播放页的线路标签一致。 */
  keys: string[] = [];
  /** `tokens[i][集号-1]` = 第 i 条线路第 n 集的解析 token。 */
  tokens: string[][] = [];
  /** 第 i 条线路是不是 VIP 线路（决定用哪个解析前缀）。 */
  vip: boolean[] = [];

  /** 第 `line` 条线路第 `episode` 集的解析播放页地址；取不到返回空串。 */
  episodeUrl(line: number, episode: number): string {
    if (line < 1 || episode < 1) {
      return '';
    }
    let seen: number = 0;
    for (let i = 0; i < this.keys.length; i++) {
      if (this.tokens[i].length === 0) {
        continue;
      }
      seen += 1;
      if (seen !== line) {
        continue;
      }
      if (episode > this.tokens[i].length) {
        return '';
      }
      const token: string = this.tokens[i][episode - 1];
      if (token.length === 0) {
        return '';
      }
      return `${this.vip[i] ? this.jxVip : this.jxZj}${token}`;
    }
    return '';
  }
}

/**
 * AGE（agedm.io）「PC 端不给播」的补救。
 *
 * ## 背景（2026-09-19 实测）
 *
 * 站点对**部分番剧**的 PC 播放页里根本不放播放器 —— 服务端只回一句
 * 「非常抱歉，由于视频版权或内容原因，暂不提供PC端播放，请下载APP进行观看」，
 * 于是取流宿主对着这个页面什么也嗅不到，用户看到的就是「解析不了」。
 * 例：`名侦探柯南`（aid 20000005）线路 1/2/3/6 的第 1271 集全是这样，
 * 而 `葬送的芙莉莲`（aid 20230207）同一套规则的 PC 页面里有正常播放器。
 *
 * 站点自己的 App 走的是另一条路：
 *
 * ```
 * GET https://api.agedm.io/v2/detail/{aid}
 *   → video.playlists: { qiyi: [["第1集","age_xxx"], …], ffm3u8: […], … }
 *   → player_jx: { vip: "https://jx.wuzhoupai.com:8443/vip/?url=",
 *                  zj:  "https://jx.wuzhoupai.com:8443/m3u8/?url=" }
 *   → 播放页 = 前缀 + token（线路在 player_vip 里就用 vip 前缀）
 * ```
 *
 * 实测拼出来的解析页里直接写着 `.m3u8`（非凡线路），我们原来的取流宿主
 * 嗅的就是这个地址，所以这条路能直接接上。
 *
 * ## 两条纪律
 *
 * 1. **只对 `cpraid = 1` 的番改写**。`cpraid = 0` 的番 PC 页面本来就有播放器，
 *    保持原地址——不能因为这次改动把原本正常的一批番带坏；
 * 2. **任何一步出问题都返回空串**（沿用原地址）。接口挂了、字段变了、
 *    集号越界……最坏也就是回到今天的行为，不会比现在更差。
 */
export class AgedmPlayback {
  private static cache: Map<string, AgedmDetail> = new Map<string, AgedmDetail>();
  private static cachedAt: Map<string, number> = new Map<string, number>();

  /**
   * 把 AGE 的 PC 播放页地址换成官方 App 的解析播放页地址。
   *
   * 返回空串表示「不用改，沿用传进来的地址」（非 AGE 规则、非播放页地址、
   * 该番 PC 端能播、或者接口没取到）。
   */
  static async resolve(pluginName: string, pageUrl: string): Promise<string> {
    if (pluginName.trim().toLowerCase() !== 'age') {
      return '';
    }
    const ref: AgedmEpisodeRef | null = AgedmPlayback.parseRef(pageUrl);
    if (ref === null) {
      return '';
    }
    const detail: AgedmDetail | null = await AgedmPlayback.detail(ref.aid);
    if (detail === null) {
      return '';
    }
    if (detail.cpraid !== 1) {
      return '';
    }
    const url: string = detail.episodeUrl(ref.line, ref.episode);
    if (url.length === 0) {
      hilog.warn(DOMAIN, TAG,
        'AGE 番 %{public}s 的 %{public}d 线第 %{public}d 集拿不到解析地址，沿用 PC 页面',
        ref.aid, ref.line, ref.episode);
      return '';
    }
    hilog.info(DOMAIN, TAG, 'AGE 改用官方 App 解析地址（%{public}s 第 %{public}d 线）：%{public}s',
      ref.aid, ref.line, url);
    Logger.info('AutumnAge',
      `AGE 走 App 解析：aid=${ref.aid} 线路=${ref.line} 集=${ref.episode}`);
    return url;
  }

  /** 清掉详情缓存（规则管理里改过站点、或用户手动重试时用得上）。 */
  static clearCache(): void {
    AgedmPlayback.cache.clear();
    AgedmPlayback.cachedAt.clear();
  }

  /** `/play/{aid}/{线路}/{集}` → 定位信息；不是这个形状返回 null。 */
  private static parseRef(pageUrl: string): AgedmEpisodeRef | null {
    const matched: RegExpMatchArray | null = pageUrl.match(/\/play\/(\d+)\/(\d+)\/(\d+)/);
    if (matched === null) {
      return null;
    }
    const ref = new AgedmEpisodeRef();
    ref.aid = matched[1];
    ref.line = Number.parseInt(matched[2], 10);
    ref.episode = Number.parseInt(matched[3], 10);
    if (Number.isNaN(ref.line) || Number.isNaN(ref.episode)) {
      return null;
    }
    return ref;
  }

  /** 取（并缓存）详情。失败返回 null，由调用方按「不改写」处理。 */
  private static async detail(aid: string): Promise<AgedmDetail | null> {
    const cached: AgedmDetail | undefined = AgedmPlayback.cache.get(aid);
    const cachedAt: number = AgedmPlayback.cachedAt.get(aid) ?? 0;
    if (cached !== undefined && Date.now() - cachedAt < CACHE_TTL_MS) {
      return cached;
    }
    const headers: Record<string, string> = {};
    headers['user-agent'] = MOBILE_UA;
    headers['referer'] = 'https://m.agedm.io/';
    try {
      const response: ApiResponse = await ApiClient.pluginDio()
        .requestWith(`${DETAIL_API}${aid}`, http.RequestMethod.GET, undefined, headers);
      if (!response.ok) {
        hilog.warn(DOMAIN, TAG, 'AGE 详情接口 HTTP %{public}d（aid %{public}s）',
          response.statusCode, aid);
        return null;
      }
      const parsed: AgedmDetail | null = AgedmPlayback.parseDetail(response.body);
      if (parsed === null) {
        hilog.warn(DOMAIN, TAG, 'AGE 详情接口返回了认不出的结构（aid %{public}s）', aid);
        return null;
      }
      AgedmPlayback.cache.set(aid, parsed);
      AgedmPlayback.cachedAt.set(aid, Date.now());
      return parsed;
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, 'AGE 详情接口请求失败：%{public}s', err.message);
      return null;
    }
  }

  /** 解析详情 JSON；结构对不上返回 null。 */
  private static parseDetail(raw: string): AgedmDetail | null {
    let root: Record<string, Object>;
    try {
      root = JSON.parse(raw) as Record<string, Object>;
    } catch (error) {
      return null;
    }
    const video: Record<string, Object> | null = JsonUtils.obj(root, 'video');
    if (video === null) {
      return null;
    }
    const playlists: Record<string, Object> | null = JsonUtils.obj(video, 'playlists');
    if (playlists === null) {
      return null;
    }
    const detail = new AgedmDetail();
    detail.cpraid = JsonUtils.intOf(video, 'cpraid');
    const jx: Record<string, Object> | null = JsonUtils.obj(root, 'player_jx');
    detail.jxVip = jx === null ? '' : JsonUtils.str(jx, 'vip');
    detail.jxZj = jx === null ? '' : JsonUtils.str(jx, 'zj');
    if (detail.jxVip.length === 0 && detail.jxZj.length === 0) {
      return null;
    }
    const vipNames: string[] = JsonUtils.str(root, 'player_vip').split(',');
    const keys: string[] = Object.keys(playlists);
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      const rawList: Object | undefined = playlists[key];
      if (rawList === undefined || !Array.isArray(rawList)) {
        continue;
      }
      const episodes: Object[] = rawList as Object[];
      const tokens: string[] = [];
      for (let e = 0; e < episodes.length; e++) {
        const entry: Object = episodes[e];
        if (!Array.isArray(entry)) {
          tokens.push('');
          continue;
        }
        const fields: Object[] = entry as Object[];
        // 每集是 [集名, token]：token 在第二位
        tokens.push(fields.length >= 2 ? `${fields[1]}` : '');
      }
      let usable: boolean = false;
      for (let t = 0; t < tokens.length; t++) {
        if (tokens[t].length > 0) {
          usable = true;
          break;
        }
      }
      if (!usable) {
        continue;
      }
      detail.keys.push(key);
      detail.tokens.push(tokens);
      detail.vip.push(vipNames.indexOf(key) >= 0);
    }
    return detail.keys.length === 0 ? null : detail;
  }
}
