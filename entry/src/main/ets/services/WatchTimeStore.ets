import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Logger } from './Logger';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnWatchTime';
/** 落盘文件名（应用私有目录）。 */
const STORE_FILE: string = 'watch_time.json';
/** 两次落盘之间的最小间隔：播放中每 500ms 就可能 +0.5s，不能每次都写文件。 */
const FLUSH_INTERVAL_MS: number = 20000;
/** 少于这个秒数的「那天」不算数（避免点开一眼就被算成一天）。 */
const ACTIVE_DAY_SECONDS: number = 60;

/** 一天的观看时长。 */
export class WatchDay {
  /** `YYYY-MM-DD`（本地时区）。 */
  day: string = '';
  seconds: number = 0;
  /** 是不是「今天」。 */
  today: boolean = false;
}

/**
 * 观看时长（**真实播放秒数**，按天分桶）。
 *
 * ## 为什么单独存一份
 *
 * 播放历史里的 `progressMs` 是「**看到哪儿**」，不是「看了多久」：
 * 重看一遍会把它覆盖（时长被低估），往前拖进度又会让它虚高。
 * 「我的」页那张观看统计卡要显示观看时长，就只能另记一份——
 * 播放页每 500ms 采样一次播放位置，把**合理增量的那一部分**累加进来
 * （见 `VideoPage.accumulateWatchTime`：只认 0 < 增量 ≤ 2×轮询间隔×倍速，
 * 拖进度、暂停、回拖都不计）。
 *
 * ## 存储
 *
 * `${filesDir}/watch_time.json`：
 * ```
 * { "days": [ { "day": "2026-09-20", "seconds": 4632 } ] }
 * ```
 * 内存里累加、最多 20 秒落一次盘（外加退出播放页/切后台时的显式 flush）。
 * 与其它存储一样：读失败一律当空表，绝不让启动抛异常。
 */
export class WatchTimeStore {
  private static days: Map<string, number> = new Map<string, number>();
  private static filePath: string = '';
  private static loaded: boolean = false;
  /** 有未落盘的改动。 */
  private static dirty: boolean = false;
  private static lastFlushMs: number = 0;
  /** 变更版本号：页面订阅 `AppStorage.watchTimeRevision` 刷新（与历史同一套机制）。 */
  private static changeCount: number = 0;

  static init(context: common.UIAbilityContext): void {
    WatchTimeStore.filePath = `${context.filesDir}/${STORE_FILE}`;
    WatchTimeStore.load();
  }

  /** 累加一次真实观看秒数（<0 或非有限值直接忽略）。 */
  static addSeconds(seconds: number): void {
    if (!(seconds > 0) || seconds > 60) {
      // 单次采样超过 60 秒必然不是「连续播放」，当异常丢掉
      return;
    }
    WatchTimeStore.ensureLoaded();
    const key: string = WatchTimeStore.dayKey(Date.now());
    const current: number = WatchTimeStore.days.get(key) ?? 0;
    WatchTimeStore.days.set(key, current + seconds);
    WatchTimeStore.dirty = true;
    if (Date.now() - WatchTimeStore.lastFlushMs >= FLUSH_INTERVAL_MS) {
      WatchTimeStore.flush();
    }
  }

  /** 落盘（节流之外的显式调用点：离开播放页、切后台、应用销毁）。 */
  static flush(): void {
    if (!WatchTimeStore.dirty) {
      return;
    }
    const path: string = WatchTimeStore.filePath;
    if (path.length === 0) {
      return;
    }
    const entries: WatchDay[] = [];
    WatchTimeStore.days.forEach((seconds: number, day: string) => {
      const item = new WatchDay();
      item.day = day;
      item.seconds = Math.round(seconds);
      entries.push(item);
    });
    const root: Record<string, Object> = {};
    root['days'] = entries;
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(root));
      } finally {
        fileIo.closeSync(file);
      }
      WatchTimeStore.dirty = false;
      WatchTimeStore.lastFlushMs = Date.now();
      WatchTimeStore.changeCount += 1;
      AppStorage.setOrCreate('watchTimeRevision', WatchTimeStore.changeCount);
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '观看时长写入失败：%{public}s', err.message);
    }
  }

  /** 累计观看秒数（全部时间）。 */
  static totalSeconds(): number {
    WatchTimeStore.ensureLoaded();
    let total: number = 0;
    WatchTimeStore.days.forEach((seconds: number) => {
      total += seconds;
    });
    return Math.round(total);
  }

  /** 今天的观看秒数。 */
  static todaySeconds(nowMs: number = Date.now()): number {
    WatchTimeStore.ensureLoaded();
    return Math.round(WatchTimeStore.days.get(WatchTimeStore.dayKey(nowMs)) ?? 0);
  }

  /**
   * 最近 `count` 天（**从早到晚**，最后一个是今天），没记录的那天补 0。
   *
   * 卡片里的迷你柱状图直接用它——所以**顺序必须固定**，
   * 不能只返回有记录的天（那样柱子会「跳」）。
   */
  static lastDays(count: number, nowMs: number = Date.now()): WatchDay[] {
    WatchTimeStore.ensureLoaded();
    const total: number = count < 1 ? 1 : count;
    const out: WatchDay[] = [];
    const todayKey: string = WatchTimeStore.dayKey(nowMs);
    for (let i = total - 1; i >= 0; i--) {
      const dayMs: number = nowMs - i * 86400000;
      const key: string = WatchTimeStore.dayKey(dayMs);
      const item = new WatchDay();
      item.day = key;
      item.seconds = Math.round(WatchTimeStore.days.get(key) ?? 0);
      item.today = key === todayKey;
      out.push(item);
    }
    return out;
  }

  /** 最近 `count` 天的合计秒数（卡片里写「本周 x 小时 y 分」）。 */
  static recentSeconds(count: number, nowMs: number = Date.now()): number {
    const days: WatchDay[] = WatchTimeStore.lastDays(count, nowMs);
    let total: number = 0;
    for (let i = 0; i < days.length; i++) {
      total += days[i].seconds;
    }
    return total;
  }

  /**
   * 连续观看天数。
   *
   * 口径：今天算起（今天还没看就从昨天算起），往前连续数「有记录且 ≥ 1 分钟」的天。
   * 断一天就停——这是最常见的 streak 语义，也最不容易让用户觉得被骗。
   */
  static streakDays(nowMs: number = Date.now()): number {
    WatchTimeStore.ensureLoaded();
    let cursor: number = nowMs;
    if (WatchTimeStore.todaySeconds(nowMs) < ACTIVE_DAY_SECONDS) {
      // 今天还没怎么看：从昨天开始数（今天看了就自然从今天算）
      cursor = nowMs - 86400000;
    }
    let count: number = 0;
    while (count < 400) {
      const key: string = WatchTimeStore.dayKey(cursor);
      const seconds: number = WatchTimeStore.days.get(key) ?? 0;
      if (seconds < ACTIVE_DAY_SECONDS) {
        break;
      }
      count += 1;
      cursor -= 86400000;
    }
    return count;
  }

  /** 本地时区的 `YYYY-MM-DD`。 */
  private static dayKey(timestampMs: number): string {
    const date = new Date(timestampMs);
    const month: number = date.getMonth() + 1;
    const day: number = date.getDate();
    const monthText: string = month < 10 ? `0${month}` : `${month}`;
    const dayText: string = day < 10 ? `0${day}` : `${day}`;
    return `${date.getFullYear()}-${monthText}-${dayText}`;
  }

  private static ensureLoaded(): void {
    if (!WatchTimeStore.loaded) {
      WatchTimeStore.load();
    }
  }

  private static load(): void {
    WatchTimeStore.loaded = true;
    const path: string = WatchTimeStore.filePath;
    if (path.length === 0 || !fileIo.accessSync(path)) {
      return;
    }
    try {
      const stat = fileIo.statSync(path);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const read: number = fileIo.readSync(file.fd, buffer);
        text = new util.TextDecoder().decodeToString(new Uint8Array(buffer, 0, read));
      } finally {
        fileIo.closeSync(file);
      }
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const list: Object | undefined = root['days'];
      if (list === undefined || !Array.isArray(list)) {
        return;
      }
      const items: Object[] = list as Object[];
      for (let i = 0; i < items.length; i++) {
        const raw: Object = items[i];
        if (raw === undefined || raw === null || Array.isArray(raw)) {
          continue;
        }
        const rec: Record<string, Object> = raw as Record<string, Object>;
        const day: string = rec['day'] === undefined ? '' : `${rec['day']}`;
        const seconds: number = Number(rec['seconds']);
        if (day.length === 0 || Number.isNaN(seconds) || seconds <= 0) {
          continue;
        }
        WatchTimeStore.days.set(day, seconds);
      }
      Logger.info(TAG, `观看时长载入：${WatchTimeStore.days.size} 天`);
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '观看时长读取失败（按空处理）：%{public}s', err.message);
    }
  }
}
