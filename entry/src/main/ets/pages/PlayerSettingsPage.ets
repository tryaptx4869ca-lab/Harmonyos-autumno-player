import { AppColor } from '../theme/AppColors';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { SectionHeader, SettingsRow, SettingsRowKind } from '../components/SettingsList';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';
import {
  SettingsChoiceRow,
  SettingsMenuRow,
  SettingsNumberRow,
  SettingsOption,
  SettingsSliderRow,
  groupBottomRadius,
  groupTopRadius
} from '../components/SettingsRows';
import { SettingsKeys, SettingKeyDef } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';

/** 默认视频比例（`PlayerAspectRatio`，存储值 1–4）。 */
const ASPECT_RATIOS: SettingsOption[] = [
  new SettingsOption(1, '自动'),
  new SettingsOption(2, '裁切填充'),
  new SettingsOption(3, '拉伸填充'),
  new SettingsOption(4, '4:3')
];

/** 滑杆范围（与源码 `player_settings.dart` 的 min/max/divisions 对齐）。 */
const MIN_PLAY_SPEED: number = 0.25;
const MAX_PLAY_SPEED: number = 3;
const MIN_SHORTCUT_SPEED: number = 1.25;
const MAX_SHORTCUT_SPEED: number = 3;
const MIN_DISAPPEAR: number = 1;
const MAX_DISAPPEAR: number = 10;

/**
 * 播放设置（规格 §24.3 / `player_settings.dart`）。
 *
 * 三组：
 *   解码与渲染（硬件解码 / 超分辨率）
 *   播放行为（自动跳转 / 自动连播 / 补全剧集标题 / 广告过滤 / 禁用动画 / 隐身模式）
 *   播放参数（默认倍速 / 长按倍速 / 跳过时长 / 控制栏消失时间 / 默认比例 / 恢复默认）
 *
 * 2026-09-19 清理：删掉六项**点了没有任何作用**的设置 —— 低延迟音频
 * （`androidEnableOpenSLES`，OpenSLES 是 Android 的音频 API）、视频渲染器与
 * 硬件解码器（`androidVideoRenderer` / `hardwareDecoder`，只有设置页自己读写，
 * 播放链路从不读，两个整页也一并删掉）、后台播放（`backgroundPlayback`，工程里
 * 根本没有 AVSession / 长时任务，后台播放没实现）、滑动手势
 * （`brightnessVolumeGesture`，视频页手势不读它，关掉照样能滑）、方向键跳转
 * （`arrowKeySkipTime`，桌面端遗产），以及整个「诊断」组（错误提示 / 调试模式 /
 * 日志等级三项同样无人消费）。
 */
@Component
export struct PlayerSettingsPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('themeRevision') themeRevision: number = 0;

  // 解码与渲染
  @State private hAenable: boolean = true;
  @State private superResolutionLabel: string = '关闭';

  // 播放行为
  @State private playResume: boolean = true;
  @State private autoPlayNext: boolean = true;
  @State private bilibiliTitle: boolean = true;
  @State private forceAdBlocker: boolean = false;
  @State private disableAnimations: boolean = false;
  @State private privateMode: boolean = false;

  // 播放参数
  @State private playSpeed: number = 1;
  @State private shortcutSpeed: number = 2;
  @State private skipTime: number = 80;
  /**
   * 控制栏消失时间（**秒**）。
   * 存储键 `playerControllerLayerDisappearTime` 的单位是**毫秒**（默认 4000），
   * 与参照实现一致：界面按秒显示（1–10），写入时 ×1000。
   */
  @State private disappearSeconds: number = 4;
  /** 默认视频比例。**不能叫 `aspectRatio`**：与 ArkUI 内置属性同名会冲突。 */
  @State private aspectRatioValue: number = 1;

  /** 0 关闭 / 1 日志等级 / 2 视频比例。 */
  private numberDialog: CustomDialogController | null = null;

  aboutToAppear(): void {
    this.load();
    this.numberDialog = new CustomDialogController({
      builder: NumberInputDialog({
        title: '跳过时长',
        hint: '长按「跳 OP」按钮时使用；单位为秒。',
        initial: 80,
        onConfirm: (value: number) => {
          this.skipTime = value;
          SettingsStore.put(SettingsKeys.buttonSkipTime, value);
        }
      }),
      autoCancel: true,
      customStyle: false
    });
  }

  private load(): void {
    this.hAenable = SettingsStore.getBool(SettingsKeys.hAenable);
    this.superResolutionLabel = PlayerSettingsPage.modeLabel(
      SettingsStore.getNumber(SettingsKeys.defaultSuperResolutionMode));

    this.playResume = SettingsStore.getBool(SettingsKeys.playResume);
    this.autoPlayNext = SettingsStore.getBool(SettingsKeys.autoPlayNext);
    this.bilibiliTitle = SettingsStore.getBool(SettingsKeys.episodeTitleBilibiliSource);
    this.forceAdBlocker = SettingsStore.getBool(SettingsKeys.forceAdBlocker);
    this.disableAnimations = SettingsStore.getBool(SettingsKeys.playerDisableAnimations);
    this.privateMode = SettingsStore.getBool(SettingsKeys.privateMode);

    this.playSpeed = SettingsStore.getNumber(SettingsKeys.defaultPlaySpeed);
    this.shortcutSpeed =
      SettingsStore.getNumber(SettingsKeys.defaultShortcutForwardPlaySpeed);
    this.skipTime = SettingsStore.getNumber(SettingsKeys.buttonSkipTime);
    this.disappearSeconds = PlayerSettingsPage.clampSeconds(
      SettingsStore.getNumber(SettingsKeys.playerControllerLayerDisappearTime) / 1000);
    this.aspectRatioValue = SettingsStore.getNumber(SettingsKeys.defaultAspectRatioType);
  }

  private static modeLabel(value: number): string {
    if (value === 2) {
      return '效率档';
    }
    return value === 3 ? '质量档' : '关闭';
  }

  /** 秒数钳制到 1–10（源码 `clamp(_min.., _max..)`），并保留一位小数。 */
  private static clampSeconds(value: number): number {
    if (value < MIN_DISAPPEAR) {
      return MIN_DISAPPEAR;
    }
    if (value > MAX_DISAPPEAR) {
      return MAX_DISAPPEAR;
    }
    return Number(value.toFixed(1));
  }

  /** 秒数的显示文案：整数不带小数点（源码 `formatPlayerControllerLayerDisappearSeconds`）。 */
  private static secondsLabel(seconds: number): string {
    return seconds === Math.round(seconds)
      ? `${Math.round(seconds)} 秒` : `${seconds.toFixed(1)} 秒`;
  }

  private static labelOf(options: SettingsOption[], value: number,
    fallback: string): string {
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === value) {
        return options[i].label;
      }
    }
    return fallback;
  }

  /** 恢复默认播放设置（对应源码的 `恢复默认设置`）。 */
  private restoreDefaults(): void {
    PlayerSettingsPage.reset(SettingsKeys.hAenable);
    PlayerSettingsPage.reset(SettingsKeys.defaultSuperResolutionMode);
    PlayerSettingsPage.reset(SettingsKeys.playResume);
    PlayerSettingsPage.reset(SettingsKeys.autoPlayNext);
    PlayerSettingsPage.reset(SettingsKeys.episodeTitleBilibiliSource);
    PlayerSettingsPage.reset(SettingsKeys.forceAdBlocker);
    PlayerSettingsPage.reset(SettingsKeys.playerDisableAnimations);
    PlayerSettingsPage.reset(SettingsKeys.privateMode);
    PlayerSettingsPage.reset(SettingsKeys.defaultPlaySpeed);
    PlayerSettingsPage.reset(SettingsKeys.defaultShortcutForwardPlaySpeed);
    PlayerSettingsPage.reset(SettingsKeys.buttonSkipTime);
    PlayerSettingsPage.reset(SettingsKeys.playerControllerLayerDisappearTime);
    PlayerSettingsPage.reset(SettingsKeys.defaultAspectRatioType);
    this.load();
    this.getUIContext().getPromptAction().showToast({ message: '已恢复默认播放设置' });
  }

  private static reset(key: SettingKeyDef): void {
    SettingsStore.resetDefault(key);
  }

  pageTransition() {
    PageTransitionEnter({
      type: RouteType.Push,
      duration: RouteTable.duration(),
      curve: PageTransitionSpec.enterCurve()
    })
      .opacity(0)
      .translate({ y: RouteTable.slideOffset() })
    PageTransitionExit({
      type: RouteType.Pop,
      duration: RouteTable.duration(),
      curve: PageTransitionSpec.exitCurve()
    })
      .opacity(0)
      // 退出：与参照实现同一条 Fade + Slide（`Offset(0, 0.02)`）——下滑 2% 的同时淡出
      .translate({ y: RouteTable.slideOffset() })
  }

  build() {
    Stack() {
      Column() {
        /**
         * 沉浸式悬浮标题（2026-09-19 用户：「把所有的设置页面都改成标题悬浮
         * 然后内容铺满的沉浸式」）：本层不占布局高度，`Scroll` 铺满整页、
         * 内容从标题下面滚过去；顶部让位由下面内容列的 padding 负责。
         */
        ImmersiveTitleLayer({
          themeRev: this.themeRevision,
          title: '播放设置',
          onBack: () => {
            RouteTable.back();
          }
        })

        Scroll() {
          Column() {
            // ---------------- 解码与渲染 ----------------
            SectionHeader({ title: '解码与渲染' })
            Column({ space: 4 }) {
              SettingsRow({
                title: '硬件解码',
                description: '使用设备硬件解码视频',
                kind: SettingsRowKind.toggle,
                checked: this.hAenable,
                topRadius: groupTopRadius(0),
                bottomRadius: groupBottomRadius(0, 2),
                onToggle: (value: boolean) => {
                  this.hAenable = value;
                  SettingsStore.put(SettingsKeys.hAenable, value);
                }
              })
              SettingsChoiceRow({
                title: '超分辨率',
                description: '默认启用的 Anime4K 档位',
                valueText: this.superResolutionLabel,
                topRadius: groupTopRadius(1),
                bottomRadius: groupBottomRadius(1, 2),
                onTap: () => {
                  RouteTable.push('pages/SuperResolutionSettingsPage');
                }
              })
            }
            .width('100%')

            // ---------------- 播放行为 ----------------
            SectionHeader({ title: '播放行为' })
            Column({ space: 4 }) {
              SettingsRow({
                title: '自动跳转',
                description: '跳转到上次播放位置',
                kind: SettingsRowKind.toggle,
                checked: this.playResume,
                topRadius: groupTopRadius(0),
                bottomRadius: groupBottomRadius(0, 6),
                onToggle: (value: boolean) => {
                  this.playResume = value;
                  SettingsStore.put(SettingsKeys.playResume, value);
                }
              })
              SettingsRow({
                title: '自动连播',
                description: '当前视频播放完毕后自动播放下一集',
                kind: SettingsRowKind.toggle,
                checked: this.autoPlayNext,
                topRadius: groupTopRadius(1),
                bottomRadius: groupBottomRadius(1, 6),
                onToggle: (value: boolean) => {
                  this.autoPlayNext = value;
                  SettingsStore.put(SettingsKeys.autoPlayNext, value);
                }
              })
              SettingsRow({
                title: '补全剧集标题',
                description: 'Bangumi 缺少分集名时从 B站补全',
                kind: SettingsRowKind.toggle,
                checked: this.bilibiliTitle,
                topRadius: groupTopRadius(2),
                bottomRadius: groupBottomRadius(2, 6),
                onToggle: (value: boolean) => {
                  this.bilibiliTitle = value;
                  SettingsStore.put(SettingsKeys.episodeTitleBilibiliSource, value);
                }
              })
              SettingsRow({
                title: '广告过滤',
                description: '强制启用HLS广告过滤，忽略规则设置',
                kind: SettingsRowKind.toggle,
                checked: this.forceAdBlocker,
                topRadius: groupTopRadius(3),
                bottomRadius: groupBottomRadius(3, 6),
                onToggle: (value: boolean) => {
                  this.forceAdBlocker = value;
                  SettingsStore.put(SettingsKeys.forceAdBlocker, value);
                }
              })
              SettingsRow({
                title: '禁用动画',
                description: '禁用播放器内的过渡动画',
                kind: SettingsRowKind.toggle,
                checked: this.disableAnimations,
                topRadius: groupTopRadius(4),
                bottomRadius: groupBottomRadius(4, 6),
                onToggle: (value: boolean) => {
                  this.disableAnimations = value;
                  SettingsStore.put(SettingsKeys.playerDisableAnimations, value);
                }
              })
              SettingsRow({
                title: '隐身模式',
                description: '不保留观看记录',
                kind: SettingsRowKind.toggle,
                checked: this.privateMode,
                topRadius: groupTopRadius(5),
                bottomRadius: groupBottomRadius(5, 6),
                onToggle: (value: boolean) => {
                  this.privateMode = value;
                  SettingsStore.put(SettingsKeys.privateMode, value);
                }
              })
            }
            .width('100%')

            // ---------------- 播放参数 ----------------
            SectionHeader({ title: '播放参数' })
            Column({ space: 4 }) {
              SettingsSliderRow({
                title: '默认倍速',
                valueText: `${this.playSpeed}x`,
                value: this.playSpeed,
                min: MIN_PLAY_SPEED,
                max: MAX_PLAY_SPEED,
                step: 0.25,
                topRadius: groupTopRadius(0),
                bottomRadius: groupBottomRadius(0, 6),
                onChange: (value: number) => {
                  this.playSpeed = value;
                  SettingsStore.put(SettingsKeys.defaultPlaySpeed, value);
                }
              })
              SettingsSliderRow({
                title: '长按倍速',
                description: '长按屏幕时的倍速',
                valueText: `${this.shortcutSpeed}x`,
                value: this.shortcutSpeed,
                min: MIN_SHORTCUT_SPEED,
                max: MAX_SHORTCUT_SPEED,
                step: 0.25,
                topRadius: groupTopRadius(1),
                bottomRadius: groupBottomRadius(1, 6),
                onChange: (value: number) => {
                  this.shortcutSpeed = value;
                  SettingsStore.put(SettingsKeys.defaultShortcutForwardPlaySpeed, value);
                }
              })
              SettingsNumberRow({
                title: '跳过时长',
                description: '顶栏跳过按钮的秒数',
                valueText: `${this.skipTime}s`,
                topRadius: groupTopRadius(2),
                bottomRadius: groupBottomRadius(2, 6),
                onTap: () => {
                  const controller: CustomDialogController | null = this.numberDialog;
                  if (controller !== null) {
                    controller.open();
                  }
                }
              })
              SettingsSliderRow({
                title: '控制栏消失时间',
                description: '播放控制器自动隐藏前的停留时长',
                valueText: PlayerSettingsPage.secondsLabel(this.disappearSeconds),
                value: this.disappearSeconds,
                min: MIN_DISAPPEAR,
                max: MAX_DISAPPEAR,
                step: 0.5,
                topRadius: groupTopRadius(3),
                bottomRadius: groupBottomRadius(3, 6),
                onChange: (value: number) => {
                  this.disappearSeconds = Number(value.toFixed(1));
                  SettingsStore.put(SettingsKeys.playerControllerLayerDisappearTime,
                    Math.round(this.disappearSeconds * 1000));
                }
              })
              SettingsMenuRow({
                title: '默认视频比例',
                description: '进入播放页时的画面比例',
                valueText: PlayerSettingsPage.labelOf(ASPECT_RATIOS, this.aspectRatioValue, '自动'),
                current: this.aspectRatioValue,
                options: ASPECT_RATIOS,
                topRadius: groupTopRadius(4),
                bottomRadius: groupBottomRadius(4, 6),
                onPick: (value: number) => {
                  this.aspectRatioValue = value;
                  SettingsStore.put(SettingsKeys.defaultAspectRatioType, value);
                }
              })
              SettingsRow({
                title: '恢复默认设置',
                description: '把本页所有播放设置恢复为初始值',
                icon: $r('sys.symbol.arrow_2_circlepath'),
                topRadius: groupTopRadius(5),
                bottomRadius: groupBottomRadius(5, 6),
                onTap: () => {
                  this.restoreDefaults();
                }
              })
            }
            .width('100%')

            Blank().height(Dimens.contentBottomSpacer)
          }
          .width('100%')
          .padding({
            left: Dimens.contentInset,
            right: Dimens.contentInset,
            // 让出悬浮标题的高度（底部间距由内容末尾的 contentBottomSpacer 负责）
            top: ImmersiveMetrics.contentTop(this.topInset)
          })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}

/** 数字输入对话框（跳过时长、后续的下载并发等都用它）。 */
@CustomDialog
struct NumberInputDialog {
  controller: CustomDialogController = new CustomDialogController({
    builder: NumberInputDialog({
      title: '',
      hint: '',
      initial: 0,
      onConfirm: (value: number) => {
      }
    })
  });
  title: string = '';
  hint: string = '';
  initial: number = 0;
  onConfirm: (value: number) => void = () => {
  };
  @State private text: string = '';

  aboutToAppear(): void {
    this.text = `${this.initial}`;
  }

  build() {
    Column({ space: 16 }) {
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.onSurface)
        .width('100%')
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(12)
          .fontColor(AppColor.onSurfaceVariant)
          .width('100%')
      }
      TextInput({ text: this.text, placeholder: '秒' })
        .type(InputType.Number)
        .fontSize(15)
        .onChange((value: string) => {
          this.text = value;
        })
      Row({ space: 12 }) {
        Button('取消')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .fontColor(AppColor.onSurfaceVariant)
          .onClick(() => {
            this.controller.close();
          })
        Button('确定')
          .fontSize(14)
          .layoutWeight(1)
          .onClick(() => {
            const value: number = Number.parseInt(this.text, 10);
            if (Number.isNaN(value) || value <= 0) {
              return;
            }
            this.onConfirm(value);
            this.controller.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(24)
  }
}
