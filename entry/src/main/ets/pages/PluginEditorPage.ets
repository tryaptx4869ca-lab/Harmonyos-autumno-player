import { AppColor } from '../theme/AppColors';
import { Dimens, PageTransitionSpec } from '../theme/Tokens';
import { RouteTable } from '../router/RouteTable';
import { JsonUtils } from '../model/JsonUtils';
import { Plugin } from '../plugins/Plugin';
import {
  ApiBodyType,
  ApiChapterConfig,
  ApiChapterFormat,
  ApiEpisodePageConfig,
  ApiSearchConfig,
  RuleMode
} from '../plugins/ApiRuleConfig';
import { AntiCrawlerConfig, CaptchaDetectType, CaptchaType } from '../plugins/AntiCrawlerConfig';
import { ApiEndpoints } from '../request/config/ApiEndpoints';
import { Logger } from '../services/Logger';
import { PluginManager } from '../services/plugin/PluginManager';
import { PluginEditorRoute, PluginTestRoute } from './PluginPage';
import { ImmersiveMetrics, ImmersiveTitleLayer } from '../components/ImmersivePageScaffold';

const TAG: string = 'AutumnPluginEditor';

/**
 * 编辑器里的一行文本字段。
 *
 * 做成组件而不是带参 `@Builder`：ArkUI 的带参 `@Builder` 参数只在首次求值，
 * 状态变了文案不刷新（阶段三踩过）；组件用 `@Prop` + 回调是本工程验证过的写法
 * （`SettingsRow` / `SettingsSliderRow` 同款）。
 */
@Component
struct EditorField {
  @Prop themeRev: number = 0;
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop helper: string = '';
  @Prop isNumber: boolean = false;
  onChange: (value: string) => void = () => {
  };

  build() {
    Column({ space: 6 }) {
      Text(this.label)
        .fontSize(14)
        .fontColor(AppColor.onSurface)
        .width('100%')
      TextInput({ text: this.value })
        .type(this.isNumber ? InputType.Number : InputType.Normal)
        .fontSize(15)
        .onChange((input: string) => {
          this.onChange(input);
        })
      if (this.helper.length > 0) {
        Text(this.helper)
          .fontSize(12)
          .fontColor(AppColor.onSurfaceVariant)
          .width('100%')
      }
    }
    .width('100%')
    .margin({ top: 12 })
  }
}

/** 单选胶囊（分段控件里的一个选项）。 */
@Component
struct EditorChip {
  @Prop themeRev: number = 0;
  @Prop label: string = '';
  @Prop selected: boolean = false;
  @Prop grow: boolean = true;
  onTap: () => void = () => {
  };

  build() {
    Text(this.label)
      .fontSize(14)
      .fontWeight(this.selected ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.selected ? AppColor.onPrimary : AppColor.onSurfaceVariant)
      .layoutWeight(this.grow ? 1 : 0)
      .textAlign(TextAlign.Center)
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(this.selected ? AppColor.primary : AppColor.surfaceContainerHigh)
      .borderRadius(this.selected ? 18 : 10)
      .margin({ right: 6 })
      .onClick(() => {
        this.onTap();
      })
  }
}

/**
 * 规则编辑器（规格 §29 / `plugin_editor_page.dart`，参照实现里最大的单文件）。
 *
 * 分区表单：基本信息 → 搜索规则 → 选集规则 → 高级选项（行为 / 网络 / 反反爬虫）。
 * 字段标签逐条取自源码的 `_RuleEditorText`；XPath 与 API 两套字段按
 * `searchMode` / `chapterMode` 切换显示。
 *
 * 与源码的差异（有意，已回写文档）：
 *   - 请求头 / 查询参数用「一行 JSON 文本」编辑，而不是键值对子编辑器
 *     （功能等价、手机上更好按；解析失败会指明是哪一项）
 *   - 不折叠字段分组，只保留分段切换
 */
@Component
export struct PluginEditorPage {
  @StorageProp('topInset') topInset: number = 39;
  @StorageProp('themeRevision') themeRevision: number = 0;

  /** 0 基本信息 / 1 搜索规则 / 2 选集规则。 */
  @State private section: number = 0;
  @State private showAdvanced: boolean = false;

  // 基础信息
  @State private ruleName: string = '';
  @State private ruleVersion: string = '1.0';
  @State private baseUrl: string = '';
  @State private apiLevel: string = '9';
  @State private useNativePlayer: boolean = true;

  // 搜索：XPath
  @State private searchMode: string = RuleMode.xpath;
  @State private searchUrl: string = '';
  @State private searchList: string = '';
  @State private searchName: string = '';
  @State private searchResult: string = '';

  // 搜索：API
  @State private searchMethod: string = 'GET';
  @State private searchApiUrl: string = '';
  @State private searchHeadersText: string = '{}';
  @State private searchQueryText: string = '{}';
  @State private searchBodyType: string = ApiBodyType.none;
  @State private searchBodyText: string = '';
  @State private searchListPath: string = '$.data[*]';
  @State private searchNamePath: string = '$.name';
  @State private searchSourcePath: string = '$.url';
  @State private searchSourceTemplate: string = '';

  // 选集：XPath
  @State private chapterMode: string = RuleMode.xpath;
  @State private chapterRoads: string = '';
  @State private chapterResult: string = '';

  // 选集：API
  @State private chapterMethod: string = 'GET';
  @State private chapterApiUrl: string = '';
  @State private chapterHeadersText: string = '{}';
  @State private chapterQueryText: string = '{}';
  @State private chapterBodyType: string = ApiBodyType.none;
  @State private chapterResponseFormat: string = ApiChapterFormat.nested;
  @State private roadsPath: string = '$.data.roads[*]';
  @State private roadNamePath: string = '$.name';
  @State private episodesPath: string = '$.episodes[*]';
  @State private episodeNamePath: string = '$.name';
  @State private episodeUrlPath: string = '$.url';
  @State private roadNamesPath: string = '';
  @State private roadEpisodesPath: string = '';
  @State private roadSeparator: string = '$$$';
  @State private episodeSeparator: string = '#';
  @State private fieldSeparator: string = '$';
  @State private playPageUrl: string = '';

  // 高级
  @State private useLegacyParser: boolean = false;
  @State private adBlocker: boolean = false;
  @State private userAgent: string = '';
  @State private referer: string = '';
  @State private antiCrawlerEnabled: boolean = false;
  @State private captchaType: number = CaptchaType.imageCaptcha;
  @State private captchaDetectType: number = CaptchaDetectType.xpath;
  @State private captchaDetectValue: string = '';
  @State private captchaImage: string = '';
  @State private captchaInput: string = '';
  @State private captchaButton: string = '';
  @State private captchaScript: string = '';

  @State private saving: boolean = false;

  aboutToAppear(): void {
    const pending: Plugin | null = PluginEditorRoute.pending;
    PluginEditorRoute.pending = null;
    this.loadFromPlugin(pending === null
      ? Plugin.fromTemplate(`${ApiEndpoints.apiLevel}`) : pending);
  }

  private loadFromPlugin(plugin: Plugin): void {
    this.ruleName = plugin.name;
    this.ruleVersion = plugin.version;
    this.baseUrl = plugin.baseUrl;
    this.apiLevel = plugin.api;
    this.useNativePlayer = plugin.useNativePlayer;

    this.searchMode = RuleMode.normalize(plugin.searchMode);
    this.searchUrl = plugin.searchURL;
    this.searchList = plugin.searchList;
    this.searchName = plugin.searchName;
    this.searchResult = plugin.searchResult;

    this.chapterMode = RuleMode.normalize(plugin.chapterMode);
    this.chapterRoads = plugin.chapterRoads;
    this.chapterResult = plugin.chapterResult;

    const search: ApiSearchConfig = plugin.searchApiConfig;
    this.searchMethod = search.request.method;
    this.searchApiUrl = search.request.url;
    this.searchHeadersText = JSON.stringify(search.request.headers);
    this.searchQueryText = JSON.stringify(search.request.query);
    this.searchBodyType = ApiBodyType.normalize(search.request.bodyType);
    this.searchBodyText = search.request.body === undefined
      ? '' : `${search.request.body}`;
    this.searchListPath = search.listPath;
    this.searchNamePath = search.namePath;
    this.searchSourcePath = search.sourcePath;
    this.searchSourceTemplate = search.sourceTemplate;

    const chapter: ApiChapterConfig = plugin.chapterApiConfig;
    this.chapterMethod = chapter.request.method;
    this.chapterApiUrl = chapter.request.url;
    this.chapterHeadersText = JSON.stringify(chapter.request.headers);
    this.chapterQueryText = JSON.stringify(chapter.request.query);
    this.chapterBodyType = ApiBodyType.normalize(chapter.request.bodyType);
    this.chapterResponseFormat = ApiChapterFormat.normalize(chapter.format);
    this.roadsPath = chapter.roadsPath;
    this.roadNamePath = chapter.roadNamePath;
    this.episodesPath = chapter.episodesPath;
    this.episodeNamePath = chapter.episodeNamePath;
    this.episodeUrlPath = chapter.episodeUrlPath;
    this.roadNamesPath = chapter.roadNamesPath;
    this.roadEpisodesPath = chapter.roadEpisodesPath;
    this.roadSeparator = chapter.roadSeparator;
    this.episodeSeparator = chapter.episodeSeparator;
    this.fieldSeparator = chapter.fieldSeparator;
    this.playPageUrl = chapter.episodePage === undefined
      ? '' : chapter.episodePage.url;

    this.useLegacyParser = plugin.useLegacyParser;
    this.adBlocker = plugin.adBlocker;
    this.userAgent = plugin.userAgent;
    this.referer = plugin.referer;
    const anti: AntiCrawlerConfig = plugin.antiCrawlerConfig;
    this.antiCrawlerEnabled = anti.enabled;
    this.captchaType = anti.captchaType;
    this.captchaDetectType = anti.captchaDetectType;
    this.captchaDetectValue = anti.captchaDetectValue;
    this.captchaImage = anti.captchaImage;
    this.captchaInput = anti.captchaInput;
    this.captchaButton = anti.captchaButton;
    this.captchaScript = anti.captchaScript;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private static parseMap(text: string, label: string): Record<string, Object> {
    const value: string = text.trim();
    if (value.length === 0 || value === '{}') {
      return {};
    }
    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(value) as Object;
    } catch (error) {
      throw new Error(`${label}不是合法 JSON`);
    }
    const rec: Record<string, Object> | null = JsonUtils.asObj(parsed);
    if (rec === null) {
      throw new Error(`${label}必须是 JSON 对象`);
    }
    return rec;
  }

  /** 把表单写回一个 `Plugin`（不落盘）。字段不合法时抛错，由调用方提示。 */
  private buildPlugin(): Plugin {
    const plugin = new Plugin();
    plugin.api = this.apiLevel.trim().length > 0
      ? this.apiLevel.trim() : `${ApiEndpoints.apiLevel}`;
    plugin.type = 'anime';
    plugin.name = this.ruleName.trim();
    plugin.version = this.ruleVersion.trim();
    plugin.baseUrl = this.baseUrl.trim();
    plugin.useNativePlayer = this.useNativePlayer;

    plugin.searchMode = this.searchMode;
    plugin.searchURL = this.searchUrl.trim();
    plugin.searchList = this.searchList.trim();
    plugin.searchName = this.searchName.trim();
    plugin.searchResult = this.searchResult.trim();

    plugin.chapterMode = this.chapterMode;
    plugin.chapterRoads = this.chapterRoads.trim();
    plugin.chapterResult = this.chapterResult.trim();

    const search = new ApiSearchConfig();
    search.request.method = this.searchMethod;
    search.request.url = this.searchApiUrl.trim();
    search.request.headers = PluginEditorPage.parseMap(this.searchHeadersText,
      '搜索请求头');
    search.request.query = PluginEditorPage.parseMap(this.searchQueryText,
      '搜索查询参数');
    search.request.bodyType = this.searchBodyType;
    if (this.searchBodyText.trim().length > 0) {
      search.request.body = this.searchBodyText.trim();
    }
    search.listPath = this.searchListPath.trim();
    search.namePath = this.searchNamePath.trim();
    search.sourcePath = this.searchSourcePath.trim();
    search.sourceTemplate = this.searchSourceTemplate.trim();
    plugin.searchApiConfig = search;

    const chapter = new ApiChapterConfig();
    chapter.request.method = this.chapterMethod;
    chapter.request.url = this.chapterApiUrl.trim();
    chapter.request.headers = PluginEditorPage.parseMap(this.chapterHeadersText,
      '选集请求头');
    chapter.request.query = PluginEditorPage.parseMap(this.chapterQueryText,
      '选集查询参数');
    chapter.request.bodyType = this.chapterBodyType;
    chapter.format = this.chapterResponseFormat;
    chapter.roadsPath = this.roadsPath.trim();
    chapter.roadNamePath = this.roadNamePath.trim();
    chapter.episodesPath = this.episodesPath.trim();
    chapter.episodeNamePath = this.episodeNamePath.trim();
    chapter.episodeUrlPath = this.episodeUrlPath.trim();
    chapter.roadNamesPath = this.roadNamesPath.trim();
    chapter.roadEpisodesPath = this.roadEpisodesPath.trim();
    chapter.roadSeparator = this.roadSeparator;
    chapter.episodeSeparator = this.episodeSeparator;
    chapter.fieldSeparator = this.fieldSeparator;
    if (this.playPageUrl.trim().length > 0) {
      const page = new ApiEpisodePageConfig();
      page.url = this.playPageUrl.trim();
      chapter.episodePage = page;
    }
    plugin.chapterApiConfig = chapter;

    plugin.useLegacyParser = this.useLegacyParser;
    plugin.adBlocker = this.adBlocker;
    plugin.userAgent = this.userAgent.trim();
    plugin.referer = this.referer.trim();

    const anti = new AntiCrawlerConfig();
    anti.enabled = this.antiCrawlerEnabled;
    anti.captchaType = this.captchaType;
    anti.captchaDetectType = this.captchaDetectType;
    anti.captchaDetectValue = this.captchaDetectValue.trim();
    anti.captchaImage = this.captchaImage.trim();
    anti.captchaInput = this.captchaInput.trim();
    anti.captchaButton = this.captchaButton.trim();
    anti.captchaScript = this.captchaScript.trim();
    plugin.antiCrawlerConfig = anti;
    return plugin;
  }

  private save(): void {
    if (this.saving) {
      return;
    }
    if (this.ruleName.trim().length === 0) {
      this.section = 0;
      this.toast('请填写规则名称');
      return;
    }
    if (this.baseUrl.trim().length === 0) {
      this.section = 0;
      this.toast('请填写基础地址（URL）');
      return;
    }
    let plugin: Plugin | null = null;
    try {
      plugin = this.buildPlugin();
    } catch (error) {
      const err = error as Error;
      this.toast(err.message);
      return;
    }
    this.saving = true;
    PluginManager.upsert(plugin);
    this.saving = false;
    Logger.info(TAG, `保存规则：${plugin.name} v${plugin.version}`);
    this.toast(`已保存「${plugin.name}」`);
    RouteTable.back();
  }

  /** 测试规则：把当前编辑中的对象直接交给测试页（源码同此做法）。 */
  private test(): void {
    let plugin: Plugin | null = null;
    try {
      plugin = this.buildPlugin();
    } catch (error) {
      const err = error as Error;
      this.toast(err.message);
      return;
    }
    if (plugin.name.trim().length === 0) {
      this.toast('请填写规则名称');
      return;
    }
    PluginTestRoute.pending = plugin;
    RouteTable.push('pages/PluginTestPage');
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
      // 沉浸式悬浮标题层（2026-09-19）；「测试规则 / 保存」作为标题右侧操作
      ImmersiveTitleLayer({
        themeRev: this.themeRevision,
        title: '规则编辑器',
        onBack: () => {
          RouteTable.back();
        }
      }) {
        Row() {
          Text('测试规则')
            .fontSize(14)
            .fontColor(AppColor.primary)
            .padding({ left: 8, right: 8, top: 8, bottom: 8 })
            .onClick(() => {
              this.test();
            })
          Text(this.saving ? '保存中' : '保存')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.primary)
            .padding({ left: 8, right: 8, top: 8, bottom: 8 })
            .onClick(() => {
              this.save();
            })
        }
      }

      Scroll() {
        Column() {
          Row() {
            EditorChip({
              label: '基本信息',
              selected: this.section === 0,
              onTap: () => {
                this.section = 0;
              }
            })
            EditorChip({
              label: '搜索规则',
              selected: this.section === 1,
              onTap: () => {
                this.section = 1;
              }
            })
            EditorChip({
              label: '选集规则',
              selected: this.section === 2,
              onTap: () => {
                this.section = 2;
              }
            })
          }
          .width('100%')

          Text(this.sectionDescription())
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ top: 10, bottom: 4 })

          if (this.section === 0) {
            this.basicSection()
          } else if (this.section === 1) {
            this.searchSection()
          } else {
            this.chapterSection()
          }

          this.advancedSection()

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

  private sectionDescription(): string {
    if (this.section === 0) {
      return '规则的名称、版本与站点地址';
    }
    return this.section === 1
      ? '定义如何在站点内检索条目' : '定义如何获取播放线路与剧集列表';
  }

  /** 卡片标题（只做展示，不带回调，避免带参 @Builder 的刷新问题）。 */
  @Builder
  cardTitle(title: string) {
    Text(title)
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor(AppColor.primary)
      .width('100%')
  }

  @Builder
  basicSection() {
    Column() {
      this.cardTitle('基础信息')
      EditorField({
        label: '规则名称',
        value: this.ruleName,
        onChange: (value: string) => {
          this.ruleName = value;
        }
      })
      EditorField({
        label: '规则版本',
        value: this.ruleVersion,
        onChange: (value: string) => {
          this.ruleVersion = value;
        }
      })
      EditorField({
        label: '基础地址（URL）',
        value: this.baseUrl,
        helper: '站点首页，例如 https://www.example.com',
        onChange: (value: string) => {
          this.baseUrl = value;
        }
      })
      EditorField({
        label: '规则级别（api）',
        value: this.apiLevel,
        helper: `高于客户端支持级别（当前 ${ApiEndpoints.apiLevel}）的规则会被拒绝导入`,
        isNumber: true,
        onChange: (value: string) => {
          this.apiLevel = value;
        }
      })

      Row() {
        Column() {
          Text('使用原生播放器')
            .fontSize(15)
            .fontColor(AppColor.onSurface)
            .width('100%')
          Text('关闭后该规则的结果交给外部播放器')
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.useNativePlayer })
          .selectedColor(AppColor.primary)
          .onChange((value: boolean) => {
            this.useNativePlayer = value;
          })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .padding(16)
    .borderRadius(24)
    .backgroundColor(AppColor.surfaceContainerLow)
    .margin({ top: 12 })
  }

  @Builder
  searchSection() {
    // 搜索规则类型
    Column() {
      this.cardTitle('搜索规则类型')
      Row() {
        EditorChip({
          label: 'XPath',
          selected: this.searchMode === RuleMode.xpath,
          onTap: () => {
            this.searchMode = RuleMode.xpath;
          }
        })
        EditorChip({
          label: 'API',
          selected: this.searchMode === RuleMode.api,
          onTap: () => {
            this.searchMode = RuleMode.api;
          }
        })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .padding(16)
    .borderRadius(24)
    .backgroundColor(AppColor.surfaceContainerLow)
    .margin({ top: 12 })

    if (this.searchMode === RuleMode.xpath) {
      Column() {
        this.cardTitle('XPath 搜索规则')
        EditorField({
          label: '搜索地址（URL）',
          value: this.searchUrl,
          helper: '可用 @keyword 占位搜索词',
          onChange: (value: string) => {
            this.searchUrl = value;
          }
        })
        EditorField({
          label: '搜索结果列表（XPath）',
          value: this.searchList,
          onChange: (value: string) => {
            this.searchList = value;
          }
        })
        EditorField({
          label: '条目名称（XPath）',
          value: this.searchName,
          onChange: (value: string) => {
            this.searchName = value;
          }
        })
        EditorField({
          label: '条目链接（XPath）',
          value: this.searchResult,
          onChange: (value: string) => {
            this.searchResult = value;
          }
        })
      }
      .width('100%')
      .padding(16)
      .borderRadius(24)
      .backgroundColor(AppColor.surfaceContainerLow)
      .margin({ top: 12 })
    } else {
      Column() {
        this.cardTitle('API 搜索规则')
        Text('搜索请求方法')
          .fontSize(14)
          .fontColor(AppColor.onSurface)
          .width('100%')
          .margin({ top: 12 })
        Row() {
          EditorChip({
            label: 'GET',
            selected: this.searchMethod === 'GET',
            onTap: () => {
              this.searchMethod = 'GET';
            }
          })
          EditorChip({
            label: 'POST',
            selected: this.searchMethod === 'POST',
            onTap: () => {
              this.searchMethod = 'POST';
            }
          })
        }
        .width('100%')

        EditorField({
          label: '搜索请求地址（URL）',
          value: this.searchApiUrl,
          onChange: (value: string) => {
            this.searchApiUrl = value;
          }
        })
        EditorField({
          label: '搜索请求头（JSON）',
          value: this.searchHeadersText,
          helper: '例如 {"referer":"https://example.com"}',
          onChange: (value: string) => {
            this.searchHeadersText = value;
          }
        })
        EditorField({
          label: '搜索查询参数（JSON）',
          value: this.searchQueryText,
          helper: '例如 {"wd":"@keyword"}',
          onChange: (value: string) => {
            this.searchQueryText = value;
          }
        })

        Text('搜索请求体类型')
          .fontSize(14)
          .fontColor(AppColor.onSurface)
          .width('100%')
          .margin({ top: 12 })
        Row() {
          EditorChip({
            label: '无',
            selected: this.searchBodyType === ApiBodyType.none,
            onTap: () => {
              this.searchBodyType = ApiBodyType.none;
            }
          })
          EditorChip({
            label: 'JSON',
            selected: this.searchBodyType === ApiBodyType.json,
            onTap: () => {
              this.searchBodyType = ApiBodyType.json;
            }
          })
          EditorChip({
            label: '表单',
            selected: this.searchBodyType === ApiBodyType.form,
            onTap: () => {
              this.searchBodyType = ApiBodyType.form;
            }
          })
        }
        .width('100%')

        EditorField({
          label: '搜索请求体（JSON）',
          value: this.searchBodyText,
          onChange: (value: string) => {
            this.searchBodyText = value;
          }
        })
        EditorField({
          label: '搜索结果列表路径（JSONPath）',
          value: this.searchListPath,
          onChange: (value: string) => {
            this.searchListPath = value;
          }
        })
        EditorField({
          label: '条目名称路径（JSONPath，相对条目）',
          value: this.searchNamePath,
          onChange: (value: string) => {
            this.searchNamePath = value;
          }
        })
        EditorField({
          label: '条目来源路径（JSONPath，相对条目）',
          value: this.searchSourcePath,
          onChange: (value: string) => {
            this.searchSourcePath = value;
          }
        })
        EditorField({
          label: '详情页地址模板（URL，可选）',
          value: this.searchSourceTemplate,
          helper: '@source 替换为条目来源，如 https://site/GV@source',
          onChange: (value: string) => {
            this.searchSourceTemplate = value;
          }
        })
      }
      .width('100%')
      .padding(16)
      .borderRadius(24)
      .backgroundColor(AppColor.surfaceContainerLow)
      .margin({ top: 12 })
    }
  }

  @Builder
  chapterSection() {
    Column() {
      this.cardTitle('选集规则类型')
      Row() {
        EditorChip({
          label: 'XPath',
          selected: this.chapterMode === RuleMode.xpath,
          onTap: () => {
            this.chapterMode = RuleMode.xpath;
          }
        })
        EditorChip({
          label: 'API',
          selected: this.chapterMode === RuleMode.api,
          onTap: () => {
            this.chapterMode = RuleMode.api;
          }
        })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .padding(16)
    .borderRadius(24)
    .backgroundColor(AppColor.surfaceContainerLow)
    .margin({ top: 12 })

    if (this.chapterMode === RuleMode.xpath) {
      Column() {
        this.cardTitle('XPath 选集规则')
        EditorField({
          label: '播放线路列表（XPath）',
          value: this.chapterRoads,
          onChange: (value: string) => {
            this.chapterRoads = value;
          }
        })
        EditorField({
          label: '剧集列表（XPath）',
          value: this.chapterResult,
          onChange: (value: string) => {
            this.chapterResult = value;
          }
        })
      }
      .width('100%')
      .padding(16)
      .borderRadius(24)
      .backgroundColor(AppColor.surfaceContainerLow)
      .margin({ top: 12 })
    } else {
      Column() {
        this.cardTitle('API 选集规则')
        Text('选集请求方法')
          .fontSize(14)
          .fontColor(AppColor.onSurface)
          .width('100%')
          .margin({ top: 12 })
        Row() {
          EditorChip({
            label: 'GET',
            selected: this.chapterMethod === 'GET',
            onTap: () => {
              this.chapterMethod = 'GET';
            }
          })
          EditorChip({
            label: 'POST',
            selected: this.chapterMethod === 'POST',
            onTap: () => {
              this.chapterMethod = 'POST';
            }
          })
        }
        .width('100%')

        EditorField({
          label: '选集请求地址（URL）',
          value: this.chapterApiUrl,
          onChange: (value: string) => {
            this.chapterApiUrl = value;
          }
        })
        EditorField({
          label: '选集请求头（JSON）',
          value: this.chapterHeadersText,
          onChange: (value: string) => {
            this.chapterHeadersText = value;
          }
        })
        EditorField({
          label: '选集查询参数（JSON）',
          value: this.chapterQueryText,
          onChange: (value: string) => {
            this.chapterQueryText = value;
          }
        })

        Text('选集响应格式')
          .fontSize(14)
          .fontColor(AppColor.onSurface)
          .width('100%')
          .margin({ top: 12 })
        Row() {
          EditorChip({
            label: '嵌套 JSON',
            selected: this.chapterResponseFormat === ApiChapterFormat.nested,
            onTap: () => {
              this.chapterResponseFormat = ApiChapterFormat.nested;
            }
          })
          EditorChip({
            label: '分隔字符串',
            selected: this.chapterResponseFormat === ApiChapterFormat.delimited,
            onTap: () => {
              this.chapterResponseFormat = ApiChapterFormat.delimited;
            }
          })
        }
        .width('100%')

        if (this.chapterResponseFormat === ApiChapterFormat.nested) {
          EditorField({
            label: '播放线路列表路径（JSONPath，留空表示单线路）',
            value: this.roadsPath,
            onChange: (value: string) => {
              this.roadsPath = value;
            }
          })
          EditorField({
            label: '线路名称路径（JSONPath，相对线路）',
            value: this.roadNamePath,
            onChange: (value: string) => {
              this.roadNamePath = value;
            }
          })
          EditorField({
            label: '剧集列表路径（JSONPath，相对线路）',
            value: this.episodesPath,
            onChange: (value: string) => {
              this.episodesPath = value;
            }
          })
          EditorField({
            label: '剧集名称路径（JSONPath，相对剧集）',
            value: this.episodeNamePath,
            onChange: (value: string) => {
              this.episodeNamePath = value;
            }
          })
          EditorField({
            label: '播放入口地址路径（JSONPath）',
            value: this.episodeUrlPath,
            helper: '从剧集对象读取交给 WebView 的地址，可以是播放页面或媒体直链。',
            onChange: (value: string) => {
              this.episodeUrlPath = value;
            }
          })
        } else {
          EditorField({
            label: '线路名称串路径（JSONPath）',
            value: this.roadNamesPath,
            onChange: (value: string) => {
              this.roadNamesPath = value;
            }
          })
          EditorField({
            label: '线路剧集串路径（JSONPath）',
            value: this.roadEpisodesPath,
            onChange: (value: string) => {
              this.roadEpisodesPath = value;
            }
          })
          EditorField({
            label: '线路分隔符',
            value: this.roadSeparator,
            onChange: (value: string) => {
              this.roadSeparator = value;
            }
          })
          EditorField({
            label: '剧集分隔符',
            value: this.episodeSeparator,
            onChange: (value: string) => {
              this.episodeSeparator = value;
            }
          })
          EditorField({
            label: '名称与地址分隔符',
            value: this.fieldSeparator,
            onChange: (value: string) => {
              this.fieldSeparator = value;
            }
          })
        }

        EditorField({
          label: '播放页地址模板（URL，可选）',
          value: this.playPageUrl,
          helper: '可用变量：@source、@episodeUrl、@roadIndex/@episodeIndex（从 0 起）、@roadNumber/@episodeNumber（从 1 起）',
          onChange: (value: string) => {
            this.playPageUrl = value;
          }
        })
      }
      .width('100%')
      .padding(16)
      .borderRadius(24)
      .backgroundColor(AppColor.surfaceContainerLow)
      .margin({ top: 12 })
    }
  }

  @Builder
  advancedSection() {
    Column() {
      Row() {
        Column() {
          Text('高级选项')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.onSurface)
            .width('100%')
          Text('行为、网络与反反爬虫配置')
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph(this.showAdvanced
          ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(18)
          .fontColor([AppColor.onSurfaceVariant])
      }
      .width('100%')
      .onClick(() => {
        this.showAdvanced = !this.showAdvanced;
      })

      if (this.showAdvanced) {
        Text('行为设置')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.primary)
          .width('100%')
          .margin({ top: 16 })

        Row() {
          Column() {
            Text('简易解析')
              .fontSize(15)
              .fontColor(AppColor.onSurface)
              .width('100%')
            Text('使用简易解析器而不是现代解析器')
              .fontSize(12)
              .fontColor(AppColor.onSurfaceVariant)
              .width('100%')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.useLegacyParser })
            .selectedColor(AppColor.primary)
            .onChange((value: boolean) => {
              this.useLegacyParser = value;
            })
        }
        .width('100%')
        .margin({ top: 10 })

        Row() {
          Column() {
            Text('广告过滤')
              .fontSize(15)
              .fontColor(AppColor.onSurface)
              .width('100%')
            Text('启用 HLS 广告过滤')
              .fontSize(12)
              .fontColor(AppColor.onSurfaceVariant)
              .width('100%')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.adBlocker })
            .selectedColor(AppColor.primary)
            .onChange((value: boolean) => {
              this.adBlocker = value;
            })
        }
        .width('100%')
        .margin({ top: 10 })

        Text('网络设置')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.primary)
          .width('100%')
          .margin({ top: 16 })

        EditorField({
          label: 'User-Agent',
          value: this.userAgent,
          helper: '留空则使用内置的随机 UA',
          onChange: (value: string) => {
            this.userAgent = value;
          }
        })
        EditorField({
          label: 'Referer',
          value: this.referer,
          helper: '留空则使用基础地址',
          onChange: (value: string) => {
            this.referer = value;
          }
        })

        Text('反反爬虫')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.primary)
          .width('100%')
          .margin({ top: 16 })

        Row() {
          Column() {
            Text('启用反反爬虫')
              .fontSize(15)
              .fontColor(AppColor.onSurface)
              .width('100%')
            Text('检索失败时显示验证码验证按钮而非重试')
              .fontSize(12)
              .fontColor(AppColor.onSurfaceVariant)
              .width('100%')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.antiCrawlerEnabled })
            .selectedColor(AppColor.primary)
            .onChange((value: boolean) => {
              this.antiCrawlerEnabled = value;
            })
        }
        .width('100%')
        .margin({ top: 10 })

        if (this.antiCrawlerEnabled) {
          Text('验证类型')
            .fontSize(14)
            .fontColor(AppColor.onSurface)
            .width('100%')
            .margin({ top: 12 })
          Row() {
            EditorChip({
              label: '图片验证码',
              selected: this.captchaType === CaptchaType.imageCaptcha,
              onTap: () => {
                this.captchaType = CaptchaType.imageCaptcha;
              }
            })
            EditorChip({
              label: '自动点击',
              selected: this.captchaType === CaptchaType.autoClickButton,
              onTap: () => {
                this.captchaType = CaptchaType.autoClickButton;
              }
            })
            EditorChip({
              label: '自定义脚本',
              selected: this.captchaType === CaptchaType.customJavaScript,
              onTap: () => {
                this.captchaType = CaptchaType.customJavaScript;
              }
            })
          }
          .width('100%')
          Text(this.captchaTypeDescription())
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ top: 6 })

          Text('验证页检测方式')
            .fontSize(14)
            .fontColor(AppColor.onSurface)
            .width('100%')
            .margin({ top: 12 })
          Row() {
            EditorChip({
              label: 'XPath',
              selected: this.captchaDetectType === CaptchaDetectType.xpath,
              onTap: () => {
                this.captchaDetectType = CaptchaDetectType.xpath;
              }
            })
            EditorChip({
              label: '文本',
              selected: this.captchaDetectType === CaptchaDetectType.text,
              onTap: () => {
                this.captchaDetectType = CaptchaDetectType.text;
              }
            })
            EditorChip({
              label: '正则',
              selected: this.captchaDetectType === CaptchaDetectType.regex,
              onTap: () => {
                this.captchaDetectType = CaptchaDetectType.regex;
              }
            })
          }
          .width('100%')
          Text('优先使用该标记判断搜索响应是否为验证页')
            .fontSize(12)
            .fontColor(AppColor.onSurfaceVariant)
            .width('100%')
            .margin({ top: 6 })

          EditorField({
            label: '验证检测值',
            value: this.captchaDetectValue,
            helper: this.captchaDetectValueHint(),
            onChange: (value: string) => {
              this.captchaDetectValue = value;
            }
          })

          if (this.captchaType === CaptchaType.imageCaptcha) {
            EditorField({
              label: '验证码图片（XPath）',
              value: this.captchaImage,
              helper: '//img[@class="captcha"]',
              onChange: (value: string) => {
                this.captchaImage = value;
              }
            })
            EditorField({
              label: '验证码输入框（XPath）',
              value: this.captchaInput,
              helper: '//input[@name="captcha"]',
              onChange: (value: string) => {
                this.captchaInput = value;
              }
            })
          }
          if (this.captchaType === CaptchaType.autoClickButton) {
            EditorField({
              label: '验证按钮（XPath）',
              value: this.captchaButton,
              helper: '填写验证按钮元素的 XPath，检测到后将自动点击。',
              onChange: (value: string) => {
                this.captchaButton = value;
              }
            })
          } else {
            EditorField({
              label: '验证提交按钮（XPath）',
              value: this.captchaButton,
              helper: '//button[@type="submit"]',
              onChange: (value: string) => {
                this.captchaButton = value;
              }
            })
          }
          if (this.captchaType === CaptchaType.customJavaScript) {
            EditorField({
              label: '验证脚本',
              value: this.captchaScript,
              helper: 'KazumiCaptcha.log("ready"); KazumiCaptcha.done();',
              onChange: (value: string) => {
                this.captchaScript = value;
              }
            })
          }
        }
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(24)
    .backgroundColor(AppColor.surfaceContainerLow)
    .margin({ top: 16 })
  }

  private captchaTypeDescription(): string {
    if (this.captchaType === CaptchaType.autoClickButton) {
      return '检测到验证按钮后自动模拟点击';
    }
    if (this.captchaType === CaptchaType.customJavaScript) {
      return '加载页面后执行规则内的验证脚本';
    }
    return '展示验证码图片，由用户手动输入';
  }

  private captchaDetectValueHint(): string {
    if (this.captchaDetectType === CaptchaDetectType.text) {
      return '身份验证';
    }
    if (this.captchaDetectType === CaptchaDetectType.regex) {
      return '身份验证|smart_verify';
    }
    return '//button[@id="verify"]';
  }
}
