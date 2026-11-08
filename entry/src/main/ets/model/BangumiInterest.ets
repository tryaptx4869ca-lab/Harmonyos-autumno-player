import { JsonUtils } from './JsonUtils';

/** 用户头像三种尺寸。对应源码 `comment_item.dart` 的 `UserAvatar`。 */
export class UserAvatar {
  small: string = '';
  medium: string = '';
  large: string = '';

  static fromJson(json: Record<string, Object>): UserAvatar {
    const avatar = new UserAvatar();
    avatar.small = JsonUtils.str(json, 'small');
    avatar.medium = JsonUtils.str(json, 'medium');
    avatar.large = JsonUtils.str(json, 'large');
    return avatar;
  }
}

/** 用户。对应源码 `comment_item.dart` 的 `User`。 */
export class User {
  id: number = 0;
  username: string = '';
  nickname: string = '';
  avatar: UserAvatar = new UserAvatar();
  sign: string = '';
  joinedAt: number = 0;

  static fromJson(json: Record<string, Object>): User {
    const user = new User();
    user.id = JsonUtils.intOf(json, 'id');
    user.username = JsonUtils.str(json, 'username');
    user.nickname = JsonUtils.str(json, 'nickname');
    const avatar: Record<string, Object> | null = JsonUtils.obj(json, 'avatar');
    user.avatar = avatar === null ? new UserAvatar() : UserAvatar.fromJson(avatar);
    user.sign = JsonUtils.str(json, 'sign');
    user.joinedAt = JsonUtils.intOf(json, 'joinedAt');
    return user;
  }
}

/**
 * 收藏状态。
 * 逐字段移植自参照实现 `lib/modules/bangumi/bangumi_interest.dart`。
 */
export class BangumiInterest {
  id: number = 0;
  rate: number = 0;
  type: number = 0;
  comment: string = '';
  tags: string[] = [];
  epStatus: number = 0;
  volStatus: number = 0;
  updatedAt: number = 0;
  user: User | undefined = undefined;

  get hasUserProfile(): boolean {
    return this.user !== undefined;
  }

  /** 有评分或有短评才算「有评论内容」。 */
  get hasReviewContent(): boolean {
    return this.rate > 0 || this.comment.trim().length > 0;
  }

  static fromJson(json: Record<string, Object>): BangumiInterest {
    const interest = new BangumiInterest();
    interest.id = JsonUtils.intOf(json, 'id');
    interest.rate = JsonUtils.intOf(json, 'rate');
    interest.type = JsonUtils.intOf(json, 'type');
    interest.comment = JsonUtils.str(json, 'comment');
    // tags 既可能是字符串数组，也可能是 [{name: ...}]
    const rawTags: Object[] = JsonUtils.arr(json, 'tags');
    const tagList: string[] = [];
    for (let i = 0; i < rawTags.length; i++) {
      const element: Object = rawTags[i];
      if (typeof element === 'string') {
        tagList.push(element as string);
        continue;
      }
      const rec: Record<string, Object> | null = JsonUtils.asObj(element);
      if (rec !== null && rec['name'] !== undefined && rec['name'] !== null) {
        tagList.push(rec['name'].toString());
      }
    }
    interest.tags = tagList;
    interest.epStatus = JsonUtils.intOf(json, 'epStatus');
    interest.volStatus = JsonUtils.intOf(json, 'volStatus');
    interest.updatedAt = JsonUtils.intOf(json, 'updatedAt');
    return interest;
  }

  /** 本地提交（源码 `BangumiInterest.mergeLocalSubmission`）。 */
  static mergeLocalSubmission(previous: BangumiInterest | undefined, rate: number,
    comment: string, tags: string[]): BangumiInterest {
    const interest = new BangumiInterest();
    interest.id = previous === undefined ? 0 : previous.id;
    interest.rate = rate;
    interest.type = previous === undefined ? 0 : previous.type;
    interest.comment = comment;
    interest.tags = tags.slice();
    interest.epStatus = previous === undefined ? 0 : previous.epStatus;
    interest.volStatus = previous === undefined ? 0 : previous.volStatus;
    // 源码用 `DateTime.now().millisecondsSinceEpoch ~/ 1000`（秒）
    interest.updatedAt = Math.floor(Date.now() / 1000);
    interest.user = previous === undefined ? undefined : previous.user;
    return interest;
  }
}
