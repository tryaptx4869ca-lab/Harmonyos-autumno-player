import { NavScrollSpec } from '../theme/Tokens';
import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';

/**
 * 底部导航的滚动隐藏控制器。
 *
 * 逐行对应源码 `lib/pages/menu/menu.dart:61-89` 的 `_handleNavScroll`：
 *
 * | 条件 | 行为 |
 * | --- | --- |
 * | 被路由覆盖 | 忽略（由调用方决定是否上报） |
 * | 轴非「垂直 + 向下」 | 忽略（本实现只接受正向 offset 增长） |
 * | delta.abs() < 0.5 | 忽略 |
 * | 向下滚动 | 累加距离，达到 48 即隐藏并清零 |
 * | 向上滚动 | 累加清零；若已隐藏则立即恢复 |
 *
 * 页面只需在滚动回调里调用 `report(scroller.currentOffset().yOffset)`，
 * 不必自己算 delta——控制器内部保存上一次的偏移量。
 */
export class NavScrollController {
  /** AppStorage 中「导航已隐藏」的键名。 */
  static readonly HIDDEN_KEY: string = 'navHidden';

  private static lastOffset: number = 0;
  private static accumulated: number = 0;

  /**
   * 距两端多少 vp 以内算「贴在边缘上」。
   *
   * 贴边时**完全不上报**：列表用的是 `EdgeEffect.Spring`，手指在末尾继续往上推
   * 会让 offset 越过 `maxOffset` 再弹回来，这一来一回的位移如果照常累加，
   * 就会在「没有内容可翻」的情况下把导航条顶没（用户实测反馈的问题）。
   */
  static readonly EDGE_GUARD: number = 24;

  /** 是否已隐藏。 */
  static isHidden(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>(NavScrollController.HIDDEN_KEY);
    return v === true;
  }

  /** 用户是否在「界面设置」里固定了导航栏。 */
  static isFixed(): boolean {
    return SettingsStore.getBool(SettingsKeys.fixedNavigationBar);
  }

  /**
   * 上报一次滚动位置。
   * @param offset 当前滚动容器的 yOffset（vp）
   * @param covered 当前页面是否被路由覆盖；覆盖时忽略（对应源码 `_isCovered`）
   */
  static report(offset: number, covered: boolean = false,
    maxOffset: number = -1): void {
    const delta: number = offset - NavScrollController.lastOffset;
    NavScrollController.lastOffset = offset;
    /**
     * 固定导航时滚动只更新位置基线，不进入隐藏状态机。
     * 设置页刚打开固定开关时可能导航仍处于上一页留下的隐藏态，这里顺便恢复。
     */
    if (NavScrollController.isFixed()) {
      NavScrollController.accumulated = 0;
      if (NavScrollController.isHidden()) {
        NavScrollController.setHidden(false);
      }
      return;
    }
    if (covered) {
      return;
    }
    // 顶部回弹：offset 被拉到 0 以下
    if (offset < 0) {
      NavScrollController.accumulated = 0;
      return;
    }
    // 底部回弹：已经到底（或越过末尾）时不参与判定，避免「推不动了还在推」
    // 被算成有效滚动。这里不清隐藏态——贴边时本来就没有内容在动。
    if (maxOffset > 0 && offset >= maxOffset - NavScrollController.EDGE_GUARD) {
      NavScrollController.accumulated = 0;
      return;
    }
    if (Math.abs(delta) < NavScrollSpec.minDelta) {
      return;
    }
    const hidden: boolean = NavScrollController.isHidden();
    if (delta > 0) {
      NavScrollController.accumulated += delta;
      if (NavScrollController.accumulated >= NavScrollSpec.hideThreshold && !hidden) {
        NavScrollController.accumulated = 0;
        NavScrollController.setHidden(true);
      }
      return;
    }
    // 向上滚动：立即恢复，并清零累计
    NavScrollController.accumulated = 0;
    if (hidden) {
      NavScrollController.setHidden(false);
    }
  }

  /** 切换 Tab 或页面重建时重置基线，避免下一次上报出现巨大 delta。 */
  static reset(): void {
    NavScrollController.lastOffset = 0;
    NavScrollController.accumulated = 0;
  }

  /** 直接设置隐藏状态（点导航、回顶等场景）。 */
  static setHidden(hidden: boolean): void {
    if (hidden && NavScrollController.isFixed()) {
      hidden = false;
    }
    AppStorage.setOrCreate(NavScrollController.HIDDEN_KEY, hidden);
  }
}
