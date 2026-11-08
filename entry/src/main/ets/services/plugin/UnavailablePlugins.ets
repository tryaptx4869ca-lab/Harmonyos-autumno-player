import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../Logger';

const TAG: string = 'AutumnPlugins';
/** 用户名单的落盘文件名（放在应用私有目录，跟其它数据一起）。 */
const STORE_FILE: string = 'unavailable_plugins.json';

/**
 * 内置的「已失效规则」名单。
 *
 * 用户 2026-09-17 反馈这五条规则对应的站点已经用不了：
 * `7sefun` / `dallvdm` / `DM84` / `gugu3` / `xfdmneo`。
 *
 * 为什么是「屏蔽」而不是「修好」：这些规则的内容是**针对各自站点 HTML 结构写的
 * 抽取规则**，站点一改版就得重新逆向一遍选择器；而且改完必须对着真机上的真实
 * 请求验证（本项目当前不连设备），盲改只会把「打不开」变成「抽到空数据」——
 * 对用户来说一样是坏的。所以先按用户说的「去掉这些规则」处理：名单里的规则
 * 在**三个入口**（播放来源弹层、规则仓库、已装规则列表）都不再出现。
 *
 * 2026-09-19（用户：「整理一下现在的源，现在有很多源能搜索到但是解析不了视频」）：
 * 这份内置名单之外，用户在「规则管理」里可以**自己标记**某条规则不可用
 * （`block()`），标记结果落盘、重启仍在；标记过的规则和内置名单一样从三个入口
 * 消失，但会出现在「已隐藏的规则」一节里，随时可以「恢复可用」（`unblock()`）。
 * 也就是说：不用改代码、不用重新打包，用户自己就能把「搜得到、解析不了」的源
 * 一条条清理干净。
 *
 * ⚠️ **2026-09-19 第二次更新：`7sefun` 已从内置名单移出**
 * （用户：「规则仓库添加上 7sefun 的下载入口」）。
 * 原因是它已经被**对着真实站点重新逆向过**，并且改在代码侧的
 * `PluginPatches.patchSevenFun()` 里自动生效——实测：搜索页
 * `div.video.anim` → `a.video-wrapper` → `/voddetail/26976.html`，
 * 详情页 2×`div.chat` + 20 个 `/vodplay/…` 链接，与补丁选择器完全对得上。
 * 于是「仓库原版仍然坏、我们下载/载入后那份是好的」：
 * 仓库下载 → `PluginManager.upsert` → 打补丁，用户拿到可用版本。
 *
 * 顺带记一笔：`dallvdm` 这一条**是拼写笔误**（仓库里叫 `dalvdm`），
 * 而匹配是按名字前缀做的，所以它从来没有真正屏蔽到 dalvdm——这也是
 * 2026-09-19 用户还能在详情页看到 dalvdm 的原因。这里**保持原样**：
 * dalvdm 的验证码选择器已在 `PluginPatches.patchDalvdm()` 里修正。
 *
 * ⚠️ **2026-09-19 第三次更新：`mgnacg` 进内置名单**（用户：「先去掉mgnacg」）。
 *
 * 站点侧核实过（真实 Chromium 打开 `www.mgnacg.com` 的搜索页）：
 * 验证页的「提交验证」**确实绑了处理器**——留空点一下，图片 `src` 会从
 * `/verify/index.html` 变成 `/index.php/verify/index.html?r=…`，
 * 说明请求发出去了、站点也回了 `{"code":1002,"msg":"验证码错误"}`。
 * 也就是说站点没坏，卡在应用这一侧的验证流程上（真机日志里的
 * 「验证页探针」那几行才能定位到底卡在哪一步）。
 * 在查清之前先按用户要求把这条规则收起来，不让它在三个入口里继续出现。
 */
const BUILTIN_NAMES: string[] = [
  'dallvdm',
  'dm84',
  'gugu3',
  'mgnacg',
  'xfdmneo'
];

/** 落盘结构（ArkTS 不允许匿名对象字面量，故显式声明）。 */
interface UnavailableRecord {
  /** 用户手动标记为不可用的规则名。 */
  blocked: string[];
  /** 用户手动恢复的规则名：优先级高于 blocked 与内置名单。 */
  allowed: string[];
}

export class UnavailablePlugins {
  /** 用户标记为不可用的（原始名字，匹配时归一化）。 */
  private static blocked: string[] = [];
  /** 用户显式恢复的（原始名字，匹配时归一化）。 */
  private static allowed: string[] = [];
  private static filePath: string = '';
  private static loaded: boolean = false;

  /** 由 `EntryAbility` 启动时调用：把用户名单读进来。 */
  static init(context: common.UIAbilityContext): void {
    UnavailablePlugins.filePath = `${context.filesDir}/${STORE_FILE}`;
    UnavailablePlugins.load();
  }

  /**
   * 判断一条规则是否在屏蔽名单里。
   *
   * 匹配方式：去掉空格与括号等符号后**完全相同**，或者**以名单名开头**
   * （规则仓库里常见 `DM84(高清)`、`7sefun v1.3` 这类带后缀的写法）。
   * 用前缀而不是「包含」，避免误伤 `my-gugu3-backup` 这种第三方改名规则。
   */
  static isUnavailable(name: string): boolean {
    const key: string = UnavailablePlugins.normalize(name);
    if (key.length === 0) {
      return false;
    }
    UnavailablePlugins.ensureLoaded();
    // 用户手动恢复过的，永远算可用（优先级最高）
    if (UnavailablePlugins.matches(UnavailablePlugins.allowed, key)) {
      return false;
    }
    if (UnavailablePlugins.matches(UnavailablePlugins.blocked, key)) {
      return true;
    }
    return UnavailablePlugins.matches(BUILTIN_NAMES, key);
  }

  /**
   * 「已隐藏的规则」列表：内置 + 用户标记，去掉用户已恢复的。
   *
   * 给规则管理页那一节用（否则被屏蔽的规则在三个入口都看不到，就没法恢复了）。
   */
  static hidden(): string[] {
    UnavailablePlugins.ensureLoaded();
    const out: string[] = [];
    const push = (name: string): void => {
      const key: string = UnavailablePlugins.normalize(name);
      if (key.length === 0) {
        return;
      }
      if (UnavailablePlugins.matches(UnavailablePlugins.allowed, key)) {
        return;
      }
      for (let i = 0; i < out.length; i++) {
        if (UnavailablePlugins.normalize(out[i]) === key) {
          return;
        }
      }
      out.push(name);
    };
    for (let i = 0; i < BUILTIN_NAMES.length; i++) {
      push(BUILTIN_NAMES[i]);
    }
    for (let i = 0; i < UnavailablePlugins.blocked.length; i++) {
      push(UnavailablePlugins.blocked[i]);
    }
    return out;
  }

  /** 手动标记为不可用（落盘）。 */
  static block(name: string): void {
    UnavailablePlugins.ensureLoaded();
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return;
    }
    UnavailablePlugins.allowed =
      UnavailablePlugins.without(UnavailablePlugins.allowed, trimmed);
    if (!UnavailablePlugins.matches(UnavailablePlugins.blocked,
      UnavailablePlugins.normalize(trimmed))) {
      UnavailablePlugins.blocked.push(trimmed);
    }
    UnavailablePlugins.persist();
    Logger.info(TAG, `规则已标记为不可用：${trimmed}`);
  }

  /** 恢复可用（落盘）：把名字从用户标记里去掉，并记进「已恢复」名单。 */
  static unblock(name: string): void {
    UnavailablePlugins.ensureLoaded();
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return;
    }
    UnavailablePlugins.blocked =
      UnavailablePlugins.without(UnavailablePlugins.blocked, trimmed);
    if (!UnavailablePlugins.matches(UnavailablePlugins.allowed,
      UnavailablePlugins.normalize(trimmed))) {
      UnavailablePlugins.allowed.push(trimmed);
    }
    UnavailablePlugins.persist();
    Logger.info(TAG, `规则已恢复可用：${trimmed}`);
  }

  /** 名单里有没有 `key`（归一化后的相等或前缀匹配）。 */
  private static matches(names: string[], key: string): boolean {
    for (let i = 0; i < names.length; i++) {
      const blocked: string = UnavailablePlugins.normalize(names[i]);
      if (blocked.length > 0 && (key === blocked || key.startsWith(blocked))) {
        return true;
      }
    }
    return false;
  }

  /** 去掉与 `name` 归一化后同名的条目。 */
  private static without(names: string[], name: string): string[] {
    const key: string = UnavailablePlugins.normalize(name);
    const out: string[] = [];
    for (let i = 0; i < names.length; i++) {
      if (UnavailablePlugins.normalize(names[i]) !== key) {
        out.push(names[i]);
      }
    }
    return out;
  }

  private static ensureLoaded(): void {
    if (!UnavailablePlugins.loaded) {
      UnavailablePlugins.load();
    }
  }

  private static load(): void {
    UnavailablePlugins.loaded = true;
    const path: string = UnavailablePlugins.filePath;
    if (path.length === 0 || !fileIo.accessSync(path)) {
      return;
    }
    try {
      const stat = fileIo.statSync(path);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const read: number = fileIo.readSync(file.fd, buffer);
        text = new util.TextDecoder().decodeToString(new Uint8Array(buffer, 0, read));
      } finally {
        fileIo.closeSync(file);
      }
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      UnavailablePlugins.blocked = UnavailablePlugins.readArray(root['blocked']);
      UnavailablePlugins.allowed = UnavailablePlugins.readArray(root['allowed']);
      Logger.info(TAG,
        `不可用规则名单载入：标记 ${UnavailablePlugins.blocked.length} 条 / 恢复 ${UnavailablePlugins.allowed.length} 条`);
    } catch (e) {
      Logger.error(TAG, '不可用规则名单读取失败（按空处理）');
    }
  }

  private static readArray(value: Object | undefined): string[] {
    const out: string[] = [];
    if (value === undefined || value === null || !Array.isArray(value)) {
      return out;
    }
    const list: Object[] = value as Object[];
    for (let i = 0; i < list.length; i++) {
      const item: string = `${list[i]}`.trim();
      if (item.length > 0) {
        out.push(item);
      }
    }
    return out;
  }

  private static persist(): void {
    const path: string = UnavailablePlugins.filePath;
    if (path.length === 0) {
      return;
    }
    const record: UnavailableRecord = {
      blocked: UnavailablePlugins.blocked,
      allowed: UnavailablePlugins.allowed
    };
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(record));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      Logger.error(TAG, '不可用规则名单写入失败');
    }
  }

  /** 归一化：小写、去掉空格与常见分隔/括号字符。 */
  private static normalize(name: string): string {
    return name.trim().toLowerCase()
      .replace(/\s+/g, '')
      .replace(/[()（）\[\]【】_-]/g, '');
  }
}
