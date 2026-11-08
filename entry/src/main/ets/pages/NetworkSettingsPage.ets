import { AppColor } from '../theme/AppColors';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { SectionHeader, SettingsRow, SettingsRowKind } from '../components/SettingsList';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';
import { PluginCatalogApi } from '../services/plugin/PluginCatalogApi';
import { PluginUpdateService } from '../services/plugin/PluginUpdateService';

/**
 * 网络设置（规格 §43.8 / `proxy/proxy_settings_page.dart`）。
 *
 * **2026-09-20：代理一节整块下线**（用户要求），现在只剩「镜像」一组：
 *   Bangumi 镜像（`enableBangumiProxy`）、规则仓库镜像（`enableGitProxy`）。
 *
 * 代理那部分（启用开关的「未测试不许开」闸门、`ProxyEditorPage` 编辑页）在
 * 参照实现里是完整的一页，本工程也已实现过；用户明确表示不需要这个入口，
 * 于是把 UI 摘掉、**保留底层设置键与网络层读取逻辑**（已设过代理的设备不受影响）。
 * 需要恢复时看 git 历史里这一节的原始实现即可（`proxyConfigured` 闸门语义：
 * 为假时点「启用代理」提示「请先在代理配置中完成测试」并拒绝开启）。
 */
@Component
export struct NetworkSettingsPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('themeRevision') themeRevision: number = 0;
  @State private bangumiProxy: boolean = true;
  @State private coverFailurePlaceholder: boolean = false;
  @State private gitProxy: boolean = true;
  @State private customRepo: string = '';

  aboutToAppear(): void {
    this.reload();
  }

  @StorageProp('navShown:pages/NetworkSettingsPage') @Watch('onNavShown') navShownTick: number = 0;

  onNavShown(): void {
    this.reload();
  }

  private reload(): void {
    this.bangumiProxy = SettingsStore.getBool(SettingsKeys.enableBangumiProxy);
    this.coverFailurePlaceholder =
      SettingsStore.getBool(SettingsKeys.enableCoverFailurePlaceholder);
    this.gitProxy = SettingsStore.getBool(SettingsKeys.enableGitProxy);
    this.customRepo = SettingsStore.getString(SettingsKeys.ruleRepositoryBase);
  }

  private async saveCustomRepo(): Promise<void> {
    const raw: string = this.customRepo.trim();
    const normalized: string = PluginCatalogApi.normalizeRepositoryBase(raw);
    if (raw.length > 0 && normalized.length === 0) {
      this.getUIContext().getPromptAction().showToast({
        message: '请填写 HTTPS raw 目录，例如 .../raw/master/'
      });
      return;
    }
    this.customRepo = normalized;
    SettingsStore.put(SettingsKeys.ruleRepositoryBase, normalized);
    PluginUpdateService.invalidateCatalogFreshness();
    this.getUIContext().getPromptAction().showToast({
      message: '正在验证规则仓库…'
    });
    try {
      const items = await PluginUpdateService.refreshCatalog();
      this.getUIContext().getPromptAction().showToast({
        message: `规则仓库连接成功，共 ${items.length} 条`
      });
    } catch (error) {
      const err = error as Error;
      this.getUIContext().getPromptAction().showToast({
        message: `地址已保存，但暂未连通：${err.message}`
      });
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
      // 沉浸式悬浮标题层（2026-09-19）：内容铺满整页、从标题下面滚过去
      ImmersiveTitleLayer({
        themeRev: this.themeRevision,
        title: '网络设置',
        onBack: () => {
          RouteTable.back();
        }
      })

      Scroll() {
        Column() {
          SectionHeader({ title: '镜像与封面' })
          Column({ space: 4 }) {
            SettingsRow({
              title: 'Bangumi 镜像',
              description: '通过镜像访问番剧信息与图片，加快加载',
              kind: SettingsRowKind.toggle,
              checked: this.bangumiProxy,
              topRadius: 24,
              bottomRadius: 4,
              onToggle: (value: boolean) => {
                this.bangumiProxy = value;
                SettingsStore.put(SettingsKeys.enableBangumiProxy, value);
              }
            })
            SettingsRow({
              title: '封面加载占位图',
              description: '0.5 秒仍未加载完成或加载失败时显示开屏图，成功后自动撤掉',
              kind: SettingsRowKind.toggle,
              checked: this.coverFailurePlaceholder,
              topRadius: 4,
              bottomRadius: 4,
              onToggle: (value: boolean) => {
                this.coverFailurePlaceholder = value;
                SettingsStore.put(SettingsKeys.enableCoverFailurePlaceholder, value);
                if (value) {
                  this.getUIContext().getPromptAction().showToast({
                    message: '已开启，重新进入页面后生效'
                  });
                }
              }
            })
            SettingsRow({
              title: '规则仓库镜像',
              description: '通过镜像获取规则目录与规则文件',
              kind: SettingsRowKind.toggle,
              checked: this.gitProxy,
              topRadius: 4,
              bottomRadius: 24,
              onToggle: (value: boolean) => {
                this.gitProxy = value;
                SettingsStore.put(SettingsKeys.enableGitProxy, value);
                PluginUpdateService.invalidateCatalogFreshness();
              }
            })
          }
          .width('100%')

          Column() {
            Text('自定义规则仓库')
              .fontSize(16)
              .fontColor(AppColor.onSurface)
              .width('100%')
            Text('可填 Gitee / GitCode 的 raw 目录。留空时使用内置镜像与上游仓库。')
              .fontSize(12)
              .fontColor(AppColor.onSurfaceVariant)
              .width('100%')
              .margin({ top: 4 })
            TextInput({
              text: this.customRepo,
              placeholder: 'https://gitee.com/用户/仓库/raw/master/'
            })
              .height(48)
              .fontSize(13)
              .fontColor(AppColor.onSurface)
              .placeholderColor(AppColor.onSurfaceVariant)
              .backgroundColor(AppColor.surfaceContainerHighest)
              .borderRadius(14)
              .margin({ top: 12 })
              .onChange((value: string) => {
                this.customRepo = value;
              })
            Row({ space: 12 }) {
              Text('保存并刷新目录')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.onPrimary)
                .padding({ left: 16, right: 16, top: 9, bottom: 9 })
                .backgroundColor(AppColor.primary)
                .borderRadius(18)
                .onClick(() => {
                  this.saveCustomRepo();
                })
              Text('清空')
                .fontSize(13)
                .fontColor(AppColor.onSurfaceVariant)
                .padding({ left: 12, right: 12, top: 9, bottom: 9 })
                .onClick(() => {
                  this.customRepo = '';
                  this.saveCustomRepo();
                })
            }
            .width('100%')
            .margin({ top: 10 })
          }
          .width('100%')
          .padding(16)
          .margin({ top: 12 })
          .borderRadius(20)
          .backgroundColor(AppColor.surfaceContainerLow)

          /**
           * ⚠️ **代理一节整块去掉**（用户 2026-09-20：「去掉设置里关于网络代理的部分」）。
           *
           * 去掉的只是**入口**：`SettingsKeys.proxyEnable` / `proxyUrl` 这些键仍然被
           * 网络层读取（`NetworkConfig.fromSettings()`），所以已经设过代理的设备
           * 行为不变、也不会因为这次改动把代理「悄悄关掉」。
           * `pages/ProxyEditorPage.ets` 保留在工程里（当前没有入口）；哪天要恢复，
           * 把这一节连同 `toggleProxy` / `proxySummary` 一起接回来即可。
           */

          Text('镜像只影响本机网络访问；关闭后立即恢复直连。')
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ top: 12 })

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
