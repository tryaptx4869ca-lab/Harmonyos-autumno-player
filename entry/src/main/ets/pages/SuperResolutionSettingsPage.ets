import { AppColor } from '../theme/AppColors';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { SectionHeader } from '../components/SettingsList';
import { SettingsRadioRow, groupBottomRadius, groupTopRadius } from '../components/SettingsRows';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';

/** 超分档位（`SuperResolutionMode`）：1 关闭 / 2 效率档 / 3 质量档。 */
class SuperResolutionOption {
  readonly value: number;
  readonly label: string;
  readonly description: string;

  constructor(value: number, label: string, description: string) {
    this.value = value;
    this.label = label;
    this.description = description;
  }
}

const MODES: SuperResolutionOption[] = [
  new SuperResolutionOption(1, '关闭', '默认禁用超分辨率'),
  new SuperResolutionOption(2, '效率档', '默认启用基于Anime4K的超分辨率 (效率优先)'),
  new SuperResolutionOption(3, '质量档', '默认启用基于Anime4K的超分辨率 (质量优先)')
];

/**
 * 超分辨率（规格 §43.5 / `super_resolution_settings.dart`）。
 *
 * 顶部那行说明是源码原文，包含「需要先开硬件解码、不生效就换 gpu 渲染器」
 * 这两条排查路径——播放页的「超分辨率」菜单也会弹同样的提示（除非关掉）。
 */
@Component
export struct SuperResolutionSettingsPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('themeRevision') themeRevision: number = 0;
  @State private mode: number = 1;

  aboutToAppear(): void {
    this.mode = SettingsStore.getNumber(SettingsKeys.defaultSuperResolutionMode);
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
    Column() {
      // 沉浸式悬浮标题层（2026-09-19）
      ImmersiveTitleLayer({
        themeRev: this.themeRevision,
        title: '超分辨率',
        onBack: () => {
          RouteTable.back();
        }
      })

      Scroll() {
        Column() {
          SectionHeader({
            title: '超分辨率需要启用硬件解码, 若启用硬件解码后仍然不生效, 尝试切换视频渲染器为 gpu'
          })
          Column({ space: 4 }) {
            ForEach(MODES, (option: SuperResolutionOption, index: number) => {
              SettingsRadioRow({
                title: option.label,
                description: option.description,
                selected: this.mode === option.value,
                topRadius: groupTopRadius(index),
                bottomRadius: groupBottomRadius(index, MODES.length),
                onTap: () => {
                  this.mode = option.value;
                  SettingsStore.put(SettingsKeys.defaultSuperResolutionMode,
                    option.value);
                }
              })
            }, (option: SuperResolutionOption) => `${option.value}`)
          }
          .width('100%')

          // 2026-09-19 清理：删掉「关闭提示」（`disableSuperResolutionWarning`）——
          // 除本页外没有任何地方读它，提示并不会因此消失；「默认行为」分组随之空掉。

          Blank().height(Dimens.contentBottomSpacer)
        }
        .width('100%')
        .padding({
          left: Dimens.contentInset,
          right: Dimens.contentInset,
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
}
