/**
 * 设置项注册表。
 *
 * 本文件由 tools/gen-settings-keys.mjs 从 Flutter 源码
 * `lib/services/storage/settings_keys.dart` 机械生成，不要手改；
 * 需要调整请改源文件后重跑脚本。
 *
 * 脚本里有一份 `SKIP_FIELDS` 清单：上游桌面 / Android / 同步相关的项，
 * 以及原生端既没界面也没消费方的「幽灵键」，都不搬过来（见脚本注释）。
 *
 * `name` 是实际落盘键名（对应 Dart `_SettingBoxKey` 的字面量），
 * 与 Flutter 版保持一致，方便后续做数据迁移与对照。
 */

/** 设置分组，对应 Dart `SettingGroup`。 */
export enum SettingGroup {
  player = 'player',
  danmaku = 'danmaku',
  theme = 'theme',
  interface = 'interface',
  proxy = 'proxy',
  webdav = 'webdav',
  download = 'download',
  bangumi = 'bangumi',
  collect = 'collect',
  sync = 'sync',
  update = 'update',
  misc = 'misc'
}

/** 设置项的值类型。 */
export type SettingValueType = 'string' | 'boolean' | 'number';

/** 一条设置项的定义。 */
export interface SettingKeyDef {
  readonly name: string;
  readonly type: SettingValueType;
  readonly defaultValue: string | number | boolean | null;
  readonly group: SettingGroup;
  /** Dart 侧的默认值表达式；与 ArkTS 默认值不一致时在此保留原文。 */
  readonly dartDefault?: string;
}

export class SettingsKeys {
  static readonly hAenable: SettingKeyDef = {
    name: 'hAenable',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.player
  };

  static readonly defaultPlaySpeed: SettingKeyDef = {
    name: 'defaultPlaySpeed',
    type: 'number',
    defaultValue: 1.0,
    group: SettingGroup.player
  };

  static readonly defaultShortcutForwardPlaySpeed: SettingKeyDef = {
    name: 'defaultShortcutForwardPlaySpeed',
    type: 'number',
    defaultValue: 2.0,
    group: SettingGroup.player
  };

  static readonly defaultAspectRatioType: SettingKeyDef = {
    name: 'defaultAspectRatioType',
    type: 'number',
    defaultValue: 1,
    group: SettingGroup.player
  };

  static readonly buttonSkipTime: SettingKeyDef = {
    name: 'buttonSkipTime',
    type: 'number',
    defaultValue: 80,
    group: SettingGroup.player
  };

  static readonly danmakuBorder: SettingKeyDef = {
    name: 'danmakuBorder',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.danmaku
  };

  static readonly danmakuBorderSize: SettingKeyDef = {
    name: 'danmakuBorderSize',
    type: 'number',
    defaultValue: 1.5,
    group: SettingGroup.danmaku
  };

  static readonly danmakuOpacity: SettingKeyDef = {
    name: 'danmakuOpacity',
    type: 'number',
    defaultValue: 1.0,
    group: SettingGroup.danmaku
  };

  static readonly danmakuFontSize: SettingKeyDef = {
    name: 'danmakuFontSize',
    type: 'number',
    defaultValue: 16.0,
    group: SettingGroup.danmaku,
    dartDefault: "25.0（defaultResolver: compactLayout ? 16.0 : 25.0，原生版取 compact 分支）"
  };

  static readonly danmakuTop: SettingKeyDef = {
    name: 'danmakuTop',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.danmaku
  };

  static readonly danmakuScroll: SettingKeyDef = {
    name: 'danmakuScroll',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.danmaku
  };

  static readonly danmakuBottom: SettingKeyDef = {
    name: 'danmakuBottom',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.danmaku
  };

  static readonly danmakuMassive: SettingKeyDef = {
    name: 'danmakuMassive',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.danmaku
  };

  static readonly danmakuDeduplication: SettingKeyDef = {
    name: 'danmakuDeduplication',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.danmaku
  };

  static readonly danmakuArea: SettingKeyDef = {
    name: 'danmakuArea',
    type: 'number',
    defaultValue: 1.0,
    group: SettingGroup.danmaku
  };

  static readonly danmakuColor: SettingKeyDef = {
    name: 'danmakuColor',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.danmaku
  };

  static readonly danmakuDuration: SettingKeyDef = {
    name: 'danmakuDuration',
    type: 'number',
    defaultValue: 8.0,
    group: SettingGroup.danmaku
  };

  static readonly danmakuLineHeight: SettingKeyDef = {
    name: 'danmakuLineHeight',
    type: 'number',
    defaultValue: 1.6,
    group: SettingGroup.danmaku
  };

  static readonly danmakuTimeOffset: SettingKeyDef = {
    name: 'danmakuTimeOffset',
    type: 'number',
    defaultValue: 0.0,
    group: SettingGroup.danmaku
  };

  static readonly danmakuEnabledByDefault: SettingKeyDef = {
    name: 'danmakuEnabledByDefault',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.danmaku
  };

  static readonly danmakuBiliBiliSource: SettingKeyDef = {
    name: 'danmakuBiliBiliSource',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.danmaku
  };

  static readonly danmakuGamerSource: SettingKeyDef = {
    name: 'danmakuGamerSource',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.danmaku
  };

  static readonly danmakuDanDanSource: SettingKeyDef = {
    name: 'danmakuDanDanSource',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.danmaku
  };

  static readonly danmakuFontWeight: SettingKeyDef = {
    name: 'danmakuFontWeight',
    type: 'number',
    defaultValue: 4,
    group: SettingGroup.danmaku
  };

  static readonly danmakuFollowSpeed: SettingKeyDef = {
    name: 'danmakuFollowSpeed',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.danmaku
  };

  static readonly themeMode: SettingKeyDef = {
    name: 'themeMode',
    type: 'string',
    defaultValue: 'system',
    group: SettingGroup.theme
  };

  static readonly themeColor: SettingKeyDef = {
    name: 'themeColor',
    type: 'string',
    defaultValue: 'default',
    group: SettingGroup.theme
  };

  static readonly customBackgroundPath: SettingKeyDef = {
    name: 'customBackgroundPath',
    type: 'string',
    defaultValue: '',
    group: SettingGroup.theme
  };

  static readonly customBackgroundIntensity: SettingKeyDef = {
    name: 'customBackgroundIntensity',
    type: 'number',
    defaultValue: 67,
    group: SettingGroup.theme
  };

  static readonly customBackgroundSeed: SettingKeyDef = {
    name: 'customBackgroundSeed',
    type: 'number',
    defaultValue: 0,
    group: SettingGroup.theme
  };

  static readonly customBackgroundBlurredPath: SettingKeyDef = {
    name: 'customBackgroundBlurredPath',
    type: 'string',
    defaultValue: '',
    group: SettingGroup.theme
  };

  static readonly customBackgroundBlurVariants: SettingKeyDef = {
    name: 'customBackgroundBlurVariants',
    type: 'string',
    defaultValue: '',
    group: SettingGroup.theme
  };

  static readonly privateMode: SettingKeyDef = {
    name: 'privateMode',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.player
  };

  static readonly autoPlayNext: SettingKeyDef = {
    name: 'autoPlayNext',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.player
  };

  static readonly episodeTitleBilibiliSource: SettingKeyDef = {
    name: 'episodeTitleBilibiliSource',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.player
  };

  static readonly playResume: SettingKeyDef = {
    name: 'playResume',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.player
  };

  static readonly oledEnhance: SettingKeyDef = {
    name: 'oledEnhance',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.theme
  };

  static readonly enableGitProxy: SettingKeyDef = {
    name: 'enableGitProxy',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.proxy
  };

  static readonly enableBangumiProxy: SettingKeyDef = {
    name: 'enableBangumiProxy',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.proxy
  };

  static readonly defaultSuperResolutionMode: SettingKeyDef = {
    name: 'defaultSuperResolutionType',
    type: 'number',
    defaultValue: 1,
    group: SettingGroup.player
  };

  static readonly playerDisableAnimations: SettingKeyDef = {
    name: 'playerDisableAnimations',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.player
  };

  static readonly timelineNotShowAbandonedBangumis: SettingKeyDef = {
    name: 'timelineNotShowAbandonedBangumis',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.collect
  };

  static readonly timelineNotShowWatchedBangumis: SettingKeyDef = {
    name: 'timelineNotShowWatchedBangumis',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.collect
  };

  static readonly timelineOnlyShowWatchingBangumis: SettingKeyDef = {
    name: 'timelineOnlyShowWatchingBangumis',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.collect
  };

  static readonly forceAdBlocker: SettingKeyDef = {
    name: 'forceAdBlocker',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.player
  };

  static readonly proxyEnable: SettingKeyDef = {
    name: 'proxyEnable',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.proxy
  };

  static readonly proxyConfigured: SettingKeyDef = {
    name: 'proxyConfigured',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.proxy
  };

  static readonly proxyUrl: SettingKeyDef = {
    name: 'proxyUrl',
    type: 'string',
    defaultValue: '',
    group: SettingGroup.proxy
  };

  static readonly proxyTestUrl: SettingKeyDef = {
    name: 'proxyTestUrl',
    type: 'string',
    defaultValue: '',
    group: SettingGroup.proxy
  };

  static readonly showRating: SettingKeyDef = {
    name: 'showRating',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.interface
  };

  static readonly downloadParallelEpisodes: SettingKeyDef = {
    name: 'downloadParallelEpisodes',
    type: 'number',
    defaultValue: 2,
    group: SettingGroup.download
  };

  static readonly downloadParallelSegments: SettingKeyDef = {
    name: 'downloadParallelSegments',
    type: 'number',
    defaultValue: 3,
    group: SettingGroup.download
  };

  static readonly downloadDanmaku: SettingKeyDef = {
    name: 'downloadDanmaku',
    type: 'boolean',
    defaultValue: true,
    group: SettingGroup.download
  };

  static readonly playerControllerLayerDisappearTime: SettingKeyDef = {
    name: 'playerControllerLayerDisappearTime',
    type: 'number',
    defaultValue: 4000,
    group: SettingGroup.player
  };

  static readonly defaultVolume: SettingKeyDef = {
    name: 'defaultVolume',
    type: 'number',
    defaultValue: 100.0,
    group: SettingGroup.player
  };

  /** 弹弹play 开放平台 AppId；为空时不发起匿名请求。 */
  static readonly danmakuDanDanAppId: SettingKeyDef = {
    name: 'danmakuDanDanAppId',
    type: 'string',
    defaultValue: '',
    group: SettingGroup.danmaku
  };

  /** 弹弹play 开放平台 AppSecret。 */
  static readonly danmakuDanDanAppSecret: SettingKeyDef = {
    name: 'danmakuDanDanAppSecret',
    type: 'string',
    defaultValue: '',
    group: SettingGroup.danmaku
  };

  /** 自定义规则仓库 raw 目录；默认使用公开的 KazumiRules 仓库。 */
  static readonly ruleRepositoryBase: SettingKeyDef = {
    name: 'ruleRepositoryBase',
    type: 'string',
    defaultValue: 'https://raw.githubusercontent.com/Predidit/KazumiRules/main/',
    group: SettingGroup.proxy
  };

  /** 仅当封面真实加载失败时显示开屏图；加载中与加载成功均不替换。 */
  static readonly enableCoverFailurePlaceholder: SettingKeyDef = {
    name: 'enableCoverFailurePlaceholder',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.interface
  };

  /** 固定底部导航栏；开启后页面滚动不会自动隐藏导航。 */
  static readonly fixedNavigationBar: SettingKeyDef = {
    name: 'fixedNavigationBar',
    type: 'boolean',
    defaultValue: false,
    group: SettingGroup.interface
  };

  /** 全部设置项，按源码声明顺序。 */
  static readonly all: SettingKeyDef[] = [
    SettingsKeys.hAenable,
    SettingsKeys.defaultPlaySpeed,
    SettingsKeys.defaultShortcutForwardPlaySpeed,
    SettingsKeys.defaultAspectRatioType,
    SettingsKeys.buttonSkipTime,
    SettingsKeys.danmakuBorder,
    SettingsKeys.danmakuBorderSize,
    SettingsKeys.danmakuOpacity,
    SettingsKeys.danmakuFontSize,
    SettingsKeys.danmakuTop,
    SettingsKeys.danmakuScroll,
    SettingsKeys.danmakuBottom,
    SettingsKeys.danmakuMassive,
    SettingsKeys.danmakuDeduplication,
    SettingsKeys.danmakuArea,
    SettingsKeys.danmakuColor,
    SettingsKeys.danmakuDuration,
    SettingsKeys.danmakuLineHeight,
    SettingsKeys.danmakuTimeOffset,
    SettingsKeys.danmakuEnabledByDefault,
    SettingsKeys.danmakuBiliBiliSource,
    SettingsKeys.danmakuGamerSource,
    SettingsKeys.danmakuDanDanSource,
    SettingsKeys.danmakuFontWeight,
    SettingsKeys.danmakuFollowSpeed,
    SettingsKeys.themeMode,
    SettingsKeys.themeColor,
    SettingsKeys.customBackgroundPath,
    SettingsKeys.customBackgroundIntensity,
    SettingsKeys.customBackgroundSeed,
    SettingsKeys.customBackgroundBlurredPath,
    SettingsKeys.customBackgroundBlurVariants,
    SettingsKeys.privateMode,
    SettingsKeys.autoPlayNext,
    SettingsKeys.episodeTitleBilibiliSource,
    SettingsKeys.playResume,
    SettingsKeys.oledEnhance,
    SettingsKeys.enableGitProxy,
    SettingsKeys.enableBangumiProxy,
    SettingsKeys.defaultSuperResolutionMode,
    SettingsKeys.playerDisableAnimations,
    SettingsKeys.timelineNotShowAbandonedBangumis,
    SettingsKeys.timelineNotShowWatchedBangumis,
    SettingsKeys.timelineOnlyShowWatchingBangumis,
    SettingsKeys.forceAdBlocker,
    SettingsKeys.proxyEnable,
    SettingsKeys.proxyConfigured,
    SettingsKeys.proxyUrl,
    SettingsKeys.proxyTestUrl,
    SettingsKeys.showRating,
    SettingsKeys.downloadParallelEpisodes,
    SettingsKeys.downloadParallelSegments,
    SettingsKeys.downloadDanmaku,
    SettingsKeys.playerControllerLayerDisappearTime,
    SettingsKeys.defaultVolume,
    SettingsKeys.danmakuDanDanAppId,
    SettingsKeys.danmakuDanDanAppSecret,
    SettingsKeys.ruleRepositoryBase,
    SettingsKeys.enableCoverFailurePlaceholder,
    SettingsKeys.fixedNavigationBar
  ];
}
