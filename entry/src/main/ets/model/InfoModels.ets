import { BangumiItem, parseBangumiItem } from './BangumiItem';
import { JsonUtils } from './JsonUtils';

/**
 * 详情页的附属模型。
 *
 * 逐字段移植自参照实现：
 *   - `lib/modules/bangumi/bangumi_relation.dart`（含关系链遍历）
 *   - `lib/modules/characters/character_item.dart` + `actor_item.dart`
 *   - `lib/modules/staff/staff_item.dart`
 */

/** 角色对应的声优（`actor_item.dart`）。 */
export class ActorItem {
  id: number = 0;
  type: number = 0;
  name: string = '';
  /** `images.grid`，角色卡左侧头像用。 */
  gridImage: string = '';

  static fromJson(json: Record<string, Object>): ActorItem {
    const item = new ActorItem();
    item.id = JsonUtils.intOf(json, 'id');
    item.type = JsonUtils.intOf(json, 'type');
    item.name = JsonUtils.str(json, 'name');
    const images: Record<string, Object> | null = JsonUtils.obj(json, 'images');
    if (images !== null) {
      item.gridImage = JsonUtils.str(images, 'grid');
    }
    return item;
  }
}

/** 角色条目（`character_item.dart`）。 */
export class CharacterItem {
  id: number = 0;
  type: number = 0;
  name: string = '';
  /** 与当前条目的关系：主角 / 配角 / 客串 …（缺省「未知」）。 */
  relation: string = '未知';
  /** `images.grid`。 */
  gridImage: string = '';
  actorList: ActorItem[] = [];

  static fromJson(json: Record<string, Object>): CharacterItem {
    const item = new CharacterItem();
    item.id = JsonUtils.intOf(json, 'id');
    item.type = JsonUtils.intOf(json, 'type');
    item.name = JsonUtils.str(json, 'name');
    const relation: string = JsonUtils.str(json, 'relation');
    item.relation = relation.length > 0 ? relation : '未知';
    const images: Record<string, Object> | null = JsonUtils.obj(json, 'images');
    if (images !== null) {
      item.gridImage = JsonUtils.str(images, 'grid');
    }
    const actors: Object[] = JsonUtils.arr(json, 'actors');
    for (let i = 0; i < actors.length; i++) {
      const rec: Record<string, Object> | null = JsonUtils.asObj(actors[i]);
      if (rec !== null) {
        item.actorList.push(ActorItem.fromJson(rec));
      }
    }
    return item;
  }
}

/**
 * 角色资料的一项（`character_full_item.dart` 的 `CharacterInfoField`）。
 *
 * Bangumi 的 infobox 是「一个 key 对多个 value」，解析时已经拼成一个字符串
 * （多值用 ` / ` 连接，带子标签的写成 `标签：值`）。
 */
export class CharacterInfoField {
  key: string = '';
  value: string = '';

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }
}

/**
 * 角色详情（`character_full_item.dart` 的 `CharacterFullItem`）。
 *
 * 解析规则逐条对齐源码：
 *   - 先读 `infobox`；**读完为空**才回头解析 `info` 文本（镜像站会把
 *     infobox 换成一段纯文本，这时要把「键: 值」的行拆成字段，
 *     拆不出来的行原样留在 `unstructuredInfo` 里）；
 *   - `nameCN` / `name_cn` 都没有时，从 infobox 的「简体中文名」里取；
 *   - 头图按 large → medium → small 取第一个非空。
 */
export class CharacterFullItem {
  id: number = 0;
  infobox: CharacterInfoField[] = [];
  summary: string = '';
  image: string = '';
  name: string = '';
  nameCn: string = '';
  unstructuredInfo: string = '';

  /** 失败态载体（`id === 0` 表示这条是「加载失败」而不是真数据）。 */
  static template(): CharacterFullItem {
    return new CharacterFullItem();
  }

  static fromRaw(raw: Object | null): CharacterFullItem | null {
    if (raw === null) {
      return null;
    }
    const rec: Record<string, Object> | null = JsonUtils.asObj(raw);
    return rec === null ? null : CharacterFullItem.fromJson(rec);
  }

  static fromJson(json: Record<string, Object>): CharacterFullItem {
    const item = new CharacterFullItem();
    item.id = JsonUtils.intOf(json, 'id');
    item.summary = JsonUtils.str(json, 'summary');
    item.name = JsonUtils.str(json, 'name');

    item.infobox = CharacterFullItem.parseInfobox(JsonUtils.arr(json, 'infobox'));
    if (item.infobox.length === 0) {
      const parsed: CharacterInfoField[] = [];
      item.unstructuredInfo =
        CharacterFullItem.parseInfoText(JsonUtils.str(json, 'info'), parsed);
      item.infobox = parsed;
    }

    let nameCn: string = JsonUtils.str(json, 'nameCN');
    if (nameCn.length === 0) {
      nameCn = JsonUtils.str(json, 'name_cn');
    }
    if (nameCn.length === 0) {
      for (let i = 0; i < item.infobox.length; i++) {
        if (item.infobox[i].key === '简体中文名') {
          nameCn = item.infobox[i].value;
          break;
        }
      }
    }
    item.nameCn = nameCn;

    const images: Record<string, Object> | null = JsonUtils.obj(json, 'images');
    if (images !== null) {
      const keys: string[] = ['large', 'medium', 'small'];
      for (let i = 0; i < keys.length; i++) {
        const url: string = JsonUtils.str(images, keys[i]);
        if (url.length > 0) {
          item.image = url;
          break;
        }
      }
    }
    return item;
  }

  /**
   * 解析 infobox 数组。
   *
   * 每个条目的值可能是字符串、也可能是 `{k, v}` 对象（带标注的别名），
   * 后者按 `k：v` 拼；一个 key 的多个值用 ` / ` 连接。
   */
  private static parseInfobox(raw: Object[]): CharacterInfoField[] {
    const out: CharacterInfoField[] = [];
    for (let i = 0; i < raw.length; i++) {
      const entry: Record<string, Object> | null = JsonUtils.asObj(raw[i]);
      if (entry === null) {
        continue;
      }
      const key: string = JsonUtils.str(entry, 'key').trim();
      if (key.length === 0) {
        continue;
      }
      // 新版用 `values`，旧版用 `value`
      let values: Object[] = JsonUtils.arr(entry, 'values');
      if (values.length === 0) {
        const single: Object | undefined = entry['value'];
        if (single !== undefined && single !== null) {
          values = Array.isArray(single) ? single as Object[] : [single];
        }
      }
      const parts: string[] = [];
      for (let j = 0; j < values.length; j++) {
        const child: Record<string, Object> | null = JsonUtils.asObj(values[j]);
        const text: string = child === null
          ? `${values[j]}`.trim() : JsonUtils.str(child, 'v').trim();
        if (text.length === 0) {
          continue;
        }
        const label: string = child === null ? '' : JsonUtils.str(child, 'k').trim();
        parts.push(label.length === 0 ? text : `${label}：${text}`);
      }
      if (parts.length > 0) {
        out.push(new CharacterInfoField(key, parts.join(' / ')));
      }
    }
    return out;
  }

  /**
   * 把 `info` 纯文本拆成字段。
   *
   * 能拆出「键: 值」的行进 `out`，拆不出来的行原样拼进返回值（`unstructuredInfo`）。
   */
  private static parseInfoText(info: string, out: CharacterInfoField[]): string {
    const remaining: string[] = [];
    const lines: string[] = info.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].replace('\r', '').trim();
      if (line.length === 0) {
        continue;
      }
      const half: number = line.indexOf(':');
      const full: number = line.indexOf('：');
      let sep: number = -1;
      if (half > 0 && full > 0) {
        sep = half < full ? half : full;
      } else if (half > 0) {
        sep = half;
      } else if (full > 0) {
        sep = full;
      }
      if (sep < 1) {
        remaining.push(line);
        continue;
      }
      const key: string = line.substring(0, sep).trim();
      const value: string = line.substring(sep + 1).trim();
      if (key.length > 0 && value.length > 0) {
        out.push(new CharacterInfoField(key, value));
      } else {
        remaining.push(line);
      }
    }
    return remaining.join('\n');
  }
}

/** 制作人员（`staff_item.dart` 的 `StaffFullItem`）。 */
export class StaffItem {
  id: number = 0;
  name: string = '';
  nameCn: string = '';
  /** `images.grid`，缺省空串。 */
  gridImage: string = '';
  /** 该人员在本条目里的职务列表（取第一个显示）。 */
  relations: string[] = [];

  static fromJson(json: Record<string, Object>): StaffItem {
    const item = new StaffItem();
    item.id = JsonUtils.intOf(json, 'id');
    item.name = JsonUtils.str(json, 'name');
    item.nameCn = JsonUtils.str(json, 'nameCN');
    const images: Record<string, Object> | null = JsonUtils.obj(json, 'images');
    if (images !== null) {
      item.gridImage = JsonUtils.str(images, 'grid');
    }
    const relations: Object[] = JsonUtils.arr(json, 'relations');
    for (let i = 0; i < relations.length; i++) {
      const value: string = `${relations[i]}`.trim();
      if (value.length > 0) {
        item.relations.push(value);
      }
    }
    return item;
  }
}

/** 关联条目（`bangumi_relation.dart`）。 */
export class BangumiRelation {
  /** 「前传」/「续集」/「关联」…；空串按「关联」处理。 */
  relation: string = '关联';
  bangumiItem: BangumiItem = new BangumiItem();

  static fromJson(json: Record<string, Object>): BangumiRelation | null {
    const id: number = JsonUtils.intOf(json, 'id');
    if (id <= 0) {
      return null;
    }
    const item = new BangumiRelation();
    const relation: string = JsonUtils.str(json, 'relation').trim();
    item.relation = relation.length > 0 ? relation : '关联';
    item.bangumiItem = parseBangumiItem(json);
    // 参照实现会做两处归一：中文名为空时回落原名、其余字段保持缺省。
    if (item.bangumiItem.nameCn.length === 0) {
      item.bangumiItem.nameCn = item.bangumiItem.name;
    }
    return item;
  }
}

/** 主线关系的方向常量（`bangumi_relation.dart`）。 */
export const bangumiPrequelRelation: string = '前传';
export const bangumiSequelRelation: string = '续集';

/** 关系链遍历节点。 */
class RelationNode {
  readonly subjectId: number;
  readonly direction: string;

  constructor(subjectId: number, direction: string) {
    this.subjectId = subjectId;
    this.direction = direction;
  }
}

/** 过滤出「同类番剧且不是自己」的关联条目，并按 id 去重。 */
export function selectRelatedAnime(relations: BangumiRelation[],
  currentSubjectId: number): BangumiRelation[] {
  const seen: Set<number> = new Set<number>();
  const result: BangumiRelation[] = [];
  for (let i = 0; i < relations.length; i++) {
    const item: BangumiItem = relations[i].bangumiItem;
    if (item.type !== 2 || item.id === currentSubjectId || seen.has(item.id)) {
      continue;
    }
    seen.add(item.id);
    result.push(relations[i]);
  }
  return result;
}

/**
 * 沿「前传 / 续集」把关联链展开成一条主线顺序。
 *
 * 逐条对齐 `resolveRelatedAnimeChain`：
 *   - 前传层**倒序**排在前面（更早的在前），续集层正序接在后面
 *   - 沿途按 `direction` 单向遍历，避免把支线混进主线
 *   - `maxDepth` 12 / `maxFetchCount` 20 与源码同值
 *   - 结果 = 主线链 + 其余直接关联
 */
export async function resolveRelatedAnimeChain(currentSubjectId: number,
  fetchRelations: (id: number) => Promise<BangumiRelation[]>): Promise<BangumiRelation[]> {
  const maxDepth: number = 12;
  const maxFetchCount: number = 20;

  let fetchCount: number = 1;
  const rootRelations: BangumiRelation[] = await fetchRelations(currentSubjectId);
  const directRelations: BangumiRelation[] =
    selectRelatedAnime(rootRelations, currentSubjectId);

  const relationById: Map<number, BangumiRelation> = new Map<number, BangumiRelation>();
  for (let i = 0; i < directRelations.length; i++) {
    relationById.set(directRelations[i].bangumiItem.id, directRelations[i]);
  }
  const mainlineDirectionById: Map<number, string> = new Map<number, string>();
  const prequelLayers: BangumiRelation[][] = [];
  const sequelLayers: BangumiRelation[][] = [];
  const scheduledIds: Set<number> = new Set<number>();
  scheduledIds.add(currentSubjectId);

  let depth: number = 1;
  let frontier: RelationNode[] = [];
  const directPrequel: BangumiRelation[] = [];
  const directSequel: BangumiRelation[] = [];

  for (let i = 0; i < rootRelations.length; i++) {
    const relation: BangumiRelation = rootRelations[i];
    const item: BangumiItem = relation.bangumiItem;
    const direction: string = relation.relation;
    const isMainline: boolean =
      direction === bangumiPrequelRelation || direction === bangumiSequelRelation;
    if (!isMainline || item.type !== 2 || item.id === currentSubjectId) {
      continue;
    }
    let displayRelation: BangumiRelation | undefined = relationById.get(item.id);
    if (displayRelation === undefined) {
      displayRelation = new BangumiRelation();
      displayRelation.relation = direction;
      displayRelation.bangumiItem = item;
      relationById.set(item.id, displayRelation);
    }
    if (!mainlineDirectionById.has(item.id)) {
      mainlineDirectionById.set(item.id, direction);
      if (direction === bangumiPrequelRelation) {
        directPrequel.push(displayRelation);
      } else {
        directSequel.push(displayRelation);
      }
    }
    if (!scheduledIds.has(item.id)) {
      scheduledIds.add(item.id);
      frontier.push(new RelationNode(item.id, direction));
    }
  }
  if (directPrequel.length > 0) {
    prequelLayers.push(directPrequel);
  }
  if (directSequel.length > 0) {
    sequelLayers.push(directSequel);
  }

  while (frontier.length > 0 && depth < maxDepth && fetchCount < maxFetchCount) {
    const budget: number = maxFetchCount - fetchCount;
    const nodesToFetch: RelationNode[] = frontier.slice(0, budget);
    const tasks: Promise<BangumiRelation[]>[] = [];
    for (let i = 0; i < nodesToFetch.length; i++) {
      tasks.push(fetchRelations(nodesToFetch[i].subjectId));
    }
    const relationLists: BangumiRelation[][] = await Promise.all(tasks);
    fetchCount += nodesToFetch.length;

    const nextFrontier: RelationNode[] = [];
    const nextPrequel: BangumiRelation[] = [];
    const nextSequel: BangumiRelation[] = [];

    for (let index = 0; index < nodesToFetch.length; index++) {
      const node: RelationNode = nodesToFetch[index];
      const relations: BangumiRelation[] = relationLists[index];
      for (let i = 0; i < relations.length; i++) {
        const relation: BangumiRelation = relations[i];
        const item: BangumiItem = relation.bangumiItem;
        if (relation.relation !== node.direction || item.type !== 2 ||
          item.id === currentSubjectId) {
          continue;
        }
        let displayRelation: BangumiRelation | undefined = relationById.get(item.id);
        if (displayRelation === undefined) {
          displayRelation = new BangumiRelation();
          displayRelation.relation = node.direction;
          displayRelation.bangumiItem = item;
          relationById.set(item.id, displayRelation);
        }
        if (!mainlineDirectionById.has(item.id)) {
          mainlineDirectionById.set(item.id, node.direction);
          if (node.direction === bangumiPrequelRelation) {
            nextPrequel.push(displayRelation);
          } else {
            nextSequel.push(displayRelation);
          }
        }
        if (!scheduledIds.has(item.id)) {
          scheduledIds.add(item.id);
          nextFrontier.push(new RelationNode(item.id, node.direction));
        }
      }
    }
    if (nextPrequel.length > 0) {
      prequelLayers.push(nextPrequel);
    }
    if (nextSequel.length > 0) {
      sequelLayers.push(nextSequel);
    }
    frontier = nextFrontier;
    depth++;
  }

  const result: BangumiRelation[] = [];
  for (let i = prequelLayers.length - 1; i >= 0; i--) {
    for (let j = 0; j < prequelLayers[i].length; j++) {
      result.push(prequelLayers[i][j]);
    }
  }
  for (let i = 0; i < sequelLayers.length; i++) {
    for (let j = 0; j < sequelLayers[i].length; j++) {
      result.push(sequelLayers[i][j]);
    }
  }
  for (let i = 0; i < directRelations.length; i++) {
    const item: BangumiItem = directRelations[i].bangumiItem;
    if (!mainlineDirectionById.has(item.id)) {
      result.push(directRelations[i]);
    }
  }
  return result;
}
