import { AppColor } from '../theme/AppColors';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { DanmakuShieldStore } from '../services/DanmakuShieldStore';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';

/**
 * 弹幕屏蔽规则（规格 §61.3 / `danmaku_shield_settings.dart`）。
 *
 * 文案逐条对齐源码：
 *   - 标题「屏蔽规则」；右上「添加规则」弹输入框
 *   - 提示「包含关键词的弹幕会被隐藏。用 / / 包裹正则表达式。」
 *   - 空态「还没有屏蔽规则」
 *   - 计数「已添加 · N」
 *   - 正则写法（以 `/` 开头并以 `/` 结尾）在副标题标「正则表达式」
 */
@Component
export struct DanmakuShieldPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('themeRevision') themeRevision: number = 0;
  @State private rules: string[] = [];
  @State private showEditor: boolean = false;
  @State private draft: string = '';
  private editorDialog: CustomDialogController | null = null;

  aboutToAppear(): void {
    this.rules = DanmakuShieldStore.all();
    this.editorDialog = new CustomDialogController({
      builder: ShieldEditorDialog({
        onConfirm: (value: string) => {
          this.addRule(value);
        }
      }),
      autoCancel: true,
      customStyle: false
    });
  }

  private addRule(value: string): void {
    const added: boolean = DanmakuShieldStore.add(value);
    this.rules = DanmakuShieldStore.all();
    this.getUIContext().getPromptAction().showToast({
      message: added ? '已添加规则' : '规则已存在或为空'
    });
  }

  private removeRule(index: number): void {
    DanmakuShieldStore.remove(index);
    this.rules = DanmakuShieldStore.all();
    this.getUIContext().getPromptAction().showToast({ message: '已删除规则' });
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
      // 沉浸式悬浮标题层（2026-09-19）；「添加规则」作为标题右侧的操作传进去
      ImmersiveTitleLayer({
        themeRev: this.themeRevision,
        title: '屏蔽规则',
        onBack: () => {
          RouteTable.back();
        }
      }) {
        Text('添加规则')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.primary)
          .padding({ left: 8, right: 8, top: 8, bottom: 8 })
          .onClick(() => {
            const controller: CustomDialogController | null = this.editorDialog;
            if (controller !== null) {
              controller.open();
            }
          })
      }

      Scroll() {
        Column() {
          Text('包含关键词的弹幕会被隐藏。用 / / 包裹正则表达式。')
            .fontSize(13)
            .lineHeight(19)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ top: 4, bottom: 12 })

          if (this.rules.length === 0) {
            Column() {
              SymbolGlyph($r('sys.symbol.list_bullet'))
                .fontSize(40)
                .fontColor([AppColor.onSurfaceVariant])
              Text('还没有屏蔽规则')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.onSurface)
                .margin({ top: 14 })
            }
            .width('100%')
            .height(220)
            .justifyContent(FlexAlign.Center)
          } else {
            Text(`已添加 · ${this.rules.length}`)
              .fontSize(14)
              .fontColor(AppColor.onSurfaceVariant)
              .width('100%')
              .margin({ bottom: 8 })

            Column({ space: 4 }) {
              ForEach(this.rules, (rule: string, index: number) => {
                Row() {
                  Column() {
                    Text(rule)
                      .fontSize(16)
                      .fontColor(AppColor.onSurface)
                      .width('100%')
                    if (DanmakuShieldStore.isRegexRule(rule)) {
                      Text('正则表达式')
                        .fontSize(12)
                        .fontColor(AppColor.onSurfaceVariant)
                        .width('100%')
                        .margin({ top: 2 })
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  SymbolGlyph($r('sys.symbol.trash'))
                    .fontSize(20)
                    .fontColor([AppColor.error])
                    .margin({ left: 12 })
                    .onClick(() => {
                      this.removeRule(index);
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .borderRadius({
                  topLeft: index === 0 ? 24 : 4,
                  topRight: index === 0 ? 24 : 4,
                  bottomLeft: index === this.rules.length - 1 ? 24 : 4,
                  bottomRight: index === this.rules.length - 1 ? 24 : 4
                })
                .backgroundColor(AppColor.surfaceContainerLow)
              }, (rule: string, index: number) => `${index}-${rule}`)
            }
            .width('100%')
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

/** 「添加规则」对话框（源码标题即「添加规则」）。 */
@CustomDialog
struct ShieldEditorDialog {
  controller: CustomDialogController = new CustomDialogController({
    builder: ShieldEditorDialog({
      onConfirm: (value: string) => {
      }
    })
  });
  onConfirm: (value: string) => void = () => {
  };
  @State private text: string = '';

  build() {
    Column({ space: 16 }) {
      Text('添加规则')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.onSurface)
        .width('100%')
      Text('包含关键词的弹幕会被隐藏。用 / / 包裹正则表达式。')
        .fontSize(12)
        .fontColor(AppColor.onSurfaceVariant)
        .width('100%')
      TextInput({ text: this.text, placeholder: '关键词或 /正则/' })
        .fontSize(15)
        .onChange((value: string) => {
          this.text = value;
        })
      Row({ space: 12 }) {
        Button('取消')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .fontColor(AppColor.onSurfaceVariant)
          .onClick(() => {
            this.controller.close();
          })
        Button('添加')
          .fontSize(14)
          .layoutWeight(1)
          .onClick(() => {
            if (this.text.trim().length === 0) {
              return;
            }
            this.onConfirm(this.text);
            this.text = '';
            this.controller.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(24)
  }
}
