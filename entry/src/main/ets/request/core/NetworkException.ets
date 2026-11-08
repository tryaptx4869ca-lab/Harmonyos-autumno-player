import { connection } from '@kit.NetworkKit';

/** 网络异常类型。对应参照实现 `network_exception.dart` 的枚举，顺序一致。 */
export enum NetworkExceptionType {
  badCertificate = 0,
  badResponse = 1,
  cancel = 2,
  connectionError = 3,
  connectionTimeout = 4,
  receiveTimeout = 5,
  sendTimeout = 6,
  parseError = 7,
  unknown = 8
}

/** 统一的网络异常。 */
export class NetworkException extends Error {
  readonly type: NetworkExceptionType;
  readonly statusCode: number;
  readonly rawError: string;

  constructor(type: NetworkExceptionType, message: string,
    statusCode: number, rawError: string) {
    super(message);
    this.type = type;
    this.statusCode = statusCode;
    this.rawError = rawError;
  }

  toString(): string {
    const status: string = this.statusCode === 0 ? '' : ` (${this.statusCode})`;
    return `NetworkException.${this.type}${status}: ${this.message}`;
  }
}

/**
 * DioException → NetworkException 的对应实现。
 *
 * 上游按 Dio 的异常类型分流；鸿蒙这边等价物是 NetworkKit 的
 * `BusinessError.code`（2300xxx 系列）+ HTTP 状态码，因此这里做一张显式的映射表，
 * 文案与上游逐字一致（错误页直接展示这些字符串）。
 */
export class NetworkErrorMapper {
  /** NetworkKit 错误码 → 异常类型。 */
  private static readonly codeMap: Map<number, NetworkExceptionType> =
    NetworkErrorMapper.buildCodeMap();

  private static buildCodeMap(): Map<number, NetworkExceptionType> {
    const map: Map<number, NetworkExceptionType> = new Map<number, NetworkExceptionType>();
    // 2300006 无法解析主机；2300007 连接服务器失败；2300005 代理校验失败
    map.set(2300005, NetworkExceptionType.connectionError);
    map.set(2300006, NetworkExceptionType.connectionError);
    map.set(2300007, NetworkExceptionType.connectionError);
    map.set(2300008, NetworkExceptionType.connectionError);
    // 2300028 操作超时
    map.set(2300028, NetworkExceptionType.connectionTimeout);
    // 2300052 服务器返回空 ／ 2300060 证书校验失败
    map.set(2300060, NetworkExceptionType.badCertificate);
    return map;
  }

  /** 把 NetworkKit 抛出的错误映射成 NetworkException。 */
  static map(code: number, message: string): NetworkException {
    const mapped: NetworkExceptionType | undefined = NetworkErrorMapper.codeMap.get(code);
    const type: NetworkExceptionType =
      mapped === undefined ? NetworkExceptionType.unknown : mapped;
    return new NetworkException(type, NetworkErrorMapper.messageOf(type, message),
      code, message);
  }

  /** 非 2xx 响应。 */
  static badResponse(statusCode: number, raw: string): NetworkException {
    return new NetworkException(NetworkExceptionType.badResponse,
      '服务器异常，请稍后重试！', statusCode, raw);
  }

  /** JSON 解析失败（对应源码 `parse`）。 */
  static parse(raw: string): NetworkException {
    return new NetworkException(NetworkExceptionType.parseError,
      '响应解析失败', 0, raw);
  }

  /** 文案与源码 `mapException` 逐字一致。 */
  private static messageOf(type: NetworkExceptionType, raw: string): string {
    switch (type) {
      case NetworkExceptionType.badCertificate:
        return '证书有误！';
      case NetworkExceptionType.cancel:
        return '请求已被取消，请重新请求';
      case NetworkExceptionType.connectionError:
        return '连接错误，请检查网络设置';
      case NetworkExceptionType.connectionTimeout:
        return '网络连接超时，请检查网络设置';
      case NetworkExceptionType.receiveTimeout:
        return '响应超时，请稍后重试！';
      case NetworkExceptionType.sendTimeout:
        return '发送请求超时，请检查网络设置';
      case NetworkExceptionType.parseError:
        return '响应解析超时，请稍后重试！';
      default:
        return `${NetworkErrorMapper.connectionLabel()} 网络异常`.trim();
    }
  }

  /** 连接状态描述（源码 `_connectionLabel`，文案逐字一致）。 */
  static connectionLabel(): string {
    try {
      const net: connection.NetHandle = connection.getDefaultNetSync();
      if (net === undefined || net.netId === 0) {
        return '未连接到任何网络';
      }
      const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);
      const bearers: connection.NetBearType[] = caps.bearerTypes;
      for (let i = 0; i < bearers.length; i++) {
        switch (bearers[i]) {
          case connection.NetBearType.BEARER_CELLULAR:
            return '正在使用移动流量';
          case connection.NetBearType.BEARER_WIFI:
            return '正在使用wifi';
          case connection.NetBearType.BEARER_ETHERNET:
            return '正在使用局域网';
          case connection.NetBearType.BEARER_VPN:
            return '正在使用代理网络';
          case connection.NetBearType.BEARER_BLUETOOTH:
            return '正在使用其他网络';
          default:
            break;
        }
      }
      return '正在使用其他网络';
    } catch (e) {
      return '';
    }
  }
}
