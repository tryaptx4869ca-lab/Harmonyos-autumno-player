/**
 * 轻量 HTML DOM + 解析器。
 *
 * 为什么自研：参照实现用 `package:html`（html5lib 的 Dart 移植，2.5 万行），
 * 整体移植不现实；而规则引擎真正依赖的只有：
 *   元素树（父子/兄弟）、属性表、元素文本、小写标签名。
 * 因此这里实现一个覆盖真实页面的「HTML5 近似」解析器：
 * void 元素、raw text 元素、注释、实体、常见隐式闭合。
 *
 * 与 html5lib 的差异（已知且可接受）：
 *   - 不做完整插入模式（如表格 foster parenting），只做常见隐式闭合
 *   - `<head>/<body>` 不做严格归属，内容统一进隐式 body
 * 对 `//div[@class=...]` 这类规则没有影响。
 */

/** 节点类型（数字沿用 DOM 约定）。 */
export enum HtmlNodeType {
  element = 1,
  text = 3,
  comment = 8,
  document = 9
}

const VOID_ELEMENTS: string[] = [
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
  'link', 'meta', 'param', 'source', 'track', 'wbr'
];

const RAW_TEXT_ELEMENTS: string[] = ['script', 'style', 'textarea', 'title'];

/** 遇到这些起始标签时自动闭合 <p>。 */
const CLOSES_P: string[] = [
  'address', 'article', 'aside', 'blockquote', 'div', 'dl', 'fieldset',
  'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hr',
  'main', 'nav', 'ol', 'p', 'pre', 'section', 'table', 'ul'
];

/** DOM 节点。 */
export class HtmlNode {
  nodeType: HtmlNodeType;
  /** 元素的小写标签名；非元素为空串。 */
  tagName: string = '';
  /** 属性表（键为小写属性名）。 */
  attrs: Map<string, string> = new Map<string, string>();
  /** 全部子节点（含文本/注释）。 */
  childNodes: HtmlNode[] = [];
  parent: HtmlNode | null = null;
  /** 文本或注释内容。 */
  data: string = '';

  constructor(nodeType: HtmlNodeType) {
    this.nodeType = nodeType;
  }

  get isElement(): boolean {
    return this.nodeType === HtmlNodeType.element;
  }

  /** 元素子节点（对应 `package:html` 的 `node.children`，只含元素）。 */
  children(): HtmlNode[] {
    const out: HtmlNode[] = [];
    for (let i = 0; i < this.childNodes.length; i++) {
      if (this.childNodes[i].isElement) {
        out.push(this.childNodes[i]);
      }
    }
    return out;
  }

  nextElementSibling(): HtmlNode | null {
    const siblings: HtmlNode[] | null =
      this.parent === null ? null : this.parent.childNodes;
    if (siblings === null) {
      return null;
    }
    let seen: boolean = false;
    for (let i = 0; i < siblings.length; i++) {
      const node: HtmlNode = siblings[i];
      if (node === this) {
        seen = true;
        continue;
      }
      if (seen && node.isElement) {
        return node;
      }
    }
    return null;
  }

  previousElementSibling(): HtmlNode | null {
    const siblings: HtmlNode[] | null =
      this.parent === null ? null : this.parent.childNodes;
    if (siblings === null) {
      return null;
    }
    let result: HtmlNode | null = null;
    for (let i = 0; i < siblings.length; i++) {
      const node: HtmlNode = siblings[i];
      if (node === this) {
        return result;
      }
      if (node.isElement) {
        result = node;
      }
    }
    return null;
  }

  /** 元素文本：自身与所有后代的文本拼接（对应 `node.text`）。 */
  textContent(): string {
    if (this.nodeType === HtmlNodeType.text) {
      return this.data;
    }
    if (this.nodeType === HtmlNodeType.comment) {
      return '';
    }
    let out: string = '';
    for (let i = 0; i < this.childNodes.length; i++) {
      out += this.childNodes[i].textContent();
    }
    return out;
  }

  /** 取属性；不存在返回 null（与 Dart 的 `attributes[key]` 一致）。 */
  attr(name: string): string | null {
    const v: string | undefined = this.attrs.get(name.toLowerCase());
    return v === undefined ? null : v;
  }

  /** 序列化（规则引擎取节点片段时用）。 */
  outerHtml(): string {
    if (this.nodeType === HtmlNodeType.text) {
      return escapeHtmlText(this.data);
    }
    if (this.nodeType === HtmlNodeType.comment) {
      return `<!--${this.data}-->`;
    }
    if (this.nodeType === HtmlNodeType.document) {
      let out: string = '';
      for (let i = 0; i < this.childNodes.length; i++) {
        out += this.childNodes[i].outerHtml();
      }
      return out;
    }
    let out: string = `<${this.tagName}`;
    this.attrs.forEach((value: string, key: string) => {
      out += ` ${key}="${escapeHtmlAttr(value)}"`;
    });
    out += '>';
    if (VOID_ELEMENTS.indexOf(this.tagName) >= 0) {
      return out;
    }
    for (let i = 0; i < this.childNodes.length; i++) {
      out += this.childNodes[i].outerHtml();
    }
    return out + `</${this.tagName}>`;
  }
}

let namedEntityCache: Map<string, string> | null = null;

/** 常用命名实体（其余走数字实体）。 */
function namedEntities(): Map<string, string> {
  if (namedEntityCache !== null) {
    return namedEntityCache;
  }
  const map: Map<string, string> = new Map<string, string>();
  const pairs: string[][] = [
    ['amp', '&'], ['lt', '<'], ['gt', '>'], ['quot', '"'], ['apos', "'"],
    ['nbsp', '\u00A0'], ['copy', '\u00A9'], ['reg', '\u00AE'],
    ['hellip', '\u2026'], ['mdash', '\u2014'], ['ndash', '\u2013'],
    ['middot', '\u00B7'], ['ldquo', '\u201C'], ['rdquo', '\u201D'],
    ['lsquo', '\u2018'], ['rsquo', '\u2019'], ['times', '\u00D7'],
    ['divide', '\u00F7'], ['deg', '\u00B0'], ['laquo', '\u00AB'],
    ['raquo', '\u00BB'], ['bull', '\u2022'], ['prime', '\u2032'],
    ['Prime', '\u2033'], ['trade', '\u2122'], ['yen', '\u00A5'],
    ['sect', '\u00A7'], ['para', '\u00B6'], ['dagger', '\u2020'],
    ['Dagger', '\u2021'], ['euro', '\u20AC'], ['pound', '\u00A3'],
    ['cent', '\u00A2'], ['emsp', '\u2003'], ['ensp', '\u2002'],
    ['thinsp', '\u2009'], ['shy', '\u00AD']
  ];
  for (let i = 0; i < pairs.length; i++) {
    map.set(pairs[i][0], pairs[i][1]);
  }
  namedEntityCache = map;
  return map;
}

/** HTML 实体解码。 */
export function decodeEntities(text: string): string {
  if (text.indexOf('&') < 0) {
    return text;
  }
  const entities: Map<string, string> = namedEntities();
  return text.replace(/&(#[xX]?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);?/g,
    (match: string, body: string): string => {
      if (body.charAt(0) === '#') {
        const isHex: boolean = body.charAt(1) === 'x' || body.charAt(1) === 'X';
        const digits: string = isHex ? body.substring(2) : body.substring(1);
        const code: number = Number.parseInt(digits, isHex ? 16 : 10);
        if (Number.isNaN(code) || code <= 0 || code > 0x10FFFF) {
          return match;
        }
        return String.fromCodePoint(code);
      }
      const named: string | undefined = entities.get(body);
      return named === undefined ? match : named;
    });
}

function escapeHtmlText(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function escapeHtmlAttr(text: string): string {
  return escapeHtmlText(text).replace(/"/g, '&quot;');
}

/** HTML 解析器。 */
export class HtmlParser {
  private source: string = '';
  private pos: number = 0;
  private document: HtmlNode = new HtmlNode(HtmlNodeType.document);
  private stack: HtmlNode[] = [];

  static isVoidElement(tag: string): boolean {
    return VOID_ELEMENTS.indexOf(tag) >= 0;
  }

  /**
   * 解析 HTML，返回 `<html>` 元素（对应 `parse(html).documentElement`）。
   * 源码里没有 `<html>` 时，像 html5lib 一样补隐式 `html > body`。
   */
  static parseDocumentElement(html: string): HtmlNode {
    const parser = new HtmlParser();
    parser.source = html;
    parser.pos = 0;
    parser.stack = [parser.document];
    parser.parseNodes();
    return parser.finalize();
  }

  private finalize(): HtmlNode {
    let html: HtmlNode | null = null;
    for (let i = 0; i < this.document.childNodes.length; i++) {
      const node: HtmlNode = this.document.childNodes[i];
      if (node.isElement && node.tagName === 'html') {
        html = node;
        break;
      }
    }
    if (html === null) {
      const implicitHtml = new HtmlNode(HtmlNodeType.element);
      implicitHtml.tagName = 'html';
      implicitHtml.parent = this.document;
      const body = new HtmlNode(HtmlNodeType.element);
      body.tagName = 'body';
      body.parent = implicitHtml;
      const moved: HtmlNode[] = this.document.childNodes;
      this.document.childNodes = [implicitHtml];
      implicitHtml.childNodes = [body];
      body.childNodes = moved;
      for (let i = 0; i < moved.length; i++) {
        moved[i].parent = body;
      }
      return implicitHtml;
    }
    let hasBody: boolean = false;
    for (let i = 0; i < html.childNodes.length; i++) {
      const child: HtmlNode = html.childNodes[i];
      if (child.isElement && child.tagName === 'body') {
        hasBody = true;
        break;
      }
    }
    if (!hasBody) {
      const body = new HtmlNode(HtmlNodeType.element);
      body.tagName = 'body';
      body.parent = html;
      const moved: HtmlNode[] = html.childNodes;
      html.childNodes = [body];
      body.childNodes = moved;
      for (let i = 0; i < moved.length; i++) {
        moved[i].parent = body;
      }
    }
    return html;
  }

  private current(): HtmlNode {
    return this.stack[this.stack.length - 1];
  }

  private append(node: HtmlNode): void {
    const parent: HtmlNode = this.current();
    node.parent = parent;
    parent.childNodes.push(node);
  }

  private parseNodes(): void {
    const len: number = this.source.length;
    while (this.pos < len) {
      const lt: number = this.source.indexOf('<', this.pos);
      if (lt < 0) {
        this.appendText(this.source.substring(this.pos));
        this.pos = len;
        break;
      }
      if (lt > this.pos) {
        this.appendText(this.source.substring(this.pos, lt));
        this.pos = lt;
      }
      if (this.source.startsWith('<!--', this.pos)) {
        this.parseComment();
        continue;
      }
      if (this.source.startsWith('<!', this.pos) ||
        this.source.startsWith('<?', this.pos)) {
        const gt: number = this.source.indexOf('>', this.pos);
        this.pos = gt < 0 ? len : gt + 1;
        continue;
      }
      if (this.source.startsWith('</', this.pos)) {
        this.parseEndTag();
        continue;
      }
      if (!this.parseStartTag()) {
        this.appendText('<');
        this.pos += 1;
      }
    }
  }

  private appendText(text: string): void {
    if (text.length === 0) {
      return;
    }
    const node = new HtmlNode(HtmlNodeType.text);
    node.data = decodeEntities(text);
    this.append(node);
  }

  private parseComment(): void {
    const end: number = this.source.indexOf('-->', this.pos + 4);
    const node = new HtmlNode(HtmlNodeType.comment);
    if (end < 0) {
      node.data = this.source.substring(this.pos + 4);
      this.pos = this.source.length;
    } else {
      node.data = this.source.substring(this.pos + 4, end);
      this.pos = end + 3;
    }
    this.append(node);
  }

  private parseEndTag(): void {
    const gt: number = this.source.indexOf('>', this.pos);
    if (gt < 0) {
      this.pos = this.source.length;
      return;
    }
    const raw: string = this.source.substring(this.pos + 2, gt).trim().toLowerCase();
    const name: string = raw.split(/\s+/)[0];
    this.pos = gt + 1;
    if (name.length === 0) {
      return;
    }
    for (let i = this.stack.length - 1; i > 0; i--) {
      if (this.stack[i].tagName === name) {
        this.stack.length = i;
        return;
      }
    }
  }

  /** 返回 false 表示 `<` 后面不是标签。 */
  private parseStartTag(): boolean {
    const start: number = this.pos + 1;
    const len: number = this.source.length;
    let i: number = start;
    while (i < len) {
      const c: string = this.source.charAt(i);
      if (c === '>' || c === '/' || c === ' ' || c === '\n' ||
        c === '\t' || c === '\r' || c === '\f') {
        break;
      }
      i++;
    }
    const name: string = this.source.substring(start, i).toLowerCase();
    if (name.length === 0 || !/^[a-z][a-z0-9:_-]*$/.test(name)) {
      return false;
    }
    const node = new HtmlNode(HtmlNodeType.element);
    node.tagName = name;

    let selfClosing: boolean = false;
    while (i < len) {
      while (i < len && /\s/.test(this.source.charAt(i))) {
        i++;
      }
      if (i >= len) {
        break;
      }
      const ch: string = this.source.charAt(i);
      if (ch === '>') {
        i++;
        break;
      }
      if (ch === '/') {
        selfClosing = true;
        i++;
        continue;
      }
      const attrStart: number = i;
      while (i < len) {
        const c: string = this.source.charAt(i);
        if (c === '=' || c === '>' || c === '/' || /\s/.test(c)) {
          break;
        }
        i++;
      }
      const attrName: string = this.source.substring(attrStart, i).toLowerCase();
      if (attrName.length === 0) {
        i++;
        continue;
      }
      while (i < len && /\s/.test(this.source.charAt(i))) {
        i++;
      }
      let attrValue: string = '';
      if (i < len && this.source.charAt(i) === '=') {
        i++;
        while (i < len && /\s/.test(this.source.charAt(i))) {
          i++;
        }
        if (i < len) {
          const quote: string = this.source.charAt(i);
          if (quote === '"' || quote === "'") {
            const close: number = this.source.indexOf(quote, i + 1);
            if (close < 0) {
              attrValue = this.source.substring(i + 1);
              i = len;
            } else {
              attrValue = this.source.substring(i + 1, close);
              i = close + 1;
            }
          } else {
            const valueStart: number = i;
            while (i < len) {
              const c: string = this.source.charAt(i);
              if (c === '>' || /\s/.test(c)) {
                break;
              }
              i++;
            }
            attrValue = this.source.substring(valueStart, i);
          }
        }
      }
      if (!node.attrs.has(attrName)) {
        node.attrs.set(attrName, decodeEntities(attrValue));
      }
    }
    this.pos = i;

    this.applyImplicitClose(name);
    this.append(node);

    if (selfClosing || HtmlParser.isVoidElement(name)) {
      return true;
    }

    if (RAW_TEXT_ELEMENTS.indexOf(name) >= 0) {
      const closeTag: string = `</${name}`;
      const close: number = this.source.toLowerCase().indexOf(closeTag, this.pos);
      const textEnd: number = close < 0 ? this.source.length : close;
      const raw: string = this.source.substring(this.pos, textEnd);
      if (raw.length > 0) {
        const textNode = new HtmlNode(HtmlNodeType.text);
        // script/style 内容不做实体解码（与浏览器一致）
        textNode.data = (name === 'script' || name === 'style')
          ? raw : decodeEntities(raw);
        textNode.parent = node;
        node.childNodes.push(textNode);
      }
      if (close < 0) {
        this.pos = this.source.length;
      } else {
        const gt: number = this.source.indexOf('>', close);
        this.pos = gt < 0 ? this.source.length : gt + 1;
      }
      return true;
    }

    this.stack.push(node);
    return true;
  }

  /** 常见隐式闭合（不做完整插入模式）。 */
  private applyImplicitClose(name: string): void {
    if (CLOSES_P.indexOf(name) >= 0 || name === 'p') {
      this.closeIfOpen('p');
    }
    if (name === 'li') {
      this.closeIfOpen('li');
    }
    if (name === 'dt' || name === 'dd') {
      this.closeIfOpen('dt');
      this.closeIfOpen('dd');
    }
    if (name === 'td' || name === 'th') {
      this.closeIfOpen('td');
      this.closeIfOpen('th');
    }
    if (name === 'tr') {
      this.closeIfOpen('tr');
    }
    if (name === 'tbody' || name === 'thead' || name === 'tfoot') {
      this.closeIfOpen('tbody');
      this.closeIfOpen('thead');
      this.closeIfOpen('tfoot');
    }
    if (name === 'option') {
      this.closeIfOpen('option');
    }
    if (name === 'p') {
      this.closeIfOpen('p');
    }
    if (/^h[1-6]$/.test(name)) {
      for (let level = 1; level <= 6; level++) {
        this.closeIfOpen(`h${level}`);
      }
    }
    if (name === 'a' || name === 'button' || name === 'form') {
      this.closeIfOpen(name);
    }
  }

  private closeIfOpen(tag: string): void {
    for (let i = this.stack.length - 1; i > 0; i--) {
      if (this.stack[i].tagName === tag) {
        this.stack.length = i;
        return;
      }
    }
  }
}
