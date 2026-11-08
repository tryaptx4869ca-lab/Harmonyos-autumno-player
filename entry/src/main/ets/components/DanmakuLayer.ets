import { AppColor } from '../theme/AppColors';
import { DanmakuEntry } from '../model/DanmakuModels';

/**
 * 「过期就不再补发」的时间窗（毫秒）。
 *
 * 参照实现每秒只取当前秒那一桶弹幕（`_emitDanmakusForCurrentPosition`），
 * 错过的不补。本工程轮询 500ms 一次，窗口取 1200ms 留两次轮询余量。
 */
const DANMAKU_STALE_WINDOW_MS: number = 1200;

/** 一条正在屏幕上飞的弹幕。 */
export class ActiveDanmaku {
  /** 唯一键（弹幕原文 + 起始时间，供 ForEach 用） */
  key: string = '';
  message: string = '';
  color: string = '#FFFFFF';
  /** 1 滚动 / 4 底部 / 5 顶部 */
  type: number = 1;
  /** 轨道序号（0 起） */
  lane: number = 0;
  /** 飞行时长（毫秒） */
  durationMs: number = 8000;
  /** 开始显示的时刻（墙钟，毫秒），用于过期回收 */
  startedAtMs: number = 0;
  fontSize: number = 16;
  fontWeight: number = 500;
  borderWidth: number = 0;
  opacity: number = 1;
}

/**
 * 单条弹幕。
 *
 * 滚动弹幕用 `animateTo` 把 `translate.x` 从「右边缘」推到「-文本宽度」，
 * 线性缓动、时长由 `danmakuDuration` 决定（跟随倍速时再按播放倍速折算）。
 * 顶部 / 底部弹幕不横向移动，只在停留时间内淡入淡出。
 *
 * 文本宽度必须**实测**（`onAreaChange`）而不能按字数估算：
 * 中文、日文、颜文字的宽度差得很多，估算会让弹幕在屏幕中间「消失」或者
 * 飞出很远才停。
 */
@Component
export struct DanmakuItemView {
  @Prop themeRev: number = 0;
  @Prop message: string = '';
  @Prop color: string = '#FFFFFF';
  @Prop type: number = 1;
  @Prop laneTop: number = 0;
  @Prop durationMs: number = 8000;
  @Prop fontSize: number = 16;
  @Prop fontWeight: number = 500;
  /** 描边粗细。**不能叫 `borderWidth`**：与 ArkUI 内置属性同名会冲突。 */
  @Prop strokeWidth: number = 0;
  @Prop panelOpacity: number = 1;
  /** 容器宽度（vp），由弹幕层实测后下发。 */
  @Prop containerWidth: number = 360;
  /** 容器高度（vp），顶部 / 底部弹幕据此定位。 */
  @Prop containerHeight: number = 220;

  @State private offsetX: number = 0;
  @State private textWidth: number = 0;
  @State private alpha: number = 1;
  private started: boolean = false;

  aboutToAppear(): void {
    /**
     * 滚动弹幕**一上来就站在右边缘**（画面外），而不是 x = 0（左边缘）。
     *
     * `offsetX` 的默认值是 0，而滚动弹幕的定位是 `.position({ x: 0 })` +
     * `.translate({ x: offsetX })`——也就是说「还没开始滚」的那一刻它正好
     * 落在画面最左边。正常情况下一帧后就会被 `startScroll()` 推到右边缘再起飞，
     * 看不出问题；但一次性创建几百条时（见 `DANMAKU_STALE_WINDOW_MS` 的注释）
     * 动画不一定每条都起得来，起不来的那些就**全堆在左上角不动**
     * （用户 2026-09-18：「刚开弹幕时左上角会叠很多弹幕定住」）。
     *
     * 初始值放右边缘之后，最坏情况只是「这一条没出现」，不会再留下视觉垃圾。
     */
    if (this.type === 1) {
      this.offsetX = this.containerWidth > 0 ? this.containerWidth : 360;
    }
    if (this.type !== 1) {
      // 顶部 / 底部：原地停留，淡入 → 淡出（各占 10%）
      this.alpha = 0;
      animateTo({ duration: Math.round(this.durationMs * 0.1) }, () => {
        this.alpha = 1;
      });
    }
  }

  private startScroll(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    // 兜底：万一创建时容器宽度还没量到（`aboutToAppear` 用了 360 的缺省），
    // 起飞前先把起点补到真正的右边缘，免得它从画面中间开始飞
    if (this.containerWidth > 0 && this.offsetX < this.containerWidth) {
      this.offsetX = this.containerWidth;
    }
    // 起点已经在右边缘（见 aboutToAppear），这里只负责把它推到左侧之外
    animateTo({ duration: this.durationMs, curve: Curve.Linear }, () => {
      this.offsetX = -this.textWidth;
    });
  }

  private topPosition(): number {
    if (this.type === 5) {
      // 顶部弹幕：从上去一点点开始排
      return 8 + this.laneTop;
    }
    if (this.type === 4) {
      // 底部弹幕：从下往上排
      return this.containerHeight - 8 - this.laneTop - this.fontSize * 1.6;
    }
    return this.laneTop;
  }

  /**
   * 顶部 / 底部弹幕的水平居中偏移。
   *
   * 这两类弹幕**本来就不横移**（原地淡入淡出），位置应当是**水平居中**——
   * 协议里的 `mode=4/5`，参照实现（canvas_danmaku 的 top/bottom）也是居中的。
   *
   * 而本工程原来写的是 `.position({ x: this.type === 1 ? 0 : undefined, y })`，
   * 以为把 x 留空就能继承 Stack 的居中；实际 `undefined` 的 x 并没换来居中，
   * 组件仍然落在**左边缘 x = 0**。真机表现就是「有的弹幕定在左上角不动，
   * 而且它们不滚动」——那些正是顶部 / 底部弹幕（用户 2026-09-18）。
   *
   * 取文本**实测宽度**来居中（宽度靠 `onAreaChange` 拿到，中文/日文/颜文字
   * 宽度差得很多，不能按字数估）。量到之前偏移是 0，会偏左一帧，
   * 但那时 `alpha` 还是 0（淡入从 0 开始），看不出来。
   */
  private centeredOffsetX(): number {
    if (this.textWidth <= 0 || this.containerWidth <= this.textWidth) {
      return 0;
    }
    return (this.containerWidth - this.textWidth) / 2;
  }

  build() {
    Text(this.message)
      .fontSize(this.fontSize)
      .fontWeight(this.fontWeight)
      .fontColor(this.color)
      .opacity(this.alpha * this.panelOpacity)
      .maxLines(1)
      .textShadow(this.strokeWidth > 0
        ? {
          radius: this.strokeWidth,
          color: '#000000',
          offsetX: 0,
          offsetY: 0
        }
        : undefined)
      // x 一律从 0 起算，横向位移全部交给 translate 表达：
      // 滚动的用飞行位移 `offsetX`，顶部/底部的用居中偏移（见 `centeredOffsetX`）
      .position({ x: 0, y: this.topPosition() })
      .translate({
        x: this.type === 1 ? this.offsetX : this.centeredOffsetX()
      })
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const width: number = Number(newValue.width);
        if (width > 0 && this.textWidth === 0) {
          this.textWidth = width;
          if (this.type === 1) {
            this.startScroll();
          }
        }
      })
  }
}

/**
 * 弹幕层：铺在视频区之上，本身不拦截手势。
 *
 * 关键取舍：`hitTestBehavior(HitTestMode.None)` —— 视频区上挂着单击/双击/拖动
 * 三套手势（§15.4–15.7），弹幕层如果参与命中测试，点「播放暂停」会被弹幕吃掉。
 */
@Component
export struct DanmakuLayer {
  @Prop themeRev: number = 0;
  /** 当前在屏的弹幕。 */
  @Prop active: ActiveDanmaku[] = [];
  @Prop containerWidth: number = 360;
  @Prop containerHeight: number = 220;
  /** 顶部 / 底部弹幕的行高（字号 + 行距）。 */
  @Prop laneHeight: number = 26;

  build() {
    Stack() {
      ForEach(this.active, (item: ActiveDanmaku) => {
        DanmakuItemView({
          message: item.message,
          color: item.color,
          type: item.type,
          laneTop: item.lane * this.laneHeight,
          durationMs: item.durationMs,
          fontSize: item.fontSize,
          fontWeight: item.fontWeight,
          strokeWidth: item.borderWidth,
          panelOpacity: item.opacity,
          containerWidth: this.containerWidth,
          containerHeight: this.containerHeight
        })
      }, (item: ActiveDanmaku) => item.key)
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 弹幕调度（纯逻辑，便于自检）。
 *
 * 对应参照实现的一整条链路，但拆成了可测的纯函数：
 *   - `timeOffsetMs`：`danmakuTimeOffset` 时间校准（毫秒；正数=弹幕提前）
 *   - 取「源时间已到、但还没发过」的那一批（用游标避免重复发）
 *   - 轨道分配：滚动弹幕按「轨道占用到期时间」挑空闲轨；
 *     `massive`（海量弹幕）打开时允许叠加绘制（直接用取模轮转）
 *   - 顶部 / 底部轨道与滚动轨**分开计数**（源码里也是分开的容器）
 */
export class DanmakuSchedule {
  /** 已发到的下标（`entries` 必须按时间升序）。 */
  private cursor: number = 0;
  /** 每条滚轨的空闲时间戳（毫秒）。 */
  private scrollLaneFreeAt: number[] = [];
  private topLaneFreeAt: number[] = [];
  private bottomLaneFreeAt: number[] = [];
  private laneCount: number = 8;
  /**
   * 上一次 `take()` 因为「已经过期」而跳过的条数（供调用方记日志）。
   *
   * 正常播放时它一直是 0；只有在「刚打开弹幕 / 关了再开 / 拖过进度」
   * 这种游标落后于播放位置的情况下才会大于 0——那正是以前把几百条
   * 弹幕一次性糊到左上角的时候。
   */
  lastSkippedStale: number = 0;
  /**
   * 上一次 `take()` 因为「轨道全忙」而**丢掉**的条数。
   *
   * 为什么要丢而不是硬塞：轨道全忙时把新弹幕塞进「最早空出来的那条」，
   * 它会和那条轨道上已经在飞的弹幕**同一条线、同一个位置**一起飘，
   * 屏幕上就是一团糊字（用户 2026-09-20：「弹幕过多 + 显示区域小的时候
   * 会糊到一起」）。现在的取舍是：**非「海量弹幕」模式下宁可不显示**，
   * 也不叠在一起；真想全都要，就打开弹幕设置里的「海量弹幕」
   * （那一档本来就是「允许叠加绘制」）。
   */
  lastDroppedForLanes: number = 0;

  setLaneCount(count: number): void {
    this.laneCount = count < 1 ? 1 : count;
  }

  reset(): void {
    this.cursor = 0;
    this.scrollLaneFreeAt = [];
    this.topLaneFreeAt = [];
    this.bottomLaneFreeAt = [];
  }

  /**
   * 取本刻要发的弹幕。
   *
   * @param positionMs 当前播放位置
   * @param nowMs 当前墙钟（用于轨道占用判断）
   * @param timeOffsetMs 弹幕时间校准（正数表示弹幕提前出现）
   * @param durationMs 单条弹幕的停留/飞行时长
   * @param massive 是否允许叠加（忽略轨道占用）
   */
  take(entries: DanmakuEntry[], positionMs: number, nowMs: number,
    timeOffsetMs: number, durationMs: number,
    massive: boolean): ActiveDanmaku[] {
    const out: ActiveDanmaku[] = [];
    const dueMs: number = positionMs + timeOffsetMs;
    /**
     * **过期的直接跳过，不补发。**
     *
     * 参照实现 `player_item.dart:1046-1088` 的 `_emitDanmakusForCurrentPosition()`：
     * 每秒只取 `danDanmakus[当前秒]` 这一桶（`player_danmaku_controller.dart:120`），
     * 错过的那几秒**永远不补**。
     *
     * 本工程原来是「把游标到当前位置之间的全部发出去」，于是：
     *   - 刚打开弹幕（游标在 0、播放位置已经几分钟）→ 一次性几百条；
     *   - 关掉一分钟再打开、或者向前拖动进度之后 → 同样一次性几百条。
     * 这些弹幕在同一帧被创建，动画不一定条条都起得来，起不来的就停在
     * 左上角不动（用户 2026-09-18：「刚开弹幕时左上角叠很多弹幕定住」）。
     *
     * 窗口取 1200ms 而不是 1000：本工程的轮询是 500ms 一次（参照实现是 1s 定时器），
     * 留两次轮询的余量，正常的弹幕一条都不会漏。
     */
    const staleBeforeMs: number = dueMs - DANMAKU_STALE_WINDOW_MS;
    let skipped: number = 0;
    while (this.cursor < entries.length
      && entries[this.cursor].time * 1000 < staleBeforeMs) {
      this.cursor += 1;
      skipped += 1;
    }
    this.lastSkippedStale = skipped;
    let dropped: number = 0;
    while (this.cursor < entries.length
      && entries[this.cursor].time * 1000 <= dueMs) {
      const entry: DanmakuEntry = entries[this.cursor];
      this.cursor += 1;
      const lane: number = this.assignLane(entry.type, nowMs, durationMs, massive);
      /**
       * `-1` = 轨道全忙（只有非「海量弹幕」模式会返回）。这一条**丢掉不发**：
       * 硬塞进最早空出来的那条会与那条轨道上的弹幕叠在同一行同一位置，
       * 屏幕上是一团糊字。丢多少条记在 `lastDroppedForLanes` 里，调用方写日志。
       */
      if (lane < 0) {
        dropped += 1;
        continue;
      }
      const active = new ActiveDanmaku();
      active.key = `${entry.time}-${this.cursor}-${entry.message}`;
      active.message = entry.message;
      active.color = entry.color;
      active.type = entry.type === 4 || entry.type === 5 ? entry.type : 1;
      active.lane = lane;
      active.durationMs = durationMs;
      out.push(active);
    }
    this.lastDroppedForLanes = dropped;
    return out;
  }

  /**
   * 轨道分配：返回轨道序号，并把该轨的占用到期时间推后。
   *
   * **返回 `-1` 表示「所有轨道都还占着」**（非海量模式）。调用方据此丢弃这一条
   * ——「同一条线上叠两条」比「少显示一条」难看得多（见 `lastDroppedForLanes`）。
   * 海量弹幕模式（用户主动打开）仍然按取模轮转、允许叠加。
   */
  private assignLane(type: number, nowMs: number, durationMs: number,
    massive: boolean): number {
    const lanes: number[] = type === 5 ? this.topLaneFreeAt
      : type === 4 ? this.bottomLaneFreeAt : this.scrollLaneFreeAt;
    for (let i = 0; i < this.laneCount; i++) {
      if (i >= lanes.length) {
        lanes.push(0);
      }
    }
    if (massive) {
      // 海量弹幕：不看占用，按序轮转，允许叠着画
      const lane: number = this.cursor % this.laneCount;
      lanes[lane] = nowMs + durationMs;
      return lane;
    }
    for (let i = 0; i < this.laneCount; i++) {
      if (lanes[i] <= nowMs) {
        lanes[i] = nowMs + durationMs;
        return i;
      }
    }
    return -1;
  }

  /**
   * 挑「最早空出来」的那条轨道；**轨道全忙也照用**。
   *
   * 只给「自己发的弹幕」用：自己发的那条必须显示出来，宁可和别的弹幕叠一下。
   */
  private earliestLane(type: number, nowMs: number, durationMs: number): number {
    const lanes: number[] = type === 5 ? this.topLaneFreeAt
      : type === 4 ? this.bottomLaneFreeAt : this.scrollLaneFreeAt;
    for (let i = 0; i < this.laneCount; i++) {
      if (i >= lanes.length) {
        lanes.push(0);
      }
    }
    let earliest: number = 0;
    for (let i = 1; i < this.laneCount; i++) {
      if (lanes[i] < lanes[earliest]) {
        earliest = i;
      }
    }
    lanes[earliest] = nowMs + durationMs;
    return earliest;
  }

  /**
   * 自己发的弹幕（本地回声）。
   *
   * 参照实现 `player_item_panel.dart` 的 `_submitDanmakuText` 在「弹幕源」这条路上
   * **不向服务器发送**，源码注释：`// This provider has no send API; display a local echo.`
   * 只往画布上补一条 `selfSend: true` 的弹幕。这里同样：走滚动轨、照常占轨排队。
   */
  selfEcho(message: string, nowMs: number, durationMs: number): ActiveDanmaku {
    let lane: number = this.assignLane(1, nowMs, durationMs, false);
    if (lane < 0) {
      // 自己发的弹幕**不能丢**：轨道全忙就挑最早空出来的那条，叠一下也认
      lane = this.earliestLane(1, nowMs, durationMs);
    }
    const active = new ActiveDanmaku();
    active.key = `self-${nowMs}-${lane}`;
    active.message = message;
    active.color = '#FFFFFF';
    active.type = 1;
    active.lane = lane;
    active.durationMs = durationMs;
    return active;
  }
}
