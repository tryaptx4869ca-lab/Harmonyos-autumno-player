/**
 * 随机请求头。
 * 移植自参照实现 `lib/utils/http_headers.dart` + `lib/utils/constants.dart` 的两个列表。
 *
 * 为什么要随机：部分站点对固定 UA 有反爬策略，参照实现每次请求都随机取一个。
 */
export class HttpHeaders {
  /** 对应 `constants.dart: userAgentsList`，顺序与内容逐条一致。 */
  static readonly userAgents: string[] = [
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.1',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.1 Safari/605.1.15',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36 Edg/136.0.0.0'
  ];

  /** 对应 `constants.dart: acceptLanguageList`。 */
  static readonly acceptLanguages: string[] = [
    'zh-CN,zh;q=0.9',
    'zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6',
    'zh-CN,zh-TW;q=0.9,zh;q=0.8,en-US;q=0.7,en;q=0.6'
  ];

  /**
   * 对应 `constants.dart: bangumiHTTPHeader`。
   * Bangumi API 文档要求 `user-agent` 形如 `<应用>/<版本> (<平台>) (<主页>)`。
   */
  static bangumiHeader(version: string): Record<string, string> {
    const header: Record<string, string> = {};
    header['user-agent'] = `Predidit/Kazumi/${version} (Android) (https://github.com/Predidit/Kazumi)`;
    header['referer'] = '';
    header['content-type'] = 'application/json';
    return header;
  }

  /** 随机 UA（源码 `getRandomUA`）。 */
  static randomUserAgent(): string {
    const index: number = Math.floor(Math.random() * HttpHeaders.userAgents.length);
    return HttpHeaders.userAgents[index];
  }

  /** 随机 accept-language（源码 `getRandomAcceptedLanguage`）。 */
  static randomAcceptedLanguage(): string {
    const index: number =
      Math.floor(Math.random() * HttpHeaders.acceptLanguages.length);
    return HttpHeaders.acceptLanguages[index];
  }
}
