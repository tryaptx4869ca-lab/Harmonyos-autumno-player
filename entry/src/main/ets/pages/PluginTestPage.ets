import { pasteboard } from '@kit.BasicServicesKit';
import { AppColor } from '../theme/AppColors';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { Plugin } from '../plugins/Plugin';
import { Road, SearchItem } from '../model/SearchModels';
import { Logger } from '../services/Logger';
import { RuleChapterTrace, RuleEngine, RuleSearchTrace } from '../services/plugin/RuleEngine';
import { PluginTestRoute } from './PluginPage';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';

const TAG: string = 'AutumnPluginTest';

/**
 * 结果卡片的标题行。
 *
 * 做成组件而不是带参 `@Builder`：带参 `@Builder` 的参数只在首次求值时读一次，
 * 状态变了副标题不刷新——实测「搜索请求」一直停在「未开始」，
 * 而下面那行错误文字（读的是 `@State`）却已经更新了。
 */
@Component
struct TestCardHeader {
  @Prop themeRev: number = 0;
  @Prop title: string = '';
  @Prop status: string = '';

  build() {
    Row() {
      Text(this.title)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.onSurface)
      Blank().layoutWeight(1)
      Text(this.status)
        .fontSize(12)
        .fontColor(this.status === '失败'
          || this.status === '已停止' ? AppColor.error : AppColor.onSurfaceVariant)
    }
    .width('100%')
  }
}

/**
 * 规则测试（规格 §29.3 / `plugin_test_page.dart`）。
 *
 * 一次测试覆盖三段：搜索请求 → 结果解析 → 播放线路。
 *   - 关键词为空 → 「请输入一个番剧名称作为测试关键词。」
 *   - 开始 / 停止测试（停止只是丢弃这次结果——规则引擎按请求粒度取消，
 *     这里用一个自增的会话号判断「回来的结果是不是当前这次的」）
 *   - 三段各有标题与副标题（检索中 / N 条 / 失败原因）
 *   - 诊断列表：解析时跳过的节点
 *   - 原始响应面板：可复制未解析原文
 */
@Component
export struct PluginTestPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('themeRevision') themeRevision: number = 0;

  private plugin: Plugin = new Plugin();
  @State private keyword: string = '';
  @State private testing: boolean = false;
  /** 会话号：停止后再点开始时递增，用来丢弃过期结果。 */
  private session: number = 0;

  @State private searchStatus: string = '未开始';
  @State private parseStatus: string = '未开始';
  @State private chapterStatus: string = '未开始';
  @State private searchError: string = '';
  @State private items: SearchItem[] = [];
  @State private roads: Road[] = [];
  @State private diagnostics: string[] = [];
  @State private rawResponse: string = '';

  aboutToAppear(): void {
    const pending: Plugin | null = PluginTestRoute.pending;
    PluginTestRoute.pending = null;
    if (pending !== null) {
      this.plugin = pending;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private static hostOf(url: string): string {
    const index: number = url.indexOf('://');
    if (index < 0) {
      return url;
    }
    let rest: string = url.substring(index + 3);
    const slash: number = rest.indexOf('/');
    if (slash >= 0) {
      rest = rest.substring(0, slash);
    }
    return rest;
  }

  private async run(): Promise<void> {
    if (this.testing) {
      // 停止：递增会话号，回来的结果会被丢弃
      this.session += 1;
      this.testing = false;
      this.searchStatus = '已停止';
      this.parseStatus = '已停止';
      this.chapterStatus = '已停止';
      this.toast('已停止测试');
      return;
    }
    const value: string = this.keyword.trim();
    if (value.length === 0) {
      this.toast('请输入一个番剧名称作为测试关键词。');
      return;
    }
    this.session += 1;
    const current: number = this.session;
    this.testing = true;
    this.items = [];
    this.roads = [];
    this.diagnostics = [];
    this.rawResponse = '';
    this.searchError = '';
    this.searchStatus = '检索中…';
    this.parseStatus = '等待检索';
    this.chapterStatus = '等待检索';

    try {
      const trace: RuleSearchTrace =
        await RuleEngine.search(this.plugin.executionConfig(), value);
      if (current !== this.session) {
        return;
      }
      this.rawResponse = trace.rawResponse;
      this.diagnostics = trace.diagnostics;
      this.searchStatus = '成功';
      this.items = trace.response.data;
      this.parseStatus = `解析到 ${trace.response.data.length} 条`;
      Logger.info(TAG,
        `测试搜索成功：${this.plugin.name}「${value}」→ ${trace.response.data.length} 条`);
      if (trace.response.data.length === 0) {
        this.chapterStatus = '无结果，跳过线路测试';
        return;
      }
      this.chapterStatus = '取线路中…';
      const first: SearchItem = trace.response.data[0];
      const chapter: RuleChapterTrace =
        await RuleEngine.queryChapters(this.plugin.executionConfig(), first.src);
      if (current !== this.session) {
        return;
      }
      this.roads = chapter.roads;
      if (chapter.diagnostics.length > 0) {
        this.diagnostics = this.diagnostics.concat(chapter.diagnostics);
      }
      let episodes: number = 0;
      for (let i = 0; i < chapter.roads.length; i++) {
        episodes += chapter.roads[i].data.length;
      }
      this.chapterStatus =
        `成功：${chapter.roads.length} 条线路 · ${episodes} 集`;
      Logger.info(TAG,
        `测试线路成功：${chapter.roads.length} 条线路 / ${episodes} 集`);
    } catch (error) {
      if (current !== this.session) {
        return;
      }
      const err = error as Error;
      this.searchError = err.message;
      this.searchStatus = '失败';
      this.parseStatus = '失败';
      this.chapterStatus = '失败';
      Logger.error(TAG, `测试失败：${err.message}`);
    } finally {
      if (current === this.session) {
        this.testing = false;
      }
    }
  }

  private copyRaw(): void {
    if (this.rawResponse.length === 0) {
      this.toast('还没有响应内容');
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,
      this.rawResponse);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.toast('已复制响应内容');
    }).catch(() => {
      this.toast('复制失败');
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
      // 退出：与参照实现同一条 Fade + Slide（Offset(0, 0.02)）——下滑 2% 的同时淡出
      .translate({ y: RouteTable.slideOffset() })
  }

  build() {
    Column() {
      // 沉浸式悬浮标题层（2026-09-19）
      ImmersiveTitleLayer({
        themeRev: this.themeRevision,
        title: '规则测试',
        onBack: () => {
          RouteTable.back();
        }
      })

      Scroll() {
        Column() {
          // 规则信息 + 关键词
          Column() {
            Text(this.plugin.name.length > 0 ? this.plugin.name : '未选择规则')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.onSurface)
              .width('100%')
            Text(PluginTestPage.hostOf(this.plugin.baseUrl))
              .fontSize(12)
              .fontColor(AppColor.onSurfaceVariant)
              .width('100%')
              .margin({ top: 4 })
            Text('试着搜索一部番剧')
              .fontSize(13)
              .fontColor(AppColor.onSurfaceVariant)
              .width('100%')
              .margin({ top: 14 })
            TextInput({ text: this.keyword, placeholder: '测试关键词' })
              .fontSize(15)
              .margin({ top: 8 })
              .onChange((value: string) => {
                this.keyword = value;
              })
            Row() {
              Text(this.testing ? '停止测试' : '开始测试')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.onPrimary)
            }
            .width('100%')
            .height(48)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(this.testing ? AppColor.error : AppColor.primary)
            .borderRadius(24)
            .margin({ top: 14 })
            .onClick(() => {
              this.run();
            })
          }
          .width('100%')
          .padding(20)
          .borderRadius(28)
          .backgroundColor(AppColor.surfaceContainerLow)

          // 三段结果：搜索请求
          Column() {
            TestCardHeader({ title: '搜索请求', status: this.searchStatus })
            Text(this.searchError.length > 0 ? this.searchError : '发起检索并拿到响应')
              .fontSize(13)
              .fontColor(this.searchError.length > 0
                ? AppColor.error : AppColor.onSurfaceVariant)
              .width('100%')
              .margin({ top: 6 })
          }
          .width('100%')
          .padding(16)
          .borderRadius(24)
          .backgroundColor(AppColor.surfaceContainerLow)
          .margin({ top: 12 })

          if (this.items.length > 0) {
            Column() {
              TestCardHeader({ title: '结果解析', status: this.parseStatus })
              ForEach(this.items, (item: SearchItem, index: number) => {
                Column() {
                  Text(`${index + 1}. ${item.name}`)
                    .fontSize(15)
                    .fontColor(AppColor.onSurface)
                    .width('100%')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`链接：${item.src}`)
                    .fontSize(12)
                    .fontColor(AppColor.onSurfaceVariant)
                    .width('100%')
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 2 })
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
              }, (item: SearchItem, index: number) => `${index}-${item.src}`)
            }
            .width('100%')
            .padding(16)
            .borderRadius(24)
            .backgroundColor(AppColor.surfaceContainerLow)
            .margin({ top: 12 })
          }

          // 三段结果：播放线路
          Column() {
            TestCardHeader({ title: '播放线路', status: this.chapterStatus })
            if (this.roads.length === 0) {
              Text('用第一条搜索结果去取线路与剧集')
                .fontSize(13)
                .fontColor(AppColor.onSurfaceVariant)
                .width('100%')
                .margin({ top: 6 })
            } else {
              ForEach(this.roads, (road: Road, index: number) => {
                Column() {
                  Text(road.name.length > 0 ? road.name : `播放线路 ${index + 1}`)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(AppColor.onSurface)
                    .width('100%')
                  Text(`章节数量：${road.data.length}`)
                    .fontSize(12)
                    .fontColor(AppColor.onSurfaceVariant)
                    .width('100%')
                    .margin({ top: 2 })
                  if (road.data.length > 0) {
                    Text(`第 1 集：${road.identifier.length > 0 ? road.identifier[0] : ''} → ${road.data[0]}`)
                      .fontSize(12)
                      .fontColor(AppColor.onSurfaceVariant)
                      .width('100%')
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 2 })
                  }
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
              }, (road: Road, index: number) => `${index}-${road.name}`)
            }
          }
          .width('100%')
          .padding(16)
          .borderRadius(24)
          .backgroundColor(AppColor.surfaceContainerLow)
          .margin({ top: 12 })

          // 诊断
          if (this.diagnostics.length > 0) {
            Column() {
              Text(`部分节点被跳过（${this.diagnostics.length}）`)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.error)
                .width('100%')
              ForEach(this.diagnostics, (line: string, index: number) => {
                Text(line)
                  .fontSize(12)
                  .fontColor(AppColor.onSurfaceVariant)
                  .width('100%')
                  .margin({ top: 4 })
              }, (line: string, index: number) => `${index}-${line}`)
            }
            .width('100%')
            .padding(16)
            .borderRadius(24)
            .backgroundColor(AppColor.surfaceContainerLow)
            .margin({ top: 12 })
          }

          // 原始响应
          if (this.rawResponse.length > 0) {
            Column() {
              Row() {
                Text('响应内容')
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.onSurface)
                  .layoutWeight(1)
                Text('复制')
                  .fontSize(14)
                  .fontColor(AppColor.primary)
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .onClick(() => {
                    this.copyRaw();
                  })
              }
              .width('100%')

              Scroll() {
                Text(this.rawResponse)
                  .fontSize(12)
                  .lineHeight(18)
                  .fontColor(AppColor.onSurfaceVariant)
                  .width('100%')
                  .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
              }
              .width('100%')
              .height(220)
              .margin({ top: 8 })
              .padding(12)
              .borderRadius(16)
              .backgroundColor(AppColor.surfaceContainerHighest)
            }
            .width('100%')
            .padding(16)
            .borderRadius(24)
            .backgroundColor(AppColor.surfaceContainerLow)
            .margin({ top: 12 })
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

}
