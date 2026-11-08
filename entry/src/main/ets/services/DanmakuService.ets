import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { DanmakuEntry, DanmakuEpisode, DanmakuEpisodeResponse,
  DanmakuSearchAnime, mergeDuplicateDanmakus } from '../model/DanmakuModels';
import { BilibiliDanmakuApi } from './BilibiliDanmakuApi';
import { DanmakuApi } from './DanmakuApi';
import { DanmakuCredentials } from './DanmakuCredentials';
import { DanmakuShieldStore } from './DanmakuShieldStore';
import { Logger } from './Logger';
import { SettingsKeys } from './storage/SettingsKeys';
import { SettingsStore } from './storage/SettingsStore';
import { EpisodeTitleService } from './metadata/EpisodeTitleService';

const TAG: string = 'AutumnDanmaku';

/** 一次取弹幕的结果。 */
export class DanmakuLoadResult {
  /** 最终要渲染的弹幕（已按来源 / 屏蔽 / 去重处理）。 */
  entries: DanmakuEntry[] = [];
  /** 弹弹play 的番剧 id（0 表示没匹配到）。 */
  danDanId: number = 0;
  /** 是否来自本地缓存。 */
  fromCache: boolean = false;
  /** 失败原因（空串表示成功；成功但没有弹幕也算成功）。 */
  error: string = '';
}

/**
 * 哔哩哔哩兜底需要的上下文。
 *
 * 弹弹play 对长番的收录是**截断**的（柯南只到第 1216 集），要靠
 * 「按番剧名搜哔哩哔哩的季」才能把后段集数接上，而搜季要的是**名字**，
 * 弹幕服务手里只有 Bangumi 条目 id，所以由调用方（播放页）带进来。
 */
export class DanmakuBiliContext {
  /** 首选名（`BangumiItem.displayName()`：中文名优先）。 */
  title: string = '';
  /** 原名（搜不到首选名时再搜一次）。 */
  originTitle: string = '';
  /** 本线路集数（用来挡住「搜到另一部番」）。 */
  episodeCount: number = 0;
  /**
   * 条目开播日期（`BangumiItem.airDate`，形如 `2026-04-11`）。
   *
   * 同名多季时用来选对季（见 `EpisodeTitleService.scoreSeason` 的年份项）：
   * 实测《时光代理人》四个季都在搜索结果里，只靠名字与集数选中了**第一季**，
   * 于是把第一季的集名/弹幕贴到了第三季上。
   */
  airDate: string = '';
}

/** 哔哩哔哩兜底的一次结果。 */
class BiliFallback {
  entries: DanmakuEntry[] = [];
  /** 给用户看的补充说明（空串 = 不需要补充）。 */
  message: string = '';
}

/** 弹弹play 的一次结果。 */
class DanDanFallback {
  entries: DanmakuEntry[] = [];
  /** 给用户看的补充说明（空串 = 不需要补充）。 */
  message: string = '';
  /** 匹配到的弹弹play 番剧 id（0 = 没匹配上），写回 `DanmakuLoadResult` 用。 */
  danDanId: number = 0;
}

/**
 * 一季的分集表：本地集号 → 上游 `episodeId`。
 *
 * 为什么要存两张表：弹弹play 的 `episodeNumber` **不一定是本季的 1、2、3**。
 * 实测《葬送的芙莉莲 第二季》（bgm 515759 → 弹弹play 18886）里它的分集是
 * **29–38**——跨季连续编号；而播放页传进来的本地集号是 1–10。
 * 只按数字对，1–10 全都查不到，表现就是「这部番匹配不到弹幕」（2026-10-31）。
 *
 * 所以：
 *   - `byNumber`：按上游集号精确对（大多数番都是 1、2、3，这条永远优先）；
 *   - `byOrdinal`：**仅当上游集号不是从 1 开始时**才建，按集号排序后的第 N 条
 *     对应本地第 N 集——正好是跨季连续编号那种情况。
 *
 * 不建 `byOrdinal` 是有意的：分集表里有缺集时（缺第 500 集），按序号对会把
 * 第 500 集对到第 501 集上，那比没有弹幕更糟。
 */
class DanmakuEpisodeTable {
  private readonly byNumber: Map<number, number> = new Map();
  private readonly byOrdinal: Map<number, number> = new Map();
  private maxNumber: number = 0;

  /** 登记一条（同一集号只认第一次，与原来的 `if (!table.has(number))` 一致）。 */
  add(number: number, id: number): void {
    if (!this.byNumber.has(number)) {
      this.byNumber.set(number, id);
    }
  }

  /** 收尾：集号不从 1 开始时补一张序号表。 */
  finish(): void {
    const numbers: number[] = [];
    this.byNumber.forEach((_value: number, key: number) => {
      numbers.push(key);
    });
    numbers.sort((a: number, b: number) => a - b);
    if (numbers.length === 0) {
      return;
    }
    this.maxNumber = numbers[numbers.length - 1];
    if (numbers[0] > 1) {
      for (let i = 0; i < numbers.length; i++) {
        const id: number | undefined = this.byNumber.get(numbers[i]);
        if (id !== undefined) {
          this.byOrdinal.set(i + 1, id);
        }
      }
    }
  }

  /** 表里一共多少集。 */
  get size(): number {
    return this.byNumber.size;
  }

  /** 分集表里最大的上游集号（只用于「只收录到第 N 集」这类提示）。 */
  get maxEpisode(): number {
    return this.maxNumber;
  }

  /** 本地集号 → episodeId；-1 = 这张表里没有这一集。 */
  idFor(episode: number): number {
    const direct: number | undefined = this.byNumber.get(episode);
    if (direct !== undefined) {
      return direct;
    }
    const ordinal: number | undefined = this.byOrdinal.get(episode);
    return ordinal === undefined ? -1 : ordinal;
  }
}

/**
 * 弹幕服务：取弹幕 + 来源过滤 + 屏蔽规则 + 去重 + 本地缓存。
 *
 * 对应参照实现里分散在几处的逻辑：
 *   - 取弹幕：`player_danmaku_controller.dart` 的 `fetchDanmaku`
 *   - 来源过滤：`player_item.dart` 的 `_isDanmakuSourceEnabled`
 *   - 屏蔽：`MyController.isDanmakuBlocked`
 *   - 去重：`utils/danmaku.dart` 的 `mergeDuplicateDanmakus`
 *   - 缓存：下载设置里的「缓存弹幕」（§18.2 `_writeDanmakuToFile`）
 *
 * **与参照实现的一处有意扩展**：弹弹play 对长番的收录是截断的
 * （柯南只到第 1216 集），所以弹弹play 没有这一集时会再走一次
 * **哔哩哔哩**（`BilibiliDanmakuApi`）。这条链路是参照实现没有的，
 * 见 `load()` 里第 3 步。
 *
 * 缓存路径：`${filesDir}/danmaku/cache/{规则名}-{条目 id}-{集数}.json`。
 * 离线播放（下载管理器落地后）优先读它；在线播放失败时也回落读它，
 * 这样看完一集再断网重看仍然有弹幕。
 */
export class DanmakuService {
  private static dir: string = '';
  /** 番剧 id → 分集表（本地集号 → 上游 episodeId）。同一个番剧只拉一次。 */
  private static episodeIdCache: Map<number, DanmakuEpisodeTable> =
    new Map();
  private static readonly MAX_EPISODE_CACHE: number = 16;
  /**
   * 「弹弹play 给得太少」的阈值。
   *
   * 低于它就去哔哩哔哩再问一次，**谁多听谁的**（见 `load` 第 3 步的注释：
   * 实测《通往夏天的隧道，再见的出口》弹弹play 345 条 / 哔哩哔哩 9600 条）。
   */
  private static readonly BILI_TOPUP_THRESHOLD: number = 500;

  /**
   * 「按名字搜到的弹弹play 条目」最低要多少分才敢用（见 `titleScore`）。
   *
   * 取 90 = **完全相同，或去掉「第 N 季 / 第 N 部 / Season N / Part N」后相同**。
   * 刻意**不**收「一方包含另一方」那一档（60）：那会把
   * 「名侦探柯南 → 名侦探柯南 警察学校篇」「进击的巨人 → 进击的巨人 最终季」
   * 这种**另一部作品**认进来，弹幕直接挂错番——比没有弹幕更糟。
   * 这一档只是「bgm 映射没命中」时的补救，漏掉的仍由哔哩哔哩兜底。
   */
  private static readonly SEARCH_MIN_SCORE: number = 90;

  /**
   * 弹幕缓存的**结构版本**：换了取源顺序 / 解析口径就 +1，旧缓存自然失效。
   *
   * 2026-09-24：取源顺序从「哔哩哔哩优先」恢复成「**弹弹play 优先**」。
   * 不换版本的话，之前那两天看过的集会在缓存里命中**哔哩哔哩**的弹幕，
   * 用户会以为改动没生效（而且缓存没有 TTL，`readCache` 命中就直接返回）。
   */
  private static readonly CACHE_SCHEMA: string = 'v2';

  static init(context: common.UIAbilityContext): void {
    DanmakuService.dir = `${context.filesDir}/danmaku/cache`;
    if (!fileIo.accessSync(DanmakuService.dir)) {
      fileIo.mkdirSync(DanmakuService.dir, true);
    }
    DanmakuService.dropLegacyCache();
  }

  /**
   * 清掉**旧结构版本**的弹幕缓存文件（只在本目录内动手）。
   *
   * 旧文件装的是上一个取源顺序下的弹幕，现在既不会被读到、又白占空间
   * （一集的弹幕 JSON 常常上百 KB，几百集就是几十 MB）。
   * 删掉不丢东西：重新播一集会按新顺序重新拉取并写回。
   */
  private static dropLegacyCache(): void {
    if (DanmakuService.dir.length === 0) {
      return;
    }
    try {
      const names: string[] = fileIo.listFileSync(DanmakuService.dir);
      const prefix: string = `${DanmakuService.CACHE_SCHEMA}-`;
      let removed: number = 0;
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (!name.endsWith('.json') || name.startsWith(prefix)) {
          continue;
        }
        try {
          fileIo.unlinkSync(`${DanmakuService.dir}/${name}`);
          removed += 1;
        } catch (e) {
          // 单个文件删不掉就跳过，不影响其它
        }
      }
      if (removed > 0) {
        Logger.info(TAG, `清理旧版弹幕缓存 ${removed} 个文件`);
      }
    } catch (e) {
      // 目录不可读就跳过（下次启动再试）
    }
  }

  /**
   * 取一集的弹幕。
   *
   * @param bgmId Bangumi 条目 id（就是详情页/播放页手上的 `BangumiItem.id`）
   * @param episode 集数（从 1 开始）
   * @param bili 哔哩哔哩兜底的上下文（名字 + 本线路集数）；不知道就传空对象，
   *   此时不会去哔哩哔哩兜底
   *
   * 链路是**两级**的，2026-09-24 过审后的顺序是：
   *   1. 弹弹play（按 Bangumi 条目 id 精确映射 → 分集 → 弹幕）；
   *   2. 弹弹play 没给到 / 给得太少（< 500 条）→ 哔哩哔哩补量，谁多听谁的。
   *
   * 中间有过一段反复：9-22 弹弹play 未过审、匿名请求整条 403，临时把哔哩哔哩
   * 提到前面；9-24 过审后凭据生效，恢复成弹弹play 优先（理由见下面第 2 步）。
   */
  static async load(pluginName: string, bgmId: number,
    episode: number, bili: DanmakuBiliContext): Promise<DanmakuLoadResult> {
    const result = new DanmakuLoadResult();
    // 1. 先看缓存
    const cached: DanmakuEntry[] =
      DanmakuService.readCache(pluginName, bgmId, episode);
    if (cached.length > 0) {
      result.entries = DanmakuService.applyFilters(cached);
      result.fromCache = true;
      Logger.info(TAG, `命中弹幕缓存：${cached.length} 条`);
      return result;
    }

    /**
     * 2. **弹弹play 优先**（2026-09-24 恢复；9-22～9-23 曾临时改成哔哩哔哩优先）。
     *
     * 那两天调顺序是因为弹弹play 的未授权请求整条 403（§35 / §39）；
     * **2026-09-24 应用过审、凭据生效**，两种鉴权模式实测都 200（§41），
     * 于是恢复本来的顺序：
     *
     *   - 弹弹play 用的是 `/bangumi/bgmtv/{bgmId}` 映射，**按 Bangumi 条目 id 精确对应**，
     *     不需要像哔哩哔哩那样靠名字猜季（名字猜错 = 弹幕挂错番）；
     *   - 它收录的长番也更全（柯南到 1216 集那种）。
     *
     * 前提是**配了 AppId**（官方要求应用凭证，见 §36）。没配就跳过这一路，
     * 直接交给哔哩哔哩——注意那趟请求在没凭据时必然是 403，白等一次往返，
     * 所以这里干脆不请求、只记一条日志与理由。
     */
    let raw: DanmakuEntry[] = [];
    /** 弹弹play 侧的失败原因（空串 = 没失败，只是这一集真没弹幕）。 */
    let reason: string = '';
    const danDanOn: boolean =
      SettingsStore.getBool(SettingsKeys.danmakuDanDanSource);
    if (danDanOn && DanmakuCredentials.usable()) {
      const dan: DanDanFallback =
        await DanmakuService.loadFromDanDan(bgmId, episode, bili.title);
      result.danDanId = dan.danDanId;
      raw = dan.entries;
      reason = dan.message;
    } else if (danDanOn) {
      reason = '弹弹play 凭据不可用，已跳过';
      Logger.warn(TAG, '弹弹play 凭据不可用（内置凭据缺失，或自定义凭据只填了一半），跳过该来源');
    }

    /**
     * 3. 哔哩哔哩补量/兜底；**弹弹play 没给到或给得太少**才问一次，谁多听谁的。
     *
     * 阈值取 500（`BILI_TOPUP_THRESHOLD`）：低于它的结果都值得再问一次，
     * 问完**比大小**，绝不会因为这条路把弹弹play 更全的集合换成更少的。
     * 实测《通往夏天的隧道，再见的出口》：弹弹play 345 条 / 哔哩哔哩 9600 条，
     * 这条兜底就是为它留的。
     *
     * 关掉「BiliBili」来源开关时 `loadFromBilibili` 直接返回空（既不请求也不提示）。
     */
    let biliReason: string = '';
    if (raw.length < DanmakuService.BILI_TOPUP_THRESHOLD) {
      const biliFallback: BiliFallback =
        await DanmakuService.loadFromBilibili(bili, episode);
      biliReason = biliFallback.message;
      if (biliFallback.entries.length > raw.length) {
        if (raw.length > 0) {
          Logger.info(TAG,
            `哔哩哔哩补量：弹弹play ${raw.length} 条 → 哔哩哔哩 ${biliFallback.entries.length} 条`);
        }
        raw = biliFallback.entries;
        reason = '';
      }
    }

    if (raw.length === 0) {
      /**
       * 两边都没取到：**把能办事的那条理由放在前面**。
       *
       * 弹弹play 是首选来源，它的理由先给（「没有匹配到该条目」/「只收录到第 N 集」），
       * 哔哩哔哩的（「没有匹配到这一季」/「这一季只到第 N 集」）跟在后面。
       */
      result.error = reason.length > 0
        ? (biliReason.length > 0 ? `${reason}；${biliReason}` : reason)
        : biliReason;
      return result;
    }
    DanmakuService.writeCache(pluginName, bgmId, episode, raw);
    result.entries = DanmakuService.applyFilters(raw);
    return result;
  }

  /**
   * 已知 B站 `cid` 时直接取弹幕。
   *
   * 两个入口共用：
   *   - B站普通投稿源本身（每个分 P 天生就带 cid）；
   *   - 播放页里的「从 B站链接匹配」。
   *
   * 仍然遵守「BiliBili」来源开关、屏蔽与去重设置，并使用独立缓存键，
   * 不会把用户手动匹配的弹幕写进其它番剧的缓存。
   */
  static async loadByBiliCid(pluginName: string, bgmId: number, episode: number,
    cid: number): Promise<DanmakuLoadResult> {
    const result = new DanmakuLoadResult();
    if (cid <= 0) {
      result.error = '链接没有对应有效的 B站 cid';
      return result;
    }
    if (!SettingsStore.getBool(SettingsKeys.danmakuBiliBiliSource)) {
      result.error = 'B站弹幕来源已关闭，请在弹幕设置中开启 BiliBili';
      return result;
    }
    const cached: DanmakuEntry[] =
      DanmakuService.readCache(pluginName, bgmId, episode);
    if (cached.length > 0) {
      result.entries = DanmakuService.applyFilters(cached);
      result.fromCache = true;
      return result;
    }
    const entries: DanmakuEntry[] = await BilibiliDanmakuApi.danmakuByCid(cid);
    if (entries.length === 0) {
      result.error = '这个 B站分 P 没有弹幕';
      return result;
    }
    DanmakuService.writeCache(pluginName, bgmId, episode, entries);
    result.entries = DanmakuService.applyFilters(entries);
    return result;
  }

  /**
   * 弹弹play 取一集的弹幕（原来内联在 `load()` 第 2 步里，2026-09-22 抽出来）。
   *
   * 调用方只在「哔哩哔哩没给到 / 给得太少」且用户开着「弹弹play」来源时才进来。
   * 失败信息统一收进 `fallback.message`，**不要**抛给上层——上层要拿它跟
   * 哔哩哔哩的原因拼给用户看。
   */
  private static async loadFromDanDan(bgmId: number,
    episode: number, title: string): Promise<DanDanFallback> {
    const fallback = new DanDanFallback();
    try {
      let danDanId: number = await DanmakuApi.bangumiIdByBgmId(bgmId);
      /**
       * 映射没命中 → **用剧名搜一次**（新版搜索引擎，`?v2=true`）。
       *
       * 2026-07-13 弹弹play 上线了新版搜索引擎（`search/anime|episodes|adv`
       * 传 `v2=true`），官方说分词与质量都更好，正好用来补这个缺口：
       * `/bangumi/bgmtv/{id}` 只覆盖**它自己收录过**的条目，没收录的一律返回 0，
       * 用户看到的就是「弹弹play 没有匹配到该条目」（然后全靠哔哩哔哩兜底）。
       *
       * ⚠️ 名字不像就**不要**认（`SEARCH_MIN_SCORE`）：弹幕带错番比没有更糟。
       */
      if (danDanId === 0) {
        danDanId = await DanmakuService.searchDanDanIdByTitle(title);
      }
      fallback.danDanId = danDanId;
      if (danDanId === 0) {
        fallback.message = '弹弹play 没有匹配到该条目';
        Logger.warn(TAG, `弹弹play 未匹配到条目 ${bgmId}`);
      } else {
        /**
         * **优先用真实 episodeId 取弹幕**。
         *
         * 原来直接拼 `/comment/{番剧id}{4位集号}`（上游注释也说这条规则是推测）。
         * 它在普通集上恰好成立，但上游的分集编号并不总是从 1 连续排
         * （实测 RE0 第二季里有 `episodeNumber = "C2"`、`episodeId = 147929102`），
         * 一旦本地集号和上游口径不一致，整集就会静默没有弹幕——
         * 表现就是「有时候加载不出来」。分集表本来就是既有接口
         * （`DanmakuApi.episodes`），查表比猜更可靠；查不到再退回拼 id。
         */
        const episodeId: number =
          await DanmakuService.episodeIdOf(danDanId, episode);
        /**
         * `-1` = 分集表**取到了、但里面真的没有这一集**（例如《名侦探柯南》：
         * 弹弹play 的分集表到集号 1216 为止，再往后连搜索接口都查不到）。
         * 这种情况**不要**再去猜 `/comment/{番剧id}{4位集号}`——那个拼法本身就不对
         * （真实规则是 `animeId × 1000 + 集号`，例如 2661100），猜出来必然 404。
         * 记下原因，交给第 3 步的哔哩哔哩兜底。
         */
        if (episodeId < 0) {
          const covered: number = DanmakuService.coveredEpisodes(danDanId);
          fallback.message = covered > 0
            ? `弹弹play 该条目只收录到第 ${covered} 集`
            : '弹弹play 没有这一集的弹幕源';
          Logger.warn(TAG,
            `第 ${episode} 集超出弹弹play 覆盖范围（到第 ${covered} 集）`);
        } else {
          fallback.entries = episodeId > 0
            ? await DanmakuApi.danmakuByEpisodeId(episodeId)
            : await DanmakuApi.danmaku(danDanId, episode);
          Logger.info(TAG,
            `取到弹幕 ${fallback.entries.length} 条（弹弹play id=${danDanId}` +
              `${episodeId > 0 ? ` episodeId=${episodeId}` : ' 用拼 id 兜底'}）`);
        }
      }
    } catch (error) {
      const err = error as Error;
      /**
       * 裸状态码翻成人话。
       *
       * `DanmakuApi.getJson` 失败时抛的是 `HTTP 403` 这种字符串，直接显示给用户
       * 等于没说（用户 2026-09-22 的原话就是「一直显示弹幕不可用，403？」）。
       * 403 在弹弹play 这里几乎只有一个含义：没带 AppId 的匿名请求被拒。
       */
      /**
       * 403 分两种，提示要分开——不然用户不知道该去申请凭据还是去查审核。
       *
       * 2026-09-23 实测（拿真凭据打主机探针）：**应用没过审**时，
       * 签名模式与凭证模式**都是 403**，和匿名请求长得一模一样（403 + 0 字节）。
       * 所以有凭据还 403，八成是「审核还没通过」或「密钥不对」。
       */
      const hasCredential: boolean = SettingsStore
        .getString(SettingsKeys.danmakuDanDanAppId).trim().length > 0;
      if (err.message.indexOf('403') >= 0) {
        fallback.message = hasCredential
          ? '弹弹play 拒绝访问（403）：凭据可能还在审核中'
          : '弹弹play 需要 AppId，匿名请求已被拒（403）';
      } else {
        fallback.message = `弹弹play 取弹幕失败：${err.message}`;
      }
      Logger.error(TAG, `取弹幕失败：${err.message}`);
    }
    return fallback;
  }

  /**
   * 用剧名搜弹弹play，返回足够像的那一条的 `animeId`（0 = 没找到像的）。
   *
   * 走的是官方 2026-07-13 上线的新版搜索引擎（`?v2=true`，见 `DanmakuApi.searchAnime`）。
   * 门槛见 `SEARCH_MIN_SCORE`：宁可返回 0、让哔哩哔哩兜底，也不要挂错番的弹幕。
   */
  private static async searchDanDanIdByTitle(title: string): Promise<number> {
    const trimmed: string = title.trim();
    if (trimmed.length < 2) {
      return 0;
    }
    try {
      const candidates: DanmakuSearchAnime[] =
        await DanmakuApi.searchAnime(trimmed);
      let bestId: number = 0;
      let bestScore: number = 0;
      let bestTitle: string = '';
      for (let i = 0; i < candidates.length; i++) {
        const score: number =
          DanmakuService.titleScore(trimmed, candidates[i].animeTitle);
        if (score > bestScore) {
          bestScore = score;
          bestId = candidates[i].animeId;
          bestTitle = candidates[i].animeTitle;
        }
      }
      if (bestScore >= DanmakuService.SEARCH_MIN_SCORE && bestId > 0) {
        Logger.info(TAG,
          `弹弹play 按名字搜到条目：${bestId}「${bestTitle}」（得分 ${bestScore}）`);
        return bestId;
      }
      Logger.warn(TAG,
        `弹弹play 搜索没有够像的条目（共 ${candidates.length} 条，最高 ${bestScore} 分）`);
    } catch (error) {
      const err = error as Error;
      Logger.warn(TAG, `弹弹play 搜索失败：${err.message}`);
    }
    return 0;
  }

  /**
   * 标题相似度打分（0–100）。
   *
   * 只做三档，够用且不会误判：
   *   - 归一化后完全相同 → 100；
   *   - 去掉「第 N 季 / 第 N 部 / Season N / Part N」后相同 → 90
   *     （多季作品两边写法经常不一致）；
   *   - 一方包含另一方 → 60。
   * 其它一律 0，交给调用方的门槛拦掉。
   */
  private static titleScore(query: string, candidate: string): number {
    const a: string = DanmakuService.normalizeTitle(query);
    const b: string = DanmakuService.normalizeTitle(candidate);
    if (a.length === 0 || b.length === 0) {
      return 0;
    }
    if (a === b) {
      return 100;
    }
    const a2: string = DanmakuService.stripSeason(a);
    const b2: string = DanmakuService.stripSeason(b);
    if (a2.length > 0 && a2 === b2) {
      return 90;
    }
    if (b.indexOf(a) >= 0 || a.indexOf(b) >= 0) {
      return 60;
    }
    if (a2.length > 1 && b2.length > 1 &&
      (b2.indexOf(a2) >= 0 || a2.indexOf(b2) >= 0)) {
      return 55;
    }
    return 0;
  }

  /** 归一化：转小写 + 只留字母/数字/汉字/假名（去掉空格与各种符号）。 */
  private static normalizeTitle(input: string): string {
    const lower: string = input.toLowerCase();
    let out: string = '';
    for (let i = 0; i < lower.length; i++) {
      const code: number = lower.charCodeAt(i);
      const keep: boolean =
        (code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x7a) ||
          (code >= 0x4e00 && code <= 0x9fff) || (code >= 0x3040 && code <= 0x30ff);
      if (keep) {
        out += lower.charAt(i);
      }
    }
    return out;
  }

  /** 去掉季/部/Part 这类后缀，用于「多季写法不一致」的第二档比较。 */
  private static stripSeason(input: string): string {
    return input
      .replace(/第[0-9一二三四五六七八九十]+季/g, '')
      .replace(/第[0-9一二三四五六七八九十]+部/g, '')
      .replace(/season[0-9]+/g, '')
      .replace(/part[0-9]+/g, '')
      .replace(/[0-9]+(st|nd|rd|th)season/g, '');
  }

  /**
   * 哔哩哔哩兜底：条目名 → 季 → 分集 cid → 弹幕。
   *
   * 全部条件都满足才会真的发请求：
   *   - 调用方给了名字与本线路集数（播放页给的是 `displayName()` / 原名 / 集数）；
   *   - 用户在弹幕设置里**开着**「BiliBili」来源。关了这个开关还去请求，
   *     既浪费流量，也会让用户以为「关了还在偷偷用」。
   */
  private static async loadFromBilibili(bili: DanmakuBiliContext,
    episode: number): Promise<BiliFallback> {
    const fallback = new BiliFallback();
    if (!SettingsStore.getBool(SettingsKeys.danmakuBiliBiliSource)) {
      return fallback;
    }
    if (bili.title.trim().length === 0 || bili.episodeCount <= 0) {
      return fallback;
    }
    try {
      const cids: Map<number, number> = await EpisodeTitleService.bilibiliCids(
        bili.title, bili.originTitle, bili.episodeCount, bili.airDate);
      const cid: number | undefined = cids.get(episode);
      if (cid === undefined || cid <= 0) {
        let last: number = 0;
        cids.forEach((_value: number, key: number) => {
          if (key > last) {
            last = key;
          }
        });
        fallback.message = last > 0
          ? `哔哩哔哩这一季只到第 ${last} 集`
          : '哔哩哔哩没有匹配到这一季';
        Logger.warn(TAG,
          `哔哩哔哩没有第 ${episode} 集的映射（共 ${cids.size} 集可用）`);
        return fallback;
      }
      fallback.entries = await BilibiliDanmakuApi.danmakuByCid(cid);
      if (fallback.entries.length === 0) {
        fallback.message = '哔哩哔哩这一集也没有弹幕';
      }
      return fallback;
    } catch (error) {
      const err = error as Error;
      fallback.message = `哔哩哔哩取弹幕失败：${err.message}`;
      Logger.warn(TAG, `哔哩哔哩兜底失败：${err.message}`);
      return fallback;
    }
  }

  /**
   * 本地集号 → 上游 `episodeId`。
   *
   * 返回值有三种含义（调用方按它分流）：
   *   - `> 0`：拿到真实 episodeId，直接按 id 取弹幕；
   *   - `0`：**分集表没拿到**（网络失败等）→ 调用方退回「拼 id」的旧兜底；
   *   - `-1`：分集表拿到了、但里面**确实没有这一集** → 上游没有这一集的弹幕，
   *     不要再发请求（见 `load()` 里的注释：柯南 1217 集之后就是这种）。
   *
   * 分集表按番剧缓存在内存里：一集查一次就够，切集不会重复请求；
   * 拉表失败**不写缓存**，下次还会重试。
   */
  private static async episodeIdOf(danDanId: number,
    episode: number): Promise<number> {
    const hit: DanmakuEpisodeTable | undefined =
      DanmakuService.episodeIdCache.get(danDanId);
    if (hit !== undefined) {
      return hit.idFor(episode);
    }
    const table: DanmakuEpisodeTable = new DanmakuEpisodeTable();
    try {
      const response: DanmakuEpisodeResponse =
        await DanmakuApi.episodes(danDanId);
      for (let i = 0; i < response.episodes.length; i++) {
        const item: DanmakuEpisode = response.episodes[i];
        // `episodeNumber` 是字符串，特典那种 "C2"/"SP1" 解析不出来就跳过
        const number: number = Number.parseInt(item.episodeNumber.trim(), 10);
        if (Number.isNaN(number) || number <= 0 || item.episodeId <= 0) {
          continue;
        }
        table.add(number, item.episodeId);
      }
      table.finish();
    } catch (error) {
      const err = error as Error;
      Logger.warn(TAG, `分集表获取失败，退回拼 id：${err.message}`);
      return 0;
    }
    if (table.size === 0) {
      Logger.warn(TAG, `番剧 ${danDanId} 的分集表为空，退回拼 id`);
      return 0;
    }
    DanmakuService.episodeIdCache.set(danDanId, table);
    DanmakuService.trimEpisodeCache();
    return table.idFor(episode);
  }

  /**
   * 该条目在弹弹play 覆盖到第几集（分集表里的最大数值集号；没查到返回 0）。
   *
   * 只用于给用户一句人话说明（「只收录到第 N 集」），不做业务判断。
   */
  private static coveredEpisodes(danDanId: number): number {
    const table: DanmakuEpisodeTable | undefined =
      DanmakuService.episodeIdCache.get(danDanId);
    return table === undefined ? 0 : table.maxEpisode;
  }

  /** 缓存上限（先到先出）。 */
  private static trimEpisodeCache(): void {
    while (DanmakuService.episodeIdCache.size >
      DanmakuService.MAX_EPISODE_CACHE) {
      const first: number | undefined =
        DanmakuService.episodeIdCache.keys().next().value;
      if (first === undefined) {
        return;
      }
      DanmakuService.episodeIdCache.delete(first);
    }
  }

  /**
   * 来源过滤 → 屏蔽规则 → 去重（顺序与源码一致：
   * 先去重再渲染时过滤来源，这里合并成一次处理，结果等价且只遍历一遍）。
   */
  static applyFilters(entries: DanmakuEntry[]): DanmakuEntry[] {
    const biliBili: boolean =
      SettingsStore.getBool(SettingsKeys.danmakuBiliBiliSource);
    const gamer: boolean = SettingsStore.getBool(SettingsKeys.danmakuGamerSource);
    const danDan: boolean = SettingsStore.getBool(SettingsKeys.danmakuDanDanSource);

    const kept: DanmakuEntry[] = [];
    for (let i = 0; i < entries.length; i++) {
      const entry: DanmakuEntry = entries[i];
      const source: string = entry.source;
      const isBiliBili: boolean = source.indexOf('BiliBili') >= 0;
      const isGamer: boolean = source.indexOf('Gamer') >= 0;
      if (!biliBili && isBiliBili) {
        continue;
      }
      if (!gamer && isGamer) {
        continue;
      }
      // 既不是 BiliBili 也不是 Gamer 的，归到「弹弹play」这一档
      if (!danDan && !isBiliBili && !isGamer) {
        continue;
      }
      if (DanmakuShieldStore.isBlocked(entry.message)) {
        continue;
      }
      kept.push(entry);
    }

    if (!SettingsStore.getBool(SettingsKeys.danmakuDeduplication)) {
      return DanmakuService.sortByTime(kept);
    }
    const merged: DanmakuEntry[] = mergeDuplicateDanmakus(kept, 5);
    Logger.info(TAG, `去重合并：${kept.length} → ${merged.length} 条`);
    return DanmakuService.sortByTime(merged);
  }

  /**
   * 按时间升序（**必须做**，不是优化）。
   *
   * `DanmakuSchedule.take()` 用**单游标**扫列表：遇到第一条时间还没到的就停下。
   * 只要列表不是升序，排在它后面的弹幕就永远发不出来——真机表现就是
   * 「这个番的弹幕滚不出来」（用户 2026-09-18：恋爱 FLOPS）。
   *
   * 而列表**天然不保证升序**，两条路都不保证：
   *   1. 不去重（默认）：直接用接口返回顺序。上游带 `withRelated=true`，
   *      会把**关联集**的弹幕一起返回（302 的 Location 里就有
   *      `related=b-ep…`），这些条目时间跨度是整个季，混进来就不再有序；
   *   2. 去重：`mergeDuplicateDanmakus` 是按**弹幕内容**分组的，
   *      输出顺序 = 内容首次出现的顺序，和时间毫无关系。
   */
  private static sortByTime(entries: DanmakuEntry[]): DanmakuEntry[] {
    entries.sort((a: DanmakuEntry, b: DanmakuEntry) => a.time - b.time);
    return entries;
  }

  // ---------------- 缓存 ----------------

  private static cachePath(pluginName: string, bgmId: number,
    episode: number): string {
    const safeName: string = pluginName.length === 0 ? 'unknown' : pluginName;
    return `${DanmakuService.dir}/${DanmakuService.CACHE_SCHEMA}-` +
      `${safeName}-${bgmId}-${episode}.json`;
  }

  private static writeCache(pluginName: string, bgmId: number, episode: number,
    entries: DanmakuEntry[]): void {
    if (DanmakuService.dir.length === 0 || entries.length === 0) {
      return;
    }
    const array: Object[] = [];
    for (let i = 0; i < entries.length; i++) {
      array.push(entries[i].toJson());
    }
    const path: string = DanmakuService.cachePath(pluginName, bgmId, episode);
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(array));
      } finally {
        fileIo.closeSync(file);
      }
      Logger.info(TAG, `弹幕已缓存：${array.length} 条`);
    } catch (error) {
      const err = error as Error;
      Logger.warn(TAG, `弹幕缓存写入失败：${err.message}`);
    }
  }

  private static readCache(pluginName: string, bgmId: number,
    episode: number): DanmakuEntry[] {
    const out: DanmakuEntry[] = [];
    if (DanmakuService.dir.length === 0) {
      return out;
    }
    const path: string = DanmakuService.cachePath(pluginName, bgmId, episode);
    if (!fileIo.accessSync(path)) {
      return out;
    }
    try {
      const stat = fileIo.statSync(path);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const read: number = fileIo.readSync(file.fd, buffer);
        text = new util.TextDecoder().decodeToString(
          new Uint8Array(buffer, 0, read));
      } finally {
        fileIo.closeSync(file);
      }
      const parsed: Object = JSON.parse(text) as Object;
      if (!Array.isArray(parsed)) {
        return out;
      }
      const list: Object[] = parsed as Object[];
      for (let i = 0; i < list.length; i++) {
        const rec: Record<string, Object> | null = asRecord(list[i]);
        if (rec !== null) {
          out.push(DanmakuEntry.fromJson(rec));
        }
      }
    } catch (error) {
      const err = error as Error;
      Logger.warn(TAG, `弹幕缓存读取失败：${err.message}`);
    }
    return out;
  }
}

/** 本地的小工具：把 JSON 值收成表（避免为此多 import 一个类）。 */
function asRecord(value: Object): Record<string, Object> | null {
  if (value === null || value === undefined || Array.isArray(value)) {
    return null;
  }
  const rec: Record<string, Object> = value as Record<string, Object>;
  return rec;
}
