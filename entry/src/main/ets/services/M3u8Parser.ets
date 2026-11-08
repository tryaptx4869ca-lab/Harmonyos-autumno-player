import { UrlParts } from '../request/core/UrlParts';

/**
 * HLS（m3u8）清单解析。逐条移植自参照实现 `lib/utils/m3u8_parser.dart`。
 *
 * 下载与离线播放都靠它：下载时把远端清单改写成指向本地 `seg_00000.ts`
 * 的清单（`buildLocalM3u8`），离线播放就直接播这份本地清单。
 *
 * 与 Dart 的差异（仅仅是没有运算符重载）：`M3u8Key` 不能重写 `==`，
 * 因此去重一律按 `uri` 比（源码 `extractUniqueKeys` 也是按 uri 去重的）。
 */
export class M3u8Key {
  method: string = '';
  uri: string = '';
  iv: string = '';

  static of(method: string, uri: string, iv: string): M3u8Key {
    const key = new M3u8Key();
    key.method = method;
    key.uri = uri;
    key.iv = iv;
    return key;
  }

  tag(): string {
    return this.iv.length > 0
      ? `#EXT-X-KEY:METHOD=${this.method},URI="${this.uri}",IV=${this.iv}`
      : `#EXT-X-KEY:METHOD=${this.method},URI="${this.uri}"`;
  }
}

export class M3u8Segment {
  duration: number = 0;
  uri: string = '';
  discontinuityGroup: number = 0;
  key: M3u8Key | null = null;

  static of(duration: number, uri: string, discontinuityGroup: number,
    key: M3u8Key | null): M3u8Segment {
    const segment = new M3u8Segment();
    segment.duration = duration;
    segment.uri = uri;
    segment.discontinuityGroup = discontinuityGroup;
    segment.key = key;
    return segment;
  }
}

export class M3u8Variant {
  bandwidth: number = 0;
  resolution: string = '';
  uri: string = '';
}

export class M3u8MasterPlaylist {
  variants: M3u8Variant[] = [];

  /** 码率最高的那一路（源码 `bestVariant`）。 */
  bestVariant(): M3u8Variant | null {
    if (this.variants.length === 0) {
      return null;
    }
    let best: M3u8Variant = this.variants[0];
    for (let i = 1; i < this.variants.length; i++) {
      if (this.variants[i].bandwidth > best.bandwidth) {
        best = this.variants[i];
      }
    }
    return best;
  }
}

export class M3u8MediaPlaylist {
  segments: M3u8Segment[] = [];
  targetDuration: number = 0;
  isVod: boolean = false;
}

export class M3u8ParseResult {
  /** 0 = master，1 = media（源码 `M3u8Type`）。 */
  kind: number = 1;
  master: M3u8MasterPlaylist = new M3u8MasterPlaylist();
  media: M3u8MediaPlaylist = new M3u8MediaPlaylist();

  static master(value: M3u8MasterPlaylist): M3u8ParseResult {
    const result = new M3u8ParseResult();
    result.kind = 0;
    result.master = value;
    return result;
  }

  static media(value: M3u8MediaPlaylist): M3u8ParseResult {
    const result = new M3u8ParseResult();
    result.kind = 1;
    result.media = value;
    return result;
  }
}

export class M3u8Parser {
  /** 是 master（多码率）还是 media（切片清单）。 */
  static detectType(content: string): number {
    return content.indexOf('#EXT-X-STREAM-INF') >= 0 ? 0 : 1;
  }

  /** 相对地址 → 绝对地址（源码 `resolveUrl`）。 */
  static resolveUrl(baseUrl: string, relativeUrl: string): string {
    if (relativeUrl.startsWith('http://') || relativeUrl.startsWith('https://')) {
      return relativeUrl;
    }
    const base: UrlParts | null = UrlParts.parse(baseUrl);
    if (relativeUrl.startsWith('/')) {
      const host: string = base === null ? '' : base.host;
      const scheme: string = base === null ? 'https' : base.scheme;
      return `${scheme}://${host}${relativeUrl}`;
    }
    const lastSlash: number = baseUrl.lastIndexOf('/');
    const basePath: string = lastSlash < 0 ? baseUrl : baseUrl.substring(0, lastSlash + 1);
    return `${basePath}${relativeUrl}`;
  }

  static parseMasterPlaylist(content: string,
    baseUrl: string): M3u8MasterPlaylist {
    const playlist = new M3u8MasterPlaylist();
    const lines: string[] = M3u8Parser.lines(content);
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const prefix: string = '#EXT-X-STREAM-INF:';
      if (!line.startsWith(prefix)) {
        continue;
      }
      const attrs: string = line.substring(prefix.length);
      const variant = new M3u8Variant();
      variant.bandwidth = M3u8Parser.intAfter(attrs, 'BANDWIDTH=');
      variant.resolution = M3u8Parser.textAfter(attrs, 'RESOLUTION=');
      if (i + 1 < lines.length && !lines[i + 1].startsWith('#')) {
        variant.uri = M3u8Parser.resolveUrl(baseUrl, lines[i + 1]);
        playlist.variants.push(variant);
      }
    }
    return playlist;
  }

  static parseMediaPlaylist(content: string, baseUrl: string): M3u8MediaPlaylist {
    const playlist = new M3u8MediaPlaylist();
    const lines: string[] = M3u8Parser.lines(content);
    let hasEndList: boolean = false;
    let isExplicitVod: boolean = false;
    let isLiveEvent: boolean = false;
    let currentDiscontinuityGroup: number = 0;
    let currentKey: M3u8Key | null = null;
    let currentDuration: number = 0;

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      if (line.startsWith('#EXT-X-TARGETDURATION:')) {
        const value: number = Number.parseFloat(
          line.substring('#EXT-X-TARGETDURATION:'.length));
        playlist.targetDuration = Number.isNaN(value) ? 0 : value;
      } else if (line === '#EXT-X-ENDLIST') {
        hasEndList = true;
      } else if (line === '#EXT-X-PLAYLIST-TYPE:VOD') {
        isExplicitVod = true;
      } else if (line === '#EXT-X-PLAYLIST-TYPE:EVENT') {
        isLiveEvent = true;
      } else if (line === '#EXT-X-DISCONTINUITY') {
        currentDiscontinuityGroup += 1;
      } else if (line.startsWith('#EXT-X-KEY:')) {
        currentKey = M3u8Parser.parseKey(line, baseUrl);
      } else if (line.startsWith('#EXTINF:')) {
        const head: string = line.substring('#EXTINF:'.length);
        const comma: number = head.indexOf(',');
        const durationText: string = comma < 0 ? head : head.substring(0, comma);
        const value: number = Number.parseFloat(durationText);
        currentDuration = Number.isNaN(value) ? 0 : value;
      } else if (line.length > 0 && !line.startsWith('#')) {
        playlist.segments.push(M3u8Segment.of(currentDuration,
          M3u8Parser.resolveUrl(baseUrl, line), currentDiscontinuityGroup,
          currentKey));
        currentDuration = 0;
      }
    }

    // VOD 判定与源码一致：有 ENDLIST / 显式 VOD / 「有有限切片且不是 EVENT 直播」。
    // 很多第三方源是 VOD 却不写 ENDLIST，这一条兜底必须有。
    playlist.isVod = hasEndList || isExplicitVod
      || (!isLiveEvent && playlist.segments.length > 0);
    return playlist;
  }

  private static parseKey(line: string, baseUrl: string): M3u8Key | null {
    const attrs: string = line.substring('#EXT-X-KEY:'.length);
    const method: string = M3u8Parser.attr(attrs, 'METHOD=');
    if (method.length === 0 || method === 'NONE') {
      return null;
    }
    const rawUri: string = M3u8Parser.quotedAttr(attrs, 'URI=');
    const uri: string = rawUri.length > 0
      ? M3u8Parser.resolveUrl(baseUrl, rawUri) : '';
    return M3u8Key.of(method, uri, M3u8Parser.attr(attrs, 'IV='));
  }

  /** 去重后的密钥集合（按 uri 去重，与源码 `extractUniqueKeys` 相同）。 */
  static extractUniqueKeys(playlist: M3u8MediaPlaylist): M3u8Key[] {
    const keys: M3u8Key[] = [];
    const seen: string[] = [];
    for (let i = 0; i < playlist.segments.length; i++) {
      const key: M3u8Key | null = playlist.segments[i].key;
      if (key === null || key.uri.length === 0) {
        continue;
      }
      if (seen.indexOf(key.uri) >= 0) {
        continue;
      }
      seen.push(key.uri);
      keys.push(key);
    }
    return keys;
  }

  /**
   * 生成**本地清单**：切片地址改写成 `seg_00000.ts`。
   *
   * `keyUriToLocal` 用于把远端密钥地址换成本地文件（下载加密流时用）。
   */
  static buildLocalM3u8(segments: M3u8Segment[], targetDuration: number,
    keyUriToLocal: Map<string, string>): string {
    let text: string = '';
    text += '#EXTM3U\n';
    text += '#EXT-X-VERSION:3\n';
    text += `#EXT-X-TARGETDURATION:${Math.ceil(targetDuration)}\n`;
    text += '#EXT-X-MEDIA-SEQUENCE:0\n';

    let lastGroup: number = 0;
    let lastKeyUri: string = '';
    for (let i = 0; i < segments.length; i++) {
      const segment: M3u8Segment = segments[i];
      if (segment.discontinuityGroup !== lastGroup && i > 0) {
        text += '#EXT-X-DISCONTINUITY\n';
        lastGroup = segment.discontinuityGroup;
      }
      const key: M3u8Key | null = segment.key;
      const keyUri: string = key === null ? '' : key.uri;
      if (keyUri !== lastKeyUri) {
        if (key === null) {
          text += '#EXT-X-KEY:METHOD=NONE\n';
        } else {
          const local: string | undefined = keyUriToLocal.get(key.uri);
          const uri: string = local === undefined ? key.uri : local;
          text += key.iv.length > 0
            ? `#EXT-X-KEY:METHOD=${key.method},URI="${uri}",IV=${key.iv}\n`
            : `#EXT-X-KEY:METHOD=${key.method},URI="${uri}"\n`;
        }
        lastKeyUri = keyUri;
      }
      text += `#EXTINF:${segment.duration.toFixed(6)},\n`;
      text += `${M3u8Parser.segmentFileName(i)}\n`;
    }
    text += '#EXT-X-ENDLIST\n';
    return text;
  }

  /** 切片文件名：`seg_00000.ts`（5 位补零，与源码一致）。 */
  static segmentFileName(index: number): string {
    const text: string = `${index}`;
    return `seg_${'00000'.substring(text.length)}${text}.ts`;
  }

  /** 判断一个地址指向的是不是 m3u8（源码 `_isM3u8Url`，只看 path 后缀）。 */
  static isM3u8Url(url: string): boolean {
    const parts: UrlParts | null = UrlParts.parse(url);
    const path: string = parts === null ? url : parts.path;
    return path.toLowerCase().endsWith('.m3u8');
  }

  /**
   * 展开嵌套清单（切片的地址本身又是一个 m3u8）。
   *
   * `fetcher` 由调用方给（下载器用带请求头的客户端去取）。
   * 递归深度上限 3，防止互相引用的清单把栈吃光。
   */
  static async resolveNestedSegments(segments: M3u8Segment[],
    fetcher: (url: string) => Promise<string>, maxDepth: number): Promise<M3u8Segment[]> {
    if (maxDepth <= 0) {
      return segments;
    }
    let hasNested: boolean = false;
    for (let i = 0; i < segments.length; i++) {
      if (M3u8Parser.isM3u8Url(segments[i].uri)) {
        hasNested = true;
        break;
      }
    }
    if (!hasNested) {
      return segments;
    }

    const result: M3u8Segment[] = [];
    let groupOffset: number = 0;
    for (let i = 0; i < segments.length; i++) {
      const segment: M3u8Segment = segments[i];
      if (!M3u8Parser.isM3u8Url(segment.uri)) {
        result.push(M3u8Segment.of(segment.duration, segment.uri,
          segment.discontinuityGroup + groupOffset, segment.key));
        continue;
      }
      try {
        const content: string = await fetcher(segment.uri);
        const nested: M3u8MediaPlaylist =
          M3u8Parser.parseMediaPlaylist(content, segment.uri);
        const resolved: M3u8Segment[] = await M3u8Parser.resolveNestedSegments(
          nested.segments, fetcher, maxDepth - 1);
        if (resolved.length === 0) {
          continue;
        }
        let maxNestedGroup: number = 0;
        for (let j = 0; j < resolved.length; j++) {
          if (resolved[j].discontinuityGroup > maxNestedGroup) {
            maxNestedGroup = resolved[j].discontinuityGroup;
          }
        }
        const nestedBase: number = segment.discontinuityGroup + groupOffset;
        for (let j = 0; j < resolved.length; j++) {
          result.push(M3u8Segment.of(resolved[j].duration, resolved[j].uri,
            resolved[j].discontinuityGroup + nestedBase, resolved[j].key));
        }
        groupOffset += maxNestedGroup;
      } catch (error) {
        // 取不到就保留原切片（源码同此做法）
        result.push(M3u8Segment.of(segment.duration, segment.uri,
          segment.discontinuityGroup + groupOffset, segment.key));
      }
    }
    return result;
  }

  // ---------------- 内部 ----------------

  private static lines(content: string): string[] {
    const raw: string[] = content.split('\n');
    const out: string[] = [];
    for (let i = 0; i < raw.length; i++) {
      out.push(raw[i].trim());
    }
    return out;
  }

  /** 取 `KEY=` 后的整数（源码 `BANDWIDTH=(\d+)`）。 */
  private static intAfter(attrs: string, key: string): number {
    const raw: string = M3u8Parser.attr(attrs, key);
    if (raw.length === 0) {
      return 0;
    }
    const value: number = Number.parseInt(raw, 10);
    return Number.isNaN(value) ? 0 : value;
  }

  /** 取 `RESOLUTION=` 后的值（到空格或逗号为止）。 */
  private static textAfter(attrs: string, key: string): string {
    const index: number = attrs.indexOf(key);
    if (index < 0) {
      return '';
    }
    let rest: string = attrs.substring(index + key.length);
    const stop: number = M3u8Parser.firstIndexOfAny(rest, [' ', ',']);
    if (stop >= 0) {
      rest = rest.substring(0, stop);
    }
    return rest;
  }

  /** 取 `KEY=` 后的值（到逗号为止）。 */
  private static attr(attrs: string, key: string): string {
    const index: number = attrs.indexOf(key);
    if (index < 0) {
      return '';
    }
    const rest: string = attrs.substring(index + key.length);
    const comma: number = rest.indexOf(',');
    return comma < 0 ? rest : rest.substring(0, comma);
  }

  /** 取 `KEY="..."` 里的引号内容。 */
  private static quotedAttr(attrs: string, key: string): string {
    const index: number = attrs.indexOf(key);
    if (index < 0) {
      return '';
    }
    const rest: string = attrs.substring(index + key.length);
    const start: number = rest.indexOf('"');
    if (start !== 0) {
      return '';
    }
    const end: number = rest.indexOf('"', 1);
    return end < 0 ? '' : rest.substring(1, end);
  }

  private static firstIndexOfAny(text: string, chars: string[]): number {
    let found: number = -1;
    for (let i = 0; i < chars.length; i++) {
      const at: number = text.indexOf(chars[i]);
      if (at >= 0 && (found < 0 || at < found)) {
        found = at;
      }
    }
    return found;
  }
}
