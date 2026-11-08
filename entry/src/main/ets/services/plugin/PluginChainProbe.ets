import { Plugin } from '../../plugins/Plugin';
import { Road, SearchItem } from '../../model/SearchModels';
import { RuleChapterTrace, RuleEngine, RuleSearchTrace } from './RuleEngine';

/**
 * 阶段 2 验收探针：用一条**适配当前站点结构**的 7sefun 规则
 * 跑通「搜索 → 线路 → 剧集」，返回第一条真实播放页（vodplay）地址。
 *
 * 为什么不用仓库里的 7sefun v1.3：见 docs/02-工作计划.md §4——
 * 站点改版后它的 `searchList`（`//div[2]/div[2]/div[2]/div[2]/div`）
 * 在当前页面上匹配不到节点。这里按报告 §7 的实测结果就地写一条规则，
 * 只用来验收链路；正式规则仍然从规则仓库下载，不写进规则库。
 */
export class PluginChainProbe {
  /** 报告 §7 用的关键词，站点上稳定有两条结果。 */
  static readonly defaultKeyword: string = '葬送的芙莉莲';

  /** 适配当前 7sefun 结构的规则。 */
  static sevenFun(): Plugin {
    const plugin = new Plugin();
    plugin.name = '7sefun(验收适配)';
    plugin.version = '1.3-probe';
    plugin.type = 'anime';
    plugin.baseUrl = 'https://www.7sefun.top';
    plugin.searchURL = 'https://www.7sefun.top/vodsearch/-------------.html?wd=@keyword';
    plugin.searchList = "//div[@class='video anim']";
    plugin.searchName = "//div[@class='video-by']";
    plugin.searchResult = "//a[@class='video-wrapper']";
    plugin.chapterRoads = "//div[@class='chat']";
    plugin.chapterResult = "//a[contains(@href,'/vodplay/')]";
    plugin.usePost = false;
    return plugin;
  }

  /**
   * 搜索 → 取第一条结果 → 转详情页 → 取第一条线路的第一集。
   *
   * `log` 把每一步交给调用方（原型页写进日志列表，同时进 hilog），
   * 这样真机日志里能直接看到链路每一步的耗时。
   */
  static async firstEpisodeUrl(plugin: Plugin, keyword: string,
    log: (message: string) => void): Promise<string> {
    const config = plugin.executionConfig();
    log(`[chain] 搜索「${keyword}」`);
    const searchStarted: number = Date.now();
    const search: RuleSearchTrace = await RuleEngine.search(config, keyword);
    const items: SearchItem[] = search.response.data;
    log(`[chain] 搜索命中 ${items.length} 条，耗时 ${Date.now() - searchStarted}ms`);
    if (items.length === 0) {
      throw new Error('搜索结果为空');
    }
    const first: SearchItem = items[0];
    log(`[chain] 选中「${first.name}」→ ${first.src}`);

    const chapterStarted: number = Date.now();
    const chapters: RuleChapterTrace =
      await RuleEngine.queryChapters(config, first.src);
    log(`[chain] 详情页线路 ${chapters.roads.length} 条，耗时 ${Date.now() - chapterStarted}ms`);
    if (chapters.roads.length === 0) {
      throw new Error('详情页没有可用线路');
    }
    const road: Road = chapters.roads[0];
    if (road.data.length === 0) {
      throw new Error(`${road.name} 没有剧集`);
    }
    log(`[chain] ${road.name}：${road.data.length} 集，第 1 集「${road.identifier[0]}」`);
    return road.data[0];
  }
}
