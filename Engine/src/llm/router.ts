import { BridgeError, checked } from '../../contracts.ts';
import type { Context, Decision } from '../../model.ts';
import { errorCode } from '../contracts/errors.ts';
import { modelPresetSchema, type ModelPreset } from '../contracts/settings.ts';
import type { MediaBlock } from '../mcp/client.ts';
import { CHAT_TIMEOUT_MS, ModelClient } from './client.ts';
import type { ModelTiming, ModelTrace } from './request.ts';
import { untilAborted, type TokenUsage } from './sse.ts';

export function estimateTokenCostUsd(preset: Pick<ModelPreset, 'mode' | 'inputPricePerMillion' | 'cachedInputPricePerMillion' | 'outputPricePerMillion'> | undefined,
  usage: TokenUsage | undefined): number {
  if (!preset || preset.mode === 'local' || !usage) return 0;
  const inputRate = preset.inputPricePerMillion ?? 0;
  const cachedRate = preset.cachedInputPricePerMillion ?? inputRate;
  const outputRate = preset.outputPricePerMillion ?? 0;
  if (inputRate <= 0 && cachedRate <= 0 && outputRate <= 0) return 0;
  const uncachedPrompt = Math.max(0, usage.promptTokens - usage.cachedTokens);
  const raw = (uncachedPrompt * inputRate + usage.cachedTokens * cachedRate + usage.completionTokens * outputRate) / 1_000_000;
  return Math.round(Math.max(0, raw) * 1_000_000) / 1_000_000;
}

type Priority = 'reply' | 'background';
export type ModelRequest = {
  priority?: Priority; signal?: AbortSignal; cloudApproved?: boolean; apiKey?: string; style?: string; memory?: string;
};
export type ChatTurnTiming = {
  promptMs: number;
  promptCacheHit: boolean;
  ttftMs: number;
  modelTotalMs: number;
  modelMode: 'local' | 'cloud';
  effort: ModelTiming['effort'];
  fallbackUsed: boolean;
  presetId?: string;
  modelName?: string;
  promptTokens: number;
  cachedTokens: number;
  completionTokens: number;
  estimatedCostUsd: number;
};
type ChatRequest = ModelRequest & {
  fallbackPresetId?: string; fallbackCloudApproved?: boolean; onTrace?: ModelTrace;
  fastReplyMode?: boolean; includeEmptyContext?: boolean;
  profileForMode?: (mode: ModelPreset['mode']) => Promise<{ style?: string; memory?: string; cacheHit?: boolean; promptMs?: number }>;
  onTurnTiming?: (timing: ChatTurnTiming) => void;
};
type Ticket = { priority: Priority; start: () => void };
export type KeyProvider = (preset: ModelPreset) => string | undefined | Promise<string | undefined>;

export function supportsModelKind(presetKind: ModelPreset['kind'] | undefined, kind: ModelPreset['kind']) {
  return presetKind === kind || (kind === 'vision' && presetKind === 'chat');
}

export class ModelRouter {
  private presets = new Map<string, ModelPreset>();
  private reasoningEffortDisabled = new Set<string>();
  private active = 0;
  private background = 0;
  private readonly queue: Ticket[] = [];
  private concurrency = 3;

  constructor(presets: readonly ModelPreset[] = [], private readonly getKey?: KeyProvider, maxConcurrent = 3) {
    this.configure(presets, maxConcurrent);
  }

  configure(presets: readonly ModelPreset[], maxConcurrent = this.concurrency) {
    if (!Number.isSafeInteger(maxConcurrent) || maxConcurrent < 1) throw new BridgeError('invalid-configuration');
    const entries = presets.map(preset => checked(modelPresetSchema, preset));
    const next = new Map(entries.map(preset => {
      const previous = this.presets.get(preset.id);
      return [preset.id, previous && JSON.stringify(previous) === JSON.stringify(preset) ? previous : preset] as const;
    }));
    if (next.size !== entries.length) throw new BridgeError('invalid-configuration');
    this.presets = next;
    this.concurrency = maxConcurrent;
    this.drain();
  }

  get inFlight() { return this.active; }

  setReasoningEffortDisabled(endpoints: readonly string[]) {
    this.reasoningEffortDisabled = new Set(endpoints);
  }

  run<T>(priority: Priority, task: () => Promise<T>, signal?: AbortSignal): Promise<T> {
    if (signal?.aborted) return Promise.reject(new BridgeError('stopped'));
    return new Promise<T>((resolve, reject) => {
      const abort = () => {
        const index = this.queue.indexOf(ticket);
        if (index >= 0) this.queue.splice(index, 1);
        reject(new BridgeError('stopped'));
      };
      const ticket: Ticket = { priority, start: () => {
        signal?.removeEventListener('abort', abort);
        this.active++;
        if (priority === 'background') this.background++;
        void Promise.resolve().then(() => {
          if (signal?.aborted) throw new BridgeError('stopped');
          return task();
        }).then(resolve, reject).finally(() => {
          this.active--;
          if (priority === 'background') this.background--;
          this.drain();
        });
      } };
      this.queue.push(ticket);
      signal?.addEventListener('abort', abort, { once: true });
      this.drain();
    });
  }

  private drain() {
    while (this.active < this.concurrency) {
      let index = this.queue.findIndex(ticket => ticket.priority === 'reply');
      // 单槽配置允许后台任务运行，释放时优先唤醒回复任务。
      if (index < 0 && this.background < Math.max(1, this.concurrency - 1)) index = 0;
      if (index < 0 || !this.queue.length) return;
      this.queue.splice(index, 1)[0]!.start();
    }
  }

  private async client(preset: ModelPreset | undefined, kind: ModelPreset['kind'], options: ModelRequest) {
    if (!preset || !supportsModelKind(preset.kind, kind)) throw new BridgeError('invalid-configuration');
    if (preset.mode === 'cloud' && !options.cloudApproved) throw new BridgeError('cloud-not-approved');
    const key = preset.mode === 'cloud' ? options.apiKey ??
      await untilAborted(Promise.resolve(this.getKey?.(preset)), options.signal) : options.apiKey;
    return new ModelClient(preset, key, this.reasoningEffortDisabled.has(preset.url));
  }

  async checkChatCredentials(id: string, cloudApproved: boolean, signal?: AbortSignal) {
    await this.client(this.presets.get(id), 'chat', { cloudApproved, signal });
  }

  private model<T>(preset: ModelPreset | undefined, kind: ModelPreset['kind'], options: ModelRequest, task: (client: ModelClient) => Promise<T>) {
    if (!preset || !supportsModelKind(preset.kind, kind)) return Promise.reject(new BridgeError('invalid-configuration'));
    if (preset.mode === 'cloud' && !options.cloudApproved) return Promise.reject(new BridgeError('cloud-not-approved'));
    return this.run(options.priority ?? 'background', async () => {
      const client = await this.client(preset, kind, options);
      if (options.signal?.aborted) throw new BridgeError('stopped');
      return task(client);
    }, options.signal);
  }

  async chat(id: string, turn: readonly string[], context: readonly Context[], options: ChatRequest = {}) {
    const { fallbackPresetId, fallbackCloudApproved, onTrace, profileForMode, onTurnTiming, signal } = options;
    const started = performance.now();
    let timing: ModelTiming | undefined;
    let promptMs = 0;
    let promptCacheHit = false;
    let activeMode: 'local' | 'cloud' = this.presets.get(id)?.mode ?? 'local';
    let activePreset: ModelPreset | undefined = this.presets.get(id);
    let fallbackUsed = false;
    const primary = this.presets.get(id);
    const fallback = fallbackPresetId && this.presets.get(fallbackPresetId);
    const eligible = fallback && fallback.id !== id && fallback.kind === 'chat' && (fallback.mode === 'local' || fallbackCloudApproved)
      ? fallback : undefined;
    const buildTurnTiming = (): ChatTurnTiming => ({
      promptMs,
      promptCacheHit,
      ttftMs: timing?.firstByteMs ?? 0,
      modelTotalMs: timing?.totalMs ?? Math.max(0, Math.round(performance.now() - started) - promptMs),
      modelMode: activeMode,
      effort: timing?.effort ?? 'default',
      fallbackUsed,
      ...(activePreset && { presetId: activePreset.id, modelName: activePreset.modelName }),
      promptTokens: timing?.usage?.promptTokens ?? 0,
      cachedTokens: timing?.usage?.cachedTokens ?? 0,
      completionTokens: timing?.usage?.completionTokens ?? 0,
      estimatedCostUsd: estimateTokenCostUsd(activePreset, timing?.usage),
    });
    const execute = async (preset: ModelPreset | undefined, request: ModelRequest, budget: number) => {
      const timeoutMs = Math.floor(started + budget - performance.now());
      if (timeoutMs <= 0) throw new BridgeError('model-timeout');
      const deadline = AbortSignal.timeout(timeoutMs);
      const attemptSignal = signal ? AbortSignal.any([signal, deadline]) : deadline;
      try {
        return await this.model(preset, 'chat', { priority: 'reply', ...request, signal: attemptSignal }, async client => {
          const mode = client.mode;
          activeMode = mode;
          activePreset = preset;
          const promptStarted = performance.now();
          const profile = profileForMode ? await untilAborted(profileForMode(mode), attemptSignal) :
            (preset === primary || primary?.mode === mode ? { style: request.style, memory: request.memory } : undefined);
          promptMs = profile?.promptMs ?? Math.max(0, Math.round(performance.now() - promptStarted));
          promptCacheHit = profile?.cacheHit === true;
          const remaining = Math.max(1, Math.floor(started + budget - performance.now()));
          return client.chat(turn, mode === 'cloud' ? context.slice(-12) : context, attemptSignal, profile, remaining, onTrace, {
            fastReplyMode: options.fastReplyMode, includeEmptyContext: options.includeEmptyContext,
            onTiming: value => { timing = value; },
          });
        });
      } catch (error) {
        if (signal?.aborted) throw new BridgeError('stopped');
        if (deadline.aborted) throw new BridgeError('model-timeout');
        throw error;
      }
    };
    try {
      let decision: Decision;
      // 备用预设可用时，为它保留部分聊天总预算。
      try { decision = await execute(primary, options, eligible ? 60_000 : CHAT_TIMEOUT_MS); }
      catch (error) {
        const code = errorCode(error);
        if (signal?.aborted || !eligible || this.presets.get(eligible.id) !== eligible ||
          !['model-timeout', 'model-unavailable', 'model-limit', 'model-format'].includes(code)) throw error;
        fallbackUsed = true;
        onTrace?.('warn', '主模型异常，已切换备用模型', code);
        decision = await execute(eligible, { ...options, apiKey: undefined, cloudApproved: fallbackCloudApproved }, CHAT_TIMEOUT_MS);
      }
      const labels = { reply: '回复', skip: '跳过', manual: '转人工', stop: '停止回复', identity: '说明身份' };
      if (timing) onTrace?.('info', `模型决策：${labels[decision.action]}（首包 ${timing.firstByteMs}ms / 共 ${timing.totalMs}ms · effort=${timing.effort}）`);
      onTurnTiming?.(buildTurnTiming());
      return decision;
    } catch (error) {
      if (!signal?.aborted) {
        onTrace?.('error', '模型调用失败', errorCode(error));
        onTurnTiming?.(buildTurnTiming());
      }
      throw error;
    }
  }

  summarize(id: string, instruction: string, data: string, options: ModelRequest = {}) {
    return this.model(this.presets.get(id), 'chat', options, client => client.summarize([{ role: 'system', content: instruction },
      { role: 'user', content: data }], options.signal));
  }

  vision(id: string, images: readonly MediaBlock[], options: ModelRequest = {}) {
    return this.model(this.presets.get(id), 'vision', options, client => client.vision(images, options.signal));
  }

  stt(id: string, audio: MediaBlock, options: ModelRequest = {}) {
    return this.model(this.presets.get(id), 'stt', options, client => client.stt(audio, options.signal));
  }
}
