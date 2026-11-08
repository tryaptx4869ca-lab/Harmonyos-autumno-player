import { AppColor } from '../theme/AppColors';
import { BangumiImageUrlRewriter } from '../services/BangumiImageUrlRewriter';
import { CoverImage } from '../components/CoverImage';
import { LoadingIndicator } from '../components/LoadingIndicator';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { OfflineEpisode, VideoRouteArgs } from '../router/RouteArgs';
import { BangumiItem } from '../model/BangumiItem';
import {
  DownloadEpisode,
  DownloadRecord,
  DownloadStats,
  DownloadStatus
} from '../model/DownloadModels';
import { DownloadManager } from '../services/DownloadManager';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';
import { CacheUsage } from '../services/storage/CacheUsage';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';

/**
 * 离线下载（规格 §51.1 / §18 / §66）。
 *
 * 页面三块：
 *   1. 统计条：N 部 · 已完成 M 集 · 占用 X（下载中附带速度）
 *   2. 记录列表：作品卡（封面 + 名称 + 规则）+ 每集一行（状态角标、进度、操作）
 *   3. 下载设置：并发集数 / 并行分片 / 缓存弹幕 / 下载目录（§43.2）
 *
 * 交互：
 *   - 已完成的一集 → 点行进**离线播放**（`VideoRouteArgs.offline`，播放页跳过取流）
 *   - 下载中 → 暂停；已暂停 / 失败 → 继续（继续会复用已下分片，即断点续传）
 *   - 删除单集 / 删除整部：都走二次确认（源码 `_confirmDeleteEpisode` / `_confirmDeleteRecord`）
 */
@Component
export struct DownloadPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('themeRevision') themeRevision: number = 0;
  /** 订阅下载变更：管理器每写一次进度都会 +1。 */
  @StorageProp('downloadRevision') @Watch('onDownloadChanged') downloadRevision: number = 0;

  @State private records: DownloadRecord[] = [];
  @State private stats: DownloadStats = new DownloadStats();
  @State private speedText: string = '';
  /** 每 1 秒重算一次速度文案（管理器内部 3 秒采样）。 */
  private speedTimer: number = -1;

  // 下载设置
  @State private parallelEpisodes: number = 2;
  @State private parallelSegments: number = 3;
  @State private downloadDanmaku: boolean = true;
  @State private directory: string = '';

  private confirmDialog: CustomDialogController | null = null;
  private pendingDeleteRecord: string = '';
  private pendingDeleteEpisode: number = 0;

  aboutToAppear(): void {
    this.loadSettings();
    this.reload();
    this.confirmDialog = new CustomDialogController({
      builder: DownloadConfirmDialog({
        title: '',
        message: '',
        confirmLabel: '删除',
        onConfirm: () => {
        }
      }),
      autoCancel: true,
      customStyle: false
    });
    this.speedTimer = setInterval(() => {
      this.refreshSpeed();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.speedTimer >= 0) {
      clearInterval(this.speedTimer);
      this.speedTimer = -1;
    }
  }

  onDownloadChanged(): void {
    this.reload();
  }

  @StorageProp('navShown:pages/DownloadPage') @Watch('onNavShown') navShownTick: number = 0;

  onNavShown(): void {
    this.reload();
  }

  private loadSettings(): void {
    this.parallelEpisodes =
      SettingsStore.getNumber(SettingsKeys.downloadParallelEpisodes);
    this.parallelSegments =
      SettingsStore.getNumber(SettingsKeys.downloadParallelSegments);
    this.downloadDanmaku =
      SettingsStore.getBool(SettingsKeys.downloadDanmaku);
    // 下载目录在鸿蒙上不可选，直接显示**实际路径**（`DownloadManager` 的根目录）
    this.directory = DownloadManager.directory();
  }

  private reload(): void {
    this.records = DownloadManager.all();
    this.stats = DownloadManager.stats();
    this.refreshSpeed();
  }

  private refreshSpeed(): void {
    const bytesPerSecond: number = DownloadManager.speed();
    this.speedText = bytesPerSecond > 0
      ? ` · ${CacheUsage.formatBytes(bytesPerSecond)}/s` : '';
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private static statusColor(status: number): string {
    if (status === DownloadStatus.completed) {
      return AppColor.primary;
    }
    if (status === DownloadStatus.failed) {
      return AppColor.error;
    }
    return AppColor.onSurfaceVariant;
  }

  /** 点一集：完成 → 离线播放；其它状态 → 暂停 / 继续。 */
  private onEpisodeTap(record: DownloadRecord, episode: DownloadEpisode): void {
    if (episode.status === DownloadStatus.completed) {
      this.playOffline(record, episode);
      return;
    }
    if (episode.status === DownloadStatus.downloading
      || episode.status === DownloadStatus.pending
      || episode.status === DownloadStatus.resolving) {
      DownloadManager.pause(record.key(), episode.episodeNumber);
      this.toast(`已暂停第 ${episode.episodeNumber} 集`);
      return;
    }
    const resumed: boolean = DownloadManager.resume(record.key(), episode.episodeNumber);
    this.toast(resumed ? `继续下载第 ${episode.episodeNumber} 集` : '这一集没有可续的地址');
  }

  /**
   * 离线播放：把该作品**所有已完成**的集拼成一条线路交给播放页。
   *
   * 只带本地清单路径，播放页看到 `offlinePlaylistPath` 就跳过取流。
   */
  private playOffline(record: DownloadRecord, episode: DownloadEpisode): void {
    const episodes: OfflineEpisode[] = [];
    for (let i = 0; i < record.episodes.length; i++) {
      const item: DownloadEpisode = record.episodes[i];
      if (item.status === DownloadStatus.completed && item.localM3u8Path.length > 0) {
        episodes.push(OfflineEpisode.of(item.episodeNumber, item.episodeName,
          item.road, item.localM3u8Path));
      }
    }
    if (episodes.length === 0) {
      this.toast('这一集还没有下载完成');
      return;
    }
    const item = new BangumiItem();
    item.id = record.bangumiId;
    item.name = record.bangumiName;
    item.nameCn = record.bangumiName;
    const args: VideoRouteArgs = VideoRouteArgs.offline(item, record.pluginName,
      episode.localM3u8Path, episodes);
    args.preferredEpisode = episode.episodeNumber;
    args.preferredRoad = 0;
    VideoRouteArgs.open(args);
  }

  private confirmDeleteEpisode(record: DownloadRecord, episode: DownloadEpisode): void {
    this.pendingDeleteRecord = record.key();
    this.pendingDeleteEpisode = episode.episodeNumber;
    this.confirmDialog = new CustomDialogController({
      builder: DownloadConfirmDialog({
        title: '删除这一集？',
        message: `将删除「${record.bangumiName} 第${episode.episodeNumber}集」的缓存文件，此操作无法撤销。`,
        confirmLabel: '删除',
        onConfirm: () => {
          DownloadManager.deleteEpisodeFiles(this.pendingDeleteRecord,
            this.pendingDeleteEpisode);
          this.reload();
          this.toast('已删除该集缓存');
        }
      }),
      autoCancel: true,
      customStyle: false
    });
    this.confirmDialog.open();
  }

  private confirmDeleteRecord(record: DownloadRecord): void {
    this.pendingDeleteRecord = record.key();
    this.pendingDeleteEpisode = 0;
    this.confirmDialog = new CustomDialogController({
      builder: DownloadConfirmDialog({
        title: '删除整部缓存？',
        message: `将删除「${record.bangumiName}」的全部缓存与记录，此操作无法撤销。`,
        confirmLabel: '全部删除',
        onConfirm: () => {
          DownloadManager.deleteRecordFiles(this.pendingDeleteRecord);
          this.reload();
          this.toast('已删除该作品的缓存');
        }
      }),
      autoCancel: true,
      customStyle: false
    });
    this.confirmDialog.open();
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
      // 沉浸式悬浮标题层（2026-09-19）；「全部暂停 / 全部继续」作为标题右侧操作
      ImmersiveTitleLayer({
        themeRev: this.themeRevision,
        title: '离线下载',
        onBack: () => {
          RouteTable.back();
        }
      }) {
        if (this.records.length > 0) {
          Row() {
            Text('全部暂停')
              .fontSize(14)
              .fontColor(AppColor.primary)
              .padding({ left: 6, right: 6, top: 8, bottom: 8 })
              .onClick(() => {
                DownloadManager.pauseAll();
                this.toast('已暂停全部下载');
              })
            Text('全部继续')
              .fontSize(14)
              .fontColor(AppColor.primary)
              .padding({ left: 6, right: 6, top: 8, bottom: 8 })
              .onClick(() => {
                DownloadManager.resumeAll();
                this.toast('已继续全部下载');
              })
          }
        }
      }

      Scroll() {
        Column() {
          if (this.records.length === 0) {
            Column() {
              // §46.4：下载页空态图标 `download_rounded` → `download`
              SymbolGlyph($r('sys.symbol.download'))
                .fontSize(40)
                .fontColor([AppColor.onSurfaceVariant])
              Text('还没有下载任务')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.onSurface)
                .margin({ top: 14 })
              Text('在播放页的「更多 → 缓存本集」即可加入下载队列')
                .fontSize(13)
                .fontColor(AppColor.onSurfaceVariant)
                .margin({ top: 8 })
            }
            .width('100%')
            .height(240)
            .justifyContent(FlexAlign.Center)
          } else {
            // 统计条
            Column() {
              Text(`${this.stats.recordCount} 部作品 · 已完成 ${this.stats.completedCount} 集`
                + (this.stats.runningCount > 0
                  ? ` · 进行中 ${this.stats.runningCount} 集${this.speedText}` : ''))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.onSurface)
                .width('100%')
              Text(`占用 ${CacheUsage.formatBytes(this.stats.totalBytes)}`)
                .fontSize(12)
                .fontColor(AppColor.onSurfaceVariant)
                .width('100%')
                .margin({ top: 4 })
            }
            .width('100%')
            .padding(16)
            .borderRadius(24)
            .backgroundColor(AppColor.surfaceContainerHigh)

            ForEach(this.records, (record: DownloadRecord) => {
              this.recordCard(record)
            }, (record: DownloadRecord) => `${record.key()}:${record.episodes.length}`)
          }

          Text('下载设置')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.onSurface)
            .width('100%')
            .margin({ top: 20, bottom: 8 })

          Column() {
            Row() {
              Text('同时下载集数').fontSize(15)
                .fontColor(AppColor.onSurface).layoutWeight(1)
              Text(`${this.parallelEpisodes}`).fontSize(14)
                .fontColor(AppColor.onSurfaceVariant)
              Slider({
                value: this.parallelEpisodes, min: 1, max: 5, step: 1,
                style: SliderStyle.InSet
              })
                .width(140)
                .margin({ left: 8 })
                // 胶囊槽（与夏绊设置页、弹幕 / 下载设置页同款）：
                // 32vp 厚槽 + 18vp 白滑块，配色走 AppColor 的两个滑杆令牌。
                .trackThickness(32)
                .blockSize({ width: 18, height: 18 })
                .blockColor(AppColor.sliderBlock)
                .trackColor(AppColor.sliderTrack)
                .selectedColor(AppColor.primary)
                .onChange((value: number) => {
                  this.parallelEpisodes = Math.round(value);
                  SettingsStore.put(SettingsKeys.downloadParallelEpisodes,
                    this.parallelEpisodes);
                })
            }
            .width('100%')

            Row() {
              Text('同时下载分片').fontSize(15)
                .fontColor(AppColor.onSurface).layoutWeight(1)
              Text(`${this.parallelSegments}`).fontSize(14)
                .fontColor(AppColor.onSurfaceVariant)
              Slider({
                value: this.parallelSegments, min: 1, max: 5, step: 1,
                style: SliderStyle.InSet
              })
                .width(140)
                .margin({ left: 8 })
                .trackThickness(32)
                .blockSize({ width: 18, height: 18 })
                .blockColor(AppColor.sliderBlock)
                .trackColor(AppColor.sliderTrack)
                .selectedColor(AppColor.primary)
                .onChange((value: number) => {
                  this.parallelSegments = Math.round(value);
                  SettingsStore.put(SettingsKeys.downloadParallelSegments,
                    this.parallelSegments);
                })
            }
            .width('100%')
            .margin({ top: 12 })

            Row() {
              Text('同时下载弹幕').fontSize(15)
                .fontColor(AppColor.onSurface).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.downloadDanmaku })
                .onChange((isOn: boolean) => {
                  this.downloadDanmaku = isOn;
                  SettingsStore.put(SettingsKeys.downloadDanmaku, isOn);
                })
            }
            .width('100%')
            .margin({ top: 12 })

            Column() {
              Text('下载目录').fontSize(15)
                .fontColor(AppColor.onSurface)
                .width('100%')
              Text(this.directory.length > 0 ? this.directory : '跟随系统默认目录')
                .fontSize(12)
                .fontColor(AppColor.onSurfaceVariant)
                .width('100%')
                .margin({ top: 4 })
            }
            .width('100%')
            .margin({ top: 12 })
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

  /** 一部作品的下载卡：封面 + 名称 + 规则 + 每集一行。 */
  @Builder
  recordCard(record: DownloadRecord) {
    Column() {
      Row() {
        if (record.bangumiCover.length > 0) {
          // 下载记录里存的是原始封面地址，渲染前过一遍镜像改写
          CoverImage({
            src: BangumiImageUrlRewriter.rewriteWithSettings(record.bangumiCover),
            fit: ImageFit.Cover,
            radius: 10
          })
            .width(48)
            .height(64)
            .draggable(false)
        }
        Blank().width(12)
        Column() {
          Text(record.bangumiName)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.onSurface)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(`${record.pluginName} · ${record.episodes.length} 集`)
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('删除')
          .fontSize(13)
          .fontColor(AppColor.error)
          .padding({ left: 8, right: 4, top: 6, bottom: 6 })
          .onClick(() => {
            this.confirmDeleteRecord(record);
          })
      }
      .width('100%')

      ForEach(record.episodes, (episode: DownloadEpisode) => {
        Column() {
          Row() {
            // 状态徽标（对应参照实现 `_EpisodeStatusBadge`：36 圆，按状态换底色与字形）
            this.statusBadge(episode)
            Column() {
              Text(episode.episodeName.length > 0
                ? episode.episodeName : `第 ${episode.episodeNumber} 集`)
                .fontSize(14)
                .fontColor(AppColor.onSurface)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.episodeSubtitle(episode))
                .fontSize(11)
                .fontColor(DownloadPage.statusColor(episode.status))
                .maxLines(2)
                .width('100%')
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: 12 })

            // 动作按钮：按状态给一个（对应参照实现 `_getActionButtons`），末尾恒为删除
            if (episode.status === DownloadStatus.completed) {
              // `play_circle_outline` → `play_circle_fill`
              SymbolGlyph($r('sys.symbol.play_circle_fill'))
                .fontSize(20)
                .fontColor([AppColor.primary])
                .padding(8)
                .onClick(() => {
                  this.playOffline(record, episode);
                })
            } else if (episode.status === DownloadStatus.downloading) {
              // `pause_rounded` → `pause_fill`
              SymbolGlyph($r('sys.symbol.pause_fill'))
                .fontSize(20)
                .fontColor([AppColor.onSurface])
                .padding(8)
                .onClick(() => {
                  DownloadManager.pause(record.key(), episode.episodeNumber);
                })
            } else if (episode.status === DownloadStatus.paused) {
              // `play_arrow_rounded` → `play_fill`
              SymbolGlyph($r('sys.symbol.play_fill'))
                .fontSize(20)
                .fontColor([AppColor.onSurface])
                .padding(8)
                .onClick(() => {
                  DownloadManager.resume(record.key(), episode.episodeNumber);
                })
            } else if (episode.status === DownloadStatus.failed) {
              // `refresh_rounded` → `arrow_clockwise`
              SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                .fontSize(20)
                .fontColor([AppColor.onSurface])
                .padding(8)
                .onClick(() => {
                  DownloadManager.resume(record.key(), episode.episodeNumber);
                })
            }
            // `delete_outline` → `trash`
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(20)
              .fontColor([AppColor.onSurfaceVariant])
              .padding(8)
              .onClick(() => {
                this.confirmDeleteEpisode(record, episode);
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (episode.status === DownloadStatus.downloading) {
            Progress({
              value: episode.progressPercent,
              total: 100,
              type: ProgressType.Linear
            })
              .width('100%')
              .color(AppColor.primary)
              .margin({ top: 6 })
          }
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .onClick(() => {
          this.onEpisodeTap(record, episode);
        })
      }, (episode: DownloadEpisode) =>
        `${episode.episodeNumber}:${episode.status}:${episode.progressPercent}`)
    }
    .width('100%')
    .padding(16)
    .borderRadius(24)
    .backgroundColor(AppColor.surfaceContainerLow)
    .margin({ top: 12 })
  }

  /** 一集的副标题：分片进度 / 失败原因 / 文件大小。 */
  private episodeSubtitle(episode: DownloadEpisode): string {
    // 文案逐条对齐参照实现 `_getStatusText`
    if (episode.status === DownloadStatus.completed) {
      return `已完成 · ${CacheUsage.formatBytes(episode.totalBytes)}`;
    }
    if (episode.status === DownloadStatus.downloading) {
      const percent: number = Math.round(episode.progressPercent * 100);
      return `${percent}% · ${episode.downloadedSegments}/${episode.totalSegments} 分片`;
    }
    if (episode.status === DownloadStatus.failed) {
      return episode.errorMessage.length > 0 ? episode.errorMessage : '下载失败';
    }
    if (episode.status === DownloadStatus.paused) {
      return `已暂停 · ${Math.round(episode.progressPercent * 100)}%`;
    }
    if (episode.status === DownloadStatus.resolving) {
      return '正在解析视频源';
    }
    return '排队中';
  }

  /**
   * 一集的状态徽标（对应参照实现 `_EpisodeStatusBadge`）：
   * 36 圆，`surfaceContainerHighest` / `secondaryContainer` / `errorContainer` 换底，
   * 字形按 §46.4 映射（`check_rounded`→`checkmark`、`pause_rounded`→`pause_fill`、
   * `schedule_rounded`→`clock`、`error_outline_rounded`→`exclamationmark_circle_fill`）。
   * 「下载中」与「解析中」用转圈（22）而不是字形。
   */
  @Builder
  statusBadge(episode: DownloadEpisode) {
    Column() {
      if (episode.status === DownloadStatus.completed) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(18)
          .fontColor([AppColor.onSecondaryContainer])
      } else if (episode.status === DownloadStatus.downloading) {
        Progress({
          value: episode.progressPercent,
          total: 100,
          type: ProgressType.Ring
        })
          .width(22)
          .height(22)
          .color(AppColor.primary)
          .style({ strokeWidth: 2.5 })
      } else if (episode.status === DownloadStatus.resolving) {
        LoadingIndicator({ sizeVp: 22 })
      } else if (episode.status === DownloadStatus.failed) {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle_fill'))
          .fontSize(18)
          .fontColor([AppColor.onErrorContainer])
      } else if (episode.status === DownloadStatus.paused) {
        SymbolGlyph($r('sys.symbol.pause_fill'))
          .fontSize(18)
          .fontColor([AppColor.onSurfaceVariant])
      } else {
        SymbolGlyph($r('sys.symbol.clock'))
          .fontSize(18)
          .fontColor([AppColor.onSurfaceVariant])
      }
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(episode.status === DownloadStatus.completed
      ? AppColor.secondaryContainer
      : (episode.status === DownloadStatus.failed
        ? AppColor.errorContainer
        : (episode.status === DownloadStatus.downloading ||
          episode.status === DownloadStatus.resolving
          ? Color.Transparent : AppColor.surfaceContainerHighest)))
  }
}

/** 删除确认对话框。 */
@CustomDialog
struct DownloadConfirmDialog {
  controller: CustomDialogController = new CustomDialogController({
    builder: DownloadConfirmDialog({
      title: '',
      message: '',
      confirmLabel: '删除',
      onConfirm: () => {
      }
    })
  });
  title: string = '';
  message: string = '';
  confirmLabel: string = '删除';
  onConfirm: () => void = () => {
  };

  build() {
    Column({ space: 16 }) {
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.onSurface)
        .width('100%')
      Text(this.message)
        .fontSize(14)
        .fontColor(AppColor.onSurfaceVariant)
        .width('100%')
      Row({ space: 12 }) {
        Button('取消')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .fontColor(AppColor.onSurfaceVariant)
          .onClick(() => {
            this.controller.close();
          })
        Button(this.confirmLabel)
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor(AppColor.error)
          .fontColor(AppColor.onError)
          .onClick(() => {
            this.onConfirm();
            this.controller.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(24)
  }
}
