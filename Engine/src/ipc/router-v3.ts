import { object } from '../../contracts.ts';
import { errorCode, type ErrorCode } from '../contracts/errors.ts';
import { IPC_VERSION, MAX_FRAME_BYTES, PUSH_TOPICS, pushFrameSchema, rpcRequestSchema, rpcSchemas,
  type PushPayload, type PushTopic, type RpcMethod, type RpcParams, type RpcResult } from '../contracts/ipc.ts';
import type { BridgeOrchestrator } from '../core/orchestrator.ts';

type Handler<M extends RpcMethod> = (params: RpcParams<M>) => RpcResult<M> | Promise<RpcResult<M>>;
export type ExtensionMethod = Extract<RpcMethod, `plugins.${string}` | `memory.${string}` | `persona.${string}` | 'system.bundles'>;
export type IpcV3Extensions = { [M in ExtensionMethod]?: Handler<M> };
type CoreHandlers = { [M in Exclude<RpcMethod, ExtensionMethod>]: Handler<M> };
type WireSink = (line: string) => void;
const frameFault = (code: ErrorCode) => ({ v: IPC_VERSION, kind: 'error', code });

export class IpcV3Router {
  private readonly handlers: CoreHandlers & IpcV3Extensions;
  private readonly unsubscribe: (() => void)[];
  private readonly pending = new Set<number>();
  private stopped = false;

  constructor(private readonly bridge: BridgeOrchestrator, private readonly sink: WireSink, extensions: IpcV3Extensions = {}) {
    this.handlers = {
      ...extensions,
      'system.status': () => bridge.status(),
      'system.healthCheck': p => bridge.healthCheck(p),
      'system.pauseAll': p => bridge.pauseAll(p.scope, p.reason),
      'xiaohe.accounts': p => bridge.accounts(p.mcpUrl),
      'xiaohe.conversations': p => bridge.listConversations(p),
      'xiaohe.groupMembers': p => bridge.groupMembers(p.conversationId),
      'xiaohe.capabilities': () => bridge.discoverCapabilities(),
      'settings.apply': p => bridge.applySettings(p.settings, p.cloudApiKeys),
      'model.preview': p => bridge.preview(p),
      'policy.evaluate': p => bridge.evaluatePolicy(p),
      'session.arm': p => bridge.arm(p),
      'session.pause': p => bridge.pause(p.conversationId, p.reason),
      'session.resumeCooldown': p => bridge.resumeCooldown(p.conversationId),
      'session.traces': p => bridge.sessionTraces(p),
      'session.sendOneShot': p => bridge.sendOneShot(p),
      'session.refreshReceipt': p => bridge.refreshReceipt(p.conversationId),
      'session.recover': p => bridge.recover(p),
      'session.backfill': p => bridge.backfill(p),
      'feed.list': p => bridge.listFeed(p),
      'feed.markRead': p => bridge.markFeedRead(p.ids),
    };
    this.unsubscribe = PUSH_TOPICS.map(topic => bridge.bus.subscribe(topic, payload => this.push(topic, payload)));
  }

  hello() { this.push('hello', { ...this.bridge.status(), v: IPC_VERSION }); }

  push<T extends PushTopic>(topic: T, payload: PushPayload<T>) {
    const frame = pushFrameSchema.safeParse({ v: IPC_VERSION, kind: 'event', topic, payload });
    if (!frame.success) { this.emit(frameFault('internal-error')); return; }
    if (!this.emit(frame.data)) this.emit(frameFault('invalid-frame'));
  }

  private emit(frame: unknown) {
    if (this.stopped) return true;
    const data = JSON.stringify(frame);
    if (Buffer.byteLength(data, 'utf8') > MAX_FRAME_BYTES) return false;
    this.sink(data + '\n');
    return true;
  }

  async route(line: string | Uint8Array): Promise<void> {
    if (this.stopped) return;
    const bytes = typeof line === 'string' ? Buffer.from(line, 'utf8') : line;
    const end = bytes.at(-1) === 10 ? bytes.length - 1 : bytes.length;
    const content = bytes.subarray(0, end);
    if (end > MAX_FRAME_BYTES || content.includes(10)) { this.emit(frameFault('invalid-frame')); return; }
    let raw: Record<string, unknown> | undefined;
    try { raw = object(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(content))); }
    catch { /* 统一发回协议错误 */ }
    if (!raw || !Number.isSafeInteger(raw.id)) { this.emit(frameFault('invalid-frame')); return; }
    const id = raw.id as number;
    const reply = { v: IPC_VERSION, kind: 'reply', id } as const;
    const fail = (code: ErrorCode) => { this.emit({ ...reply, ok: false, code }); };
    if (raw.v !== IPC_VERSION) { fail('engine-protocol'); return; }
    if (typeof raw.method !== 'string' || !Object.hasOwn(rpcSchemas, raw.method)) { fail('invalid-command'); return; }
    const request = rpcRequestSchema.safeParse(raw);
    if (!request.success) { fail('invalid-frame'); return; }
    if (this.pending.has(id) || (this.pending.size >= 32 && request.data.method !== 'system.pauseAll')) { fail('busy'); return; }
    const { method, params } = request.data;
    const handler = this.handlers[method] as Handler<typeof method> | undefined;
    if (!handler) { fail('engine-not-ready'); return; }
    this.pending.add(id);
    try {
      const result = rpcSchemas[method].result.safeParse(await handler(params));
      if (!result.success) { fail('internal-error'); return; }
      if (!this.emit({ ...reply, ok: true, result: result.data })) fail('invalid-frame');
    } catch (error) { fail(errorCode(error)); }
    finally { this.pending.delete(id); }
  }

  close() {
    this.stopped = true;
    for (const unsubscribe of this.unsubscribe) unsubscribe();
  }
}
