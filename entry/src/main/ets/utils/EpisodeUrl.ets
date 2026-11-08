/**
 * 集数源站 URL 归一化。
 * 移植自参照实现 `lib/utils/episode_url.dart`。
 *
 * 归一化后的字符串同时充当「身份 key」与「请求 URL」，因此：
 *   - 相对路径基于 baseUrl 补全
 *   - 同站 URL 的协议统一到 baseUrl 的协议（跨站/跨端口不动）
 *   - 去掉 path 多余尾斜杠（根路径除外）、空 query
 *   - 幂等
 */

class ParsedUrl {
  scheme: string = '';
  host: string = '';
  port: number = -1;
  path: string = '';
  query: string = '';
  fragment: string = '';
}

export class EpisodeUrl {
  static normalize(baseUrl: string, raw: string): string {
    const trimmed: string = raw.trim();
    if (trimmed.length === 0) {
      return '';
    }
    const rawParsed: ParsedUrl | null = EpisodeUrl.parse(trimmed);
    const baseParsed: ParsedUrl | null = EpisodeUrl.parse(baseUrl.trim());
    const hasValidBase: boolean = baseParsed !== null && baseParsed.host.length > 0;

    let resolved: ParsedUrl | null = null;
    if (rawParsed !== null && rawParsed.host.length > 0) {
      resolved = rawParsed;
    } else if (hasValidBase) {
      resolved = EpisodeUrl.resolve(baseParsed as ParsedUrl, trimmed);
    }
    if (resolved === null || resolved.host.length === 0) {
      return trimmed;
    }

    // 同站协议统一
    if (hasValidBase) {
      const base: ParsedUrl = baseParsed as ParsedUrl;
      const samePort: boolean = base.port === resolved.port;
      if (EpisodeUrl.isHttp(base.scheme) && EpisodeUrl.isHttp(resolved.scheme) &&
        resolved.scheme !== base.scheme && resolved.host === base.host && samePort) {
        resolved.scheme = base.scheme;
      }
    }

    let path: string = resolved.path;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    let out: string = `${resolved.scheme}://${resolved.host}`;
    if (resolved.port > 0) {
      out += `:${resolved.port}`;
    }
    out += path;
    if (resolved.query.length > 0) {
      out += `?${resolved.query}`;
    }
    if (resolved.fragment.length > 0) {
      out += `#${resolved.fragment}`;
    }
    return out;
  }

  private static isHttp(scheme: string): boolean {
    return scheme === 'http' || scheme === 'https';
  }

  /** 解析绝对 URL；非绝对返回 null。 */
  private static parse(url: string): ParsedUrl | null {
    const schemeEnd: number = url.indexOf('://');
    if (schemeEnd <= 0) {
      return null;
    }
    const parsed = new ParsedUrl();
    parsed.scheme = url.substring(0, schemeEnd).toLowerCase();
    const rest: string = url.substring(schemeEnd + 3);
    let cut: number = rest.length;
    const slash: number = rest.indexOf('/');
    const question: number = rest.indexOf('?');
    const hash: number = rest.indexOf('#');
    if (slash >= 0 && slash < cut) {
      cut = slash;
    }
    if (question >= 0 && question < cut) {
      cut = question;
    }
    if (hash >= 0 && hash < cut) {
      cut = hash;
    }
    let authority: string = rest.substring(0, cut);
    let remainder: string = rest.substring(cut);
    const at: number = authority.lastIndexOf('@');
    if (at >= 0) {
      authority = authority.substring(at + 1);
    }
    const colon: number = authority.lastIndexOf(':');
    if (colon >= 0) {
      const portText: string = authority.substring(colon + 1);
      const port: number = Number.parseInt(portText, 10);
      if (!Number.isNaN(port)) {
        parsed.port = port;
        authority = authority.substring(0, colon);
      }
    }
    parsed.host = authority.toLowerCase();

    const hashIndex: number = remainder.indexOf('#');
    if (hashIndex >= 0) {
      parsed.fragment = remainder.substring(hashIndex + 1);
      remainder = remainder.substring(0, hashIndex);
    }
    const queryIndex: number = remainder.indexOf('?');
    if (queryIndex >= 0) {
      parsed.query = remainder.substring(queryIndex + 1);
      remainder = remainder.substring(0, queryIndex);
    }
    parsed.path = remainder.length === 0 ? '/' : remainder;
    return parsed;
  }

  /** 以 base 解析相对路径。 */
  private static resolve(base: ParsedUrl, reference: string): ParsedUrl | null {
    if (reference.startsWith('//')) {
      return EpisodeUrl.parse(`${base.scheme}:${reference}`);
    }
    const out = new ParsedUrl();
    out.scheme = base.scheme;
    out.host = base.host;
    out.port = base.port;

    let ref: string = reference;
    let hash: string = '';
    const hashIndex: number = ref.indexOf('#');
    if (hashIndex >= 0) {
      hash = ref.substring(hashIndex + 1);
      ref = ref.substring(0, hashIndex);
    }
    let query: string = '';
    const queryIndex: number = ref.indexOf('?');
    if (queryIndex >= 0) {
      query = ref.substring(queryIndex + 1);
      ref = ref.substring(0, queryIndex);
    }
    out.fragment = hash;

    if (ref.length === 0) {
      out.path = base.path;
      out.query = query.length > 0 ? query : base.query;
      return out;
    }
    let path: string;
    if (ref.startsWith('/')) {
      path = ref;
    } else {
      const baseSlash: number = base.path.lastIndexOf('/');
      const prefix: string = baseSlash >= 0 ? base.path.substring(0, baseSlash + 1) : '/';
      path = prefix + ref;
    }
    out.path = EpisodeUrl.removeDotSegments(path);
    out.query = query;
    return out;
  }

  /** 处理 `.` 与 `..` 段。 */
  private static removeDotSegments(path: string): string {
    const segments: string[] = path.split('/');
    const out: string[] = [];
    for (let i = 0; i < segments.length; i++) {
      const segment: string = segments[i];
      if (segment === '.') {
        continue;
      }
      if (segment === '..') {
        if (out.length > 1) {
          out.pop();
        }
        continue;
      }
      out.push(segment);
    }
    const joined: string = out.join('/');
    return joined.length === 0 ? '/' : joined;
  }
}

/** 便捷入口（与源码同名）。 */
export function normalizeEpisodeUrl(baseUrl: string, raw: string): string {
  return EpisodeUrl.normalize(baseUrl, raw);
}
