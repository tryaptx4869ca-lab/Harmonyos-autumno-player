import { hilog } from '@kit.PerformanceAnalysisKit';
import { Plugin } from '../plugins/Plugin';
import { PluginImportParseResult, PluginImportParser } from './plugin/PluginImportParser';
import { ApiEndpoints } from '../request/config/ApiEndpoints';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnSelf';

/**
 * 规则导入解析自检（阶段五）。
 *
 * 用例就是工作计划 §23 里写好的那五条：
 *   1. 单条 JSON 导入成功
 *   2. 同名去重（后者覆盖前者）
 *   3. 空名失败
 *   4. api 级别过高拒收
 *   5. `kazumi://` 链接夹在说明文字里也能认出来
 *
 * 为什么需要：剪贴板导入依赖系统剪贴板，自动化里不好构造；而解析逻辑
 * （尤其是「链接后面跟一段话」这种脏输入）恰恰是最容易出错的地方，
 * 用自检把它钉住，比点 UI 可靠。
 */
export class PluginImportSelfCheck {
  private static passCount: number = 0;
  private static failCount: number = 0;

  static run(): void {
    PluginImportSelfCheck.passCount = 0;
    PluginImportSelfCheck.failCount = 0;
    hilog.info(DOMAIN, TAG, '=== 规则导入解析自检开始 ===');

    const json: string = PluginImportSelfCheck.sampleJson('自检规则A', '1.0',
      `${ApiEndpoints.apiLevel}`);

    // 1. 单条 JSON
    const single: PluginImportParseResult = PluginImportParser.parse(json);
    PluginImportSelfCheck.check('单条 JSON 导入成功',
      single.plugins.length === 1 && single.plugins[0].name === '自检规则A',
      `得到 ${single.plugins.length} 条 / 失败 ${single.failureCount()} 条`);

    // 2. 同名去重（后者覆盖前者，且保留一次）
    const newer: string = PluginImportSelfCheck.sampleJson('自检规则A', '2.0',
      `${ApiEndpoints.apiLevel}`);
    const deduped: PluginImportParseResult =
      PluginImportParser.parse(`[${json},${newer}]`);
    PluginImportSelfCheck.check('同名去重后只留 1 条',
      deduped.plugins.length === 1,
      `得到 ${deduped.plugins.length} 条`);
    PluginImportSelfCheck.check('同名去重取后者（版本 2.0）',
      deduped.plugins.length === 1 && deduped.plugins[0].version === '2.0',
      deduped.plugins.length === 1 ? `实际 ${deduped.plugins[0].version}` : '无条目');
    PluginImportSelfCheck.check('重复计数为 1',
      deduped.duplicateCount === 1, `实际 ${deduped.duplicateCount}`);

    // 3. 空名失败
    const emptyName: PluginImportParseResult =
      PluginImportParser.parse(PluginImportSelfCheck.sampleJson('', '1.0',
        `${ApiEndpoints.apiLevel}`));
    PluginImportSelfCheck.check('空名被拒收',
      emptyName.plugins.length === 0 && emptyName.failureCount() === 1,
      `条目 ${emptyName.plugins.length} / 失败 ${emptyName.failureCount()}`);

    // 4. api 级别过高拒收
    const tooNew: PluginImportParseResult =
      PluginImportParser.parse(PluginImportSelfCheck.sampleJson('自检规则B', '1.0',
        `${ApiEndpoints.apiLevel + 5}`));
    PluginImportSelfCheck.check('api 级别过高被拒收',
      tooNew.plugins.length === 0 && tooNew.failureCount() === 1,
      `条目 ${tooNew.plugins.length} / 失败 ${tooNew.failureCount()}`);

    // 5. kazumi:// 链接夹在说明文字里
    const link: string = PluginImportParser.jsonToKazumiBase64(json);
    const messy: string = `看看这条规则 ${link} 装完告诉我`;
    const fromLink: PluginImportParseResult = PluginImportParser.parse(messy);
    PluginImportSelfCheck.check('夹在文字里的 kazumi:// 链接能解析',
      fromLink.plugins.length === 1 && fromLink.plugins[0].name === '自检规则A',
      `得到 ${fromLink.plugins.length} 条 / 失败 ${fromLink.failureCount()} 条`);

    // 6. 链接往返：链接转 JSON 再转回链接，内容一致
    const roundTrip: string = PluginImportParser.kazumiBase64ToJson(link);
    PluginImportSelfCheck.check('链接解码回原文',
      roundTrip === json, `长度 ${roundTrip.length} vs ${json.length}`);

    // 7. 合法 JSON 数组里的坏条目不影响好条目
    const mixed: string = `[${json}, {"name":""}]`;
    const mixedResult: PluginImportParseResult = PluginImportParser.parse(mixed);
    PluginImportSelfCheck.check('坏条目被跳过、好条目保留',
      mixedResult.plugins.length === 1 && mixedResult.failureCount() === 1,
      `条目 ${mixedResult.plugins.length} / 失败 ${mixedResult.failureCount()}`);

    hilog.info(DOMAIN, TAG,
      '=== 规则导入解析自检结束：%{public}d 通过 / %{public}d 失败 ===',
      PluginImportSelfCheck.passCount, PluginImportSelfCheck.failCount);
  }

  /** 一条最小的合法规则（字段够 `Plugin.fromJson` 用）。 */
  private static sampleJson(name: string, version: string,
    apiLevel: string): string {
    const plugin = new Plugin();
    plugin.api = apiLevel;
    plugin.type = 'anime';
    plugin.name = name;
    plugin.version = version;
    plugin.baseUrl = 'https://example.com';
    plugin.searchURL = 'https://example.com/search?wd=@keyword';
    plugin.searchList = '//div[@class="item"]';
    plugin.searchName = '//a';
    plugin.searchResult = '//a';
    plugin.chapterRoads = '//div[@class="road"]';
    plugin.chapterResult = '//a';
    return JSON.stringify(plugin.toJson());
  }

  private static check(name: string, ok: boolean, detail: string): void {
    if (ok) {
      PluginImportSelfCheck.passCount += 1;
      hilog.info(DOMAIN, TAG, '✅ %{public}s', name);
    } else {
      PluginImportSelfCheck.failCount += 1;
      hilog.error(DOMAIN, TAG, '❌ %{public}s（%{public}s）', name, detail);
    }
  }
}
