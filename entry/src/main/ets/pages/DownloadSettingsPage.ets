import { AppColor } from '../theme/AppColors';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { SectionHeader, SettingsRow, SettingsRowKind } from '../components/SettingsList';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';
import { SettingsSliderRow, groupBottomRadius, groupTopRadius } from '../components/SettingsRows';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';
import { DownloadManager } from '../services/DownloadManager';

/**
 * 下载设置（规格 §43.2 / `download_settings.dart`）。
 *
 * 两组：
 *   并发设置：同时下载集数、并行分片（两张滑杆）
 *   下载内容：缓存弹幕
 * 外加「下载位置」一行。
 *
 * 关于选目录（2026-09-19 改）：鸿蒙上原生版没有可用的持久化目录授权通路，
 * 下载只能落在**应用私有目录**，所以这一行不再是「点开一个只能说不能选的弹窗」，
 * 而是直接**显示实际路径**（只读）——用户问「下载到哪个文件夹」时，界面上就能看到。
 * 同时删掉了 `downloadDirectory` / `downloadDirectoryBookmark` 两个只被这个弹窗
 * 读写的键（写进去也没有任何下载链路会用它）。
 */
@Component
export struct DownloadSettingsPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('themeRevision') themeRevision: number = 0;
  @State private parallelEpisodes: number = 2;
  @State private parallelSegments: number = 3;
  @State private downloadDanmaku: boolean = true;
  /** 下载根目录（实际路径，只读展示）。 */
  private readonly downloadDir: string = DownloadManager.directory();

  aboutToAppear(): void {
    this.parallelEpisodes =
      SettingsStore.getNumber(SettingsKeys.downloadParallelEpisodes);
    this.parallelSegments =
      SettingsStore.getNumber(SettingsKeys.downloadParallelSegments);
    this.downloadDanmaku =
      SettingsStore.getBool(SettingsKeys.downloadDanmaku);
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
        title: '下载设置',
        onBack: () => {
          RouteTable.back();
        }
      })

      Scroll() {
        Column() {
          SectionHeader({ title: '并发设置' })
          Column({ space: 4 }) {
            SettingsSliderRow({
              title: '同时下载集数',
              description: '同时进行的剧集下载数量',
              valueText: `${this.parallelEpisodes}`,
              value: this.parallelEpisodes,
              min: 1,
              max: 5,
              step: 1,
              topRadius: groupTopRadius(0),
              bottomRadius: groupBottomRadius(0, 2),
              onChange: (value: number) => {
                this.parallelEpisodes = Math.round(value);
                SettingsStore.put(SettingsKeys.downloadParallelEpisodes,
                  this.parallelEpisodes);
              }
            })
            SettingsSliderRow({
              title: '并行分片',
              description: '单个剧集内同时下载的分片数',
              valueText: `${this.parallelSegments}`,
              value: this.parallelSegments,
              min: 1,
              max: 5,
              step: 1,
              topRadius: groupTopRadius(1),
              bottomRadius: groupBottomRadius(1, 2),
              onChange: (value: number) => {
                this.parallelSegments = Math.round(value);
                SettingsStore.put(SettingsKeys.downloadParallelSegments,
                  this.parallelSegments);
              }
            })
          }
          .width('100%')

          SectionHeader({ title: '下载内容' })
          SettingsRow({
            title: '缓存弹幕',
            description: '下载剧集时一并缓存弹幕文件',
            kind: SettingsRowKind.toggle,
            checked: this.downloadDanmaku,
            topRadius: 24,
            bottomRadius: 24,
            onToggle: (value: boolean) => {
              this.downloadDanmaku = value;
              SettingsStore.put(SettingsKeys.downloadDanmaku, value);
            }
          })

          SectionHeader({ title: '下载位置' })
          SettingsRow({
            title: '下载目录',
            description: this.downloadDir.length > 0
              ? `${this.downloadDir}（应用私有目录，文件管理里看不到）`
              : '应用私有目录',
            // §46.4：`folder_rounded` → `folder`
            icon: $r('sys.symbol.folder'),
            kind: SettingsRowKind.info,
            topRadius: 24,
            bottomRadius: 24
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
}
