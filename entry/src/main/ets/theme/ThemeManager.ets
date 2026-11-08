import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { AppColorScheme } from './ColorScheme';
import { ThemeEngine, ThemePreset } from './ThemeEngine';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';
import { ThemeSelfCheck } from './ThemeSelfCheck';
import { ArkUITheme } from './ArkUITheme';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnTheme';

/** 主题模式，对应源码 `SettingsKeys.themeMode` 的三种取值。 */
export enum ThemeModeValue {
  system = 'system',
  light = 'light',
  dark = 'dark'
}

/** 背景强度档位，对应源码 `_backgroundLevels = [0, 33, 67, 100]`。 */
export class BackgroundLevels {
  static readonly levels: number[] = [0, 33, 67, 100];

  /** 把任意强度吸附到最近档位（源码 `_snapLevel`）。 */
  static snap(value: number): number {
    let best: number = BackgroundLevels.levels[0];
    for (let i = 0; i < BackgroundLevels.levels.length; i++) {
      const level: number = BackgroundLevels.levels[i];
      if (Math.abs(value - level) <= Math.abs(value - best)) {
        best = level;
      }
    }
    return best;
  }

  /** 档位短标签（源码 `_levelLabel`）。 */
  static label(value: number): string {
    switch (BackgroundLevels.snap(value)) {
      case 0:
        return '原图';
      case 33:
        return '轻';
      case 67:
        return '标准';
      case 100:
        return '柔和';
      default:
        return '标准';
    }
  }

  /** 档位完整名称（源码 `_levelName`）。 */
  static levelName(level: number): string {
    switch (level) {
      case 0:
        return '原图（无模糊）';
      case 33:
        return '轻';
      case 67:
        return '标准';
      case 100:
        return '柔和';
      default:
        return '标准';
    }
  }
}

/**
 * 全局主题状态。
 *
 * 对应 Flutter 侧的 `ThemeProvider` + `buildHarmonyTheme` 组合：
 * 持有种子色 / 明暗模式 / OLED 增强 / 自定义背景，并负责算出
 * 明暗两套 `AppColorScheme`。
 *
 * 视图侧通过 `@StorageProp('themeRevision')` 订阅变化——
 * 数值一变，所有引用颜色令牌的组件都会重新渲染。
 */
export class ThemeManager {
  /** AppStorage 中的版本号键名。 */
  static readonly REVISION_KEY: string = 'themeRevision';
  /** AppStorage 中的系统深色标记键名（由 EntryAbility 写入）。 */
  static readonly SYSTEM_DARK_KEY: string = 'systemDark';

  private static inst: ThemeManager | null = null;
  private appContext: common.UIAbilityContext | null = null;

  private themeMode: string = ThemeModeValue.system;
  private themeColorValue: string = 'default';
  private oledEnhance: boolean = false;
  private backgroundPathValue: string = '';
  private backgroundBlurredPathValue: string = '';
  private backgroundIntensityValue: number = 67;
  private backgroundSeedValue: number = 0;

  private seedArgbValue: number = ThemeEngine.defaultSeedArgb;
  private lightScheme: AppColorScheme = ThemeEngine.lightOf(ThemeEngine.defaultSeedArgb);
  private darkScheme: AppColorScheme = ThemeEngine.darkOf(ThemeEngine.defaultSeedArgb);

  static instance(): ThemeManager {
    if (ThemeManager.inst === null) {
      ThemeManager.inst = new ThemeManager();
    }
    return ThemeManager.inst;
  }

  /** 绑定 Ability 上下文：应用内深色模式要同步给 ArkUI 系统绘制组件。 */
  attachContext(context: common.UIAbilityContext): void {
    this.appContext = context;
    this.applyApplicationColorMode();
  }

  /** 从设置存储载入并算出方案。Ability 启动时调用一次。 */
  load(): void {
    this.themeMode = SettingsStore.getString(SettingsKeys.themeMode);
    this.themeColorValue = SettingsStore.getString(SettingsKeys.themeColor);
    this.oledEnhance = SettingsStore.getBool(SettingsKeys.oledEnhance);
    this.backgroundPathValue = SettingsStore.getString(SettingsKeys.customBackgroundPath);
    this.backgroundBlurredPathValue =
      SettingsStore.getString(SettingsKeys.customBackgroundBlurredPath);
    this.backgroundIntensityValue =
      SettingsStore.getNumber(SettingsKeys.customBackgroundIntensity);
    this.backgroundSeedValue = SettingsStore.getNumber(SettingsKeys.customBackgroundSeed);
    this.applyApplicationColorMode();
    this.recompute(false);
    hilog.info(DOMAIN, TAG, '%{public}s',
      `主题载入 mode=${this.themeMode} color=${this.themeColorValue} ` +
      `oled=${this.oledEnhance} seed=#${(this.seedArgbValue >>> 0).toString(16)} ` +
      `bg=${this.backgroundPathValue.length > 0 ? '有' : '无'}`);
    ThemeSelfCheck.log(this.seedArgbValue);
  }

  // ---- 只读访问 ----

  get themeModeValue(): string {
    return this.themeMode;
  }

  get themeColor(): string {
    return this.themeColorValue;
  }

  get oled(): boolean {
    return this.oledEnhance;
  }

  get backgroundPath(): string {
    return this.backgroundPathValue;
  }

  get backgroundBlurredPath(): string {
    return this.backgroundBlurredPathValue;
  }

  get backgroundIntensity(): number {
    return this.backgroundIntensityValue;
  }

  get backgroundSeed(): number {
    return this.backgroundSeedValue;
  }

  get seedArgb(): number {
    return this.seedArgbValue;
  }

  /** 是否有可用的自定义背景（对应源码 `hasCustomBackground`）。 */
  get hasCustomBackground(): boolean {
    return this.backgroundPathValue.length > 0;
  }

  /** 是否处于深色（跟随系统时看系统设置）。 */
  isEffectiveDark(): boolean {
    if (this.themeMode === ThemeModeValue.dark) {
      return true;
    }
    if (this.themeMode === ThemeModeValue.light) {
      return false;
    }
    return ThemeManager.systemDark();
  }

  static systemDark(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>(ThemeManager.SYSTEM_DARK_KEY);
    return v === true;
  }

  /** 当前生效的方案（已应用 OLED 增强）。 */
  current(): AppColorScheme {
    if (this.isEffectiveDark()) {
      return this.oledEnhance ? this.darkScheme.toOledDark() : this.darkScheme;
    }
    return this.lightScheme;
  }

  lightOfCurrent(): AppColorScheme {
    return this.lightScheme;
  }

  darkOfCurrent(): AppColorScheme {
    return this.oledEnhance ? this.darkScheme.toOledDark() : this.darkScheme;
  }

  // ---- 修改 ----

  setThemeMode(mode: string): void {
    this.themeMode = mode;
    SettingsStore.put(SettingsKeys.themeMode, mode);
    this.applyApplicationColorMode();
    this.recompute(true);
  }

  /** 选中某个预设（源码 `setTheme` / `resetTheme`）。 */
  setThemePreset(preset: ThemePreset): void {
    this.themeColorValue = preset.storageValue;
    SettingsStore.put(SettingsKeys.themeColor, preset.storageValue);
    this.recompute(true);
  }

  setOledEnhance(enabled: boolean): void {
    this.oledEnhance = enabled;
    SettingsStore.put(SettingsKeys.oledEnhance, enabled);
    this.recompute(true);
  }

  /** 设置自定义背景（源码 `_pickCustomBackground` 的后半段）。 */
  applyCustomBackground(path: string, seedArgb: number, intensity: number): void {
    this.backgroundPathValue = path;
    this.backgroundSeedValue = seedArgb;
    this.backgroundIntensityValue = intensity;
    SettingsStore.put(SettingsKeys.customBackgroundPath, path);
    SettingsStore.put(SettingsKeys.customBackgroundSeed, seedArgb);
    SettingsStore.put(SettingsKeys.customBackgroundIntensity, intensity);
    this.recompute(true);
  }

  setBackgroundIntensity(intensity: number): void {
    this.backgroundIntensityValue = intensity;
    SettingsStore.put(SettingsKeys.customBackgroundIntensity, intensity);
    this.recompute(true);
  }

  /** 清除自定义背景（源码 `_clearCustomBackground`）。 */
  clearCustomBackground(): void {
    this.backgroundPathValue = '';
    this.backgroundBlurredPathValue = '';
    this.backgroundSeedValue = 0;
    SettingsStore.put(SettingsKeys.customBackgroundPath, '');
    SettingsStore.put(SettingsKeys.customBackgroundBlurredPath, '');
    SettingsStore.put(SettingsKeys.customBackgroundBlurVariants, '');
    SettingsStore.put(SettingsKeys.customBackgroundSeed, 0);
    this.recompute(true);
  }

  /**
   * 重算色板。
   *
   * 种子色的选择顺序与源码 build() 中的 `themedFor` 一致：
   * 只有在「有自定义背景」且「背景种子非 0」时，才用背景取色取代主题色。
   */
  private recompute(notify: boolean): void {
    const useBackgroundSeed: boolean = this.hasCustomBackground && this.backgroundSeedValue !== 0;
    this.seedArgbValue = useBackgroundSeed
      ? this.backgroundSeedValue
      : ThemeEngine.seedOfSetting(this.themeColorValue);
    this.lightScheme = ThemeEngine.lightOf(this.seedArgbValue);
    this.darkScheme = ThemeEngine.darkOf(this.seedArgbValue);
    // 把新配色同步给 **ArkUI 系统组件**（原生菜单 / 对话框 / 弹层 / 开关…）。
    // 只在这里调：换预设、切明暗、跟随壁纸取色都会走到 recompute。
    ArkUITheme.apply();
    if (notify) {
      ThemeManager.bumpRevision();
    } else {
      AppStorage.setOrCreate(ThemeManager.REVISION_KEY, ThemeManager.revision() + 1);
    }
  }

  /**
   * 把应用内主题模式映射到 ArkUI 的应用级 ColorMode。
   *
   * 不调用这个接口时，自绘的 AppColor 会变，但系统绘制的菜单、开关、
   * TextInput 光标、未显式着色的 SymbolGlyph/Text 仍跟随系统浅色，
   * 表现就是「应用里开了深色，有些图标字体还是浅色模式」。
   */
  private applyApplicationColorMode(): void {
    const context: common.UIAbilityContext | null = this.appContext;
    if (context === null) {
      return;
    }
    let colorMode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (this.themeMode === ThemeModeValue.dark) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (this.themeMode === ThemeModeValue.light) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    try {
      context.getApplicationContext().setColorMode(colorMode);
      hilog.info(DOMAIN, TAG, '应用 ColorMode → %{public}s', this.themeMode);
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '设置应用 ColorMode 失败: %{public}s', err.message);
    }
  }

  private static revision(): number {
    const v: number | undefined = AppStorage.get<number>(ThemeManager.REVISION_KEY);
    return v === undefined ? 0 : v;
  }

  static bumpRevision(): void {
    AppStorage.setOrCreate(ThemeManager.REVISION_KEY, ThemeManager.revision() + 1);
  }
}
