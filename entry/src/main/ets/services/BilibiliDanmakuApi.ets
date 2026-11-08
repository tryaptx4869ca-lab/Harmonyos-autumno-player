import { util } from '@kit.ArkTS';
import { DanmakuEntry } from '../model/DanmakuModels';
import { ApiEndpoints } from '../request/config/ApiEndpoints';
import { ApiBytesResponse, ApiClient } from '../request/core/ApiClient';
import { BilibiliDanmakuXml } from './BilibiliDanmakuXml';
import { InflateRaw } from './InflateRaw';
import { EpisodeTitleService } from './metadata/EpisodeTitleService';
import { Logger } from './Logger';

const TAG: string = 'AutumnBiliDanmaku';

/**
 * 哔哩哔哩弹幕。
 *
 * ## 为什么需要它
 *
 * 参照实现（Kazumi）只走弹弹play 一条弹幕链路，而弹弹play 对长番的收录是
 * **截断**的：实测《名侦探柯南》（Bangumi 899）在弹弹play 是 animeId 266，
 * 数字集号只到 **1216**（之后全是 `C143` 这类特典编号），
 * 而哔哩哔哩同名季（season_id 33378）有 **1272** 集、每集都有弹幕。
 * 于是用户在柯南后段看到的永远是「这一集没有弹幕源」（用户 2026-09-19）。
 *
 * 这里补上第二条链路：**季 → 分集 cid → 弹幕 XML**。三段的复用情况：
 *   - 搜季 / 拉分集表：直接用 `EpisodeTitleService`（集标题已经在做同一件事，
 *     顺带把每集的 `cid` 留了下来，两个功能共用一次请求）；
 *   - 弹幕本体：`x/v1/dm/list.so?oid={cid}`，返回 deflate 压缩的 XML。
 *
 * ## 与弹弹play 的差异
 *
 *   - 来源标成 `BiliBili`，正好命中弹幕设置里的「BiliBili」来源开关；
 *   - 弹幕类型按哔哩哔哩的 mode 归一化到本工程的 1/4/5
 *     （mode 1/2/3/6 = 滚动，4 = 底部，5 = 顶部，7/8/9 = 高级/代码/脚本，丢弃）；
 *   - 颜色是十进制 RGB，用 `rgbHex` 转成 `#RRGGBB`。
 */
export class BilibiliDanmakuApi {
  /**
   * 一次取一集弹幕。
   *
   * 失败/为空都返回空数组（调用方只关心「有没有拿到」）；
   * 返回体里没有弹幕时**换一份 cookie 重试一次**——被风控时哔哩哔哩会回
   * 一个 HTML 错误页（HTTP 200 + 没有 `<d>` 节点），那种情况一次重试就能救回来。
   */
  static async danmakuByCid(cid: number): Promise<DanmakuEntry[]> {
    if (cid <= 0) {
      return [];
    }
    const url: string = ApiEndpoints.bilibiliAPIDomain +
      ApiEndpoints.formatUrl(ApiEndpoints.bilibiliDanmakuList, [`${cid}`]);
    for (let attempt = 0; attempt < 2; attempt++) {
      const headers: Record<string, string> =
        await EpisodeTitleService.bilibiliHeaders(attempt > 0);
      const response: ApiBytesResponse =
        await ApiClient.apiDio().getBytes(url, headers);
      if (!response.ok || response.bytes.length === 0) {
        Logger.warn(TAG,
          `弹幕接口 HTTP ${response.statusCode}（第 ${attempt + 1} 次，cid=${cid}）`);
        continue;
      }
      try {
        const xml: string = BilibiliDanmakuApi.decodeXmlBytes(response.bytes);
        const entries: DanmakuEntry[] = BilibiliDanmakuXml.parse(xml);
        if (entries.length > 0) {
          Logger.info(TAG,
            `cid=${cid} 取到哔哩哔哩弹幕 ${entries.length} 条` +
              `（响应 ${response.bytes.length} 字节 → XML ${xml.length} 字符）`);
          return entries;
        }
        /**
         * 响应**确实是弹幕 XML、只是没有弹幕**（新番常见）：
         * 直接收工，不要为了一个确定的空结果再打一次请求。
         */
        if (BilibiliDanmakuApi.isDanmakuXml(xml)) {
          Logger.info(TAG, `cid=${cid} 这一集确实没有弹幕（XML 有效但为空）`);
          return [];
        }
        Logger.warn(TAG,
          `cid=${cid} 响应不是弹幕 XML（第 ${attempt + 1} 次）：${xml.substring(0, 80)}`);
      } catch (error) {
        const err = error as Error;
        Logger.warn(TAG,
          `弹幕解压/解析失败（第 ${attempt + 1} 次，cid=${cid}）：${err.message}`);
      }
    }
    return [];
  }

  /**
   * 响应字节 → XML 文本。
   *
   * 两种情况都要认：`@ohos.net.http` 有时会替我们把 `Content-Encoding` 解掉
   * （拿到手就是 `<?xml…?><i>…`），有时原样给出裸 DEFLATE（`0x94` 开头那类）。
   * 只认其中一种，真机上就是「有时候能出弹幕、有时候一片空白」。
   */
  static decodeXmlBytes(bytes: Uint8Array): string {
    if (bytes.length === 0) {
      return '';
    }
    /**
     * 判据是「解出来的文本**长得像不像弹幕 XML**」，不能只看首字节：
     * 裸 DEFLATE 没有魔数，它的第一个字节可以是任意值（包括 `<`），
     * 只看首字节会在压缩体上误判成文本，直接静默变成「这一集没弹幕」。
     * 反过来，弹幕 XML 的头部形状很固定：`<?xml …?><i><chatserver>…`。
     */
    const text: string = BilibiliDanmakuApi.decodeText(bytes);
    if (BilibiliDanmakuApi.looksLikeDanmakuXml(text)) {
      return text;
    }
    return BilibiliDanmakuApi.decodeText(InflateRaw.auto(bytes));
  }

  /** 文本是不是弹幕 XML（给调用方判断「空」与「不是弹幕接口的响应」用）。 */
  static isDanmakuXml(text: string): boolean {
    return BilibiliDanmakuApi.looksLikeDanmakuXml(text);
  }

  /** UTF-8 解码（顺手去掉 BOM）。 */
  private static decodeText(bytes: Uint8Array): string {
    const text: string = new util.TextDecoder().decodeToString(bytes);
    if (text.length > 0 && text.charCodeAt(0) === 0xFEFF) {
      return text.substring(1);
    }
    return text;
  }

  /** 头部是不是弹幕 XML（`<?xml …?><i>`；只看前 64 个字符）。 */
  private static looksLikeDanmakuXml(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    const head: string = text.substring(0, 64);
    return head.indexOf('<?xml') >= 0 || head.indexOf('<i>') >= 0;
  }

  /**
   * 解析入口的转发：XML → 弹幕列表。
   *
   * 真正的实现在 `BilibiliDanmakuXml`（纯函数、无系统 API），
   * 这里保留同名方法是为了让调用点只依赖一个类。
   */
  static parseXml(xml: string): DanmakuEntry[] {
    return BilibiliDanmakuXml.parse(xml);
  }
}
