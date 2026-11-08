import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Plugin, pluginNameKey } from '../../plugins/Plugin';
import { JsonUtils } from '../../model/JsonUtils';
import { PluginPatches } from './PluginPatches';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnPlugin';

/**
 * 插件（规则）管理器。
 * 对应参照实现 `lib/plugins/plugins_controller.dart` 的存储部分。
 *
 * 落盘布局与源码一致：
 *   `${filesDir}/plugins/`        旧版：一条规则一个 json
 *   `${filesDir}/plugins/v2/plugins.json`  当前：整表一个文件
 * 首次启动若只有旧目录，会做一次迁移再写回 v2（对应 `_loadAllPlugins`）。
 *
 * 与源码的差异：源码会把 `assets/plugins/*.json` 的内置规则拷进来；
 * 原生版不带内置规则，改为从规则仓库目录按需下载（见 PluginCatalogApi）。
 */
export class PluginManager {
  /** 当前规则表（顺序即展示顺序）。 */
  static readonly pluginList: Plugin[] = [];
  private static v2Dir: string = '';
  private static oldDir: string = '';

  static init(context: common.UIAbilityContext): void {
    PluginManager.oldDir = `${context.filesDir}/plugins`;
    PluginManager.v2Dir = `${PluginManager.oldDir}/v2`;
    PluginManager.ensureDir(PluginManager.oldDir);
    PluginManager.ensureDir(PluginManager.v2Dir);
    PluginManager.loadAll();
  }

  private static ensureDir(path: string): void {
    if (!fileIo.accessSync(path)) {
      fileIo.mkdirSync(path, true);
    }
  }

  /** 读取规则表；没有 v2 文件时从旧目录迁移。 */
  static loadAll(): void {
    PluginManager.pluginList.length = 0;
    const listFile: string = `${PluginManager.v2Dir}/plugins.json`;
    if (fileIo.accessSync(listFile)) {
      PluginManager.addAllFromJson(PluginManager.readFile(listFile));
      hilog.info(DOMAIN, TAG, '规则载入 %{public}d 条', PluginManager.pluginList.length);
      // 内置补丁：站点改版后仓库规则会失效，这里在载入后立刻修正
      if (PluginPatches.applyAll(PluginManager.pluginList) > 0) {
        PluginManager.save();
      }
      return;
    }
    // 旧格式迁移：plugins/*.json 逐条读入后删除，再写回 v2
    const names: string[] = PluginManager.listJsonFiles(PluginManager.oldDir);
    for (let i = 0; i < names.length; i++) {
      const path: string = `${PluginManager.oldDir}/${names[i]}`;
      try {
        PluginManager.addOneFromJson(PluginManager.readFile(path));
        fileIo.unlinkSync(path);
      } catch (e) {
        const err = e as Error;
        hilog.warn(DOMAIN, TAG, '迁移规则失败 %{public}s: %{public}s', names[i], err.message);
      }
    }
    if (names.length > 0) {
      PluginManager.save();
      hilog.info(DOMAIN, TAG, '从旧目录迁移 %{public}d 条规则', names.length);
    }
    if (PluginPatches.applyAll(PluginManager.pluginList) > 0) {
      PluginManager.save();
    }
  }

  /** 整表写回。 */
  static save(): void {
    const array: Object[] = [];
    for (let i = 0; i < PluginManager.pluginList.length; i++) {
      array.push(PluginManager.pluginList[i].toJson());
    }
    const path: string = `${PluginManager.v2Dir}/plugins.json`;
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(array));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '保存规则失败: %{public}s', err.message);
    }
  }

  /** 新增或覆盖（按名字归一化去重，对应 `_replacePlugin`）。 */
  static upsert(plugin: Plugin): void {
    // 从仓库下载 / 手动导入的规则同样要过一遍补丁
    PluginPatches.apply(plugin);
    const key: string = pluginNameKey(plugin.name);
    for (let i = 0; i < PluginManager.pluginList.length; i++) {
      if (pluginNameKey(PluginManager.pluginList[i].name) === key) {
        PluginManager.pluginList[i] = plugin;
        PluginManager.save();
        return;
      }
    }
    PluginManager.pluginList.push(plugin);
    PluginManager.save();
  }

  static remove(name: string): void {
    const key: string = pluginNameKey(name);
    for (let i = PluginManager.pluginList.length - 1; i >= 0; i--) {
      if (pluginNameKey(PluginManager.pluginList[i].name) === key) {
        PluginManager.pluginList.splice(i, 1);
      }
    }
    PluginManager.save();
  }

  /**
   * 调整规则顺序（规则列表的「上移 / 下移」）。
   *
   * 顺序有意义：搜索时按这个顺序依次询问各站点，用户把常用的放前面能更快出结果
   * （源码注释同此意，列表页也写着「拖动调整搜索顺序」）。
   */
  static move(from: number, to: number): boolean {
    const count: number = PluginManager.pluginList.length;
    if (from < 0 || from >= count || to < 0 || to >= count || from === to) {
      return false;
    }
    const moved: Plugin = PluginManager.pluginList[from];
    PluginManager.pluginList.splice(from, 1);
    PluginManager.pluginList.splice(to, 0, moved);
    PluginManager.save();
    return true;
  }

  /** 批量删除（规则列表的「多选 → 删除所选」）。返回实际删除的条数。 */
  static removeAll(names: string[]): number {
    if (names.length === 0) {
      return 0;
    }
    const keys: string[] = [];
    for (let i = 0; i < names.length; i++) {
      keys.push(pluginNameKey(names[i]));
    }
    let removed: number = 0;
    for (let i = PluginManager.pluginList.length - 1; i >= 0; i--) {
      if (keys.indexOf(pluginNameKey(PluginManager.pluginList[i].name)) >= 0) {
        PluginManager.pluginList.splice(i, 1);
        removed += 1;
      }
    }
    if (removed > 0) {
      PluginManager.save();
    }
    return removed;
  }

  static find(name: string): Plugin | null {
    const key: string = pluginNameKey(name);
    for (let i = 0; i < PluginManager.pluginList.length; i++) {
      if (pluginNameKey(PluginManager.pluginList[i].name) === key) {
        return PluginManager.pluginList[i];
      }
    }
    return null;
  }

  /** 规则仓库目录的离线缓存路径（与已安装规则一起放在应用持久目录）。 */
  static catalogCachePath(): string {
    return `${PluginManager.v2Dir}/catalog-cache.json`;
  }

  /** 批量导入（同名的覆盖），返回实际新增 / 覆盖的条数。 */
  static importAll(plugins: Plugin[]): number {
    for (let i = 0; i < plugins.length; i++) {
      PluginManager.upsert(plugins[i]);
    }
    return plugins.length;
  }

  // ------------------------------------------------------------ 内部

  private static addAllFromJson(raw: string): void {
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) {
        hilog.warn(DOMAIN, TAG, '规则表不是数组，忽略');
        return;
      }
      const array: Object[] = parsed as Object[];
      for (let i = 0; i < array.length; i++) {
        PluginManager.addOneFromJson(JSON.stringify(array[i]));
      }
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '规则表解析失败: %{public}s', err.message);
    }
  }

  private static addOneFromJson(raw: string): void {
    const parsed: Object = JSON.parse(raw) as Object;
    const rec: Record<string, Object> | null = JsonUtils.asObj(parsed);
    if (rec === null) {
      return;
    }
    PluginManager.pluginList.push(Plugin.fromJson(rec));
  }

  private static readFile(path: string): string {
    const stat = fileIo.statSync(path);
    const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const read: number = fileIo.readSync(file.fd, buffer);
      return bufferToString(buffer, read);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static listJsonFiles(dir: string): string[] {
    const out: string[] = [];
    try {
      const names: string[] = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        if (names[i].endsWith('.json')) {
          out.push(names[i]);
        }
      }
    } catch (e) {
      // 目录不存在等情况按空处理
    }
    return out;
  }
}

/** ArrayBuffer 前 `length` 字节按 UTF-8 解成字符串。 */
function bufferToString(buffer: ArrayBuffer, length: number): string {
  const bytes: Uint8Array = new Uint8Array(buffer, 0, length);
  return new util.TextDecoder().decodeToString(bytes);
}
