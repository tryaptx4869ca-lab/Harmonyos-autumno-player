import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Plugin, pluginNameKey } from '../../plugins/Plugin';
import { PluginHttpItem } from '../../model/PluginHttpItem';
import { ApiEndpoints } from '../../request/config/ApiEndpoints';
import { remoteIsNewer } from '../../utils/VersionUtils';
import { PluginCatalogApi } from './PluginCatalogApi';
import { PluginManager } from './PluginManager';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnPlugin';

/** 目录条目相对本机的状态（源码 `PluginCatalogItemStatus`）。 */
export enum PluginCatalogItemStatus {
  /** 本地没有这条规则 */
  install = 0,
  /** 已安装且不落后于目录 */
  installed = 1,
  /** 已安装但目录里有更新 */
  update = 2
}

/** 单条规则的更新可用性（源码 `PluginUpdateAvailability`）。 */
export enum PluginUpdateAvailability {
  /** 目录还没加载过，无从判断 */
  unknown = 0,
  /** 目录里没有这条规则 */
  notInCatalog = 1,
  /** 已是最新 */
  latest = 2,
  /** 有更新 */
  updatable = 3
}

/** 单条更新结果（源码 `PluginUpdateResult`）。 */
export enum PluginUpdateResult {
  updated = 0,
  requiresNewerClient = 1,
  failed = 2,
  notNewer = 3
}

/** 批量更新统计（源码 `PluginBatchUpdateResult`）。 */
export class PluginBatchUpdateResult {
  readonly candidates: number;
  readonly updated: number;
  readonly requiresNewerClient: number;
  readonly failed: number;
  readonly notNewer: number;

  constructor(candidates: number, updated: number, requiresNewerClient: number,
    failed: number, notNewer: number) {
    this.candidates = candidates;
    this.updated = updated;
    this.requiresNewerClient = requiresNewerClient;
    this.failed = failed;
    this.notNewer = notNewer;
  }
}

/** 一次单条更新的中间产物。 */
class PluginUpdateAttempt {
  readonly result: PluginUpdateResult;
  readonly plugin: Plugin | null;

  constructor(result: PluginUpdateResult, plugin: Plugin | null) {
    this.result = result;
    this.plugin = plugin;
  }
}

/**
 * 规则仓库目录缓存 + 更新检查。
 * 对应参照实现 `lib/plugins/plugins_controller.dart` 的目录 / 更新部分
 * （源码把存储与目录混在一个 controller 里；原生版按职责切开：
 *   存储 → `PluginManager`，目录与更新 → 本类）。
 *
 * 逐条对齐的语义：
 *   - 目录缓存 **5 分钟**（`_pluginCatalogMaxAge`），显式刷新永远绕过缓存
 *   - 刷新**单飞**（`AsyncSingleFlight`）：并发调用只发一次请求
 *   - 更新时**校验规则名**，名字对不上直接判失败（防止下错文件写进规则表）
 *   - `api` 级别高于客户端 → `requiresNewerClient`，不写盘
 *   - **永不降级**：镜像可能落后上游，`notNewer` 就不覆盖本地
 *   - 批量下载并发上限 4（`_maxConcurrentRuleDownloads`）
 */
export class PluginUpdateService {
  private static readonly catalogMaxAgeMs: number = 5 * 60 * 1000;
  private static readonly maxConcurrentDownloads: number = 4;

  /** 最近一次成功加载的目录（顺序即展示顺序）。 */
  static readonly catalog: PluginHttpItem[] = [];
  private static catalogByName: Map<string, PluginHttpItem> =
    new Map<string, PluginHttpItem>();
  /** 0 表示从未加载成功过。 */
  private static refreshedAt: number = 0;
  /** 规则目录离线缓存文件。 */
  private static cachePath: string = '';
  /** 单飞句柄：非 null 表示有刷新在途。 */
  private static refreshing: Promise<PluginHttpItem[]> | null = null;

  /**
   * 载入上次成功获取的目录。
   *
   * 规则目录本身很小（当前约 5 KB），落盘后即使镜像/直连全部不可用，
   * 规则仓库页也能先展示已知条目，更新单个规则时再走网络。
   */
  static init(cachePath: string): void {
    PluginUpdateService.cachePath = cachePath;
    PluginUpdateService.loadCatalogCache();
  }

  static catalogIsLoaded(): boolean {
    return PluginUpdateService.refreshedAt > 0;
  }

  /** 目录是否还在有效期内（源码 `isPluginCatalogFresh`）。 */
  static catalogIsFresh(): boolean {
    return PluginUpdateService.refreshedAt > 0 &&
      Date.now() - PluginUpdateService.refreshedAt <
      PluginUpdateService.catalogMaxAgeMs;
  }

  /** 距上次刷新过了多久（毫秒）；从未刷新返回 -1。 */
  static catalogAgeMs(): number {
    return PluginUpdateService.refreshedAt === 0
      ? -1 : Date.now() - PluginUpdateService.refreshedAt;
  }

  /** 当前可用目录（内存 → 上次落盘缓存）。 */
  static currentCatalog(): PluginHttpItem[] {
    return PluginUpdateService.catalog.slice();
  }

  /**
   * 让当前目录立即过期但不丢弃它。
   * 修改自定义仓库或镜像开关后调用；下一次打开仓库会强制刷新，
   * 刷新失败时仍可显示旧目录。
   */
  static invalidateCatalogFreshness(): void {
    PluginUpdateService.refreshedAt = 0;
  }

  /** 强制刷新目录（单飞）。失败时 Promise 会 reject，与源码一致。 */
  static refreshCatalog(): Promise<PluginHttpItem[]> {
    const running: Promise<PluginHttpItem[]> | null = PluginUpdateService.refreshing;
    if (running !== null) {
      return running;
    }
    const task: Promise<PluginHttpItem[]> = PluginUpdateService.loadCatalog();
    PluginUpdateService.refreshing = task;
    return task;
  }

  private static async loadCatalog(): Promise<PluginHttpItem[]> {
    try {
      const items: PluginHttpItem[] = await PluginCatalogApi.getPluginList();
      PluginUpdateService.catalog.length = 0;
      const byName: Map<string, PluginHttpItem> = new Map<string, PluginHttpItem>();
      for (let i = 0; i < items.length; i++) {
        PluginUpdateService.catalog.push(items[i]);
        byName.set(pluginNameKey(items[i].name), items[i]);
      }
      PluginUpdateService.catalogByName = byName;
      PluginUpdateService.refreshedAt = Date.now();
      PluginUpdateService.saveCatalogCache();
      hilog.info(DOMAIN, TAG, '规则目录已刷新：%{public}d 条', items.length);
      return PluginUpdateService.catalog.slice();
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '刷新规则目录失败: %{public}s', err.message);
      throw err;
    } finally {
      PluginUpdateService.refreshing = null;
    }
  }

  /** 有效期内复用，否则刷新（源码 `ensurePluginCatalog`）。 */
  static async ensureCatalog(): Promise<PluginHttpItem[]> {
    if (PluginUpdateService.catalogIsFresh()) {
      return PluginUpdateService.catalog.slice();
    }
    return await PluginUpdateService.refreshCatalog();
  }

  /** 启动时检查：刷新目录并返回「可更新」条数（源码 `checkPluginUpdatesOnStartup`）。 */
  static async checkUpdatesOnStartup(enabled: boolean): Promise<number> {
    if (!enabled) {
      return 0;
    }
    await PluginUpdateService.refreshCatalog();
    return PluginUpdateService.updatableNames().length;
  }

  /** 目录条目相对本机的状态（规则商店列表用）。 */
  static catalogItemStatus(item: PluginHttpItem): PluginCatalogItemStatus {
    const installed: Plugin | null = PluginManager.find(item.name);
    if (installed === null) {
      return PluginCatalogItemStatus.install;
    }
    return remoteIsNewer(installed.version, item.version)
      ? PluginCatalogItemStatus.update : PluginCatalogItemStatus.installed;
  }

  /** 单条规则的更新可用性（规则列表用）。 */
  static updateAvailability(plugin: Plugin): PluginUpdateAvailability {
    if (!PluginUpdateService.catalogIsLoaded()) {
      return PluginUpdateAvailability.unknown;
    }
    const remote: PluginHttpItem | undefined =
      PluginUpdateService.catalogByName.get(pluginNameKey(plugin.name));
    if (remote === undefined) {
      return PluginUpdateAvailability.notInCatalog;
    }
    return remoteIsNewer(plugin.version, remote.version)
      ? PluginUpdateAvailability.updatable : PluginUpdateAvailability.latest;
  }

  /** 目录里那条规则的原始拼写（保留大小写，不按归一化键回写）。 */
  static catalogNameFor(name: string): string {
    const remote: PluginHttpItem | undefined =
      PluginUpdateService.catalogByName.get(pluginNameKey(name));
    return remote === undefined ? name : remote.name;
  }

  /** 更新一条（源码 `tryUpdatePluginByName`）。 */
  static async tryUpdateByName(name: string): Promise<PluginUpdateResult> {
    const catalogName: string = PluginUpdateService.catalogNameFor(name);
    const attempt: PluginUpdateAttempt =
      await PluginUpdateService.prepareUpdate(catalogName);
    if (attempt.result === PluginUpdateResult.updated && attempt.plugin !== null) {
      PluginManager.upsert(attempt.plugin);
    }
    return attempt.result;
  }

  /** 批量更新全部「可更新」的规则（源码 `tryUpdateAllPlugin`）。 */
  /**
   * 从规则目录**补齐未安装**的规则（规则商店「安装」语义）。
   * 更新语义见 `tryUpdateByName` / `tryUpdateAll`，这里只处理本地没有的那些。
   */
  static async installMissingFromCatalog(limit: number = 0):
    Promise<PluginBatchUpdateResult> {
    await PluginUpdateService.ensureCatalog();
    const names: string[] = [];
    for (let i = 0; i < PluginUpdateService.catalog.length; i++) {
      const item: PluginHttpItem = PluginUpdateService.catalog[i];
      if (PluginManager.find(item.name) === null) {
        names.push(item.name);
      }
    }
    const picked: string[] = limit > 0 && names.length > limit
      ? names.slice(0, limit) : names;
    const attempts: PluginUpdateAttempt[] =
      await PluginUpdateService.prepareUpdates(picked);
    let updated: number = 0;
    let requiresNewerClient: number = 0;
    let failed: number = 0;
    for (let i = 0; i < attempts.length; i++) {
      const result: PluginUpdateResult = attempts[i].result;
      const plugin: Plugin | null = attempts[i].plugin;
      if (result === PluginUpdateResult.updated && plugin !== null) {
        PluginManager.upsert(plugin);
        updated++;
      } else if (result === PluginUpdateResult.requiresNewerClient) {
        requiresNewerClient++;
      } else {
        failed++;
      }
    }
    return new PluginBatchUpdateResult(attempts.length, updated,
      requiresNewerClient, failed, attempts.length - updated -
      requiresNewerClient - failed);
  }

  static async tryUpdateAll(ensureCatalog: boolean = true):
    Promise<PluginBatchUpdateResult> {
    if (ensureCatalog) {
      await PluginUpdateService.ensureCatalog();
    } else if (!PluginUpdateService.catalogIsLoaded()) {
      throw new Error('规则目录尚未加载');
    }
    const names: string[] = PluginUpdateService.updatableNames();
    const attempts: PluginUpdateAttempt[] =
      await PluginUpdateService.prepareUpdates(names);
    let updated: number = 0;
    let requiresNewerClient: number = 0;
    let failed: number = 0;
    let notNewer: number = 0;
    for (let i = 0; i < attempts.length; i++) {
      const result: PluginUpdateResult = attempts[i].result;
      if (result === PluginUpdateResult.updated) {
        updated++;
        const plugin: Plugin | null = attempts[i].plugin;
        if (plugin !== null) {
          PluginManager.upsert(plugin);
        }
      } else if (result === PluginUpdateResult.requiresNewerClient) {
        requiresNewerClient++;
      } else if (result === PluginUpdateResult.notNewer) {
        notNewer++;
      } else {
        failed++;
      }
    }
    return new PluginBatchUpdateResult(attempts.length, updated,
      requiresNewerClient, failed, notNewer);
  }

  /** 按并发上限分批下载。 */
  private static async prepareUpdates(names: string[]): Promise<PluginUpdateAttempt[]> {
    const results: PluginUpdateAttempt[] = [];
    if (names.length === 0) {
      return results;
    }
    const limit: number = PluginUpdateService.maxConcurrentDownloads;
    for (let start = 0; start < names.length; start += limit) {
      const slice: string[] = names.slice(start, start + limit);
      const batch: Promise<PluginUpdateAttempt>[] = [];
      for (let i = 0; i < slice.length; i++) {
        batch.push(PluginUpdateService.prepareUpdate(slice[i]));
      }
      const done: PluginUpdateAttempt[] = await Promise.all(batch);
      for (let i = 0; i < done.length; i++) {
        results.push(done[i]);
      }
    }
    return results;
  }

  private static async prepareUpdate(name: string): Promise<PluginUpdateAttempt> {
    let remote: Plugin;
    try {
      remote = await PluginCatalogApi.getPlugin(name);
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '下载规则 %{public}s 失败: %{public}s',
        name, err.message);
      return new PluginUpdateAttempt(PluginUpdateResult.failed, null);
    }
    // 名字必须对得上：下错文件直接拒收，不要写进规则表
    if (remote.name.length === 0 ||
      pluginNameKey(remote.name) !== pluginNameKey(name)) {
      hilog.error(DOMAIN, TAG, '规则名不匹配：下载到 %{public}s，期望 %{public}s',
        remote.name, name);
      return new PluginUpdateAttempt(PluginUpdateResult.failed, null);
    }
    remote.name = name;
    if (remote.requiresNewerClient(ApiEndpoints.apiLevel)) {
      hilog.warn(DOMAIN, TAG, '规则 %{public}s 需要更新的客户端（api %{public}s > %{public}d）',
        name, remote.api, ApiEndpoints.apiLevel);
      return new PluginUpdateAttempt(PluginUpdateResult.requiresNewerClient, null);
    }
    const local: Plugin | null = PluginManager.find(name);
    // 永不降级：镜像可能落后于上游
    if (local !== null && !remoteIsNewer(local.version, remote.version)) {
      return new PluginUpdateAttempt(PluginUpdateResult.notNewer, null);
    }
    return new PluginUpdateAttempt(PluginUpdateResult.updated, remote);
  }

  private static updatableNames(): string[] {
    const out: string[] = [];
    const installed: Plugin[] = PluginManager.pluginList;
    for (let i = 0; i < installed.length; i++) {
      if (PluginUpdateService.updateAvailability(installed[i]) ===
        PluginUpdateAvailability.updatable) {
        const remote: PluginHttpItem | undefined =
          PluginUpdateService.catalogByName.get(pluginNameKey(installed[i].name));
        if (remote !== undefined) {
          out.push(remote.name);
        }
      }
    }
    return out;
  }

  private static loadCatalogCache(): void {
    const path: string = PluginUpdateService.cachePath;
    if (path.length === 0 || !fileIo.accessSync(path)) {
      return;
    }
    try {
      const stat = fileIo.statSync(path);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let raw: string = '';
      try {
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        const read: number = fileIo.readSync(file.fd, buffer);
        raw = new util.TextDecoder().decodeToString(new Uint8Array(buffer, 0, read));
      } finally {
        fileIo.closeSync(file);
      }
      const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const stamp: Object | undefined = parsed['refreshedAt'];
      const list: Object | undefined = parsed['items'];
      if (typeof stamp !== 'number' || !Array.isArray(list)) {
        return;
      }
      const items: PluginHttpItem[] = [];
      const byName: Map<string, PluginHttpItem> = new Map<string, PluginHttpItem>();
      const array: Object[] = list as Object[];
      for (let i = 0; i < array.length; i++) {
        const rec: Record<string, Object> | null =
          PluginUpdateService.asObject(array[i]);
        if (rec === null) {
          continue;
        }
        try {
          const item: PluginHttpItem = PluginHttpItem.fromJson(rec);
          items.push(item);
          byName.set(pluginNameKey(item.name), item);
        } catch (e) {
          // 单条坏缓存不阻断其余条目
        }
      }
      if (items.length === 0) {
        return;
      }
      PluginUpdateService.catalog.length = 0;
      for (let i = 0; i < items.length; i++) {
        PluginUpdateService.catalog.push(items[i]);
      }
      PluginUpdateService.catalogByName = byName;
      PluginUpdateService.refreshedAt = stamp as number;
      hilog.info(DOMAIN, TAG, '规则目录缓存已载入：%{public}d 条', items.length);
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '规则目录缓存读取失败: %{public}s', err.message);
    }
  }

  private static saveCatalogCache(): void {
    const path: string = PluginUpdateService.cachePath;
    if (path.length === 0) {
      return;
    }
    try {
      const items: Object[] = [];
      for (let i = 0; i < PluginUpdateService.catalog.length; i++) {
        items.push(PluginUpdateService.catalog[i].toJson());
      }
      const cache: Record<string, Object> = {};
      cache['refreshedAt'] = PluginUpdateService.refreshedAt;
      cache['items'] = items;
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(cache));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '规则目录缓存写入失败: %{public}s', err.message);
    }
  }

  private static asObject(value: Object | undefined): Record<string, Object> | null {
    if (value === undefined || value === null || typeof value !== 'object' ||
      Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }
}
