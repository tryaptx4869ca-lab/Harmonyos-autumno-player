import { image } from '@kit.ImageKit';
import { AppColor } from '../theme/AppColors';
import { LoadingIndicator } from './LoadingIndicator';

/**
 * 验证码对话框的阶段（与参照实现 `_SourceCaptchaFlow` 的三种对话框一一对应）。
 *
 * - `loading`   正在加载验证码（图还没到手）
 * - `image`     图到手：显示图 + 输入框 + 「验证」
 * - `verifying` 已提交：圈 +「正在等待验证结果…」
 * - `auto`      类型 2/3 的自动验证：大圈 +「正在验证」
 * - `passed`    验证通过：主色圆 + 勾，3 秒后自动关闭并继续检索
 */
export class CaptchaPhase {
  static readonly loading: string = 'loading';
  static readonly image: string = 'image';
  static readonly verifying: string = 'verifying';
  static readonly auto: string = 'auto';
  static readonly passed: string = 'passed';
}

/**
 * 反爬验证对话框。
 *
 * 逐项对齐参照实现 `lib/pages/info/source_captcha_flow.dart`：
 *   - 外框 `_VerifyDialogFrame`：`surfaceContainerHigh`、圆角 28、maxWidth 420、
 *     内边距 (24,24,24,16)、标题区「verified_user 图标 20 + 插件名」后接大字标题；
 *   - 图片框：`surfaceContainerHighest`、圆角 20、内边距 16、`minHeight` 128，
 *     图高 88、白底、居中、圆角 8；
 *     （2026-09-19：底色从主题派生的 `surfaceContainerHighest` 换成**系统灰白**
 *     `sys.color.comp_background_secondary`，见 `imageArea()` 上方注释。）
 *   - 有图之后右对齐一个「换一张」（refresh 图标 18）；
 *   - 输入框：labelText「验证码」、圆角 12、错误文案「请输入图片中的字符」/「未能提交，请重试」；
 *   - 按钮：「返回来源」（文字按钮）/「验证」（**系统灰白按钮**
 *     `ButtonStyleMode.NORMAL`，图没到手或提交中禁用，提交中显示「验证中…」）；
 *   - 验证通过态：主色圆 64 + 勾，**3 秒后自动关闭**（由父组件计时）。
 *
 * 状态全部放在父组件（`@Link`），组件只负责画——这样换页/重建不会把进行中的流程搞丢。
 */
@Component
export struct CaptchaVerifyDialog {
  /** 插件名（标题区第一行）。 */
  @Prop pluginName: string = '';
  /** 当前阶段，取 `CaptchaPhase` 里的常量。 */
  @Link phase: string;
  /** 图片加载或提交失败的文案（空串表示没有错误）。 */
  @Link errorText: string;
  /** 用户输入的验证码（双向绑定）。 */
  @Link code: string;
  /** 已解码的验证码图（`undefined` 表示还没到手）。 */
  @Link pixel: image.PixelMap | undefined;
  /** 点「验证」。 */
  onSubmit: (code: string) => void = () => {};
  /** 点「换一张」/「重新加载」。 */
  onReload: () => void = () => {};
  /** 点「返回来源」。 */
  onCancel: () => void = () => {};

  /** 标题（三种状态三套文案，取自参照实现）。 */
  private title(): string {
    if (this.phase === CaptchaPhase.passed) {
      return '验证通过';
    }
    if (this.phase === CaptchaPhase.auto) {
      return '正在验证';
    }
    return '输入验证码';
  }

  private description(): string {
    if (this.phase === CaptchaPhase.passed) {
      return '即将自动继续检索。';
    }
    if (this.phase === CaptchaPhase.auto) {
      return '正在等待网站响应，通过后会自动继续检索。';
    }
    return '输入下图中的字符，继续检索此来源。';
  }

  /** 图片框内容：错误态 / 加载与提交中 / 图片。 */
  @Builder
  imageArea() {
    if (this.errorText.length > 0 && this.pixel === undefined) {
      Column() {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
          .fontSize(28)
          .fontColor([AppColor.onSurfaceVariant])
        Text(this.errorText)
          .fontSize(13)
          .fontColor(AppColor.onSurfaceVariant)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
        Button('重新加载')
          .fontSize(13)
          .height(40)
          .backgroundColor(Color.Transparent)
          .fontColor(AppColor.primary)
          .onClick(() => {
            this.onReload();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    } else if (this.pixel === undefined || this.phase === CaptchaPhase.verifying) {
      Column() {
        LoadingIndicator({ sizeVp: 40 })
        Text(this.phase === CaptchaPhase.verifying ? '正在等待验证结果…' : '正在加载验证码…')
          .fontSize(13)
          .fontColor(AppColor.onSurfaceVariant)
          .textAlign(TextAlign.Center)
          .margin({ top: 12 })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    } else {
      Row() {
        Image(this.pixel)
          .height(88)
          .objectFit(ImageFit.Contain)
          .borderRadius(8)
          .backgroundColor(Color.White)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
  }

  build() {
    Column() {
      // ---- 标题区（verified_user + 插件名，再一行大字标题）----
      Row() {
        SymbolGlyph($r('sys.symbol.checkmark_shield'))
          .fontSize(20)
          .fontColor([AppColor.onSurfaceVariant])
          .margin({ right: 8 })
        Text(this.pluginName)
          .fontSize(14)
          .fontColor(AppColor.onSurfaceVariant)
          .layoutWeight(1)
      }
      .width('100%')

      Text(this.title())
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.onSurface)
        .width('100%')
        .margin({ top: 16 })

      Text(this.description())
        .fontSize(14)
        .fontColor(AppColor.onSurfaceVariant)
        .width('100%')
        .margin({ top: 20 })

      // ---- 内容区 ----
      if (this.phase === CaptchaPhase.passed) {
        Column() {
          Column() {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(32)
              .fontColor([AppColor.onPrimaryContainer])
          }
          .width(64)
          .height(64)
          .borderRadius(32)
          .backgroundColor(AppColor.primaryContainer)
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 24, bottom: 24 })
      } else if (this.phase === CaptchaPhase.auto) {
        Column() {
          LoadingIndicator({ sizeVp: 72 })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 16, bottom: 16 })
      } else {
        /**
         * 图片框底色：**系统灰白**（2026-09-19 用户：「源的验证码弹窗包裹验证码的
         * 颜色……好像没有调成灰白」）。
         *
         * 外框前一天已经统一成 `sys.color.comp_background_primary`（系统弹窗白），
         * 只有这块还在用主题派生的 `surfaceContainerHighest`——那是「近白 + 极淡
         * 主题色」的中性色，摆在同一张弹窗里就是「两种白」，浅色下偏米、深色下
         * 偏棕。换成系统的 `comp_background_secondary` 之后，白底 + 灰白控件
         * 与系统弹窗、与筛选/热度弹窗都是同一套语言（同 2026-09-17「统一到系统
         * 的灰白」那条决策）。
         */
        Column() {
          this.imageArea()
        }
        .width('100%')
        .constraintSize({ minHeight: 128 })
        .padding(16)
        .backgroundColor($r('sys.color.comp_background_secondary'))
        .borderRadius(20)
        .justifyContent(FlexAlign.Center)
        .margin({ top: 24 })

        if (this.pixel !== undefined) {
          Row() {
            Text('换一张')
              .fontSize(13)
              .fontColor(AppColor.primary)
              .onClick(() => {
                if (this.phase !== CaptchaPhase.verifying) {
                  this.onReload();
                }
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
          .margin({ top: 4 })

          TextInput({ text: this.code, placeholder: ' ' })
            .type(InputType.Normal)
            .fontSize(15)
            .width('100%')
            .height(52)
            .borderRadius(12)
            .enabled(this.phase !== CaptchaPhase.verifying)
            .margin({ top: 4 })
            .onChange((value: string) => {
              this.code = value;
              if (this.errorText.length > 0) {
                this.errorText = '';
              }
            })
            .onSubmit(() => {
              this.submit();
            })

          // 输入框下方就是原版的错误文案位置（原版用 InputDecoration.errorText）
          if (this.errorText.length > 0) {
            Text(this.errorText)
              .fontSize(12)
              .fontColor(AppColor.error)
              .width('100%')
              .margin({ top: 6 })
          }
        }
      }

      // ---- 按钮区 ----
      Row({ space: 8 }) {
        if (this.phase !== CaptchaPhase.passed) {
          Button('返回来源')
            .fontSize(14)
            .height(48)
            .layoutWeight(1)
            .backgroundColor(Color.Transparent)
            .fontColor(AppColor.primary)
            .onClick(() => {
              this.onCancel();
            })
        }
        if (this.phase === CaptchaPhase.image || this.phase === CaptchaPhase.loading ||
          this.phase === CaptchaPhase.verifying) {
          /**
           * 「验证」＝确认按钮：**系统灰白**（2026-09-19 用户：「……还有后续的
           * 确认颜色好像没有调成灰白」）。
           *
           * 之前没指定样式，取的是 ArkUI 默认的 **强调按钮**（`comp_background_emphasize`，
           * 系统蓝）——白色弹窗里唯一一块高饱和蓝，和「统一到系统的灰白」这套
           * 语言不合。`ButtonStyleMode.NORMAL` 就是系统那档**灰白按钮**：
           * 底 `comp_background_secondary`、字 `comp_foreground_primary`，
           * 而且禁用态由系统自己降级（图没到手 / 提交中 / 还没输入时看起来
           * 就是「按不动」的灰），不用手写一套禁用配色。
           */
          Button(this.phase === CaptchaPhase.verifying ? '验证中…' : '验证')
            .fontSize(14)
            .height(48)
            .layoutWeight(1)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .enabled(this.pixel !== undefined && this.phase !== CaptchaPhase.verifying &&
              this.code.trim().length > 0)
            .onClick(() => {
              this.submit();
            })
        }
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .constraintSize({ maxWidth: 420 })
    .padding({ left: 24, right: 24, top: 24, bottom: 16 })
    /**
     * 白色底（2026-09-19 用户：「番剧源的验证码弹窗也做成白色的」）。
     *
     * 同 `SearchFilterPanel` / 弹幕设置弹层：`sys.color.comp_background_primary`
     * 是系统弹窗那层白，跟着系统深浅色走，不是主题派生的中性色。
     * 卡片内的输入框 / 图片框仍是 `surfaceContainerHighest` 的浅灰，
     * 压在纯白上正好是「白底 + 浅灰控件」的系统弹窗观感。
     */
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(28)
  }

  private submit(): void {
    if (this.phase === CaptchaPhase.verifying) {
      return;
    }
    const value: string = this.code.trim();
    if (value.length === 0) {
      this.errorText = '请输入图片中的字符';
      return;
    }
    this.errorText = '';
    this.onSubmit(value);
  }
}
