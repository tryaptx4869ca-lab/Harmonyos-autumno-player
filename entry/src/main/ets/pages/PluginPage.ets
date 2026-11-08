import { pasteboard } from '@kit.BasicServicesKit';
import { AppColor } from '../theme/AppColors';
import { LoadingIndicator } from '../components/LoadingIndicator';
import { SectionHeader } from '../components/SettingsList';
import { AppCurves, Dimens, Motion, PageTransitionSpec } from '../theme/Tokens';
import { MotionRuntime } from '../theme/MotionRuntime';
import { RouteTable } from '../router/RouteTable';
import { Plugin } from '../plugins/Plugin';
import { JsonUtils } from '../model/JsonUtils';
import { ApiEndpoints } from '../request/config/ApiEndpoints';
import { Logger } from '../services/Logger';
import { PluginManager } from '../services/plugin/PluginManager';
import { UnavailablePlugins } from '../services/plugin/UnavailablePlugins';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';
import { PluginImportParseResult, PluginImportParser } from '../services/plugin/PluginImportParser';
import {
  PluginUpdateAvailability,
  PluginUpdateResult,
  PluginUpdateService
} from '../services/plugin/PluginUpdateService';

const TAG: string = 'AutumnPlugin';

/** 「添加规则」的四种方式（源码 `RuleAddSource`）。 */
const ADD_SOURCES: string[] = ['浏览规则仓库', '从剪贴板导入', '从文件导入', '新建规则'];
const ADD_SOURCE_DESCS: string[] = [
  '发现并安装社区规则',
  '粘贴规则链接或 JSON',
  '读取本地 JSON 规则文件',
  '从模板开始编写'
];

/**
 * 规则管理（规格 §23.2 `/settings/plugin/` / `plugin_view_page.dart`）。
 *
 *   - 头部卡：「我的规则」+「管理你的番剧来源。拖动调整搜索顺序，点按规则进行编辑。」
 *     两个按钮：添加规则 / 规则仓库
 *   - 搜索框（名称或站点）、两个过滤胶囊（全部 N / 可更新 N）
 *   - 每行：规则名 + 站点主机名；右侧「更多」→ 编辑 / 测试 / 检查更新 / 分享 / 上移 / 下移 / 删除
 *   - 多选模式：进入后每行带勾选，右上变成「删除所选」
 *
 * 「可更新 N」依赖规则仓库目录；拉不到目录时显示源码的兜底文案
 * 「暂时无法检查更新，已安装的规则仍可使用。」，不影响已安装规则的使用。
 */
@Component
export struct PluginPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('bottomInset') bottomInset: number = 28;
  @StorageProp('themeRevision') themeRevision: number = 0;

  /** 列表数据（从 PluginManager 拷贝一份用于渲染）。 */
  @State private plugins: Plugin[] = [];
  @State private query: string = '';
  /** 0 全部 / 1 可更新。 */
  @State private filterKind: number = 0;
  @State private updatableCount: number = 0;
  @State private catalogFailed: boolean = false;
  @State private checking: boolean = true;
  /** 多选模式。 */
  @State private selecting: boolean = false;
  @State private selectedNames: string[] = [];
  /** 正在执行的规则名（转圈 + 防重复点击）。 */
  @State private busyName: string = '';
  /** 「更多」浮层：正在操作哪条规则。 */
  @State private menuName: string = '';
  /** 「添加规则」浮层是否展开。 */
  @State private showAddOptions: boolean = false;
  /**
   * 「从剪贴板导入」浮层。
   *
   * 为什么不直接 `pasteboard.getData()`：读剪贴板要求
   * `ohos.permission.READ_PASTEBOARD`，而它的 `availableLevel` 是 `system_basic`，
   * 普通应用申请不到——直接调必然抛错，用户看到的就是「无法读取剪贴板」。
   * 现在改成放一颗系统安全控件 `PasteButton`：用户点它的那一刻系统给**一次性**
   * 剪贴板读取授权，点完再读就能拿到内容；下面另附「手动粘贴」入口兜底。
   */
  @State private showPastePanel: boolean = false;
  /** 手动粘贴框的内容。 */
  @State private pasteDraft: string = '';
  /** 是否展开手动粘贴框（默认收起，先走 PasteButton）。 */
  @State private showManualPaste: boolean = false;
  /** 「已隐藏的规则」名单的版本号：标记 / 恢复之后 +1，逼那一节重排。 */
  @State private hiddenRev: number = 0;
  private confirmDialog: CustomDialogController | null = null;
  private pendingDeleteNames: string[] = [];

  aboutToAppear(): void {
    this.reloadList();
    this.confirmDialog = new CustomDialogController({
      builder: PluginConfirmDialog({
        title: '',
        message: '',
        confirmLabel: '删除',
        onConfirm: () => {
        }
      }),
      autoCancel: true,
      customStyle: false
    });
    this.checkUpdates();
  }

  @StorageProp('navShown:pages/PluginPage') @Watch('onNavShown') navShownTick: number = 0;

  onNavShown(): void {
    this.reloadList();
  }

  private reloadList(): void {
    this.plugins = PluginManager.pluginList.slice();
    this.selectedNames = this.selectedNames.filter((name: string) =>
      PluginManager.find(name) !== null);
  }

  /** 拉一次规则仓库目录，统计可更新条数。 */
  private async checkUpdates(): Promise<void> {
    this.checking = true;
    this.catalogFailed = false;
    try {
      await PluginUpdateService.ensureCatalog();
      let count: number = 0;
      for (let i = 0; i < this.plugins.length; i++) {
        if (PluginUpdateService.updateAvailability(this.plugins[i])
          === PluginUpdateAvailability.updatable) {
          count += 1;
        }
      }
      this.updatableCount = count;
    } catch (error) {
      const err = error as Error;
      this.catalogFailed = true;
      this.updatableCount = 0;
      Logger.warn(TAG, `检查规则更新失败：${err.message}`);
    } finally {
      this.checking = false;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 站点主机名（源码用 `Uri.tryParse(baseUrl)?.host`，取不到就显示原始地址）。 */
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
    const colon: number = rest.indexOf(':');
    return colon >= 0 ? rest.substring(0, colon) : rest;
  }

  private filtered(): Plugin[] {
    /**
     * 读一次 `hiddenRev`：`UnavailablePlugins.isUnavailable()` 不在 ArkUI 的依赖图里，
     * 不读这个版本号的话「标记为不可用」之后这一列不会重排（要切页才更新）。
     */
    if (this.hiddenRev < 0) {
      return [];
    }
    const keyword: string = this.query.trim().toLowerCase();
    const out: Plugin[] = [];
    for (let i = 0; i < this.plugins.length; i++) {
      const plugin: Plugin = this.plugins[i];
      // 已失效的规则不出现在已装列表里（名单见 `UnavailablePlugins`）
      if (UnavailablePlugins.isUnavailable(plugin.name)) {
        continue;
      }
      if (this.filterKind === 1
        && PluginUpdateService.updateAvailability(plugin)
          !== PluginUpdateAvailability.updatable) {
        continue;
      }
      if (keyword.length > 0
        && plugin.name.toLowerCase().indexOf(keyword) < 0
        && plugin.baseUrl.toLowerCase().indexOf(keyword) < 0) {
        continue;
      }
      out.push(plugin);
    }
    return out;
  }

  /**
   * 「已隐藏的规则」名单（内置失效名单 + 用户标记，去掉已恢复的）。
   *
   * 读 `hiddenRev` 是为了让「标记 / 恢复」之后这一节重排——ArkUI 只重绘
   * 「build 里读过」的状态，`UnavailablePlugins` 自己的数组不在其中。
   */
  private hiddenList(): string[] {
    return this.hiddenRev < 0 ? [] : UnavailablePlugins.hidden();
  }

  private indexOf(plugin: Plugin): number {
    for (let i = 0; i < PluginManager.pluginList.length; i++) {
      if (PluginManager.pluginList[i].name === plugin.name) {
        return i;
      }
    }
    return -1;
  }

  // ---------------- 动作 ----------------

  private async onAddOption(index: number): Promise<void> {
    this.showAddOptions = false;
    if (index === 0) {
      RouteTable.push('pages/PluginCatalogPage');
      return;
    }
    if (index === 1) {
      this.showPastePanel = true;
      return;
    }
    if (index === 2) {
      // OHOS 侧文件选择器尚未接入：明确说明，并指到剪贴板导入这条可用路径
      this.toast('当前版本请用「从剪贴板导入」，文件选择器将在后续版本接入');
      return;
    }
    // 新建规则：从模板起手，进编辑器
    const template: Plugin = Plugin.fromTemplate('8');
    PluginEditorRoute.pending = template;
    PluginEditorRoute.isNew = true;
    RouteTable.push('pages/PluginEditorPage');
  }

  /**
   * 读一次剪贴板并导入。
   *
   * **只能由 `PasteButton` 的点击回调调用**：安全控件在那一下给了临时授权，
   * 离开这个回调（或稍晚一点）再读就会重新被拒。
   */
  private async readClipboardAndImport(): Promise<void> {
    let text: string = '';
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      text = data.getPrimaryText();
    } catch (error) {
      const err = error as Error;
      Logger.warn(TAG, `读取剪贴板失败：${err.message}`);
      this.toast('读取剪贴板失败，可改用「手动粘贴」');
      this.showManualPaste = true;
      return;
    }
    this.importText(text);
  }

  /**
   * 把一段文本按规则导入（剪贴板 / 手动粘贴共用）。
   *
   * 解析器支持三种：单个 JSON、JSON 数组、文本里夹的任意多个 `kazumi://` 链接。
   */
  private importText(text: string): void {
    if (text.trim().length === 0) {
      this.toast('剪贴板里没有可导入的内容');
      return;
    }
    const result: PluginImportParseResult = PluginImportParser.parse(text);
    if (result.plugins.length === 0) {
      const reason: string = result.failures.length > 0
        ? result.failures[0] : '未找到可导入的规则';
      this.toast(reason);
      return;
    }
    const imported: number = PluginManager.importAll(result.plugins);
    this.reloadList();
    this.showPastePanel = false;
    this.showManualPaste = false;
    this.pasteDraft = '';
    let message: string = `已导入 ${imported} 条规则`;
    if (result.duplicateCount > 0) {
      message += `（覆盖同名 ${result.duplicateCount} 条）`;
    }
    if (result.failureCount() > 0) {
      message += `，${result.failureCount()} 条失败`;
    }
    this.toast(message);
    Logger.info(TAG, `规则导入：${message}`);
  }

  private async updateOne(plugin: Plugin): Promise<void> {
    if (this.busyName.length > 0) {
      return;
    }
    this.busyName = plugin.name;
    this.menuName = '';
    try {
      const result: PluginUpdateResult =
        await PluginUpdateService.tryUpdateByName(plugin.name);
      this.reloadList();
      this.toast(PluginPage.updateMessage(result));
      await this.checkUpdates();
    } catch (error) {
      const err = error as Error;
      this.toast(`检查更新失败：${err.message}`);
    } finally {
      this.busyName = '';
    }
  }

  private static updateMessage(result: PluginUpdateResult): string {
    if (result === PluginUpdateResult.updated) {
      return '规则已更新';
    }
    if (result === PluginUpdateResult.notNewer) {
      return '已经是最新版本';
    }
    if (result === PluginUpdateResult.requiresNewerClient) {
      return '规则需要更高版本客户端';
    }
    return '更新失败，请稍后重试';
  }

  private shareRule(plugin: Plugin): void {
    this.menuName = '';
    const link: string = PluginImportParser.jsonToKazumiBase64(
      JSON.stringify(plugin.toJson()));
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, link);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.toast('规则分享链接已复制到剪贴板');
    }).catch(() => {
      this.toast('复制失败');
    });
  }

  private reorder(plugin: Plugin, delta: number): void {
    this.menuName = '';
    const from: number = this.indexOf(plugin);
    if (from < 0) {
      return;
    }
    const moved: boolean = PluginManager.move(from, from + delta);
    if (moved) {
      this.reloadList();
      this.toast(delta < 0 ? '已上移' : '已下移');
    }
  }

  private confirmDelete(names: string[]): void {
    if (names.length === 0) {
      return;
    }
    this.menuName = '';
    this.pendingDeleteNames = names;
    const title: string = names.length === 1
      ? '删除规则？' : `删除 ${names.length} 条规则？`;
    const message: string = names.length === 1
      ? `将删除「${names[0]}」，此操作无法撤销。`
      : '将删除所选规则，此操作无法撤销。';
    this.confirmDialog = new CustomDialogController({
      builder: PluginConfirmDialog({
        title: title,
        message: message,
        confirmLabel: '删除',
        onConfirm: () => {
          const removed: number =
            PluginManager.removeAll(this.pendingDeleteNames);
          this.pendingDeleteNames = [];
          this.selecting = false;
          this.selectedNames = [];
          this.reloadList();
          this.toast(`已删除 ${removed} 条规则`);
        }
      }),
      autoCancel: true,
      customStyle: false
    });
    this.confirmDialog.open();
  }

  private toggleSelect(name: string): void {
    const index: number = this.selectedNames.indexOf(name);
    if (index >= 0) {
      const next: string[] = this.selectedNames.slice();
      next.splice(index, 1);
      this.selectedNames = next;
    } else {
      this.selectedNames = this.selectedNames.concat([name]);
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
    Stack() {
      Column() {
        /**
         * 沉浸式悬浮标题层（2026-09-19）。
         *
         * 多选态原来是「退出多选 + 已选择 N 条 + 删除所选」三段，这里收敛成：
         * 玻璃返回钮在多选时承担「退出多选」，标题显示「已选择 N 条」，
         * 右侧操作位显示「删除所选」。
         */
        ImmersiveTitleLayer({
          themeRev: this.themeRevision,
          title: this.selecting ? `已选择 ${this.selectedNames.length} 条` : '规则管理',
          onBack: () => {
            if (this.selecting) {
              this.selecting = false;
              this.selectedNames = [];
              return;
            }
            RouteTable.back();
          }
        }) {
          if (this.selecting) {
            Text('删除所选')
              .fontSize(15)
              .fontColor(this.selectedNames.length === 0
                ? AppColor.onSurfaceVariant : AppColor.error)
              .padding({ left: 8, right: 8, top: 8, bottom: 8 })
              .onClick(() => {
                this.confirmDelete(this.selectedNames);
              })
          } else if (this.plugins.length > 0) {
            Text('多选')
              .fontSize(15)
              .fontColor(AppColor.primary)
              .padding({ left: 8, right: 8, top: 8, bottom: 8 })
              .onClick(() => {
                this.selecting = true;
              })
          }
        }

        Scroll() {
          Column() {
            // 头部卡
            Column() {
              Text('我的规则')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.onSurface)
                .width('100%')
              Text('管理你的番剧来源。拖动调整搜索顺序，点按规则进行编辑。')
                .fontSize(13)
                .fontColor(AppColor.onSurfaceVariant)
                .width('100%')
                .margin({ top: 6 })
              Row({ space: 12 }) {
                Row() {
                  SymbolGlyph($r('sys.symbol.arrow_down_to_line'))
                    .fontSize(18)
                    .fontColor([AppColor.onPrimary])
                  Text('添加规则')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(AppColor.onPrimary)
                    .margin({ left: 6 })
                }
                .layoutWeight(1)
                .height(48)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(AppColor.primary)
                .borderRadius(24)
                .onClick(() => {
                  this.showAddOptions = true;
                })

                Row() {
                  SymbolGlyph($r('sys.symbol.magnifyingglass'))
                    .fontSize(18)
                    .fontColor([AppColor.onSecondaryContainer])
                  Text('规则仓库')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(AppColor.onSecondaryContainer)
                    .margin({ left: 6 })
                }
                .layoutWeight(1)
                .height(48)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(AppColor.secondaryContainer)
                .borderRadius(24)
                .onClick(() => {
                  RouteTable.push('pages/PluginCatalogPage');
                })
              }
              .width('100%')
              .margin({ top: 16 })
            }
            .width('100%')
            .padding(20)
            .borderRadius(28)
            .backgroundColor(AppColor.surfaceContainerLow)

            /**
             * 内置 B站来源。
             *
             * 它不参与插件搜索，但和规则来源并列展示；点进去可粘贴普通投稿
             * 链接，解析多 P/合集后直接播放。不能删，也不会被规则更新覆盖。
             */
            // 搜索
            Row() {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(18)
                .fontColor([AppColor.onSurfaceVariant])
                .margin({ left: 16 })
              TextInput({ text: this.query, placeholder: '搜索名称或站点' })
                .placeholderColor(AppColor.onSurfaceVariant)
                .backgroundColor(Color.Transparent)
                .fontSize(15)
                .fontColor(AppColor.onSurface)
                .layoutWeight(1)
                .padding({ left: 12, right: 12 })
                .onChange((value: string) => {
                  this.query = value;
                })
              if (this.query.length > 0) {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(16)
                  .fontColor([AppColor.onSurfaceVariant])
                  .padding({ left: 8, right: 16 })
                  .onClick(() => {
                    this.query = '';
                  })
              }
            }
            .width('100%')
            .constraintSize({ minHeight: 56 })
            .backgroundColor(AppColor.surfaceContainerHigh)
            .borderRadius(28)
            .margin({ top: 20 })

            // 过滤胶囊
            Row() {
              this.filterChip(0, `全部 ${this.plugins.length}`)
              this.filterChip(1, this.checking
                ? '检查更新中…' : `可更新 ${this.updatableCount}`)
            }
            .width('100%')
            .margin({ top: 12 })

            if (this.catalogFailed) {
              Text('暂时无法检查更新，已安装的规则仍可使用。')
                .fontSize(12)
                .fontColor(AppColor.onSurfaceVariant)
                .width('100%')
                .padding({ top: 8 })
            }

            // 列表
            if (this.plugins.length === 0) {
              Column() {
                SymbolGlyph($r('sys.symbol.gearshape'))
                  .fontSize(40)
                  .fontColor([AppColor.onSurfaceVariant])
                Text('还没有番剧站点规则')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(AppColor.onSurface)
                  .margin({ top: 14 })
                Text('可从规则仓库下载来源，或用「添加规则」自己写一条')
                  .fontSize(13)
                  .fontColor(AppColor.onSurfaceVariant)
                  .margin({ top: 8 })
              }
              .width('100%')
              .height(220)
              .justifyContent(FlexAlign.Center)
            } else {
              Column({ space: 4 }) {
                ForEach(this.filtered(), (plugin: Plugin, index: number) => {
                  this.pluginRow(plugin,
                    index, this.filtered().length)
                }, (plugin: Plugin) => `${plugin.name}:${this.selecting}:${this.selectedNames.indexOf(plugin.name)}`)
              }
              .width('100%')
              .margin({ top: 16 })
            }

            // 已隐藏的规则（内置失效名单 + 用户标记），可以在这里恢复
            if (this.hiddenList().length > 0) {
              SectionHeader({ title: `已隐藏的规则 ${this.hiddenList().length}` })
              Column({ space: 4 }) {
                ForEach(this.hiddenList(), (name: string, index: number) => {
                  Row() {
                    Column({ space: 2 }) {
                      Text(name)
                        .fontSize(15)
                        .fontColor(AppColor.onSurface)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                      Text('已从来源列表、规则仓库里隐藏')
                        .fontSize(12)
                        .fontColor(AppColor.onSurfaceVariant)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    Text('恢复')
                      .fontSize(14)
                      .fontColor(AppColor.primary)
                      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                      .onClick(() => {
                        UnavailablePlugins.unblock(name);
                        this.hiddenRev += 1;
                        this.toast(`已恢复 ${name}`);
                      })
                  }
                  .width('100%')
                  .constraintSize({ minHeight: 64 })
                  .padding({ left: 16, right: 8, top: 10, bottom: 10 })
                  .backgroundColor(AppColor.surfaceContainerLow)
                  .borderRadius(16)
                  .alignItems(VerticalAlign.Center)
                }, (name: string) => `hidden-${name}-${this.hiddenRev}`)
              }
              .width('100%')
              .margin({ top: 4 })
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

      if (this.menuName.length > 0) {
        this.moreMenu()
      }
      if (this.showAddOptions) {
        this.addOptionsOverlay()
      }
      if (this.showPastePanel) {
        this.pasteOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  filterChip(kind: number, label: string) {
    Text(label)
      .fontSize(14)
      .fontWeight(this.filterKind === kind ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.filterKind === kind
        ? AppColor.onSecondaryContainer : AppColor.onSurfaceVariant)
      .padding({ left: 18, right: 18, top: 12, bottom: 12 })
      .backgroundColor(this.filterKind === kind
        ? AppColor.secondaryContainer : AppColor.surfaceContainerLow)
      .borderRadius(this.filterKind === kind ? 20 : 12)
      .margin({ right: 8 })
      // 规则卡选中态：`rule_card.dart:43-53` —— AnimatedContainer
      // **220ms** + `Curves.easeInOutCubicEmphasized`（规格 §38.2 / §38.5）。
      .animation({
        duration: MotionRuntime.ms(Motion.medium),
        curve: AppCurves.easeInOutCubicEmphasized()
      })
      .onClick(() => {
        this.filterKind = kind;
      })
  }

  @Builder
  pluginRow(plugin: Plugin, index: number, total: number) {
    Row() {
      if (this.selecting) {
        SymbolGlyph(this.selectedNames.indexOf(plugin.name) >= 0
          ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
          .fontSize(22)
          .fontColor([this.selectedNames.indexOf(plugin.name) >= 0
            ? AppColor.primary : AppColor.onSurfaceVariant])
        Blank().width(12)
      }

      Column() {
        Text(plugin.name)
          .fontSize(16)
          .fontColor(AppColor.onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(PluginPage.hostOf(plugin.baseUrl))
          .fontSize(12)
          .fontColor(AppColor.onSurfaceVariant)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })
        if (PluginUpdateService.updateAvailability(plugin)
          === PluginUpdateAvailability.updatable) {
          Text('有更新')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.primary)
            .margin({ top: 4 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .constraintSize({ minHeight: 32 })

      if (this.busyName === plugin.name) {
        LoadingIndicator({ sizeVp: 22 })
          .margin({ left: 12 })
      } else if (!this.selecting) {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(20)
          .fontColor([AppColor.onSurfaceVariant])
          .padding({ left: 12, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.menuName = this.menuName === plugin.name ? '' : plugin.name;
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .borderRadius({
      topLeft: index === 0 ? 24 : 4,
      topRight: index === 0 ? 24 : 4,
      bottomLeft: index === total - 1 ? 24 : 4,
      bottomRight: index === total - 1 ? 24 : 4
    })
    .backgroundColor(AppColor.surfaceContainerLow)
    .onClick(() => {
      if (this.selecting) {
        this.toggleSelect(plugin.name);
        return;
      }
      if (this.menuName.length > 0) {
        this.menuName = '';
        return;
      }
      PluginEditorRoute.pending = plugin;
      PluginEditorRoute.isNew = false;
      RouteTable.push('pages/PluginEditorPage');
    })
  }

  @Builder
  moreMenu() {
    Column() {
      Column() {
        Text(this.menuName)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.onSurfaceVariant)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ bottom: 8 })

        this.menuItem('编辑规则', () => {
          const plugin: Plugin | null = PluginManager.find(this.menuName);
          if (plugin !== null) {
            PluginEditorRoute.pending = plugin;
            PluginEditorRoute.isNew = false;
            this.menuName = '';
            RouteTable.push('pages/PluginEditorPage');
          }
        })
        this.menuItem('测试规则', () => {
          const plugin: Plugin | null = PluginManager.find(this.menuName);
          if (plugin !== null) {
            PluginTestRoute.pending = plugin;
            this.menuName = '';
            RouteTable.push('pages/PluginTestPage');
          }
        })
        this.menuItem('检查更新', () => {
          const plugin: Plugin | null = PluginManager.find(this.menuName);
          if (plugin !== null) {
            this.updateOne(plugin);
          }
        })
        this.menuItem('分享规则', () => {
          const plugin: Plugin | null = PluginManager.find(this.menuName);
          if (plugin !== null) {
            this.shareRule(plugin);
          }
        })
        this.menuItem('上移', () => {
          const plugin: Plugin | null = PluginManager.find(this.menuName);
          if (plugin !== null) {
            this.reorder(plugin, -1);
          }
        })
        this.menuItem('下移', () => {
          const plugin: Plugin | null = PluginManager.find(this.menuName);
          if (plugin !== null) {
            this.reorder(plugin, 1);
          }
        })
        /**
         * 「整理源」用的入口（2026-09-19 用户：「现在有很多源能搜索到但是解析不了视频」）。
         *
         * 标记之后这条规则从**三个入口**（来源列表 / 规则仓库 / 已装列表）一起消失，
         * 名单落盘，重启仍在；要恢复就去页面底部「已隐藏的规则」那一节点「恢复」。
         */
        this.menuItem('标记为不可用', () => {
          const name: string = this.menuName;
          if (name.length === 0) {
            return;
          }
          UnavailablePlugins.block(name);
          this.menuName = '';
          this.hiddenRev += 1;
          this.toast('已隐藏这条规则，可在列表底部恢复');
        })
        Divider().color(AppColor.outlineVariant).margin({ top: 4, bottom: 4 })
        Row() {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(20)
            .fontColor([AppColor.error])
          Blank().width(12)
          Text('删除规则')
            .fontSize(15)
            .fontColor(AppColor.error)
            .layoutWeight(1)
        }
        .width('100%')
        .height(48)
        .onClick(() => {
          this.confirmDelete([this.menuName]);
        })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(AppColor.surfaceContainerHigh)
      .borderRadius(24)
      .shadow({ radius: 24, color: '#40000000', offsetX: 0, offsetY: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .padding({ left: 24, right: 24, bottom: 24 + Dimens.contentBottomSpacer })
    .backgroundColor('#66000000')
    .onClick(() => {
      this.menuName = '';
    })
  }

  @Builder
  menuItem(label: string, action: () => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor(AppColor.onSurface)
        .layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .onClick(() => {
      action();
    })
  }

  @Builder
  addOptionsOverlay() {
    Column() {
      Column() {
        Text('添加规则')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.onSurface)
          .width('100%')
        Text('选择一种方式，添加新的番剧来源。')
          .fontSize(13)
          .fontColor(AppColor.onSurfaceVariant)
          .width('100%')
          .margin({ top: 6, bottom: 12 })

        ForEach(ADD_SOURCES, (label: string, index: number) => {
          Row() {
            Column() {
              Text(label)
                .fontSize(16)
                .fontColor(AppColor.onSurface)
                .width('100%')
              Text(ADD_SOURCE_DESCS[index])
                .fontSize(12)
                .fontColor(AppColor.onSurfaceVariant)
                .width('100%')
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .borderRadius(index === 0 ? 20 : 12)
          .backgroundColor(index === 0
            ? AppColor.secondaryContainer : AppColor.surfaceContainerLow)
          .margin({ bottom: 4 })
          .onClick(() => {
            this.onAddOption(index);
          })
        }, (label: string) => label)
      }
      .width('100%')
      .padding(20)
      .backgroundColor(AppColor.surfaceContainerHigh)
      .borderRadius(28)
      .shadow({ radius: 24, color: '#40000000', offsetX: 0, offsetY: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .padding({ left: 16, right: 16, bottom: 24 + Dimens.contentBottomSpacer })
    .backgroundColor('#66000000')
    .onClick(() => {
      this.showAddOptions = false;
    })
  }

  /**
   * 「从剪贴板导入」浮层。
   *
   * 中间那颗是系统**安全控件** `PasteButton`：用户点它 = 明确同意这一次粘贴，
   * 系统当场给一次性剪贴板授权，应用才读得到内容。直接 `getData()` 是不行的
   * （`READ_PASTEBOARD` 属于 system_basic，普通应用申请不到）。
   * 下面另给「手动粘贴」兜底：用 TextArea，用户自己长按 → 系统粘贴菜单，
   * 这条路完全不需要权限。
   */
  @Builder
  pasteOverlay() {
    Column() {
      Column() {
        Text('从剪贴板导入')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.onSurface)
          .width('100%')
        Text('先复制规则 JSON 或 kazumi:// 分享链接，再点下面的按钮。')
          .fontSize(13)
          .fontColor(AppColor.onSurfaceVariant)
          .width('100%')
          .margin({ top: 6, bottom: 16 })

        Row() {
          PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE })
            .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
              if (result === PasteButtonOnClickResult.SUCCESS) {
                this.readClipboardAndImport();
              } else {
                this.toast('没拿到剪贴板授权，可改用「手动粘贴」');
                this.showManualPaste = true;
              }
            })
        }
        .width('100%')
        .height(56)
        .justifyContent(FlexAlign.Center)

        Text(this.showManualPaste ? '收起手动粘贴' : '手动粘贴')
          .fontSize(13)
          .fontColor(AppColor.primary)
          .padding({ top: 12, bottom: 10 })
          .onClick(() => {
            this.showManualPaste = !this.showManualPaste;
          })

        if (this.showManualPaste) {
          TextArea({
            text: this.pasteDraft,
            placeholder: '在这里长按 → 粘贴规则 JSON 或 kazumi:// 链接'
          })
            .width('100%')
            .height(120)
            .fontSize(13)
            .backgroundColor(AppColor.surfaceContainerLow)
            .borderRadius(12)
            .onChange((value: string) => {
              this.pasteDraft = value;
            })
          Row() {
            Blank()
            Text('导入')
              .fontSize(14)
              .fontColor(AppColor.onPrimary)
              .padding({ left: 22, right: 22, top: 9, bottom: 9 })
              .backgroundColor(AppColor.primary)
              .borderRadius(18)
              .onClick(() => {
                this.importText(this.pasteDraft);
              })
          }
          .width('100%')
          .margin({ top: 10 })
        }

        Text('取消')
          .fontSize(14)
          .fontColor(AppColor.onSurfaceVariant)
          .padding({ top: 14, bottom: 2 })
          .onClick(() => {
            this.showPastePanel = false;
            this.showManualPaste = false;
            this.pasteDraft = '';
          })
      }
      .width('100%')
      .padding(20)
      .backgroundColor(AppColor.surfaceContainerHigh)
      .borderRadius(28)
      .shadow({ radius: 24, color: '#40000000', offsetX: 0, offsetY: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .padding({ left: 16, right: 16, bottom: 24 + Dimens.contentBottomSpacer })
    .backgroundColor('#66000000')
    .onClick(() => {
      this.showPastePanel = false;
    })
  }
}

/** 编辑器路由参数（静态槽位，与 `InfoRouteArgs` 同一套做法）。 */
export class PluginEditorRoute {
  static pending: Plugin | null = null;
  static isNew: boolean = false;
}

/** 测试页路由参数。 */
export class PluginTestRoute {
  static pending: Plugin | null = null;
}

/** 通用确认对话框（删除规则用）。 */
@CustomDialog
struct PluginConfirmDialog {
  controller: CustomDialogController = new CustomDialogController({
    builder: PluginConfirmDialog({
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
