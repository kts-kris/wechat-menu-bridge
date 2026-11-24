import { setTimeout as delay } from 'node:timers/promises';
import { BridgeError, id, object, sha } from '../../contracts.ts';
import { classifyText } from '../../policy.ts';
import { errorCode, type ErrorCode } from '../contracts/errors.ts';
import { normalizedEventSchema, xiaoheEventSchema, type EventOrigin, type MessageKind, type ScopeType, type XiaoheCapabilities } from '../contracts/events.ts';
import type { JournalV2 } from '../storage/journal-v2.ts';
import { identityKey, peerKey, routeKey, type EventScope, type RemoteIdentity, type XiaoheClient } from './client.ts';

export type IngestTarget = { conversationId: string; type: ScopeType; priority: 'reply' | 'background' };
export type EventInput = { event: ReturnType<typeof normalizedEventSchema.parse>; mediaRef?: string; route: string; identity: string;
  scopeKind: 'account' | 'conversation'; unavailableBody?: boolean };
export type SendFence = { route: string; cursor: string | null; scope: EventScope };
export const eventHash = (eventId: string, conversationId?: string) =>
  sha(conversationId ? JSON.stringify(['event', conversationId, eventId]) : `event:${eventId}`);
export const refHash = (messageRef: string, conversationId?: string) =>
  sha(conversationId ? JSON.stringify(['ref', conversationId, messageRef]) : `ref:${messageRef}`);
export const eventRefHash = (input: EventInput, ref = input.event.messageRef) =>
  refHash(ref, input.scopeKind === 'account' ? input.event.conversationId : undefined);
export const conversationType = (id: string): ScopeType => id.endsWith('@chatroom') ? 'group' : id.startsWith('gh_') ? 'service' : 'direct';
const contract = () => new BridgeError('mcp-contract');

function messageKind(type: string, eventType: string): MessageKind {
  if (/recall|revoke|撤回/i.test(eventType) || /recall|revoke/i.test(type)) return 'recall';
  if (/image|video|^3$|^43$/i.test(type)) return 'image';
  if (/voice|audio|^34$/i.test(type)) return 'voice';
  if (/^text$|^1$/i.test(type)) return 'text';
  if (/link|app/i.test(type)) return 'link';
  return /file/i.test(type) ? 'file' : 'system';
}

function mentionsByName(text: string, selfNames: readonly string[]) {
  if (!text || !selfNames.length) return false;
  for (const raw of selfNames) {
    const name = raw.trim();
    if (!name) continue;
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    if (new RegExp(`(?:^|[\\s\\u2005])@${escaped}(?:[\\u2005\\s,，:：!！?？。]|$)`, 'u').test(text)) return true;
  }
  return false;
}

export function normalizeEvent(raw: unknown, scope: EventScope, type: ScopeType, origin: EventOrigin, route: string,
  identity: string, seenAt = Date.now(), selfNames: readonly string[] = []): EventInput | undefined {
  const row = object(raw);
  if (!row) throw contract();
  if (Object.entries(scope).some(([key, value]) => row[key] !== undefined && row[key] !== value)) throw new BridgeError('wechat-changed');
  const history = origin === 'backfill';
  const parsed = xiaoheEventSchema.safeParse(history ? {
    ...row, conversation_id: row.conversation_id ?? scope.conversation_id, event_type: row.event_type ?? 'message.saved',
    event_id: row.event_id ?? (id(row.message_ref) ? `history:${sha(row.message_ref)}` : undefined),
    observed_at: row.observed_at ?? row.created_at ?? new Date(seenAt).toISOString(),
  } : row);
  if (!parsed.success) throw contract();
  const r = parsed.data;
  const kind = r.status === 'recalled' ? 'recall' : messageKind(r.type, r.event_type);
  if (kind !== 'recall' && (r.recalled === true || r.is_recalled === true)) return;
  if (kind !== 'recall' && !history && r.event_type !== 'message.saved') return;
  const createdAt = r.created_at ? Date.parse(r.created_at) : r.created_at_seconds != null ?
    r.created_at_seconds * 1000 : Date.parse(r.observed_at);
  const observedAt = Date.parse(r.observed_at);
  if (!Number.isSafeInteger(createdAt) || !Number.isSafeInteger(observedAt) || createdAt < 0 || observedAt < 0) throw contract();
  if (!history && (Math.max(createdAt, observedAt) > seenAt + 5000)) throw new BridgeError('clock-changed');
  if (!r.is_self && kind !== 'recall' && type === 'direct' && r.sender_id !== r.conversation_id) return;
  const mentionInfo = object(r.mentions);
  const mentionIDs = r.mention_user_ids ?? r.mentioned_user_ids ?? mentionInfo?.ids ?? (Array.isArray(r.mentions) ? r.mentions : undefined);
  const ids = Array.isArray(mentionIDs) ? mentionIDs.map(item => object(item)?.user_id ?? item).filter(id) : [];
  const mediaRef = r.attachments?.map(item => item.media_ref).find(id);
  const targetRef = r.recall_target_ref ?? r.target_message_ref ?? r.recalled_message_ref;
  const transcript = typeof r.transcript === 'string' ? r.transcript.trim() : '';
  const text = r.text?.trim() ?? '';
  return { route, identity, mediaRef, scopeKind: scope.conversation_id ? 'conversation' : 'account', event: normalizedEventSchema.parse({
    eventId: r.event_id, messageRef: r.message_ref, origin, accountId: scope.account_id, conversationId: r.conversation_id,
    scopeType: type, senderId: r.sender_id ?? '', senderLabel: (r.sender_name?.trim() || r.sender_id) ?? '',
    isSelf: r.is_self, clientRequestId: r.client_request_id ?? undefined, kind,
    text: kind === 'voice' && transcript ? transcript : text, rawText: text,
    mentions: { ids, mentionsSelf: r.mentions_self === true || r.mentioned_self === true ||
      mentionInfo?.mentionsSelf === true || mentionInfo?.mentions_self === true || ids.includes(scope.account_id) ||
      mentionsByName(text, selfNames) },
    recallTargetRef: kind === 'recall' ? id(targetRef) ? targetRef : r.message_ref : undefined,
    createdAt, observedAt, seenAt,
  }) };
}

type Loop = { controller: AbortController; task: Promise<void>; signature: string };
type State = { scope: EventScope; cursor: string | null; identity: string; synced: boolean };
type Options = {
  url: string; accountId: string; journal: JournalV2;
  createClient: () => XiaoheClient | Promise<XiaoheClient>;
  onEvent: (input: EventInput) => void;
  onState?: (ids: string[], state: 'listening' | 'retrying' | 'fault', reason?: ErrorCode) => void;
  selfNames?: () => readonly string[];
  shortPollMs?: number;
};

export class AccountIngestScheduler {
  private targets = new Map<string, IngestTarget>();
  private safetyPeers = new Map<string, ScopeType>();
  private readonly loops = new Map<string, Loop>();
  private readonly tasks = new Set<Promise<void>>();
  private readonly states = new Map<string, State>();
  private identity?: RemoteIdentity;
  private capabilities?: XiaoheCapabilities;

  constructor(private readonly options: Options) {}

  get currentIdentity() { return this.identity ? identityKey(this.identity) : undefined; }

  bindIdentity(remote: RemoteIdentity) {
    if (remote.binding.account_id !== this.options.accountId ||
        (this.identity && identityKey(this.identity) !== identityKey(remote))) throw new BridgeError('wechat-changed');
    this.identity = remote;
  }

  configure(capabilities: XiaoheCapabilities, targets: Iterable<IngestTarget>, safetyPeers?: Iterable<{ conversationId: string; type: ScopeType }>) {
    this.capabilities = capabilities;
    this.targets = new Map([...targets].map(target => [target.conversationId, target]));
    this.safetyPeers = new Map([
      ...(safetyPeers ? [...safetyPeers].map(peer => [peer.conversationId, peer.type] as const) : []),
      ...[...this.targets.values()].map(target => [target.conversationId, target.type] as const),
    ]);
    this.reconcile();
  }

  private reconcile() {
    const desired = new Map<string, { conversations: string[]; wait: boolean }>();
    if (this.targets.size && this.capabilities?.accountWideEvents) desired.set('account', { conversations: [], wait: true });
    else {
      const active = [...this.targets.values()].filter(v => v.priority === 'reply').slice(0, 8);
      for (const target of active) desired.set(`long:${target.conversationId}`, { conversations: [target.conversationId], wait: true });
      const low = [...this.targets.keys()].filter(id => !desired.has(`long:${id}`));
      // 每个短轮询保持自己的会话游标，共用连接并轮转读取。
      if (low.length) desired.set('shared', { conversations: low, wait: false });
    }
    for (const [key, loop] of this.loops) {
      if (JSON.stringify(desired.get(key)?.conversations) === loop.signature) continue;
      loop.controller.abort();
      this.loops.delete(key);
    }
    for (const [key, { conversations, wait }] of desired) {
      if (this.loops.has(key)) continue;
      const controller = new AbortController();
      const task = this.watch(conversations, wait, controller.signal).finally(() => this.tasks.delete(task));
      this.tasks.add(task);
      this.loops.set(key, { controller, task, signature: JSON.stringify(conversations) });
    }
  }

  routeFor(conversationId: string) {
    return routeKey(this.options.url, this.options.accountId, this.capabilities?.accountWideEvents ? undefined : conversationId);
  }

  fence(conversationId: string): SendFence & { identity: string } {
    const route = this.routeFor(conversationId);
    const current = this.states.get(route);
    if (!current?.synced || this.options.journal.read(route)?.fault || !this.targets.has(conversationId)) throw new BridgeError('send-fence');
    return { route, cursor: current.cursor, scope: current.scope, identity: current.identity };
  }

  async stop() {
    this.targets.clear();
    this.reconcile();
    await Promise.all(this.tasks);
  }

  async restart(conversationId: string, reset = false) {
    const route = this.routeFor(conversationId);
    const affected = [...this.loops.entries()].filter(([key, loop]) => key === 'account' ||
      (JSON.parse(loop.signature) as string[]).includes(conversationId));
    for (const [, loop] of affected) loop.controller.abort();
    await Promise.all(affected.map(([, loop]) => loop.task));
    for (const [key, loop] of affected) if (this.loops.get(key) === loop) this.loops.delete(key);
    if (reset) this.options.journal.resetRead(route);
    const stored = this.options.journal.read(route);
    if (!stored || (this.identity && stored.identity !== identityKey(this.identity))) this.identity = undefined;
    this.reconcile();
  }

  private async watch(conversations: string[], wait: boolean, signal: AbortSignal) {
    const { accountId, url, journal, createClient, onState } = this.options;
    const scopeIds = conversations.length ? conversations : [undefined];
    const routes = scopeIds.map(id => routeKey(url, accountId, id));
    const faults = new Set<string>();
    const ids = (conversation?: string) => conversation ? [conversation] : [...this.targets.keys()];
    let retry = 0;
    while (!signal.aborted) {
      let client: XiaoheClient | undefined;
      const owned = new Map<string, State>();
      try {
        client = await createClient();
        const remote = await client.identify(accountId, signal);
        signal.throwIfAborted();
        const identity = identityKey(remote);
        this.bindIdentity(remote);
        for (const [i, conversation] of scopeIds.entries()) {
          const route = routes[i]!;
          const stored = journal.read(route);
          const why = stored && (stored.identity !== identity ? 'wechat-changed' : stored.fault);
          if (why) {
            faults.add(route);
            onState?.(ids(conversation), 'fault', errorCode(new BridgeError(why)));
            continue;
          }
          const scope = { ...remote.binding, ...(conversation ? { conversation_id: conversation } : {}) };
          const state = { scope, cursor: stored?.cursor ?? null, identity, synced: false };
          owned.set(route, state);
          this.states.set(route, state);
        }
        while (!signal.aborted && owned.size) {
          const began = Date.now();
          let empty = true;
          for (const [route, state] of owned) {
            try {
              if (await this.poll(client, route, state, wait, signal)) empty = false;
              retry = 0;
            } catch (error) {
              if (signal.aborted) return;
              const why = errorCode(error);
              if (why === 'mcp-offline' || why === 'wechat-changed' || why === 'clock-changed') throw error;
              journal.holdRead(route, identity, why, this.cursorScope(state.scope));
              owned.delete(route);
              if (this.states.get(route) === state) this.states.delete(route);
              faults.add(route);
              onState?.(ids(state.scope.conversation_id), 'fault', why);
            }
          }
          if (!wait || (empty && Date.now() - began < 150)) {
            await delay(wait ? 350 : this.options.shortPollMs ?? 3500, undefined, { signal });
          }
        }
        return;
      } catch (error) {
        if (signal.aborted) return;
        const why = errorCode(error);
        if (why !== 'mcp-offline') {
          if (this.identity) for (const [i, route] of routes.entries()) if (!faults.has(route)) {
            journal.holdRead(route, identityKey(this.identity), why, { scope_kind: conversations.length ? 'conversation' : 'account',
              conversation_id: scopeIds[i] });
          }
          for (const conversation of scopeIds) onState?.(ids(conversation), 'fault', why);
          return;
        }
        for (const [route, state] of owned) if (this.states.get(route) === state) this.states.delete(route);
        for (const conversation of scopeIds) onState?.(ids(conversation), 'retrying', why);
      } finally {
        for (const [route, state] of owned) if (this.states.get(route) === state) this.states.delete(route);
        await client?.close();
      }
      await delay(Math.min(10_000, 350 * 2 ** Math.min(retry++, 5)), undefined, { signal }).catch(() => {});
    }
  }

  private cursorScope(scope: EventScope) {
    return { scope_kind: scope.conversation_id ? 'conversation' as const : 'account' as const, conversation_id: scope.conversation_id };
  }

  private async poll(client: XiaoheClient, route: string, state: State, wait: boolean, signal: AbortSignal) {
    const { journal, onEvent, onState } = this.options;
    const wasSynced = state.synced;
    const started = Date.now();
    const cursors = new Set<string>();
    let count = 0;
    let anchorReads = 0;
    for (let i = 0; i < 160; i++) {
      const page = await client.events(state.scope, state.cursor, wait && wasSynced && i === 0 && state.cursor !== null, signal);
      signal.throwIfAborted();
      state.synced = false;
      count += page.events.length;
      if (Date.now() - started > (wait && wasSynced ? 32_000 : 11_000)) throw new BridgeError('backlog-limit');
      if (page.more && page.cursor && cursors.has(page.cursor)) throw contract();
      if (page.cursor) cursors.add(page.cursor);
      const hashes = new Set<string>();
      const fresh: EventInput[] = [];
      const pausedStops = new Set<string>();
      for (const raw of page.events) {
        const conversation = object(raw)?.conversation_id;
        if (!id(conversation)) throw contract();
        if (state.scope.conversation_id && conversation !== state.scope.conversation_id) throw contract();
        const target = this.targets.get(conversation);
        const safetyType = target?.type ?? this.safetyPeers.get(conversation);
        if (!safetyType) continue;
        const input = normalizeEvent(raw, state.scope, safetyType, 'live', route, state.identity, Date.now(), this.options.selfNames?.());
        if (!input) continue;
        const { event } = input;
        if (!target) {
          // 账号级共享游标越过暂停会话时，仍必须捕获叫停与撤回等安全信号，不分发正文也不落普通事件去重表。
          if (event.kind === 'recall' && event.recallTargetRef) {
            journal.markRecalled(route, eventRefHash(input, event.recallTargetRef));
          } else if (safetyType !== 'service' && !event.isSelf && event.text && classifyText(event.text) === 'stop') {
            pausedStops.add(peerKey(state.scope.account_id, conversation));
          }
          continue;
        }
        const eventKey = eventHash(event.eventId, input.scopeKind === 'account' ? conversation : undefined);
        const keys = event.kind === 'recall' ? [eventKey] : [eventKey, eventRefHash(input)];
        if (keys.some(key => hashes.has(key) || journal.known(route, key))) continue;
        for (const key of keys) hashes.add(key);
        fresh.push(input);
      }
      for (const input of fresh) if (input.event.kind === 'recall' && input.event.recallTargetRef) {
        journal.markRecalled(route, eventRefHash(input, input.event.recallTargetRef));
      }
      const readyToDeliver: EventInput[] = [];
      for (const raw of fresh) {
        const { event } = raw;
        if (event.kind !== 'recall' && journal.isRecalled(route, eventRefHash(raw))) continue;
        let input = raw;
        if (!event.isSelf && event.kind === 'text' && !event.text && Date.now() - event.observedAt < 45_000) {
          input = { ...raw, unavailableBody: true };
          if (++anchorReads <= 4) {
            try {
              const anchor = await client.messageContext({ ...state.scope, conversation_id: event.conversationId }, event.messageRef, signal);
              if (anchor.is_self !== false || anchor.sender_id !== event.senderId || anchor.type !== 'text') throw new BridgeError('wrong-anchor');
              if (typeof anchor.text === 'string' && anchor.text.trim()) {
                const text = anchor.text.trim();
                input = { ...raw, event: { ...event, text, rawText: text } };
              }
            } catch (error) {
              if (errorCode(error) !== 'no-anchor') throw error;
            }
          }
        }
        signal.throwIfAborted();
        readyToDeliver.push(input);
      }
      for (const peer of pausedStops) journal.optOut(peer);
      const shouldAdvance = page.events.length > 0 || page.more || state.cursor === null || !journal.read(route);
      if (shouldAdvance) {
        journal.advance(route, state.identity, page.cursor, hashes, Date.now(), undefined, this.cursorScope(state.scope));
        state.cursor = page.cursor;
      }
      for (const input of readyToDeliver) {
        if (this.targets.has(input.event.conversationId)) onEvent(input);
      }
      if (!page.more) {
        state.synced = true;
        if (!wasSynced) onState?.(state.scope.conversation_id ? [state.scope.conversation_id] : [...this.targets.keys()], 'listening');
        return count > 0;
      }
    }
    throw new BridgeError('backlog-limit');
  }
}
