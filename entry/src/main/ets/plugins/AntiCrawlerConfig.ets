import { JsonUtils } from '../model/JsonUtils';

/** 反反爬验证类型（对应源码 `CaptchaType`，保留整数以便向后兼容）。 */
export class CaptchaType {
  static readonly imageCaptcha: number = 1;
  static readonly autoClickButton: number = 2;
  static readonly customJavaScript: number = 3;
}

/** 验证页检测方式（对应源码 `CaptchaDetectType`）。 */
export class CaptchaDetectType {
  static readonly xpath: number = 1;
  static readonly text: number = 2;
  static readonly regex: number = 3;
}

/**
 * 反反爬配置。
 * 逐字段移植自 `lib/plugins/anti_crawler_config.dart`。
 * 仅在 XPath 搜索响应是验证页时启用：WebView 加载搜索页 → 完成验证 → 存 Cookie → 重试。
 */
export class AntiCrawlerConfig {
  enabled: boolean = false;
  captchaType: number = CaptchaType.imageCaptcha;
  captchaImage: string = '';
  captchaInput: string = '';
  captchaButton: string = '';
  captchaDetectType: number = CaptchaDetectType.xpath;
  captchaDetectValue: string = '';
  captchaScript: string = '';

  static empty(): AntiCrawlerConfig {
    return new AntiCrawlerConfig();
  }

  static fromJson(json: Record<string, Object>): AntiCrawlerConfig {
    const config = new AntiCrawlerConfig();
    config.enabled = JsonUtils.boolOf(json, 'enabled');
    config.captchaType = JsonUtils.intOf(json, 'captchaType', CaptchaType.imageCaptcha);
    config.captchaImage = JsonUtils.str(json, 'captchaImage');
    config.captchaInput = JsonUtils.str(json, 'captchaInput');
    config.captchaButton = JsonUtils.str(json, 'captchaButton');
    config.captchaDetectType =
      JsonUtils.intOf(json, 'captchaDetectType', CaptchaDetectType.xpath);
    config.captchaDetectValue = JsonUtils.str(json, 'captchaDetectValue');
    config.captchaScript = JsonUtils.str(json, 'captchaScript');
    return config;
  }

  toJson(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['enabled'] = this.enabled;
    out['captchaType'] = this.captchaType;
    out['captchaImage'] = this.captchaImage;
    out['captchaInput'] = this.captchaInput;
    out['captchaButton'] = this.captchaButton;
    out['captchaDetectType'] = this.captchaDetectType;
    out['captchaDetectValue'] = this.captchaDetectValue;
    out['captchaScript'] = this.captchaScript;
    return out;
  }

  copyWith(enabled: boolean, captchaType: number, captchaImage: string,
    captchaInput: string, captchaButton: string, captchaDetectType: number,
    captchaDetectValue: string, captchaScript: string): AntiCrawlerConfig {
    const config = new AntiCrawlerConfig();
    config.enabled = enabled;
    config.captchaType = captchaType;
    config.captchaImage = captchaImage;
    config.captchaInput = captchaInput;
    config.captchaButton = captchaButton;
    config.captchaDetectType = captchaDetectType;
    config.captchaDetectValue = captchaDetectValue;
    config.captchaScript = captchaScript;
    return config;
  }
}
