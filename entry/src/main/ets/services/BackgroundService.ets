import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BackgroundLevels, ThemeManager } from '../theme/ThemeManager';
import { BackgroundSeedExtractor, RgbaImage } from '../theme/ThemeEngine';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnBackground';

/** 处理结果。 */
export interface BackgroundApplyResult {
  readonly ok: boolean;
  readonly message: string;
  /** 取到的种子色（失败时为 0）。 */
  readonly seedArgb: number;
}

/** 解码结果。 */
class DecodedImage {
  readonly image: RgbaImage;
  readonly orientation: number;

  constructor(image: RgbaImage, orientation: number) {
    this.image = image;
    this.orientation = orientation;
  }
}

/**
 * 自定义背景。
 *
 * 对应源码 `theme_settings_page.dart` 的 `_pickCustomBackground` 前半段：
 *   1. 相册选图（`image_picker` → `PhotoViewPicker`）
 *   2. 拷进应用目录 `${ApplicationSupport}/${custom_background}<ext>`
 *   3. 解码后取种子色：24 宽 nearest 缩放 → 过滤亮度 → 求均值
 *   4. 落盘 path / seed / intensity，并刷新主题
 *
 * 尚未做的两步（源码里有、这里留白）：
 *   - 生成 4 档模糊 PNG（源码用 `img.gaussianBlur` 离线生成，
 *     原生版倾向改成渲染期 `blur()`，需要先与源码效果比对）
 *   - 背景图绘制到全局（由 `components/AppBackground.ets` 负责）
 */
export class BackgroundService {
  /** 解码上限：超过该像素数直接放弃取色，避免大图把内存顶爆。 */
  private static readonly MAX_DECODE_PIXELS: number = 40 * 1000 * 1000;
  /** 拷贝用的分块大小。 */
  private static readonly COPY_CHUNK: number = 1024 * 1024;
  /** 背景底图的目标宽度：对应参照实现的 `cacheWidth: 1080`（只限宽、保比例）。 */
  private static readonly BACKGROUND_TARGET_WIDTH: number = 1080;
  /** 背景底图的重编码质量（只作壁纸用，92 已经看不出损失）。 */
  private static readonly BACKGROUND_JPEG_QUALITY: number = 92;

  /**
   * 从相册选一张图并应用为主题背景。
   *
   * @param context 页面所属的 UIAbility 上下文（用于取沙箱目录）
   */
  static async pickAndApply(context: common.UIAbilityContext): Promise<BackgroundApplyResult> {
    let uri: string = '';
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = {
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      };
      const picked: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      if (picked.photoUris.length === 0) {
        return { ok: false, message: '未选择图片', seedArgb: 0 };
      }
      uri = picked.photoUris[0];
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '选图失败: %{public}s', err.message);
      return { ok: false, message: '选择图片失败', seedArgb: 0 };
    }

    // 目标文件名与源码一致：custom_background + 原扩展名
    const extension: string = BackgroundService.extensionOf(uri);
    const destination: string = `${context.filesDir}/custom_background${extension}`;
    try {
      await BackgroundService.copyFile(uri, destination);
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '拷贝背景失败: %{public}s', err.message);
      return { ok: false, message: '保存背景失败', seedArgb: 0 };
    }

    let seed: number = 0;
    try {
      const decoded: DecodedImage | null = await BackgroundService.decode(destination);
      if (decoded !== null) {
        seed = BackgroundSeedExtractor.extract(decoded.image, decoded.orientation);
        hilog.info(DOMAIN, TAG,
          '背景取色 seed=#%{public}s size=%{public}dx%{public}d orientation=%{public}d',
          (seed >>> 0).toString(16), decoded.image.width, decoded.image.height,
          decoded.orientation);
      } else {
        hilog.warn(DOMAIN, TAG, '背景解码失败，种子保持 0（主题将回落主题色）');
      }
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '背景取色异常: %{public}s', err.message);
    }

    // 强度按源码 `_snapLevel(customBackgroundIntensity)` 吸附到最近档位
    const intensity: number = BackgroundLevels.snap(
      ThemeManager.instance().backgroundIntensity);

    /**
     * 落盘背景改存**等比例缩略图**（宽 1080）。
     *
     * 为什么不能直接用原图：`AppBackground` 里那张 `Image` 需要限制解码尺寸，
     * 而 ArkUI 的 `sourceSize` 是「强制解码尺寸」——比例不一致会把位图拉伸
     * （用户 2026-10-07：自定义背景尺寸不对时被拉变形）。参照实现的做法是只限
     * **宽度**（`cacheWidth: 1080`，保比例），所以这里在选图时离线生成一张
     * 等比例副本：既不变形，又省掉每页「全分辨率解码 + 全分辨率模糊」。
     * 生成失败就退回原图（`AppBackground` 不设 sourceSize，同样不会变形）。
     */
    let backgroundPath: string = destination;
    const scaledPath: string =
      await BackgroundService.writeScaledCopy(destination, context);
    if (scaledPath.length > 0) {
      backgroundPath = scaledPath;
      // 缩略图才是被引用的那份，原图副本删掉省空间
      try {
        fileIo.unlinkSync(destination);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '删除原图副本失败: %{public}s', (e as Error).message);
      }
    }

    ThemeManager.instance().applyCustomBackground(backgroundPath, seed, intensity);
    return { ok: true, message: '已设置背景', seedArgb: seed };
  }

  /**
   * 把刚拷进来的原图重新编码成等比例缩略图（宽 ≤ 1080，EXIF 方向摆正）。
   *
   * 返回新文件路径；任何一步失败都返回空串，调用方退回使用原图。
   */
  private static async writeScaledCopy(sourcePath: string,
    context: common.UIAbilityContext): Promise<string> {
    const scaled: string = `${context.filesDir}/custom_background_scaled.jpg`;
    let file: fileIo.File | null = null;
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      file = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      source = image.createImageSource(file.fd);
      const info: image.ImageInfo = await source.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      if (width <= 0 || height <= 0) {
        return '';
      }
      // 只限宽、按原图比例算高——这样解码出来的位图不会变形
      const targetWidth: number =
        Math.min(BackgroundService.BACKGROUND_TARGET_WIDTH, width);
      const targetHeight: number =
        Math.max(1, Math.round(height * targetWidth / width));
      const options: image.DecodingOptions = {
        desiredSize: { width: targetWidth, height: targetHeight },
        /**
         * 原图的 EXIF 方向**不会**被解码器自动应用（取色那条路径也是自己按
         * orientation 转的，见 `BackgroundSeedExtractor`），重编码时必须显式
         * 摆正，否则竖拍照片会变成横的。只处理常见的 3 / 6 / 8。
         */
        rotate: BackgroundService.rotateFor(
          await BackgroundService.readOrientation(source))
      };
      pixelMap = await source.createPixelMap(options);
      packer = image.createImagePacker();
      const buffer: ArrayBuffer = await packer.packing(pixelMap, {
        format: 'image/jpeg',
        quality: BackgroundService.BACKGROUND_JPEG_QUALITY
      });
      const out = fileIo.openSync(scaled,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(out.fd, buffer);
      } finally {
        fileIo.closeSync(out);
      }
      hilog.info(DOMAIN, TAG,
        '背景底图 %{public}dx%{public}d → %{public}dx%{public}d',
        width, height, targetWidth, targetHeight);
      return scaled;
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '生成背景缩略图失败: %{public}s', err.message);
      return '';
    } finally {
      if (packer !== null) {
        packer.release();
      }
      if (pixelMap !== null) {
        pixelMap.release();
      }
      if (source !== null) {
        source.release();
      }
      if (file !== null) {
        fileIo.closeSync(file);
      }
    }
  }

  /** 读 EXIF 方向；没有或解析不出来时按 1（无需旋转）。 */
  private static async readOrientation(source: image.ImageSource): Promise<number> {
    try {
      const text: string = await source.getImageProperty(image.PropertyKey.ORIENTATION);
      const parsed: number = Number.parseInt(text, 10);
      return Number.isNaN(parsed) ? 1 : parsed;
    } catch (e) {
      return 1;
    }
  }

  /** EXIF 方向 → 解码时需要的顺时针旋转角度。 */
  private static rotateFor(orientation: number): number {
    if (orientation === 3) {
      return 180;
    }
    if (orientation === 6) {
      return 90;
    }
    if (orientation === 8) {
      return 270;
    }
    return 0;
  }

  /** 清除背景：先删文件再清设置（源码 `_clearCustomBackground`）。 */
  static async clear(context: common.UIAbilityContext): Promise<void> {
    const manager: ThemeManager = ThemeManager.instance();
    const paths: string[] = [manager.backgroundPath, manager.backgroundBlurredPath];
    for (let i = 0; i < paths.length; i++) {
      const path: string = paths[i];
      if (path.length === 0) {
        continue;
      }
      try {
        if (fileIo.accessSync(path)) {
          fileIo.unlinkSync(path);
        }
      } catch (e) {
        const err = e as Error;
        hilog.warn(DOMAIN, TAG, '删除背景文件失败 %{public}s: %{public}s', path, err.message);
      }
    }
    manager.clearCustomBackground();
  }

  /** 取文件扩展名（含点）；没有扩展名时按源码回落到 `.jpg`。 */
  private static extensionOf(uri: string): string {
    const slash: number = uri.lastIndexOf('/');
    const name: string = slash >= 0 ? uri.substring(slash + 1) : uri;
    const dot: number = name.lastIndexOf('.');
    if (dot < 0 || dot === name.length - 1) {
      return '.jpg';
    }
    return name.substring(dot);
  }

  /** 分块拷贝，避免大图一次性读进内存。 */
  private static async copyFile(sourceUri: string, destination: string): Promise<void> {
    const source = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
    try {
      const size: number = fileIo.statSync(source.fd).size;
      const dest = fileIo.openSync(destination,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        const buffer: ArrayBuffer = new ArrayBuffer(BackgroundService.COPY_CHUNK);
        let offset: number = 0;
        while (offset < size) {
          const want: number = Math.min(BackgroundService.COPY_CHUNK, size - offset);
          const read: number =
            fileIo.readSync(source.fd, buffer, { offset: offset, length: want });
          if (read <= 0) {
            break;
          }
          fileIo.writeSync(dest.fd, buffer, { offset: offset, length: read });
          offset += read;
        }
      } finally {
        fileIo.closeSync(dest);
      }
    } finally {
      fileIo.closeSync(source);
    }
  }

  /**
   * 解码成 RGBA 位图并读取 EXIF 方向。
   * 位图顺序固定为 RGBA_8888，与 `BackgroundSeedExtractor` 的约定一致。
   */
  private static async decode(path: string): Promise<DecodedImage | null> {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const source: image.ImageSource = image.createImageSource(file.fd);
      try {
        let orientation: number = 1;
        try {
          const text: string = await source.getImageProperty(image.PropertyKey.ORIENTATION);
          const parsed: number = Number.parseInt(text, 10);
          orientation = Number.isNaN(parsed) ? 1 : parsed;
        } catch (e) {
          // 没有 EXIF 方向时按 1 处理（源码同样视作无需旋转）
        }

        const options: image.DecodingOptions = {
          desiredPixelFormat: image.PixelMapFormat.RGBA_8888
        };
        const pixelMap: image.PixelMap = await source.createPixelMap(options);
        try {
          const info: image.ImageInfo = await pixelMap.getImageInfo();
          const width: number = info.size.width;
          const height: number = info.size.height;
          if (width <= 0 || height <= 0 || width * height > BackgroundService.MAX_DECODE_PIXELS) {
            hilog.warn(DOMAIN, TAG,
              '背景尺寸超限，跳过取色: %{public}dx%{public}d', width, height);
            return null;
          }
          const buffer: ArrayBuffer = new ArrayBuffer(width * height * 4);
          await pixelMap.readPixelsToBuffer(buffer);
          return new DecodedImage(new RgbaImage(new Uint8Array(buffer), width, height),
            orientation);
        } finally {
          pixelMap.release();
        }
      } finally {
        source.release();
      }
    } finally {
      fileIo.closeSync(file);
    }
  }
}
