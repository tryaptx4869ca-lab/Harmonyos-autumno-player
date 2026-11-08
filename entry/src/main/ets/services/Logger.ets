import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;

/**
 * 文件日志。对应参照实现 `services/logging/logger.dart`。
 *
 * 上游把日志写进 `<应用支持目录>/logs/kazumi_logs.log`，设置页的「存储与日志」
 * 与日志页都读这个文件。原生版此前只用 hilog（只进系统日志，应用自己读不到），
 * 因此这里补一个同样落盘的日志器——日志页才有内容可看、可复制、可清空。
 *
 * 与上游的差异（有意）：
 *   - 不做分级过滤面板，`level` 只影响写入的前缀（`E/W/I/D`）；
 *   - 单文件不轮转，超过 [maxBytes] 时**截掉前半**再续写，
 *     避免长期使用把沙箱撑满（上游由外部工具做轮转）。
 */
export class Logger {
  /** 单文件上限 1 MB（与同步日志分片阈值同一个量级）。 */
  private static readonly maxBytes: number = 1024 * 1024;
  private static dir: string = '';
  private static filePath: string = '';
  private static ready: boolean = false;

  static init(context: common.UIAbilityContext): void {
    Logger.dir = `${context.filesDir}/logs`;
    if (!fileIo.accessSync(Logger.dir)) {
      fileIo.mkdirSync(Logger.dir, true);
    }
    Logger.filePath = `${Logger.dir}/kazumi_logs.log`;
    Logger.ready = true;
    // 启动就落一行：日志页第一眼能看到「应用什么时候起的」，
    // 也让「日志文件存在但永远为空」这种状态不可能出现。
    Logger.info('AutumnLogs', '应用启动');
  }

  static path(): string {
    return Logger.filePath;
  }

  static write(level: string, tag: string, message: string): void {
    if (level === 'E') {
      hilog.error(DOMAIN, tag, '%{public}s', message);
    } else if (level === 'W') {
      hilog.warn(DOMAIN, tag, '%{public}s', message);
    } else {
      hilog.info(DOMAIN, tag, '%{public}s', message);
    }
    if (!Logger.ready) {
      return;
    }
    const line: string = `${Logger.timestamp()} ${level} [${tag}] ${message}\n`;
    try {
      Logger.rotateIfNeeded();
      Logger.appendLine(line);
    } catch (e) {
      // 写日志失败不能再抛：会把调用方的业务流程带崩。
      // 但要留下线索——否则「日志页永远是空的」会变成查不出的怪事。
      const err = e as Error;
      hilog.warn(DOMAIN, 'AutumnLogs', '写日志失败: %{public}s', err.message);
    }
  }

  /**
   * 追加一行。
   *
   * 为什么不用 `OpenMode.APPEND`：实测在应用沙箱里
   * `READ_WRITE | CREATE | APPEND` 会抛异常且被静默吞掉（日志文件压根没建出来），
   * 而工程里其它存储（收藏 / 搜索历史 / 规则表）走的都是
   * 「整读 → 拼 → TRUNC 整写」，那条路径是验证过的。
   */
  private static appendLine(line: string): void {
    let text: string = '';
    if (fileIo.accessSync(Logger.filePath)) {
      const stat = fileIo.statSync(Logger.filePath);
      if (stat.size > 0) {
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        const reader = fileIo.openSync(Logger.filePath, fileIo.OpenMode.READ_ONLY);
        try {
          const read: number = fileIo.readSync(reader.fd, buffer);
          text = new util.TextDecoder().decodeToString(
            new Uint8Array(buffer, 0, read));
        } finally {
          fileIo.closeSync(reader);
        }
      }
    }
    const file = fileIo.openSync(Logger.filePath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, text + line);
    } finally {
      fileIo.closeSync(file);
    }
  }

  static info(tag: string, message: string): void {
    Logger.write('I', tag, message);
  }

  static warn(tag: string, message: string): void {
    Logger.write('W', tag, message);
  }

  static error(tag: string, message: string): void {
    Logger.write('E', tag, message);
  }

  /** 读全部行（日志页的初始加载）。文件不存在返回空数组。 */
  static readLines(): string[] {
    if (!Logger.ready || !fileIo.accessSync(Logger.filePath)) {
      return [];
    }
    try {
      const stat = fileIo.statSync(Logger.filePath);
      if (stat.size === 0) {
        return [];
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const file = fileIo.openSync(Logger.filePath, fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const read: number = fileIo.readSync(file.fd, buffer);
        text = new util.TextDecoder().decodeToString(
          new Uint8Array(buffer, 0, read));
      } finally {
        fileIo.closeSync(file);
      }
      const raw: string[] = text.split('\n');
      const lines: string[] = [];
      for (let i = 0; i < raw.length; i++) {
        if (raw[i].length > 0) {
          lines.push(raw[i]);
        }
      }
      return lines;
    } catch (e) {
      return [];
    }
  }

  static clear(): void {
    if (!Logger.ready) {
      return;
    }
    try {
      const file = fileIo.openSync(Logger.filePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.closeSync(file);
      Logger.info('AutumnLogs', '日志已清空');
    } catch (e) {
      Logger.info('AutumnLogs', '清空日志失败');
    }
  }

  /** 日志文件占用的字节数（「存储与日志」页显示）。 */
  static usedBytes(): number {
    if (!Logger.ready || !fileIo.accessSync(Logger.filePath)) {
      return 0;
    }
    try {
      return fileIo.statSync(Logger.filePath).size;
    } catch (e) {
      return 0;
    }
  }

  private static rotateIfNeeded(): void {
    if (!fileIo.accessSync(Logger.filePath)) {
      return;
    }
    const size: number = fileIo.statSync(Logger.filePath).size;
    if (size <= Logger.maxBytes) {
      return;
    }
    const keep: string[] = Logger.readLines();
    const half: number = Math.floor(keep.length / 2);
    let text: string = '';
    for (let i = half; i < keep.length; i++) {
      text += `${keep[i]}\n`;
    }
    const file = fileIo.openSync(Logger.filePath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static timestamp(): string {
    const now = new Date();
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ` +
      `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
  }
}
