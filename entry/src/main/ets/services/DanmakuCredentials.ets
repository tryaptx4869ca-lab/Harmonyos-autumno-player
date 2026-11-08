import { SettingsStore } from './storage/SettingsStore';
import { SettingsKeys } from './storage/SettingsKeys';

/**
 * 弹弹play 凭据读取入口。
 *
 * 公开快照不包含任何内置应用凭据。用户必须在设置中填写自己申请的
 * AppId 和 AppSecret 后才能使用该来源。
 */
export class DanmakuCredentials {
  static appId(): string {
    return SettingsStore.getString(SettingsKeys.danmakuDanDanAppId).trim();
  }

  static primarySecret(): string {
    return SettingsStore.getString(SettingsKeys.danmakuDanDanAppSecret).trim();
  }

  static alternateSecret(): string {
    return '';
  }

  static usable(): boolean {
    return DanmakuCredentials.appId().length > 0 &&
      DanmakuCredentials.primarySecret().length > 0;
  }

  static customized(): boolean {
    return DanmakuCredentials.usable();
  }
}
