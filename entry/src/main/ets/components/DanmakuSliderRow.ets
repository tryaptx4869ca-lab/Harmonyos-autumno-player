import { AppColor } from '../theme/AppColors';
import { HarmonySlider } from './HarmonySlider';

/**
 * 弹幕设置里的一行滑杆：标题 + 当前值 + HarmonyOS 滑杆。
 *
 * 为什么必须是**独立组件**，而不是页面里的 `@Builder`：
 * ArkUI 的 `@Builder` 带值参数时不会随状态刷新（工程里已经踩过并记录过）。
 * 原来的 `danmakuSliderRow(label, valueText, value, …)` 把值和文案都当参数传，
 * 拖动时父层不重渲染 → 右侧数值一直是旧值、滑块也停在原地
 * （用户 2026-09-18：「弹幕设置卡片中不能即时拖动修改条」）。
 *
 * 组件自己持有 `@State current`：手指到哪、数值与滑块就到哪，
 * 变化再通过 `onChanged` 交给调用方落盘（真正的效果即时生效，
 * 因为渲染链路每次都读设置）。
 *
 * 文案格式由三个参数拼出来，避免为每个滑杆写一个组件：
 * `显示值 = (current × displayScale).toFixed(decimals) + suffix`
 * （字体大小 20 / 不透明度 80% / 行间距 1.0 / 停留时间 8 秒）。
 */
@Component
export struct DanmakuSliderRow {
  label: string = '';
  /** 初始值（一般取设置里的当前值）。 */
  initial: number = 0;
  min: number = 0;
  max: number = 1;
  /** 步长；0 = 连续取值。 */
  step: number = 0;
  /** 显示倍率（如不透明度 ×100）。 */
  displayScale: number = 1;
  /** 显示小数位。 */
  decimals: number = 0;
  /** 显示后缀（如 `%` / ` 秒`）。 */
  suffix: string = '';
  onChanged: (value: number) => void = () => {
  };

  @State private current: number = 0;

  aboutToAppear(): void {
    this.current = this.initial;
  }

  /** 步长 → `divisions`（HarmonySlider 用它做取整）。 */
  private divisions(): number {
    if (this.step <= 0) {
      return 0;
    }
    return Math.max(1, Math.round((this.max - this.min) / this.step));
  }

  private valueText(): string {
    return `${(this.current * this.displayScale).toFixed(this.decimals)}${this.suffix}`;
  }

  build() {
    Column() {
      Row() {
        Text(this.label)
          .fontSize(15)
          .fontColor(AppColor.onSurface)
          .layoutWeight(1)
        Text(this.valueText())
          .fontSize(13)
          .fontColor(AppColor.onSurfaceVariant)
      }
      .width('100%')

      HarmonySlider({
        value: this.current,
        min: this.min,
        max: this.max,
        divisions: this.divisions(),
        onChanged: (value: number) => {
          this.current = value;
          this.onChanged(value);
        }
      })
        .width('100%')
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }
}
