import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';

const TAG: string = 'AutumnDanmaku';

/**
 * 弹幕屏蔽规则。对应参照实现里的 Hive 盒子 `shieldList` + `MyController.isDanmakuBlocked`。
 *
 * 匹配语义逐条对齐源码：
 *   - 规则以 `/` 开头且以 `/` 结尾 → 当**正则**用（去掉两侧斜杠后 `RegExp` 匹配）；
 *     正则非法就记一条日志并**跳过这条**（不能让一条坏规则挡掉整个弹幕流）；
 *   - 其余规则 → 子串包含匹配；
 *   - 空规则忽略。
 *
 * 落盘：`${filesDir}/danmaku/shield.json`（字符串数组）。
 */
export class DanmakuShieldStore {
  private static rules: string[] = [];
  private static dir: string = '';

  static init(context: common.UIAbilityContext): void {
    DanmakuShieldStore.dir = `${context.filesDir}/danmaku`;
    if (!fileIo.accessSync(DanmakuShieldStore.dir)) {
      fileIo.mkdirSync(DanmakuShieldStore.dir, true);
    }
    DanmakuShieldStore.load();
  }

  static all(): string[] {
    return DanmakuShieldStore.rules.slice();
  }

  static count(): number {
    return DanmakuShieldStore.rules.length;
  }

  static add(rule: string): boolean {
    const value: string = rule.trim();
    if (value.length === 0) {
      return false;
    }
    for (let i = 0; i < DanmakuShieldStore.rules.length; i++) {
      if (DanmakuShieldStore.rules[i] === value) {
        return false;
      }
    }
    DanmakuShieldStore.rules.push(value);
    DanmakuShieldStore.persist();
    return true;
  }

  static remove(index: number): void {
    if (index < 0 || index >= DanmakuShieldStore.rules.length) {
      return;
    }
    DanmakuShieldStore.rules.splice(index, 1);
    DanmakuShieldStore.persist();
  }

  /** 一条规则是不是正则写法（`/xxx/`，且长度 > 2）。 */
  static isRegexRule(rule: string): boolean {
    return rule.length > 2 && rule.startsWith('/') && rule.endsWith('/');
  }

  /** 这条弹幕是否命中任一屏蔽规则（播放器渲染弹幕时逐条调用）。 */
  static isBlocked(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    for (let i = 0; i < DanmakuShieldStore.rules.length; i++) {
      const rule: string = DanmakuShieldStore.rules[i];
      if (rule.length === 0) {
        continue;
      }
      if (DanmakuShieldStore.isRegexRule(rule)) {
        const pattern: string = rule.substring(1, rule.length - 1);
        try {
          if (new RegExp(pattern).test(text)) {
            return true;
          }
        } catch (e) {
          Logger.error(TAG, `弹幕屏蔽规则不是合法正则，已跳过：${pattern}`);
          continue;
        }
      } else if (text.indexOf(rule) >= 0) {
        return true;
      }
    }
    return false;
  }

  private static load(): void {
    DanmakuShieldStore.rules = [];
    const path: string = `${DanmakuShieldStore.dir}/shield.json`;
    if (!fileIo.accessSync(path)) {
      return;
    }
    try {
      const stat = fileIo.statSync(path);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const read: number = fileIo.readSync(file.fd, buffer);
        text = new util.TextDecoder().decodeToString(
          new Uint8Array(buffer, 0, read));
      } finally {
        fileIo.closeSync(file);
      }
      const parsed: Object = JSON.parse(text) as Object;
      if (Array.isArray(parsed)) {
        const list: Object[] = parsed as Object[];
        for (let i = 0; i < list.length; i++) {
          const value: string = `${list[i]}`.trim();
          if (value.length > 0) {
            DanmakuShieldStore.rules.push(value);
          }
        }
      }
      Logger.info(TAG, `屏蔽规则载入 ${DanmakuShieldStore.rules.length} 条`);
    } catch (e) {
      Logger.error(TAG, '屏蔽规则读取失败');
    }
  }

  private static persist(): void {
    const array: Object[] = [];
    for (let i = 0; i < DanmakuShieldStore.rules.length; i++) {
      array.push(DanmakuShieldStore.rules[i]);
    }
    const path: string = `${DanmakuShieldStore.dir}/shield.json`;
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(array));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      Logger.error(TAG, '屏蔽规则保存失败');
    }
  }
}
