import { AppColor } from '../theme/AppColors';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { SectionHeader, SettingsRow, SettingsRowKind } from '../components/SettingsList';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';
import { NavScrollController } from '../components/NavScrollController';

/**
 * 界面设置（规格 §43.4 / `interface_settings.dart`）。
 *
 * 一组：展示信息（显示评分）。
 *
 * 2026-09-19 清理：删掉「启动界面设置」（`defaultStartupPage`）——全工程没有
 * 任何地方读这个键，选完照样从推荐页起。原来的「启动」分组随之整组消失。
 */
@Component
export struct InterfaceSettingsPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('themeRevision') themeRevision: number = 0;
  @State private fixedNavigationBar: boolean = false;
  @State private showRating: boolean = true;

  aboutToAppear(): void {
    this.fixedNavigationBar =
      SettingsStore.getBool(SettingsKeys.fixedNavigationBar);
    this.showRating = SettingsStore.getBool(SettingsKeys.showRating);
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
        // 沉浸式悬浮标题层（2026-09-19）
        ImmersiveTitleLayer({
          themeRev: this.themeRevision,
          title: '界面设置',
          onBack: () => {
            RouteTable.back();
          }
        })

        Scroll() {
          Column() {
            SectionHeader({ title: '导航' })
            SettingsRow({
              title: '固定导航栏',
              description: '开启后滚动页面时底部导航保持显示',
              kind: SettingsRowKind.toggle,
              checked: this.fixedNavigationBar,
              topRadius: 24,
              bottomRadius: 24,
              onToggle: (value: boolean) => {
                this.fixedNavigationBar = value;
                SettingsStore.put(SettingsKeys.fixedNavigationBar, value);
                NavScrollController.setHidden(false);
              }
            })

            Blank().height(8)
            SectionHeader({ title: '展示信息' })
            SettingsRow({
              title: '显示评分',
              description: '关闭后将在概览中隐藏评分信息',
              kind: SettingsRowKind.toggle,
              checked: this.showRating,
              topRadius: 24,
              bottomRadius: 24,
              onToggle: (value: boolean) => {
                this.showRating = value;
                SettingsStore.put(SettingsKeys.showRating, value);
              }
            })

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
    .width('100%')
    .height('100%')
  }
}
