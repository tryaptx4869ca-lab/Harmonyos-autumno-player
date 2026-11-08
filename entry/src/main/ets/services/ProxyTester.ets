import { http } from '@kit.NetworkKit';
import { ProxyAddress, ProxyUtils } from '../request/core/NetworkConfig';

/**
 * 代理连通性测试。对应参照实现里「代理配置」页的「测试连接」。
 *
 * 语义与源码一致：
 *   - 地址为空直接失败（文案「请输入代理地址」由页面给）；
 *   - 走代理发一次真实请求，2xx/3xx 视为成功；
 *   - 成功 → 页面写入 `proxyConfigured = true` 并**自动开启代理**；
 *     失败 → 写入 `false` 并关闭代理。
 */
export class ProxyTester {
  /** @returns 空串表示成功，否则是失败原因（可直接给用户看）。 */
  static async test(proxyUrl: string, testUrl: string): Promise<string> {
    const address: ProxyAddress | null = ProxyUtils.parseProxyUrl(proxyUrl);
    if (address === null) {
      return '无法解析代理地址，请检查格式（如 http://127.0.0.1:7890）';
    }
    const target: string = testUrl.trim().length > 0
      ? testUrl.trim() : 'https://www.bing.com';
    const client = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 15000,
        usingProxy: {
          host: address.host,
          port: address.port,
          exclusionList: []
        }
      };
      const response: http.HttpResponse = await client.request(target, options);
      const code: number = response.responseCode;
      if (code >= 200 && code < 400) {
        return '';
      }
      return `代理返回 ${code}`;
    } catch (error) {
      const err = error as Error;
      return `代理连接失败：${err.message}`;
    } finally {
      client.destroy();
    }
  }
}
