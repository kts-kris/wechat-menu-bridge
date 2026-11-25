import { randomUUID } from 'node:crypto';
import { BridgeError, id, sha, tomorrow } from '../../contracts.ts';
import type { Context, Decision } from '../../model.ts';
import { MAX_AGE } from '../../policy.ts';
import { errorCode, type ErrorCode } from '../contracts/errors.ts';
import type { NormalizedEvent } from '../contracts/events.ts';
import type { SessionRuntimeState, SessionTraceEntry, TurnPerfSample } from '../contracts/ipc.ts';
import { riskLevel, type ConversationPolicy, type QuietHoursConfig } from '../contracts/settings.ts';
import type { ChatTurnTiming } from '../llm/router.ts';
import { peerKey, type Receipt } from '../mcp/client.ts';
import { eventRefHash, type EventInput, type SendFence } from '../mcp/ingest.ts';
import { classifyTurnBottleneck, type JournalV2 } from '../storage/journal-v2.ts';
import { isInQuietHours, manualReview, PolicyEngine, reviewDescription, type PolicyDecision } from './policy.ts';
import type { TransmitService } from './transmit.ts';

type Timer = ReturnType<typeof setTimeout>;
type Grant = { mode: 'draft' | 'auto'; cloudApproved?: boolean; apiKey?: string };
type Fence = SendFence & { identity: string };
type Options = {
  accountId: string; journal: JournalV2; transmitter: TransmitService;
  fence: () => Fence;
  generate: (
    turn: string[], context: Context[], grant: Grant, signal: AbortSignal,
    onTurnTiming?: (timing: ChatTurnTiming) => void,
  ) => Promise<Decision>;
  prewarm?: (grant: Grant) => void;
  capabilities?: () => { nativeReply: boolean; mentionSend: boolean };
  quietHours?: () => QuietHoursConfig | undefined;
  quietHoursNow?: () => number;
  onStatus?: (status: SessionRuntimeState) => void; onScheduleCancelled?: (reason: ErrorCode) => void;
  onTrace?: (stage: SessionTraceEntry['stage'], level: SessionTraceEntry['level'], summary: string, code?: ErrorCode) => void;
  onMetric?: (sample: TurnPerfSample) => void;
  workingMaxMessages?: number; workingTtlMs?: number; debounceMs?: number; batchMaxMs?: number;
  now?: () => number;
};
type Shot = { request: string; text: string; at: number; deadline: number; timer?: Timer };
const traceReasons: Partial<Record<ErrorCode, string>> = {
  'user-paused': '用户手动暂停', 'manual-takeover': '本人接管', 'manual-review': '需要人工复核',
  'settings-changed': '回复配置已变更', 'stopped': '引擎或会话已停止', 'peer-stopped': '对方要求停止回复',
  'send-unknown': '发信结果未知，请在微信核对', 'send-fence': '发送前检测到新的会话事件或游标变更',
  'send-rejected': '小禾拒绝发信', 'send-not-authorized': '当前会话未获发信授权',
  'duplicate-attempt': '已有同一笔发信记录', 'turn-obsolete': '本轮回复已过期或被更新',
  'wechat-permission': '微信账号或会话权限不足', 'wechat-changed': '微信登录状态已变化',
  'mcp-offline': '小禾连接断开', 'model-auth': '模型鉴权失败', 'model-timeout': '模型调用超时',
};

export class ConversationActor {
  readonly peer: string;
  private readonly engine = new PolicyEngine();
  private statusValue: SessionRuntimeState = { phase: 'idle', replyMode: 'off' };
  private grant?: Grant;
  private shot?: Shot;
  private timer?: Timer;
  private draftTimer?: Timer;
  private cooldown?: Timer;
  private generation?: AbortController;
  private readonly processingRefs = new Set<string>();
  private window: NormalizedEvent[] = [];
  private queue: NormalizedEvent[] = [];
  private revision = 0;
  private prewarmedRevision?: number;
  private lastEnqueuedAt?: number;
  private firstEnqueuedPerfMs?: number;
  private firstEnqueuedAfterGap = false;
  private since?: number;
  private replyAfter = 0;
  private armed = false;
  private synced = false;
  private lastPhaseFault?: ErrorCode;
  private backfillToken?: symbol;

  constructor(private policyValue: ConversationPolicy, private readonly options: Options) {
    this.peer = peerKey(options.accountId, policyValue.conversationId);
    const fault = this.ironLaw();
    if (fault) this.pause(fault);
  }

  private now() { return (this.options.now ?? Date.now)(); }
  private activeQuietHoursAction(): QuietHoursConfig['action'] | undefined {
    if (this.policy.ignoreQuietHours) return undefined;
    const config = this.options.quietHours?.();
    if (!config || !isInQuietHours(config, (this.options.quietHoursNow ?? this.options.now ?? Date.now)())) return undefined;
    return config.action;
  }
  get policy() { return this.policyValue; }
  private get riskLevel() { return riskLevel(this.policy.riskProfile); }
  get status(): SessionRuntimeState { return { ...this.statusValue }; }
  get needsIngest() { return !!(this.grant || this.shot); }
  get isAuto() { return this.grant?.mode === 'auto'; }
  get cloudApproved() { return this.grant?.cloudApproved === true; }

  updatePolicy(nextPolicy: ConversationPolicy) {
    const narrowedTrigger = nextPolicy.type === 'group' && this.policy.groupTrigger === 'all' && nextPolicy.groupTrigger === 'mention_only';
    const changedKeywords = JSON.stringify(this.policy.triggerKeywords) !== JSON.stringify(nextPolicy.triggerKeywords) ||
      JSON.stringify(this.policy.ignoreKeywords) !== JSON.stringify(nextPolicy.ignoreKeywords);
    const changedRules = JSON.stringify(this.policy.riskProfile.ruleOverrides) !== JSON.stringify(nextPolicy.riskProfile.ruleOverrides) ||
      JSON.stringify(this.policy.riskProfile.customBlockKeywords) !== JSON.stringify(nextPolicy.riskProfile.customBlockKeywords) ||
      this.policy.riskProfile.customBlockAction !== nextPolicy.riskProfile.customBlockAction;
    const changedLevel = this.riskLevel !== riskLevel(nextPolicy.riskProfile);
    this.policyValue = nextPolicy;
    if (changedLevel || changedRules) this.window = this.window.filter(event => this.keepsContext(event));
    if (changedLevel || narrowedTrigger || changedKeywords || changedRules) {
      // 旧档或旧规则/关键词门禁下已排队/拟好的回合不能继续发送；保留授权、锁和正在解析的媒体。
      const eligible = changedLevel ? [] : this.queue.filter(event => {
        const check = this.engine.inbound(event, nextPolicy, false);
        return check.action === 'allow' || check.action === 'identity' || check.action === 'draft_only';
      });
      const removed = eligible.length !== this.queue.length;
      if (removed) this.invalidate();
      this.queue = eligible;
      const hadDraft = !!this.statusValue.draft;
      this.clearDraft();
      if (hadDraft || (removed && this.grant && ['generating', 'checking'].includes(this.statusValue.phase))) {
        this.show(this.shot ? 'scheduled' : 'listening');
      }
      this.debounce();
    }
    this.options.onTrace?.('state', 'info', '已热更新会话策略');
  }

  resumeCooldown() {
    if (this.statusValue.phase !== 'cooldown' || !this.grant) return;
    const fault = this.ironLaw() ?? this.lastPhaseFault;
    if (fault) { this.pause(fault); throw new BridgeError(fault); }
    this.finishCooldown('listening');
    this.options.onTrace?.('state', 'info', '已手动解除冷静期恢复监听');
  }

  private finishCooldown(phase: 'listening' | 'retrying') {
    clearTimeout(this.cooldown);
    if (!this.grant || this.statusValue.phase !== 'cooldown') return;
    this.replyAfter = this.now();
    this.show(phase);
  }

  private show(phase: SessionRuntimeState['phase'], reason?: ErrorCode, extra: Partial<SessionRuntimeState> = {}) {
    this.statusValue = { phase, replyMode: this.grant?.mode ?? 'off', ...(reason && { reason }),
      ...(this.statusValue.receipt && { receipt: this.statusValue.receipt }),
      ...(this.shot && { scheduledAt: this.shot.at }), ...extra };
    this.options.onStatus?.(this.status);
  }

  private ironLaw() {
    return this.options.journal.optedOut(this.peer) ? 'peer-stopped' : this.options.journal.uncertain(this.peer) ? 'send-unknown' : undefined;
  }

  private invalidate() {
    this.revision++;
    this.generation?.abort();
    clearTimeout(this.timer);
  }

  private clearDraft() {
    clearTimeout(this.draftTimer);
    this.statusValue = { ...this.statusValue, draft: undefined };
  }

  private clearTurn() {
    this.invalidate();
    this.queue = [];
    this.processingRefs.clear();
    this.clearDraft();
  }

  beginDrain(route: string) {
    this.since = this.options.journal.beginDrain(sha(JSON.stringify([route, this.peer])), this.now());
  }

  arm(grant: Grant, waitingForHistory = false) {
    const fault = this.ironLaw() ?? this.lastPhaseFault;
    if (fault) throw new BridgeError(fault);
    this.clearTurn();
    clearTimeout(this.cooldown);
    this.grant = grant;
    this.replyAfter = this.now();
    this.armed = true;
    this.backfillToken = waitingForHistory ? Symbol() : undefined;
    this.show(this.synced ? 'listening' : 'connecting');
    this.options.onTrace?.('state', 'info', grant.mode === 'auto' ? '已开启自动回复' : '已开启草稿回复');
    return this.backfillToken;
  }

  finishArm(token: symbol, history: NormalizedEvent[]) {
    if (this.backfillToken !== token) return;
    this.backfillToken = undefined;
    for (const event of history) if (event.origin === 'backfill') this.remember(event);
    this.debounce();
  }

  pause(reason: ErrorCode = 'user-paused') {
    const iron = this.ironLaw();
    if (iron) reason = iron;
    this.clearTurn();
    clearTimeout(this.cooldown);
    this.cancelShot(reason);
    this.grant = undefined;
    this.backfillToken = undefined;
    this.armed = false;
    this.window = [];
    this.show(reason === 'peer-stopped' ? 'locked-opt-out' : reason === 'send-unknown' ? 'blocked-unknown' : 'paused', reason);
    this.options.onTrace?.('state', 'warn', `会话已暂停：${traceReasons[reason] ?? reason}`, reason);
  }

  pauseSending(reason: ErrorCode) {
    if (this.grant?.mode === 'draft') {
      this.cancelShot(reason);
      return;
    }
    if (this.needsIngest) this.pause(reason);
  }

  recover() {
    this.lastPhaseFault = undefined;
    this.pause(this.ironLaw() ?? 'user-paused');
    if (!this.ironLaw()) this.show('idle');
  }

  ingestState(state: 'listening' | 'retrying' | 'fault', reason?: ErrorCode) {
    this.synced = state === 'listening';
    if (state === 'fault') {
      this.lastPhaseFault = reason;
      this.pause(reason);
    } else if (state === 'retrying' && this.needsIngest) {
      this.clearTurn();
      this.replyAfter = this.now();
      if (this.shot) this.cancelShot(reason ?? 'mcp-offline');
      if (this.grant && this.statusValue.phase !== 'cooldown') this.show('retrying', reason);
      else if (!this.grant) this.show('paused', reason);
    } else if (this.synced && this.needsIngest) {
      if (['connecting', 'retrying', 'idle'].includes(this.statusValue.phase)) this.show(this.shot ? 'scheduled' : 'listening');
      this.debounce();
      if (this.shot && this.shot.at <= this.now()) this.launchShot(this.shot);
    }
  }

  private keepsContext(event: NormalizedEvent) {
    const level = this.riskLevel;
    const risk = this.engine.resolveRisk(event.text, this.policy.riskProfile);
    return risk.kind === 'none' || (level === 'legacy' && risk.kind === 'manual');
  }

  private remember(event: NormalizedEvent) {
    if (!event.text || !['text', 'voice', 'image'].includes(event.kind) || !this.keepsContext(event)) return;
    const index = this.window.findIndex(old => old.messageRef === event.messageRef);
    if (index < 0) this.window.push(event);
    else if (event.origin === 'live') this.window[index] = event;
    this.trimWindow();
  }

  private formatForModel(event: NormalizedEvent) {
    return this.policy.type === 'group' && !event.isSelf && event.senderLabel
      ? `${event.senderLabel}: ${event.text}` : event.text;
  }

  private trimWindow() {
    this.expireContext();
    this.window = this.window.sort((a, b) => a.createdAt - b.createdAt).slice(-(this.options.workingMaxMessages ?? 16));
  }

  context(): NormalizedEvent[] { this.trimWindow(); return structuredClone(this.window); }

  expireContext() {
    const min = this.now() - (this.options.workingTtlMs ?? 30 * 60_000);
    this.window = this.window.filter(event => event.createdAt >= min);
  }

  private inScope(event: NormalizedEvent) {
    return event.accountId === this.options.accountId && event.conversationId === this.policy.conversationId;
  }

  recall(messageRef: string) {
    const before = this.window.length;
    this.window = this.window.filter(event => event.messageRef !== messageRef);
    const length = this.queue.length;
    this.queue = this.queue.filter(event => event.messageRef !== messageRef);
    const pending = this.processingRefs.delete(messageRef);
    if (before !== this.window.length || length !== this.queue.length || pending) {
      this.invalidate();
      this.clearDraft();
      this.debounce();
    }
  }

  observe({ event, identity, unavailableBody }: EventInput): boolean {
    if (!this.inScope(event) || event.origin !== 'live') return false;
    if (event.kind === 'recall') {
      if (event.recallTargetRef) this.recall(event.recallTargetRef);
      return false;
    }
    const now = this.now();
    const cutoff = Math.floor((this.since ?? now) / 1000) * 1000;
    if (event.observedAt < cutoff && event.createdAt < cutoff) return false;
    const own = event.isSelf && this.options.journal.own(this.peer, identity, event.clientRequestId, event.messageRef);
    const media = event.kind === 'image' || event.kind === 'voice';
    const current = Math.min(event.createdAt, event.observedAt) >= Math.floor(this.replyAfter / 1000) * 1000 &&
      Math.min(event.createdAt, event.observedAt) > this.replyAfter && now - Math.min(event.createdAt, event.observedAt) <= MAX_AGE;
    const outcome = this.engine.inbound(event, this.policy, own, media);
    if (outcome.action === 'lock_peer') { this.apply(outcome); return false; }
    if (unavailableBody && this.needsIngest && (!event.isSelf || this.policy.riskProfile.takeoverAction !== 'ignore')) {
      this.apply(manualReview('pause_session', { source: 'unavailable-body' }));
      return false;
    }
    if (event.isSelf) {
      if (!own && this.needsIngest && this.policy.riskProfile.takeoverAction === 'ignore') {
        this.options.onTrace?.('policy', 'info', '按策略忽略本人插话');
      }
      if (!own && this.needsIngest && outcome.action === 'cooldown_or_pause') {
        const writing = this.options.transmitter.settled(event.conversationId);
        if (!writing) this.apply(outcome);
        else {
          this.invalidate();
          this.processingRefs.add(event.messageRef);
          const revision = this.revision;
          void writing.then(() => {
            if (revision === this.revision || this.processingRefs.has(event.messageRef)) {
              this.processingRefs.delete(event.messageRef);
              const current = this.engine.inbound(event, this.policy, false);
              if (current.action === 'cooldown_or_pause' && this.needsIngest &&
                !this.options.journal.own(this.peer, identity, event.clientRequestId, event.messageRef)) this.apply(current);
              else this.debounce();
            }
          }).catch(() => {});
        }
      }
      if (this.grant) this.remember(event);
      return false;
    }
    if (!current && !this.shot) return false;
    const isCrisisHit = outcome.review?.source === 'inbound' && outcome.review.rule === 'crisis';
    if (isCrisisHit && outcome.action === 'pause_session' && (this.needsIngest || this.armed)) {
      this.apply(outcome);
      return false;
    }
    if (this.grant && this.statusValue.phase !== 'cooldown' && !isCrisisHit && this.activeQuietHoursAction() === 'skip_turn') {
      this.options.onTrace?.('policy', 'info', '命中勿扰时段，已跳过本轮');
      return false;
    }
    if (outcome.action === 'pause_session' && (this.needsIngest || this.armed)) { this.apply(outcome); return false; }
    if (!this.grant) return false;
    if (this.statusValue.phase === 'cooldown') {
      const seconds = Math.max(0, Math.ceil(((this.statusValue.cooldownUntil ?? now) - now) / 1000));
      this.options.onTrace?.('policy', 'info', `冷静期中跳过（剩余 ${seconds}s）`);
      return false;
    }
    if (media && (outcome.action === 'allow' || outcome.action === 'identity' || outcome.action === 'draft_only')) {
      this.invalidate();
      this.processingRefs.add(event.messageRef);
      return true;
    }
    this.enqueueForReply(event);
    return false;
  }

  completeMedia(input: EventInput) {
    const { event } = input;
    if (!this.processingRefs.delete(event.messageRef) || this.options.journal.isRecalled(input.route, eventRefHash(input))) return;
    this.enqueueForReply(event);
    this.debounce();
  }

  enqueueForReply(event: NormalizedEvent) {
    if (event.origin !== 'live' || !this.inScope(event) || event.isSelf || !this.grant ||
        this.statusValue.phase === 'cooldown') return;
    const outcome = this.engine.inbound(event, this.policy, false);
    if (outcome.action === 'skip_turn') {
      if (outcome.reason) this.apply(outcome);
      else if (outcome.keywordGate === 'ignored') {
        this.options.onTrace?.('policy', 'info', '命中忽略词，已跳过本轮');
      } else if (outcome.keywordGate === 'trigger-missed') {
        this.options.onTrace?.('policy', 'info', '未命中触发白名单词，已跳过本轮');
      } else if (outcome.keywordGate === 'group-unmentioned') {
        this.options.onTrace?.('policy', 'info', this.policy.triggerKeywords.length > 0
          ? '仅被 @ 或命中触发词时触发，已跳过本轮' : '仅被 @ 时触发，未提及本人');
      }
      return;
    }
    if (outcome.action !== 'allow' && outcome.action !== 'identity' && outcome.action !== 'draft_only') { this.apply(outcome); return; }
    this.remember(event);
    this.invalidate();
    this.clearDraft();
    const now = this.now();
    if (!this.queue.length) {
      this.firstEnqueuedAfterGap = now - (this.lastEnqueuedAt ?? -Infinity) > 1200;
      this.firstEnqueuedPerfMs = performance.now();
    }
    this.lastEnqueuedAt = now;
    this.queue.push(event);
    if (this.queue.length > 8) this.apply(this.engine.busy(this.policy));
    else this.debounce();
  }

  private apply(outcome: PolicyDecision) {
    const effect = outcome.action === 'pause_session' ? '暂停会话' : '跳过本轮';
    if (outcome.review) this.options.onTrace?.('policy', 'warn', `${reviewDescription(outcome.review)} → ${effect}`, outcome.reason);
    if (outcome.reason === 'busy-chat') this.options.onTrace?.('policy', 'warn', `消息过于密集 → ${effect}`, outcome.reason);
    if (outcome.action === 'lock_peer') {
      this.options.onTrace?.('policy', 'warn', '命中叫停 → 锁定会话', outcome.reason);
      this.options.journal.optOut(this.peer, this.now());
      this.pause('peer-stopped');
    } else if (outcome.action === 'pause_session') this.pause(outcome.reason);
    else if (outcome.action === 'skip_turn') {
      this.clearTurn();
      if (this.grant) this.show(this.shot ? 'scheduled' : 'listening', outcome.reason);
    } else if (outcome.action === 'cooldown_or_pause') {
      if (!this.grant || this.policy.riskProfile.takeoverAction === 'pause_session') { this.pause('manual-takeover'); return; }
      this.clearTurn();
      this.cancelShot('manual-takeover');
      clearTimeout(this.cooldown);
      const until = this.now() + this.policy.riskProfile.takeoverCooldownMinutes * 60_000;
      this.show('cooldown', 'manual-takeover', { cooldownUntil: until });
      this.options.onTrace?.('policy', 'warn', '本人插话进入冷静期', 'manual-takeover');
      this.cooldown = setTimeout(() => {
        this.finishCooldown(this.synced ? 'listening' : 'retrying');
        this.options.onTrace?.('state', 'info', '冷静期结束，已恢复会话监听');
      }, Math.max(0, until - this.now()));
    }
  }

  private debounce() {
    if (!this.grant || !this.synced || !this.queue.length || this.processingRefs.size || this.backfillToken ||
        this.statusValue.phase === 'cooldown' || this.generation || this.shot?.at !== undefined && this.shot.at <= this.now()) return;
    clearTimeout(this.timer);
    const text = this.queue[0]!.text.trim();
    const fast = this.queue.length === 1 && (/[?？!！。~～]$/.test(text) || (text.length >= 4 && this.firstEnqueuedAfterGap));
    const wait = Math.max(0, Math.min(this.options.debounceMs ?? (fast ? 260 : 620),
      this.queue[0]!.seenAt + (this.options.batchMaxMs ?? 1350) - this.now()));
    this.timer = setTimeout(() => { void this.respond().catch(error => this.pause(errorCode(error))); }, wait);
    if (this.prewarmedRevision !== this.revision) {
      this.prewarmedRevision = this.revision;
      this.options.prewarm?.(this.grant);
    }
  }

  private valid(revision: number) {
    if (revision !== this.revision || !this.synced || this.processingRefs.size) throw new BridgeError('turn-obsolete');
  }

  private async respond() {
    const grant = this.grant;
    if (!grant || this.generation || this.backfillToken || !this.synced || this.processingRefs.size || this.statusValue.phase === 'cooldown') return;
    const why = this.ironLaw();
    if (why) { this.pause(why); return; }
    const now = this.now();
    this.queue = this.queue.filter(event => now - Math.min(event.createdAt, event.observedAt) <= MAX_AGE);
    const turn = this.queue.slice().sort((a, b) => a.createdAt - b.createdAt);
    if (!turn.length) { this.show(this.shot ? 'scheduled' : 'listening'); return; }
    if (turn.length > 4) { this.apply(this.engine.busy(this.policy)); return; }
    if (this.activeQuietHoursAction() === 'skip_turn') {
      this.queue = [];
      this.options.onTrace?.('policy', 'info', '命中勿扰时段，已跳过本轮');
      this.show(this.shot ? 'scheduled' : 'listening');
      return;
    }
    const revision = this.revision;
    const respondStartedPerfMs = performance.now();
    const earliest = turn[0]!;
    const ingestMs = Math.max(0, Math.min(MAX_AGE, earliest.seenAt - earliest.createdAt));
    const debounceMs = this.firstEnqueuedPerfMs !== undefined
      ? Math.max(0, Math.round(respondStartedPerfMs - this.firstEnqueuedPerfMs))
      : Math.max(0, now - earliest.seenAt);
    let modelTiming: ChatTurnTiming | undefined;
    let sendTiming: { fenceMs: number; wireMs: number } | undefined;
    const emitMetric = (outcome: TurnPerfSample['outcome'], errorCodeValue?: ErrorCode) => {
      if (!this.options.onMetric) return;
      const promptMs = modelTiming?.promptMs ?? 0;
      const modelTtftMs = modelTiming?.ttftMs ?? 0;
      const modelTotalMs = modelTiming?.modelTotalMs ?? 0;
      const fenceMs = sendTiming?.fenceMs ?? 0;
      const sendWireMs = sendTiming?.wireMs ?? 0;
      const activeMs = Math.max(0, Math.round(performance.now() - respondStartedPerfMs));
      const totalMs = Math.max(ingestMs + debounceMs + activeMs, ingestMs + debounceMs + promptMs + modelTotalMs + fenceMs + sendWireMs);
      const sample: TurnPerfSample = {
        id: randomUUID(),
        conversationId: this.policy.conversationId,
        at: this.now(),
        outcome,
        ingestMs,
        debounceMs,
        promptMs,
        promptCacheHit: modelTiming?.promptCacheHit ?? false,
        modelTtftMs,
        modelTotalMs,
        fenceMs,
        sendWireMs,
        totalMs,
        bottleneck: classifyTurnBottleneck({ ingestMs, debounceMs, promptMs, modelTtftMs, modelTotalMs, fenceMs, sendWireMs }),
        ...(modelTiming && { modelMode: modelTiming.modelMode, effort: modelTiming.effort }),
        fallbackUsed: modelTiming?.fallbackUsed ?? false,
        ...(errorCodeValue && { errorCode: errorCodeValue }),
      };
      try { this.options.onMetric(sample); } catch { /* 性能指标采集绝不干扰主流程 */ }
    };
    const controller = this.generation = new AbortController();
    const check = () => {
      this.valid(revision);
      if (this.grant !== grant || this.now() - Math.min(...turn.map(e => Math.min(e.createdAt, e.observedAt))) > Math.max(MAX_AGE, 120_000)) {
        throw new BridgeError('turn-obsolete');
      }
    };
    let sending = false;
    try {
      this.show('generating');
      const refs = new Set(turn.map(event => event.messageRef));
      const context = this.context().filter(event => !refs.has(event.messageRef)).map((event): Context =>
        ({ from: event.isSelf ? 'auto' : 'peer', text: this.formatForModel(event) }));
      const identity = turn.some(event => this.engine.resolveRisk(event.text, this.policy.riskProfile).kind === 'identity');
      const ruleDraftHit = turn.map(event => this.engine.inbound(event, this.policy, false)).find(d => d.action === 'draft_only');
      if (identity) this.options.onTrace?.('policy', 'info', '命中身份询问，使用固定说明');
      const decision = identity ? { action: 'identity' as const } :
        await this.options.generate(turn.map(event => this.formatForModel(event)), context, grant, controller.signal, value => {
          modelTiming = value;
        });
      check();
      if (decision.action === 'identity' && !identity) this.options.onTrace?.('policy', 'info', '模型判定为身份询问，使用固定说明');
      const outcome = this.engine.outbound(decision, this.riskLevel);
      if (!outcome.text) {
        emitMetric('skipped', outcome.reason);
        this.apply(outcome);
        return;
      }
      const quietAction = this.activeQuietHoursAction();
      if (quietAction === 'skip_turn') {
        this.queue = [];
        emitMetric('skipped');
        this.options.onTrace?.('policy', 'info', '命中勿扰时段，已跳过本轮');
        this.show(this.shot ? 'scheduled' : 'listening');
        return;
      }
      if (grant.mode === 'draft' || quietAction === 'draft_only' || ruleDraftHit) {
        if (grant.mode === 'auto' && ruleDraftHit?.review) {
          this.options.onTrace?.('policy', 'warn', `${reviewDescription(ruleDraftHit.review)} → 降级为只拟稿`, 'manual-review');
        } else if (grant.mode === 'auto' && quietAction === 'draft_only') {
          this.options.onTrace?.('policy', 'info', '命中勿扰时段，已降级为只拟稿');
        }
        this.queue = [];
        emitMetric('draft');
        this.show(this.shot ? 'scheduled' : 'listening', 'draft-ready', { draft: outcome.text });
        this.draftTimer = setTimeout(() => {
          if (this.statusValue.draft) this.show(this.statusValue.phase);
        }, MAX_AGE);
        return;
      }
      sending = true;
      const fence = this.options.fence();
      const { messageRef, mentionUserIds } = this.replyTarget(turn);
      this.show('checking');
      const receipt = await this.options.transmitter.send({ sourceKind: 'auto', conversationId: this.policy.conversationId,
        text: outcome.text, attemptId: this.options.transmitter.autoAttempt(this.peer, [...refs]),
        ...(messageRef && { messageRef }), ...(mentionUserIds && { mentionUserIds }),
        expectedIdentity: fence.identity, fenceCursor: fence, originGuard: 'live_or_human', origin: 'live', checkStillValid: check,
        onTiming: timing => { sendTiming = timing; },
        onWire: () => {
          this.options.onTrace?.('send', 'info', '正在提交微信发信');
          if (this.revision === revision) this.show('sending');
        } });
      this.setReceipt(receipt);
      this.traceReceipt(receipt);
      emitMetric(decision.action === 'identity' ? 'identity' : 'sent');
      this.queue = this.queue.filter(event => !refs.has(event.messageRef));
      if (this.grant && this.status.phase !== 'cooldown') this.show(this.shot ? 'scheduled' : 'listening');
    } catch (error) {
      const why = errorCode(error);
      if (why !== 'turn-obsolete' && why !== 'stopped') emitMetric('failed', why);
      if (sending) this.traceSendFault(why);
      if (why === 'send-unknown' || why === 'peer-stopped') this.pause(why);
      else if (revision === this.revision && this.grant) {
        if (['send-fence', 'turn-obsolete', 'duplicate-attempt'].includes(why)) this.apply({ action: 'skip_turn' });
        else if (this.riskLevel !== 'strict' &&
          ['model-timeout', 'model-format', 'model-unavailable', 'model-limit'].includes(why)) {
          // 瞬时模型抖动跳过本轮并展示原因，不直接关闭整个会话的自动回复开关。
          this.clearTurn();
          this.show(this.shot ? 'scheduled' : 'listening', why);
        } else this.pause(why);
      }
    } finally {
      if (this.generation === controller) this.generation = undefined;
      this.debounce();
    }
  }

  /** 依据会话开关与小禾能力决定是否原生引用回复、是否 @ 本轮发言人；能力缺失时降级为普通发信。 */
  private replyTarget(turn: readonly NormalizedEvent[]) {
    const caps = this.options.capabilities?.() ?? { nativeReply: false, mentionSend: false };
    const latest = turn.at(-1);
    const messageRef = this.policy.useNativeReply && caps.nativeReply && latest && id(latest.messageRef) ? latest.messageRef : undefined;
    let mentionUserIds: string[] | undefined;
    if (this.policy.type === 'group' && this.policy.mentionReplySender && caps.mentionSend) {
      const senders = [...new Set(turn.filter(event => !event.isSelf && id(event.senderId)).map(event => event.senderId))].slice(0, 50);
      if (senders.length) mentionUserIds = senders;
    }
    return { messageRef, mentionUserIds };
  }

  schedule(text: string, request: string, scheduledAt?: number) {
    const now = this.now();
    const at = scheduledAt ?? now;
    if (at < now || at >= tomorrow(now)) throw new BridgeError('invalid-expiry');
    if (this.shot) throw new BridgeError('busy');
    const why = this.ironLaw() ?? this.lastPhaseFault;
    if (why) throw new BridgeError(why);
    if (this.statusValue.phase === 'cooldown') throw new BridgeError('manual-takeover');
    const id = this.shotAttempt(request);
    if (this.options.journal.get(id)) throw new BridgeError('duplicate-attempt');
    const deadline = Math.min(tomorrow(now), at + 12_000);
    const shot: Shot = this.shot = { text, request, at, deadline };
    shot.timer = setTimeout(() => this.launchShot(shot), Math.max(0, at - now));
    this.show(this.synced ? 'scheduled' : 'connecting');
  }

  private shotAttempt(request: string) { return `wmb-${sha(`${this.peer}:${request}`)}`; }

  private launchShot(shot: Shot) {
    if (this.shot !== shot || !shot.timer) return;
    clearTimeout(shot.timer);
    if (!this.synced && this.now() < shot.deadline) {
      shot.timer = setTimeout(() => this.launchShot(shot), Math.min(200, shot.deadline - this.now()));
      return;
    }
    shot.timer = undefined;
    void this.sendShot(shot);
  }

  private cancelShot(reason: ErrorCode) {
    if (!this.shot) return;
    clearTimeout(this.shot.timer);
    this.shot = undefined;
    this.options.onScheduleCancelled?.(reason);
  }

  private async sendShot(shot: Shot) {
    this.invalidate();
    const revision = this.revision;
    const check = () => {
      if (this.shot !== shot) throw new BridgeError('stopped');
      if (this.now() >= shot.deadline) throw new BridgeError('expired');
      this.valid(revision);
    };
    try {
      check();
      const fence = this.options.fence();
      this.show('checking');
      const receipt = await this.options.transmitter.send({ sourceKind: 'active', conversationId: this.policy.conversationId,
        text: shot.text, attemptId: this.shotAttempt(shot.request), expectedIdentity: fence.identity, fenceCursor: fence,
        checkStillValid: check, originGuard: 'live_or_human', origin: 'human',
        onWire: () => {
          this.options.onTrace?.('send', 'info', '正在提交微信发信');
          if (this.shot === shot) this.show('sending');
        } });
      this.setReceipt(receipt);
      this.traceReceipt(receipt);
      if (this.shot !== shot) return;
      this.shot = undefined;
      this.show(this.grant ? 'listening' : 'idle', 'one-shot-complete');
    } catch (error) {
      const why = errorCode(error);
      this.traceSendFault(why);
      if (why === 'send-unknown' || why === 'peer-stopped') this.pause(why);
      else if (this.shot === shot) {
        this.cancelShot(why);
        this.show(this.grant ? 'listening' : 'paused', why);
      }
    } finally { this.debounce(); }
  }

  private traceSendFault(code: ErrorCode) {
    const summary = code === 'send-unknown' ? '发信结果未知，请在微信核对' : `发送未完成：${traceReasons[code] ?? code}`;
    this.options.onTrace?.('send', 'warn', summary, code);
  }

  private traceReceipt(receipt: Receipt) {
    const status = receipt.delivery === 'delivered' ? 'delivered' : receipt.status;
    if (status === 'delivered' || status === 'submitted') {
      this.options.onTrace?.('send', 'info', `微信发信已提交（${status}）`);
    } else this.options.onTrace?.('send', 'warn', `微信发信结果（${status}）`);
  }

  setReceipt(receipt: Receipt) {
    this.statusValue.receipt = { status: receipt.status, delivery: receipt.delivery,
      ...(receipt.operation && { operationId: receipt.operation }) };
  }

  updateReceipt(receipt: Receipt) {
    this.setReceipt(receipt);
    this.options.onStatus?.(this.status);
  }
}
