import { HtmlNode } from './HtmlDom';

/**
 * 简化版 XPath 引擎。
 *
 * 逐行等价移植参照实现所用的 `xpath_selector` 3.0.2 +
 * `xpath_selector_html_parser` 3.0.1（合计约 1100 行）。
 *
 * 它**不是**完整 XPath 1.0，而是规则实际用到的那一部分：
 *   - 路径：`//a/b`、`/a`、多个路径用 `|` 并联
 *   - 轴：child（默认）/ self / parent / ancestor(-or-self) /
 *         descendant(-or-self) / following(-sibling) / preceding-sibling / attribute
 *   - 节点测试：`*`、标签名、`node()`、`text()`、`string()`、`name()`…
 *   - 谓词：`[1]`、`[last()]`、`[last()-1]`、`[position()<3]`、
 *          `[@a='v']`、`[contains(@a,'v')]`、`[starts-with(...)]`、
 *          `[ends-with(...)]`、`[child>1]`，以及 `and`/`or`/`not` 组合
 *   - 取属性：路径末尾的 `@attr`
 *
 * 为什么必须照抄而不是换成浏览器 XPath：规则是按这套语义写的，
 * 位置谓词（`[1]`、`[last()]`）在不同实现下的作用域不同，换实现会改变结果。
 */

// ---------------------------------------------------------------- 正则

const PREDICATE_LAST = /last\(\s*\)/;
const PREDICATE_INT = /^(?<num>\d+)$/;
const PREDICATE_CHILD = /(?<child>\w+)\s*(?<op><|<=|>|>=)\s*(?<num>\d+)/;
const SIMPLE_POSITION = /position\(\s*\)\s*(?<op><|<=|>|>=)\s*(?<num>\d+)/;
const SIMPLE_LAST = /last\(\s*\)\s*(?<op>\+|-|\*|\/%\^)\s*(?<num>\d+)/;
const SIMPLE_SINGLE_LAST = /last\(\s*\)/;
const PREDICATE_EQUAL =
  /(?<not>(?:not)?)\s*\(?\s*(?<fn>@?[\w-]+\(?\s*\)?)\s*(?<op>=|~=|\|=|\^=|\$=|\*=|!=)\s*['"](?<value>.+?)['"]\)?/;
const FUNCTION_PREDICATE =
  /(?<not>(?:not)?)\s*\(?\s*(?<fn>[\w-]{4,})\s*\(\s*(?<param1>.+?)\s*,\s*['"](?<param2>.+?)\s*['"]\s*\)\)?/;
const PREDICATE_REG = /\[(?<predicate>.+?)\]/g;
const XPATH_GROUP = /\/{0,2}@?[\w*-]+:{0,2}[\*\w]*(?:\[.+?\])*(?:\(\))?/g;

/**
 * 取命名捕获组。
 *
 * ArkTS 不允许对字段做下标访问（`arkts-no-props-by-index`），
 * 所以 `match.groups['name']` 统一走本函数；缺失时返回空串。
 */
function groupOf(match: RegExpMatchArray | RegExpExecArray, name: string): string {
  const groups: Record<string, string> | undefined = match.groups;
  if (groups === undefined) {
    return '';
  }
  const value: string | undefined = groups[name];
  return value === undefined ? '' : value;
}
// ---------------------------------------------------------------- 选择器模型

export enum SelectorType {
  descendant = 0,
  self = 1
}

export enum AxesAxis {
  ancestor = 0,
  ancestorOrSelf = 1,
  child = 2,
  descendant = 3,
  descendantOrSelf = 4,
  following = 5,
  followingSibling = 6,
  parent = 7,
  precedingSibling = 8,
  self = 9,
  attribute = 10
}

export class SelectorAxes {
  axis: AxesAxis | undefined;
  nodeTest: string;
  predicate: string[];

  constructor(axis: AxesAxis | undefined, nodeTest: string, predicate: string[]) {
    this.axis = axis;
    this.nodeTest = nodeTest;
    this.predicate = predicate;
  }

  static createAxis(axis: string): AxesAxis {
    switch (axis) {
      case 'ancestor':
        return AxesAxis.ancestor;
      case 'ancestor-or-self':
        return AxesAxis.ancestorOrSelf;
      case 'child':
        return AxesAxis.child;
      case 'descendant':
        return AxesAxis.descendant;
      case 'descendant-or-self':
        return AxesAxis.descendantOrSelf;
      case 'following':
        return AxesAxis.following;
      case 'following-sibling':
        return AxesAxis.followingSibling;
      case 'parent':
        return AxesAxis.parent;
      case 'preceding-sibling':
        return AxesAxis.precedingSibling;
      case 'self':
        return AxesAxis.self;
      case 'attribute':
        return AxesAxis.attribute;
      default:
        throw new Error(`not support axis: ${axis}`);
    }
  }
}

export class Selector {
  selectorType: SelectorType;
  axes: SelectorAxes;
  attr: string | undefined;
  fn: string | undefined;

  constructor(selectorType: SelectorType, axes: SelectorAxes,
    attr: string | undefined, fn: string | undefined) {
    this.selectorType = selectorType;
    this.axes = axes;
    this.attr = attr;
    this.fn = fn;
  }
}

// ---------------------------------------------------------------- 解析

/** 解析 XPath 表达式为若干选择器组（`|` 并联）。 */
export function parseSelectGroup(xpath: string): Selector[][] {
  const groups: Selector[][] = [];
  const parts: string[] = xpath.split('|');
  for (let g = 0; g < parts.length; g++) {
    const path: string = parts[g].trim();
    const list: Selector[] = [];
    const matches: RegExpMatchArray[] = Array.from(path.matchAll(XPATH_GROUP));
    for (let i = 0; i < matches.length; i++) {
      const text: string = matches[i][0].trim();
      if (text.length > 0) {
        list.push(parseSelector(text));
      }
    }
    groups.push(list);
  }
  return groups;
}

function parseSelector(input: string): Selector {
  let source: string;
  let selectorType: SelectorType;
  if (input.startsWith('//')) {
    selectorType = SelectorType.descendant;
    source = input.substring(2);
  } else if (input.startsWith('/')) {
    selectorType = SelectorType.self;
    source = input.substring(1);
  } else {
    throw new Error(`'${input}' is not a valid xpath query string`);
  }

  const simple: Selector | null = parseSimpleSelector(selectorType, source);
  if (simple !== null) {
    return simple;
  }

  let axis: AxesAxis | undefined = undefined;
  let withoutAxis: string;
  if (source.indexOf('::') >= 0) {
    const pattern: string[] = source.split('::');
    if (pattern.length > 2) {
      throw new Error('Not support multiple axis');
    }
    axis = SelectorAxes.createAxis(pattern[0].trim());
    withoutAxis = pattern[pattern.length - 1].trim();
  } else {
    withoutAxis = source;
  }

  let nodeTest: string = withoutAxis;
  const predicates: string[] = [];
  const regex: RegExp = new RegExp(PREDICATE_REG.source, 'g');
  let match: RegExpExecArray | null = regex.exec(withoutAxis);
  while (match !== null) {
    const whole: string = match[0];
    if (whole.length > 0) {
      nodeTest = nodeTest.split(whole).join('');
    }
    const inner: string | undefined = match.groups === undefined
      ? undefined : groupOf(match, 'predicate');
    if (inner !== undefined) {
      predicates.push(inner);
    }
    match = regex.exec(withoutAxis);
  }

  if (nodeTest === '.') {
    axis = AxesAxis.self;
    nodeTest = '*';
  } else if (nodeTest === '..') {
    axis = AxesAxis.parent;
    nodeTest = '*';
  }

  return new Selector(selectorType,
    new SelectorAxes(axis, nodeTest, predicates), undefined, undefined);
}

function parseSimpleSelector(selectorType: SelectorType, source: string): Selector | null {
  if (source.startsWith('@')) {
    return new Selector(selectorType,
      new SelectorAxes(AxesAxis.self, '*', []), source.substring(1), undefined);
  }
  if (source === '..') {
    return new Selector(selectorType,
      new SelectorAxes(AxesAxis.parent, '*', []), undefined, undefined);
  }
  if (source === '.') {
    return new Selector(selectorType,
      new SelectorAxes(AxesAxis.self, '*', []), undefined, undefined);
  }
  if (source === 'node()') {
    return new Selector(selectorType,
      new SelectorAxes(AxesAxis.child, 'node()', []), undefined, undefined);
  }
  const fn: RegExpMatchArray | null = source.match(/^\w*\(\s*\)$/);
  if (fn !== null) {
    return new Selector(selectorType,
      new SelectorAxes(AxesAxis.self, '*', []), undefined, fn[0]);
  }
  return null;
}

/** 取节点函数值（text()/string()/name()/local-name()/…）。 */
export function elementFunction(node: HtmlNode, fn: string): string | null {
  if (fn.startsWith('@')) {
    return node.attr(fn.substring(1));
  }
  switch (fn) {
    case 'text()':
    case 'string()':
      return node.textContent();
    case 'name()':
    case 'qualified()':
      return node.isElement ? node.tagName : null;
    case 'local-name()':
      return node.isElement ? node.tagName : null;
    case 'namespace()':
    case 'prefix()':
      // 参照实现的 name 只带 localName，命名空间恒为空
      return null;
    default:
      throw new Error(`Unsupported function: ${fn}`);
  }
}

/** 路径末尾是 `@attr` 或函数时，把结果作为属性值输出。 */
export function parseAttr(selectorList: Selector[], elements: HtmlNode[]): (string | null)[] {
  const result: (string | null)[] = [];
  if (selectorList.length === 0) {
    return result;
  }
  const last: Selector = selectorList[selectorList.length - 1];
  for (let i = 0; i < elements.length; i++) {
    const element: HtmlNode = elements[i];
    if (last.attr !== undefined) {
      if (last.attr === '*') {
        element.attrs.forEach((value: string) => result.push(value));
      } else {
        result.push(element.attr(last.attr));
      }
    } else if (last.fn !== undefined) {
      result.push(elementFunction(element, last.fn));
    } else if (last.axes.axis === AxesAxis.attribute) {
      if (last.axes.nodeTest === '*') {
        element.attrs.forEach((value: string) => result.push(value));
      } else {
        result.push(element.attr(last.axes.nodeTest));
      }
    }
  }
  return result;
}

// ---------------------------------------------------------------- 轴

function top(node: HtmlNode): HtmlNode {
  let current: HtmlNode = node;
  while (current.parent !== null) {
    current = current.parent;
  }
  return current;
}

function ancestor(node: HtmlNode): HtmlNode[] {
  const result: HtmlNode[] = [];
  let current: HtmlNode | null = node.parent;
  while (current !== null) {
    if (current.isElement) {
      result.push(current);
    }
    current = current.parent;
  }
  return result;
}

function descendant(node: HtmlNode): HtmlNode[] {
  const result: HtmlNode[] = [];
  for (let i = 0; i < node.childNodes.length; i++) {
    const child: HtmlNode = node.childNodes[i];
    result.push(child);
    const nested: HtmlNode[] = descendant(child);
    for (let j = 0; j < nested.length; j++) {
      result.push(nested[j]);
    }
  }
  return result;
}

function followingSibling(node: HtmlNode): HtmlNode[] {
  const result: HtmlNode[] = [];
  let current: HtmlNode | null = node.nextElementSibling();
  while (current !== null) {
    result.push(current);
    current = current.nextElementSibling();
  }
  return result;
}

function precedingSibling(node: HtmlNode): HtmlNode[] {
  const result: HtmlNode[] = [];
  let current: HtmlNode | null = node.previousElementSibling();
  while (current !== null) {
    result.push(current);
    current = current.previousElementSibling();
  }
  return result;
}

/** 当前节点之后、文档序中出现的全部节点。 */
function following(root: HtmlNode, target: HtmlNode): HtmlNode[] {
  const result: HtmlNode[] = [];
  let found: boolean = false;
  const walk = (parent: HtmlNode): void => {
    for (let i = 0; i < parent.childNodes.length; i++) {
      const child: HtmlNode = parent.childNodes[i];
      if (child === target) {
        found = true;
      }
      if (found) {
        result.push(child);
      }
      walk(child);
    }
  };
  walk(root);
  return result;
}

// ---------------------------------------------------------------- 求值

function addIfNotExist(list: HtmlNode[], node: HtmlNode): void {
  if (list.indexOf(node) < 0) {
    list.push(node);
  }
}

function addAllIfNotExist(list: HtmlNode[], nodes: HtmlNode[]): void {
  for (let i = 0; i < nodes.length; i++) {
    addIfNotExist(list, nodes[i]);
  }
}

export function execute(selectorList: Selector[], element: HtmlNode): HtmlNode[] {
  let tmp: HtmlNode[] = [element];
  for (let s = 0; s < selectorList.length; s++) {
    const selector: Selector = selectorList[s];
    const rootMatch: HtmlNode[] = [];
    for (let e = 0; e < tmp.length; e++) {
      const seed: HtmlNode = tmp[e];
      const pathNodes: HtmlNode[] = [];
      if (selector.selectorType === SelectorType.descendant) {
        addIfNotExist(pathNodes, seed);
        addAllIfNotExist(pathNodes, descendant(seed));
      } else {
        addIfNotExist(pathNodes, seed);
      }

      const selectorMatch: HtmlNode[] = [];
      for (let p = 0; p < pathNodes.length; p++) {
        const axisNodes: HtmlNode[] = matchAxis(selector, pathNodes[p]);

        // 节点测试
        const remove: number[] = [];
        for (let i = 0; i < axisNodes.length; i++) {
          if (!matchSelector(selector, axisNodes[i])) {
            remove.push(i);
          }
        }
        removeDescending(axisNodes, remove);

        // 谓词
        for (let pi = 0; pi < selector.axes.predicate.length; pi++) {
          const predicate: string = selector.axes.predicate[pi];
          const removeIdx: number[] = [];
          for (let i = 0; i < axisNodes.length; i++) {
            if (!matchPredicates(predicate, axisNodes[i], i, axisNodes.length)) {
              removeIdx.push(i);
            }
          }
          removeDescending(axisNodes, removeIdx);
        }

        addAllIfNotExist(selectorMatch, axisNodes);
      }
      addAllIfNotExist(rootMatch, selectorMatch);
    }
    tmp = rootMatch;
  }
  return tmp;
}

function removeDescending(list: HtmlNode[], indexes: number[]): void {
  for (let i = indexes.length - 1; i >= 0; i--) {
    list.splice(indexes[i], 1);
  }
}

function matchAxis(selector: Selector, node: HtmlNode): HtmlNode[] {
  const out: HtmlNode[] = [];
  const axis: AxesAxis | undefined = selector.axes.axis;
  if (axis === undefined) {
    return node.children();
  }
  switch (axis) {
    case AxesAxis.child:
      return node.children();
    case AxesAxis.ancestor:
      addAllIfNotExist(out, ancestor(node));
      return out;
    case AxesAxis.ancestorOrSelf:
      addIfNotExist(out, node);
      addAllIfNotExist(out, ancestor(node));
      return out;
    case AxesAxis.descendant:
      addAllIfNotExist(out, descendant(node));
      return out;
    case AxesAxis.descendantOrSelf:
      addIfNotExist(out, node);
      addAllIfNotExist(out, descendant(node));
      return out;
    case AxesAxis.following:
      addAllIfNotExist(out, following(top(node), node));
      return out;
    case AxesAxis.parent:
      if (node.parent !== null) {
        out.push(node.parent);
      }
      return out;
    case AxesAxis.followingSibling:
      addAllIfNotExist(out, followingSibling(node));
      return out;
    case AxesAxis.precedingSibling:
      addAllIfNotExist(out, precedingSibling(node));
      return out;
    case AxesAxis.attribute:
    case AxesAxis.self:
      addIfNotExist(out, node);
      return out;
    default:
      return out;
  }
}

function matchSelector(selector: Selector, element: HtmlNode): boolean {
  if (selector.attr !== undefined) {
    return true;
  }
  if (selector.axes.axis === AxesAxis.attribute) {
    return true;
  }
  const nodeTest: string = selector.axes.nodeTest;
  if (nodeTest !== 'node()') {
    if (!element.isElement) {
      return false;
    }
    if (nodeTest !== '*' && element.tagName !== nodeTest) {
      return false;
    }
  }
  return true;
}

function matchPredicates(predicate: string, element: HtmlNode,
  position: number, length: number): boolean {
  let expr: string = predicate;
  expr = expr.split(' and ').join(' && ');
  expr = expr.split(' or ').join(' || ');
  expr = expr.split(' div ').join(' / ');
  expr = expr.split(' mod ').join(' % ');

  if (expr.indexOf(' && ') >= 0 || expr.indexOf(' || ') >= 0) {
    return multipleCompare(expr, element, position, length);
  }
  if (PREDICATE_LAST.test(expr) || PREDICATE_INT.test(expr)) {
    return singlePosition(expr, position, length);
  }
  return singleCompare(expr, element, position, length);
}

function singlePosition(predicate: string, position: number, length: number): boolean {
  const lastReg: RegExpMatchArray | null = predicate.match(SIMPLE_LAST);
  if (lastReg !== null && lastReg.groups !== undefined) {
    const num: number = Number.parseInt(groupOf(lastReg, 'num'), 10);
    const op: string = groupOf(lastReg, 'op');
    return opNum(length, num, op) === position + 1;
  }
  if (SIMPLE_SINGLE_LAST.test(predicate)) {
    return length === position + 1;
  }
  const indexReg: RegExpMatchArray | null = predicate.match(PREDICATE_INT);
  if (indexReg !== null && indexReg.groups !== undefined) {
    const num: number = Number.parseInt(groupOf(indexReg, 'num'), 10);
    return num === position + 1;
  }
  throw new Error(`Unsupported predicate: ${predicate}`);
}

function multipleCompare(predicate: string, element: HtmlNode,
  position: number, length: number): boolean {
  let expression: string = predicate;

  const positionRegs: RegExpMatchArray[] =
    Array.from(predicate.matchAll(new RegExp(SIMPLE_POSITION.source, 'g')));
  for (let i = 0; i < positionRegs.length; i++) {
    const reg: RegExpMatchArray = positionRegs[i];
    const result: boolean = positionMatch(position, reg);
    expression = expression.split(reg[0]).join(result ? 'true' : 'false');
  }

  const equalRegs: RegExpMatchArray[] =
    Array.from(predicate.matchAll(new RegExp(PREDICATE_EQUAL.source, 'g')));
  for (let i = 0; i < equalRegs.length; i++) {
    const reg: RegExpMatchArray = equalRegs[i];
    const result: boolean = equalMatch(element, reg);
    expression = expression.split(reg[0]).join(result ? 'true' : 'false');
  }

  const childRegs: RegExpMatchArray[] =
    Array.from(predicate.matchAll(new RegExp(PREDICATE_CHILD.source, 'g')));
  for (let i = 0; i < childRegs.length; i++) {
    const reg: RegExpMatchArray = childRegs[i];
    const result: boolean = childMatch(element, reg);
    expression = expression.split(reg[0]).join(result ? 'true' : 'false');
  }

  const fnRegs: RegExpMatchArray[] =
    Array.from(predicate.matchAll(new RegExp(FUNCTION_PREDICATE.source, 'g')));
  for (let i = 0; i < fnRegs.length; i++) {
    const reg: RegExpMatchArray = fnRegs[i];
    const result: boolean = functionMatch(element, reg);
    expression = expression.split(reg[0]).join(result ? 'true' : 'false');
  }

  return evalBoolean(expression);
}

function singleCompare(predicate: string, element: HtmlNode,
  position: number, length: number): boolean {
  const positionReg: RegExpMatchArray | null = predicate.match(SIMPLE_POSITION);
  if (positionReg !== null) {
    return positionMatch(position, positionReg);
  }
  const attrReg: RegExpMatchArray | null = predicate.match(PREDICATE_EQUAL);
  if (attrReg !== null) {
    return equalMatch(element, attrReg);
  }
  const childReg: RegExpMatchArray | null = predicate.match(PREDICATE_CHILD);
  if (childReg !== null) {
    return childMatch(element, childReg);
  }
  const fnReg: RegExpMatchArray | null = predicate.match(FUNCTION_PREDICATE);
  if (fnReg !== null) {
    return functionMatch(element, fnReg);
  }
  throw new Error(`Unsupported predicate: ${predicate}`);
}

function positionMatch(position: number, reg: RegExpMatchArray): boolean {
  if (reg.groups === undefined) {
    return false;
  }
  const op: string = groupOf(reg, 'op');
  const num: number = Number.parseInt(groupOf(reg, 'num'), 10);
  return opCompare(position + 1, num, op);
}

function equalMatch(node: HtmlNode, reg: RegExpMatchArray): boolean {
  if (reg.groups === undefined) {
    return false;
  }
  const key: string = groupOf(reg, 'fn').split(' ').join('');
  const rightValue: string = groupOf(reg, 'value');
  const op: string = groupOf(reg, 'op');
  const isNot: boolean = groupOf(reg, 'not') === 'not';
  const leftValue: string | null = elementFunction(node, key);
  if (leftValue === null) {
    return false;
  }
  const value: boolean = opString(leftValue, rightValue, op);
  return isNot ? !value : value;
}

function childMatch(element: HtmlNode, reg: RegExpMatchArray): boolean {
  if (reg.groups === undefined) {
    return false;
  }
  const childName: string = groupOf(reg, 'child');
  const op: string = groupOf(reg, 'op');
  const num: number = Number.parseInt(groupOf(reg, 'num'), 10);
  const children: HtmlNode[] = element.children();
  let childValue: number | null = null;
  for (let i = 0; i < children.length; i++) {
    const child: HtmlNode = children[i];
    if (child.isElement && child.tagName === childName) {
      const parsed: number = Number.parseInt(child.textContent().trim(), 10);
      if (!Number.isNaN(parsed)) {
        childValue = parsed;
        break;
      }
    }
  }
  if (childValue === null) {
    return false;
  }
  return opCompare(childValue, num, op);
}

function functionMatch(node: HtmlNode, reg: RegExpMatchArray): boolean {
  if (reg.groups === undefined) {
    return false;
  }
  const isNot: boolean = groupOf(reg, 'not') === 'not';
  const fn: string = groupOf(reg, 'fn').toLowerCase().trim();
  const param1: string = groupOf(reg, 'param1').toLowerCase().trim();
  const param2: string = groupOf(reg, 'param2');
  const leftValue: string | null = elementFunction(node, param1);
  if (leftValue === null) {
    return false;
  }
  let value: boolean;
  if (fn === 'contains') {
    value = leftValue.indexOf(param2) >= 0;
  } else if (fn === 'starts-with') {
    value = leftValue.startsWith(param2);
  } else if (fn === 'ends-with') {
    value = leftValue.endsWith(param2);
  } else {
    throw new Error(`UnSupport ${fn}`);
  }
  return isNot ? !value : value;
}

// ---------------------------------------------------------------- 布尔表达式

/**
 * 求值 `true/false/&&/||/!/()`。
 *
 * 参照实现用的是 `expressions` 包；比较操作在调用前已被替换成
 * true/false 字面量，所以这里只需要处理布尔运算即可，语义等价。
 */
function evalBoolean(expression: string): boolean {
  const parser = new BooleanExpressionParser(expression);
  const value: boolean = parser.parseOr();
  parser.skipSpaces();
  if (!parser.atEnd()) {
    throw new Error(`Expression parse error, raw: ${expression}`);
  }
  return value;
}

class BooleanExpressionParser {
  private text: string;
  private pos: number = 0;

  constructor(text: string) {
    this.text = text;
  }

  atEnd(): boolean {
    return this.pos >= this.text.length;
  }

  skipSpaces(): void {
    while (this.pos < this.text.length && /\s/.test(this.text.charAt(this.pos))) {
      this.pos++;
    }
  }

  parseOr(): boolean {
    let value: boolean = this.parseAnd();
    while (true) {
      this.skipSpaces();
      if (this.text.startsWith('||', this.pos)) {
        this.pos += 2;
        const right: boolean = this.parseAnd();
        value = value || right;
      } else {
        return value;
      }
    }
  }

  private parseAnd(): boolean {
    let value: boolean = this.parseUnary();
    while (true) {
      this.skipSpaces();
      if (this.text.startsWith('&&', this.pos)) {
        this.pos += 2;
        const right: boolean = this.parseUnary();
        value = value && right;
      } else {
        return value;
      }
    }
  }

  private parseUnary(): boolean {
    this.skipSpaces();
    if (this.text.charAt(this.pos) === '!') {
      this.pos++;
      return !this.parseUnary();
    }
    return this.parsePrimary();
  }

  private parsePrimary(): boolean {
    this.skipSpaces();
    if (this.text.charAt(this.pos) === '(') {
      this.pos++;
      const value: boolean = this.parseOr();
      this.skipSpaces();
      if (this.text.charAt(this.pos) !== ')') {
        throw new Error(`Expression parse error: ${this.text}`);
      }
      this.pos++;
      return value;
    }
    if (this.text.startsWith('true', this.pos)) {
      this.pos += 4;
      return true;
    }
    if (this.text.startsWith('false', this.pos)) {
      this.pos += 5;
      return false;
    }
    throw new Error(`Expression parse error: ${this.text}`);
  }
}

// ---------------------------------------------------------------- 运算符

function opNum(a: number, b: number, op: string): number {
  switch (op) {
    case '+':
      return a + b;
    case '-':
      return a - b;
    case '*':
      return a * b;
    case '/':
      return Math.trunc(a / b);
    case '%':
      return a % b;
    default:
      throw new Error(`Unknown operator: ${op}`);
  }
}

function opCompare(a: number, b: number, op: string): boolean {
  switch (op) {
    case '<':
      return a < b;
    case '<=':
      return a <= b;
    case '>':
      return a > b;
    case '>=':
      return a >= b;
    case '==':
    case '=':
      return a === b;
    case '!=':
      return a !== b;
    default:
      throw new Error(`Unknown operator: ${op}`);
  }
}

function opString(attr: string, value: string, op: string): boolean {
  switch (op) {
    case '=':
      return attr === value;
    case '!=':
      return attr !== value;
    case '~=':
      return attr.split(' ').indexOf(value) >= 0;
    case '*=':
      return attr.indexOf(value) >= 0;
    case '^=':
      return attr.startsWith(value);
    case '$=':
      return attr.endsWith(value);
    default:
      throw new Error(`Unknown operator: ${op}`);
  }
}

// ---------------------------------------------------------------- 对外接口

/** 查询结果（对应 `XPathResult`）。 */
export class XPathResult {
  readonly nodes: HtmlNode[];
  readonly attrs: (string | null)[];

  constructor(nodes: HtmlNode[], attrs: (string | null)[]) {
    this.nodes = nodes;
    this.attrs = attrs;
  }

  /** 第一个节点。 */
  node(): HtmlNode | null {
    return this.nodes.length > 0 ? this.nodes[0] : null;
  }

  /** 第一个非空属性/函数值。 */
  attr(): string | null {
    for (let i = 0; i < this.attrs.length; i++) {
      if (this.attrs[i] !== null) {
        return this.attrs[i];
      }
    }
    return null;
  }
}

/** XPath 查询入口。 */
export class XPath {
  /**
   * 在 `root` 上求值 `xpath`。
   * 对应 `HtmlXPath.node(root).query(xpath)`。
   */
  static query(root: HtmlNode, xpath: string): XPathResult {
    const result: HtmlNode[] = [];
    const resultAttrs: (string | null)[] = [];
    const groups: Selector[][] = parseSelectGroup(xpath);
    for (let g = 0; g < groups.length; g++) {
      const group: Selector[] = groups[g];
      const selected: HtmlNode[] = [];
      const executed: HtmlNode[] = execute(group, root);
      for (let i = 0; i < executed.length; i++) {
        if (result.indexOf(executed[i]) < 0 && selected.indexOf(executed[i]) < 0) {
          selected.push(executed[i]);
        }
      }
      for (let i = 0; i < selected.length; i++) {
        result.push(selected[i]);
      }
      const attrs: (string | null)[] = parseAttr(group, selected);
      for (let i = 0; i < attrs.length; i++) {
        resultAttrs.push(attrs[i]);
      }
    }
    return new XPathResult(result, resultAttrs);
  }

  /** 便捷方法：取选中节点。 */
  static nodes(root: HtmlNode, xpath: string): HtmlNode[] {
    return XPath.query(root, xpath).nodes;
  }

  /** 便捷方法：取第一个节点。 */
  static first(root: HtmlNode, xpath: string): HtmlNode | null {
    return XPath.query(root, xpath).node();
  }
}
