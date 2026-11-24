import { BridgeError, type ModelConfig } from '../../contracts.ts';
import { type ErrorCode } from '../contracts/errors.ts';
import { untilAborted } from './sse.ts';

type Effort = Exclude<ModelConfig['reasoningEffort'], 'default'>;
export type ModelTrace = (level: 'info' | 'warn' | 'error', summary: string, code?: ErrorCode) => void;
export type ModelTiming = { firstByteMs: number; totalMs: number; effort: NonNullable<Effort> | 'default' };
type Options<T> = {
  url: URL; key?: string; mode: 'local' | 'cloud'; effort?: Effort;
  timeoutMs: number; signal?: AbortSignal; onTrace?: ModelTrace; retryFormat?: boolean;
  body: (effort: Effort, correctFormat: boolean) => string | FormData;
  parse: (response: Response, signal: AbortSignal, onFirstByte: () => void) => Promise<T>;
  onTiming?: (timing: ModelTiming) => void;
};

const capabilities = new Map<string, Set<string>>();
const reasoning = 'reasoning_effort';
const transientStatus = new Set([502, 503, 504]);
const backoffs = [600, 1500];

export function resetEndpointCapabilities() { capabilities.clear(); }

function retryAfter(response: Response) {
  const header = response.headers.get('retry-after')?.trim() ?? '';
  return /^\d+(?:\.\d+)?$/.test(header) ? Math.min(8000, Math.max(500, Number(header) * 1000)) : 1500;
}

function wait(ms: number, signal: AbortSignal) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const task = new Promise<void>(resolve => { timer = setTimeout(resolve, ms); });
  return untilAborted(task, signal).finally(() => clearTimeout(timer));
}

async function rejectsEffort(response: Response, signal: AbortSignal) {
  const reader = response.body?.getReader();
  if (!reader) return false;
  const decoder = new TextDecoder();
  let detail = '';
  try {
    while (detail.length < 16_384) {
      const { value, done } = await untilAborted(reader.read(), signal);
      if (done) break;
      detail += decoder.decode(value.subarray(0, 16_384 - detail.length), { stream: true });
    }
    return /reasoning_effort/i.test(detail) &&
      /unsupported|not supported|not allowed|not permitted|unrecognized|unknown|unexpected|extra_forbidden|不支持/i.test(detail);
  } finally { void reader.cancel().catch(() => {}); }
}

export async function requestModel<T>(options: Options<T>): Promise<T> {
  const { url, key, mode, timeoutMs, onTrace, signal } = options;
  const deadline = new AbortController();
  const deadlineTimer = setTimeout(() => deadline.abort(new BridgeError('model-timeout')), timeoutMs);
  const combined = signal ? AbortSignal.any([signal, deadline.signal]) : deadline.signal;
  const started = performance.now();
  const endsAt = started + timeoutMs;
  let effort = options.effort;
  let transientRetries = 0, rateRetries = 0;
  let corrected = false, downgraded = false;
  const canRetry = (delay: number) => endsAt - performance.now() > delay;
  try {
    for (;;) {
      combined.throwIfAborted();
      if (capabilities.get(url.href)?.has(reasoning)) effort = undefined;
      const payload = options.body(effort, corrected);
      onTrace?.('info', `开始调用${mode === 'cloud' ? '云模型' : '本地模型'}（reasoning_effort=${effort ?? '未发送'}）`);
      let status: number | undefined;
      let rateDelay = 1500;
      try {
        // 为长请求的首包超时预留一次降档机会。持续到达的流只受空闲和总截止时间约束。
        const firstByte = new AbortController();
        const firstByteTimer = effort === 'max' && timeoutMs >= 15_000 && !downgraded
          ? setTimeout(() => firstByte.abort(new BridgeError('model-timeout')), Math.floor(timeoutMs * 2 / 3)) : undefined;
        const attemptSignal = firstByteTimer ? AbortSignal.any([combined, firstByte.signal]) : combined;
        const attemptStarted = performance.now();
        let response: Response;
        try {
          response = await untilAborted(fetch(url, {
            method: 'POST', credentials: 'omit', redirect: 'error', proxy: '', signal: attemptSignal,
            headers: { ...(typeof payload === 'string' && { 'content-type': 'application/json', accept: 'text/event-stream, application/json' }),
              ...(key && { authorization: `Bearer ${key}` }) }, body: payload,
          }), attemptSignal);
        } catch (error) {
          if (firstByte.signal.aborted) throw new BridgeError('model-timeout');
          throw error;
        } finally { clearTimeout(firstByteTimer); }
        if (response.ok) {
          let firstByteAt: number | undefined;
          const onFirstByte = () => { firstByteAt ??= performance.now(); };
          const result = await untilAborted(options.parse(response, combined, onFirstByte), combined);
          if (firstByteAt !== undefined) options.onTiming?.({
            firstByteMs: Math.round(firstByteAt - attemptStarted),
            totalMs: Math.round(performance.now() - started),
            effort: effort ?? 'default',
          });
          return result;
        }
        status = response.status;
        if (status === 400 && effort) {
          if (await rejectsEffort(response, combined)) {
            capabilities.set(url.href, new Set([reasoning]));
            effort = undefined;
            onTrace?.('warn', '上游不支持 reasoning_effort，已移除该字段并重试');
            continue;
          }
        } else {
          if (status === 429) rateDelay = retryAfter(response);
          void response.body?.cancel().catch(() => {});
        }
        throw new BridgeError(status === 401 || status === 403 ? 'model-auth' : status === 429 ? 'model-limit' : 'model-unavailable');
      } catch (error) {
        combined.throwIfAborted();
        const fault = error instanceof BridgeError ? error : new BridgeError('model-unavailable');
        if (status === 429 && rateRetries < 2 && canRetry(rateDelay)) {
          onTrace?.('warn', `上游 429，等待 ${rateDelay} ms 后第 ${++rateRetries} 次重试`, 'model-limit');
          await wait(rateDelay, combined);
          continue;
        }
        const delay = backoffs[transientRetries];
        if (fault.code === 'model-unavailable' && (status === undefined || transientStatus.has(status)) && delay !== undefined && canRetry(delay)) {
          onTrace?.('warn', `${status ? `上游 ${status}` : '模型连接中断'}，正在第 ${++transientRetries} 次重试`, 'model-unavailable');
          await wait(delay, combined);
          continue;
        }
        if (fault.code === 'model-timeout' && effort === 'max' && !downgraded && canRetry(500)) {
          effort = 'high';
          downgraded = true;
          onTrace?.('warn', '模型请求超时，已将 reasoning_effort 降为 high 再试一次', 'model-timeout');
          continue;
        }
        if (fault.code === 'model-format' && options.retryFormat && !corrected) {
          corrected = true;
          onTrace?.('warn', '模型输出格式有误，正在重试并要求仅输出决策 JSON', 'model-format');
          continue;
        }
        throw fault;
      }
    }
  } catch (error) {
    if (signal?.aborted) throw new BridgeError('stopped');
    if (deadline.signal.aborted) throw new BridgeError('model-timeout');
    throw error;
  } finally { clearTimeout(deadlineTimer); }
}
