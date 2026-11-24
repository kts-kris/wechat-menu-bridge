import { BridgeError, checked } from '../../contracts.ts';
import type { Context, Decision } from '../../model.ts';
import { errorCode } from '../contracts/errors.ts';
import { modelPresetSchema, type ModelPreset } from '../contracts/settings.ts';
import type { MediaBlock } from '../mcp/client.ts';
import { CHAT_TIMEOUT_MS, ModelClient } from './client.ts';
import type { ModelTiming, ModelTrace } from './request.ts';
import { untilAborted } from './sse.ts';

type Priority = 'reply' | 'background';
export type ModelRequest = {
  priority?: Priority; signal?: AbortSignal; cloudApproved?: boolean; apiKey?: string; style?: string; memory?: string;
};
type ChatRequest = ModelRequest & {
  fallbackPresetId?: string; fallbackCloudApproved?: boolean; onTrace?: ModelTrace;
  fastReplyMode?: boolean; includeEmptyContext?: boolean;
  profileForMode?: (mode: ModelPreset['mode']) => Promise<{ style?: string; memory?: string }>;
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
    const { fallbackPresetId, fallbackCloudApproved, onTrace, profileForMode, signal } = options;
    const started = performance.now();
    let timing: ModelTiming | undefined;
    const primary = this.presets.get(id);
    const fallback = fallbackPresetId && this.presets.get(fallbackPresetId);
    const eligible = fallback && fallback.id !== id && fallback.kind === 'chat' && (fallback.mode === 'local' || fallbackCloudApproved)
      ? fallback : undefined;
    const execute = async (preset: ModelPreset | undefined, request: ModelRequest, budget: number) => {
      const timeoutMs = Math.floor(started + budget - performance.now());
      if (timeoutMs <= 0) throw new BridgeError('model-timeout');
      const deadline = AbortSignal.timeout(timeoutMs);
      const attemptSignal = signal ? AbortSignal.any([signal, deadline]) : deadline;
      try {
        return await this.model(preset, 'chat', { priority: 'reply', ...request, signal: attemptSignal }, async client => {
          const mode = client.mode;
          const profile = profileForMode ? await untilAborted(profileForMode(mode), attemptSignal) :
            (preset === primary || primary?.mode === mode ? { style: request.style, memory: request.memory } : undefined);
          const remaining = Math.max(1, Math.floor(started + budget - performance.now()));
          return client.chat(turn, mode === 'cloud' ? context.slice(-12) : context, attemptSignal, profile, remaining, onTrace, {
            fastReplyMode: options.fastReplyMode, includeEmptyContext: options.includeEmptyContext,
            onTiming: onTrace ? value => { timing = value; } : undefined,
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
        onTrace?.('warn', '主模型异常，已切换备用模型', code);
        decision = await execute(eligible, { ...options, apiKey: undefined, cloudApproved: fallbackCloudApproved }, CHAT_TIMEOUT_MS);
      }
      const labels = { reply: '回复', skip: '跳过', manual: '转人工', stop: '停止回复', identity: '说明身份' };
      if (timing) onTrace?.('info', `模型决策：${labels[decision.action]}（首包 ${timing.firstByteMs}ms / 共 ${timing.totalMs}ms · effort=${timing.effort}）`);
      return decision;
    } catch (error) {
      if (!signal?.aborted) onTrace?.('error', '模型调用失败', errorCode(error));
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
