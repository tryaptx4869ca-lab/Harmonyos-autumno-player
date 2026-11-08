import { SettingsStore } from '../services/storage/SettingsStore';
import { SettingsKeys } from '../services/storage/SettingsKeys';

/**
 * 「关闭动画」总开关（规格 §38.9 / §38.15）。
 *
 * 参照实现里这条约定写成同一个模式，反复出现在 9 个文件里：
 *
 * ```dart
 * MediaQuery.disableAnimationsOf(context) ? Duration.zero : <正常时长>
 * ```
 *
 * 触发源有两个：
 *   1. 系统「关闭动画」辅助功能 —— `MediaQuery.disableAnimationsOf(context)`
 *   2. 应用设置 —— `SettingsKeys.playerDisableAnimations`（默认 false）
 *
 * **鸿蒙侧已知限制**：API 24 的 ArkTS 接口里没有把系统「减弱动态效果 /
 * 关闭动画」暴露给应用——已翻遍 `@ohos.accessibility.d.ts`、
 * `@ohos.app.ability.Configuration`、`@ohos.arkui.*` 全量声明，没有
 * `reduceMotion` / `animationScale` 一类的取值。因此这里落地第 2 个触发源
 * （应用内设置），第 1 个触发源记入文档的「已知限制」，等系统开放接口后
 * 只需在 `isOff()` 里或上一个系统值即可。
 *
 * 用法（时长过闸）：
 * ```ts
 * .animation({ duration: MotionRuntime.ms(Motion.normal), curve: ... })
 * ```
 */
export class MotionRuntime {
  /**
   * ⚠️ **取证用慢放倍数**：这里必须保持 1。
   *
   * 420ms 的动效在真机上没法逐帧取证——`snapshot_display` 一次就要 0.8 秒，
   * 等截到图动画早结束了（2026-09-16 实测：连拍 4 张平均亮度完全一样 = 全在动画之后）。
   * 需要逐帧取证时，临时把它调成 8（动画变 3.4 秒，能拍到中间帧），
   * **取完证立刻改回 1 并重新装机**——用户真机试手感的版本必须是 1 倍速。
   */
  private static readonly evidenceScale: number = 1;

  /** 读设置项判断是否关闭动画。preferences 走内存镜像，是 Map 查表，开销可忽略。 */
  static isOff(): boolean {
    return SettingsStore.getBool(SettingsKeys.playerDisableAnimations);
  }

  /** 时长过闸：关闭动画时一律 0ms。 */
  static ms(duration: number): number {
    return MotionRuntime.isOff() ? 0 : duration * MotionRuntime.evidenceScale;
  }
}
