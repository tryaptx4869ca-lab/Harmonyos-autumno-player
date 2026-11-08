/**
 * 应用元信息。
 *
 * `appDisplayName` 取自参照实现 `lib/utils/constants.dart` 的 `appDisplayName`；
 * `appVersion` 是**原生版自己的版本号**，显示在「我的 → 关于 → 版本号」那一行。
 *
 * ⚠️ 改版本时**两处一起改**：这里和 `AppScope/app.json5` 的 `versionName`。
 * （2026-09-19 定版 2.0.0：此前这里一直停在 Flutter 版的 `1.0.1`，与安装包
 * 的版本对不上，用户报「我的页版本号也要改」。
 * 2026-09-22 升 2.0.1：目录实时进度条 + tag 条件筛选修复那一版。
 * 本公开快照以 2.3.4 为历史功能边界，供代码审阅和许可证归档使用。
 * 它并非从 2.3.4 二进制包逐字恢复，也不保证与历史发布包完全一致。）
 */
export const appDisplayName: string = '秋绪';
export const appVersion: string = '2.3.4';
