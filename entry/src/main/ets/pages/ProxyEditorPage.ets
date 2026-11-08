import { AppColor } from '../theme/AppColors';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { SectionHeader } from '../components/SettingsList';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';
import { ProxyTester } from '../services/ProxyTester';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';

/**
 * 代理配置（规格 §43.8 / `proxy/proxy_editor_page.dart`）。
 *
 * 两个输入：代理地址（`proxyUrl`）、测试地址（`proxyTestUrl`）；
 * 一个「测试连接」按钮。文案与联动逐条对齐源码：
 *   - 地址为空 → 「请输入代理地址」
 *   - 成功 → 「测试成功」+ 写 `proxyConfigured = true` + 自动开启代理
 *   - 失败 → 「代理连接失败」+ 写 false + 关闭代理
 */
@Component
export struct ProxyEditorPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('themeRevision') themeRevision: number = 0;
  @State private url: string = '';
  @State private testUrl: string = '';
  @State private testing: boolean = false;

  aboutToAppear(): void {
    this.url = SettingsStore.getString(SettingsKeys.proxyUrl);
    this.testUrl = SettingsStore.getString(SettingsKeys.proxyTestUrl);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async runTest(): Promise<void> {
    if (this.testing) {
      return;
    }
    if (this.url.trim().length === 0) {
      this.toast('请输入代理地址');
      return;
    }
    this.testing = true;
    this.toast('正在测试连接…');
    SettingsStore.put(SettingsKeys.proxyUrl, this.url.trim());
    SettingsStore.put(SettingsKeys.proxyTestUrl, this.testUrl.trim());
    const failure: string = await ProxyTester.test(this.url, this.testUrl);
    this.testing = false;
    if (failure.length === 0) {
      SettingsStore.put(SettingsKeys.proxyConfigured, true);
      SettingsStore.put(SettingsKeys.proxyEnable, true);
      this.toast('测试成功');
    } else {
      SettingsStore.put(SettingsKeys.proxyConfigured, false);
      SettingsStore.put(SettingsKeys.proxyEnable, false);
      this.toast(`代理连接失败：${failure}`);
    }
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
        title: '代理配置',
        onBack: () => {
          RouteTable.back();
        }
      })

      Scroll() {
        Column() {
          SectionHeader({ title: '服务器' })
          Column() {
            Column({ space: 6 }) {
              Text('服务器地址')
                .fontSize(14)
                .fontColor(AppColor.onSurface)
                .width('100%')
              TextInput({ text: this.url, placeholder: 'http://127.0.0.1:7890' })
                .fontSize(15)
                .onChange((value: string) => {
                  this.url = value;
                })
            }
            .width('100%')

            Column({ space: 6 }) {
              Text('测试地址')
                .fontSize(14)
                .fontColor(AppColor.onSurface)
                .width('100%')
              TextInput({ text: this.testUrl, placeholder: 'https://www.bing.com' })
                .fontSize(15)
                .onChange((value: string) => {
                  this.testUrl = value;
                })
            }
            .width('100%')
            .margin({ top: 16 })

            Text('支持 http / https / socks 前缀，也可省略前缀只填「主机:端口」。')
              .fontSize(12)
              .fontColor(AppColor.onSurfaceVariant)
              .width('100%')
              .margin({ top: 12 })

            Row() {
              Text(this.testing ? '正在测试连接…' : '测试连接')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.onPrimary)
            }
            .width('100%')
            .height(48)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(this.testing ? AppColor.surfaceContainerHighest : AppColor.primary)
            .borderRadius(24)
            .margin({ top: 16 })
            .onClick(() => {
              this.runTest();
            })
          }
          .width('100%')
          .padding(16)
          .borderRadius(24)
          .backgroundColor(AppColor.surfaceContainerLow)

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
