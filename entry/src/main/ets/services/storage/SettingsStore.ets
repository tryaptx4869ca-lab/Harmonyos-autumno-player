import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsKeys, SettingKeyDef } from './SettingsKeys';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnStore';

/**
 * 设置存储。
 *
 * 对应 Flutter 侧的 `GStorage` + Hive 盒子：全应用一个键值存储，
 * 键名与默认值来自 `SettingsKeys`（由源码机械生成，见 tools/）。
 *
 * 实现说明：鸿蒙的 preferences 本身就够用（设置总量小、需要同步读），
 * 因此没有直接上 relationalStore——关系库留给历史/追番/插件等结构化数据。
 * 读走内存镜像，写同时落盘并 flush，保证冷启动与前台一致。
 */
export class SettingsStore {
  private static prefs: preferences.Preferences | null = null;
  private static mirror: Map<string, preferences.ValueType> = new Map<string, preferences.ValueType>();

  /** 存储文件名。对应 Hive 里的 settings 盒子。 */
  private static readonly STORE_NAME: string = 'autumn_settings';

  /** 在 Ability 启动时调用一次。 */
  static init(context: common.UIAbilityContext): void {
    if (SettingsStore.prefs !== null) {
      return;
    }
    try {
      const options: preferences.Options = { name: SettingsStore.STORE_NAME };
      const store: preferences.Preferences =
        preferences.getPreferencesSync(context, options);
      SettingsStore.prefs = store;
      SettingsStore.loadMirror(store);
      hilog.info(DOMAIN, TAG, '%{public}s',
        `设置存储就绪，已载入 ${SettingsStore.mirror.size} 条 / 共 ${SettingsKeys.all.length} 项`);
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '初始化设置存储失败: %{public}s', err.message);
    }
  }

  private static loadMirror(store: preferences.Preferences): void {
    const all: SettingKeyDef[] = SettingsKeys.all;
    for (let i = 0; i < all.length; i++) {
      const def: SettingKeyDef = all[i];
      if (store.hasSync(def.name)) {
        SettingsStore.mirror.set(def.name, store.getSync(def.name, def.defaultValue ?? ''));
      }
    }
  }

  private static raw(def: SettingKeyDef): preferences.ValueType {
    const cached: preferences.ValueType | undefined = SettingsStore.mirror.get(def.name);
    if (cached !== undefined && cached !== null) {
      return cached;
    }
    return def.defaultValue ?? '';
  }

  static getString(def: SettingKeyDef): string {
    const v: preferences.ValueType = SettingsStore.raw(def);
    return typeof v === 'string' ? v : `${v}`;
  }

  static getBool(def: SettingKeyDef): boolean {
    const v: preferences.ValueType = SettingsStore.raw(def);
    if (typeof v === 'boolean') {
      return v;
    }
    return v === 'true';
  }

  static getNumber(def: SettingKeyDef): number {
    const v: preferences.ValueType = SettingsStore.raw(def);
    if (typeof v === 'number') {
      return v;
    }
    const parsed: number = Number.parseFloat(`${v}`);
    return Number.isNaN(parsed) ? 0 : parsed;
  }

  /** 写设置。内存镜像立即生效，落盘异步完成。 */
  static put(def: SettingKeyDef, value: preferences.ValueType): void {
    SettingsStore.mirror.set(def.name, value);
    const store: preferences.Preferences | null = SettingsStore.prefs;
    if (store === null) {
      hilog.warn(DOMAIN, TAG, '设置存储未初始化，写入被丢弃: %{public}s', def.name);
      return;
    }
    try {
      store.putSync(def.name, value);
      store.flush().then(() => {
      }).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, 'flush 失败: %{public}s', e.message);
      });
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '写入设置失败 %{public}s: %{public}s', def.name, err.message);
    }
  }

  static putAll(entries: SettingsEntry[]): void {
    for (let i = 0; i < entries.length; i++) {
      SettingsStore.put(entries[i].def, entries[i].value);
    }
  }

  /**
   * 把一项设置恢复为注册表里的默认值。
   *
   * 之所以要有这个方法：`SettingKeyDef.defaultValue` 的类型是
   * `string | number | boolean | null`，而 `put` 要的是 `preferences.ValueType`，
   * 调用点直接传会被 ArkTS 拒绝（结构不同）。这里按实际类型分派，
   * `null`（少数无法机械转换的项）直接跳过而不是写入。
   */
  static resetDefault(def: SettingKeyDef): void {
    const value: string | number | boolean | null = def.defaultValue;
    if (value === null) {
      hilog.warn(DOMAIN, TAG, '该项没有可用的默认值，跳过: %{public}s', def.name);
      return;
    }
    SettingsStore.put(def, value);
  }
}

/** 批量写入的一项。 */
export interface SettingsEntry {
  def: SettingKeyDef;
  value: preferences.ValueType;
}
