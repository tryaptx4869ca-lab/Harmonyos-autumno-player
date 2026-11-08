/**
 * 版本比较。移植自参照实现 `lib/utils/version.dart`。
 */

/**
 * 严格整数解析。
 *
 * 必须自己判一遍：Dart 的 `int.parse('3b')` 抛 FormatException，
 * 而 JS 的 `Number.parseInt('3b')` 会得到 3——直接用后者会让
 * `1.3b` / `1.3c` 这种版本号被判成「相等」，兜底逻辑静默失效
 * （真机自检 `AutumnSelf` 抓到过这个差异）。
 */
function parseVersionSegment(text: string): number {
  if (!/^[+-]?\d+$/.test(text)) {
    throw new Error(`版本号含非数字段: ${text}`);
  }
  return Number.parseInt(text, 10);
}

/**
 * 按 `.` 分段做**数值**比较，缺段按 0；任一段不是数字则抛错
 * （调用方 `remoteIsNewer` 会捕获并退化成「字符串不相等即视为有更新」）。
 */
export function needUpdate(localVersion: string, remoteVersion: string): boolean {
  const localParts: string[] = localVersion.split('.');
  const remoteParts: string[] = remoteVersion.split('.');
  const maxLength: number = Math.max(localParts.length, remoteParts.length);
  for (let i = 0; i < maxLength; i++) {
    const localSegment: number =
      parseVersionSegment(i < localParts.length ? localParts[i] : '0');
    const remoteSegment: number =
      parseVersionSegment(i < remoteParts.length ? remoteParts[i] : '0');
    if (remoteSegment > localSegment) {
      return true;
    }
    if (remoteSegment < localSegment) {
      return false;
    }
  }
  return false;
}

/** 源码 `_remoteIsNewer`：比较失败时退化为「不相等即更新」。 */
export function remoteIsNewer(localVersion: string, remoteVersion: string): boolean {
  try {
    return needUpdate(localVersion, remoteVersion);
  } catch (e) {
    return localVersion !== remoteVersion;
  }
}
