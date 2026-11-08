import { SettingsKeys } from '../../services/storage/SettingsKeys';
import { SettingsStore } from '../../services/storage/SettingsStore';

/**
 * 网络配置。
 * 移植自参照实现 `lib/request/core/network_config.dart`。
 *
 * 默认值一致：连接 12 秒、接收 12 秒；下载专用实例在工厂里覆盖成 15 / 30。
 * 代理开启时从 `proxyUrl` 解析 host/port，并放开自签证书
 * （与源码一致：`allowBadCertificates: true`，因为代理常见中间人证书）。
 */
export class NetworkConfig {
  connectTimeoutMs: number = 12000;
  receiveTimeoutMs: number = 12000;
  sendTimeoutMs: number = 0;
  proxyHost: string = '';
  proxyPort: number = 0;
  allowBadCertificates: boolean = false;
  enableLog: boolean = true;

  constructor(connectTimeoutMs: number, receiveTimeoutMs: number,
    sendTimeoutMs: number, proxyHost: string, proxyPort: number,
    allowBadCertificates: boolean, enableLog: boolean) {
    this.connectTimeoutMs = connectTimeoutMs;
    this.receiveTimeoutMs = receiveTimeoutMs;
    this.sendTimeoutMs = sendTimeoutMs;
    this.proxyHost = proxyHost;
    this.proxyPort = proxyPort;
    this.allowBadCertificates = allowBadCertificates;
    this.enableLog = enableLog;
  }

  get hasProxy(): boolean {
    return this.proxyHost.length > 0 && this.proxyPort > 0;
  }

  /** 从设置构造（对应源码 `NetworkConfig.fromSettings`）。 */
  static fromSettings(connectTimeoutMs: number = 12000,
    receiveTimeoutMs: number = 12000, sendTimeoutMs: number = 0): NetworkConfig {
    const proxyEnable: boolean = SettingsStore.getBool(SettingsKeys.proxyEnable);
    if (!proxyEnable) {
      return new NetworkConfig(connectTimeoutMs, receiveTimeoutMs, sendTimeoutMs,
        '', 0, false, true);
    }
    const proxyUrl: string = SettingsStore.getString(SettingsKeys.proxyUrl);
    const parsed: ProxyAddress | null = ProxyUtils.parseProxyUrl(proxyUrl);
    if (parsed === null) {
      // 源码在此记一条 warn 后回落成直连
      return new NetworkConfig(connectTimeoutMs, receiveTimeoutMs, sendTimeoutMs,
        '', 0, false, true);
    }
    return new NetworkConfig(connectTimeoutMs, receiveTimeoutMs, sendTimeoutMs,
      parsed.host, parsed.port, true, true);
  }
}

/** 解析出来的代理地址。 */
export class ProxyAddress {
  readonly host: string;
  readonly port: number;

  constructor(host: string, port: number) {
    this.host = host;
    this.port = port;
  }
}

/**
 * 代理地址解析。
 * 对应 `lib/services/network/proxy_utils.dart`：接受带 scheme 或不带 scheme 的
 * `host:port`，缺少端口或端口非法时返回 null。
 */
export class ProxyUtils {
  static parseProxyUrl(raw: string): ProxyAddress | null {
    const trimmed: string = raw.trim();
    if (trimmed.length === 0) {
      return null;
    }
    let rest: string = trimmed;
    const schemeEnd: number = rest.indexOf('://');
    if (schemeEnd >= 0) {
      rest = rest.substring(schemeEnd + 3);
    }
    const slash: number = rest.indexOf('/');
    if (slash >= 0) {
      rest = rest.substring(0, slash);
    }
    const colon: number = rest.lastIndexOf(':');
    if (colon <= 0) {
      return null;
    }
    const host: string = rest.substring(0, colon);
    const port: number = Number.parseInt(rest.substring(colon + 1), 10);
    if (host.length === 0 || Number.isNaN(port) || port <= 0 || port > 65535) {
      return null;
    }
    return new ProxyAddress(host, port);
  }
}
