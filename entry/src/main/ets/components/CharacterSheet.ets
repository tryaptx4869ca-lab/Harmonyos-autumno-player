import { AppColor } from '../theme/AppColors';
import { AppMaterial } from '../theme/Material';
import { Dimens } from '../theme/Tokens';
import { BangumiApi } from '../api/BangumiApi';
import { CharacterFullItem, CharacterInfoField } from '../model/InfoModels';
import { BangumiImageUrlRewriter } from '../services/BangumiImageUrlRewriter';
import { LoadingIndicator } from './LoadingIndicator';

/**
 * 角色详情弹层（对应参照实现 `lib/pages/info/character_page.dart` +
 * `character_info_view.dart` —— 源码就是**底部弹层**，
 * `MaterialBottomSheetHeader` + 内容滚动）。
 *
 * 2026-09-17 第二轮：最初做成了独立二级页，用户要求「改成底部弹层」，
 * 于是搬回弹层。挂载方式见 `InfoPage` 的 `sheetContent()`——
 * **与「播放来源」共用同一个 `bindSheet`**，靠 `sheetKind` 切换内容。
 * 本工程有过「同一页挂多个 bindSheet 只显示一个」的先例（播放页那一批），
 * 所以不给详情页叠第二个 bindSheet。
 *
 * 数据：`BangumiApi.getCharacterFullByID` → `CharacterFullItem`。
 * 标题/关系/声优由点进来的那一行带过来，接口没回来时先显示这些。
 */

/** 「基本资料」优先展示的字段（源码 `_quickKeys`）。 */
const QUICK_KEYS: string[] = ['性别', '生日', '年龄', '身高', '体重', '血型'];

@Component
export struct CharacterSheet {
  @Prop themeRev: number = 0;
  /** 点进来的那一行带过来的信息。 */
  characterId: number = 0;
  characterName: string = '';
  characterRelation: string = '';
  actorNames: string[] = [];

  @State private character: CharacterFullItem | null = null;
  @State private failed: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.failed = false;
    this.character = null;
    const result: CharacterFullItem | null =
      await BangumiApi.getCharacterFullByID(this.characterId);
    if (result === null) {
      this.failed = true;
      return;
    }
    this.character = result;
  }

  // ============================================================
  // 取文案（对应 `character_info_view.dart` 里那几个 name 分支）
  // ============================================================

  private displayName(): string {
    const c: CharacterFullItem | null = this.character;
    if (c !== null && c.nameCn.length > 0) {
      return c.nameCn;
    }
    if (this.characterName.trim().length > 0) {
      return this.characterName.trim();
    }
    if (c !== null && c.name.length > 0) {
      return c.name;
    }
    return '人物';
  }

  private originalName(): string {
    const c: CharacterFullItem | null = this.character;
    if (c === null || c.name.length === 0) {
      return '';
    }
    return c.name === this.displayName() ? '' : c.name;
  }

  /** 去掉「引用来源」（源码 `fields` 的过滤）。 */
  private allFields(): CharacterInfoField[] {
    const c: CharacterFullItem | null = this.character;
    if (c === null) {
      return [];
    }
    const out: CharacterInfoField[] = [];
    for (let i = 0; i < c.infobox.length; i++) {
      if (c.infobox[i].key !== '引用来源') {
        out.push(c.infobox[i]);
      }
    }
    return out;
  }

  /** 基本资料：命中 `QUICK_KEYS` 的字段，最多 4 条。 */
  private quickFields(): CharacterInfoField[] {
    const fields: CharacterInfoField[] = this.allFields();
    const out: CharacterInfoField[] = [];
    for (let i = 0; i < fields.length && out.length < 4; i++) {
      if (QUICK_KEYS.indexOf(fields[i].key) >= 0) {
        out.push(fields[i]);
      }
    }
    return out;
  }

  /** 更多资料：去掉「简体中文名」与已在基本资料里出现过的。 */
  private moreFields(): CharacterInfoField[] {
    const fields: CharacterInfoField[] = this.allFields();
    const quick: CharacterInfoField[] = this.quickFields();
    const out: CharacterInfoField[] = [];
    for (let i = 0; i < fields.length; i++) {
      const f: CharacterInfoField = fields[i];
      if (f.key === '简体中文名' || quick.indexOf(f) >= 0) {
        continue;
      }
      out.push(f);
    }
    return out;
  }

  private hasAnyContent(): boolean {
    const c: CharacterFullItem | null = this.character;
    if (c === null) {
      return false;
    }
    return this.allFields().length > 0 || c.summary.length > 0
      || c.unstructuredInfo.length > 0;
  }

  build() {
    Column() {
      // 弹层自己的标题行（对应 `MaterialBottomSheetHeader`）
      Row() {
        Text(this.displayName())
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .height(48)
      .padding({ left: 24, right: 24 })
      .alignItems(VerticalAlign.Center)

      if (this.failed) {
        this.failureBlock()
      } else if (this.character === null) {
        this.skeleton()
      } else {
        this.body()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  body() {
    Scroll() {
      Column() {
        this.portrait()

        if (this.character !== null) {
          this.profileCard(this.character)
        }

        if (this.quickFields().length > 0) {
          this.basicSection()
        }

        if (this.character !== null && this.character.summary.length > 0) {
          this.textSection('人物简介', this.character.summary)
        }

        if (this.moreFields().length > 0) {
          this.moreSection()
        }

        if (this.character !== null && this.character.unstructuredInfo.length > 0) {
          this.textSection('人物资料', this.character.unstructuredInfo)
        }

        if (!this.hasAnyContent()) {
          this.emptyCard()
        }
      }
      .width('100%')
      .padding({
        left: Dimens.contentInset,
        right: Dimens.contentInset,
        top: 4,
        bottom: 32
      })
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /** 立绘卡：图片按 `Contain` 放，避免把人物裁掉。 */
  @Builder
  portrait() {
    Column() {
      if (this.character !== null && this.character.image.length > 0) {
        Image(BangumiImageUrlRewriter.rewriteWithSettings(this.character.image))
          .width('100%')
          .height(260)
          .objectFit(ImageFit.Contain)
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.person_2'))
            .fontSize(40)
            .fontColor([AppColor.onSurfaceVariant])
          Text('暂无人物图片')
            .fontSize(14)
            .fontColor(AppColor.onSurfaceVariant)
            .margin({ top: 12 })
        }
        .width('100%')
        .height(180)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(28)
    .backgroundColor($r('sys.color.comp_background_primary'))
  }

  /** 资料卡：关系胶囊 + 姓名 + 原名 + 配音。 */
  @Builder
  profileCard(c: CharacterFullItem) {
    Column() {
      if (this.characterRelation.trim().length > 0
        && this.characterRelation !== '未知') {
        Text(this.characterRelation)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.onSecondaryContainer)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(999)
          .backgroundColor(AppColor.secondaryContainer)
      }
      Text(this.displayName())
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.onSurface)
        .width('100%')
        .margin({ top: this.characterRelation.trim().length > 0 ? 12 : 0 })
      if (this.originalName().length > 0) {
        Text(this.originalName())
          .fontSize(14)
          .fontColor(AppColor.onSurfaceVariant)
          .width('100%')
          .margin({ top: 8 })
      }
      if (this.actorNames.length > 0) {
        this.field('配音', this.actorNames.join(' / '), 20)
      }
    }
    .width('100%')
    .padding(20)
    .margin({ top: 16 })
    .borderRadius(28)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(18)
      .fontColor(AppColor.onSurface)
      .width('100%')
  }

  @Builder
  basicSection() {
    Column() {
      this.sectionTitle('基本资料')
      Column() {
        this.fieldGrid(this.quickFields())
      }
      .width('100%')
      .padding(20)
      .margin({ top: 8 })
      .borderRadius(28)
      .backgroundColor($r('sys.color.comp_background_primary'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .margin({ top: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  moreSection() {
    Column() {
      this.sectionTitle('更多资料')
      Column() {
        this.fieldGrid(this.moreFields())
      }
      .width('100%')
      .padding(20)
      .margin({ top: 8 })
      .borderRadius(28)
      .backgroundColor($r('sys.color.comp_background_primary'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .margin({ top: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  textSection(title: string, text: string) {
    Column() {
      this.sectionTitle(title)
      Column() {
        Text(text)
          .fontSize(15)
          .lineHeight(24)
          .fontColor(AppColor.onSurfaceVariant)
          .width('100%')
      }
      .width('100%')
      .padding(20)
      .margin({ top: 8 })
      .borderRadius(28)
      .backgroundColor($r('sys.color.comp_background_primary'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .margin({ top: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  fieldGrid(fields: CharacterInfoField[]) {
    Column() {
      ForEach(fields, (f: CharacterInfoField) => {
        this.field(f.key, f.value, 16)
      }, (f: CharacterInfoField) => `field-${f.key}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  field(label: string, value: string, topMargin: number) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontColor(AppColor.onSurfaceVariant)
        .width('100%')
      Text(value)
        .fontSize(15)
        .lineHeight(22)
        .fontColor(AppColor.onSurface)
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .margin({ top: topMargin })
    .alignItems(HorizontalAlign.Start)
  }

  /** 骨架（源码 `Skeletonizer`：一张 300 高的卡 + 5 行文字）。 */
  @Builder
  skeleton() {
    Column() {
      Column()
        .width('100%')
        .height(260)
        .borderRadius(28)
        .backgroundColor(AppColor.surfaceContainerLow)
      Column({ space: 10 }) {
        ForEach([0, 1, 2, 3, 4], (index: number) => {
          Column()
            .width(index === 4 ? '62%' : '100%')
            .height(14)
            .borderRadius(7)
            .backgroundColor(AppColor.surfaceContainerHighest)
        }, (index: number) => `bone-${index}`)
      }
      .width('100%')
      .margin({ top: 24 })
      .alignItems(HorizontalAlign.Start)

      LoadingIndicator({ sizeVp: 32 })
        .margin({ top: 32 })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: Dimens.contentInset, right: Dimens.contentInset, top: 4 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  failureBlock() {
    Column() {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(44)
        .fontColor([AppColor.onSurfaceVariant])
      Text('人物资料加载失败')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.onSurface)
        .margin({ top: 16 })
      Text('请检查网络连接后重试。')
        .fontSize(13)
        .fontColor(AppColor.onSurfaceVariant)
        .margin({ top: 8 })
      Text('重新加载')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.onSecondaryContainer)
        .padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .backgroundColor(AppColor.secondaryContainer)
        .borderRadius(20)
        .margin({ top: 20 })
        .onClick(() => {
          this.load();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: Dimens.contentInset * 2, right: Dimens.contentInset * 2 })
  }

  @Builder
  emptyCard() {
    Column() {
      SymbolGlyph($r('sys.symbol.person_2'))
        .fontSize(40)
        .fontColor([AppColor.onSurfaceVariant])
      Text('暂无人物资料')
        .fontSize(15)
        .fontColor(AppColor.onSurfaceVariant)
        .margin({ top: 12 })
    }
    .width('100%')
    .padding(28)
    .margin({ top: 24 })
    .borderRadius(28)
    .backgroundColor($r('sys.color.comp_background_primary'))
  }
}
