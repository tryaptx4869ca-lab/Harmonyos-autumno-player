import { HistoryEntry } from '../model/HistoryModels';

/**
 * 观看统计。对应参照实现 `lib/modules/my/watch_stats.dart`。
 *
 * 「我的」页顶部那两个数字不是简单的记录条数：
 *   - 看过番剧 = **去重后的番剧数**（同一部番从两个规则看过只算一部）
 *   - 观看集数 = **去重后的 (番剧, 集数) 对数**
 *     （同一集既在在线记录里又在缓存记录里，只算一集）
 *
 * 没有进度的记录（`progresses` 为空）不计入——源码同款判断。
 */
export class WatchStats {
  watchedEpisodeCount: number = 0;
  watchedBangumiCount: number = 0;

  static from(histories: HistoryEntry[]): WatchStats {
    const stats = new WatchStats();
    const bangumiIds: string[] = [];
    const episodeKeys: string[] = [];
    for (let i = 0; i < histories.length; i++) {
      const history: HistoryEntry = histories[i];
      if (history.progresses.size === 0) {
        continue;
      }
      const id: number = history.bangumiItem.id;
      if (bangumiIds.indexOf(`${id}`) < 0) {
        bangumiIds.push(`${id}`);
      }
      history.progresses.forEach((_value, episode: number) => {
        const key: string = `${id}-${episode}`;
        if (episodeKeys.indexOf(key) < 0) {
          episodeKeys.push(key);
        }
      });
    }
    stats.watchedBangumiCount = bangumiIds.length;
    stats.watchedEpisodeCount = episodeKeys.length;
    return stats;
  }
}
