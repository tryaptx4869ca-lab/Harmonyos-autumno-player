/**
 * 共享元素两端在**窗口坐标系**里的矩形（vp）。
 */
export class HeroRect {
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;

  constructor(x: number, y: number, w: number, h: number) {
    this.x = x;
    this.y = y;
    this.w = w;
    this.h = h;
  }

  /** 量到过而且尺寸有效。 */
  get usable(): boolean {
    return this.w > 1 && this.h > 1;
  }
}

/**
 * 共享元素两端的位置登记表。
 *
 * 为什么要自己记：参照实现的退场是「整页自己淡出 + 弹栈放到动画之后」
 * （见 `InfoPage.backOut` / `NavHost.finishHeroExit`），**没有路由动作**；
 * 而 ArkUI 的共享元素转场要求由路由动作触发（push/pop 包在 `animateTo` 里）。
 * 没有路由动作，就只能由我们**自己画一层 shuttle** 把封面送回去——
 * 那就需要两端的屏幕位置：
 *
 *   - 卡片端（源）：各个卡片在封面的 `onAreaChange` 里登记（`setCard`）；
 *   - 详情页端：详情页的封面同样登记一份（`setDetail`）。
 *
 * 两端都用 `Area.globalPosition`（相对**窗口**的坐标），与 shuttle 所在的
 * 那一层（`Index` 的最外层 Stack，铺满窗口）同一坐标系，不用换算。
 */
export class HeroRects {
  private static cards: Map<string, HeroRect> = new Map<string, HeroRect>();
  private static details: Map<string, HeroRect> = new Map<string, HeroRect>();

  static fromArea(area: Area): HeroRect {
    return new HeroRect(Number(area.globalPosition.x), Number(area.globalPosition.y),
      Number(area.width), Number(area.height));
  }

  /** 卡片端登记（源）。空 tag 是「这一档不参与转场」的写法（见 CollectPage）。 */
  static setCard(tag: string, area: Area): void {
    if (tag.length === 0) {
      return;
    }
    HeroRects.cards.set(tag, HeroRects.fromArea(area));
  }

  /** 详情页端登记。 */
  static setDetail(tag: string, area: Area): void {
    if (tag.length === 0) {
      return;
    }
    HeroRects.details.set(tag, HeroRects.fromArea(area));
  }

  static card(tag: string): HeroRect | null {
    const rect: HeroRect | undefined = HeroRects.cards.get(tag);
    return rect === undefined ? null : rect;
  }

  static detail(tag: string): HeroRect | null {
    const rect: HeroRect | undefined = HeroRects.details.get(tag);
    return rect === undefined ? null : rect;
  }
}
