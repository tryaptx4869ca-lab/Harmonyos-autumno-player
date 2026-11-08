import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import {
  DanmakuEntry,
  hexToRgb,
  mergeDuplicateDanmakus,
  normalizeMessage,
  rgbHex
} from '../model/DanmakuModels';
import { DanmakuApi } from './DanmakuApi';
import { BilibiliDanmakuApi } from './BilibiliDanmakuApi';
import { DanmakuBiliContext, DanmakuLoadResult, DanmakuService } from './DanmakuService';
import { EpisodeTitleService } from './metadata/EpisodeTitleService';
import { DanmakuShieldStore } from './DanmakuShieldStore';
import { Logger } from './Logger';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnSelf';

/**
 * 弹幕自检（阶段五）。
 *
 * 分两段：
 *   1. 纯逻辑：颜色解析、`p` 字段解析、文本归一化、同内容合并、屏蔽规则
 *   2. 真实取弹幕：拿一个真实 Bangumi 条目 id 走一遍「bgm id → 弹弹play id → 评论」
 *      （模拟器上就能跑，也是这条链路唯一的自动化证据）
 *
 * 逻辑用例的期望值都是从源码 `utils/danmaku.dart` 逐行推出来的。
 */
export class DanmakuSelfCheck {
  private static passCount: number = 0;
  private static failCount: number = 0;

  /**
   * 真实格式的哔哩哔哩弹幕响应体（**裸 DEFLATE**，base64）。
   *
   * 内容是把下面这段 XML 用 `zlib.deflateRawSync` 压出来的：
   * ```
   * <d p="12.5,1,25,16777215,…">第一条&lt;滚动&gt;弹幕</d>
   * <d p="30.25,5,25,16711680,…">顶部弹幕 &amp; 特殊字符</d>
   * <d p="40.5,4,25,255,…">底部弹幕</d>
   * <d p="50,7,25,16777215,…">高级弹幕应被丢弃</d>
   * ```
   * 四种 mode（滚动 / 顶部 / 底部 / 高级）与实体转义都在里面。
   */
  private static readonly biliDeflatedXml: string =
    'bc/NSsNAEAfwVwl7yGlNdjfZppJNevMJ9AHSJNSFfJQ0FI9CT/ZsUQQP7UELjR6liX2cbmLfQvKB6cGBgYHh/2OGje7CQJr7yYzHkQWwgoDkR27s8WhigZvrq4shGNmM28y9ddKZn8z9xK5HZcwDXrfixiFTz7bMk6YWwEShEENCIR4YhkFwPVyitiCCztiFGGIE7CrLjvv78nUtB6lZfr+I5VaepKY45CJfMdXrQA0phELaiRgPhqgXcSeSRjytv06LbQtIshNOTal6yMvPpfh4qrK33tSRQqFek4Se3Uc6TWs0Uaz+tD5KETT+/07r0np7y+65Kt7btCgefza7434jDotGUrn9Cw==';

  /** 用作哔哩哔哩链路的真实条目：名侦探柯南（Bangumi 899 / 哔哩哔哩季 33378）。 */
  private static readonly conanBgmId: number = 899;
  private static readonly conanTitle: string = '名侦探柯南';
  private static readonly conanOriginTitle: string = '名探偵コナン';
  private static readonly conanEpisodeCount: number = 1275;
  /** 弹弹play 覆盖不到、但哔哩哔哩有弹幕的那一集（用户 2026-09-19 的场景）。 */
  private static readonly conanProbeEpisode: number = 1217;

  /**
   * 用作真实取弹幕的条目：葬送的芙莉莲（bgm 400602）。
   *
   * 为什么不用榜单上的新番：弹弹play 只对**它自己收录过的**条目做 bgm 映射，
   * 2026 年的新番（例如 Re:Zero 第四季 633836）映射查不到，会返回
   * `errorCode 7 无法找到指定的资源`。这不是代码问题，是数据覆盖问题。
   */
  private static readonly sampleBgmId: number = 400602;

  static run(): void {
    DanmakuSelfCheck.passCount = 0;
    DanmakuSelfCheck.failCount = 0;
    hilog.info(DOMAIN, TAG, '=== 弹幕自检开始 ===');

    // 1. 颜色
    DanmakuSelfCheck.check('白色 0xFFFFFF → #FFFFFF',
      rgbHex(16777215) === '#FFFFFF', rgbHex(16777215));
    DanmakuSelfCheck.check('红色 0xFF0000 → #FF0000',
      rgbHex(16711680) === '#FF0000', rgbHex(16711680));
    DanmakuSelfCheck.check('#FF0000 → 16711680',
      hexToRgb('#FF0000') === 16711680, `${hexToRgb('#FF0000')}`);

    // 2. p 字段解析：12.5,1,16711680,DanDan
    const parsed = new DanmakuEntry();
    const source = new DanmakuEntry();
    const rec: Record<string, Object> = {};
    rec['m'] = '测试弹幕';
    rec['p'] = '12.5,1,16711680,DanDan';
    const entry: DanmakuEntry = DanmakuEntry.fromJson(rec);
    DanmakuSelfCheck.check('p 字段解析出时间 12.5',
      entry.time === 12.5, `${entry.time}`);
    DanmakuSelfCheck.check('p 字段解析出类型 1',
      entry.type === 1, `${entry.type}`);
    DanmakuSelfCheck.check('p 字段解析出颜色 #FF0000',
      entry.color === '#FF0000', entry.color);
    DanmakuSelfCheck.check('p 字段解析出来源 DanDan',
      entry.source === 'DanDan', entry.source);

    // 3. 归一化：全角转半角、去空白、3 个以上重复压成 3 个
    DanmakuSelfCheck.check('全角转半角（ＡＢＣ → abc）',
      normalizeMessage('ＡＢＣ') === 'abc', normalizeMessage('ＡＢＣ'));
    DanmakuSelfCheck.check('去掉空白（a b c → abc）',
      normalizeMessage('a b c') === 'abc', normalizeMessage('a b c'));
    DanmakuSelfCheck.check('重复字符压缩（啊啊啊啊啊 → 啊啊啊）',
      normalizeMessage('啊啊啊啊啊') === '啊啊啊', normalizeMessage('啊啊啊啊啊'));
    DanmakuSelfCheck.check('标点被剔除（好！好！ → 好好）',
      normalizeMessage('好！好！') === '好好', normalizeMessage('好！好！'));

    // 4. 同内容合并：5 秒窗口内合成一条 x2
    const a = DanmakuSelfCheck.make('前方高能', 10, 1);
    const b = DanmakuSelfCheck.make('前方高能', 13, 1);
    const merged: DanmakuEntry[] = mergeDuplicateDanmakus([a, b], 5);
    DanmakuSelfCheck.check('同内容 5 秒内合并为 1 条',
      merged.length === 1, `${merged.length}`);
    DanmakuSelfCheck.check('合并文案为「前方高能 x2」',
      merged.length === 1 && merged[0].message === '前方高能 x2',
      merged.length === 1 ? merged[0].message : '无结果');
    DanmakuSelfCheck.check('合并后类型变顶部（5）',
      merged.length === 1 && merged[0].type === 5,
      merged.length === 1 ? `${merged[0].type}` : '无结果');
    const c = DanmakuSelfCheck.make('前方高能', 30, 1);
    const notMerged: DanmakuEntry[] =
      mergeDuplicateDanmakus([a, c], 5);
    DanmakuSelfCheck.check('同内容超过窗口不合并',
      notMerged.length === 2, `${notMerged.length}`);

    // 5. 屏蔽规则
    const shieldBefore: number = DanmakuShieldStore.count();
    DanmakuShieldStore.add('/^自检屏蔽/');
    DanmakuSelfCheck.check('正则屏蔽规则命中',
      DanmakuShieldStore.isBlocked('自检屏蔽测试'), '未命中');
    DanmakuSelfCheck.check('普通弹幕不被误伤',
      !DanmakuShieldStore.isBlocked('这是一条普通弹幕'), '被误伤');
    if (shieldBefore !== DanmakuShieldStore.count()) {
      DanmakuShieldStore.remove(DanmakuShieldStore.count() - 1);
    }

    // 6. 来源过滤（用设置驱动，跑完还原）
    const filtered: DanmakuEntry[] =
      DanmakuService.applyFilters([a, b]);
    DanmakuSelfCheck.check('来源过滤不丢当前默认源（弹弹play）',
      filtered.length > 0, `${filtered.length}`);

    hilog.info(DOMAIN, TAG,
      '=== 弹幕自检结束：%{public}d 通过 / %{public}d 失败 ===',
      DanmakuSelfCheck.passCount, DanmakuSelfCheck.failCount);
    Logger.info(TAG,
      `弹幕自检结束：${DanmakuSelfCheck.passCount} 通过 / ${DanmakuSelfCheck.failCount} 失败`);
  }

  /** 真实取一次弹幕（网络链路证据）。 */
  static async runNetworkProbe(): Promise<void> {
    hilog.info(DOMAIN, TAG, '=== 弹幕网络自检开始（条目 %{public}d） ===',
      DanmakuSelfCheck.sampleBgmId);
    try {
      const danDanId: number =
        await DanmakuApi.bangumiIdByBgmId(DanmakuSelfCheck.sampleBgmId);
      hilog.info(DOMAIN, TAG, '弹弹play 番剧 id = %{public}d', danDanId);
      if (danDanId === 0) {
        hilog.warn(DOMAIN, TAG, '❌ 未匹配到弹弹play 条目');
        return;
      }
      const entries: DanmakuEntry[] = await DanmakuApi.danmaku(danDanId, 1);
      hilog.info(DOMAIN, TAG, '第 1 集弹幕条数 = %{public}d', entries.length);
      DanmakuSelfCheck.check('真实取到弹幕（>0 条）', entries.length > 0,
        `${entries.length}`);
      if (entries.length > 0) {
        const head: DanmakuEntry = entries[0];
        hilog.info(DOMAIN, TAG,
          '首条弹幕：t=%{public}s type=%{public}d color=%{public}s source=%{public}s text=%{public}s',
          `${head.time}`, head.type, head.color, head.source, head.message);
      }
      const viaService: DanmakuLoadResult = await DanmakuService.load(
        'selfcheck', DanmakuSelfCheck.sampleBgmId, 1,
        new DanmakuBiliContext());
      hilog.info(DOMAIN, TAG,
        '服务层结果：%{public}d 条（缓存=%{public}s 错误=「%{public}s」）',
        viaService.entries.length, `${viaService.fromCache}`,
        viaService.error);
      Logger.info(TAG,
        `弹幕服务层：${viaService.entries.length} 条（缓存=${viaService.fromCache}）`);
    } catch (error) {
      const err = error as Error;
      hilog.error(DOMAIN, TAG, '❌ 弹幕网络自检失败：%{public}s', err.message);
    }
    hilog.info(DOMAIN, TAG, '=== 弹幕网络自检结束 ===');
  }

  /**
   * 哔哩哔哩弹幕自检（**离线**）：解压 → XML 解析 → 类型 / 颜色 / 实体。
   *
   * 用的样本就是真实接口的响应体（裸 DEFLATE），所以这一段同时验证了
   * `InflateRaw` 与 `BilibiliDanmakuApi.parseXml` 两段。
   */
  static runBilibiliOffline(): void {
    DanmakuSelfCheck.passCount = 0;
    DanmakuSelfCheck.failCount = 0;
    hilog.info(DOMAIN, TAG, '=== 哔哩哔哩弹幕自检（离线）开始 ===');

    const compressed: Uint8Array =
      new util.Base64Helper().decodeSync(DanmakuSelfCheck.biliDeflatedXml);
    const xml: string = BilibiliDanmakuApi.decodeXmlBytes(compressed);
    const entries: DanmakuEntry[] = BilibiliDanmakuApi.parseXml(xml);
    DanmakuSelfCheck.check('裸 DEFLATE 解压出 XML',
      xml.indexOf('<i>') >= 0, xml.substring(0, 40));
    DanmakuSelfCheck.check('解析出 3 条（高级弹幕被丢弃）',
      entries.length === 3, `${entries.length}`);

    if (entries.length >= 3) {
      const first: DanmakuEntry = entries[0];
      DanmakuSelfCheck.check('滚动弹幕时间 12.5',
        first.time === 12.5, `${first.time}`);
      DanmakuSelfCheck.check('滚动弹幕类型 1',
        first.type === 1, `${first.type}`);
      DanmakuSelfCheck.check('滚动弹幕颜色 #FFFFFF',
        first.color === '#FFFFFF', first.color);
      DanmakuSelfCheck.check('来源标成 BiliBili',
        first.source === 'BiliBili', first.source);
      DanmakuSelfCheck.check('实体还原（&lt;滚动&gt; → <滚动>）',
        first.message === '第一条<滚动>弹幕', first.message);
      DanmakuSelfCheck.check('顶部弹幕类型 5 且颜色 #FF0000',
        entries[1].type === 5 && entries[1].color === '#FF0000',
        `${entries[1].type} / ${entries[1].color}`);
      DanmakuSelfCheck.check('底部弹幕类型 4 且颜色 #0000FF',
        entries[2].type === 4 && entries[2].color === '#0000FF',
        `${entries[2].type} / ${entries[2].color}`);
      DanmakuSelfCheck.check('&amp; 还原且不被二次还原（&amp; → &）',
        entries[1].message === '顶部弹幕 & 特殊字符', entries[1].message);
    }

    // 未被压缩的 XML（@ohos.net.http 自己解压过的那种）也要能走通
    const plain: string =
      '<i><d p="5,1,25,16777215,1,0,a,1,10">纯文本分支</d></i>';
    const plainBytes: Uint8Array =
      new util.TextEncoder().encodeInto(plain);
    DanmakuSelfCheck.check('未压缩响应体直接可解析',
      BilibiliDanmakuApi.parseXml(
        BilibiliDanmakuApi.decodeXmlBytes(plainBytes)).length === 1, '0 条');

    hilog.info(DOMAIN, TAG,
      '=== 哔哩哔哩弹幕自检（离线）结束：%{public}d 通过 / %{public}d 失败 ===',
      DanmakuSelfCheck.passCount, DanmakuSelfCheck.failCount);
    Logger.info(TAG,
      `哔哩哔哩弹幕离线自检：${DanmakuSelfCheck.passCount} 通过 / ${DanmakuSelfCheck.failCount} 失败`);
  }

  /**
   * 哔哩哔哩弹幕自检（**网络**）：柯南第 1217 集。
   *
   * 这一集正是用户报的场景：弹弹play 的分集表到 1216 为止，
   * 走旧链路只会得到「这一集没有弹幕源」。
   */
  static async runBilibiliProbe(): Promise<void> {
    hilog.info(DOMAIN, TAG, '=== 哔哩哔哩弹幕网络自检开始（%{public}s 第 %{public}d 集） ===',
      DanmakuSelfCheck.conanTitle, DanmakuSelfCheck.conanProbeEpisode);
    try {
      const cids: Map<number, number> = await EpisodeTitleService.bilibiliCids(
        DanmakuSelfCheck.conanTitle, DanmakuSelfCheck.conanOriginTitle,
        DanmakuSelfCheck.conanEpisodeCount);
      DanmakuSelfCheck.check('哔哩哔哩搜到季并建出集号→cid 表',
        cids.size > 0, `${cids.size} 集`);
      const cid: number | undefined =
        cids.get(DanmakuSelfCheck.conanProbeEpisode);
      hilog.info(DOMAIN, TAG, '第 %{public}d 集 cid = %{public}d',
        DanmakuSelfCheck.conanProbeEpisode, cid === undefined ? 0 : cid);
      if (cid !== undefined && cid > 0) {
        const entries: DanmakuEntry[] = await BilibiliDanmakuApi.danmakuByCid(cid);
        DanmakuSelfCheck.check('哔哩哔哩取到弹幕（>0 条）',
          entries.length > 0, `${entries.length} 条`);
        if (entries.length > 0) {
          const head: DanmakuEntry = entries[0];
          hilog.info(DOMAIN, TAG,
            '首条：t=%{public}s type=%{public}d color=%{public}s text=%{public}s',
            `${head.time}`, head.type, head.color, head.message);
        }
      }

      // 整条服务链路（弹弹play 没货 → 哔哩哔哩兜底）
      const context: DanmakuBiliContext = new DanmakuBiliContext();
      context.title = DanmakuSelfCheck.conanTitle;
      context.originTitle = DanmakuSelfCheck.conanOriginTitle;
      context.episodeCount = DanmakuSelfCheck.conanEpisodeCount;
      const result: DanmakuLoadResult = await DanmakuService.load('selfcheck',
        DanmakuSelfCheck.conanBgmId, DanmakuSelfCheck.conanProbeEpisode, context);
      hilog.info(DOMAIN, TAG,
        '服务层结果：%{public}d 条（缓存=%{public}s 错误=「%{public}s」）',
        result.entries.length, `${result.fromCache}`, result.error);
      DanmakuSelfCheck.check('服务层兜底后有弹幕（>0 条）',
        result.entries.length > 0, `${result.entries.length} 条`);
      if (result.entries.length > 0) {
        DanmakuSelfCheck.check('兜底来源是 BiliBili',
          result.entries[0].source === 'BiliBili', result.entries[0].source);
      }
    } catch (error) {
      const err = error as Error;
      hilog.error(DOMAIN, TAG, '❌ 哔哩哔哩自检失败：%{public}s', err.message);
    }
    hilog.info(DOMAIN, TAG, '=== 哔哩哔哩弹幕网络自检结束 ===');
    Logger.info(TAG,
      `哔哩哔哩弹幕网络自检：${DanmakuSelfCheck.passCount} 通过 / ${DanmakuSelfCheck.failCount} 失败`);
  }

  private static make(message: string, time: number, type: number): DanmakuEntry {
    const entry = new DanmakuEntry();
    entry.message = message;
    entry.time = time;
    entry.type = type;
    entry.color = '#FFFFFF';
    entry.source = 'DanDan';
    return entry;
  }

  private static check(name: string, ok: boolean, detail: string): void {
    if (ok) {
      DanmakuSelfCheck.passCount += 1;
      hilog.info(DOMAIN, TAG, '✅ %{public}s', name);
      Logger.info(TAG, `✅ ${name}`);
    } else {
      DanmakuSelfCheck.failCount += 1;
      hilog.error(DOMAIN, TAG, '❌ %{public}s（%{public}s）', name, detail);
      Logger.error(TAG, `❌ ${name}（${detail}）`);
    }
  }
}
