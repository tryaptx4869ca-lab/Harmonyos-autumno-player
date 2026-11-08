import { M3u8Segment } from './M3u8Parser';

/**
 * HLS 去广告。逐条移植自参照实现 `lib/utils/m3u8_ad_filter.dart`。
 *
 * 设计来源是源码注释里写明的「模仿 FFmpeg 的 `hls_ad_filter`」：
 * 按 `#EXT-X-DISCONTINUITY` 把切片分组，**最长的那组当正片**，
 * 明显短于它的组判为广告。三条判定（命中任一即广告）：
 *
 *   1. 组时长 < 正片的 30%
 *   2. 组是首组或末组，且时长 < 30 秒
 *   3. 组时长 < 10 秒
 *
 * 只有一组时直接返回原切片（没广告可判）。
 */
export class M3u8AdFilter {
  static filterAds(segments: M3u8Segment[]): M3u8Segment[] {
    if (segments.length === 0) {
      return segments;
    }
    // 按 discontinuityGroup 分组（保持首次出现顺序）
    const groupIds: number[] = [];
    const groups: M3u8Segment[][] = [];
    for (let i = 0; i < segments.length; i++) {
      const id: number = segments[i].discontinuityGroup;
      let at: number = groupIds.indexOf(id);
      if (at < 0) {
        groupIds.push(id);
        groups.push([]);
        at = groupIds.length - 1;
      }
      groups[at].push(segments[i]);
    }
    if (groups.length <= 1) {
      return segments;
    }

    // 每组总时长
    const durations: number[] = [];
    let maxDuration: number = 0;
    for (let i = 0; i < groups.length; i++) {
      let sum: number = 0;
      for (let j = 0; j < groups[i].length; j++) {
        sum += groups[i][j].duration;
      }
      durations.push(sum);
      if (sum > maxDuration) {
        maxDuration = sum;
      }
    }

    // 组 id 排序后判定「首组 / 末组」
    const sortedIds: number[] = groupIds.slice();
    sortedIds.sort((a: number, b: number) => a - b);
    const firstId: number = sortedIds[0];
    const lastId: number = sortedIds[sortedIds.length - 1];

    const adGroups: number[] = [];
    for (let i = 0; i < groupIds.length; i++) {
      const id: number = groupIds[i];
      const duration: number = durations[i];
      // 正片那组跳过
      if (duration === maxDuration) {
        continue;
      }
      let isAd: boolean = false;
      if (duration < maxDuration * 0.3) {
        isAd = true;
      }
      if ((id === firstId || id === lastId) && duration < 30) {
        isAd = true;
      }
      if (duration < 10) {
        isAd = true;
      }
      if (isAd) {
        adGroups.push(id);
      }
    }
    if (adGroups.length === 0) {
      return segments;
    }

    const kept: M3u8Segment[] = [];
    for (let i = 0; i < segments.length; i++) {
      if (adGroups.indexOf(segments[i].discontinuityGroup) < 0) {
        kept.push(segments[i]);
      }
    }
    return kept;
  }

  /** 过滤后的目标时长 = 最长切片时长（源码 `calculateTargetDuration`）。 */
  static calculateTargetDuration(segments: M3u8Segment[]): number {
    let maxDuration: number = 0;
    for (let i = 0; i < segments.length; i++) {
      if (segments[i].duration > maxDuration) {
        maxDuration = segments[i].duration;
      }
    }
    return maxDuration;
  }
}
