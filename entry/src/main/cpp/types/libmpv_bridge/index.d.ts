/**
 * 秋绪原生版 · mpv 桥
 *
 * 把 libmpv 的核心能力暴露给 ArkTS。属性设置顺序严格对齐参照实现
 * media_kit_video/lib/src/video_controller/ohos_video_controller/real.dart：
 *
 *   1. 创建后先把 vo 置为 'null'
 *   2. 绑定 surface 时设置 ohos-surface-size / wid / hwdec 等
 *   3. 最后再把 vo 设为实际渲染器（默认 gpu-next）
 */

/** 创建一个播放器实例，返回句柄（>0 有效，0 表示失败）。 */
export const create: () => number;

/** 销毁播放器实例。 */
export const destroy: (handle: number) => void;

/** 以字符串形式设置 mpv 选项（需在加载文件前设置）。 */
export const setOption: (handle: number, key: string, value: string) => void;

/** 以字符串形式设置 mpv 属性。 */
export const setProperty: (handle: number, key: string, value: string) => void;

/** 读取 mpv 属性，失败返回空串。 */
export const getProperty: (handle: number, key: string) => string;

/**
 * 执行 mpv 命令，args 为字符串数组，例如 ['loadfile', 'https://...']。
 *
 * **返回 mpv 的返回码**：0 = 成功，负数 = `MPV_ERROR_*`
 * （-4 MPV_ERROR_COMMAND / -10 MPV_ERROR_PROPERTY_UNAVAILABLE …）。
 * 截图链路要用它区分「命令没被接受」和「命令收下了但文件还没写出来」。
 */
export const command: (handle: number, args: string[]) => number;

/**
 * 绑定 XComponent 的 surface 并启用视频输出。
 * 必须在 XComponent 的 surface 创建之后调用。
 * 内部按「vo=null → 设置属性 → vo=gpu-next」的顺序执行。
 *
 * @param surfaceId XComponentController.getXComponentSurfaceId() 的返回值
 * @param vo 渲染器，留空则用 'gpu-next'
 * @param hwdec 硬件解码，留空则用 'auto'
 */
export const attachSurface: (
  handle: number,
  surfaceId: string,
  vo: string,
  hwdec: string
) => void;

/** surface 尺寸变化时调用，会同步更新 ohos-surface-size。 */
export const setSurfaceSize: (
  handle: number,
  width: number,
  height: number
) => void;

/** 当前是否已拿到有效的 OHNativeWindow。 */
export const hasSurface: () => boolean;
