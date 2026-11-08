import { hilog } from '@kit.PerformanceAnalysisKit';
import { Plugin } from '../plugins/Plugin';
import { HistoryEntry, HistoryEntryKind, HistoryProgress } from '../model/HistoryModels';
import { Road } from '../model/SearchModels';
import { VideoRouteArgs } from '../router/RouteArgs';
import { PluginManager } from './plugin/PluginManager';
import { RuleChapterTrace, RuleEngine } from './plugin/RuleEngine';
import { Logger } from './Logger';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnHistoryPlay';

/** 解析结果：要么拿到可进播放页的参数，要么给出可读原因。 */
export class HistoryPlaybackResult {
  /** 是否解析成功。 */
  ok: boolean = false;
  /** 失败原因（直接给 Toast 用）。 */
  reason: string = '';
  /** 成功时的播放页参数。 */
  args: VideoRouteArgs | null = null;
}

/**
 * 从一条历史记录还原出播放参数。
 *
 * 对应参照实现 `lib/services/player/history_playback_service.dart`：
 * 历史页与「我的」页共用这一条解析路径，卡片自身不做源查找。
 *
 * 离线（缓存）分支要等下载管理器（§66）落地后再接——
 * 当前只处理在线记录，离线记录给出明确原因而不是静默失败。
 */
export class HistoryPlaybackService {
  static async open(entry: HistoryEntry): Promise<HistoryPlaybackResult> {
    Logger.info('AutumnHistory',
      `续播解析开始：src=${entry.lastSrc} adapter=${entry.adapterName}`);
    const result = new HistoryPlaybackResult();
    if (HistoryEntryKind.normalize(entry.entryKind) === HistoryEntryKind.offline) {
      result.reason = '未找到可用缓存';
      return result;
    }
    if (entry.lastSrc.length === 0) {
      result.reason = '在线源不可用，请重新选择播放源';
      return result;
    }
    const plugin: Plugin | null = PluginManager.find(entry.adapterName);
    if (plugin === null) {
      result.reason = '在线源不可用，请重新选择播放源';
      return result;
    }
    let roads: Road[] = [];
    try {
      const trace: RuleChapterTrace =
        await RuleEngine.queryChapters(plugin.executionConfig(), entry.lastSrc);
      roads = trace.roads;
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '查询线路失败（%{public}s）: %{public}s',
        entry.adapterName, err.message);
    }
    if (roads.length === 0) {
      Logger.info('AutumnHistory', '续播解析失败：线路为空（源站多半要验证码了）');
      result.reason = '在线源不可用，请重新选择播放源';
      return result;
    }

    const progress: HistoryProgress | undefined =
      entry.progresses.get(entry.lastWatchEpisode);
    const args = new VideoRouteArgs();
    args.bangumiItem = entry.bangumiItem;
    args.plugin = plugin;
    args.title = entry.displayName();
    args.src = entry.lastSrc;
    args.roads = roads;
    args.preferredEpisode = entry.lastWatchEpisode;
    args.preferredRoad = progress === undefined ? 0 : progress.road;
    result.ok = true;
    result.args = args;
    hilog.info(DOMAIN, TAG, '历史续播解析成功：%{public}s 第%{public}d集（%{public}d 条线路）',
      entry.displayName(), entry.lastWatchEpisode, roads.length);
    return result;
  }
}
