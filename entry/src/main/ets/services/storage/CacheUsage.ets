import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnStorage';

/** 一个顶层目录项的占用。 */
export class DirUsage {
  name: string = '';
  bytes: number = 0;
  isDirectory: boolean = false;

  constructor(name: string = '', bytes: number = 0, isDirectory: boolean = false) {
    this.name = name;
    this.bytes = bytes;
    this.isDirectory = isDirectory;
  }
}

/** 存储占用明细。 */
export class StorageUsage {
  /** cacheDir 总占用（可清理）。 */
  cacheBytes: number = 0;
  /** filesDir 总占用（用户数据：规则、收藏、搜索历史…）。 */
  dataBytes: number = 0;
  /** 应用数据库 + preferences 目录占用（系统管理，不在清理范围）。 */
  systemBytes: number = 0;
  cacheEntries: DirUsage[] = [];
  dataEntries: DirUsage[] = [];

  totalBytes(): number {
    return this.cacheBytes + this.dataBytes + this.systemBytes;
  }
}

/**
 * 缓存 / 数据占用统计。
 *
 * 「缓存大小」在参照实现里由 `StorageSettingsPage` 通过
 * `path_provider` 的 cache 目录递归求和得到；原生版直接用
 * `AbilityContext.cacheDir / filesDir / databaseDir` 递归求和，
 * 并额外给出顶层目录明细，便于在存储管理页解释每一块是什么。
 */
export class CacheUsage {
  static compute(context: common.UIAbilityContext): StorageUsage {
    const usage = new StorageUsage();
    usage.cacheEntries = CacheUsage.listEntries(context.cacheDir);
    usage.dataEntries = CacheUsage.listEntries(context.filesDir);
    usage.cacheBytes = CacheUsage.sum(usage.cacheEntries);
    usage.dataBytes = CacheUsage.sum(usage.dataEntries);
    usage.systemBytes = CacheUsage.dirSize(context.databaseDir);
    return usage;
  }

  /** 清空 cacheDir（保留目录本身）。返回释放的字节数。 */
  static clearCache(context: common.UIAbilityContext): number {
    const before: number = CacheUsage.dirSize(context.cacheDir);
    CacheUsage.removeChildren(context.cacheDir);
    hilog.info(DOMAIN, TAG, '清理缓存 %{public}d 字节', before);
    return before;
  }

  /** 递归求和（字节）。目录不存在或不可读时算 0。 */
  static dirSize(path: string): number {
    if (path.length === 0 || !fileIo.accessSync(path)) {
      return 0;
    }
    try {
      const stat = fileIo.statSync(path);
      if (!stat.isDirectory()) {
        return stat.size;
      }
    } catch (e) {
      return 0;
    }
    let total: number = 0;
    const names: string[] = CacheUsage.children(path);
    for (let i = 0; i < names.length; i++) {
      total += CacheUsage.dirSize(`${path}/${names[i]}`);
    }
    return total;
  }

  /** 顶层条目 + 各自占用，按占用从大到小。 */
  private static listEntries(path: string): DirUsage[] {
    const out: DirUsage[] = [];
    const names: string[] = CacheUsage.children(path);
    for (let i = 0; i < names.length; i++) {
      const child: string = `${path}/${names[i]}`;
      let isDir: boolean = false;
      try {
        isDir = fileIo.statSync(child).isDirectory();
      } catch (e) {
        continue;
      }
      out.push(new DirUsage(names[i], CacheUsage.dirSize(child), isDir));
    }
    return out.sort((a: DirUsage, b: DirUsage) => b.bytes - a.bytes);
  }

  private static sum(entries: DirUsage[]): number {
    let total: number = 0;
    for (let i = 0; i < entries.length; i++) {
      total += entries[i].bytes;
    }
    return total;
  }

  private static children(path: string): string[] {
    try {
      return fileIo.listFileSync(path);
    } catch (e) {
      return [];
    }
  }

  private static removeChildren(path: string): void {
    const names: string[] = CacheUsage.children(path);
    for (let i = 0; i < names.length; i++) {
      const child: string = `${path}/${names[i]}`;
      try {
        fileIo.rmdirSync(child);
      } catch (e) {
        try {
          fileIo.unlinkSync(child);
        } catch (inner) {
          hilog.warn(DOMAIN, TAG, '删除失败: %{public}s', child);
        }
      }
    }
  }

  /** 人类可读的占用文案（与参照实现的 `formatBytes` 同口径）。 */
  static formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    const kb: number = bytes / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB`;
    }
    const mb: number = kb / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(1)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
  }
}
