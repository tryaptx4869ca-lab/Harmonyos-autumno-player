import { SettingsStore } from './storage/SettingsStore';
import { SettingsKeys } from './storage/SettingsKeys';

/**
 * Bangumi 图片域名改写。
 *
 * 对应参照实现 lib/services/network/bangumi_image_url_rewriter.dart。
 *
 * 镜像接口返回的封面仍指向 `lain.bgm.tv`，该域名在部分网络下无法解析，
 * 因此统一改写为 `bgmimg.anibt.net` 图片镜像：
 *   https://lain.bgm.tv/pic/cover/l/43/ca/xxx.jpg
 *     -> https://bgmimg.anibt.net/r/600/pic/cover/l/43/ca/xxx.jpg
 * 卡片与详情页统一使用 600px 档，在清晰度与首屏下载量之间取平衡，也保证两端 URL
 * 完全相同（Hero 共享元素不能一边大图、一边缩略图）。
 *
 * 同时支持 api.bgm.tv 的条目图片：
 *   https://api.bgm.tv/v0/{subjects|characters|persons}/{id}/image
 */
class ParsedUrl {
  host: string = '';
  path: string = '';
  query: string = '';
}

export class BangumiImageUrlRewriter {
  /** Bangumi 封面专用镜像：实测首字节和完整下载均明显快于 wsrv。 */
  private static readonly coverMirrorBase: string = 'https://bgmimg.anibt.net';
  /** 兼容 `api.bgm.tv/.../image` 与表情图等无法直达的地址。 */
  private static readonly wsrvHost: string = 'wsrv.nl';
  private static readonly coverWidth: number = 600;

  /**
   * 按**当前设置**改写（渲染图片前调用）。
   *
   * ⚠️ 参照实现是在**取图时**统一改写的：它换掉了图片缓存层的
   * FileService（`proxy_aware_image_cache_manager.dart:30-42`），
   * 所以控件里存的是原始 URL 也没关系。
   * ArkUI 的 `Image()` 自己发请求、没有这层钩子，因此**凡是把 URL 交给
   * `Image()` 的地方都必须先过一次改写**——否则在解析不了 `lain.bgm.tv`
   * 的网络里就是「白框没图」（实测模拟器 DNS 失败，curl_code 6）。
   */
  static rewriteWithSettings(url: string): string {
    return BangumiImageUrlRewriter.rewrite(url,
      SettingsStore.getBool(SettingsKeys.enableBangumiProxy));
  }

  /* 2026-09-20 深夜回退记录：
   *
   * 这上面原来还有 `cardUrl(url, size)` / `thumbnail(url, size)` 两个方法，
   * 用来把封面降到 `lain.bgm.tv/r/{size}/…`（实测 229 KB → 57 KB / 17 KB），
   * 想省下卡片封面的流量。用户实测下来**反而更慢、甚至加载不出来**
   * （缩略档是站点/代理**现场生成**的，冷缓存首字节实测 0.8–3.3s），
   * 于是要求「改成之前发行版本的那种」——也就是**全部走原图 + 只有一层
   * wsrv 代理**，两个方法一并删掉。
   *
   * 另外缩略档还有个副作用：卡片和详情页海报的 URL 不同 → 共享元素飞行
   * 途中目标端没图可画（见 `HeroFlight` 的类注释）。
   *
   * 2026-10-22：使用 `bgmimg.anibt.net` 的 `/r/600/` 档。相比 400 档提高
   * 平板与详情页清晰度，同时仍比 800 档或原图明显更省流量。
   * 卡片、详情、历史、下载记录仍然都走同一 URL，不会破坏共享元素。
   */
  static rewrite(url: string, enabled: boolean): string {
    if (!enabled || url.length === 0) {
      return url;
    }
    /**
     * 本地图片（自建番剧的封面）**原样返回**。
     *
     * 它是沙箱里的 `file://` 路径，不是网络地址；一旦被当成待改写地址，
     * 会拼成 `https://wsrv.nl/?url=file://...` 这种必然 404 的串，卡片就是白块。
     */
    if (url.indexOf('http://') !== 0 && url.indexOf('https://') !== 0) {
      return url;
    }
    const parsed: ParsedUrl | null = BangumiImageUrlRewriter.parse(url);
    if (parsed === null) {
      return url;
    }
    if (!BangumiImageUrlRewriter.isMirrorable(parsed)) {
      return url;
    }
    if (parsed.host === 'lain.bgm.tv') {
      const coverPath: string =
        BangumiImageUrlRewriter.coverPath800(parsed.path);
      if (coverPath.length > 0) {
        return BangumiImageUrlRewriter.coverMirrorBase + coverPath +
          (parsed.query.length > 0 ? `?${parsed.query}` : '');
      }
    }
    let source: string = parsed.host + parsed.path;
    if (parsed.query.length > 0) {
      source += '?' + parsed.query;
    }
    let out: string =
      `https://${BangumiImageUrlRewriter.wsrvHost}/?url=${encodeURIComponent(source)}`;
    if (parsed.path.toLowerCase().endsWith('.gif')) {
      out += '&n=-1';
    }
    return out;
  }

  /**
   * 把 Bangumi 旧封面档位归一成镜像站支持的 `/r/800/pic/cover/l/...`。
   * `l/c/m/s/g` 都指向同一份原图，只换交付尺寸；旧地址也会先去掉已有限定。
   */
  private static coverPath800(path: string): string {
    let normalized: string = path;
    const sizedPrefix: RegExp = /^\/r\/\d+(?:x\d+)?(\/pic\/cover\/)/;
    normalized = normalized.replace(sizedPrefix, '$1');
    const legacyCover: RegExp = /^\/pic\/cover\/(?:l|c|m|s|g)(\/)/;
    if (!legacyCover.test(normalized)) {
      return '';
    }
    normalized = normalized.replace(legacyCover, '/pic/cover/l$1');
    return `/r/${BangumiImageUrlRewriter.coverWidth}${normalized}`;
  }

  private static isMirrorable(u: ParsedUrl): boolean {
    if (u.host === 'lain.bgm.tv') {
      return true;
    }
    // api.bgm.tv/v0/{subjects|characters|persons}/{id}/image
    if (u.host !== 'api.bgm.tv') {
      return false;
    }
    const segs: string[] = u.path.split('/').filter((s: string) => s.length > 0);
    if (segs.length !== 4 || segs[0] !== 'v0' || segs[3] !== 'image') {
      return false;
    }
    const kind: string = segs[1];
    const isKind: boolean =
      kind === 'subjects' || kind === 'characters' || kind === 'persons';
    const id: number = Number.parseInt(segs[2], 10);
    return isKind && !Number.isNaN(id) && id > 0;
  }

  /** 轻量解析：只取 scheme / host / path / query 四段。 */
  private static parse(url: string): ParsedUrl | null {
    const schemeEnd: number = url.indexOf('://');
    if (schemeEnd < 0) {
      return null;
    }
    const scheme: string = url.substring(0, schemeEnd).toLowerCase();
    if (scheme !== 'http' && scheme !== 'https') {
      return null;
    }
    const rest: string = url.substring(schemeEnd + 3);
    const slash: number = rest.indexOf('/');
    if (slash < 0) {
      return null;
    }
    const host: string = rest.substring(0, slash);
    if (host.length === 0) {
      return null;
    }
    let pathAndQuery: string = rest.substring(slash);
    let query: string = '';
    const q: number = pathAndQuery.indexOf('?');
    if (q >= 0) {
      query = pathAndQuery.substring(q + 1);
      pathAndQuery = pathAndQuery.substring(0, q);
    }
    const parsed = new ParsedUrl();
    parsed.host = host;
    parsed.path = pathAndQuery;
    parsed.query = query;
    return parsed;
  }
}
