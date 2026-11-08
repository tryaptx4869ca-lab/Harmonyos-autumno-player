import { AppColor } from '../theme/AppColors';
import { AppCurves } from '../theme/Tokens';
import { MotionRuntime } from '../theme/MotionRuntime';
import {
  defaultAnimeTags,
  searchSortLabel,
  searchSortOptions,
  SearchDateRange,
  SearchDoubleRange,
  SearchFilterState,
  SearchIntRange,
  SearchParser
} from '../utils/SearchParser';
import { formatDateParts, weekdayName } from '../utils/SearchDates';

/**
 * 「按条件查找」面板。对应参照实现 `pages/search/search_filter_sheet.dart`。
 *
 * 分组与文案逐条对齐：排序方式 / 题材标签 / 放送时间 / 评分与排名 / 收藏状态，
 * 底部「重置 + 查看结果」。面板只编辑草稿，点「查看结果」才把结果回抛给
 * 搜索页——与参照实现 `_SearchFilterResult` 一致。
 *
 * 与参照实现的差异（ArkUI 组件能力所限，已在报告里记录）：
 *   1. 下拉用 `Select`（Flutter 是 DropdownButtonFormField）；
 *   2. 区间用两个 `Slider`（Flutter 是 RangeSlider）；
 *   3. 分组默认展开状态与 Flutter 相同（有值时展开）。
 */
@Component
export struct SearchFilterPanel {
  /** 初始条件（由搜索页用当前查询串解析后传入）。 */
  initial: SearchFilterState = new SearchFilterState();
  initialHideWatched: boolean = false;
  initialHideAbandoned: boolean = false;
  onApply: (state: SearchFilterState, hideWatched: boolean,
    hideAbandoned: boolean) => void = () => {
  };
  onClose: () => void = () => {
  };

  @State sort: string = 'heat';
  @State tags: string[] = [];
  @State customTag: string = '';
  @State season: string = '';
  @State dateStart: string = '';
  @State dateEnd: string = '';
  @State weekdays: number[] = [];
  @State scoreEnabled: boolean = false;
  @State scoreMin: number = 7;
  @State scoreMax: number = 10;
  @State rankEnabled: boolean = false;
  @State rankMin: number = 1;
  @State rankMax: number = 5000;
  @State hideWatched: boolean = false;
  @State hideAbandoned: boolean = false;
  @State expandedTags: boolean = false;
  @State expandedAirtime: boolean = false;
  @State expandedScore: boolean = false;
  @State expandedStatus: boolean = false;
  /**
   * 入场进度 0 → 1。
   *
   * 参照实现 `adaptive_bottom_sheet.dart:103-127` 用的是
   * `SpringSimulation(SpringDescription.withDampingRatio(mass: 1, stiffness: 380,
   * ratio: 0.8), 0, 1, 0, snapToEnd: false)`——**保留过冲**，
   * 再由 `(1 - value) * 200` 的位移与 `clamp(value, 0, 1)` 的透明度驱动
   * （`:197-205`）。这里的时长由弹簧参数决定，`animateTo` 不给 duration。
   */
  @State private entrance: number = 0;

  aboutToAppear(): void {
    this.initFromInitial();
    if (MotionRuntime.isOff()) {
      // 关闭动画时直接落到终点（源码 `_entrance.value = 1`）
      this.entrance = 1;
      return;
    }
    animateTo({ curve: AppCurves.springSheet() }, () => {
      this.entrance = 1;
    });
  }

  /** 把传入的初始条件摊到各状态上。 */
  private initFromInitial(): void {
    const state: SearchFilterState = this.initial;
    this.sort = state.sort;
    this.tags = state.tags.slice();
    this.season = state.season;
    if (state.dateRange !== null) {
      this.dateStart = state.dateRange.start;
      this.dateEnd = state.dateRange.end;
    }
    this.weekdays = state.weekdays.slice();
    if (state.scoreRange !== null) {
      this.scoreEnabled = state.scoreRange.isValid();
      this.scoreMin = state.scoreRange.hasMin ? state.scoreRange.min : 0;
      this.scoreMax = state.scoreRange.hasMax ? state.scoreRange.max : 10;
    }
    if (state.rankRange !== null) {
      this.rankEnabled = state.rankRange.isValid();
      this.rankMin = state.rankRange.hasMin ? state.rankRange.min : 1;
      this.rankMax = state.rankRange.hasMax ? state.rankRange.max : 10000;
    }
    this.hideWatched = this.initialHideWatched;
    this.hideAbandoned = this.initialHideAbandoned;
    this.expandedTags = this.tags.length > 0;
    this.expandedAirtime = this.season.length > 0 || this.dateStart.length > 0;
    this.expandedScore = this.scoreEnabled || this.rankEnabled;
    this.expandedStatus = this.hideWatched || this.hideAbandoned;
  }

  /** 日期摘要：季度优先，其次自定义日期。 */
  private dateSummary(): string {
    if (this.season.length > 0) {
      return SearchParser.seasonDescription(this.season);
    }
    if (this.dateStart.length > 0 && this.dateEnd.length > 0) {
      return `${this.dateStart} 至 ${this.dateEnd}`;
    }
    return '不限日期';
  }

  private scoreSummary(): string {
    const parts: string[] = [];
    if (this.scoreEnabled) {
      parts.push(`评分 ${this.scoreMin.toFixed(1)}..${this.scoreMax.toFixed(1)}`);
    }
    if (this.rankEnabled) {
      parts.push(`排名 ${this.rankMin}..${this.rankMax}`);
    }
    return parts.length === 0 ? '不限' : parts.join(' · ');
  }

  private statusSummary(): string {
    const parts: string[] = [];
    if (this.hideWatched) {
      parts.push('隐藏已看');
    }
    if (this.hideAbandoned) {
      parts.push('隐藏已弃');
    }
    return parts.length === 0 ? '显示全部' : parts.join(' · ');
  }

  private toggleTag(tag: string): void {
    const index: number = this.tags.indexOf(tag);
    if (index >= 0) {
      this.tags = this.tags.filter((item: string) => item !== tag);
    } else {
      this.tags = this.tags.concat([tag]);
    }
  }

  private addCustomTag(): void {
    const value: string = this.customTag.trim();
    if (value.length === 0 || this.tags.indexOf(value) >= 0) {
      return;
    }
    this.tags = this.tags.concat([value]);
    this.customTag = '';
  }

  private toggleWeekday(day: number): void {
    if (this.weekdays.indexOf(day) >= 0) {
      this.weekdays = this.weekdays.filter((item: number) => item !== day);
    } else {
      this.weekdays = this.weekdays.concat([day]).sort((a: number, b: number) => a - b);
    }
  }

  private reset(): void {
    this.sort = 'heat';
    this.tags = [];
    this.customTag = '';
    this.season = '';
    this.dateStart = '';
    this.dateEnd = '';
    this.weekdays = [];
    this.scoreEnabled = false;
    this.scoreMin = 7;
    this.scoreMax = 10;
    this.rankEnabled = false;
    this.rankMin = 1;
    this.rankMax = 5000;
    this.hideWatched = false;
    this.hideAbandoned = false;
  }

  private buildState(): SearchFilterState {
    const state: SearchFilterState = this.initial.clone();
    state.sort = this.sort;
    state.tags = this.tags.slice();
    state.season = this.season;
    state.dateRange = this.dateStart.length > 0 && this.dateEnd.length > 0
      ? new SearchDateRange(this.dateStart, this.dateEnd) : null;
    state.weekdays = this.weekdays.slice();
    state.scoreRange = this.scoreEnabled
      ? new SearchDoubleRange(this.scoreMin, this.scoreMax, true, true) : null;
    state.rankRange = this.rankEnabled
      ? new SearchIntRange(this.rankMin, this.rankMax, true, true) : null;
    return state;
  }

  /** 自定义日期：先选开始，再选结束（对齐参照实现的 showDateRangePicker）。 */
  private pickStartDate(): void {
    DatePickerDialog.show({
      start: new Date(1970, 0, 1),
      end: new Date(2100, 11, 31),
      selected: this.dateStart.length > 0
        ? new Date(this.dateStart) : new Date(),
      onDateAccept: (value: Date) => {
        this.dateStart = formatDateParts(value.getFullYear(),
          value.getMonth() + 1, value.getDate());
        this.season = '';
      }
    });
  }

  private pickEndDate(): void {
    DatePickerDialog.show({
      start: new Date(1970, 0, 1),
      end: new Date(2100, 11, 31),
      selected: this.dateEnd.length > 0 ? new Date(this.dateEnd) : new Date(),
      onDateAccept: (value: Date) => {
        this.dateEnd = formatDateParts(value.getFullYear(),
          value.getMonth() + 1, value.getDate());
        this.season = '';
      }
    });
  }

  build() {
    Column() {
      this.header()
      Scroll() {
        Column() {
          this.sortSection()
          this.tagsHeader()
          if (this.expandedTags) {
            Column() {
              this.tagsSection()
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ bottom: 20 })
          }
          Divider().color(AppColor.outlineVariant)
          this.airtimeHeader()
          if (this.expandedAirtime) {
            Column() {
              this.airtimeSection()
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ bottom: 20 })
          }
          Divider().color(AppColor.outlineVariant)
          this.scoreHeader()
          if (this.expandedScore) {
            Column() {
              this.scoreSection()
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ bottom: 20 })
          }
          Divider().color(AppColor.outlineVariant)
          this.statusHeader()
          if (this.expandedStatus) {
            Column() {
              this.statusSection()
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ bottom: 20 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 24, right: 24, bottom: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      this.footer()
    }
    .width('100%')
    .constraintSize({ maxHeight: '90%' })
    /**
     * 白色底（2026-09-19 用户：「筛选的弹窗颜色也做成白色」）。
     *
     * 用 `sys.color.comp_background_primary`——与弹幕设置弹层、
     * `CharacterSheet` 同一个「系统默认白」，跟着系统深浅色走，
     * 而不是主题派生出来的那档 M3 中性色（摆在一起会是「两种白」）。
     */
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius({ topLeft: 28, topRight: 28 })
    .clip(true)
    // 弹簧入场：位移 (1 - v) × 200、透明度 clamp(v, 0, 1)（§38.4 第 1 处）
    .translate({ y: (1 - this.entrance) * 200 })
    .opacity(Math.max(0, Math.min(1, this.entrance)))
  }

  @Builder
  header() {
    Row() {
      Text('筛选番剧')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.onSurface)
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(18)
        .fontColor([AppColor.onSurfaceVariant])
        .padding(8)
        .onClick(() => {
          this.onClose();
        })
    }
    .width('100%')
    .padding({ left: 24, right: 16, top: 16, bottom: 8 })
  }

  @Builder
  sortSection() {
    Column() {
      Text('排序方式')
        .fontSize(13)
        .fontColor(AppColor.onSurfaceVariant)
      Select(this.sortOptions())
        .selected(this.sortIndex())
        .value(`按${searchSortLabel(this.sort)}排序`)
        .width('100%')
        .margin({ top: 6 })
        .onSelect((index: number) => {
          this.sort = searchSortOptions[index].key;
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 12 })
  }

  private sortOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i = 0; i < searchSortOptions.length; i++) {
      options.push({ value: `按${searchSortOptions[i].label}排序` });
    }
    return options;
  }

  private sortIndex(): number {
    for (let i = 0; i < searchSortOptions.length; i++) {
      if (searchSortOptions[i].key === this.sort) {
        return i;
      }
    }
    return 0;
  }

  /**
   * 分组标题行。
   *
   * ⚠️ 四个标题各自成一个**无参** `@Builder`，且不再互相调用带参 builder：
   * ArkUI V1 下按值传参会把参数求值一次，之后状态变化**不会**刷新该参数
   * （实测：标签已选中，但摘要仍停在「不限题材」）。标题、摘要、箭头
   * 都必须写成「本组件状态的直接表达式」才会跟着刷新。
   */
  @Builder
  tagsHeader() {
    Row() {
      Column() {
        Text('题材标签')
          .fontSize(16)
          .fontColor(AppColor.onSurface)
        Text(this.tags.length === 0 ? '不限题材' : this.tags.join('、'))
          .fontSize(12)
          .fontColor(AppColor.onSurfaceVariant)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph(this.expandedTags
        ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
        .fontSize(18)
        .fontColor([AppColor.onSurfaceVariant])
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .onClick(() => {
        this.expandedTags = !this.expandedTags;
      })
  }

  @Builder
  airtimeHeader() {
    Row() {
      Column() {
        Text('放送时间')
          .fontSize(16)
          .fontColor(AppColor.onSurface)
        Text(this.dateSummary() + (this.weekdays.length > 0
          ? ` · 已选 ${this.weekdays.length} 天` : ''))
          .fontSize(12)
          .fontColor(AppColor.onSurfaceVariant)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph(this.expandedAirtime
        ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
        .fontSize(18)
        .fontColor([AppColor.onSurfaceVariant])
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .onClick(() => {
        this.expandedAirtime = !this.expandedAirtime;
      })
  }

  @Builder
  scoreHeader() {
    Row() {
      Column() {
        Text('评分与排名')
          .fontSize(16)
          .fontColor(AppColor.onSurface)
        Text(this.scoreSummary())
          .fontSize(12)
          .fontColor(AppColor.onSurfaceVariant)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph(this.expandedScore
        ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
        .fontSize(18)
        .fontColor([AppColor.onSurfaceVariant])
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .onClick(() => {
        this.expandedScore = !this.expandedScore;
      })
  }

  @Builder
  statusHeader() {
    Row() {
      Column() {
        Text('收藏状态')
          .fontSize(16)
          .fontColor(AppColor.onSurface)
        Text(this.statusSummary())
          .fontSize(12)
          .fontColor(AppColor.onSurfaceVariant)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph(this.expandedStatus
        ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
        .fontSize(18)
        .fontColor([AppColor.onSurfaceVariant])
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .onClick(() => {
        this.expandedStatus = !this.expandedStatus;
      })
  }

  @Builder
  tagsSection() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.allTags(), (tag: string) => {
        Text(tag)
          .fontSize(13)
          .fontColor(this.tags.indexOf(tag) >= 0
            ? AppColor.onPrimaryContainer : AppColor.onSurface)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .margin({ right: 8, bottom: 8 })
          .backgroundColor(this.tags.indexOf(tag) >= 0
            ? AppColor.primaryContainer : AppColor.surfaceContainerHighest)
          .borderRadius(16)
          .onClick(() => {
            this.toggleTag(tag);
          })
      }, (tag: string) => `tag-${tag}`)
    }
    .width('100%')

    Row() {
      TextInput({ text: this.customTag, placeholder: '自定义标签' })
        .layoutWeight(1)
        .height(44)
        .fontSize(14)
        .onChange((value: string) => {
          this.customTag = value;
        })
        .onSubmit(() => {
          this.addCustomTag();
        })
      Button('添加')
        .fontSize(13)
        .height(40)
        .margin({ left: 8 })
        .onClick(() => {
          this.addCustomTag();
        })
    }
    .width('100%')
    .margin({ top: 4 })
  }

  /** 已选标签 + 默认标签（去重，参照实现 `{...defaultAnimeTags, ...tags}`）。 */
  private allTags(): string[] {
    return defaultAnimeTags.concat(
      this.tags.filter((tag: string) => defaultAnimeTags.indexOf(tag) < 0));
  }

  @Builder
  airtimeSection() {
    Column() {
      Select(this.seasonOptions())
        .selected(this.seasonIndex())
        .value(this.season.length === 0
          ? '不限季度' : SearchParser.seasonDescription(this.season))
        .width('100%')
        .onSelect((index: number) => {
          this.season = index === 0 ? '' : SearchParser.seasonKeys()[index - 1];
          this.dateStart = '';
          this.dateEnd = '';
        })

      Row() {
        Button('自定义日期')
          .fontSize(13)
          .height(38)
          .backgroundColor(AppColor.surfaceContainerHighest)
          .fontColor(AppColor.onSurface)
          .onClick(() => {
            this.pickStartDate();
          })
        if (this.dateStart.length > 0) {
          Text(`${this.dateStart} 起`)
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .margin({ left: 8 })
            .onClick(() => {
              this.pickEndDate();
            })
          Button('清除日期')
            .fontSize(13)
            .height(38)
            .margin({ left: 8 })
            .backgroundColor(AppColor.surfaceContainerHighest)
            .fontColor(AppColor.onSurface)
            .onClick(() => {
              this.dateStart = '';
              this.dateEnd = '';
              this.season = '';
            })
        }
      }
      .width('100%')
      .margin({ top: 8 })

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach([1, 2, 3, 4, 5, 6, 7], (day: number) => {
          Text(`周${weekdayName(day)}`)
            .fontSize(13)
            .fontColor(this.weekdays.indexOf(day) >= 0
              ? AppColor.onPrimaryContainer : AppColor.onSurface)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .margin({ right: 8, bottom: 8 })
            .backgroundColor(this.weekdays.indexOf(day) >= 0
              ? AppColor.primaryContainer : AppColor.surfaceContainerHighest)
            .borderRadius(16)
            .onClick(() => {
              this.toggleWeekday(day);
            })
        }, (day: number) => `weekday-${day}`)
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private seasonOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '不限季度' }];
    const keys: string[] = SearchParser.seasonKeys();
    for (let i = 0; i < keys.length; i++) {
      options.push({ value: SearchParser.seasonDescription(keys[i]) });
    }
    return options;
  }

  private seasonIndex(): number {
    if (this.season.length === 0) {
      return 0;
    }
    const keys: string[] = SearchParser.seasonKeys();
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] === this.season) {
        return i + 1;
      }
    }
    return 0;
  }

  @Builder
  scoreSection() {
    Column() {
      Row() {
        Text('限定评分').fontSize(15).fontColor(AppColor.onSurface).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.scoreEnabled })
          .onChange((isOn: boolean) => {
            this.scoreEnabled = isOn;
          })
      }
      .width('100%')

      if (this.scoreEnabled) {
        Text(`评分下限 ${this.scoreMin.toFixed(1)}`)
          .fontSize(12).fontColor(AppColor.onSurfaceVariant).margin({ top: 8 })
        Slider({
          value: this.scoreMin, min: 0, max: 10, step: 0.5,
          style: SliderStyle.InSet
        })
          .width('100%')
          // 胶囊槽（与夏绊设置页同款）：32vp 厚槽 + 18vp 白滑块
          .trackThickness(32)
          .blockSize({ width: 18, height: 18 })
          .blockColor(AppColor.sliderBlock)
          .trackColor(AppColor.sliderTrack)
          .selectedColor(AppColor.primary)
          .onChange((value: number) => {
            this.scoreMin = Math.min(value, this.scoreMax);
          })
        Text(`评分上限 ${this.scoreMax.toFixed(1)}`)
          .fontSize(12).fontColor(AppColor.onSurfaceVariant)
        Slider({
          value: this.scoreMax, min: 0, max: 10, step: 0.5,
          style: SliderStyle.InSet
        })
          .width('100%')
          .trackThickness(32)
          .blockSize({ width: 18, height: 18 })
          .blockColor(AppColor.sliderBlock)
          .trackColor(AppColor.sliderTrack)
          .selectedColor(AppColor.primary)
          .onChange((value: number) => {
            this.scoreMax = Math.max(value, this.scoreMin);
          })
      }

      Row() {
        Text('限定排名').fontSize(15).fontColor(AppColor.onSurface).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.rankEnabled })
          .onChange((isOn: boolean) => {
            this.rankEnabled = isOn;
          })
      }
      .width('100%')
      .margin({ top: 12 })

      if (this.rankEnabled) {
        Text(`排名 ${this.rankMin} .. ${this.rankMax}`)
          .fontSize(12).fontColor(AppColor.onSurfaceVariant).margin({ top: 8 })
        Row() {
          Slider({
            value: this.rankMin, min: 1, max: 10000, step: 50,
            style: SliderStyle.InSet
          })
            .layoutWeight(1)
            .trackThickness(32)
            .blockSize({ width: 18, height: 18 })
            .blockColor(AppColor.sliderBlock)
            .trackColor(AppColor.sliderTrack)
            .selectedColor(AppColor.primary)
            .onChange((value: number) => {
              this.rankMin = Math.min(value, this.rankMax);
            })
          Slider({
            value: this.rankMax, min: 1, max: 10000, step: 50,
            style: SliderStyle.InSet
          })
            .layoutWeight(1)
            .margin({ left: 8 })
            .trackThickness(32)
            .blockSize({ width: 18, height: 18 })
            .blockColor(AppColor.sliderBlock)
            .trackColor(AppColor.sliderTrack)
            .selectedColor(AppColor.primary)
            .onChange((value: number) => {
              this.rankMax = Math.max(value, this.rankMin);
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  statusSection() {
    Column() {
      Row() {
        Text('隐藏看过的番剧').fontSize(15)
          .fontColor(AppColor.onSurface).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.hideWatched })
          .onChange((isOn: boolean) => {
            this.hideWatched = isOn;
          })
      }
      .width('100%')
      Row() {
        Text('隐藏抛弃的番剧').fontSize(15)
          .fontColor(AppColor.onSurface).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.hideAbandoned })
          .onChange((isOn: boolean) => {
            this.hideAbandoned = isOn;
          })
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
  }

  @Builder
  footer() {
    Row() {
      Text('重置')
        .fontSize(15)
        .fontColor(AppColor.primary)
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .onClick(() => {
          this.reset();
        })
      Button('查看结果')
        .fontSize(15)
        .height(56)
        .layoutWeight(1)
        .margin({ left: 16 })
        .onClick(() => {
          this.onApply(this.buildState(), this.hideWatched, this.hideAbandoned);
        })
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 12, bottom: 24 })
  }
}
