import { BridgeError, object } from '../../contracts.ts';

export function stripJsonFence(text: string) {
  const trimmed = text.trim();
  const match = /^```(?:json)?[ \t]*\r?\n([\s\S]*?)\r?\n```$/i.exec(trimmed);
  return match ? match[1]!.trim() : trimmed;
}

export function extractJsonObject(text: string): string {
  const source = stripJsonFence(text);
  try {
    if (object(JSON.parse(source))) return source;
    throw new BridgeError('model-format');
  } catch (error) {
    if (error instanceof BridgeError) throw error;
  }
  const objectStart = /\s*["}]/y;
  const arrayStart = /\s*[[{"\]tfn\d-]/y;
  const stack: string[] = [];
  let start = -1, quoted = false, escaped = false;
  for (let index = 0; index < source.length; index++) {
    const char = source[index];
    if (start === -1) {
      const opener = char === '{' ? objectStart : char === '[' ? arrayStart : undefined;
      if (opener) {
        opener.lastIndex = index + 1;
        if (opener.test(source)) { start = index; stack.push(char === '{' ? '}' : ']'); }
      }
      continue;
    }
    if (quoted) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') quoted = false;
    } else if (char === '"') quoted = true;
    else if (char === '{' || char === '[') stack.push(char === '{' ? '}' : ']');
    else if (char === '}' || char === ']') {
      if (stack.pop() !== char) stack.length = 0;
      if (!stack.length) {
        if (source[start] === '{') {
          const candidate = source.slice(start, index + 1);
          try { if (object(JSON.parse(candidate))) return candidate; }
          catch { /* 继续查找下一个顶层对象 */ }
        }
        start = -1;
      }
    }
  }
  throw new BridgeError('model-format');
}

export async function untilAborted<T>(task: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return task;
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason);
    if (signal.aborted) abort();
    else signal.addEventListener('abort', abort, { once: true });
    void task.then(resolve, reject).finally(() => signal.removeEventListener('abort', abort));
  });
}

function extractStandardJSON(raw: string): string {
  let data: Record<string, unknown> | undefined;
  try { data = object(JSON.parse(raw)); } catch { throw new BridgeError('model-format'); }
  const choice = Array.isArray(data?.choices) && data.choices.length === 1 ? object(data.choices[0]) : undefined;
  const message = object(choice?.message);
  if (choice?.finish_reason !== 'stop' || typeof message?.content !== 'string' ||
    message.tool_calls || message.function_call || message.refusal) {
    throw new BridgeError('model-format');
  }
  return message.content;
}

class SseAccumulator {
  private readonly parts: string[] = [];
  private finishReason?: string;
  done = false;

  feedLine(rawLine: string) {
    const line = rawLine.endsWith('\r') ? rawLine.slice(0, -1) : rawLine;
    if (!line || line.startsWith(':')) return;
    if (!line.startsWith('data:')) return;
    const payload = line.slice(5).trim();
    if (!payload) return;
    if (payload === '[DONE]') { this.done = true; return; }
    let chunk: Record<string, unknown> | undefined;
    try { chunk = object(JSON.parse(payload)); } catch { throw new BridgeError('model-format'); }
    if (!chunk) throw new BridgeError('model-format');
    if (chunk.error) throw new BridgeError('model-unavailable');
    if (!Array.isArray(chunk.choices) || chunk.choices.length === 0) return;
    if (chunk.choices.length !== 1) throw new BridgeError('model-format');
    const choice = object(chunk.choices[0]);
    if (!choice) throw new BridgeError('model-format');
    const delta = object(choice.delta) ?? object(choice.message);
    if (delta?.tool_calls || delta?.function_call || delta?.refusal) throw new BridgeError('model-format');
    if (typeof delta?.content === 'string') this.parts.push(delta.content);
    if (typeof choice.finish_reason === 'string' && choice.finish_reason) {
      this.finishReason = choice.finish_reason;
    }
  }

  finish(): string {
    if (!this.done && this.finishReason === undefined) throw new BridgeError('model-unavailable');
    if (this.finishReason !== undefined && this.finishReason !== 'stop') {
      throw new BridgeError('model-format');
    }
    const text = this.parts.join('');
    if (!text) throw new BridgeError('model-format');
    return text;
  }
}

export async function readCompletionContent(response: Response, maxBytes: number,
  options: { idleTimeoutMs?: number; signal?: AbortSignal; onFirstByte?: () => void } = {}): Promise<string> {
  if (!response.body) throw new BridgeError('model-format');
  const contentType = (response.headers.get('content-type') ?? '').toLowerCase();
  const reader = response.body.getReader();
  let bytes = 0;
  const countBytes = (value: Uint8Array) => {
    if (bytes === 0 && value.byteLength > 0) options.onFirstByte?.();
    bytes += value.byteLength;
    if (bytes > maxBytes) throw new BridgeError('model-format');
  };

  if (contentType.includes('text/event-stream')) {
    const decoder = new TextDecoder('utf-8', { fatal: true });
    const acc = new SseAccumulator();
    let pending = '';
    try {
      for (;;) {
        options.signal?.throwIfAborted();
        const idle = new AbortController();
        const timer = setTimeout(() => idle.abort(new BridgeError('model-timeout')), options.idleTimeoutMs ?? 45_000);
        const signal = options.signal ? AbortSignal.any([options.signal, idle.signal]) : idle.signal;
        const { value, done } = await untilAborted(reader.read(), signal).finally(() => clearTimeout(timer));
        if (done) break;
        countBytes(value);
        try { pending += decoder.decode(value, { stream: true }); }
        catch { throw new BridgeError('model-format'); }
        let nl = pending.indexOf('\n');
        while (nl >= 0) {
          acc.feedLine(pending.slice(0, nl));
          pending = pending.slice(nl + 1);
          if (acc.done) break;
          nl = pending.indexOf('\n');
        }
        if (acc.done) break;
      }
      if (!acc.done) {
        try {
          pending += decoder.decode();
          if (pending.length) acc.feedLine(pending);
        } catch { throw new BridgeError('model-unavailable'); }
      }
    } finally { void reader.cancel().catch(() => {}); }
    return acc.finish();
  }

  const chunks: Uint8Array[] = [];
  try {
    for (;;) {
      options.signal?.throwIfAborted();
      const { value, done } = await untilAborted(reader.read(), options.signal);
      if (done) break;
      countBytes(value);
      chunks.push(value);
    }
  } finally { void reader.cancel().catch(() => {}); }
  let raw: string;
  try { raw = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)); }
  catch { throw new BridgeError('model-format'); }
  const trimmed = raw.trimStart();
  // 部分中转网关返回 SSE 正文但未设 text/event-stream 头，按正文前缀自动兜底解析。
  if (trimmed.startsWith('data:') || trimmed.startsWith(':')) {
    const acc = new SseAccumulator();
    for (const line of raw.split('\n')) {
      acc.feedLine(line);
      if (acc.done) break;
    }
    return acc.finish();
  }
  return extractStandardJSON(raw);
}
