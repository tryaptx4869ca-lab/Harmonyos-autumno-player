import { AppColor } from '../theme/AppColors';
import { Hct } from '../theme/color/Hct';

/**
 * 配色方案卡片。
 * 逐行移植自源码 `lib/bean/card/palette_card.dart`：
 *
 *   70×70 卡片（底色 surfaceContainerLow @ 0.9、圆角 16、无阴影）
 *   └ 内边距 10
 *     └ 圆形裁剪
 *       ├ 上半：HCT(hue, 20, 90)
 *       └ 下半：左 HCT(hue+50, 20, 85) / 右 HCT(hue, 30, 50)
 *   选中时叠一个 25×25 圆（HCT(hue, 30, 40)），中心 12 的 checkmark，
 *   图标色为 surfaceContainerLow。
 */
@Component
export struct PaletteCard {
  /** 主题版本：由父组件下发，@Prop 变化会让本组件整体重跑 build。 */
  @Prop themeRev: number = 0;
  /** 会随主题/选中变化，必须是 @Prop（普通成员不会二次同步）。 */
  @Prop
  colorArgb: number = 0;
  @Prop
  selected: boolean = false;
  onPick: () => void = () => {
  };

  private primaryOf(): string {
    return PaletteCard.hex(Hct.from(this.hueOf(), 20.0, 90.0).toInt());
  }

  private tertiaryOf(): string {
    return PaletteCard.hex(Hct.from(this.hueOf() + 50.0, 20.0, 85.0).toInt());
  }

  private containerOf(): string {
    return PaletteCard.hex(Hct.from(this.hueOf(), 30.0, 50.0).toInt());
  }

  private checkColorOf(): string {
    return PaletteCard.hex(Hct.from(this.hueOf(), 30.0, 40.0).toInt());
  }

  private hueOf(): number {
    return Hct.fromInt(this.colorArgb >>> 0).hue;
  }

  private static hex(argb: number): string {
    return '#' + ((argb >>> 0) & 0xFFFFFF).toString(16).toUpperCase().padStart(6, '0');
  }

  build() {
    Stack() {
      Column() {
        Column() {
          Column()
            .width('100%')
            .layoutWeight(1)
            .backgroundColor(this.primaryOf())
          Row() {
            Column()
              .layoutWeight(1)
              .height('100%')
              .backgroundColor(this.tertiaryOf())
            Column()
              .layoutWeight(1)
              .height('100%')
              .backgroundColor(this.containerOf())
          }
          .width('100%')
          .layoutWeight(1)
        }
        .width(50)
        .height(50)
        .borderRadius(25)
        .clip(true)
      }
      .width(70)
      .height(70)
      .padding(10)
      .borderRadius(16)
      .backgroundColor(AppColor.surfaceContainerLow)

      if (this.selected) {
        Stack() {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(12)
            .fontColor([AppColor.surfaceContainerLow])
        }
        .width(25)
        .height(25)
        .borderRadius(12.5)
        .backgroundColor(this.checkColorOf())
      }
    }
    .width(70)
    .height(70)
    .onClick(() => {
      this.onPick();
    })
  }
}
