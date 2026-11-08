import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SettingsStore } from '../services/storage/SettingsStore';
import { ThemeManager } from '../theme/ThemeManager';
import { RequestSelfCheck } from '../request/RequestSelfCheck';
import { PluginManager } from '../services/plugin/PluginManager';
import { PluginUpdateService } from '../services/plugin/PluginUpdateService';
import { CollectStore } from '../services/collect/CollectStore';
import { SearchHistoryStore } from '../services/search/SearchHistoryStore';
import { HistoryRepository } from '../services/HistoryRepository';
import { Logger } from '../services/Logger';
import { DanmakuShieldStore } from '../services/DanmakuShieldStore';
import { DanmakuService } from '../services/DanmakuService';
import { DownloadManager } from '../services/DownloadManager';
import { UnavailablePlugins } from '../services/plugin/UnavailablePlugins';
import { PluginCookieManager } from '../services/plugin/PluginCookieManager';
import { WatchTimeStore } from '../services/WatchTimeStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnArkUI';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    // 设置存储与主题要在界面之前就绪：所有页面都依赖主题令牌。
    SettingsStore.init(this.context);
    // 规则表要在界面之前就绪：规则列表 / 搜索 / 更新都依赖它
    PluginManager.init(this.context);
    // 规则目录也先读离线缓存：镜像抖动时仓库页仍有内容可展示
    PluginUpdateService.init(PluginManager.catalogCachePath());
    // 收藏表同样要在界面之前就绪（追番页首帧就要用）
    CollectStore.init(this.context);
    // 搜索历史：搜索页探索态的「最近搜索」首帧就要用
    SearchHistoryStore.init(this.context);
    // 播放历史（阶段五 §19/§60）：详情页续播、历史页、推荐页「最近在看」都依赖它
    HistoryRepository.init(this.context);
    // 文件日志（§53）：日志页与「存储与日志」都读它，必须早于其它服务初始化
    Logger.init(this.context);
    // 弹幕屏蔽规则（§61.3）：弹幕渲染时逐条判定，启动即载入
    DanmakuShieldStore.init(this.context);
    // 弹幕缓存目录（§18.2 / §43.1）：离线播放与断网重看都靠它
    DanmakuService.init(this.context);
    // 下载管理器（§18/§66）：记录表要在下载页首帧就能读到
    DownloadManager.init(this.context);
    // 规则管理里「标记为不可用」的名单：读一次落盘文件，之后查询都走内存
    UnavailablePlugins.init(this.context);
    // 验证态（站点 Cookie + 验证时的 UA）：读回来，免得每次冷启动都要重过验证码
    PluginCookieManager.init(this.context);
    // 观看时长（「我的」页统计卡的真实数据来源）
    WatchTimeStore.init(this.context);
    EntryAbility.publishSystemDark(this.context.config);
    ThemeManager.instance().attachContext(this.context);
    ThemeManager.instance().load();
    // 网络层 + 数据模型自检（阶段 2 完成前保留，见 RequestSelfCheck 注释）
    RequestSelfCheck.run();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
    });

    // 沉浸式（对应 Flutter 侧 Scaffold 背景铺满整窗的效果）：
    // 只调用 expandSafeArea 不够，必须先把窗口设为全屏布局，
    // 否则窗口本身仍被系统栏收缩，页面根节点永远从状态栏之下开始。
    // 随后把系统实际的安全区高度换算成 vp 放进 AppStorage，由各视图自行让位。
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowLayoutFullScreen(true)
        .then(() => {
          EntryAbility.publishInsets(mainWindow);
        })
        .catch((err: BusinessError) => {
          hilog.error(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s',
            JSON.stringify(err));
          EntryAbility.publishInsets(mainWindow);
        });
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, 'read avoid area failed: %{public}s', err.message);
      AppStorage.setOrCreate('topInset', 39);
      AppStorage.setOrCreate('bottomInset', 28);
      AppStorage.setOrCreate('leftInset', 0);
      AppStorage.setOrCreate('rightInset', 0);
    }
  }

  /** 读取系统安全区并换算为 vp。 */
  private static publishInsets(mainWindow: window.Window): void {
    try {
      const density: number = display.getDefaultDisplaySync().densityPixels;
      const topArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const bottomArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const topInset: number = Math.round(topArea.topRect.height / density);
      const bottomInset: number = Math.round(bottomArea.bottomRect.height / density);
      // 横屏时刘海/挖孔会落在左或右，播放页全屏的三个控制组都要让开
      // （参照实现是给它们套 `SafeArea(left/right: isFullscreen)`）。
      const leftInset: number = Math.round(topArea.leftRect.width / density);
      const rightInset: number = Math.round(topArea.rightRect.width / density);
      AppStorage.setOrCreate('topInset', topInset);
      AppStorage.setOrCreate('bottomInset', bottomInset);
      AppStorage.setOrCreate('leftInset', leftInset);
      AppStorage.setOrCreate('rightInset', rightInset);
      hilog.info(DOMAIN, TAG, 'insets ' + JSON.stringify({
        top: topInset, bottom: bottomInset, left: leftInset, right: rightInset
      }));
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, 'publishInsets failed: %{public}s', err.message);
      AppStorage.setOrCreate('topInset', 39);
      AppStorage.setOrCreate('bottomInset', 28);
      AppStorage.setOrCreate('leftInset', 0);
      AppStorage.setOrCreate('rightInset', 0);
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  /**
   * 系统深色模式变化。
   *
   * 对应源码 `didChangePlatformBrightness`：源实现只用来同步 Windows 标题栏，
   * 主题本身由 `ThemeMode.system` 在每次 build 时读平台亮度决定。
   * 原生版把平台亮度放进 AppStorage，主题变更后 bump 版本号触发重绘。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    EntryAbility.publishSystemDark(newConfig);
    ThemeManager.bumpRevision();
  }

  private static publishSystemDark(config: Configuration): void {
    const isDark: boolean = config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate(ThemeManager.SYSTEM_DARK_KEY, isDark);
    hilog.info(DOMAIN, TAG, 'system color mode dark=%{public}s', `${isDark}`);
  }

}
