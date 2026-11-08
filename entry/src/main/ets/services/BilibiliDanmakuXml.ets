import { DanmakuEntry, rgbHex } from '../model/DanmakuModels';

/**
 * 哔哩哔哩弹幕 XML → 弹幕列表（**纯函数，无网络无系统 API**）。
 *
 * 拆出来的原因有两个：
 *   1. 网络与解析分开后，解析这段可以拿**真实响应体**在设备外直接跑
 *      （Node 里跑同一份实现，见工程根 `.tmp_verify` 的取证脚本）；
 *   2. 自检 `DanmakuSelfCheck.runBilibiliOffline()` 只验证这一段，
 *      不需要网络就能确认「解压 → 解析 → 类型/颜色/实体」整条转换是对的。
 *
 * 不做完整 XML 解析：只需要 `<d p="…">文本</d>` 这一种节点，顺序扫描足够，
 * 也不用担心实体展开。文本里的 `<` / `>` 一律是实体（`&lt;` / `&gt;`），
 * 所以按 `</d>` 收尾是安全的。
 */
export class BilibiliDanmakuXml {
  /** `<d p="` 前缀。 */
  private static readonly DM_PREFIX: string = '<d p="';

  static parse(xml: string): DanmakuEntry[] {
    const out: DanmakuEntry[] = [];
    if (xml.length === 0) {
      return out;
    }
    let cursor: number = 0;
    while (cursor < xml.length) {
      const start: number = xml.indexOf(BilibiliDanmakuXml.DM_PREFIX, cursor);
      if (start < 0) {
        break;
      }
      const attrStart: number = start + BilibiliDanmakuXml.DM_PREFIX.length;
      const attrEnd: number = xml.indexOf('"', attrStart);
      if (attrEnd < 0) {
        break;
      }
      const textStart: number = xml.indexOf('>', attrEnd);
      if (textStart < 0) {
        break;
      }
      const textEnd: number = xml.indexOf('</d>', textStart);
      if (textEnd < 0) {
        break;
      }
      const attrs: string = xml.substring(attrStart, attrEnd);
      const text: string =
        BilibiliDanmakuXml.unescape(xml.substring(textStart + 1, textEnd)).trim();
      cursor = textEnd + 4;
      const entry: DanmakuEntry | null =
        BilibiliDanmakuXml.entryOf(attrs, text);
      if (entry !== null) {
        out.push(entry);
      }
    }
    return out;
  }

  /**
   * `p` 字段 + 文本 → 一条弹幕；返回 null 表示这条不渲染。
   *
   * `p` 形如 `12.345,1,25,16777215,1690000000,0,abcdef,1234567890,10`：
   * 时间(秒), 模式, 字号, 颜色(十进制 RGB), 发送时间戳, 弹幕池, 用户哈希, 行号, …
   */
  private static entryOf(attrs: string, text: string): DanmakuEntry | null {
    if (text.length === 0) {
      return null;
    }
    const parts: string[] = attrs.split(',');
    if (parts.length < 4) {
      return null;
    }
    const mode: number = Number.parseInt(parts[1], 10);
    const type: number = BilibiliDanmakuXml.renderType(mode);
    if (type === 0) {
      return null;
    }
    const time: number = Number.parseFloat(parts[0]);
    const color: number = Number.parseInt(parts[3], 10);
    const entry = new DanmakuEntry();
    entry.message = text;
    entry.time = Number.isNaN(time) || time < 0 ? 0 : time;
    entry.type = type;
    entry.color = Number.isNaN(color) ? '#FFFFFF' : rgbHex(color);
    entry.source = 'BiliBili';
    return entry;
  }

  /**
   * 哔哩哔哩的弹幕 mode → 本工程的 1 / 4 / 5。
   *
   * | mode | 含义 | 本工程 |
   * |------|------|--------|
   * | 1/2/3 | 滚动（普通 / 底部 / 顶部以外的普通弹幕） | 1 普通 |
   * | 6 | 逆向滚动 | 1 普通 |
   * | 4 | 底部 | 4 底部 |
   * | 5 | 顶部 | 5 顶部 |
   * | 7/8/9 | 高级 / 代码 / BAS | 0 丢弃（本工程没有定位与脚本弹幕的渲染能力） |
   */
  private static renderType(mode: number): number {
    if (mode === 4) {
      return 4;
    }
    if (mode === 5) {
      return 5;
    }
    if (mode === 7 || mode === 8 || mode === 9) {
      return 0;
    }
    return 1;
  }

  /** XML 实体还原（弹幕文本里 `<` `>` `&` `"` 与数字实体都会出现）。 */
  private static unescape(input: string): string {
    if (input.indexOf('&') < 0) {
      return input;
    }
    let out: string = input;
    out = out.replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
      .replace(/&#39;/g, "'");
    out = out.replace(/&#(\d+);/g, (match: string, digits: string): string => {
      const code: number = Number.parseInt(digits, 10);
      if (Number.isNaN(code) || code > 0x10FFFF) {
        return match;
      }
      return BilibiliDanmakuXml.fromCodePoint(code);
    });
    out = out.replace(/&#x([0-9a-fA-F]+);/g,
      (match: string, digits: string): string => {
        const code: number = Number.parseInt(digits, 16);
        if (Number.isNaN(code) || code > 0x10FFFF) {
          return match;
        }
        return BilibiliDanmakuXml.fromCodePoint(code);
      });
    // &amp; 必须最后换，否则 "&amp;lt;" 会被二次还原成 "<"
    return out.replace(/&amp;/g, '&');
  }

  /**
   * 码点 → 字符串（自己拼代理对）。
   *
   * 不用 `String.fromCodePoint`：BMP 之外的实体（emoji 那种）在 ArkTS 上
   * 走 `fromCharCode` 会被截断成半个代理对，渲染出方块字。
   */
  private static fromCodePoint(code: number): string {
    if (code <= 0xFFFF) {
      return String.fromCharCode(code);
    }
    const offset: number = code - 0x10000;
    return String.fromCharCode(0xD800 + (offset >> 10),
      0xDC00 + (offset & 0x3FF));
  }
}
