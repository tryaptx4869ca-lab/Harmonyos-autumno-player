import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiBodyType } from '../../plugins/ApiRuleConfig';
import { ApiClient, ApiResponse } from '../../request/core/ApiClient';
import { PreparedRuleRequest } from './RuleEngineModels';
import { Logger } from '../Logger';
import { PluginCookieManager } from './PluginCookieManager';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnRule';

/**
 * 规则站点请求。
 * 对应参照实现 `lib/request/clients/plugin_site_client.dart` +
 * `rule_engine.dart` 里的 `_DefaultRuleRequestExecutor`。
 *
 * 关键行为（逐条对齐源码）：
 *   - `referer` 固定为 `${baseUrl}/`
 *   - 规则自定义头**键名小写**后并入，与内置头冲突时以规则为准
 *   - 通过了验证码的插件，其 User-Agent 必须覆盖规则自己的
 *     （clearance cookie 与 UA 绑定，换 UA 会被重新判定为验证页）
 *   - POST 的 content-type 由 bodyType 决定：json / form
 */
export class PluginSiteClient {
  static async execute(request: PreparedRuleRequest, pluginName: string,
    baseUrl: string): Promise<string> {
    const headers: Record<string, string> = {};
    headers['referer'] = `${baseUrl}/`;

    // Cookie 与 UA 都来自 PluginCookieManager（每插件独立）
    const cookie: string = request.includeCookies
      ? PluginCookieManager.cookieHeaderFor(pluginName, request.url) : '';
    if (cookie.length > 0) {
      headers['cookie'] = cookie;
    }

    const ruleHeaderKeys: string[] = Object.keys(request.headers);
    for (let i = 0; i < ruleHeaderKeys.length; i++) {
      headers[ruleHeaderKeys[i].toLowerCase()] = request.headers[ruleHeaderKeys[i]];
    }

    if (cookie.length > 0) {
      // clearance cookie 与签发时的 UA 绑定：必须用同一个 UA 重放
      const verified: string = PluginCookieManager.userAgentFor(pluginName);
      if (verified.length > 0) {
        headers['user-agent'] = verified;
      }
      // 站点是按 UA 判定「有没有验证过」的（主机侧对照实验：换 UA 重放同一会话
      // 会被打回验证页）。所以这里把「实际发出去的 UA 是哪一个」记下来——
      // 否则失败时只能看到「重搜仍被判需要验证」，看不出是 UA 掉回随机值了。
      hilog.info(DOMAIN, TAG, '%{public}s 重搜带 Cookie(%{public}d 字符) UA=%{public}s',
        pluginName, cookie.length,
        verified.length > 0 ? '验证时的 UA' : '规则/随机 UA（无验证 UA）');
      // 同一条也写进应用日志文件：真机排查「验证过了还要求验证」就靠这几行
      Logger.info('AutumnCaptcha',
        `重搜带 Cookie：${pluginName} ${cookie.length} 字符，` +
          `UA=${verified.length > 0 ? '验证时的 UA' : '规则/随机 UA（无验证 UA）'}`);
    }

    let body: string | undefined = undefined;
    if (request.method === 'POST') {
      if (request.bodyType === ApiBodyType.json) {
        if (headers['content-type'] === undefined) {
          headers['content-type'] = 'application/json';
        }
        body = JSON.stringify(request.body);
      } else if (request.bodyType === ApiBodyType.form) {
        if (headers['content-type'] === undefined) {
          headers['content-type'] = 'application/x-www-form-urlencoded';
        }
        body = PluginSiteClient.encodeForm(request.body);
      }
    }

    const url: string = PluginSiteClient.appendQuery(request.url, request.query);
    const method: http.RequestMethod =
      request.method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET;
    const response: ApiResponse =
      await ApiClient.pluginDio().requestWith(url, method, body, headers);
    if (!response.ok) {
      throw new Error(`HTTP ${response.statusCode} ${url}`);
    }
    hilog.info(DOMAIN, TAG, '%{public}s %{public}s -> %{public}d len=%{public}d',
      request.method, url, response.statusCode, response.body.length);
    return response.body;
  }

  /** 查询参数拼到 URL 上（已存在 query 时用 `&`）。 */
  private static appendQuery(url: string, query: Record<string, Object>): string {
    const keys: string[] = Object.keys(query);
    if (keys.length === 0) {
      return url;
    }
    const parts: string[] = [];
    for (let i = 0; i < keys.length; i++) {
      parts.push(`${encodeURIComponent(keys[i])}=${encodeURIComponent(`${query[keys[i]]}`)}`);
    }
    const separator: string = url.indexOf('?') >= 0 ? '&' : '?';
    return `${url}${separator}${parts.join('&')}`;
  }

  /** 表单体编码。 */
  private static encodeForm(body: Object | undefined): string {
    if (body === undefined || body === null) {
      return '';
    }
    const rec: Record<string, Object> | null = typeof body === 'object' && !Array.isArray(body)
      ? body as Record<string, Object> : null;
    if (rec === null) {
      return '';
    }
    const keys: string[] = Object.keys(rec);
    const parts: string[] = [];
    for (let i = 0; i < keys.length; i++) {
      parts.push(`${encodeURIComponent(keys[i])}=${encodeURIComponent(`${rec[keys[i]]}`)}`);
    }
    return parts.join('&');
  }
}
