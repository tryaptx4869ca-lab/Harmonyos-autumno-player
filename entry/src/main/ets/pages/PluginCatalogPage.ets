import { AppColor } from '../theme/AppColors';
import { LoadingIndicator } from '../components/LoadingIndicator';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { Plugin } from '../plugins/Plugin';
import { PluginHttpItem } from '../model/PluginHttpItem';
import { Logger } from '../services/Logger';
import { PluginManager } from '../services/plugin/PluginManager';
import { UnavailablePlugins } from '../services/plugin/UnavailablePlugins';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';
import {
  PluginBatchUpdateResult,
  PluginCatalogItemStatus,
  PluginUpdateResult,
  PluginUpdateService
} from '../services/plugin/PluginUpdateService';

const TAG: string = 'AutumnPluginCatalog';

/**
 * 规则仓库（规格 §23.2 `/settings/plugin/shop` / `plugin_catalog_view.dart`）。
 *
 *   - 头部：「发现更多来源 / 浏览社区规则，为你的番剧搜索添加更多选择。」
 *   - 工具条：排序切换（名称排序 / 最近更新）+「规则仓库 · 已安装 N」
 *   - 列表项：规则名 + 版本胶囊（+「含验证支持」）+ 作者 / 描述；右侧状态：
 *     已安装 / 可更新 / 安装
 *   - 拉目录失败时显示「刷新失败，正在显示上次获取的规则。」或空态「无法访问规则仓库」
 */
@Component
export struct PluginCatalogPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('themeRevision') themeRevision: number = 0;
  @State private items: PluginHttpItem[] = [];
  @State private installedCount: number = 0;
  @State private loading: boolean = true;
  @State private failed: boolean = false;
  @State private errorMessage: string = '';
  /** 0 最近更新 / 1 名称排序。 */
  @State private sortKind: number = 0;
  @State private query: string = '';
  @State private busyName: string = '';
  @State private updatingAll: boolean = false;
  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      this.items = await PluginUpdateService.ensureCatalog();
      this.failed = false;
      this.errorMessage = '';
    } catch (error) {
      const err = error as Error;
      this.items = PluginUpdateService.currentCatalog();
      this.failed = true;
      this.errorMessage = err.message;
      Logger.warn(TAG, `规则仓库加载失败：${err.message}`);
    } finally {
      this.loading = false;
      this.installedCount = PluginManager.pluginList.length;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private visibleItems(): PluginHttpItem[] {
    const keyword: string = this.query.trim().toLowerCase();
    const out: PluginHttpItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const item: PluginHttpItem = this.items[i];
      // 已失效的规则不进仓库列表（名单见 `UnavailablePlugins`）
      if (UnavailablePlugins.isUnavailable(item.name)) {
        continue;
      }
      if (keyword.length > 0
        && item.name.toLowerCase().indexOf(keyword) < 0) {
        continue;
      }
      out.push(item);
    }
    if (this.sortKind === 1) {
      out.sort((a: PluginHttpItem, b: PluginHttpItem) =>
        a.name.localeCompare(b.name));
    }
    return out;
  }

  private statusLabel(item: PluginHttpItem): string {
    const status: PluginCatalogItemStatus =
      PluginUpdateService.catalogItemStatus(item);
    if (status === PluginCatalogItemStatus.installed) {
      return '已安装';
    }
    return status === PluginCatalogItemStatus.update ? '可更新' : '安装';
  }

  private async installOrUpdate(item: PluginHttpItem): Promise<void> {
    if (this.busyName.length > 0 || this.updatingAll) {
      return;
    }
    this.busyName = item.name;
    try {
      const result: PluginUpdateResult =
        await PluginUpdateService.tryUpdateByName(item.name);
      this.installedCount = PluginManager.pluginList.length;
      if (result === PluginUpdateResult.updated) {
        this.toast(`已安装 / 更新「${item.name}」`);
      } else if (result === PluginUpdateResult.notNewer) {
        this.toast('已经是最新版本');
      } else if (result === PluginUpdateResult.requiresNewerClient) {
        this.toast('规则需要更高版本客户端');
      } else {
        this.toast('安装失败，请稍后重试');
      }
      Logger.info(TAG, `规则仓库操作：${item.name} → ${result}`);
    } catch (error) {
      const err = error as Error;
      this.toast(`安装失败：${err.message}`);
    } finally {
      this.busyName = '';
    }
  }

  private async updateAll(): Promise<void> {
    if (this.updatingAll || this.busyName.length > 0) {
      return;
    }
    this.updatingAll = true;
    this.toast('正在批量更新…');
    try {
      const result: PluginBatchUpdateResult =
        await PluginUpdateService.tryUpdateAll(false);
      this.installedCount = PluginManager.pluginList.length;
      this.toast(`批量更新完成：成功 ${result.updated} 条，失败 ${result.failed} 条`);
    } catch (error) {
      const err = error as Error;
      this.toast(`批量更新失败：${err.message}`);
    } finally {
      this.updatingAll = false;
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
      // 退出：与参照实现同一条 Fade + Slide（Offset(0, 0.02)）——下滑 2% 的同时淡出
      .translate({ y: RouteTable.slideOffset() })
  }

  build() {
    Column() {
      // 沉浸式悬浮标题层（2026-09-19）
      ImmersiveTitleLayer({
        themeRev: this.themeRevision,
        title: '规则仓库',
        onBack: () => {
          RouteTable.back();
        }
      })

      Scroll() {
        Column() {
          // 头部
          Column() {
            Text('发现更多来源')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.onSurface)
              .width('100%')
            Text('浏览社区规则，为你的番剧搜索添加更多选择。')
              .fontSize(13)
              .fontColor(AppColor.onSurfaceVariant)
              .width('100%')
              .margin({ top: 6 })
            Row({ space: 12 }) {
              Text(this.sortKind === 0 ? '最近更新' : '名称排序')
                .fontSize(14)
                .fontColor(AppColor.onSecondaryContainer)
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                .backgroundColor(AppColor.secondaryContainer)
                .borderRadius(20)
                .onClick(() => {
                  this.sortKind = this.sortKind === 0 ? 1 : 0;
                })
              Text(this.updatingAll ? '更新中…' : '批量更新')
                .fontSize(14)
                .fontColor(AppColor.onSurfaceVariant)
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                .backgroundColor(AppColor.surfaceContainerHighest)
                .borderRadius(20)
                .onClick(() => {
                  this.updateAll();
                })
            }
            .width('100%')
            .margin({ top: 14 })
          }
          .width('100%')
          .padding(20)
          .borderRadius(28)
          .backgroundColor(AppColor.surfaceContainerLow)

          // 搜索 + 状态行
          Row() {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(18)
              .fontColor([AppColor.onSurfaceVariant])
              .margin({ left: 16 })
            TextInput({ text: this.query, placeholder: '搜索规则名称' })
              .placeholderColor(AppColor.onSurfaceVariant)
              .backgroundColor(Color.Transparent)
              .fontSize(15)
              .fontColor(AppColor.onSurface)
              .layoutWeight(1)
              .padding({ left: 12, right: 12 })
              .onChange((value: string) => {
                this.query = value;
              })
          }
          .width('100%')
          .constraintSize({ minHeight: 56 })
          .backgroundColor(AppColor.surfaceContainerHigh)
          .borderRadius(28)
          .margin({ top: 20 })

          Text(this.loading
            ? '正在获取规则仓库…'
            : `规则仓库 · 已安装 ${this.installedCount}`)
            .fontSize(13)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ top: 12 })

          if (this.failed) {
            Row({ space: 12 }) {
              Text(this.items.length > 0
                ? '刷新失败，正在显示上次获取的规则。'
                : '无法访问规则仓库，请检查网络或自定义仓库地址。')
                .fontSize(12)
                .fontColor(AppColor.error)
                .layoutWeight(1)
              Text('重试')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.primary)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .onClick(() => {
                  this.load();
                })
            }
            .width('100%')
            .margin({ top: 6 })
          }

          // 列表
          if (!this.loading && this.visibleItems().length === 0) {
            Column() {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(40)
                .fontColor([AppColor.onSurfaceVariant])
              Text(this.items.length === 0 ? '仓库暂无规则' : '没有符合条件的规则')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.onSurface)
                .margin({ top: 14 })
              Text(this.items.length === 0
                ? '稍后再试，或检查网络与镜像设置'
                : '换个关键词试试')
                .fontSize(13)
                .fontColor(AppColor.onSurfaceVariant)
                .margin({ top: 8 })
            }
            .width('100%')
            .height(220)
            .justifyContent(FlexAlign.Center)
          } else {
            Column({ space: 4 }) {
              ForEach(this.visibleItems(), (item: PluginHttpItem, index: number) => {
                Row() {
                  Column() {
                    Row() {
                      Text(item.name)
                        .fontSize(16)
                        .fontColor(AppColor.onSurface)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(item.version)
                        .fontSize(12)
                        .fontColor(AppColor.onSurfaceVariant)
                        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                        .backgroundColor(AppColor.surfaceContainerHighest)
                        .borderRadius(10)
                        .margin({ left: 8 })
                    }
                    .width('100%')

                    Text(this.authorLine(item))
                      .fontSize(12)
                      .fontColor(AppColor.onSurfaceVariant)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                      .margin({ top: 4 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  if (this.busyName === item.name) {
                    LoadingIndicator({ sizeVp: 22 })
                      .margin({ left: 12 })
                  } else {
                    Text(this.statusLabel(item))
                      .fontSize(13)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(PluginUpdateService.catalogItemStatus(item)
                        === PluginCatalogItemStatus.install
                        ? AppColor.onPrimary : AppColor.onSurfaceVariant)
                      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                      .backgroundColor(PluginUpdateService.catalogItemStatus(item)
                        === PluginCatalogItemStatus.install
                        ? AppColor.primary : AppColor.surfaceContainerHighest)
                      .borderRadius(18)
                      .margin({ left: 12 })
                      .onClick(() => {
                        this.installOrUpdate(item);
                      })
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 14, bottom: 14 })
                .borderRadius({
                  topLeft: index === 0 ? 24 : 4,
                  topRight: index === 0 ? 24 : 4,
                  bottomLeft: index === this.visibleItems().length - 1 ? 24 : 4,
                  bottomRight: index === this.visibleItems().length - 1 ? 24 : 4
                })
                .backgroundColor(AppColor.surfaceContainerLow)
              }, (item: PluginHttpItem) => `${item.name}:${item.version}`)
            }
            .width('100%')
            .margin({ top: 16 })
          }

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

  /** 作者与描述一行（`PluginHttpItem` 的可选字段）。 */
  private authorLine(item: PluginHttpItem): string {
    const parts: string[] = [];
    if (item.author.length > 0) {
      parts.push(item.author);
    }
    if (item.useNativePlayer) {
      parts.push('原生播放器');
    }
    if (item.antiCrawlerEnabled) {
      parts.push('含验证支持');
    }
    return parts.join(' · ');
  }

}
