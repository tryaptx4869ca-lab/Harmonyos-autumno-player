import { SettingsKeys } from '../services/storage/SettingsKeys';
import { SettingsStore } from '../services/storage/SettingsStore';

/** 用户可感知的封面等待阈值；超过后先盖开屏图，原请求继续完成。 */
const COVER_PLACEHOLDER_DELAY_MS: number = 500;

/**
 * 带延迟占位的番剧封面。
 *
 * 关键点：占位图是叠在**仍在加载**的原图上方，而不是替换 `src`。
 * 因此达到 500ms 后即使先看到开屏图，原封面仍会继续下载；一旦 `onComplete`
 * 就撤掉占位并显示原图。加载失败则直接显示占位。
 *
 * 外部仍可照常给这个组件设置 width / height / aspectRatio / position /
 * geometryTransition / onAreaChange 等通用属性，保持原有布局和 Hero 动画。
 */
@Component
export struct CoverImage {
  @Prop @Watch('onSourceChanged') src: ResourceStr = '';
  @Prop fit: ImageFit = ImageFit.Cover;
  @Prop radius: number = 0;
  @Prop sourceWidth: number = 0;
  @Prop sourceHeight: number = 0;

  @State private loaded: boolean = false;
  @State private showPlaceholder: boolean = false;
  private timerId: number = -1;

  aboutToAppear(): void {
    this.restartTimer();
  }

  aboutToDisappear(): void {
    this.clearTimer();
  }

  onSourceChanged(): void {
    this.restartTimer();
  }

  private restartTimer(): void {
    this.clearTimer();
    this.loaded = false;
    this.showPlaceholder = false;
    /**
     * 本地文件（自建番的封面，`file://…`）**不挂占位图**。
     *
     * 占位图用的是启动图（一张明亮的天空截图），盖在本地封面上就是一层白，
     * 从详情页返回、卡片重建重新解码时尤其明显（用户 2026-10-31：
     * 「封面会透一点白」）。本地文件要么立刻读到、要么就是文件没了——
     * 两种都不该盖一张亮图上去。
     */
    if (this.isLocalSource()) {
      return;
    }
    if (typeof this.src !== 'string' || this.src.length === 0
      || !SettingsStore.getBool(SettingsKeys.enableCoverFailurePlaceholder)) {
      return;
    }
    this.timerId = setTimeout(() => {
      this.timerId = -1;
      if (!this.loaded
        && SettingsStore.getBool(SettingsKeys.enableCoverFailurePlaceholder)) {
        this.showPlaceholder = true;
      }
    }, COVER_PLACEHOLDER_DELAY_MS);
  }

  /** 是不是沙箱里的本地图片。 */
  private isLocalSource(): boolean {
    if (typeof this.src !== 'string') {
      return false;
    }
    return this.src.indexOf('file://') === 0 || this.src.indexOf('/data/') === 0
      || this.src.indexOf('/storage/') === 0;
  }

  /**
   * 交给 `Image()` 的最终地址。
   *
   * 沙箱里的绝对路径要补 `file://` 前缀才认；调用方（自建番库、历史快照）
   * 有的存路径、有的存 `file://` 形式，这里统一处理一次，免得一处能显示、
   * 另一处只剩一个白框。
   */
  private resolvedSource(): ResourceStr {
    if (typeof this.src !== 'string') {
      return this.src;
    }
    const raw: string = this.src;
    if (raw.indexOf('/data/') === 0 || raw.indexOf('/storage/') === 0) {
      return `file://${raw}`;
    }
    return raw;
  }

  private clearTimer(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  private onLoaded(): void {
    this.loaded = true;
    this.showPlaceholder = false;
    this.clearTimer();
  }

  private onLoadFailed(): void {
    this.loaded = false;
    this.clearTimer();
    // 本地文件失败了就让它空着（底色由调用方的 backgroundColor 给），
    // 不要盖启动图——那会变成一层白。
    if (this.isLocalSource()) {
      this.showPlaceholder = false;
      return;
    }
    if (SettingsStore.getBool(SettingsKeys.enableCoverFailurePlaceholder)) {
      this.showPlaceholder = true;
    }
  }

  build() {
    Stack() {
      if (this.sourceWidth > 0 && this.sourceHeight > 0) {
        Image(this.resolvedSource())
          .width('100%')
          .height('100%')
          .objectFit(this.fit)
          .borderRadius(this.radius)
          .sourceSize({ width: this.sourceWidth, height: this.sourceHeight })
          .onComplete(() => {
            this.onLoaded();
          })
          .onError(() => {
            this.onLoadFailed();
          })
      } else {
        Image(this.resolvedSource())
          .width('100%')
          .height('100%')
          .objectFit(this.fit)
          .borderRadius(this.radius)
          .onComplete(() => {
            this.onLoaded();
          })
          .onError(() => {
            this.onLoadFailed();
          })
      }

      if (this.showPlaceholder) {
        Image($r('app.media.splash'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .borderRadius(this.radius)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    /**
     * 外部页面会给封面组件设置 `backgroundColor` 作为加载底色。
     * 图片自己虽然有 `borderRadius`，但组件根容器不裁切时，底色仍按矩形绘制，
     * 圆角外就会露出一圈/一块方形背景。这里把根容器按同一个圆角裁切。
     */
    .borderRadius(this.radius)
    .clip(true)
  }
}
