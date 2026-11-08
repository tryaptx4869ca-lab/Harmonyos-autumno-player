/**
 * 可替换异步操作的会话所有�权。
 * 移植自参照实现 `lib/utils/async_session.dart`。
 *
 * 语义：开启新会话会让上一个会话失效（`isStale`），
 * 因此"后发起的搜索"不会被"先发起但更慢的那个"覆盖写回。
 */
export class AsyncSessionOwner {
  private version: number = 0;
  private closed: boolean = false;

  get isClosed(): boolean {
    return this.closed;
  }

  begin(): AsyncSession {
    if (this.closed) {
      throw new Error('Cannot begin a session after the owner is closed.');
    }
    this.version = this.version + 1;
    return new AsyncSession(this, this.version);
  }

  cancel(): void {
    if (!this.closed) {
      this.version = this.version + 1;
    }
  }

  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.version = this.version + 1;
  }

  /** 会话是否仍属于当前版本。 */
  owns(session: AsyncSession): boolean {
    return !this.closed && session.owner === this && session.version === this.version;
  }
}

export class AsyncSession {
  readonly owner: AsyncSessionOwner;
  readonly version: number;

  constructor(owner: AsyncSessionOwner, version: number) {
    this.owner = owner;
    this.version = version;
  }

  get isActive(): boolean {
    return this.owner.owns(this);
  }

  get isStale(): boolean {
    return !this.isActive;
  }
}
