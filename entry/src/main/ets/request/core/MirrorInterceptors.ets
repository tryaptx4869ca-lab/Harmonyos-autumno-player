import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiEndpoints } from '../config/ApiEndpoints';
import { UrlParts } from './UrlParts';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnHttp';

/**
 * Bangumi 镜像凭据。
 *
 * 上游通过 `--dart-define=KAZUMI_APPID / KAZUMI_KEY` 在发布构建里注入；
 * 本地构建为空。为空时，受保护的接口（搜索、评论）走无需凭据的兼容镜像，
 * **这个分支行为必须保留**——否则本地构建会一律 401。
 */
export class BangumiMirrorCredentials {
  static readonly id: string = '';
  static readonly value: string = '';

  static get missing(): boolean {
    return BangumiMirrorCredentials.id.length === 0 ||
      BangumiMirrorCredentials.value.length === 0;
  }
}

/**
 * Bangumi 域名镜像。
 * 对应参照实现 `dio_factory.dart` 的 `_BangumiMirrorInterceptor`。
 *
 * 开启 `enableBangumiProxy` 后：
 *   api.bgm.tv / next.bgm.tv → api.kazumi.fyi
 * 没有镜像私钥且命中受保护路径（搜索、三类评论）时：
 *   → api.bgmapi.com（无需凭据）
 */
export class BangumiMirrorInterceptor {
  private static readonly mirrorableHosts: string[] = ['api.bgm.tv', 'next.bgm.tv'];

  static rewrite(url: string, method: string, enableBangumiProxy: boolean): string {
    if (!enableBangumiProxy) {
      return url;
    }
    const parts: UrlParts | null = UrlParts.parse(url);
    if (parts === null || BangumiMirrorInterceptor.mirrorableHosts.indexOf(parts.host) < 0) {
      return url;
    }
    if (BangumiMirrorCredentials.missing &&
      BangumiMirrorInterceptor.isProtectedRequest(parts.path, method)) {
      const fallback: string =
        ApiEndpoints.bangumiCompatibleDomain + parts.path +
          (parts.hasQuery ? `?${parts.query}` : '');
      hilog.debug(DOMAIN, TAG, 'Bangumi mirror(compatible): %{public}s', fallback);
      return fallback;
    }
    const mirrored: string =
      ApiEndpoints.bangumiMirrorDomain + parts.path +
        (parts.hasQuery ? `?${parts.query}` : '');
    hilog.debug(DOMAIN, TAG, 'Bangumi mirror: %{public}s', mirrored);
    return mirrored;
  }

  /** 需要镜像私钥的路径（源码 `_isProtectedBangumiMirrorRequest`）。 */
  static isProtectedRequest(path: string, method: string): boolean {
    if (method.toUpperCase() === 'POST' && path === '/v0/search/subjects') {
      return true;
    }
    const subjectComments: boolean =
      path.startsWith('/p1/subjects/') && path.endsWith('/comments');
    const episodeComments: boolean =
      path.startsWith('/p1/episodes/') && path.endsWith('/comments');
    const characterComments: boolean =
      path.startsWith('/p1/characters/') && path.endsWith('/comments');
    return subjectComments || episodeComments || characterComments;
  }

  /**
   * 镜像**降级**地址：主镜像（api.kazumi.fyi）整条路由不可用时，
   * 换兼容镜像（api.bgmapi.com）重试同一个 path + query。
   *
   * 为什么需要（2026-09-18 实测）：
   *   - `api.kazumi.fyi/v0/subjects/{id}` → **所有 id 都是 404**
   *     （`{"error":{"code":"not_found"}}`），而 `api.bgmapi.com` 正常；
   *   - `api.kazumi.fyi/p1/trending/subjects` 同样 404；
   *   - 同一时刻 `/v0/episodes`、`/kazumi/v1/popular/subjects` 还是好的，
   *     所以不是「镜像整体挂了」，而是**部分路由没了**。
   * 受影响的正是详情页：拿不到 `platform` / `info` → 「连载中 / 已完结」
   * 显示不出来（用户 2026-09-18：「从最近在看打开恋爱 FLOPS，连载中和
   * 完结也没有了，只有有的还在」——"还在"的那些是数据本来就带着字段的条目）。
   *
   * 只在主镜像上生效；已经是兼容镜像的地址返回 null（避免来回重试）。
   */
  static fallbackUrl(url: string): string | null {
    const parts: UrlParts | null = UrlParts.parse(url);
    if (parts === null) {
      return null;
    }
    /**
     * 主镜像上的地址 → 兼容镜像；
     *
     * 2026-09-19 追加：**官方域名上的地址也映射到兼容镜像**。
     *
     * 起因：调用方构造的都是官方地址（`api.bgm.tv/...`），镜像改写发生在
     * `ApiClient` 内部，失败后回到这里时 url 还是官方的——原来 host 不等于
     * `api.kazumi.fyi` 就直接 `null`，等于「这条兜底只对镜像地址生效」，
     * 官方地址发出去的请求根本没有第二跳。搜索就是这么死的：无凭据时它被
     * 改写到 `api.bgmapi.com`，而那个站现在整站 502。
     */
    if (parts.host !== 'api.kazumi.fyi' &&
      BangumiMirrorInterceptor.mirrorableHosts.indexOf(parts.host) < 0) {
      return null;
    }
    return ApiEndpoints.bangumiCompatibleDomain + parts.path +
      (parts.hasQuery ? `?${parts.query}` : '');
  }

  /**
   * 把任意 Bangumi 镜像地址还原成**官方地址**（`api.bgm.tv`）。
   *
   * 用途：镜像链路（主镜像 + 兼容镜像）都挂掉时的最后一跳——用
   * `ApiClient.apiDirectDio()` 直连官方，绕过镜像改写。
   * 不是 Bangumi 的路由（例如规则仓库、弹弹play）返回 null。
   */
  static officialUrl(url: string): string | null {
    const parts: UrlParts | null = UrlParts.parse(url);
    if (parts === null) {
      return null;
    }
    const known: boolean = parts.host === 'api.kazumi.fyi' ||
      parts.host === ApiEndpoints.bangumiCompatibleDomain.replace('https://', '') ||
      BangumiMirrorInterceptor.mirrorableHosts.indexOf(parts.host) >= 0;
    if (!known) {
      return null;
    }
    return ApiEndpoints.bangumiAPIDomain + parts.path +
      (parts.hasQuery ? `?${parts.query}` : '');
  }

  /** 这个状态码值不值得换兼容镜像再试一次。 */
  static shouldFallback(status: number): boolean {
    return status === 404 || status === 403 || status >= 500;
  }
}

/**
 * 规则仓库镜像。
 *
 * 运行时规则仓库按「镜像 → 备用镜像 → GitHub 直连」顺序尝试。
 * 这里只生成候选地址，由 `PluginCatalogApi` 根据 HTTP 结果逐个切换，
 * 这样 403 / 429 / 超时都能真正落到下一跳；单纯在拦截器里改写一次时，
 * 任一镜像失效就会表现为整个规则仓库一直加载不出来。
 */
export class RulesMirrorInterceptor {
  static rewrite(url: string, enableGitProxy: boolean): string {
    const candidates: string[] = RulesMirrorInterceptor.candidates(url, enableGitProxy);
    return candidates.length === 0 ? url : candidates[0];
  }

  /** 按可尝试顺序返回全部仓库地址。 */
  static candidates(url: string, enableGitProxy: boolean): string[] {
    if (!url.startsWith(ApiEndpoints.pluginShop)) {
      return [url];
    }
    const relative: string = url.substring(ApiEndpoints.pluginShop.length);
    const mirror: string = ApiEndpoints.pluginShopMirror + relative;
    const fallback: string = ApiEndpoints.pluginShopFallbackMirror + relative;
    const direct: string = url;
    if (!enableGitProxy) {
      return [direct, mirror, fallback];
    }
    const candidates: string[] = [mirror, fallback, direct];
    if (candidates[0].startsWith(ApiEndpoints.pluginShopMirror)) {
      hilog.debug(DOMAIN, TAG, 'Rules mirror candidates: %{public}s', candidates.join(' | '));
    }
    return candidates;
  }

}
