import { hilog } from '@kit.PerformanceAnalysisKit';
import { BangumiApi } from '../api/BangumiApi';
import { BangumiItem } from '../model/BangumiItem';
import { HistoryEntry, HistoryProgress, PlaybackHistoryIdentity } from '../model/HistoryModels';
import { HistoryRepository } from './HistoryRepository';
import { SettingsKeys } from './storage/SettingsKeys';
import { SettingsStore } from './storage/SettingsStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnSelf';

/**
 * 播放历史自检（阶段五）。
 *
 * 为什么需要它：模拟器上 libmpv 是桩实现，播不出画面也就不会有真实进度，
 * 于是「写了没写、去重对不对、快看完归零有没有生效」这些**无法靠肉眼**判断。
 * 这里把仓库的每条语义拉出来跑一遍并打日志（标签 `AutumnSelf`），
 * 与阶段 2 的 `Stage2SelfCheck` 同一套做法。
 *
 * `seedDemo()` 另外写三条可看的演示记录（用真实 Bangumi 条目），
 * 供历史页 / 推荐页「最近在看」/ 详情页「继续观看」三个界面取证。
 */
export class HistorySelfCheck {
  private static passCount: number = 0;
  private static failCount: number = 0;

  /** 仓库语义自检：跑完会把原有历史恢复回去。 */
  static run(): void {
    const backup: HistoryEntry[] = HistoryRepository.getAll();
    HistorySelfCheck.passCount = 0;
    HistorySelfCheck.failCount = 0;
    hilog.info(DOMAIN, TAG, '=== 播放历史自检开始（原有 %{public}d 条） ===',
      backup.length);

    HistoryRepository.clearAll();
    const item: BangumiItem = HistorySelfCheck.fakeItem(900001, '自检·测试番剧');
    const other: BangumiItem = HistorySelfCheck.fakeItem(900002, '自检·另一部番剧');

    // 1. 首次写入
    HistoryRepository.updateHistory(
      PlaybackHistoryIdentity.online(item, 'selfPlugin', 3, '第03集', 0,
        'https://example.com/detail/1', 'https://example.com/play/1-3'), 60000, 0);
    HistorySelfCheck.check('首次写入生成 1 条记录',
      HistoryRepository.getAll().length === 1,
      `实际 ${HistoryRepository.getAll().length}`);

    // 2. 同一 key 再写：不新增记录，进度被覆盖
    HistoryRepository.updateHistory(
      PlaybackHistoryIdentity.online(item, 'selfPlugin', 5, '第05集', 0,
        'https://example.com/detail/1', 'https://example.com/play/1-5'), 120000, 0);
    const afterSecond: HistoryEntry[] = HistoryRepository.getAll();
    const progress5 = afterSecond[0].progresses.get(5);
    HistorySelfCheck.check('同 key 覆盖不新增记录',
      afterSecond.length === 1, `实际 ${afterSecond.length}`);
    HistorySelfCheck.check('最后观看集数被更新为 5',
      afterSecond[0].lastWatchEpisode === 5,
      `实际 ${afterSecond[0].lastWatchEpisode}`);
    HistorySelfCheck.check('进度写入正确（120000ms）',
      progress5 !== undefined && progress5.progressMs === 120000,
      progress5 === undefined ? '没有第 5 集进度' : `实际 ${progress5.progressMs}`);

    // 3. 距结尾 5 秒内 → 归零（§60.2）
    HistoryRepository.updateHistory(
      PlaybackHistoryIdentity.online(item, 'selfPlugin', 6, '第06集', 0,
        'https://example.com/detail/1', 'https://example.com/play/1-6'),
      1436000, 1440000);
    const progress6 = HistoryRepository.getAll()[0].progresses.get(6);
    HistorySelfCheck.check('快看完（距结尾 4 秒）进度归零',
      progress6 !== undefined && progress6.progressMs === 0,
      progress6 === undefined ? '没有第 6 集进度' : `实际 ${progress6.progressMs}`);

    // 4. 来源区分：同插件同番剧的离线记录是另一条
    HistoryRepository.updateHistory(
      PlaybackHistoryIdentity.offline(item, 'selfPlugin', 2, '第02集', 0,
        'https://example.com/play/1-2'), 30000, 0);
    HistorySelfCheck.check('在线 / 缓存各算一条（共 2 条）',
      HistoryRepository.getAll().length === 2,
      `实际 ${HistoryRepository.getAll().length}`);

    // 5. 另一部番剧 + 时间倒序
    HistoryRepository.updateHistory(
      PlaybackHistoryIdentity.online(other, 'selfPlugin', 1, '第01集', 0,
        'https://example.com/detail/2', 'https://example.com/play/2-1'), 5000, 0);
    const sorted: HistoryEntry[] = HistoryRepository.getAll();
    HistorySelfCheck.check('按最后观看时间倒序',
      sorted.length === 3 && sorted[0].bangumiItem.id === 900002,
      `首条 id=${sorted.length > 0 ? sorted[0].bangumiItem.id : -1}`);

    // 6. 落盘 → 重新载入（进程重启后仍在）
    HistoryRepository.load();
    const reloaded: HistoryEntry[] = HistoryRepository.getAll();
    const resumed = reloaded[0].progresses.get(1);
    HistorySelfCheck.check('重新载入后条数不变（持久化）',
      reloaded.length === 3, `实际 ${reloaded.length}`);
    HistorySelfCheck.check('重新载入后进度仍可读（5000ms）',
      resumed !== undefined && resumed.progressMs === 5000,
      resumed === undefined ? '没有第 1 集进度' : `实际 ${resumed.progressMs}`);
    HistorySelfCheck.check('重新载入后条目字段完整（名称）',
      reloaded[0].bangumiItem.name === '自检·另一部番剧',
      `实际「${reloaded[0].bangumiItem.name}」`);

    // 7. 查询接口
    const found = HistoryRepository.findProgress(item, 'selfPlugin', 5, 'online');
    HistorySelfCheck.check('findProgress 命中第 5 集',
      found !== undefined && found.progressMs === 120000,
      found === undefined ? '未命中' : `实际 ${found.progressMs}`);
    const lastWatching = HistoryRepository.getLastWatchingProgress(
      item, 'selfPlugin', 'online');
    HistorySelfCheck.check('getLastWatchingProgress 取最后观看的那一集',
      lastWatching !== undefined && lastWatching.episode === 6,
      lastWatching === undefined ? '未命中' : `实际第 ${lastWatching.episode} 集`);

    // 8. 删除
    const toDelete: HistoryEntry = HistoryRepository.getAll()[0];
    HistoryRepository.deleteHistory(toDelete);
    HistorySelfCheck.check('删除一条后剩 2 条',
      HistoryRepository.getAll().length === 2,
      `实际 ${HistoryRepository.getAll().length}`);

    // 9. 隐私模式：开启后写入被跳过
    const previousPrivate: boolean = SettingsStore.getBool(SettingsKeys.privateMode);
    SettingsStore.put(SettingsKeys.privateMode, true);
    const beforePrivate: number = HistoryRepository.getAll().length;
    HistoryRepository.updateHistory(
      PlaybackHistoryIdentity.online(other, 'selfPlugin', 9, '第09集', 0,
        'https://example.com/detail/2', 'https://example.com/play/2-9'), 9999, 0);
    const afterPrivate: number = HistoryRepository.getAll().length;
    SettingsStore.put(SettingsKeys.privateMode, previousPrivate);
    HistorySelfCheck.check('隐私模式下不写入',
      afterPrivate === beforePrivate,
      `写入前 ${beforePrivate} 条，写入后 ${afterPrivate} 条`);

    // 10. 清空
    HistoryRepository.clearAll();
    HistorySelfCheck.check('清空后为 0 条',
      HistoryRepository.getAll().length === 0,
      `实际 ${HistoryRepository.getAll().length}`);

    // 恢复原有历史（用 upsert 原样写回：updateHistory 会把时间改成「现在」，
    // 那会破坏用户原有记录的排序，属于自检不该有的副作用）
    HistoryRepository.clearAll();
    for (let i = 0; i < backup.length; i++) {
      HistoryRepository.upsert(backup[i]);
    }
    hilog.info(DOMAIN, TAG,
      '=== 播放历史自检结束：%{public}d 通过 / %{public}d 失败 ===',
      HistorySelfCheck.passCount, HistorySelfCheck.failCount);
  }

  /**
   * 写三条演示记录（真实条目、真实封面），供界面取证。
   * 会先清空历史，属于「演示数据」而非用户数据，只在自检入口手动触发。
   */
  static async seedDemo(): Promise<void> {
    try {
      const items: BangumiItem[] = await BangumiApi.popular('', 3, 0);
      if (items.length === 0) {
        hilog.warn(DOMAIN, TAG, '演示数据创建失败：榜单为空');
        return;
      }
      HistoryRepository.clearAll();
      const now: number = Date.now();
      const day: number = 86400000;

      // 今天·在线·第 3 集看到 12:34
      HistoryRepository.updateHistory(
        PlaybackHistoryIdentity.online(items[0], '7sefun', 3, '第03集', 0,
          'https://www.7sefun.top/voddetail/26976.html',
          'https://www.7sefun.top/vodplay/26976-1-3.html'), 754000, 1440000);
      // 昨天·在线·第 8 集（快看完，进度归零）
      if (items.length > 1) {
        HistoryRepository.updateHistory(
          PlaybackHistoryIdentity.online(items[1], 'AGE', 8, '第08集', 1,
            'https://www.agedm.org/detail/20240001',
            'https://www.agedm.org/play/20240001-1-8'), 1439500, 1440000);
      }
      // 三天前·缓存·第 2 集看到 02:05
      HistoryRepository.updateHistory(
        PlaybackHistoryIdentity.offline(items[0], '7sefun', 2, '', 0,
          'https://www.7sefun.top/vodplay/26976-1-2.html'), 125000, 1440000);

      HistorySelfCheck.shiftTimes(now, day);
      hilog.info(DOMAIN, TAG, '演示历史已写入 %{public}d 条',
        HistoryRepository.getAll().length);
    } catch (error) {
      const err = error as Error;
      hilog.error(DOMAIN, TAG, '演示数据创建失败: %{public}s', err.message);
    }
  }

  /**
   * 把三条记录的时间摊到今天 / 昨天 / 三天前。
   *
   * `updateHistory` 一律写「现在」，而界面要按日分组，
   * 因此写完再按条目顺序回填时间（顺带验证「按 key 覆盖」这条路径）。
   */
  private static shiftTimes(now: number, day: number): void {
    const all: HistoryEntry[] = HistoryRepository.getAll();
    if (all.length < 2) {
      return;
    }
    const offlineFirst: boolean = all[0].entryKind === 'offline';
    const target: number[] = [
      now - 40 * 60 * 1000,
      now - day - 3 * 60 * 60 * 1000,
      now - 3 * day
    ];
    for (let i = 0; i < all.length && i < target.length; i++) {
      const entry: HistoryEntry = all[i];
      entry.lastWatchTime = target[i];
      entry.progresses.forEach((progress: HistoryProgress) => {
        progress.updatedAtMs = target[i];
      });
      HistoryRepository.upsert(entry);
    }
    hilog.info(DOMAIN, TAG, '演示时间摊平完成（缓存条目在前=%{public}s）',
      `${offlineFirst}`);
  }

  private static fakeItem(id: number, name: string): BangumiItem {
    const item = new BangumiItem();
    item.id = id;
    item.name = name;
    item.nameCn = name;
    item.airDate = '2026-01-01';
    return item;
  }

  private static check(name: string, ok: boolean, detail: string): void {
    if (ok) {
      HistorySelfCheck.passCount += 1;
      hilog.info(DOMAIN, TAG, '✅ %{public}s', name);
    } else {
      HistorySelfCheck.failCount += 1;
      hilog.error(DOMAIN, TAG, '❌ %{public}s（%{public}s）', name, detail);
    }
  }
}
