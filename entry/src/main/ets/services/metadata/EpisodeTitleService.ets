import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BangumiApi } from '../../api/BangumiApi';
import { ApiClient, ApiResponse } from '../../request/core/ApiClient';
import { ApiEndpoints } from '../../request/config/ApiEndpoints';
import { Logger } from '../Logger';
import { SettingsKeys } from '../storage/SettingsKeys';
import { SettingsStore } from '../storage/SettingsStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'EpisodeTitle';

/** 哔哩哔哩搜索出来的一个季。 */
class BiliSeason {
  seasonId: number = 0;
  title: string = '';
  episodeCount: number = 0;
  /**
   * 该季的开播时间（秒级时间戳，来自搜索结果的 `pubtime`）。
   *
   * 同名番剧有多个季时（「时光代理人」第一季 / 第二季 / 第三季 / 英都篇），
   * 只有集数和年份能把它们分开：2026-09-20 实测选季选中了**第一季**
   * （它跟条目名一字不差，拿了满分），于是把第一季的集名贴到了第三季的集上。
   */
  publishSeconds: number = 0;
}

/**
 * 一条分集：**本地集号** + 标题。
 *
 * `sort` 这个名字是为了跟上游字段对上，但它的值在进入 `EpisodeFetch` 之前
 * 已经换算成「本地第几集」：
 *   - Bangumi：`fromBangumi` 按顺序下标重编号成 1…N（**不看上游 sort**）；
 *   - 哔哩哔哩：`seasonTitles` 直接用季自己的集号（`title` 字段）。
 */
class EpisodeLine {
  sort: number = 0;
  name: string = '';
  /**
   * 哔哩哔哩分集 id（`cid`）。
   *
   * 拿它取这一集的**弹幕**（`BilibiliDanmakuApi`）。Bangumi 那条路没有这个
   * 字段，留 0 即可——弹幕兜底只认哔哩哔哩的季，不会用 Bangumi 的集号去猜。
   */
  cid: number = 0;
}

/**
 * 一次分集抓取的结果。
 *
 * `failed` 专门用来区分「请求失败」和「请求成功但上游就是没有数据」：
 * 前者不写 `unavailable`（否则一次网络抖动会让这个条目在本次运行内
 * 永远退化成「第 N 集」），后者才写。
 */
class EpisodeFetch {
  lines: EpisodeLine[] = [];
  failed: boolean = false;
  /** 选中的季（形如 `「时光代理人 第三季」/ 95 分 / season 105212`）；没选中留空。 */
  seasonLabel: string = '';
  /** 没拿到的原因（写进明细，给界面和用户回报用）。 */
  note: string = '';
}

/** 哔哩哔哩季搜索的结果（同样要区分失败与「确实没有」）。 */
class SeasonSearch {
  seasons: BiliSeason[] = [];
  failed: boolean = false;
}

/**
 * 分集标题：**Bangumi 打底 + 哔哩哔哩补洞**（用户 2026-09-18）。
 *
 * 两张表**并列**取，不是二选一（参照实现就是这么分的）：
 *   - Bangumi 名字：`episode_selection_panel.dart:146-181` 的 `_loadEpisodeNames`，
 *     `/v0/episodes` **分页拉全**（`limit=100 + offset`，不看 `total` 就短在半路），
 *     正片（`type === 0`）按 `sort` 排序后**用顺序下标 1…N 当集号**，
 *     `name_cn` 优先于 `name`，名字为空的集**占位不占标题**；
 *   - 哔哩哔哩名字：`episode_title_service.dart` 的 `resolve`，
 *     按番剧名搜索 → 给候选项打分（不到 60 分放弃）→ 拉季分集，
 *     `min(4, 集数)` 且 30% 以上才认；行渲染时
 *     `bangumiName.isNotEmpty ? bangumiName : bilibiliName`，也就是
 *     **Bangumi 优先、B 站只补 Bangumi 缺的集**。
 *   - 结果缓存在内存里，同一个条目不会重复请求。
 *
 * 与源码的两处**有意偏离**（都是为了真机上的实际失败，2026-09-18 实测）：
 *   1. 哔哩哔哩请求带 `buvid3`：不带会话 cookie 时搜索接口会被风控拦成
 *      `HTTP 412` + 一个 HTML 页（补上 cookie 后同一个请求 200 + `code 0`），
 *      参照实现走的是「先请求首页、吸收 Set-Cookie」，本工程的 `ApiResponse`
 *      不带响应头，所以改用 `/x/frontend/finger/spi` 的 `data.b_3`；
 *   2. 网络/风控类失败**不写** `unavailable`（源码是取不到就记死），
 *      否则一次抖动会让这个条目在本次运行内永远是「第 N 集」。
 */
export class EpisodeTitleService {
  /** 匹配分数门槛（`_minAcceptScore`）。 */
  /**
   * 季匹配的最低分。
   *
   * 从 60 降到 40 的由来（2026-09-20）：名字那一档最低就是「包含」= 40 分，
   * 也就是说 40 分的含义是「名字能对上、只是集数或年份差得多」。这种情况下
   * **照样值得把这一季的分集表拉下来看看**——真正的安全阀是后面
   * `pickForLocal()` 的覆盖率门槛（`min(4, 集数)` 且 ≥ 30%），
   * 它是拿**真实分集表**去比对的，比一个提前算死的前置分数可靠得多。
   * 名字完全对不上的季在 `scoreSeason` 里直接返回 0，根本进不来。
   */
  private static readonly MIN_SCORE: number = 40;
  /** 「强匹配」门槛：到了它就不再往下试别的关键词（见 `fromBilibili` 的注释）。 */
  private static readonly STRONG_SCORE: number = 60;

  /**
   * 拿哪些关键词去哔哩哔哩搜季（按顺序，去重）。
   *
   * 为什么不能只搜条目名（2026-09-20 实测条目 555710）：这个条目在 Bangumi 叫
   * 《时光代理人 第三季 Part 1》（原名《时光代理人Ⅲ Part One》），而哔哩哔哩那边
   * 就叫《时光代理人 第三季》——直接把带 `Part 1` 的名字丢给搜索接口，搜不到那一季，
   * 用户看到的就是「第 6/7 集没标题」。
   *
   * 所以按「原样 → 去掉分部后缀 → 只留基名」三档依次试：
   *   1. `时光代理人 第三季 Part 1`（原样）
   *   2. `时光代理人 第三季`（去掉 Part 1）
   *   3. `时光代理人`（再去掉季数）
   * 每档都真的搜一次，打分器挑最好的那个季；集数与开播年份负责把「哪一季」定下来。
   */
  private static keywordVariants(title: string, originTitle: string): string[] {
    const out: string[] = [];
    const push = (text: string): void => {
      const trimmed: string = text.trim();
      if (trimmed.length === 0) {
        return;
      }
      const key: string = EpisodeTitleService.normalize(trimmed);
      for (let i = 0; i < out.length; i++) {
        if (EpisodeTitleService.normalize(out[i]) === key) {
          return;
        }
      }
      out.push(trimmed);
    };
    const sources: string[] = [title, originTitle];
    for (let i = 0; i < sources.length; i++) {
      push(sources[i]);
    }
    for (let i = 0; i < sources.length; i++) {
      push(EpisodeTitleService.stripPartSuffix(sources[i]));
    }
    for (let i = 0; i < sources.length; i++) {
      push(EpisodeTitleService.stripSeasonSuffix(sources[i]));
    }
    return out;
  }

  /** 去掉「Part 1 / Part One / 第 2 部分 / (上)(下)」这类**分部**后缀。 */
  private static stripPartSuffix(input: string): string {
    return input
      .replace(/part\s*(?:\d+|[ivx]+|one|two|three|four|five)\b/gi, '')
      .replace(/第\s*[0-9一二三四五六七八九十]+\s*(?:部分|篇|章)/g, '')
      .replace(/[（(]\s*(?:上|下|前|后)\s*[）)]/g, '')
      .trim();
  }

  /** 再去掉「第 N 季 / 第 N 部 / Season N / 罗马数字季数」，只留基名。 */
  private static stripSeasonSuffix(input: string): string {
    return EpisodeTitleService.stripPartSuffix(input)
      .replace(/第\s*[0-9一二三四五六七八九十]+\s*(?:季|部|期|章)/g, '')
      .replace(/\bseason\s*\d+\b/gi, '')
      .replace(/[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ]/g, '')
      .trim();
  }
  private static readonly MAX_CACHE: number = 24;
  private static cache: Map<number, Map<number, string>> = new Map();
  private static unavailable: Set<number> = new Set();
  /**
   * 哔哩哔哩搜季结果的缓存：`标题|本线路集数` → 分集行（含 `cid`）。
   *
   * 集标题与弹幕兜底用的是**同一份数据**（同一季、同一批分集），但入口
   * 不同（`resolve` 在分集面板/播放页取标题时跑，弹幕兜底在播放页取弹幕时跑）。
   * 不缓存的话，同一条目会白白做两遍「搜索 + 拉季分集」——
   * 哔哩哔哩搜索是有风控的（无 cookie 直接 412），请求越少越稳。
   */
  private static biliFetchCache: Map<string, EpisodeFetch> = new Map();
  private static readonly MAX_BILI_FETCH: number = 6;

  /** 已有结果的条目；没有结果返回 undefined。 */
  static cached(bangumiId: number): Map<number, string> | undefined {
    return EpisodeTitleService.cache.get(bangumiId);
  }

  /** 是否已经确定拿不到（避免每次开目录都重试）。 */
  static isUnavailable(bangumiId: number): boolean {
    return EpisodeTitleService.unavailable.has(bangumiId);
  }

  /**
   * 忘掉某个条目的结果（缓存 + 「拿不到」标记）。
   *
   * 播放页目录里那行「集标题 x/y · 重试」按钮用它：第一次可能撞上风控/断网，
   * 用户点一下就能原地重来，不必退出应用（内存缓存在同一次运行里不会自己失效）。
   */
  static forget(bangumiId: number, refreshCookie: boolean = false): void {
    EpisodeTitleService.cache.delete(bangumiId);
    EpisodeTitleService.unavailable.delete(bangumiId);
    if (refreshCookie) {
      // 连哔哩哔哩的会话 cookie 一起丢掉：撞上风控时换一枚 `buvid3` 再试，
      // 比原样重放同一个请求有用得多
      EpisodeTitleService.biliCookieReady = false;
      EpisodeTitleService.biliCookie = '';
    }
  }

  /**
   * 最近一次解析的明细（给界面显示 / 用户回报用）。
   *
   * 「集标题 5/7」这种数字只说明**合并后**有多少条，说明不了是哪个源给的、
   * 另一个源为什么没给。用户 2026-09-20 报「显示 5/7」时，光看界面完全无法
   * 判断是「哔哩哔哩没匹配到季」还是「Bangumi 只有前 5 集有名字」。
   * 这里把两个源的条数、选中的季、以及失败原因都拼成一行。
   */
  private static report: string = '';

  static lastReport(): string {
    return EpisodeTitleService.report;
  }

  private static setReport(text: string): void {
    EpisodeTitleService.report = text;
    Logger.info('EpisodeTitle', `[集标题] 明细：${text}`);
  }

  /**
   * 哔哩哔哩「本地集号 → 分集 cid」。
   *
   * 弹幕兜底用：弹弹play 只收录到第 1216 集（《名侦探柯南》，实测
   * 2026-09-19），而哔哩哔哩那一季有 1272 集且每集都有弹幕；
   * 有了这张表，后段集数也能走哔哩哔哩拿弹幕。
   *
   * 拿不到（没匹配到季 / 请求失败 / 覆盖率不到门槛）返回空表——
   * 调用方按「这一集哔哩哔哩也没有」处理，不要编造。
   */
  static async bilibiliCids(title: string, originTitle: string,
    episodeCount: number, airDate: string = ''): Promise<Map<number, number>> {
    const cids: Map<number, number> = new Map();
    if (title.trim().length === 0 || episodeCount <= 0) {
      return cids;
    }
    const fetch: EpisodeFetch =
      await EpisodeTitleService.fromBilibili(title, originTitle, episodeCount,
        airDate);
    /**
     * 同样**不按线路集数截断**（与集标题表一个道理）：这张表是按条目缓存的，
     * 而 `episodeCount` 只是「当前这条线路有多少集」。柯南实测有 1272 集的
     * 正片线路、也有 381 集的另一条线路，按短的截断会让长线路后段拿不到弹幕。
     */
    let within: number = 0;
    for (let i = 0; i < fetch.lines.length; i++) {
      const line: EpisodeLine = fetch.lines[i];
      if (line.cid <= 0 || line.sort < 1) {
        continue;
      }
      if (!cids.has(line.sort)) {
        cids.set(line.sort, line.cid);
      }
      if (line.sort <= episodeCount) {
        within += 1;
      }
    }
    /**
     * 与集标题同一个门槛：至少 `min(4, 集数)` 条且覆盖率 ≥ 30%。
     * 挡住「按番剧名搜到另一部番」——那种表的集号也在 1…N 范围内，
     * 不设门槛就会把别人家的弹幕贴到这一集上。
     */
    if (!EpisodeTitleService.accept(within, episodeCount, 4, 0.3)) {
      hilog.info(DOMAIN, TAG,
        '哔哩哔哩弹幕映射不走（命中 %{public}d/%{public}d）',
        within, episodeCount);
      cids.clear();
    }
    return cids;
  }

  /**
   * 哔哩哔哩接口的公共请求头：桌面 UA + referer + 会话 cookie（`buvid3`）。
   *
   * 弹幕接口也需要这一套：没有 cookie 时搜索接口会被风控 412，
   * 弹幕接口目前宽松（实测不带 cookie 也能拿到 XML），但没必要赌它一直宽松。
   */
  static async bilibiliHeaders(forceRefreshCookie: boolean):
    Promise<Record<string, string>> {
    const headers: Record<string, string> = {};
    headers['user-agent'] = EpisodeTitleService.DESKTOP_UA;
    headers['referer'] = 'https://www.bilibili.com/';
    const cookie: string = await EpisodeTitleService.ensureBiliCookie(
      forceRefreshCookie);
    if (cookie.length > 0) {
      headers['cookie'] = cookie;
    }
    return headers;
  }

  /** 取某一条目的「集号 → 集标题」。失败返回空 Map（不抛异常）。 */
  static async resolve(bangumiId: number, title: string,
    originTitle: string, episodeCount: number,
    airDate: string = ''): Promise<Map<number, string>> {
    if (bangumiId <= 0 || episodeCount <= 0) {
      return new Map();
    }
    const hit: Map<number, string> | undefined =
      EpisodeTitleService.cache.get(bangumiId);
    if (hit !== undefined) {
      return hit;
    }
    if (EpisodeTitleService.unavailable.has(bangumiId)) {
      return new Map();
    }
    Logger.info('EpisodeTitle',
      `[集标题] 开始解析：条目 ${bangumiId} 本线路 ${episodeCount} 集`);

    // ---- 1) Bangumi 优先 ----
    const fromBgm: EpisodeFetch =
      await EpisodeTitleService.fromBangumi(bangumiId);
    /**
     * Bangumi 这一档**不卡 30% 覆盖率**（`1 / 0`）。
     *
     * 条目 id 是从条目本身来的、不是搜出来的，所以这张表就是可信的：
     * 参照实现的 Bangumi 名字（`_loadEpisodeNames`）同样一个门槛都没有，
     * 拿到几条用几条。一部 25 集的番如果本地线路有 100 集（合集/多季合并），
     * 按 30% 门槛会整条放弃，用户看到的就是「一条标题都没有」。
     */
    const bgmTitles: Map<number, string> | null =
      EpisodeTitleService.pickForLocal(fromBgm, episodeCount, 1, 0);

    /**
     * ---- 2) 哔哩哔哩**总是**再取一次：它只用来补 Bangumi 没填的集 ----
     *
     * 参照实现里这两步是**并列**的，不是二选一（`episode_selection_panel.dart`）：
     *   - `_loadEpisodeNames()` 拿 Bangumi 的名字，**然后无条件**调
     *     `_ensureBilibiliNames()`；
     *   - 行渲染时 `bangumiName.isNotEmpty ? bangumiName : bilibiliName`。
     * 所以 Bangumi 只有前 5 集有标题时（正在播的新番经常如此，实测 RE0
     * 第四季 夺还篇第 6–8 集的 `name_cn` / `name` 都是空），B 站那几集
     * 仍然补得进来。以前写成「Bangumi 命中就直接 return」，
     * 这几集就只能退化成「第 N 集」。
     */
    let biliTitles: Map<number, string> | null = null;
    let biliFailed: boolean = false;
    // 提到 if 外面：收尾的「明细」要用它写「哔哩哔哩为什么没给」
    let fromBili: EpisodeFetch = new EpisodeFetch();
    if (SettingsStore.getBool(SettingsKeys.episodeTitleBilibiliSource)) {
      fromBili = await EpisodeTitleService.fromBilibili(title, originTitle,
        episodeCount, airDate);
      biliFailed = fromBili.failed;
      // 哔哩哔哩是**搜出来的季**，可能整季就是另一部番：`min(4, 集数)` + 30%
      biliTitles = EpisodeTitleService.pickForLocal(fromBili, episodeCount, 4, 0.3);
    } else {
      fromBili.note = '开关已关闭';
    }

    /**
     * ---- 3) 合并：**哔哩哔哩优先**，Bangumi 补 B 站没有的集 ----
     *
     * ⚠️ 与参照实现**有意相反**（它渲染时是 `bangumiName.isNotEmpty ?
     * bangumiName : bilibiliName`）。原因是两边的集号口径不同——
     * 2026-09-19 实测《名侦探柯南》：
     *   - 哔哩哔哩 season 33378 的分集 `title` **就是播出集号**，1…1273 与本地
     *     线路逐号对齐（本地第 1273 集 = 「目击者毛利兰」✓）；
     *   - Bangumi 条目 899 只有 **1221** 条 `type=0` 正片，而本工程按**顺序
     *     下标**重编号成 1…1221，比播出集号少 52 条（数码重映之类的口径差异），
     *     于是过半之后整体错位：下标 100 是「初恋情人的回忆事件(上集)」，
     *     播出第 100 集却是「走投无路的名侦探」。
     * 让 Bangumi 覆盖 B 站，长番后半段就会串位、出现「前面的集名在后面又出现
     * 一遍」（用户 2026-09-19：「柯南最后面的集名和前面的重复」）。
     *
     * B 站那一路本来就有 `min(4, 集数)` + 覆盖率 ≥ 30% 的门槛；没搜到季
     * （`biliTitles === null`）时自动退回纯 Bangumi，与改之前完全一致。
     */
    const merged: Map<number, string> = new Map();
    if (bgmTitles !== null) {
      const bgmKeys = bgmTitles.keys();
      let step = bgmKeys.next();
      while (step.done !== true) {
        const key: number = step.value as number;
        const value: string | undefined = bgmTitles.get(key);
        if (value !== undefined) {
          merged.set(key, value);
        }
        step = bgmKeys.next();
      }
    }
    if (biliTitles !== null) {
      // 哔哩哔哩的值**后写**，也就是覆盖同名集号
      const biliKeys = biliTitles.keys();
      let step = biliKeys.next();
      while (step.done !== true) {
        const key: number = step.value as number;
        const value: string | undefined = biliTitles.get(key);
        if (value !== undefined) {
          merged.set(key, value);
        }
        step = biliKeys.next();
      }
    }
    if (merged.size > 0) {
      const bgmCount: number = bgmTitles === null ? 0 : bgmTitles.size;
      const biliCount: number = biliTitles === null ? 0 : biliTitles.size;
      hilog.info(DOMAIN, TAG,
        '集标题就绪 %{public}d 条（哔哩哔哩 %{public}d / Bangumi %{public}d）',
        merged.size, biliCount, bgmCount);
      Logger.info('EpisodeTitle',
        `[集标题] 合并结果 ${merged.size} 条（哔哩哔哩 ${biliCount} 打底，Bangumi ${bgmCount} 补洞）`);
      EpisodeTitleService.setReport(
        `条目 ${bangumiId}｜本线路 ${episodeCount} 集｜` +
          `哔哩哔哩 ${biliCount}（${fromBili.seasonLabel.length > 0
            ? fromBili.seasonLabel : (fromBili.note.length > 0
              ? fromBili.note : '未匹配')}）｜Bangumi ${bgmCount}` +
          `（${fromBgm.note.length > 0 ? fromBgm.note
            : (fromBgm.lines.length > 0 ? `${fromBgm.lines.length} 条` : '无分集')}）` +
          `｜合并 ${merged.size}`);
      EpisodeTitleService.remember(bangumiId, merged);
      return merged;
    }
    EpisodeTitleService.setReport(
      `条目 ${bangumiId}｜本线路 ${episodeCount} 集｜哔哩哔哩 ${fromBili.note.length > 0
        ? fromBili.note : `无可用集`}｜Bangumi ${fromBgm.lines.length > 0
        ? `有分集但名字为空` : '无分集'}｜合并 0`);
    EpisodeTitleService.markUnavailableIfDefinite(bangumiId,
      fromBgm.failed || biliFailed);
    return new Map();
  }

  /**
   * 只有**两个源都确实回答过「没有」**时才记「拿不到」。
   *
   * 网络类失败不写这个标记：以前写死之后，一次风控/断网就会让这个条目
   * 在本次运行内永远是「第 N 集」，切集、切线路、重进播放页都不再重试。
   */
  private static markUnavailableIfDefinite(bangumiId: number,
    anyFailed: boolean): void {
    if (anyFailed) {
      hilog.info(DOMAIN, TAG, '集标题请求失败，不写死缓存，下次还会重试');
      return;
    }
    EpisodeTitleService.unavailable.add(bangumiId);
    hilog.info(DOMAIN, TAG, '两个源都没有可用集标题，退化成第N集');
  }

  /**
   * 把上游的分集表对齐到**本地集号**；够用返回可直接查表的 Map，否则 null。
   *
   * ⚠️ **这里不再看 Bangumi 的 `sort`**：`fromBangumi` 已经按「正片排序后的
   * 顺序下标」重编号成 1…N 了（参照实现 `episode_selection_panel.dart`
   * 的 `_loadEpisodeNames` 就是这么建的：`names[episodeIndex++] = name`）。
   * 之前的实现按 `sort` 建表、发现对不上再整体前移，方向本身就错了——
   * RE0 第四季两篇的 `sort` 是 67…77 / 78…85，前移能不能生效还要看
   * 「这一季集数是否 ≥ 本线路集数的一半」，条件一不满足就整季没标题。
   *
   * 门槛（`minCount` / `ratio`）由调用方给，与源码一一对应：
   *   - Bangumi 表：源码不设门槛（拿到就用），这里取 `1 / 0`；
   *   - 哔哩哔哩表：`min(4, 集数)` 且 30% 以上，用来挡住「搜到另一部番」。
   */
  private static pickForLocal(fetch: EpisodeFetch, episodeCount: number,
    minCount: number, ratio: number): Map<number, string> | null {
    if (fetch.lines.length === 0) {
      return null;
    }
    const titles: Map<number, string> = EpisodeTitleService.compile(fetch);
    /**
     * 门槛只看**本线路集数范围内**覆盖了多少集，但**返回的表不截断**。
     *
     * 为什么不截断（用户 2026-09-19：「名侦探柯南较后的集名加载不出来了」）：
     * 这张表按**条目 id** 缓存、整个播放页只建一次，而 `episodeCount` 是
     * **打开播放页时那条线路**的集数。同一个条目的不同线路集数可以差很多
     * （实测柯南：1272 集的正片线路 vs 381 集的另一条线路），
     * 一旦先落在短线路上，按它截断的表就只剩前 381 条，
     * 之后切到长线路 / 看后面的集数时，382 集往后一条标题都没有。
     */
    const within: number =
      EpisodeTitleService.coveredWithin(titles, episodeCount);
    if (!EpisodeTitleService.accept(within, episodeCount, minCount, ratio)) {
      EpisodeTitleService.logPick('放弃', fetch, within, episodeCount, false);
      return null;
    }
    EpisodeTitleService.logPick('采用', fetch, within, episodeCount, true);
    return titles;
  }

  /**
   * 按本地集号建表（本地集号 = `line.sort`，由各自的 `fromXxx` 保证）。
   *
   * **不做集数截断**（原因见 `pickForLocal`）：表跟着条目走，
   * 不是跟着某一条线路走。
   */
  private static compile(fetch: EpisodeFetch): Map<number, string> {
    const out: Map<number, string> = new Map();
    for (let i = 0; i < fetch.lines.length; i++) {
      const line: EpisodeLine = fetch.lines[i];
      // 上游某些集还没标题（正在播的新番很常见）：占位但不出标题
      if (line.name.length === 0) {
        continue;
      }
      const local: number = line.sort;
      if (local >= 1 && !out.has(local)) {
        out.set(local, line.name);
      }
    }
    return out;
  }

  /**
   * 表里「本地集号 ≤ 本线路集数」的条数（门槛与日志用）。
   *
   * 表本身**不再按线路集数截断**，所以「能用多少条」要单独数一次：
   * 播放页用它写「覆盖 x / 本线路 y 集」，服务层用它做 30% 覆盖率门槛。
   */
  static coveredWithin(titles: Map<number, string>,
    episodeCount: number): number {
    let count: number = 0;
    titles.forEach((_value: string, key: number) => {
      if (key >= 1 && key <= episodeCount) {
        count += 1;
      }
    });
    return count;
  }

  /**
   * 把这次匹配的**全部数字**写进应用日志（日志页可读）。
   *
   * 「集标题为什么不显示」以前完全靠猜：接口返回了几条、集号范围是多少、
   * 命中了几条、用的是原样还是前移，界面上一个都看不到。这一行把
   * 它们一次性摊开，出问题直接看「我的 → 日志」即可。
   */
  private static logPick(mode: string, fetch: EpisodeFetch, covered: number,
    episodeCount: number, accepted: boolean): void {
    let minSort: number = 0;
    let maxSort: number = 0;
    for (let i = 0; i < fetch.lines.length; i++) {
      const sort: number = fetch.lines[i].sort;
      if (sort <= 0) {
        continue;
      }
      if (minSort === 0 || sort < minSort) {
        minSort = sort;
      }
      if (sort > maxSort) {
        maxSort = sort;
      }
    }
    const text: string = `[集标题] ${mode}：上游 ${fetch.lines.length} 条` +
      `（本地集号 ${minSort}..${maxSort}）命中 ${covered}/${episodeCount}` +
      `${accepted ? '' : ' → 不达标'}` +
      `${fetch.failed ? '（有请求失败）' : ''}`;
    hilog.info(DOMAIN, TAG, '%{public}s', text);
    Logger.info('EpisodeTitle', text);
  }

  /**
   * 够不够用：至少 `minCount` 条，且覆盖率不低于 `ratio`。
   *
   * 与源码一一对应：Bangumi 表 `1 / 0`（拿到就用），
   * 哔哩哔哩表 `min(4, 集数) / 0.3`（挡住「搜到另一部番」）。
   */
  private static accept(covered: number, episodeCount: number,
    minCount: number, ratio: number): boolean {
    const floor: number = Math.min(minCount, episodeCount);
    if (covered < floor) {
      return false;
    }
    return ratio <= 0 ? true : covered >= episodeCount * ratio;
  }

  private static remember(bangumiId: number, names: Map<number, string>): void {
    EpisodeTitleService.cache.set(bangumiId, names);
    while (EpisodeTitleService.cache.size > EpisodeTitleService.MAX_CACHE) {
      const first: number | undefined =
        EpisodeTitleService.cache.keys().next().value;
      if (first === undefined) {
        break;
      }
      EpisodeTitleService.cache.delete(first);
    }
  }

  /**
   * Bangumi `/v0/episodes` → 本地集号（1…N）→ `name_cn || name`。
   *
   * ⚠️ **必须分页拉全**：接口不传 `limit` 时只返回 100 条
   * （实测《名侦探柯南》`total = 1340`、默认只给 100），
   * 长番会因此永远凑不满 30% 覆盖率，整表退化成「第 N 集」。
   *
   * ⚠️ **按顺序下标建表，不用 `sort` 当集号**。参照实现
   * `episode_selection_panel.dart:146-181` 就是这么做的：
   * ```
   * final mainEpisodes = episodes.where((e) => e.type == 0).toList()..sort(...);
   * final source = mainEpisodes.isNotEmpty ? mainEpisodes : episodes...;
   * var episodeIndex = 1;
   * for (final episode in source) { names[episodeIndex] = name; episodeIndex++; }
   * ```
   * 为什么不能用 `sort`：Bangumi 的续作是**接着上一季连续编号**的，
   * RE0 第二季 `sort = 26…38`、第三季 55…66、第四季 67…77 / 78…85，
   * 而本地线路永远是 1…N。以前按 `sort` 建表 + 整体前移，能不能出标题
   * 取决于「前移条件」是否凑巧满足，所以会出现「第二季有、第四季没有」。
   * 用顺序下标则任何编号形态都能对齐（真机 2026-09-18：RE0 第四季不显示）。
   *
   * 非正片（SP / OP / ED）仍然要排除，但**全是非正片时退回用全部条目**
   * ——这条也与源码一致（它的 `source` 就是这么一个二选一）。
   */
  private static async fromBangumi(bangumiId: number):
    Promise<EpisodeFetch> {
    const fetch = new EpisodeFetch();
    try {
      const data: Object[] | null =
        await BangumiApi.getAllBangumiEpisodesByID(bangumiId);
      if (data === null) {
        fetch.failed = true;
        hilog.warn(DOMAIN, TAG, 'Bangumi 集标题请求失败');
        return fetch;
      }
      const all: EpisodeLine[] = [];
      const main: EpisodeLine[] = [];
      for (let i = 0; i < data.length; i++) {
        const rec: Record<string, Object> | null =
          EpisodeTitleService.obj(data[i]);
        if (rec === null) {
          continue;
        }
        const sort: number = EpisodeTitleService.num(rec['sort']);
        /**
         * **正片优先**（`type === 0`）。
         *
         * 真机反馈（用户 2026-09-18：「集数的标题错了」）：`/v0/episodes`
         * 同一份响应里除了正片，还会有 SP / OP / ED 之类的条目，它们也带着
         * 自己的 `sort`。不区分就会把正片标题覆盖掉——《葬送的芙莉莲》出现过
         * 第 1 集显示成 `Anytime Anywhere (ver. 1)`、第 3 集显示成特别版。
         */
        const type: number = EpisodeTitleService.num(rec['type']);
        const cn: string = EpisodeTitleService.str(rec['name_cn']).trim();
        const raw: string = EpisodeTitleService.str(rec['name']).trim();
        const name: string = cn.length > 0 ? cn : raw;
        /**
         * **名字为空的集也要占位**（名字留空即可，位置不能丢）。
         *
         * 参照实现里 `episodeIndex++` 是无条件的：
         * ```
         * for (final episode in source) {
         *   if (name.isNotEmpty) names[episodeIndex] = name;
         *   episodeIndex++;
         * }
         * ```
         * 正在播的新番经常只有前几集有标题（实测 RE0 第四季 夺还篇第 6–8 集
         * 的 `name_cn` / `name` 都是空），这里若直接 `continue`，
         * 后面所有集号都会**整体前移**，标题就串位了。
         */
        const line = new EpisodeLine();
        line.sort = sort;
        line.name = name;
        all.push(line);
        if (type === 0) {
          main.push(line);
        }
      }
      const source: EpisodeLine[] = main.length > 0 ? main : all;
      source.sort((a: EpisodeLine, b: EpisodeLine) => a.sort - b.sort);
      // 重编号成 1…N：这才是本地集号
      for (let i = 0; i < source.length; i++) {
        const line = new EpisodeLine();
        line.sort = i + 1;
        line.name = source[i].name;
        fetch.lines.push(line);
      }
      if (main.length === 0 && all.length > 0) {
        Logger.info('EpisodeTitle',
          `[集标题] 条目 ${bangumiId} 没有 type=0 的正片，退回用全部 ${all.length} 条`);
      }
    } catch (error) {
      const err = error as Error;
      fetch.failed = true;
      hilog.warn(DOMAIN, TAG, 'Bangumi 集标题失败: %{public}s', err.message);
    }
    return fetch;
  }

  /**
   * 哔哩哔哩兜底：搜索 → 打分挑季 → 拉分集标题（顺带留下每集的 `cid`）。
   *
   * ## 拿什么名字去搜（用户 2026-09-19 问过这条）
   *
   * **不是**用视频源（规则）里的名字——播放页顶部显示的「名侦探柯南日语版」
   * 是**源的名字**，跟这里的搜索无关（用户明确要求不要用它，2026-09-19）。
   * 关键词只有两个，按顺序试：
   *   1. `title` —— 条目中文名（`BangumiItem.displayName()`：`nameCn` 优先）；
   *   2. `originTitle` —— 条目原名（`BangumiItem.name`，日文原名那种）；
   * 后者只有在前者搜不到够格的季时才会用到（参照实现也是这两个）。
   *
   * 每个关键词只要有一个季能到 `MIN_SCORE`，就不再往下试（与参照实现一致）；
   * 用的是**哪个关键词、选中了哪一季**都会写进日志，出问题不用猜。
   *
   * 结果按 `中文名|原名|集数` 缓存（只缓存**成功**的），这样集标题与
   * 弹幕兜底两条链路合起来也只做一次「搜索 + 拉季分集」。
   */
  private static async fromBilibili(title: string, originTitle: string,
    episodeCount: number, airDate: string = ''): Promise<EpisodeFetch> {
    const cacheKey: string =
      `${title.trim()}|${originTitle.trim()}|${episodeCount}|${airDate.trim()}`;
    const expectedYear: number = EpisodeTitleService.yearOfAirDate(airDate);
    const cached: EpisodeFetch | undefined =
      EpisodeTitleService.biliFetchCache.get(cacheKey);
    if (cached !== undefined) {
      hilog.info(DOMAIN, TAG, '哔哩哔哩分集表命中缓存（%{public}d 条）',
        cached.lines.length);
      return cached;
    }
    const fetch = new EpisodeFetch();
    const keywords: string[] = EpisodeTitleService.keywordVariants(title, originTitle);

    let bestScore: number = 0;
    let best: BiliSeason | null = null;
    /** 命中的那个关键词（写日志用）。 */
    let bestKeyword: string = '';
    /** 有任意一次搜索是**失败**（风控 / 网络）而不是「确实没有结果」。 */
    let searchFailed: boolean = false;
    for (let i = 0; i < keywords.length; i++) {
      const search: SeasonSearch =
        await EpisodeTitleService.searchSeasons(keywords[i]);
      if (search.failed) {
        searchFailed = true;
      }
      const seasons: BiliSeason[] = search.seasons;
      for (let j = 0; j < seasons.length; j++) {
        const score: number = EpisodeTitleService.scoreSeason(
          keywords[i], seasons[j], episodeCount, expectedYear);
        if (score > bestScore) {
          bestScore = score;
          best = seasons[j];
          bestKeyword = keywords[i];
        }
      }
      // 第一个关键词就能匹配上就不再拿译名搜一遍（与源码一致）
      /**
       * 提前收工的门槛比最终门槛高：**只有强匹配（≥60）才停**。
       *
       * 2026-09-20 实测（条目 555710《时光代理人 第三季 Part 1》）：拿
       * 「…Part 1」这个名字去搜，B 站只回得到一个 30 分的弱匹配；如果按
       * `MIN_SCORE`（40）就停，我们会错过后面用**清洗过的关键词**搜出来的
       * 那个 95 分的正确答案。多打一两次搜索接口（有缓存、不贵）比贴错标题划算。
       */
      if (bestScore >= EpisodeTitleService.STRONG_SCORE) {
        break;
      }
    }

    if (best === null || bestScore < EpisodeTitleService.MIN_SCORE) {
      fetch.failed = searchFailed;
      fetch.note = searchFailed
        ? '搜索失败（风控/网络）' : `没匹配到季（最高 ${bestScore} 分）`;
      const tried: string = keywords.join(' / ');
      hilog.info(DOMAIN, TAG,
        '哔哩哔哩没有够格的季（best=%{public}d，搜索失败=%{public}s，试过：%{public}s）',
        bestScore, `${searchFailed}`, tried);
      Logger.info('EpisodeTitle',
        `[集标题] 哔哩哔哩没有够格的季（最高 ${bestScore} 分，试过：${tried}）`);
      return fetch;
    }
    hilog.info(DOMAIN, TAG,
      '哔哩哔哩选季：关键词「%{public}s」→ season %{public}d「%{public}s」' +
        '（%{public}d 分 / %{public}d 集）',
      bestKeyword, best.seasonId, best.title, bestScore, best.episodeCount);
    Logger.info('EpisodeTitle',
      `[集标题] 哔哩哔哩选季：关键词「${bestKeyword}」→ season ${best.seasonId}` +
        `「${best.title}」（${bestScore} 分 / ${best.episodeCount} 集）`);
    const season: EpisodeFetch =
      await EpisodeTitleService.seasonTitles(best.seasonId);
    if (season.failed) {
      fetch.failed = true;
      fetch.note = `季 ${best.seasonId} 分集请求失败`;
      hilog.info(DOMAIN, TAG, '季 %{public}d 分集请求失败', best.seasonId);
      return fetch;
    }
    fetch.lines = season.lines;
    fetch.seasonLabel =
      `「${best.title}」/ ${bestScore} 分 / season ${best.seasonId}`;
    EpisodeTitleService.rememberBiliFetch(cacheKey, fetch);
    return fetch;
  }

  /** 记住一次性搜季结果（容量小、先到先出；失败的结果不进来）。 */
  private static rememberBiliFetch(key: string, fetch: EpisodeFetch): void {
    EpisodeTitleService.biliFetchCache.set(key, fetch);
    while (EpisodeTitleService.biliFetchCache.size >
      EpisodeTitleService.MAX_BILI_FETCH) {
      const first: string | undefined =
        EpisodeTitleService.biliFetchCache.keys().next().value;
      if (first === undefined) {
        break;
      }
      EpisodeTitleService.biliFetchCache.delete(first);
    }
  }

  /** `x/web-interface/search/type`：按番剧名搜季。 */
  private static async searchSeasons(keyword: string): Promise<SeasonSearch> {
    const out = new SeasonSearch();
    if (keyword.length === 0) {
      return out;
    }
    /**
     * **两个类目都要搜**：番剧（`media_bangumi`）+ 影视（`media_ft`）。
     *
     * 剧场版 / 电影在哔哩哔哩的分类是「影视」，只搜番剧会整部找不到
     * （实测《通往夏天的隧道，再见的出口》：`media_ft` → season 99556，
     * `media_bangumi` → 0 条）。两条搜索结果直接合并，交给同一个打分器挑，
     * 名字对不上/集数差太多照样会被 `MIN_SCORE` 挡掉。
     */
    const searchPaths: string[] = [
      ApiEndpoints.bilibiliSearchBangumi,
      ApiEndpoints.bilibiliSearchMovie
    ];
    for (let t = 0; t < searchPaths.length; t++) {
      const found: SeasonSearch =
        await EpisodeTitleService.searchSeasonsByType(keyword, searchPaths[t]);
      if (found.failed) {
        out.failed = true;
      }
      for (let i = 0; i < found.seasons.length; i++) {
        out.seasons.push(found.seasons[i]);
      }
    }
    if (out.seasons.length > 0) {
      out.failed = false;
    }
    return out;
  }

  /** 单个类目的搜索（`searchSeasons` 的一趟）。 */
  private static async searchSeasonsByType(keyword: string,
    path: string): Promise<SeasonSearch> {
    const out = new SeasonSearch();
    const url: string = ApiEndpoints.bilibiliAPIDomain +
      ApiEndpoints.formatUrl(path, [encodeURIComponent(keyword)]);
    /**
     * 最多两轮，**第二轮强制换一份新 cookie**。
     *
     * 哔哩哔哩的风控有两种形态：HTTP 412（`getJson` 里已经会换 cookie 重试）
     * 和 **HTTP 200 + `code: -412`**。后者以前直接判失败就算了，
     * 于是「集标题有时候出不来」（用户 2026-09-19）——它其实换一份 cookie
     * 就能过。这里两种都覆盖：`code !== 0` 也走换 cookie 再试一次。
     *
     * `code !== 0` 一律当**失败**（不能当「确实没有」）：否则会被写成
     * `unavailable`，本次运行内再也不重试。
     */
    let json: Record<string, Object> | null = null;
    for (let attempt = 0; attempt < 2; attempt++) {
      json = await EpisodeTitleService.getJson(url, attempt > 0);
      if (json === null) {
        out.failed = true;
        continue;
      }
      const code: number = EpisodeTitleService.num(json['code']);
      if (code !== 0) {
        out.failed = true;
        hilog.warn(DOMAIN, TAG,
          '哔哩哔哩搜索返回 code=%{public}d（第 %{public}d 次）',
          code, attempt + 1);
        continue;
      }
      out.failed = false;
      break;
    }
    if (json === null) {
      return out;
    }
    if (EpisodeTitleService.num(json['code']) !== 0) {
      return out;
    }
    const data: Record<string, Object> | null =
      EpisodeTitleService.obj(json['data']);
    if (data === null) {
      return out;
    }
    const result: Object[] = EpisodeTitleService.arr(data, 'result');
    for (let i = 0; i < result.length; i++) {
      const rec: Record<string, Object> | null =
        EpisodeTitleService.obj(result[i]);
      if (rec === null) {
        continue;
      }
      const seasonId: number = EpisodeTitleService.num(rec['season_id']);
      if (seasonId <= 0) {
        continue;
      }
      const season = new BiliSeason();
      season.seasonId = seasonId;
      season.title = EpisodeTitleService.stripHtml(
        EpisodeTitleService.str(rec['title']));
      season.episodeCount = EpisodeTitleService.num(rec['ep_size']);
      season.publishSeconds = EpisodeTitleService.num(rec['pubtime']);
      out.seasons.push(season);
    }
    return out;
  }

  /** `pgc/view/web/season`：拉某一季的全部分集标题（集号 → 标题）。 */
  private static async seasonTitles(seasonId: number):
    Promise<EpisodeFetch> {
    const fetch = new EpisodeFetch();
    if (seasonId <= 0) {
      return fetch;
    }
    const url: string = ApiEndpoints.bilibiliAPIDomain +
      ApiEndpoints.formatUrl(ApiEndpoints.bilibiliSeasonDetail, [`${seasonId}`]);
    const json: Record<string, Object> | null =
      await EpisodeTitleService.getJson(url);
    if (json === null) {
      fetch.failed = true;
      return fetch;
    }
    if (EpisodeTitleService.num(json['code']) !== 0) {
      fetch.failed = true;
      return fetch;
    }
    const result: Record<string, Object> | null =
      EpisodeTitleService.obj(json['result']);
    if (result === null) {
      fetch.failed = true;
      return fetch;
    }

    const raw: Object[] = [];
    EpisodeTitleService.collect(raw, result['episodes']);
    const main: Record<string, Object> | null =
      EpisodeTitleService.obj(result['main_section']);
    if (main !== null) {
      EpisodeTitleService.collect(raw, main['episodes']);
    }
    /**
     * ⚠️ **不再收集 `section`**（OP / 预告花絮 / 时光留影 那一类分区）。
     *
     * 它们在哔哩哔哩的语义是「正片之外的附加内容」，`share_copy` 也看不出规律
     * （实测《时光代理人 第三季》的「时光留影」分区里是 21 条宣传短片），
     * 混进来会把集号映射整段带偏：模拟跑出来本地第 8 集变成了
     * 「旋律响起，时光重逢！」这种宣传片标题。正片只在 `episodes`
     * 与 `main_section.episodes` 里，取这两处足够。
     */

    /**
     * 集号能不能用：**整季一个数字集号都没有**时才退化成「按返回顺序当 1…N」。
     *
     * 实测到的两种形态：
     *   - 番剧季：`title` 就是集号（柯南 "1"…"1273"），中间混着几条非数字的
     *     `SP`（位置 1115 / 1152 / 1191）——这些**跳过就好，不能因此整季改用序号**
     *     （跳过的条目不多，但序号会让后面每一集都错位 3 位）；
     *   - 影视季：`title` 是「原版」「中文版」（《通往夏天的隧道，再见的出口》
     *     season 99556），一个数字都没有 → 这时才按顺序当 1…N
     *     （与 Bangumi 那条「按顺序下标」的路子一致，取第 1 集正好是原版）。
     *
     * 另外，预告/花絮条目（认 `share_copy`）在下面先被剔掉：实测
     * 《时光代理人 第三季》第 7 集有两条（一条「第7集预告」、一条正片）、
     * 第 8 集干脆只有「第8集预告」——原来「重复的直接丢」会让**正片那一条**
     * 被预告顶掉，后两集既没标题、弹幕还会取到预告的（用户 2026-09-19）。
     */
    let numericCount: number = 0;
    for (let i = 0; i < raw.length; i++) {
      const rec: Record<string, Object> | null =
        EpisodeTitleService.obj(raw[i]);
      if (rec === null) {
        continue;
      }
      const share: string = EpisodeTitleService.stripHtml(
        EpisodeTitleService.str(rec['share_copy']));
      if (EpisodeTitleService.looksLikeExtra(share)) {
        continue;
      }
      const probe: number =
        Number.parseInt(EpisodeTitleService.str(rec['title']).trim(), 10);
      if (!Number.isNaN(probe) && probe > 0) {
        numericCount += 1;
      }
    }
    const ordinalFallback: boolean = numericCount === 0;
    if (ordinalFallback && raw.length > 0) {
      hilog.info(DOMAIN, TAG,
        '哔哩哔哩季 %{public}d 的集号不可用（非数字或有重复），按返回顺序当 1…%{public}d',
        seasonId, raw.length);
    }

    /** 预告/花絮/PV 不是正片：标题和弹幕都不该拿它们顶替。 */
    let ordinal: number = 0;
    for (let i = 0; i < raw.length; i++) {
      const rec: Record<string, Object> | null =
        EpisodeTitleService.obj(raw[i]);
      if (rec === null) {
        continue;
      }
      const share: string =
        EpisodeTitleService.stripHtml(EpisodeTitleService.str(rec['share_copy']));
      if (EpisodeTitleService.looksLikeExtra(share)) {
        continue;
      }
      ordinal += 1;
      // `title` 字段是集号字符串（不是标题）；标题在 `long_title` / `share_copy`
      let number: number =
        Number.parseInt(EpisodeTitleService.str(rec['title']).trim(), 10);
      if (Number.isNaN(number) || number <= 0) {
        if (!ordinalFallback) {
          continue;
        }
        number = ordinal;
      }
      if (ordinalFallback) {
        number = ordinal;
      }
      const long: string = EpisodeTitleService.str(rec['long_title']).trim();
      const title: string = long.length > 0
        ? long
        : EpisodeTitleService.stripHtml(
          EpisodeTitleService.str(rec['share_copy'])).trim();
      /**
       * `cid` 一并留下：它既是「这一集在哔哩哔哩的弹幕 id」，也是
       * `BilibiliDanmakuApi` 取弹幕的唯一入参。
       *
       * ⚠️ **不能用 `id`（ep_id）顶替**：弹幕接口 `list.so?oid=` 要的是
       * `cid`，拿 ep_id 去查只会静默返回空 XML（看起来又是「这一集没弹幕」）。
       * 实测柯南整季 1275 条分集全都有 `cid`，取不到就留 0、后面按 0 过滤。
       */
      const cid: number = EpisodeTitleService.num(rec['cid']);
      if (title.length > 0) {
        const line = new EpisodeLine();
        line.sort = number;
        line.name = title;
        line.cid = cid;
        fetch.lines.push(line);
      } else if (cid > 0) {
        // 没标题但有分集 id：**不能丢**，弹幕兜底还要按集号找它
        const line = new EpisodeLine();
        line.sort = number;
        line.name = '';
        line.cid = cid;
        fetch.lines.push(line);
      }
    }
    return fetch;
  }

  private static collect(target: Object[], value: Object | undefined): void {
    if (value === undefined || !Array.isArray(value)) {
      return;
    }
    const list: Object[] = value as Object[];
    for (let i = 0; i < list.length; i++) {
      target.push(list[i]);
    }
  }

  /**
   * 是不是「不是正片」的那类条目（预告 / 花絮 / PV / CM / 特报）。
   *
   * 判据用 `share_copy`（哔哩哔哩自己写的那句分享文案），实测很稳定：
   * 《时光代理人 第三季》里同一个集号出现两次，一次是
   * `《时光代理人 第三季》第7集预告`、一次是 `第7话 唐人街探案`；
   * 第 8 集则只有 `第8集预告`（`long_title` 为空）。这类条目**带 cid**，
   * 不剔除就会「用预告的弹幕冒充正片」并把正片那条挤掉。
   */
  private static looksLikeExtra(share: string): boolean {
    if (share.length === 0) {
      return false;
    }
    const lower: string = share.toLowerCase();
    const markers: string[] = ['预告', '花絮', '特报', '资讯', 'pv', 'cm'];
    for (let i = 0; i < markers.length; i++) {
      if (lower.includes(markers[i])) {
        return true;
      }
    }
    return false;
  }

  /** 哔哩哔哩会话 cookie（`buvid3=…`）；空串表示没取到。 */
  private static biliCookie: string = '';
  private static biliCookieReady: boolean = false;

  /**
   * 取一次 `buvid3`（`/x/frontend/finger/spi` 的 `data.b_3`）。
   *
   * **必须带**：不带会话 cookie 时搜索接口会被风控拦成 `HTTP 412` 并返回
   * 一个 HTML 页（实测「从零开始的异世界生活」连续两次都是 412，补上
   * `buvid3` 后立刻是 200 + `code 0`）。以前只加 UA / referer，
   * 所以兜底链在真机上经常整条断掉。
   *
   * 用这个 JSON 接口而不是「先请求首页读 Set-Cookie」：本工程的
   * `ApiResponse` 不带响应头，拿不到 `Set-Cookie`，而这个接口把同一个值
   * 放在 body 里。
   */
  private static async ensureBiliCookie(forceRefresh: boolean):
    Promise<string> {
    if (EpisodeTitleService.biliCookieReady && !forceRefresh) {
      return EpisodeTitleService.biliCookie;
    }
    EpisodeTitleService.biliCookieReady = true;
    EpisodeTitleService.biliCookie = '';
    const headers: Record<string, string> = {};
    headers['user-agent'] = EpisodeTitleService.DESKTOP_UA;
    headers['referer'] = 'https://www.bilibili.com/';
    try {
      const res: ApiResponse = await ApiClient.apiDio().request(
        ApiEndpoints.bilibiliAPIDomain + ApiEndpoints.bilibiliFingerSpi,
        http.RequestMethod.GET, undefined, headers);
      if (!res.ok || res.body.length === 0) {
        hilog.warn(DOMAIN, TAG, '取 buvid3 失败：HTTP %{public}d',
          res.statusCode);
        return '';
      }
      const json: Record<string, Object> | null =
        EpisodeTitleService.obj(JSON.parse(res.body) as Object);
      const data: Record<string, Object> | null =
        json === null ? null : EpisodeTitleService.obj(json['data']);
      const token: string = data === null ? ''
        : EpisodeTitleService.str(data['b_3']).trim();
      if (token.length > 0) {
        EpisodeTitleService.biliCookie = `buvid3=${token}`;
        hilog.info(DOMAIN, TAG, '已取到哔哩哔哩 buvid3');
      }
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '取 buvid3 异常: %{public}s', err.message);
    }
    return EpisodeTitleService.biliCookie;
  }

  /** 桌面 UA：带 cookie 后哔哩哔哩不再按「匿名」风控。 */
  private static readonly DESKTOP_UA: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  /**
   * 带桌面 UA / referer / `buvid3` 的 GET。
   *
   * 风控类状态码（403 / 412）会**换一份新 cookie 重试一次**——
   * 真机上这几种失败是偶发的，直接放弃就等于「这次没标题」。
   *
   * 2026-09-22 补：**连接层失败**（`statusCode === 0`，DNS / 连不上 / TLS 失败）
   * 也要重试。这天实测本网络**连接失败是交替性的**——同一秒连发两次，一次
   * `Failed to connect … after 16 ms`、下一次 200 正常返回。原来只对 403/412
   * 重试，于是「弹幕只能用哔哩哔哩兜底」的时代里，一次抖动就等于
   * 「哔哩哔哩没有匹配到这一季」（用户 2026-09-22 报的「弹幕不可用」就叠了
   * 弹弹play 403 + 这条抖动）。现在总共 3 次尝试，连接失败之间隔 250/500ms。
   */
  private static async getJson(url: string,
    forceFreshCookie: boolean = false):
    Promise<Record<string, Object> | null> {
    for (let attempt = 0; attempt < 3; attempt++) {
      const headers: Record<string, string> =
        await EpisodeTitleService.bilibiliHeaders(forceFreshCookie || attempt > 0);
      try {
        const res: ApiResponse = await ApiClient.apiDio()
          .request(url, http.RequestMethod.GET, undefined, headers);
        if (res.ok && res.body.length > 0) {
          const parsed: Object = JSON.parse(res.body) as Object;
          return EpisodeTitleService.obj(parsed);
        }
        hilog.warn(DOMAIN, TAG, '哔哩哔哩返回 HTTP %{public}d（第 %{public}d 次）',
          res.statusCode, attempt + 1);
        if (attempt < 2) {
          // 风控：下一轮会带一份新 cookie
          if (res.statusCode === 412 || res.statusCode === 403) {
            continue;
          }
          // 连接层失败：隔一拍再来（交替性抖动，重试一次多半就好了）
          if (res.statusCode === 0) {
            await EpisodeTitleService.pause(250 * (attempt + 1));
            continue;
          }
        }
        return null;
      } catch (error) {
        const err = error as Error;
        hilog.warn(DOMAIN, TAG, '哔哩哔哩请求失败: %{public}s', err.message);
        if (attempt < 2) {
          await EpisodeTitleService.pause(250 * (attempt + 1));
          continue;
        }
        return null;
      }
    }
    return null;
  }

  /** 重试之间的短暂等待（不占用事件循环的忙等）。 */
  private static async pause(ms: number): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /** 季匹配打分（`_scoreSeason`）。 */
  private static scoreSeason(keyword: string, season: BiliSeason,
    expectedEpisodes: number, expectedYear: number = 0): number {
    const key: string = EpisodeTitleService.normalize(keyword);
    const title: string = EpisodeTitleService.normalize(season.title);
    if (key.length === 0 || title.length === 0) {
      return 0;
    }
    /**
     * 名字分档。
     *
     * ⚠️ 与参照实现相比**压平了一档**（原来完全相同 +100、包含 +45）。
     * 原因是「同名多季」的场景（2026-09-20 实测《时光代理人》第三季）：
     *   - 第一季的标题与条目名**一字不差** → 老规则 +100；
     *   - 第三季的标题是条目名 + 后缀 → 老规则只有 +45；
     * 55 分的差距**不是集数能补回来的**（集数满分才 +30），于是选了第一季、
     * 把第一季的集名贴到了第三季上。
     * 现在名字分差只有 20 分，剩下的交给「集数对不对得上」和「开播年份」，
     * 这两项才是判断「本地这条线路到底是哪一季」的真正依据。
     */
    let score: number = 0;
    if (title === key) {
      score += 60;
    } else if (EpisodeTitleService.normalize(
      EpisodeTitleService.stripDubMarkers(season.title)) ===
      EpisodeTitleService.normalize(
        EpisodeTitleService.stripDubMarkers(keyword))) {
      score += 50;
    } else if (title.includes(key) || key.includes(title)) {
      score += 40;
    } else {
      // 名字都对不上就别往下算了，宁可没有标题
      return 0;
    }

    if (season.episodeCount > 0) {
      const diff: number = Math.abs(season.episodeCount - expectedEpisodes);
      const tight: number = Math.max(2, Math.round(expectedEpisodes * 0.02));
      const loose: number = Math.max(12, Math.round(expectedEpisodes * 0.1));
      if (diff === 0) {
        score += 60;
      } else if (diff <= tight) {
        score += 35;
      } else if (diff <= loose) {
        score += 10;
      } else {
        // 集数差得很远：扣分但**不致命**——本地线路可能是「多季合并」的一条
        // （集数远大于单季），那不是「搜到另一部番」，只是分母不一样。
        // 真正的把关交给后面的覆盖率门槛。
        score -= 10;
      }
    } else {
      score -= 5;
    }
    /**
     * 开播年份：**同名多季的最终判据**。
     *
     * 条目的开播时间来自 Bangumi（`BangumiItem.airDate`），季的来自搜索结果
     * 的 `pubtime`。同年 +20、差一年 +10、差三年以上 -20。
     * 实测《时光代理人》：条目 2026-04-11，第一季 2021 / 第二季 2023 /
     * 英都篇 2024 / 第三季 2026 —— 只有第三季同年。
     */
    if (expectedYear > 0) {
      const seasonYear: number = EpisodeTitleService.yearOf(season.publishSeconds);
      if (seasonYear > 0) {
        const gap: number = Math.abs(seasonYear - expectedYear);
        if (gap === 0) {
          score += 20;
        } else if (gap <= 1) {
          score += 10;
        } else if (gap >= 3) {
          score -= 20;
        }
      }
    }
    if (EpisodeTitleService.looksDubbed(season.title) !==
      EpisodeTitleService.looksDubbed(keyword)) {
      score -= 25;
    }
    return score;
  }

  /** 秒级时间戳 → 年份；0/异常返回 0。 */
  private static yearOf(seconds: number): number {
    if (seconds <= 0) {
      return 0;
    }
    return new Date(seconds * 1000).getFullYear();
  }

  /**
   * `BangumiItem.airDate`（形如 `2026-04-11`）→ 年份；取不到返回 0。
   */
  static yearOfAirDate(airDate: string): number {
    const text: string = airDate.trim();
    if (text.length < 4) {
      return 0;
    }
    const year: number = Number.parseInt(text.substring(0, 4), 10);
    return Number.isNaN(year) || year < 1900 ? 0 : year;
  }

  private static readonly DUB_MARKERS: string[] = [
    '中配', '国语', '中文配音', '普通话', '台配', '粤配', '日语', '日配', '原声'
  ];

  private static stripDubMarkers(input: string): string {
    let out: string = input;
    for (let i = 0; i < EpisodeTitleService.DUB_MARKERS.length; i++) {
      out = out.replace(EpisodeTitleService.DUB_MARKERS[i], '');
    }
    return out;
  }

  private static looksDubbed(input: string): boolean {
    return input.includes('中配') || input.includes('国语') ||
      input.includes('中文配音') || input.includes('普通话') ||
      input.includes('台配') || input.includes('粤配');
  }

  /** 归一化：去 HTML、全角转半角、只留数字/字母/汉字。 */
  private static normalize(input: string): string {
    const plain: string = EpisodeTitleService.stripHtml(input).toLowerCase();
    let out: string = '';
    for (let i = 0; i < plain.length; i++) {
      const code: number = plain.charCodeAt(i);
      const ch: string = (code >= 0xFF01 && code <= 0xFF5E)
        ? String.fromCharCode(code - 0xFEE0) : plain.charAt(i);
      if (/[0-9a-z\u4e00-\u9fff]/.test(ch)) {
        out += ch;
      }
    }
    return out;
  }

  /** 搜索结果里的标题带 `<em class="keyword">` 高亮标签，去掉它们。 */
  private static stripHtml(input: string): string {
    if (input.length === 0) {
      return '';
    }
    return input.replace(/<[^>]*>/g, '')
      .replace(/&quot;/g, '"').replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&#39;/g, "'").trim();
  }

  private static obj(value: Object | undefined | null):
    Record<string, Object> | null {
    if (value === undefined || value === null || typeof value !== 'object' ||
      Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }

  private static arr(value: Object | null, key: string): Object[] {
    const rec: Record<string, Object> | null = EpisodeTitleService.obj(value);
    if (rec === null) {
      return [];
    }
    const inner: Object | undefined = rec[key];
    if (inner === undefined || !Array.isArray(inner)) {
      return [];
    }
    return inner as Object[];
  }

  private static num(value: Object | undefined): number {
    if (value === undefined) {
      return 0;
    }
    const parsed: number = Number.parseFloat(`${value}`);
    return Number.isNaN(parsed) ? 0 : parsed;
  }

  private static str(value: Object | undefined): string {
    return value === undefined ? '' : `${value}`;
  }
}
