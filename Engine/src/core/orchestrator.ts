import { randomUUID } from 'node:crypto';
import { BridgeError, checked, endpoint } from '../../contracts.ts';
import { ReplyModel } from '../../model.ts';
import { errorCode, isErrorCode, type ErrorCode } from '../contracts/errors.ts';
import type { BackfillRequest, NormalizedEvent, XiaoheCapabilities } from '../contracts/events.ts';
import { type FeedItem, type HealthCheckStep, type PluginRuntimeState, type PushPayload, type PushTopic, type RpcParams, type RpcResult, type SessionRuntimeState, type SessionTraceEntry } from '../contracts/ipc.ts';
import { loadSettingsV2FromDisk, settingsV2Schema, type ConversationPolicy, type SettingsV2 } from '../contracts/settings.ts';
import { CHAT_TIMEOUT_MS, modelEndpoint } from '../llm/client.ts';
import { ModelRouter, supportsModelKind, type KeyProvider } from '../llm/router.ts';
import { HistoryBackfiller } from '../mcp/backfill.ts';
import { CapabilityRegistry } from '../mcp/capabilities.ts';
import { identityKey, peerKey, routeKey, XiaoheClient, type Account, type Receipt, type RemoteIdentity } from '../mcp/client.ts';
import { AccountIngestScheduler, conversationType, eventRefHash, refHash, type EventInput } from '../mcp/ingest.ts';
import { MediaEnricher } from '../mcp/media.ts';
import { DiagnosticLog } from '../storage/diag-log.ts';
import { JournalV2, type FeedItem as StoredFeedItem } from '../storage/journal-v2.ts';
import { ConversationActor } from './actor.ts';
import { EventBus } from './event-bus.ts';
import { PolicyEngine } from './policy.ts';
import { TransmitService } from './transmit.ts';

export type BridgeEvents = { [K in PushTopic]: PushPayload<K> } & {
  message: NormalizedEvent;
  recall: NormalizedEvent;
  history: { jobId: string; purpose: BackfillRequest['purpose']; event: NormalizedEvent };
};
type StatusContributor = () => { plugins: Record<string, PluginRuntimeState>; activePluginCount: number; pendingProposalCount: number };
type PromptProfileResolver = (policy: ConversationPolicy, mode: 'local' | 'cloud') => Promise<{ style?: string; memory?: string }>;
type PromptCacheFingerprint = (policy: ConversationPolicy, mode: 'local' | 'cloud') => string;
type Options = {
  settings?: SettingsV2;
  getMcpToken?: (url: string) => string | undefined | Promise<string | undefined>;
  getModelKey?: KeyProvider;
  createClient?: (url: string, token?: string) => XiaoheClient;
  assemblePrompt?: PromptProfileResolver;
  promptCacheFingerprint?: PromptCacheFingerprint;
  statusContributor?: StatusContributor;
  onSettingsApplied?: (settings: SettingsV2, cloudApiKeys?: Record<string, string>) => void;
  onPauseAll?: (scope: 'sending_only' | 'all') => void;
  actorTiming?: { debounceMs?: number; batchMaxMs?: number };
  quietHoursNow?: () => number;
  shortPollMs?: number;
};
type Job = { conversationId: string; controller: AbortController; task: Promise<void> };
type Connection = { client: XiaoheClient; ingest: AccountIngestScheduler; transmit: TransmitService };
const statusReceipt = (receipt: Receipt) => ({ status: receipt.status, delivery: receipt.delivery,
  ...(receipt.operation && { operationId: receipt.operation }) });
const feedItem = (row: StoredFeedItem): FeedItem => ({ id: row.id, kind: row.kind, title: row.title, body: row.body,
  createdAt: row.created_at, read: row.read === 1, ...(row.conversation_id && { conversationId: row.conversation_id }),
  ...(row.plugin_id && { pluginId: row.plugin_id }), ...(row.ref_path && { refPath: row.ref_path }) });
const fingerprint = (data: unknown) => JSON.stringify(data);
function eventSnapshot(event: NormalizedEvent) {
  const value = structuredClone(event);
  Object.freeze(value.mentions.ids);
  Object.freeze(value.mentions);
  Object.freeze(value.media);
  Object.freeze(value.quote);
  Object.freeze(value.link);
  return Object.freeze(value);
}

export class BridgeOrchestrator {
  readonly bus = new EventBus<BridgeEvents>();
  readonly journal: JournalV2;
  readonly models: ModelRouter;
  private readonly media: MediaEnricher;
  private readonly diagLog: DiagnosticLog;
  private readonly traces = new Map<string, SessionTraceEntry[]>();
  private settings: SettingsV2;
  private readonly actors = new Map<string, ConversationActor>();
  private readonly jobs = new Map<string, Job>();
  private readonly background = new Set<Promise<unknown>>();
  private capabilities = new CapabilityRegistry().detect();
  private connection?: Connection;
  private wiring?: Promise<Connection>;
  private closing?: Promise<void>;
  private applying = false;
  private pausedAll = false;
  private sendingPaused = false;
  private globalEpoch = 0;
  private readonly sessionEpoch = new Map<string, number>();
  private subscriptionSyncQueued = false;
  private readOnly = new Set<string>();
  private listening = new Set<string>();
  private readonly mediaAbort = new Map<string, AbortController>();
  private readonly previewAbort = new Set<AbortController>();
  private promptCacheEpoch = 0;
  private readonly promptCache = new Map<string, { at: number; epoch: number; fingerprint?: string; task: Promise<{ style?: string; memory?: string }> }>();
  private readonly clock: ReturnType<typeof setInterval>;
  private runtimeError?: ErrorCode;

  constructor(dir: string, private readonly options: Options = {}) {
    this.settings = options.settings ? checked(settingsV2Schema, options.settings) : loadSettingsV2FromDisk(dir);
    this.validateSettings(this.settings);
    this.models = new ModelRouter(this.settings.models, options.getModelKey, this.settings.runtime.maxConcurrentLlmCalls);
    this.journal = new JournalV2(dir);
    this.diagLog = new DiagnosticLog(dir);
    this.media = new MediaEnricher(dir, this.models, id => this.listening.has(id));
    let wall = Date.now(), monotonic = performance.now(), nextMediaPrune = wall;
    this.clock = setInterval(() => {
      const now = Date.now(), tick = performance.now();
      if (now < wall - 1000 || now - wall > 3500 || Math.abs(now - wall - (tick - monotonic)) > 3500) {
        this.pauseAll('all', 'clock-changed');
      }
      wall = now;
      monotonic = tick;
      for (const actor of this.actors.values()) actor.expireContext();
      if (now >= nextMediaPrune) {
        nextMediaPrune = now + 60 * 60_000;
        try { this.media.prune(now); } catch { /* 缓存故障由媒体降级处理 */ }
      }
    }, 1000);
    this.clock.unref?.();
  }

  private validateSettings(settings: SettingsV2) {
    if (settings.xiaohe.mcpUrl) endpoint(settings.xiaohe.mcpUrl, 'mcp');
    const presets = new Map(settings.models.map(preset => [preset.id, preset]));
    if (presets.size !== settings.models.length) throw new BridgeError('invalid-configuration');
    for (const preset of presets.values()) modelEndpoint(preset);
    for (const [key, value] of Object.entries(settings.defaultModels)) {
      const kind = key === 'visionPresetId' ? 'vision' : key === 'sttPresetId' ? 'stt' : 'chat';
      if (value && !supportsModelKind(presets.get(value)?.kind, kind)) throw new BridgeError('invalid-configuration');
    }
    for (const policy of Object.values(settings.conversations)) if (policy.type !== conversationType(policy.conversationId) ||
      (policy.replyPresetId && presets.get(policy.replyPresetId)?.kind !== 'chat')) throw new BridgeError('invalid-configuration');
  }

  private available() {
    if (this.closing) throw new BridgeError('stopped');
    if (this.applying) throw new BridgeError('busy');
  }

  emitTrace(conversationId: string, stage: SessionTraceEntry['stage'], level: SessionTraceEntry['level'], summary: string, detail?: string) {
    const entry = Object.freeze({ id: randomUUID(), conversationId, at: Date.now(), stage, level, summary: summary.slice(0, 300),
      ...(detail !== undefined && { detail: detail.slice(0, 500) }) });
    const items = this.traces.get(conversationId) ?? [];
    if (!items.length) this.traces.set(conversationId, items);
    items.push(entry);
    if (items.length > 40) items.shift();
    this.diagLog.append(entry);
    void this.bus.publish('session.trace', { entry });
  }

  sessionTraces({ conversationId, limit = 30 }: RpcParams<'session.traces'>): RpcResult<'session.traces'> {
    return { items: (this.traces.get(conversationId) ?? []).slice(-limit).reverse() };
  }

  private async client(url: string, authenticated = true) {
    const enabled = authenticated && url === this.settings.xiaohe.mcpUrl && this.settings.xiaohe.hasAuthToken;
    const token = enabled ? await this.options.getMcpToken?.(url) : undefined;
    if (enabled && !token) throw new BridgeError('missing-key');
    return this.options.createClient?.(url, token) ?? new XiaoheClient(url, { token });
  }

  private async connect() {
    this.available();
    if (this.connection) return this.connection;
    if (this.wiring) return this.wiring;
    const { mcpUrl, accountId } = this.settings.xiaohe;
    if (!mcpUrl || !accountId) throw new BridgeError('invalid-configuration');
    this.wiring = (async () => {
      const client = await this.client(mcpUrl);
      try {
        const capabilities = await client.listTools(accountId);
        this.available();
        const createClient = () => this.client(mcpUrl);
        const ingest = new AccountIngestScheduler({ url: mcpUrl, accountId, journal: this.journal, createClient,
          shortPollMs: this.options.shortPollMs, onEvent: input => this.ingested(input),
          selfNames: () => this.settings.xiaohe.accountLabel.trim() ? [this.settings.xiaohe.accountLabel.trim()] : [],
          onState: (ids, state, reason) => {
            if (reason === 'wechat-changed' || reason === 'clock-changed') this.pauseAll('all', reason);
            for (const id of ids) this.actors.get(id)?.ingestState(state, reason);
            this.publishGlobal();
          } });
        const transmit = new TransmitService({ accountId, mcpUrl, journal: this.journal, createWriter: createClient,
          beforeWrite: () => {
            if (this.sendingPaused || this.closing || this.connection?.transmit !== transmit) throw new BridgeError('stopped');
          },
          onUnknown: (id, attemptId) => {
            const actor = this.actors.get(id);
            const attempt = this.journal.get(attemptId);
            if (attempt?.status === 'unknown') actor?.setReceipt({
              status: 'unknown', delivery: attempt.delivery, operation: attempt.operation ?? undefined,
            });
            actor?.pause('send-unknown');
            this.addFeed('alert', id, '微信发信状态未知', '请到微信核对这笔消息的状态。此笔请求不会重发。');
          },
          onIdentityChanged: () => this.pauseAll('all', 'wechat-changed'),
          onInFlight: () => this.publishGlobal(),
        });
        this.capabilities = capabilities;
        const connection = this.connection = { client, ingest, transmit };
        this.publishGlobal();
        return connection;
      } catch (error) {
        await client.close();
        throw error;
      }
    })();
    try { return await this.wiring; }
    finally { this.wiring = undefined; }
  }

  private policy(id: string, requireEnabled = true) {
    const value = Object.hasOwn(this.settings.conversations, id) ? this.settings.conversations[id] : undefined;
    if (!value || (requireEnabled && !value.enabled)) throw new BridgeError('invalid-configuration');
    return value;
  }

  private actor(policy: ConversationPolicy, connection: Connection) {
    const id = policy.conversationId;
    const existing = this.actors.get(id);
    if (existing) return existing;
    let actor: ConversationActor | undefined;
    let previousReason: ErrorCode | undefined;
    actor = new ConversationActor(policy, {
      accountId: this.settings.xiaohe.accountId, journal: this.journal, transmitter: connection.transmit,
      workingMaxMessages: this.settings.memory.workingMaxMessages,
      workingTtlMs: this.settings.memory.workingTtlMinutes * 60_000, ...this.options.actorTiming,
      fence: () => connection.ingest.fence(id),
      capabilities: () => ({ nativeReply: this.capabilities.nativeReply, mentionSend: this.capabilities.mentionSend }),
      fastReplyMode: () => this.settings.runtime.fastReplyMode,
      quietHours: () => this.settings.runtime.quietHours,
      quietHoursNow: this.options.quietHoursNow,
      onTrace: (stage, level, summary, code) => this.emitTrace(id, stage, level, summary, code),
      onMetric: sample => {
        this.journal.recordTurnMetric(sample);
        void this.bus.publish('metrics.updated', { sample });
      },
      prewarm: () => {
        const current = actor?.policy ?? policy;
        try {
          const preset = this.replyPreset(current);
          void this.assemblePromptCached(current, preset.mode).catch(() => {});
        } catch { /* 预热失败交由正式生成处理 */ }
      },
      generate: async (turn, context, grant, signal, onTurnTiming) => {
        const current = actor?.policy ?? policy;
        const preset = this.replyPreset(current);
        return this.models.chat(preset.id, turn, context, {
          signal, cloudApproved: grant.cloudApproved, apiKey: grant.apiKey,
          fastReplyMode: this.settings.runtime.fastReplyMode,
          ...this.fallbackOptions(this.settings),
          profileForMode: mode => this.assemblePromptCached(actor?.policy ?? policy, mode),
          onTrace: (level, summary, code) => this.emitTrace(id, 'model', level, summary, code),
          onTurnTiming,
        });
      },
      onStatus: status => {
        if (actor && this.actors.get(id) !== actor) return;
        void this.bus.publish('session.updated', { conversationId: id, status });
        if (status.phase === 'paused' && status.reason && status.reason !== 'user-paused' && previousReason !== status.reason) {
          this.addFeed('alert', id, '会话已暂停', status.reason);
        } else if (status.phase === 'listening' && status.reason &&
          ['model-timeout', 'model-format', 'model-unavailable', 'model-limit'].includes(status.reason) && previousReason !== status.reason) {
          this.addFeed('alert', id, '本轮未回复（已保持监听）', status.reason);
        }
        previousReason = status.reason;
        this.publishGlobal();
        this.queueSubscriptionSync();
      },
      onScheduleCancelled: reason => this.addFeed('schedule_cancelled', id, '单次定时发信已取消', reason),
    });
    actor.beginDrain(connection.ingest.routeFor(id));
    this.actors.set(id, actor);
    return actor;
  }

  private assemblePromptCached(policy: ConversationPolicy, mode: 'local' | 'cloud'): Promise<{ style?: string; memory?: string; cacheHit?: boolean; promptMs?: number }> {
    if (!this.options.assemblePrompt) return Promise.resolve({ cacheHit: false, promptMs: 0 });
    const key = `${policy.conversationId}:${mode}`;
    const epoch = this.promptCacheEpoch;
    const fp = this.options.promptCacheFingerprint?.(policy, mode);
    const now = Date.now();
    const cached = this.promptCache.get(key);
    const hit = cached !== undefined && cached.epoch === epoch && (
      fp !== undefined ? cached.fingerprint === fp : now - cached.at <= 30_000
    );
    if (hit) {
      return cached.task.then(value => ({ ...value, cacheHit: true, promptMs: 0 }));
    }
    const started = performance.now();
    const task = this.options.assemblePrompt(policy, mode).catch(error => {
      if (this.promptCache.get(key)?.task === task) this.promptCache.delete(key);
      throw error;
    });
    if (this.promptCache.size >= 256 && !this.promptCache.has(key)) {
      const oldest = this.promptCache.keys().next().value;
      if (oldest !== undefined) this.promptCache.delete(oldest);
    }
    this.promptCache.set(key, { at: now, epoch, fingerprint: fp, task });
    return task.then(value => ({ ...value, cacheHit: false, promptMs: Math.max(0, Math.round(performance.now() - started)) }));
  }

  invalidatePromptCache() {
    this.promptCacheEpoch++;
    this.promptCache.clear();
  }

  private replyPreset(policy: ConversationPolicy) {
    const id = policy.replyPresetId ?? this.settings.defaultModels.replyPresetId;
    const preset = this.settings.models.find(preset => preset.id === id && preset.kind === 'chat');
    if (!preset) throw new BridgeError('invalid-configuration');
    return preset;
  }

  private fallbackOptions(settings: SettingsV2) {
    const fallbackPresetId = settings.defaultModels.fallbackReplyPresetId;
    return { fallbackPresetId, fallbackCloudApproved: !!fallbackPresetId && settings.runtime.approvedCloudPresetIds.includes(fallbackPresetId) };
  }

  private syncSubscriptions() {
    const connection = this.connection;
    if (!connection) return;
    const targets = this.pausedAll ? [] : Object.values(this.settings.conversations).filter(policy => policy.enabled &&
      (this.actors.get(policy.conversationId)?.needsIngest || this.readOnly.has(policy.conversationId))).map(policy => ({
      conversationId: policy.conversationId, type: policy.type,
      priority: this.actors.get(policy.conversationId)?.needsIngest ? 'reply' as const : 'background' as const,
    }));
    const next = new Set(targets.map(target => target.conversationId));
    for (const [id, controller] of this.mediaAbort) if (!next.has(id)) {
      controller.abort();
      this.mediaAbort.delete(id);
    }
    this.listening = next;
    const safetyPeers = Object.values(this.settings.conversations).map(policy => ({
      conversationId: policy.conversationId, type: policy.type,
    }));
    connection.ingest.configure(this.capabilities, targets, safetyPeers);
    for (const id of next) {
      try { connection.ingest.fence(id); }
      catch { continue; }
      this.actors.get(id)?.ingestState('listening');
    }
  }

  private queueSubscriptionSync() {
    if (this.subscriptionSyncQueued) return;
    this.subscriptionSyncQueued = true;
    queueMicrotask(() => {
      this.subscriptionSyncQueued = false;
      if (!this.closing && !this.applying) this.syncSubscriptions();
    });
  }

  private track<T>(task: Promise<T>) {
    this.background.add(task);
    void task.finally(() => this.background.delete(task)).catch(() => {});
    return task;
  }

  private ingested(input: EventInput) {
    const { event } = input;
    const id = event.conversationId;
    const connection = this.connection;
    if (!connection || !this.listening.has(id)) return;
    if (event.origin === 'live') {
      const summary = event.kind === 'recall' ? '收到消息撤回事件' : event.isSelf ? '收到本人发言' :
        event.scopeType === 'group' ? '收到群聊消息' : '收到会话消息';
      this.emitTrace(id, 'inbound', 'info', summary, event.scopeType === 'group' && !event.isSelf ? event.senderLabel : undefined);
    }
    const actor = this.actors.get(id);
    const forReply = actor?.observe(input) ?? false;
    if (event.kind === 'recall') {
      if (event.recallTargetRef) this.journal.markPluginBufferRecalled(id, event.recallTargetRef);
      void this.bus.publish('recall', eventSnapshot(event));
      return;
    }
    const isMedia = event.kind === 'image' || event.kind === 'voice';
    const needName = event.scopeType === 'group' && event.senderId && (!event.senderLabel || event.senderLabel === event.senderId) && this.capabilities.groupMembers;
    if (!isMedia && !needName) { void this.bus.publish('message', eventSnapshot(event)); return; }
    const controller = this.mediaAbort.get(id) ?? new AbortController();
    this.mediaAbort.set(id, controller);
    this.track((async () => {
      let enriched = input;
      let mediaStarted = false;
      try {
        const bound = connection.ingest.boundIdentity;
        const remote = bound && bound.binding.account_id === event.accountId && identityKey(bound) === input.identity
          ? bound
          : await connection.client.identify(event.accountId, controller.signal);
        if (identityKey(remote) !== input.identity) throw new BridgeError('wechat-changed');
        const scope = { ...remote.binding, conversation_id: id };
        const { replyPresetId, visionPresetId: explicitVisionPresetId, sttPresetId } = this.settings.defaultModels;
        const visionPresetId = explicitVisionPresetId ?? replyPresetId;
        const mediaPresetId = event.kind === 'image' ? visionPresetId : sttPresetId;
        const mediaCloudApproved = (forReply && actor?.cloudApproved) ||
          (!!mediaPresetId && this.settings.runtime.approvedCloudPresetIds.includes(mediaPresetId));
        if (isMedia) {
          let failure: ErrorCode | undefined;
          const started = performance.now();
          mediaStarted = true;
          enriched = await this.media.enrich(input, scope, connection.client, {
            visionPresetId, sttPresetId,
            priority: forReply ? 'reply' : 'background', cloudApproved: mediaCloudApproved,
            onDegraded: code => { failure = code; },
          }, controller.signal);
          this.traceMedia(event, enriched, Math.round(performance.now() - started), failure);
        }
        if (forReply && !controller.signal.aborted && this.connection === connection) actor?.completeMedia(enriched);
        if (needName) {
          const member = (await connection.client.groupMembers(scope, controller.signal)).find(v => v.userId === event.senderId);
          if (member) enriched = { ...enriched, event: { ...enriched.event, senderLabel: member.displayName } };
        }
      } catch (error) {
        if (errorCode(error) === 'wechat-changed') this.pauseAll('all', 'wechat-changed');
        if (isMedia && !mediaStarted) this.traceMedia(event, undefined, 0, controller.signal.aborted ? 'stopped' : errorCode(error));
        if (forReply && !controller.signal.aborted && this.connection === connection) actor?.completeMedia(enriched);
      }
      if (!controller.signal.aborted && this.connection === connection && this.listening.has(id) &&
          !this.journal.isRecalled(input.route, eventRefHash(input))) void this.bus.publish('message', eventSnapshot(enriched.event));
    })());
  }

  /** 只记录耗时与原因码，绝不写入图片描述或语音转写正文。 */
  private traceMedia(event: NormalizedEvent, enriched: EventInput | undefined, ms: number, failure?: ErrorCode) {
    if (event.origin !== 'live') return;
    const label = event.kind === 'image' ? '图片' : '语音';
    const status = enriched?.event.media?.enrichmentStatus;
    if (status === 'ok') this.emitTrace(event.conversationId, 'inbound', 'info', `${label}解析完成（耗时 ${ms}ms）`);
    else if (!enriched || status === 'degraded' || status === 'failed') {
      this.emitTrace(event.conversationId, 'inbound', 'warn', `${label}解析失败（${failure ?? 'internal-error'}）`);
    }
  }

  async setReadOnlySubscriptions(ids: Iterable<string>) {
    this.available();
    const next = new Set(ids);
    for (const id of next) this.policy(id);
    if (next.size) {
      const connection = await this.connect();
      for (const id of next) this.actor(this.policy(id), connection);
    }
    this.readOnly = next;
    this.syncSubscriptions();
  }

  status(): RpcResult<'system.status'> {
    const global = this.global();
    const extra = this.statusContributor?.();
    const accountId = this.settings.xiaohe.accountId;
    const mcpUrl = this.settings.xiaohe.mcpUrl;
    const sessions = Object.fromEntries(Object.values(this.settings.conversations).map(policy => {
      const actor = this.actors.get(policy.conversationId);
      if (actor) return [policy.conversationId, actor.status];
      return [policy.conversationId, this.projectedStatus(policy.conversationId, accountId, mcpUrl)];
    }));
    return { capabilities: this.capabilities, globalPhase: global.phase, sessions,
      plugins: extra?.plugins ?? {}, unreadFeedCount: this.countFeed(), pendingProposalCount: extra?.pendingProposalCount ?? 0 };
  }

  systemMetrics(params: RpcParams<'system.metrics'> = {}): RpcResult<'system.metrics'> {
    return this.journal.queryTurnMetrics({
      windowHours: params.windowHours,
      conversationId: params.conversationId,
      recentLimit: params.recentLimit,
    });
  }

  private statusContributor?: StatusContributor;
  setStatusContributor(contributor: StatusContributor) { this.statusContributor = contributor; }
  get currentSettings(): SettingsV2 { return this.settings; }
  get modelRouter(): ModelRouter { return this.models; }
  get currentIdentity(): string | undefined { return this.connection?.ingest.currentIdentity; }

  async historyContext(conversationId: string, signal?: AbortSignal) {
    const policy = this.policy(conversationId, false);
    const connection = await this.connect();
    const remote = await connection.client.identify(this.settings.xiaohe.accountId, signal);
    const route = connection.ingest.routeFor(conversationId);
    const identity = identityKey(remote);
    const saved = this.journal.read(route);
    if (saved && saved.identity !== identity) throw new BridgeError('wechat-changed');
    return {
      backfiller: new HistoryBackfiller(connection.client),
      scope: { ...remote.binding, conversation_id: conversationId },
      type: policy.type, route, identity,
    };
  }

  async fetchBackfillEvents(request: BackfillRequest, signal?: AbortSignal): Promise<NormalizedEvent[]> {
    const ctx = await this.historyContext(request.conversationId, signal);
    const events: NormalizedEvent[] = [];
    await ctx.backfiller.run(randomUUID(), request, ctx.scope, ctx.type, ctx.route, ctx.identity, {
      signal, onEvent: ({ event }) => {
        if (event.kind !== 'recall' && !this.journal.isRecalled(ctx.route, refHash(event.messageRef, this.capabilities.accountWideEvents ? event.conversationId : undefined))) {
          events.push(event);
        }
      },
    });
    return events;
  }

  private projectedStatus(conversationId: string, accountId: string, mcpUrl: string): SessionRuntimeState {
    if (!accountId) return { phase: 'idle', replyMode: 'off' };
    const peer = peerKey(accountId, conversationId);
    const latest = this.journal.latest(peer);
    const receipt = latest ? statusReceipt({
      status: latest.status === 'trying' ? 'unknown' : latest.status,
      delivery: latest.delivery, operation: latest.operation ?? undefined,
    }) : undefined;
    if (this.journal.optedOut(peer)) {
      return { phase: 'locked-opt-out', replyMode: 'off', reason: 'peer-stopped', ...(receipt && { receipt }) };
    }
    if (this.journal.uncertain(peer)) {
      return { phase: 'blocked-unknown', replyMode: 'off', reason: 'send-unknown', ...(receipt && { receipt }) };
    }
    if (mcpUrl) {
      const route = this.connection ? this.connection.ingest.routeFor(conversationId) : routeKey(mcpUrl, accountId, conversationId);
      const accountRoute = routeKey(mcpUrl, accountId, undefined);
      const fault = this.journal.read(route)?.fault ?? this.journal.read(accountRoute)?.fault;
      if (fault) return { phase: 'paused', replyMode: 'off', reason: errorCode(new BridgeError(fault)), ...(receipt && { receipt }) };
    }
    return { phase: 'idle', replyMode: 'off', ...(receipt && { receipt }) };
  }

  private global(): PushPayload<'global.updated'> {
    const extra = this.statusContributor?.();
    const activePlugins = extra?.activePluginCount ?? 0;
    const phase = this.pausedAll || this.runtimeError ? 'paused' : this.wiring && !this.connection ? 'connecting' :
      this.listening.size || activePlugins ? 'running' : 'idle';
    return { phase, activeAutoCount: [...this.actors.values()].filter(actor => actor.isAuto).length,
      activePluginCount: activePlugins, inFlightCount: (this.connection?.transmit.inFlight ?? 0) + this.models.inFlight,
      ...(this.runtimeError && { error: this.runtimeError }) };
  }

  private publishGlobal() { if (!this.closing) void this.bus.publish('global.updated', this.global()); }

  pauseAll(scope: RpcParams<'system.pauseAll'>['scope'], reason: ErrorCode) {
    this.globalEpoch++;
    this.sendingPaused = true;
    if (scope === 'all') {
      this.pausedAll = true;
      for (const job of this.jobs.values()) job.controller.abort();
      for (const controller of this.previewAbort) controller.abort();
    }
    this.runtimeError = reason;
    for (const actor of this.actors.values()) {
      if (scope === 'all') actor.pause(reason);
      else actor.pauseSending(reason);
    }
    this.options.onPauseAll?.(scope);
    this.syncSubscriptions();
    this.publishGlobal();
    return true as const;
  }

  pause(conversationId: string, reason: ErrorCode = 'user-paused') {
    this.available();
    this.policy(conversationId);
    this.sessionEpoch.set(conversationId, (this.sessionEpoch.get(conversationId) ?? 0) + 1);
    for (const job of this.jobs.values()) if (job.conversationId === conversationId) job.controller.abort();
    this.actors.get(conversationId)?.pause(reason);
    this.syncSubscriptions();
    return true as const;
  }

  resumeCooldown(conversationId: string) {
    this.available();
    this.policy(conversationId);
    this.actors.get(conversationId)?.resumeCooldown();
    return true as const;
  }

  async arm(params: RpcParams<'session.arm'>) {
    const check = this.sessionGuard(params.conversationId);
    const policy = this.policy(params.conversationId);
    this.requireConsent(policy, params.consent, params.replyMode === 'auto', params.groupConfirmed);
    const preset = this.replyPreset(policy);
    if (preset.mode === 'cloud' && !params.cloudApproved) throw new BridgeError('cloud-not-approved');
    if (preset.mode === 'local' && params.apiKey) throw new BridgeError('invalid-key');
    const connection = await this.connect();
    const remote = await connection.client.identify(this.settings.xiaohe.accountId, undefined, params.replyMode === 'auto', policy.conversationId);
    check();
    if (policy !== this.policy(params.conversationId) || connection !== this.connection) throw new BridgeError('settings-changed');
    this.bindIdentity(connection, remote);
    const actor = this.actor(policy, connection);
    const count = policy.backfillOnArmCount;
    const history = !!count && this.capabilities.historyQuery;
    const token = actor.arm({ mode: params.replyMode, cloudApproved: params.cloudApproved, apiKey: params.apiKey }, history);
    this.pausedAll = false;
    if (params.replyMode === 'auto') this.sendingPaused = false;
    if (!this.sendingPaused) this.runtimeError = undefined;
    this.syncSubscriptions();
    if (token) {
      const rows: NormalizedEvent[] = [];
      try {
        this.startBackfill({ conversationId: policy.conversationId, purpose: 'context', recentCount: count }, connection,
          event => rows.push(event), () => actor.finishArm(token, rows.filter(event => !this.wasRecalled(connection, event))));
      } catch (error) {
        actor.finishArm(token, []);
        if (errorCode(error) !== 'busy') throw error;
      }
    }
    return true as const;
  }

  private requireConsent(policy: ConversationPolicy, consent: boolean, sends: boolean, groupConfirmed?: boolean) {
    if (!consent || policy.type === 'service' || (sends && policy.type === 'group' && !groupConfirmed)) {
      throw new BridgeError('send-not-authorized');
    }
  }

  private sessionGuard(id: string) {
    this.available();
    const global = this.globalEpoch, session = this.sessionEpoch.get(id);
    return () => {
      this.available();
      if (global !== this.globalEpoch || session !== this.sessionEpoch.get(id)) throw new BridgeError('stopped');
    };
  }

  private bindIdentity(connection: Connection, remote: RemoteIdentity) {
    try { connection.ingest.bindIdentity(remote); }
    catch (error) {
      if (errorCode(error) === 'wechat-changed') this.pauseAll('all', 'wechat-changed');
      throw error;
    }
  }

  private wasRecalled(connection: Connection, event: NormalizedEvent) {
    return this.journal.isRecalled(connection.ingest.routeFor(event.conversationId),
      refHash(event.messageRef, this.capabilities.accountWideEvents ? event.conversationId : undefined));
  }

  async sendOneShot(params: RpcParams<'session.sendOneShot'>) {
    const check = this.sessionGuard(params.conversationId);
    const policy = this.policy(params.conversationId, false);
    this.requireConsent(policy, params.consent, true, params.groupConfirmed);
    const connection = await this.connect();
    const remote = await connection.client.identify(this.settings.xiaohe.accountId, undefined, true, policy.conversationId);
    check();
    if (policy !== this.policy(params.conversationId) || connection !== this.connection) throw new BridgeError('settings-changed');
    this.bindIdentity(connection, remote);
    this.actor(policy, connection).schedule(params.text, params.request, params.at);
    this.pausedAll = false;
    this.sendingPaused = false;
    this.runtimeError = undefined;
    this.syncSubscriptions();
    return true as const;
  }

  async refreshReceipt(conversationId: string) {
    const policy = this.policy(conversationId, false);
    const connection = await this.connect();
    const actor = this.actor(policy, connection);
    const attempt = this.journal.latest(actor.peer);
    if (!attempt?.operation) throw new BridgeError('no-operation');
    const remote = await connection.client.identify(this.settings.xiaohe.accountId);
    if (identityKey(remote) !== attempt.identity) throw new BridgeError('wechat-changed');
    const result = await connection.client.operation(attempt.operation);
    if (this.connection !== connection) throw new BridgeError('turn-obsolete');
    if (result.status === 'unknown') {
      // 查回执发现状态未知：立刻原子落盘未确认 unknown 并撤销授权锁定后续发信，绝不因并发丢弃未知状态。
      if (this.journal.markUnknown(attempt.id, result.operation)) {
        actor.updateReceipt(result);
        actor.pause('send-unknown');
        this.addFeed('alert', conversationId, '回执查询结果未知', '小禾报告该笔发送状态未知，已锁定后续发信，请到微信核对。此笔请求不会重发。');
      }
      return statusReceipt(result);
    }
    if (this.journal.latest(actor.peer)?.id !== attempt.id) throw new BridgeError('turn-obsolete');
    // 未知尝试只通过人工确认解除锁定；已提交记录可更新送达状态。
    if (attempt.status === 'submitted') this.journal.complete(attempt.id, result);
    actor.updateReceipt(result);
    return statusReceipt(result);
  }

  async recover(params: RpcParams<'session.recover'>) {
    if (!params.confirmed) throw new BridgeError('invalid-configuration');
    const policy = this.policy(params.conversationId, false);
    const connection = await this.connect();
    const actor = this.actor(policy, connection);
    if (actor.needsIngest || connection.transmit.settled(params.conversationId)) throw new BridgeError('busy');
    if (params.action === 'reset-read') await connection.ingest.restart(params.conversationId, true);
    else if (params.action === 'restore-consent') this.journal.restoreConsent(actor.peer);
    else {
      const attempt = this.journal.uncertain(actor.peer);
      if (attempt?.status === 'trying') throw new BridgeError('busy');
      if (attempt) this.journal.acknowledge(attempt.id);
    }
    actor.recover();
    return true as const;
  }

  async backfill(params: RpcParams<'session.backfill'>) {
    this.available();
    if (params.action === 'cancel') {
      this.jobs.get(params.jobId)?.controller.abort();
      return { jobId: params.jobId };
    }
    this.policy(params.request.conversationId);
    const connection = await this.connect();
    if (!this.capabilities.historyQuery) throw new BridgeError('mcp-contract');
    return { jobId: this.startBackfill(params.request, connection) };
  }

  private startBackfill(request: BackfillRequest, connection: Connection, collect?: (event: NormalizedEvent) => void, done?: () => void) {
    const { conversationId, purpose } = request;
    const policy = this.policy(conversationId);
    if (this.jobs.size >= 8 || [...this.jobs.values()].some(job => job.conversationId === conversationId)) throw new BridgeError('busy');
    const jobId = randomUUID();
    const controller = new AbortController();
    const accountId = this.settings.xiaohe.accountId;
    const progress = (p: { fetched: number; done: boolean; error?: string }) => {
      void this.bus.publish('backfill.progress', { jobId, conversationId, fetched: p.fetched, done: p.done,
        ...(isErrorCode(p.error) && { error: p.error }) });
    };
    const task = this.track((async () => {
      let started = false;
      try {
        const remote = await connection.client.identify(accountId, controller.signal);
        const route = connection.ingest.routeFor(conversationId);
        const identity = identityKey(remote);
        const saved = this.journal.read(route);
        if (saved && saved.identity !== identity) throw new BridgeError('wechat-changed');
        started = true;
        await new HistoryBackfiller(connection.client).run(jobId, request, { ...remote.binding, conversation_id: conversationId },
          policy.type, route, identity, {
            signal: controller.signal, onProgress: progress,
            onEvent: ({ event }) => {
              if (event.kind !== 'recall' && !this.wasRecalled(connection, event)) {
                collect?.(event);
                void this.bus.publish('history', Object.freeze({ jobId, purpose, event: eventSnapshot(event) }));
              }
            },
          });
      } catch (error) {
        if (!started) progress({ fetched: 0, done: true, error: errorCode(error) });
        if (errorCode(error) === 'wechat-changed') this.pauseAll('all', 'wechat-changed');
      } finally {
        this.jobs.delete(jobId);
        done?.();
      }
    })());
    this.jobs.set(jobId, { conversationId, controller, task });
    return jobId;
  }

  async applySettings(value: SettingsV2, cloudApiKeys?: Record<string, string>) {
    this.available();
    const next = checked(settingsV2Schema, value);
    this.validateSettings(next);
    this.applying = true;
    try {
      const old = this.settings;
      const changedConnection = fingerprint([old.xiaohe.mcpUrl, old.xiaohe.accountId, old.xiaohe.hasAuthToken]) !==
        fingerprint([next.xiaohe.mcpUrl, next.xiaohe.accountId, next.xiaohe.hasAuthToken]);
      const preset = (policy: ConversationPolicy, settings: SettingsV2) => {
        const id = policy.replyPresetId ?? settings.defaultModels.replyPresetId;
        return settings.models.find(preset => preset.id === id);
      };
      const fallback = (settings: SettingsV2) => [
        this.fallbackOptions(settings), settings.models.find(model => model.id === settings.defaultModels.fallbackReplyPresetId),
      ];
      const changedFallback = fingerprint(fallback(old)) !== fingerprint(fallback(next));
      const changedWindow = old.memory.workingMaxMessages !== next.memory.workingMaxMessages ||
        old.memory.workingTtlMinutes !== next.memory.workingTtlMinutes;
      for (const [id, actor] of this.actors) {
        const nextPolicy = Object.hasOwn(next.conversations, id) ? next.conversations[id] : undefined;
        if (changedConnection || !nextPolicy?.enabled || changedWindow || changedFallback ||
          fingerprint(preset(actor.policy, old)) !== fingerprint(preset(nextPolicy, next))) {
          for (const job of this.jobs.values()) if (job.conversationId === id) job.controller.abort();
          this.mediaAbort.get(id)?.abort();
          this.mediaAbort.delete(id);
          actor.pause('settings-changed');
          this.actors.delete(id);
        } else if (fingerprint(actor.policy) !== fingerprint(nextPolicy)) actor.updatePolicy(nextPolicy);
      }
      if (changedConnection) {
        for (const job of this.jobs.values()) job.controller.abort();
        for (const controller of this.mediaAbort.values()) controller.abort();
        await this.closeConnection();
      }
      this.models.configure(next.models, next.runtime.maxConcurrentLlmCalls);
      this.settings = next;
      this.invalidatePromptCache();
      this.readOnly = new Set([...this.readOnly].filter(id => Object.hasOwn(next.conversations, id) && next.conversations[id]?.enabled));
      this.options.onSettingsApplied?.(next, cloudApiKeys);
    } finally { this.applying = false; }
    if (this.readOnly.size && !this.pausedAll) await this.setReadOnlySubscriptions(this.readOnly);
    this.syncSubscriptions();
    this.publishGlobal();
    return true as const;
  }

  async accounts(mcpUrl = this.settings.xiaohe.mcpUrl) {
    this.available();
    endpoint(mcpUrl, 'mcp');
    const client = await this.client(mcpUrl);
    try { return (await client.accounts()).map(({ binding: _binding, ...row }) => row); }
    finally { await client.close(); }
  }

  async listConversations(params: RpcParams<'xiaohe.conversations'>): Promise<RpcResult<'xiaohe.conversations'>> {
    const { accountId = this.settings.xiaohe.accountId, cursor, query, limit, type } = params;
    const client = await this.client(this.settings.xiaohe.mcpUrl);
    try {
      const remote = await client.identify(accountId);
      const page = await client.conversations(remote.binding, { cursor, query, limit });
      return { nextCursor: page.has_more ? page.next_cursor! : null, ...(page.sync_status && { syncStatus: page.sync_status }),
        items: page.conversations.filter(item => !type || item.type === type).map(row => ({
          conversationId: row.conversation_id, type: row.type, displayName: row.display_name ?? row.remark ?? row.nickname ?? row.conversation_id,
          ...(row.nickname != null && { nickname: row.nickname }), ...(row.remark != null && { remark: row.remark }),
          ...(row.is_sticky !== undefined && { isSticky: row.is_sticky }),
        })) };
    } finally { await client.close(); }
  }

  async groupMembers(conversationId: string) {
    const { client } = await this.connect();
    const remote = await client.identify(this.settings.xiaohe.accountId);
    return client.groupMembers({ ...remote.binding, conversation_id: conversationId });
  }

  async discoverCapabilities() {
    if (!this.settings.xiaohe.mcpUrl || !this.settings.xiaohe.accountId) return this.capabilities;
    await this.connect();
    return this.capabilities;
  }

  healthCheck(params: RpcParams<'system.healthCheck'>): Promise<RpcResult<'system.healthCheck'>> {
    this.available();
    const controller = new AbortController();
    this.previewAbort.add(controller);
    const task = this.runHealthCheck(params, controller.signal).finally(() => this.previewAbort.delete(controller));
    return this.track(task);
  }

  private async runHealthCheck({ presetId, conversationId }: RpcParams<'system.healthCheck'>, signal: AbortSignal) {
    const settings = this.settings;
    const { mcpUrl, accountId } = settings.xiaohe;
    const selected = presetId ?? settings.defaultModels.replyPresetId;
    const approved = !!selected && settings.runtime.approvedCloudPresetIds.includes(selected);
    const steps: HealthCheckStep[] = [];
    const check = async (id: HealthCheckStep['id'], label: string, work: () => Promise<string>, advice: (code: ErrorCode) => string) => {
      const start = performance.now();
      let ok = false, detail: string;
      try { signal.throwIfAborted(); detail = await work(); ok = true; }
      catch (error) {
        const code = signal.aborted ? 'stopped' : errorCode(error);
        detail = code === 'stopped' ? '体检已中止，请重新运行。' : `${advice(code)}（${code}）`;
      }
      steps.push({ id, label, ok, detail: detail.slice(0, 400), durationMs: Math.round(performance.now() - start) });
      return ok;
    };
    let account: Account | undefined;
    await check('xiaohe', '小禾连接', async () => {
      if (!mcpUrl || !accountId) throw new BridgeError('invalid-configuration');
      const client = await this.client(mcpUrl);
      try {
        await client.systemStatus(signal);
        const accounts = (await client.accounts(signal)).filter(row => row.id === accountId);
        account = accounts.length === 1 ? accounts[0] : undefined;
        if (!account?.binding || !account.canRead) throw new BridgeError('wechat-permission');
        return '小禾连接正常，微信账号已就绪。';
      } finally { await client.close().catch(() => {}); }
    }, code => code === 'missing-key' ? '请解锁并检查小禾访问令牌。' : '请确认小禾正在运行、连接地址正确且微信账号已就绪并允许读消息。');

    await check('whitelist', '发信白名单', async () => {
      if (!account?.canSend) throw new BridgeError('wechat-permission');
      const targets = conversationId !== undefined ? [conversationId] :
        Object.values(settings.conversations).filter(policy => policy.enabled).map(policy => policy.conversationId);
      const allowed = new Set(account.sendConversations);
      const missing = allowed.has('*') ? 0 : targets.filter(id => !allowed.has(id)).length;
      if (missing) throw new BridgeError('send-not-authorized');
      return targets.length ? `账号允许发信，已核对 ${targets.length} 个会话。` : '账号允许发信，当前没有启用的会话。';
    }, code => code === 'send-not-authorized' ? '请在小禾发信白名单中加入目标会话或启用的会话。' : '请先确认账号就绪，并在小禾开启文字发信权限。');

    const ready = await check('credentials', '模型配置与凭据', async () => {
      if (!selected) throw new BridgeError('invalid-configuration');
      await this.models.checkChatCredentials(selected, approved, signal);
      return '所选对话模型配置和凭据已就绪。';
    }, code => code === 'cloud-not-approved' ? '请先授权所选云模型。' : code === 'missing-key' || code === 'invalid-key'
      ? '请重新录入并解锁所选云模型的 API Key。' : '请检查对话模型预设、模型名称和请求地址。');

    const activity: string[] = [];
    await check('model', '模型最小请求', async () => {
      if (!selected || !ready) throw new BridgeError('invalid-configuration');
      if (this.settings !== settings) throw new BridgeError('settings-changed');
      await this.models.chat(selected, ['你好'], [], {
        ...this.fallbackOptions(settings), cloudApproved: approved, signal, includeEmptyContext: true,
        onTrace: (level, summary, code) => {
          if (level === 'warn') activity.push(summary);
          else if (summary.startsWith('模型决策')) activity.unshift(summary);
          if (conversationId) this.emitTrace(conversationId, 'model', level, summary, code);
        },
      });
      return activity.join('。');
    }, code => {
      const reason = !ready ? '请先修复模型配置与凭据，再重试。' : code === 'model-auth' ? '请检查 API Key 的有效期与模型访问权限。' :
        code === 'model-format' ? '请确认模型支持聊天补全和 JSON 决策输出。' : code === 'settings-changed' ? '模型设置已变化，请重新运行体检。' :
        '请检查模型端点、服务可用性和调用额度，再重试。';
      return [reason, ...activity].join(' ');
    });
    return { ok: steps.every(step => step.ok), steps };
  }

  async preview(params: RpcParams<'model.preview'>): Promise<RpcResult<'model.preview'>> {
    this.available();
    const controller = new AbortController();
    this.previewAbort.add(controller);
    const policy = new PolicyEngine();
    try {
      let model: ReplyModel;
      try {
        model = await ReplyModel.load(params.model);
      } catch (error) {
        const code = errorCode(error);
        if ((code === 'cloud-profile' || code === 'profile-unreadable') && (params.model.stylePath || params.model.memoryPath)) {
          model = await ReplyModel.load({ ...params.model, stylePath: '', memoryPath: '' });
        } else {
          throw error;
        }
      }
      const rule = policy.classify(params.text);
      if (rule === 'manual' || rule === 'stop') return { action: rule };
      const decision = rule === 'identity' ? { action: rule } as const :
        await this.models.run('reply', () => model.generate([params.text], [], controller.signal, CHAT_TIMEOUT_MS, 4096), controller.signal);
      const result = policy.outbound(decision);
      if (decision.action === 'reply' && !result.text) return { action: 'manual' };
      return { action: decision.action, ...(result.text && { text: result.text }) };
    } finally { this.previewAbort.delete(controller); }
  }

  evaluatePolicy(params: RpcParams<'policy.evaluate'>): RpcResult<'policy.evaluate'> {
    return new PolicyEngine().evaluate({
      text: params.text,
      policy: params.policy,
      quietHours: params.quietHours ?? this.settings.runtime.quietHours,
      mentionsSelf: params.mentionsSelf,
      inQuietHours: params.inQuietHours,
      nowMs: (this.options.quietHoursNow ?? Date.now)(),
    });
  }

  private addFeed(kind: FeedItem['kind'], id: string, title: string, body: string) {
    const item: FeedItem = { id: randomUUID(), kind, title, body, conversationId: id, createdAt: Date.now(), read: false };
    this.journal.saveFeedItem({ id: item.id, kind, title, body, conversation_id: id,
      plugin_id: null, ref_path: null, created_at: item.createdAt, read: 0 });
    void this.bus.publish('feed.added', { item, notifyDesktop: true });
  }

  private countFeed() {
    let offset = 0;
    while (true) {
      const rows = this.journal.listFeedItems(500, offset, true);
      offset += rows.length;
      if (rows.length < 500) return offset;
    }
  }

  listFeed(params: RpcParams<'feed.list'>) {
    const offset = params.cursor === undefined ? 0 : Number(params.cursor);
    if (!Number.isSafeInteger(offset) || offset < 0 || (params.cursor !== undefined && !/^\d+$/.test(params.cursor))) {
      throw new BridgeError('invalid-configuration');
    }
    const limit = params.limit ?? 100;
    const rows = this.journal.listFeedItems(limit + 1, offset, params.unreadOnly);
    return { items: rows.slice(0, limit).map(feedItem), nextCursor: rows.length > limit ? String(offset + limit) : null };
  }

  markFeedRead(ids: string[]) { this.journal.markFeedRead(ids); return true as const; }

  get transmitter() { return this.connection?.transmit; }

  private async closeConnection() {
    const connection = this.connection;
    this.connection = undefined;
    this.capabilities = new CapabilityRegistry().detect();
    this.listening.clear();
    await Promise.allSettled([
      connection?.ingest.stop(), connection?.transmit.drain(), connection?.client.close(), this.wiring,
    ]);
  }

  close() {
    if (this.closing) return this.closing;
    clearInterval(this.clock);
    this.pauseAll('all', 'stopped');
    this.closing = (async () => {
      await this.closeConnection();
      await Promise.allSettled([...this.background]);
      this.journal.close();
    })();
    return this.closing;
  }
}
