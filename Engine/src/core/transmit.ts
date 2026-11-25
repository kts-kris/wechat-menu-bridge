import { BridgeError, id, object, sha } from '../../contracts.ts';
import { errorCode } from '../contracts/errors.ts';
import { identityKey, peerKey, routeKey, type Receipt, type XiaoheClient } from '../mcp/client.ts';
import type { SendFence } from '../mcp/ingest.ts';
import type { AttemptKind, JournalV2 } from '../storage/journal-v2.ts';

export type TransmitRequest = {
  sourceKind: AttemptKind;
  conversationId: string;
  text: string;
  attemptId: string;
  expectedIdentity: string;
  fenceCursor?: SendFence;
  checkStillValid: () => void;
  onWire?: () => void;
  originGuard: 'live_or_human';
  origin?: 'live' | 'human' | 'backfill';
  pluginId?: string;
  pluginDailyLimit?: number;
  messageRef?: string;
  mentionUserIds?: string[];
  onTiming?: (timing: { fenceMs: number; wireMs: number }) => void;
};
type Options = {
  accountId: string; mcpUrl: string; journal: JournalV2; createWriter: () => XiaoheClient | Promise<XiaoheClient>;
  onUnknown?: (conversationId: string, attemptId: string) => void;
  onIdentityChanged?: () => void;
  beforeWrite?: (kind: AttemptKind) => void;
  onInFlight?: () => void;
  now?: () => number;
};
const unknown = { status: 'unknown', delivery: 'unknown' } as const;
const rejected = { status: 'rejected', delivery: 'failed' } as const;
const definite = new Set(['wechat-permission', 'wechat-changed', 'send-rejected']);
const dropWriterOn = new Set(['mcp-offline', 'wechat-changed', 'mcp-contract', 'send-unknown', 'stopped']);

export class TransmitService {
  private readonly peers = new Map<string, Promise<unknown>>();
  private readonly writing = new Map<string, Promise<void>>();
  private pooledWriter?: XiaoheClient;
  private acquiringWriter?: Promise<XiaoheClient>;
  private drained = false;
  constructor(private readonly options: Options) {}
  get inFlight() { return this.writing.size; }

  settled(conversationId: string) {
    return this.writing.get(peerKey(this.options.accountId, conversationId));
  }

  private async acquireWriter(): Promise<XiaoheClient> {
    if (this.pooledWriter) return this.pooledWriter;
    if (this.acquiringWriter) return this.acquiringWriter;
    const task = Promise.resolve(this.options.createWriter()).then(client => {
      if (this.drained) {
        void client.close().catch(() => {});
        throw new BridgeError('stopped');
      }
      this.pooledWriter = client;
      return client;
    }).finally(() => {
      if (this.acquiringWriter === task) this.acquiringWriter = undefined;
    });
    this.acquiringWriter = task;
    return task;
  }

  private dropWriter(target: XiaoheClient) {
    if (this.pooledWriter !== target) return;
    this.pooledWriter = undefined;
    void target.close().catch(() => {});
  }

  async drain() {
    this.drained = true;
    await Promise.allSettled(this.peers.values());
    const pending = this.acquiringWriter;
    this.acquiringWriter = undefined;
    const client = this.pooledWriter ?? (pending ? await pending.catch(() => undefined) : undefined);
    this.pooledWriter = undefined;
    if (client) await client.close().catch(() => {});
  }

  async send(req: TransmitRequest): Promise<Receipt> {
    const { conversationId, text, attemptId } = req;
    if (req.origin === 'backfill' || req.originGuard !== 'live_or_human') throw new BridgeError('send-not-authorized');
    if (!id(conversationId) || !id(attemptId) || !text.trim() || text.length > 500 || /[\p{Cc}\p{Cf}]/u.test(text) ||
      !['auto', 'active', 'plugin'].includes(req.sourceKind) ||
      (req.sourceKind === 'plugin' && !id(req.pluginId)) || (req.messageRef !== undefined && !id(req.messageRef)) ||
      (req.mentionUserIds && (!conversationId.endsWith('@chatroom') || req.mentionUserIds.length > 50 || !req.mentionUserIds.every(id)))) {
      throw new BridgeError('invalid-configuration');
    }
    const peer = peerKey(this.options.accountId, conversationId);
    const previous = this.peers.get(peer);
    const request = { ...req, mentionUserIds: req.mentionUserIds?.slice(), fenceCursor: req.fenceCursor && {
      ...req.fenceCursor, scope: { ...req.fenceCursor.scope },
    } };
    const next = (previous ? previous.catch(() => {}) : Promise.resolve()).then(() => this.transmit(peer, request));
    this.peers.set(peer, next);
    try { return await next; }
    finally { if (this.peers.get(peer) === next) this.peers.delete(peer); }
  }

  private async transmit(peer: string, req: TransmitRequest) {
    const { journal, accountId, mcpUrl, createWriter } = this.options;
    const now = this.options.now ?? Date.now;
    const { attemptId, conversationId, sourceKind, expectedIdentity, checkStillValid, fenceCursor } = req;
    const check = () => {
      this.options.beforeWrite?.(sourceKind);
      checkStillValid();
      if (journal.optedOut(peer)) throw new BridgeError('peer-stopped');
      if (journal.uncertain(peer)) throw new BridgeError('send-unknown');
      if (journal.get(attemptId)) throw new BridgeError('duplicate-attempt');
      if (sourceKind !== 'plugin') {
        const saved = fenceCursor && journal.read(fenceCursor.route);
        if (!saved || saved.fault || saved.identity !== expectedIdentity ||
          (fenceCursor.scope.conversation_id !== undefined && saved.cursor !== fenceCursor.cursor)) throw new BridgeError('send-fence');
      }
    };
    check();
    if (sourceKind !== 'plugin' && (!fenceCursor || fenceCursor.scope.account_id !== accountId ||
        (fenceCursor.scope.conversation_id !== undefined && fenceCursor.scope.conversation_id !== conversationId) ||
        fenceCursor.route !== routeKey(mcpUrl, accountId, fenceCursor.scope.conversation_id))) throw new BridgeError('send-fence');
    const fenceStarted = performance.now();
    let wireStarted: number | undefined;
    const writer = await this.acquireWriter();
    let reserved = false, onWire = false;
    let release!: () => void;
    try {
      check();
      const shouldCheckFence = sourceKind !== 'plugin' && !!fenceCursor;
      const [remoteResult, pageResult] = shouldCheckFence
        ? await Promise.allSettled([
            writer.identify(accountId, undefined, true, conversationId),
            writer.events(fenceCursor!.scope, fenceCursor!.cursor),
          ])
        : [await Promise.allSettled([writer.identify(accountId, undefined, true, conversationId)]).then(r => r[0]!), undefined];
      if (remoteResult.status === 'rejected') throw remoteResult.reason;
      const remote = remoteResult.value;
      if (identityKey(remote) !== expectedIdentity) throw new BridgeError('wechat-changed');
      const scope = { ...remote.binding, conversation_id: conversationId };
      if (shouldCheckFence && fenceCursor) {
        if (fenceCursor.scope.instance_id !== remote.binding.instance_id ||
            fenceCursor.scope.login_generation !== remote.binding.login_generation) throw new BridgeError('send-fence');
        if (!pageResult || pageResult.status === 'rejected') throw pageResult?.reason ?? new BridgeError('send-fence');
        const page = pageResult.value;
        const targetTouched = fenceCursor.scope.conversation_id !== undefined
          ? page.events.length > 0
          : page.events.some(raw => {
              const cid = object(raw)?.conversation_id;
              return !id(cid) || cid === conversationId;
            });
        // 小禾的 opaque1.* 游标每次空读都会重新随机加密，不能把“无新事件但游标密文变化”误判为 send-fence；
        // 账号级事件流中其他会话的消息也不应阻断当前会话发信。
        if (page.more || targetTouched) throw new BridgeError('send-fence');
      }
      check();
      const gate = () => {
        check();
        journal.reserve(attemptId, peer, fenceCursor?.route ?? routeKey(mcpUrl, accountId, conversationId), expectedIdentity,
          sourceKind, now(), sourceKind === 'plugin' ? { pluginId: req.pluginId!, dailyLimit: req.pluginDailyLimit } : undefined);
        reserved = true;
        checkStillValid();
        this.writing.set(peer, new Promise<void>(resolve => { release = resolve; }));
        onWire = true;
        wireStarted = performance.now();
        queueMicrotask(() => {
          try { req.onWire?.(); } catch { /* 状态观察者不参与发信结果判定 */ }
          this.options.onInFlight?.();
        });
      };
      const receipt = req.messageRef ? await writer.reply(scope, req.messageRef, req.text, attemptId, gate, req.mentionUserIds) :
        await writer.sendText(scope, req.text, attemptId, gate, req.mentionUserIds);
      const finished = performance.now();
      const fenceMs = Math.max(0, Math.round((wireStarted ?? finished) - fenceStarted));
      const wireMs = wireStarted !== undefined ? Math.max(0, Math.round(finished - wireStarted)) : 0;
      try { req.onTiming?.({ fenceMs, wireMs }); } catch { /* 性能埋点不参与发信结果判定 */ }
      if (!reserved) throw new BridgeError('send-not-authorized');
      journal.complete(attemptId, receipt);
      if (receipt.status === 'unknown') throw new BridgeError('send-unknown');
      if (receipt.status === 'rejected' || receipt.delivery === 'failed') throw new BridgeError('send-rejected');
      return receipt;
    } catch (error) {
      const code = errorCode(error);
      if (dropWriterOn.has(code)) this.dropWriter(writer);
      if (code === 'wechat-changed') this.options.onIdentityChanged?.();
      if (!reserved) throw error;
      if (!onWire || definite.has(code)) {
        if (journal.get(attemptId)?.status === 'trying') journal.complete(attemptId, rejected);
        throw error;
      }
      try {
        if (journal.get(attemptId)?.status === 'trying') journal.complete(attemptId, unknown);
      } catch {
        // 无法更新时保留已落盘的 trying。它也会阻止后续发送。
      } finally {
        try { this.options.onUnknown?.(conversationId, attemptId); } catch { /* 发信结果已独立归档 */ }
      }
      this.dropWriter(writer);
      throw new BridgeError('send-unknown');
    } finally {
      if (release) {
        this.writing.delete(peer);
        release();
        this.options.onInFlight?.();
      }
    }
  }

  autoAttempt(peer: string, refs: readonly string[]) {
    return `wmb-${sha(`${peer}:${refs.map(ref => sha(`ref:${ref}`)).sort().join(':')}`)}`;
  }
}
