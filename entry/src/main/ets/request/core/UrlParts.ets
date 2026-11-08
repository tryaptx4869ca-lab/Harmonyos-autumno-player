/**
 * 轻量 URL 拆解。
 *
 * ArkTS 的 URL 类在部分接口上不可用/行为不一致，而我们只需要
 * 「scheme / host / path / query」四段，因此这里自己解析——
 * 与参照实现里 `Uri.parse` 用到的字段一一对应。
 */
export class UrlParts {
  scheme: string = '';
  host: string = '';
  path: string = '';
  query: string = '';

  get hasQuery(): boolean {
    return this.query.length > 0;
  }

  /** 带 scheme 的完整地址。 */
  toString(): string {
    return `${this.scheme}://${this.host}${this.path}` +
      (this.hasQuery ? `?${this.query}` : '');
  }

  /** `host + path [+ ?query]`，镜像改写用的相对形式。 */
  hostPathQuery(): string {
    return this.host + this.path + (this.hasQuery ? `?${this.query}` : '');
  }

  static parse(url: string): UrlParts | null {
    const schemeEnd: number = url.indexOf('://');
    if (schemeEnd <= 0) {
      return null;
    }
    const parts = new UrlParts();
    parts.scheme = url.substring(0, schemeEnd).toLowerCase();
    const rest: string = url.substring(schemeEnd + 3);
    const slash: number = rest.indexOf('/');
    if (slash < 0) {
      parts.host = rest;
      return parts;
    }
    parts.host = rest.substring(0, slash);
    let pathAndQuery: string = rest.substring(slash);
    const q: number = pathAndQuery.indexOf('?');
    if (q >= 0) {
      parts.query = pathAndQuery.substring(q + 1);
      pathAndQuery = pathAndQuery.substring(0, q);
    }
    parts.path = pathAndQuery;
    return parts;
  }
}
