import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnShutdown';

/**
 * 定时关闭。
 *
 * 逐条对齐参照实现 `lib/services/player/timed_shutdown_service.dart`：
 *   - `start(minutes, onExpired)` 先取消旧计时，再每秒递减；
 *   - 归零时先回调 `onExpired`（播放页用它暂停），再由页面弹「定时时间已到」；
 *   - `cancel()` 清零并复位「上次设置分钟数」以外的所有状态；
 *   - `repeatLast()` 对应对话框上的「重复」按钮。
 *
 * 与源码的差异：源码用 `ValueNotifier` 驱动菜单标题，
 * 原生侧改成 `AppStorage` 版本号（`timedShutdownRevision`），
 * 页面用 `@StorageProp` 订阅——与本项目其它「服务 → 视图」的通知方式一致。
 */
export class TimedShutdown {
  /** 视图订阅这个版本号来刷新「定时关闭 (mm:ss)」标题。 */
  static readonly REVISION_KEY: string = 'timedShutdownRevision';

  private static timer: number = -1;
  private static remaining: number = 0;
  private static minutes: number = 0;
  private static lastMinutes: number = 0;
  private static expiring: boolean = false;
  private static onExpired: () => void = () => {
  };

  static isActive(): boolean {
    return TimedShutdown.timer >= 0;
  }

  /** 剩余秒数。 */
  static remainingSeconds(): number {
    return TimedShutdown.remaining;
  }

  /** 本次设置的分钟数（0 表示未开启）。 */
  static setMinutes(): number {
    return TimedShutdown.minutes;
  }

  /** 上一次设置的分钟数，供「重复」使用。 */
  static lastSetMinutes(): number {
    return TimedShutdown.lastMinutes;
  }

  static start(minutes: number, onExpired: () => void): void {
    TimedShutdown.cancelInternal();
    if (minutes <= 0) {
      TimedShutdown.bump();
      return;
    }
    TimedShutdown.lastMinutes = minutes;
    TimedShutdown.minutes = minutes;
    TimedShutdown.remaining = minutes * 60;
    TimedShutdown.onExpired = onExpired;
    hilog.info(DOMAIN, TAG, '定时关闭已启动：%{public}d 分钟', minutes);
    TimedShutdown.timer = setInterval(() => {
      if (TimedShutdown.remaining > 0) {
        TimedShutdown.remaining--;
        TimedShutdown.bump();
      }
      if (TimedShutdown.remaining <= 0) {
        TimedShutdown.expire();
      }
    }, 1000);
    TimedShutdown.bump();
  }

  /** 重复上一次的时长（对话框上的「重复」）。 */
  static repeatLast(): boolean {
    const minutes: number = TimedShutdown.lastMinutes;
    if (minutes <= 0) {
      return false;
    }
    TimedShutdown.start(minutes, TimedShutdown.onExpired);
    return true;
  }

  static cancel(): void {
    if (TimedShutdown.timer >= 0) {
      hilog.info(DOMAIN, TAG, '定时关闭已取消');
    }
    TimedShutdown.cancelInternal();
    TimedShutdown.bump();
  }

  private static cancelInternal(): void {
    if (TimedShutdown.timer >= 0) {
      clearInterval(TimedShutdown.timer);
      TimedShutdown.timer = -1;
    }
    TimedShutdown.remaining = 0;
    TimedShutdown.minutes = 0;
  }

  private static expire(): void {
    TimedShutdown.cancelInternal();
    TimedShutdown.bump();
    try {
      TimedShutdown.onExpired();
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, 'onExpired 回调失败: %{public}s', err.message);
    }
    TimedShutdown.expiring = true;
    TimedShutdown.bump();
  }

  /** 页面取走「刚到期」这一次事件（取完即清，避免重复弹框）。 */
  static consumeExpired(): boolean {
    if (!TimedShutdown.expiring) {
      return false;
    }
    TimedShutdown.expiring = false;
    return true;
  }

  /** 剩余时间 mm:ss（菜单标题用）。 */
  static formatRemaining(): string {
    const total: number = TimedShutdown.remaining;
    if (total <= 0) {
      return '00:00';
    }
    const minutes: number = Math.floor(total / 60);
    const seconds: number = total % 60;
    const two = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${two(minutes)}:${two(seconds)}`;
  }

  /** 「1 小时 30 分钟」这种展示（对应 `formatMinutesToDisplay`）。 */
  static formatMinutes(totalMinutes: number): string {
    const hours: number = Math.floor(totalMinutes / 60);
    const minutes: number = totalMinutes % 60;
    if (hours > 0 && minutes > 0) {
      return `${hours} 小时 ${minutes} 分钟`;
    }
    if (hours > 0) {
      return `${hours} 小时`;
    }
    return `${minutes} 分钟`;
  }

  private static bump(): void {
    const current: number | undefined =
      AppStorage.get<number>(TimedShutdown.REVISION_KEY);
    AppStorage.setOrCreate(TimedShutdown.REVISION_KEY,
      (current === undefined ? 0 : current) + 1);
  }
}
