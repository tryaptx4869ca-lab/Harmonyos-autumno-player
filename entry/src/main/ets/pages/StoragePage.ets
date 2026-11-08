import { common } from '@kit.AbilityKit';
import { AppColor } from '../theme/AppColors';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';
import { RouteTable } from '../router/RouteTable';
import { CacheUsage, DirUsage, StorageUsage } from '../services/storage/CacheUsage';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';
import { Logger } from '../services/Logger';
import { DownloadManager } from '../services/DownloadManager';

/**
 * 存储管理（我的 → 存储管理，规格 §7.4 `/settings/storage`）。
 *
 * 缓存大小用 `AbilityContext` 的三个目录**递归求和**（见 `CacheUsage`），
 * 清理只动 cacheDir —— 与源码一致：用户数据（规则 / 收藏 / 搜索历史）
 * 不随「清理缓存」丢失。
 */
@Component
export struct StoragePage {
  @StorageProp('topInset') topInset: number = 39;
  @State usage: StorageUsage = new StorageUsage();
  @State clearing: boolean = false;

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.usage = CacheUsage.compute(context);
  }

  private clearCache(): void {
    this.clearing = true;
    const context = getContext(this) as common.UIAbilityContext;
    const freed: number = CacheUsage.clearCache(context);
    this.refresh();
    this.clearing = false;
    this.toast(`已清理 ${CacheUsage.formatBytes(freed)}`);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 提示失败不影响主流程
    }
  }

  /** 「错误日志」那行的副标题：日志文件大小（§43.3）。 */
  private logText(): string {
    const bytes: number = Logger.usedBytes();
    return bytes === 0
      ? '暂无日志' : `${CacheUsage.formatBytes(bytes)} · 点击查看与导出`;
  }

  /** 二级页转场（§12.4）。 */
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
        title: '存储管理',
        onBack: () => {
          RouteTable.back();
        }
      })
      Scroll() {
        Column() {
          // 总览
          Column() {
            Text(CacheUsage.formatBytes(this.usage.totalBytes()))
              .fontSize(34)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.onSurface)
            Text('应用总占用')
              .fontSize(13)
              .fontColor(AppColor.onSurfaceVariant)
              .margin({ top: 4 })
            Row() {
              Column() {
                Text(CacheUsage.formatBytes(this.usage.cacheBytes))
                  .fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor(AppColor.onSurface)
                Text('缓存').fontSize(12)
                  .fontColor(AppColor.onSurfaceVariant).margin({ top: 2 })
              }.layoutWeight(1)
              Column() {
                Text(CacheUsage.formatBytes(this.usage.dataBytes))
                  .fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor(AppColor.onSurface)
                Text('数据').fontSize(12)
                  .fontColor(AppColor.onSurfaceVariant).margin({ top: 2 })
              }.layoutWeight(1)
              Column() {
                Text(CacheUsage.formatBytes(this.usage.systemBytes))
                  .fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor(AppColor.onSurface)
                Text('系统').fontSize(12)
                  .fontColor(AppColor.onSurfaceVariant).margin({ top: 2 })
              }.layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 16 })
          }
          .width('100%')
          .padding({ top: 20, bottom: 20 })
          .borderRadius(28)
          .backgroundColor(AppColor.surfaceContainerHigh)

          Row() {
            Column() {
              Text('清理缓存').fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.onSurface)
              Text('只删除可再生成的临时文件，规则与收藏不受影响')
                .fontSize(12)
                .fontColor(AppColor.onSurfaceVariant)
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button(this.clearing ? '清理中…' : '清理')
              .fontSize(14)
              .height(40)
              .enabled(!this.clearing)
              .onClick(() => {
                this.clearCache();
              })
          }
          .width('100%')
          .padding(16)
          .margin({ top: 12 })
          .borderRadius(24)
          .backgroundColor(AppColor.surfaceContainerLow)

          // 诊断：错误日志（§43.3 的「诊断 → 错误日志」）
          Row() {
            Column() {
              Text('错误日志')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.onSurface)
              Text(this.logText())
                .fontSize(12)
                .fontColor(AppColor.onSurfaceVariant)
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.arrow_right'))
              .fontSize(18)
              .fontColor([AppColor.onSurfaceVariant])
          }
          .width('100%')
          .padding(16)
          .margin({ top: 12 })
          .borderRadius(24)
          .backgroundColor(AppColor.surfaceContainerLow)
          .onClick(() => {
            RouteTable.push(RouteTable.logs);
          })

          // 明细
          Text('缓存明细')
            .fontSize(14)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .padding({ left: 4, top: 24, bottom: 8 })
          this.cacheEntryList()

          Text('数据明细')
            .fontSize(14)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .padding({ left: 4, top: 24, bottom: 8 })
          this.dataEntryList()

          // 下载目录在鸿蒙上不可选：直接把应用私有目录的真实路径写出来
          Text(`下载目录：${DownloadManager.directory()}`)
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .padding({ left: 4, top: 20 })

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

  @Builder
  cacheEntryList() {
    Column() {
      if (this.usage.cacheEntries.length === 0) {
        Text('缓存目录为空')
          .fontSize(13)
          .fontColor(AppColor.onSurfaceVariant)
          .width('100%')
          .padding({ top: 12, bottom: 12 })
      } else {
        ForEach(this.usage.cacheEntries, (entry: DirUsage, index: number) => {
          Column() {
            Row() {
              Text(entry.isDirectory ? `📁 ${entry.name}` : entry.name)
                .fontSize(14)
                .fontColor(AppColor.onSurface)
                .layoutWeight(1)
              Text(CacheUsage.formatBytes(entry.bytes))
                .fontSize(13)
                .fontColor(AppColor.onSurfaceVariant)
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            if (index < this.usage.cacheEntries.length - 1) {
              Divider().color(AppColor.outlineVariant)
            }
          }
          .width('100%')
        }, (entry: DirUsage) => `${entry.name}-${entry.bytes}`)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .borderRadius(24)
    .backgroundColor(AppColor.surfaceContainerLow)
  }

  @Builder
  dataEntryList() {
    Column() {
      if (this.usage.dataEntries.length === 0) {
        Text('还没有写入任何数据')
          .fontSize(13)
          .fontColor(AppColor.onSurfaceVariant)
          .width('100%')
          .padding({ top: 12, bottom: 12 })
      } else {
        ForEach(this.usage.dataEntries, (entry: DirUsage, index: number) => {
          Column() {
            Row() {
              Text(entry.isDirectory ? `📁 ${entry.name}` : entry.name)
                .fontSize(14)
                .fontColor(AppColor.onSurface)
                .layoutWeight(1)
              Text(CacheUsage.formatBytes(entry.bytes))
                .fontSize(13)
                .fontColor(AppColor.onSurfaceVariant)
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            if (index < this.usage.dataEntries.length - 1) {
              Divider().color(AppColor.outlineVariant)
            }
          }
          .width('100%')
        }, (entry: DirUsage) => `${entry.name}-${entry.bytes}`)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .borderRadius(24)
    .backgroundColor(AppColor.surfaceContainerLow)
  }
}
