import { hilog } from '@kit.PerformanceAnalysisKit';
import { BangumiItem } from '../model/BangumiItem';
import { BangumiApi } from '../api/BangumiApi';
import { ApiEndpoints } from './config/ApiEndpoints';
import { ApiClient, ApiResponse } from './core/ApiClient';
import { NetworkConfig } from './core/NetworkConfig';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnHttp';

/**
 * 网络层 + 数据模型自检。
 *
 * 目的：一次启动就能验证
 *   1. 请求能通（含镜像改写后的实际地址）
 *   2. 解析出的字段与上游 JSON 对得上（别名、票数分布、infobox 派生字段等）
 *
 * 这些字段大多是「解析时容易漏、漏了要到具体页面才暴露」的，
 * 因此单独打出来核对。
 *
 * ⚠️ **默认关闭**：启动时发网络请求同样会拖长冷启动，
 * 与 ThemeSelfCheck 一起跑会触发系统 ANR。需要复验时临时置 true。
 */
export class RequestSelfCheck {
  /** 是否在启动时执行。 */
  private static readonly enabled: boolean = false;

  static async run(): Promise<void> {
    if (!RequestSelfCheck.enabled) {
      return;
    }
    await RequestSelfCheck.checkPopular();
    await RequestSelfCheck.checkSubject();
  }

  /** 镜像榜单：验证列表解析 + 单条字段。 */
  private static async checkPopular(): Promise<void> {
    const list: BangumiItem[] = await BangumiApi.popular('', 2, 0);
    hilog.info(DOMAIN, TAG, 'SELF popular 返回 %{public}d 条', list.length);
    if (list.length === 0) {
      return;
    }
    RequestSelfCheck.dump('popular', list[0]);
  }

  /** v0 单品：字段最全，含 infobox 派生的 platform / endDate / 别名。 */
  private static async checkSubject(): Promise<void> {
    // 用榜单里出现的新条目：镜像只缓存新番，老条目（如 id=2）会 404
    const item: BangumiItem | null = await BangumiApi.getBangumiInfoByID(633836);
    if (item === null) {
      hilog.warn(DOMAIN, TAG, 'SELF subject(633836) 拉取失败');
      await RequestSelfCheck.probeDirect();
      return;
    }
    RequestSelfCheck.dump('subject/633836', item);
  }

  /**
   * 直连官方域名探针。
   *
   * 用途：镜像开启后详情接口走 api.kazumi.fyi，实测该域名对
   * `/v0/subjects/{id}` 与 `/p1/subjects/{id}` 都返回 404。
   * 这里绕过镜像直连 api.bgm.tv 对照一次，确认是「镜像侧不提供该路径」
   * 还是「本机网络出不去」，结论直接决定阶段 2 详情页该用哪个域名。
   */
  private static async probeDirect(): Promise<void> {
    const direct: ApiClient = ApiClient.createForConfig(NetworkConfig.fromSettings());
    // id 2 是冷门老条目，633836 是刚在榜单里出现的新条目——
    // 镜像若只是「缓存榜单」，两者表现会不同。
    const urls: string[] = [
      `${ApiEndpoints.bangumiAPIDomain}/v0/subjects/633836`,
      `${ApiEndpoints.bangumiAPINextDomain}/p1/subjects/633836`,
      `${ApiEndpoints.bangumiMirrorDomain}/v0/subjects/633836`,
      `${ApiEndpoints.bangumiMirrorDomain}/p1/subjects/633836`
    ];
    for (let i = 0; i < urls.length; i++) {
      const response: ApiResponse = await direct.get(urls[i]);
      hilog.info(DOMAIN, TAG, 'SELF probe %{public}s -> %{public}d ok=%{public}s len=%{public}d',
        urls[i], response.statusCode, `${response.ok}`, response.body.length);
    }
  }

  private static dump(source: string, item: BangumiItem): void {
    hilog.info(DOMAIN, TAG,
      'SELF %{public}s id=%{public}d type=%{public}d name=%{public}s nameCn=%{public}s',
      source, item.id, item.type, item.name, item.nameCn);
    hilog.info(DOMAIN, TAG,
      'SELF    airDate=%{public}s weekday=%{public}d rank=%{public}d score=%{public}s votes=%{public}d',
      item.airDate, item.airWeekday, item.rank,
      item.ratingScore.toFixed(1), item.votes);
    hilog.info(DOMAIN, TAG,
      'SELF    platform=%{public}s eps=%{public}s totalEps=%{public}s episodeCount=%{public}d endDate=%{public}s hasEnd=%{public}s countText=%{public}s',
      item.platform,
      item.eps === undefined ? 'null' : `${item.eps}`,
      item.totalEpisodes === undefined ? 'null' : `${item.totalEpisodes}`,
      item.episodeCount(),
      item.endDate === undefined ? 'null' : item.endDate,
      `${item.hasEndField}`, item.episodeCountText);
    hilog.info(DOMAIN, TAG,
      'SELF    tags=%{public}d alias=%{public}d votesCount=%{public}d metaTags=%{public}d interest=%{public}s',
      item.tags.length, item.alias.length, item.votesCount.length,
      item.metaTags.length, item.interest === undefined ? 'null' : 'ok');
    hilog.info(DOMAIN, TAG, 'SELF    cover=%{public}s', item.coverUrl());
    if (item.alias.length > 0) {
      hilog.info(DOMAIN, TAG, 'SELF    alias[0]=%{public}s', item.alias[0]);
    }
  }
}
