import { http } from '@kit.NetworkKit';

export class DailyQuote {
  text: string = '';
  source: string = '';
  author: string = '';
}

/**
 * 「今日一句」的内存缓存：**每次冷启动应用都是一次新的开始**（进程内有效）。
 *
 * 这里只看进程内存，不落盘：重启应用 → 换新的一条；同一次运行里切页、从详情页
 * 返回推荐页 → 保持同一条，不重复联网（用户 2026-09-18 反馈过「每次回到推荐页
 * 都在重新加载」，那条要求仍然成立）。
 */
class QuoteCache {
  static quote: DailyQuote | null = null;
}

/**
 * 今日一句。
 *
 * 参照实现 lib/pages/popular/daily_quotes.dart：
 *   优先请求 hitokoto 番剧分类 https://v1.hitokoto.cn/?c=a&charset=utf-8
 *   失败时回落到本地 20 条原创文案，按「距 2026-01-01 的天数 % 20」取值。
 *
 * 与参照实现的差别（2026-09-19 用户：「今日一句改成每次打开都换？」）：
 * 源码 `popular_page.dart:105-139` 会把结果按天落盘（同一个自然日内始终是同一条），
 * 本工程改成**只做进程内缓存** ——
 *   - **每次打开应用**（冷启动）都换一条新的；
 *   - 同一次运行里切页、从详情页返回推荐页都保持同一条，不再联网；
 *   - 首帧先用本地文案顶上，网络那条回来再替换，全程不出现空白卡片。
 */
export class DailyQuoteService {
  private static readonly localPool: string[] = [
    '今天的进度条，不需要一次拉满，只要比昨天长一点就好。',
    '故事不会因为暂停键而停止生长，你也是。',
    '把上次没看完的那一集，当作今天的小小奖励吧。',
    '好的作品会提醒你：世界还可以被温柔地讲述。',
    '放下手机之前，先替今天的自己按一下保存。',
    '所谓追番，其实是和许多平行世界约好了每周见面。',
    '屏幕亮起的那一刻，今天的疲惫可以先退场。',
    '每一个二刷，都是在和过去某个时刻的自己重逢。',
    '别急着快进，有些风景藏在下一次呼吸里。',
    '愿你喜欢的角色，今天也在某个地方好好生活。',
    '秋绪替你记着：上次停在这里，是为了留一点期待。',
    '好的作品像风，读完以后，连走路都会变得轻一点。',
    '慢慢来，连一集的片尾曲也值得听完。',
    '那些看过的故事，最后都会变成你温柔的理由。',
    '今天没有必须追上谁，只要还在继续就好。',
    '封面会泛黄，但第一次心动的瞬间不会。',
    '把喜欢的东西看完，是一件很浪漫的小事。',
    '季节会轮换，你喜欢的番也可以一季一季地看。',
    '暂停、回味、再继续——这是属于读者的特权。',
    '愿你今晚合上屏幕时，心里还留着一点余温。'
  ];

  private static localFor(now: Date): string {
    const anchor: number = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate());
    const origin: number = Date.UTC(2026, 0, 1);
    const days: number = Math.floor((anchor - origin) / 86400000);
    let idx: number = days % DailyQuoteService.localPool.length;
    if (idx < 0) {
      idx += DailyQuoteService.localPool.length;
    }
    return DailyQuoteService.localPool[idx];
  }

  private static fallback(): DailyQuote {
    const q = new DailyQuote();
    q.text = DailyQuoteService.localFor(new Date());
    q.source = '秋绪';
    q.author = '';
    return q;
  }

  /**
   * 本次运行里已经拿到的那条（**同步、不联网**）；还没取过返回 null。
   *
   * 页面重建（返回推荐页）时先用它，所以不会出现「空卡片 → 再联网」那一下。
   */
  static cached(): DailyQuote | null {
    return QuoteCache.quote;
  }

  /**
   * 取「今日一句」：本次运行里已有就直接返回，否则请求一次（失败回落本地文案），
   * 结果写进内存缓存。
   */
  static async load(): Promise<DailyQuote> {
    const cached: DailyQuote | null = DailyQuoteService.cached();
    if (cached !== null) {
      return cached;
    }
    const quote: DailyQuote = await DailyQuoteService.fetch();
    QuoteCache.quote = quote;
    return quote;
  }

  /** 本地兜底文案（同步返回）：首帧先顶上，避免今日一句出现空白。 */
  static localToday(): DailyQuote {
    return DailyQuoteService.fallback();
  }

  static async fetch(): Promise<DailyQuote> {
    const client = http.createHttp();
    try {
      const resp: http.HttpResponse = await client.request(
        'https://v1.hitokoto.cn/?c=a&charset=utf-8',
        {
          method: http.RequestMethod.GET,
          header: { 'Accept': 'application/json' } as Record<string, string>,
          connectTimeout: 8000,
          readTimeout: 8000,
          expectDataType: http.HttpDataType.STRING
        } as http.HttpRequestOptions
      );
      if (resp.responseCode === 200) {
        const result: string | Object | ArrayBuffer = resp.result;
        const text: string = typeof result === 'string' ? result : JSON.stringify(result);
        const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
        const hitokoto: Object | undefined = root['hitokoto'];
        if (hitokoto !== undefined && hitokoto !== null) {
          const body: string = hitokoto.toString().trim();
          if (body.length > 0) {
            const q = new DailyQuote();
            q.text = body;
            const from: Object | undefined = root['from'];
            const fromWho: Object | undefined = root['from_who'];
            q.source = from === undefined || from === null ? '' : from.toString().trim();
            q.author = fromWho === undefined || fromWho === null ? '' : fromWho.toString().trim();
            return q;
          }
        }
      }
    } catch (e) {
      // 离线或 DNS 失败：使用本地文案
    } finally {
      client.destroy();
    }
    return DailyQuoteService.fallback();
  }
}
