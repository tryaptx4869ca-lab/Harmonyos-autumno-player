import { hilog } from '@kit.PerformanceAnalysisKit';
import { M3u8AdFilter } from './M3u8AdFilter';
import {
  M3u8Key,
  M3u8MediaPlaylist,
  M3u8Parser,
  M3u8Segment
} from './M3u8Parser';
import { DownloadStatus } from '../model/DownloadModels';
import { Logger } from './Logger';

const DOMAIN: number = 0x0000;
const TAG: string = 'AutumnSelf';

/**
 * 下载链路自检（阶段五）。
 *
 * 覆盖三块纯逻辑（不需要网络就能跑，模拟器/真机都可以）：
 *   1. m3u8 清单解析（master/media、相对地址、密钥、VOD 判定）
 *   2. 去广告分组判定（源码那三条规则）
 *   3. 下载产物的命名与本地清单（`seg_00000.ts` 断点续传就靠这个命名）
 *
 * 期望值都是从参照实现逐行推出来的：
 * 例如 `#EXT-X-DISCONTINUITY` 每出现一次就把分组号 +1，
 * 而广告判定里「首组或末组且 < 30 秒」这一条最容易写错。
 */
export class DownloadSelfCheck {
  private static passCount: number = 0;
  private static failCount: number = 0;

  static run(): void {
    DownloadSelfCheck.passCount = 0;
    DownloadSelfCheck.failCount = 0;
    hilog.info(DOMAIN, TAG, '=== 下载链路自检开始 ===');

    // 1. 类型识别
    const masterText: string = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1280000,'
      + 'RESOLUTION=1280x720\n720/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=640000\n'
      + '480/index.m3u8\n';
    DownloadSelfCheck.check('master 清单被识别为 master',
      M3u8Parser.detectType(masterText) === 0,
      `${M3u8Parser.detectType(masterText)}`);
    const mediaText: string = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:5.0,\nseg0.ts\n';
    DownloadSelfCheck.check('media 清单被识别为 media',
      M3u8Parser.detectType(mediaText) === 1,
      `${M3u8Parser.detectType(mediaText)}`);

    // 2. master 解析：取码率最高的一路
    const master = M3u8Parser.parseMasterPlaylist(masterText,
      'https://cdn.example.com/hls/index.m3u8');
    DownloadSelfCheck.check('master 解析出 2 路码率',
      master.variants.length === 2, `${master.variants.length}`);
    const best = master.bestVariant();
    DownloadSelfCheck.check('最高码率那一路的地址正确（相对地址已补全）',
      best !== null && best.uri === 'https://cdn.example.com/hls/720/index.m3u8',
      best === null ? '无' : best.uri);
    DownloadSelfCheck.check('分辨率被解析出来',
      best !== null && best.resolution === '1280x720',
      best === null ? '无' : best.resolution);

    // 3. 相对地址三种形态
    DownloadSelfCheck.check('绝对地址原样返回',
      M3u8Parser.resolveUrl('https://a.com/x/y.m3u8', 'https://b.com/s.ts')
        === 'https://b.com/s.ts', '错误');
    DownloadSelfCheck.check('根相对地址补主机',
      M3u8Parser.resolveUrl('https://a.com/x/y.m3u8', '/s.ts') === 'https://a.com/s.ts',
      M3u8Parser.resolveUrl('https://a.com/x/y.m3u8', '/s.ts'));
    DownloadSelfCheck.check('路径相对地址补目录',
      M3u8Parser.resolveUrl('https://a.com/x/y.m3u8', 's.ts') === 'https://a.com/x/s.ts',
      M3u8Parser.resolveUrl('https://a.com/x/y.m3u8', 's.ts'));

    // 4. media 解析（含 DISCONTINUITY 与 KEY）
    const playlistText: string = '#EXTM3U\n'
      + '#EXT-X-TARGETDURATION:6\n'
      + '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x1234\n'
      + '#EXTINF:6.0,\nseg0.ts\n'
      + '#EXTINF:6.0,\nseg1.ts\n'
      + '#EXT-X-DISCONTINUITY\n'
      + '#EXTINF:4.0,\nseg2.ts\n'
      + '#EXT-X-ENDLIST\n';
    const playlist: M3u8MediaPlaylist =
      M3u8Parser.parseMediaPlaylist(playlistText, 'https://a.com/x/y.m3u8');
    DownloadSelfCheck.check('解析出 3 个切片',
      playlist.segments.length === 3, `${playlist.segments.length}`);
    DownloadSelfCheck.check('目标时长 6 秒',
      playlist.targetDuration === 6, `${playlist.targetDuration}`);
    DownloadSelfCheck.check('有 ENDLIST 判定为 VOD',
      playlist.isVod, `${playlist.isVod}`);
    DownloadSelfCheck.check('第二段后分组号 +1',
      playlist.segments[2].discontinuityGroup === 1,
      `${playlist.segments[2].discontinuityGroup}`);
    const key: M3u8Key | null = playlist.segments[0].key;
    DownloadSelfCheck.check('密钥方法为 AES-128',
      key !== null && key.method === 'AES-128', key === null ? '无' : key.method);
    DownloadSelfCheck.check('密钥地址相对路径已补全',
      key !== null && key.uri === 'https://a.com/x/key.bin',
      key === null ? '无' : key.uri);
    DownloadSelfCheck.check('IV 被解析出来',
      key !== null && key.iv === '0x1234', key === null ? '无' : key.iv);
    DownloadSelfCheck.check('去重后只有 1 个密钥',
      M3u8Parser.extractUniqueKeys(playlist).length === 1,
      `${M3u8Parser.extractUniqueKeys(playlist).length}`);

    // 5. 没有 ENDLIST 的第三方 VOD 也要判成 VOD（源码的兜底）
    const noEndList: string = '#EXTM3U\n#EXTINF:5.0,\na.ts\n#EXTINF:5.0,\nb.ts\n';
    const fallback: M3u8MediaPlaylist =
      M3u8Parser.parseMediaPlaylist(noEndList, 'https://a.com/y.m3u8');
    DownloadSelfCheck.check('没有 ENDLIST 也判定为 VOD（兜底）',
      fallback.isVod, `${fallback.isVod}`);

    // 6. 去广告：三组（前 5 秒广告 / 中间 600 秒正片 / 末尾 8 秒广告）
    const segments: M3u8Segment[] = [];
    segments.push(M3u8Segment.of(5, 'https://a.com/ad0.ts', 0, null));
    for (let i = 0; i < 100; i++) {
      segments.push(M3u8Segment.of(6, `https://a.com/main${i}.ts`, 1, null));
    }
    segments.push(M3u8Segment.of(8, 'https://a.com/ad1.ts', 2, null));
    const filtered: M3u8Segment[] = M3u8AdFilter.filterAds(segments);
    DownloadSelfCheck.check('去广告后只剩正片 100 个切片',
      filtered.length === 100, `${filtered.length}`);
    DownloadSelfCheck.check('保留下来的都是正片（分组 1）',
      filtered.length > 0 && filtered[0].discontinuityGroup === 1,
      filtered.length > 0 ? `${filtered[0].discontinuityGroup}` : '空');
    const singleGroup: M3u8Segment[] = [
      M3u8Segment.of(6, 'https://a.com/a.ts', 0, null),
      M3u8Segment.of(6, 'https://a.com/b.ts', 0, null)
    ];
    DownloadSelfCheck.check('只有一组时不判广告（原样返回）',
      M3u8AdFilter.filterAds(singleGroup).length === 2, '被过滤了');
    DownloadSelfCheck.check('过滤后目标时长 = 最长切片 6 秒',
      M3u8AdFilter.calculateTargetDuration(filtered) === 6,
      `${M3u8AdFilter.calculateTargetDuration(filtered)}`);

    // 7. 分片命名与本地清单（断点续传靠这个命名）
    DownloadSelfCheck.check('第 0 个分片名为 seg_00000.ts',
      M3u8Parser.segmentFileName(0) === 'seg_00000.ts',
      M3u8Parser.segmentFileName(0));
    DownloadSelfCheck.check('第 12 个分片名为 seg_00012.ts',
      M3u8Parser.segmentFileName(12) === 'seg_00012.ts',
      M3u8Parser.segmentFileName(12));
    const local: string = M3u8Parser.buildLocalM3u8(filtered,
      6, new Map<string, string>());
    DownloadSelfCheck.check('本地清单含 #EXTM3U 与 ENDLIST',
      local.indexOf('#EXTM3U') >= 0 && local.indexOf('#EXT-X-ENDLIST') >= 0, '缺失');
    DownloadSelfCheck.check('本地清单里切片指向 seg_00000.ts',
      local.indexOf('seg_00000.ts') >= 0, '缺失');
    DownloadSelfCheck.check('本地清单的 TARGETDURATION 为 6',
      local.indexOf('#EXT-X-TARGETDURATION:6') >= 0, '缺失');

    // 8. 状态文案（下载页角标）
    DownloadSelfCheck.check('状态文案：2 → 下载中',
      DownloadStatus.label(2) === '下载中', DownloadStatus.label(2));
    DownloadSelfCheck.check('状态文案：5 → 已暂停',
      DownloadStatus.label(5) === '已暂停', DownloadStatus.label(5));

    hilog.info(DOMAIN, TAG,
      '=== 下载链路自检结束：%{public}d 通过 / %{public}d 失败 ===',
      DownloadSelfCheck.passCount, DownloadSelfCheck.failCount);
    Logger.info(TAG,
      `下载链路自检结束：${DownloadSelfCheck.passCount} 通过 / ${DownloadSelfCheck.failCount} 失败`);
  }

  private static check(name: string, ok: boolean, detail: string): void {
    if (ok) {
      DownloadSelfCheck.passCount += 1;
      hilog.info(DOMAIN, TAG, '✅ %{public}s', name);
      Logger.info(TAG, `✅ ${name}`);
    } else {
      DownloadSelfCheck.failCount += 1;
      hilog.error(DOMAIN, TAG, '❌ %{public}s（%{public}s）', name, detail);
      Logger.error(TAG, `❌ ${name}（${detail}）`);
    }
  }
}
