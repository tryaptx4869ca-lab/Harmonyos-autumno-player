import { pasteboard } from '@kit.BasicServicesKit';
import { AppColor } from '../theme/AppColors';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { Viewport } from '../utils/Viewport';
import { Logger } from '../services/Logger';

/**
 * 日志页（规格 §53 / `pages/logs/logs_page.dart`）。
 *
 * 与参照实现逐条对齐的点：
 *   - 滚到底部**惰性加载更多行**（一次 200 行）
 *   - 右上两个悬浮按钮：清空、复制，间距 **15**
 *   - 空态图标 `receipt_long_rounded`
 *   - 日志文字 **fontSize 12**
 *   - 内容宽度 `clamp(600, infinity)`：窄屏就是整宽，宽屏居中 600
 */
const PAGE_SIZE: number = 200;
/** 内容宽度下限（`clamp(600, infinity)`）。 */
const CONTENT_MIN_WIDTH: number = 600;

@Component
export struct LogsPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('bottomInset') bottomInset: number = 28;
  @StorageProp('themeRevision') themeRevision: number = 0;
  /** 已加载的行（倒序展示：最新在最上面）。 */
  @State private lines: string[] = [];
  /** 已经加载了多少行（分页游标，从尾部往前取）。 */
  @State private loaded: number = 0;
  @State private total: number = 0;
  @State private viewportWidth: number = 0;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    const all: string[] = Logger.readLines();
    this.total = all.length;
    this.loaded = 0;
    this.lines = [];
    this.loadMore();
  }

  /** 从末尾（最新）往前取一页。 */
  private loadMore(): void {
    const all: string[] = Logger.readLines();
    this.total = all.length;
    if (this.loaded >= this.total) {
      return;
    }
    const next: string[] = [];
    const keep: number = Math.min(PAGE_SIZE, this.total - this.loaded);
    for (let i = 0; i < keep; i++) {
      next.push(all[this.total - 1 - this.loaded - i]);
    }
    this.lines = this.lines.concat(next);
    this.loaded += keep;
  }

  private contentWidth(): number {
    const width: number = Viewport.widthVp(this.viewportWidth);
    return width > CONTENT_MIN_WIDTH ? CONTENT_MIN_WIDTH : width;
  }

  private clearLogs(): void {
    Logger.clear();
    this.reload();
    this.getUIContext().getPromptAction().showToast({ message: '日志已清空' });
  }

  private copyLogs(): void {
    const all: string[] = Logger.readLines();
    if (all.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '暂无日志可复制' });
      return;
    }
    let text: string = '';
    for (let i = 0; i < all.length; i++) {
      text += `${all[i]}\n`;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.getUIContext().getPromptAction().showToast({
        message: `已复制 ${all.length} 行日志`
      });
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败' });
    });
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
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        // 沉浸式悬浮标题层（2026-09-19）；「N 行」作为标题右侧的次要信息传进去
        ImmersiveTitleLayer({
          themeRev: this.themeRevision,
          title: '日志',
          onBack: () => {
            RouteTable.back();
          }
        }) {
          Text(this.total > 0 ? `${this.total} 行` : '')
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .padding({ left: 8, top: 8, bottom: 8 })
        }

        if (this.lines.length === 0) {
          Column() {
            // §46.4：`description_outlined` → `doc_plaintext`
            SymbolGlyph($r('sys.symbol.doc_plaintext'))
              .fontSize(44)
              .fontColor([AppColor.onSurfaceVariant])
            Text('还没有日志')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.onSurface)
              .margin({ top: 16 })
            Text('播放、下载、同步等操作会记录在这里')
              .fontSize(13)
              .fontColor(AppColor.onSurfaceVariant)
              .margin({ top: 8 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .padding({ top: ImmersiveMetrics.contentTop(this.topInset) })
        } else {
          List({ scroller: this.scroller }) {
            // 沉浸式：顶部留出悬浮标题的高度。放在**列表项里**而不是 List 的
            // padding 上——那样才能让日志真的从标题下面滑过去（padding 会把
            // 内容裁在标题下方，见 SearchPage 里同一条注释）。
            ListItem() {
              Column()
                .width('100%')
                .height(ImmersiveMetrics.contentTop(this.topInset))
            }
            ForEach(this.lines, (line: string, index: number) => {
              ListItem() {
                Text(line)
                  .fontSize(12)
                  .lineHeight(18)
                  .fontColor(AppColor.onSurfaceVariant)
                  .width('100%')
                  .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
              }
              .width('100%')
              .padding({ top: 4, bottom: 4 })
            }, (line: string, index: number) => `${index}-${line}`)

            ListItem() {
              Column() {
                Text(this.loaded >= this.total
                  ? '— 已经到底了 —' : '上滑加载更早的日志')
                  .fontSize(12)
                  .fontColor(AppColor.onSurfaceVariant)
              }
              .width('100%')
              .padding({ top: 12, bottom: 12 })
            }
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .onReachEnd(() => {
            this.loadMore();
          })
        }
      }
      .width('100%')
      .height('100%')

      // 两个悬浮按钮，间距 15（§53）
      Column({ space: 15 }) {
        Column() {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(22)
            .fontColor([AppColor.onSurface])
        }
        .width(52)
        .height(52)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(AppColor.surfaceContainerHigh)
        .borderRadius(16)
        .shadow({ radius: 16, color: '#33000000', offsetX: 0, offsetY: 4 })
        .onClick(() => {
          this.clearLogs();
        })

        Column() {
          SymbolGlyph($r('sys.symbol.doc_plaintext'))
            .fontSize(22)
            .fontColor([AppColor.onSurface])
        }
        .width(52)
        .height(52)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(AppColor.surfaceContainerHigh)
        .borderRadius(16)
        .shadow({ radius: 16, color: '#33000000', offsetX: 0, offsetY: 4 })
        .onClick(() => {
          this.copyLogs();
        })
      }
      .margin({ right: 16, bottom: this.bottomInset + 16 })
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.viewportWidth = Number(newValue.width);
    })
  }
}
