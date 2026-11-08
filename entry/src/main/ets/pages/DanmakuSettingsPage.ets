import { AppColor } from '../theme/AppColors';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { SectionHeader, SettingsRow, SettingsRowKind } from '../components/SettingsList';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';
import { SettingsSliderRow, groupBottomRadius, groupTopRadius } from '../components/SettingsRows';
import { DanmakuShieldStore } from '../services/DanmakuShieldStore';
import { SettingKeyDef, SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';

/**
 * 弹幕设置（规格 §43.1 / §61）。
 *
 * 四组（顺序与 `danmaku_settings.dart` 一致）：
 *   弹幕来源：BiliBili / Gamer / 弹弹play —— 三个源开关
 *   弹幕屏蔽：关键词屏蔽（进屏蔽规则页，带「已添加 · N」）
 *   弹幕显示：区域 / 持续时间 / 行高 / 跟随倍速 / 顶底滚动 / 海量 / 去重
 *   弹幕样式：描边 / 描边粗细 / 颜色 / 字号 / 字重 / 不透明度
 *
 * 滑杆范围与数值文案逐条对齐源码（区域是百分比、持续时间带「秒」等）。
 */
@Component
export struct DanmakuSettingsPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('themeRevision') themeRevision: number = 0;

  @State private bilibili: boolean = true;
  @State private gamer: boolean = true;
  @State private danDan: boolean = true;
  @State private shieldCount: number = 0;
  /** 弹弹play 应用凭据（留空 = 跳过该来源），见 `DanmakuApi.authHeaders`。 */
  @State private danDanAppId: string = '';
  @State private danDanSecret: string = '';
  /** 凭据编辑弹层。 */
  @State private showCredEditor: boolean = false;
  @State private credAppId: string = '';
  @State private credSecret: string = '';
  @State private area: number = 0.5;
  @State private duration: number = 8;
  @State private lineHeight: number = 1;
  @State private followSpeed: boolean = false;
  @State private top: boolean = true;
  @State private bottom: boolean = true;
  @State private scroll: boolean = true;
  @State private massive: boolean = false;
  @State private deduplication: boolean = false;

  /** 弹幕描边开关。**不能叫 `border`**：与 ArkUI 内置属性同名会冲突。 */
  @State private borderOn: boolean = true;
  @State private borderSize: number = 0.6;
  @State private color: boolean = true;
  @State private fontSize: number = 16;
  @State private fontWeight: number = 5;
  /** **不能叫 `opacity`**：与 ArkUI 内置属性同名会冲突。 */
  @State private opacityValue: number = 1;

  aboutToAppear(): void {
    this.load();
    this.shieldCount = DanmakuShieldStore.count();
  }

  @StorageProp('navShown:pages/DanmakuSettingsPage') @Watch('onNavShown') navShownTick: number = 0;

  onNavShown(): void {
    this.shieldCount = DanmakuShieldStore.count();
  }

  private load(): void {
    this.bilibili = SettingsStore.getBool(SettingsKeys.danmakuBiliBiliSource);
    this.gamer = SettingsStore.getBool(SettingsKeys.danmakuGamerSource);
    this.danDan = SettingsStore.getBool(SettingsKeys.danmakuDanDanSource);
    this.danDanAppId = SettingsStore.getString(SettingsKeys.danmakuDanDanAppId);
    this.danDanSecret =
      SettingsStore.getString(SettingsKeys.danmakuDanDanAppSecret);

    this.area = SettingsStore.getNumber(SettingsKeys.danmakuArea);
    this.duration = SettingsStore.getNumber(SettingsKeys.danmakuDuration);
    this.lineHeight = SettingsStore.getNumber(SettingsKeys.danmakuLineHeight);
    this.followSpeed = SettingsStore.getBool(SettingsKeys.danmakuFollowSpeed);
    this.top = SettingsStore.getBool(SettingsKeys.danmakuTop);
    this.bottom = SettingsStore.getBool(SettingsKeys.danmakuBottom);
    this.scroll = SettingsStore.getBool(SettingsKeys.danmakuScroll);
    this.massive = SettingsStore.getBool(SettingsKeys.danmakuMassive);
    this.deduplication = SettingsStore.getBool(SettingsKeys.danmakuDeduplication);

    this.borderOn = SettingsStore.getBool(SettingsKeys.danmakuBorder);
    this.borderSize = SettingsStore.getNumber(SettingsKeys.danmakuBorderSize);
    this.color = SettingsStore.getBool(SettingsKeys.danmakuColor);
    this.fontSize = SettingsStore.getNumber(SettingsKeys.danmakuFontSize);
    this.fontWeight = SettingsStore.getNumber(SettingsKeys.danmakuFontWeight);
    this.opacityValue = SettingsStore.getNumber(SettingsKeys.danmakuOpacity);
  }

  private restoreDefaults(): void {
    const keys: SettingKeyDef[] = [
      SettingsKeys.danmakuBiliBiliSource, SettingsKeys.danmakuGamerSource,
      SettingsKeys.danmakuDanDanSource, SettingsKeys.danmakuArea,
      SettingsKeys.danmakuDuration, SettingsKeys.danmakuLineHeight,
      SettingsKeys.danmakuFollowSpeed, SettingsKeys.danmakuTop,
      SettingsKeys.danmakuBottom, SettingsKeys.danmakuScroll,
      SettingsKeys.danmakuMassive, SettingsKeys.danmakuDeduplication,
      SettingsKeys.danmakuBorder, SettingsKeys.danmakuBorderSize,
      SettingsKeys.danmakuColor, SettingsKeys.danmakuFontSize,
      SettingsKeys.danmakuFontWeight, SettingsKeys.danmakuOpacity
    ];
    for (let i = 0; i < keys.length; i++) {
      SettingsStore.resetDefault(keys[i]);
    }
    this.load();
    this.getUIContext().getPromptAction().showToast({ message: '已恢复默认弹幕设置' });
  }

  private static percent(value: number): string {
    return `${Math.round(value * 100)}%`;
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
        title: '弹幕设置',
        onBack: () => {
          RouteTable.back();
        }
      })

      Scroll() {
        Column() {
          // ---------------- 弹幕来源 ----------------
          SectionHeader({ title: '弹幕来源' })
          Column({ space: 4 }) {
            SettingsRow({
              title: 'BiliBili',
              kind: SettingsRowKind.toggle,
              checked: this.bilibili,
              topRadius: groupTopRadius(0),
              bottomRadius: groupBottomRadius(0, 3),
              onToggle: (value: boolean) => {
                this.bilibili = value;
                SettingsStore.put(SettingsKeys.danmakuBiliBiliSource, value);
              }
            })
            SettingsRow({
              title: 'Gamer',
              kind: SettingsRowKind.toggle,
              checked: this.gamer,
              topRadius: groupTopRadius(1),
              bottomRadius: groupBottomRadius(1, 3),
              onToggle: (value: boolean) => {
                this.gamer = value;
                SettingsStore.put(SettingsKeys.danmakuGamerSource, value);
              }
            })
            SettingsRow({
              title: '弹弹play',
              kind: SettingsRowKind.toggle,
              checked: this.danDan,
              topRadius: groupTopRadius(2),
              bottomRadius: groupBottomRadius(2, 4),
              onToggle: (value: boolean) => {
                this.danDan = value;
                SettingsStore.put(SettingsKeys.danmakuDanDanSource, value);
              }
            })
            /**
             * 弹弹play 凭据（2026-09-22）。
             *
             * 它现在要求应用凭证，匿名请求一律 403（详见 `DanmakuApi` 的注释）。
             * 申请入口在 `https://dev.dandanplay.com`；没填就跳过这个来源，
             * 由哔哩哔哩承担。
             */
            SettingsRow({
              title: '弹弹play 凭据',
              /**
               * 三态：两个都填了 = 用自定义的；只填一个 = 不完整（会跳过该来源，
               * 避免「拿内置密钥配自定义 AppId」这种混搭）；都没填 = 用**内置凭据**
               * 公开快照不附带内置凭据，需要用户自行申请。
               */
              description: this.danDanAppId.length > 0 && this.danDanSecret.length > 0
                ? '已使用自定义凭据'
                : (this.danDanAppId.length > 0 || this.danDanSecret.length > 0
                  ? '凭据不完整 · 该来源会被跳过'
                  : '未配置 · 点击填写自己的凭据'),
              icon: $r('sys.symbol.key'),
              showChevron: true,
              topRadius: groupTopRadius(3),
              bottomRadius: groupBottomRadius(3, 4),
              onTap: () => {
                this.credAppId = this.danDanAppId;
                this.credSecret = this.danDanSecret;
                this.showCredEditor = true;
              }
            })
          }
          .width('100%')

          // ---------------- 弹幕屏蔽 ----------------
          SectionHeader({ title: '弹幕屏蔽' })
          SettingsRow({
            title: '关键词屏蔽',
            description: `已添加 · ${this.shieldCount}`,
            icon: $r('sys.symbol.xmark'),
            // 2026-09-19：本行进二级页（`DanmakuShieldPage`），补行尾箭头。
            // 同页「恢复默认设置」是就地执行、不跳页，**不要**跟着加。
            showChevron: true,
            topRadius: 24,
            bottomRadius: 24,
            onTap: () => {
              RouteTable.push('pages/DanmakuShieldPage');
            }
          })

          // ---------------- 弹幕显示 ----------------
          SectionHeader({ title: '弹幕显示' })
          Column({ space: 4 }) {
            SettingsSliderRow({
              title: '弹幕区域',
              valueText: DanmakuSettingsPage.percent(this.area),
              value: this.area,
              min: 0,
              max: 1,
              step: 0.125,
              topRadius: groupTopRadius(0),
              bottomRadius: groupBottomRadius(0, 9),
              onChange: (value: number) => {
                this.area = value;
                SettingsStore.put(SettingsKeys.danmakuArea, value);
              }
            })
            SettingsSliderRow({
              title: '弹幕持续时间',
              valueText: `${Math.round(this.duration)} 秒`,
              value: this.duration,
              min: 2,
              max: 16,
              step: 1,
              topRadius: groupTopRadius(1),
              bottomRadius: groupBottomRadius(1, 9),
              onChange: (value: number) => {
                this.duration = Math.round(value);
                SettingsStore.put(SettingsKeys.danmakuDuration, this.duration);
              }
            })
            SettingsSliderRow({
              title: '弹幕行高',
              valueText: this.lineHeight.toFixed(1),
              value: this.lineHeight,
              min: 0,
              max: 3,
              step: 0.1,
              topRadius: groupTopRadius(2),
              bottomRadius: groupBottomRadius(2, 9),
              onChange: (value: number) => {
                this.lineHeight = Number(value.toFixed(1));
                SettingsStore.put(SettingsKeys.danmakuLineHeight, this.lineHeight);
              }
            })
            SettingsRow({
              title: '弹幕跟随视频倍速',
              description: '开启后弹幕速度会随视频倍速而改变',
              kind: SettingsRowKind.toggle,
              checked: this.followSpeed,
              topRadius: groupTopRadius(3),
              bottomRadius: groupBottomRadius(3, 9),
              onToggle: (value: boolean) => {
                this.followSpeed = value;
                SettingsStore.put(SettingsKeys.danmakuFollowSpeed, value);
              }
            })
            SettingsRow({
              title: '顶部弹幕',
              kind: SettingsRowKind.toggle,
              checked: this.top,
              topRadius: groupTopRadius(4),
              bottomRadius: groupBottomRadius(4, 9),
              onToggle: (value: boolean) => {
                this.top = value;
                SettingsStore.put(SettingsKeys.danmakuTop, value);
              }
            })
            SettingsRow({
              title: '底部弹幕',
              kind: SettingsRowKind.toggle,
              checked: this.bottom,
              topRadius: groupTopRadius(5),
              bottomRadius: groupBottomRadius(5, 9),
              onToggle: (value: boolean) => {
                this.bottom = value;
                SettingsStore.put(SettingsKeys.danmakuBottom, value);
              }
            })
            SettingsRow({
              title: '滚动弹幕',
              kind: SettingsRowKind.toggle,
              checked: this.scroll,
              topRadius: groupTopRadius(6),
              bottomRadius: groupBottomRadius(6, 9),
              onToggle: (value: boolean) => {
                this.scroll = value;
                SettingsStore.put(SettingsKeys.danmakuScroll, value);
              }
            })
            SettingsRow({
              title: '海量弹幕',
              description: '弹幕过多时进行叠加绘制',
              kind: SettingsRowKind.toggle,
              checked: this.massive,
              topRadius: groupTopRadius(7),
              bottomRadius: groupBottomRadius(7, 9),
              onToggle: (value: boolean) => {
                this.massive = value;
                SettingsStore.put(SettingsKeys.danmakuMassive, value);
              }
            })
            SettingsRow({
              title: '弹幕去重',
              description: '相同内容弹幕过多时合并为一条弹幕',
              kind: SettingsRowKind.toggle,
              checked: this.deduplication,
              topRadius: groupTopRadius(8),
              bottomRadius: groupBottomRadius(8, 9),
              onToggle: (value: boolean) => {
                this.deduplication = value;
                SettingsStore.put(SettingsKeys.danmakuDeduplication, value);
              }
            })
          }
          .width('100%')

          // ---------------- 弹幕样式 ----------------
          SectionHeader({ title: '弹幕样式' })
          Column({ space: 4 }) {
            SettingsRow({
              title: '弹幕描边',
              kind: SettingsRowKind.toggle,
              checked: this.borderOn,
              topRadius: groupTopRadius(0),
              bottomRadius: groupBottomRadius(0, 6),
              onToggle: (value: boolean) => {
                this.borderOn = value;
                SettingsStore.put(SettingsKeys.danmakuBorder, value);
              }
            })
            SettingsSliderRow({
              title: '弹幕描边粗细',
              valueText: this.borderSize.toFixed(1),
              value: this.borderSize,
              min: 0.1,
              max: 3,
              step: 0.1,
              topRadius: groupTopRadius(1),
              bottomRadius: groupBottomRadius(1, 6),
              onChange: (value: number) => {
                this.borderSize = Number(value.toFixed(1));
                SettingsStore.put(SettingsKeys.danmakuBorderSize, this.borderSize);
              }
            })
            SettingsRow({
              title: '弹幕颜色',
              kind: SettingsRowKind.toggle,
              checked: this.color,
              topRadius: groupTopRadius(2),
              bottomRadius: groupBottomRadius(2, 6),
              onToggle: (value: boolean) => {
                this.color = value;
                SettingsStore.put(SettingsKeys.danmakuColor, value);
              }
            })
            SettingsSliderRow({
              title: '字体大小',
              valueText: `${Math.floor(this.fontSize)}`,
              value: this.fontSize,
              min: 10,
              max: 32,
              step: 1,
              topRadius: groupTopRadius(3),
              bottomRadius: groupBottomRadius(3, 6),
              onChange: (value: number) => {
                this.fontSize = Math.floor(value);
                SettingsStore.put(SettingsKeys.danmakuFontSize, this.fontSize);
              }
            })
            SettingsSliderRow({
              title: '字体字重',
              valueText: `${this.fontWeight}`,
              value: this.fontWeight,
              min: 1,
              max: 9,
              step: 1,
              topRadius: groupTopRadius(4),
              bottomRadius: groupBottomRadius(4, 6),
              onChange: (value: number) => {
                this.fontWeight = Math.round(value);
                SettingsStore.put(SettingsKeys.danmakuFontWeight, this.fontWeight);
              }
            })
            SettingsSliderRow({
              title: '弹幕不透明度',
              valueText: DanmakuSettingsPage.percent(this.opacityValue),
              value: this.opacityValue,
              min: 0.1,
              max: 1,
              step: 0.05,
              topRadius: groupTopRadius(5),
              bottomRadius: groupBottomRadius(5, 6),
              onChange: (value: number) => {
                this.opacityValue = Number(value.toFixed(2));
                SettingsStore.put(SettingsKeys.danmakuOpacity, this.opacityValue);
              }
            })
          }
          .width('100%')

          Column() {
            SettingsRow({
              title: '恢复默认设置',
              description: '将弹幕相关设置恢复为默认值',
              icon: $r('sys.symbol.arrow_2_circlepath'),
              topRadius: 24,
              bottomRadius: 24,
              onTap: () => {
                this.restoreDefaults();
              }
            })
          }
          .width('100%')
          .margin({ top: 16 })

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
    .bindSheet($$this.showCredEditor, this.credentialEditor(), {
      height: 320,
      dragBar: false,
      onDisappear: () => {
        this.showCredEditor = false;
      }
    })
  }

  /**
   * 弹弹play 凭据编辑弹层（AppId + AppSecret）。
   *
   * 提醒文案里直接给申请入口：官方文档说得很清楚，要先去
   * `https://dev.dandanplay.com` 注册开发者、创建应用、过审之后才会拿到
   * 一个 AppId 与两个 AppSecret。留空则保存为「未配置」＝跳过该来源。
   */
  @Builder
  credentialEditor() {
    Column({ space: 12 }) {
      Text('弹弹play 应用凭据')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.onSurface)
        .width('100%')
      /**
       * 说明改了两层含义：①应用**自带内置凭据**，不用自己申请；
       * ②这两个框是「覆盖内置」用的（有自己申请的凭据就填自己的）。
       */
      Text('应用已内置可用凭据，无需填写即可使用弹弹play 弹幕；\n' +
        '若你有自己在 dev.dandanplay.com 申请的凭据，可在此覆盖（两个都要填）。')
        .fontSize(12)
        .fontColor(AppColor.onSurfaceVariant)
        .width('100%')
      TextInput({ text: this.credAppId, placeholder: 'AppId' })
        .fontSize(15)
        .onChange((value: string) => {
          this.credAppId = value;
        })
      TextInput({ text: this.credSecret, placeholder: 'AppSecret' })
        .fontSize(15)
        .onChange((value: string) => {
          this.credSecret = value;
        })
      Row({ space: 12 }) {
        Button('清空')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .fontColor(AppColor.onSurfaceVariant)
          .onClick(() => {
            SettingsStore.put(SettingsKeys.danmakuDanDanAppId, '');
            SettingsStore.put(SettingsKeys.danmakuDanDanAppSecret, '');
            this.danDanAppId = '';
            this.danDanSecret = '';
            this.credAppId = '';
            this.credSecret = '';
            this.showCredEditor = false;
            this.getUIContext().getPromptAction()
              .showToast({ message: '已清空弹弹play凭据' });
          })
        Button('保存')
          .fontSize(14)
          .layoutWeight(1)
          .onClick(() => {
            const id: string = this.credAppId.trim();
            const secret: string = this.credSecret.trim();
            SettingsStore.put(SettingsKeys.danmakuDanDanAppId, id);
            SettingsStore.put(SettingsKeys.danmakuDanDanAppSecret, secret);
            this.danDanAppId = id;
            this.danDanSecret = secret;
            this.showCredEditor = false;
            this.getUIContext().getPromptAction().showToast({
              message: id.length > 0 ? '已保存弹弹play凭据' : '已清空弹弹play凭据'
            });
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 20, bottom: 20 })
  }
}
