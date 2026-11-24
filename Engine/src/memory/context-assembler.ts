import { constants } from 'node:fs';
import { open } from 'node:fs/promises';
import { BridgeError } from '../contracts/errors.ts';
import type { SettingsV2 } from '../contracts/settings.ts';
import { MemoryGuard } from './guard.ts';
import { nextFence, type MemoryStore } from './store.ts';
import { expired, localDate, type MemoryEntry, type MemoryMessage, type ScopeTarget } from './types.ts';

const LEGACY_BYTES = 65_536;
const START = '<!-- bridge-cloud:start -->', END = '<!-- bridge-cloud:end -->';
const STYLE_MAX = 1500, MEMORY_MAX = 2000, WORKING_MAX = 4000;
const guard = new MemoryGuard();
type Mode = 'local' | 'cloud';
export type ContextMessage = { from: 'peer' | 'self' | 'auto'; text: string };
export type WorkingMessage = Pick<MemoryMessage, 'text' | 'kind' | 'recalled' | 'accountId' | 'conversationId'> & {
  createdAt?: number; from?: ContextMessage['from']; isSelf?: boolean;
};
export type PromptContextInput = Partial<Pick<SettingsV2['memory'], 'legacyStylePath' | 'legacyMemoryPath' |
  'workingMaxMessages' | 'workingTtlMinutes'>> & {
  mode: Mode; target?: ScopeTarget; working?: readonly WorkingMessage[]; workingMaxChars?: number;
};

export function entriesForPrompt(entries: readonly MemoryEntry[], mode: Mode, today: string): MemoryEntry[] {
  return entries.filter(entry => !expired(entry, today) && (mode === 'local' ||
    (entry.managed && entry.visibility === 'cloud-safe' && guard.allowsCloud(entry.content))));
}

function clip(text: string, limit: number) {
  // UTF-16 限额沿用既有模型接口，不截断代理对。
  return text.slice(0, limit).replace(/[\uD800-\uDBFF]$/, '');
}

async function legacyExcerpt(path: string | undefined, mode: Mode, oldLimit: number) {
  if (!path) return '';
  let text: string;
  try {
    const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const stat = await file.stat();
      if (!stat.isFile() || stat.size > LEGACY_BYTES || stat.uid !== process.getuid?.()) throw new Error();
      const bytes = Buffer.alloc(LEGACY_BYTES + 1);
      let offset = 0;
      while (offset < bytes.length) {
        const { bytesRead } = await file.read(bytes, offset, bytes.length - offset, offset);
        if (!bytesRead) break;
        offset += bytesRead;
      }
      if (offset > LEGACY_BYTES) throw new Error();
      text = new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, offset));
      if (text.includes('\0')) throw new Error();
    } finally { await file.close(); }
  } catch { throw new BridgeError('profile-unreadable'); }
  if (mode === 'local') return clip(text.trim(), oldLimit);
  const lines = text.split(/\r?\n/), start = lines.indexOf(START), end = lines.indexOf(END);
  if (start < 0 || end <= start || text.indexOf(START) !== text.lastIndexOf(START) || text.indexOf(END) !== text.lastIndexOf(END)) {
    throw new BridgeError('cloud-profile');
  }
  let fence: string | undefined;
  for (let index = 0; index <= end; index++) {
    if (fence && (index === start || index === end)) throw new BridgeError('cloud-profile');
    fence = nextFence(lines[index]!, fence);
  }
  const approved = lines.slice(start + 1, end).join('\n').trim();
  if (!approved || approved.length > oldLimit) throw new BridgeError('cloud-profile');
  // 白名单块仍不能越过 v2 的敏感信息过滤；整行排除，不暴露其片段。
  return approved.split('\n').filter(line => guard.allowsCloud(line)).join('\n').trim();
}

function profile(legacy: string, entries: MemoryEntry[], limit: number) {
  const lines = [legacy, ...entries.map(entry => `- ${entry.content}`)].filter(Boolean);
  return clip(lines.join('\n'), limit);
}

export class PromptContextAssembler {
  constructor(private readonly store: MemoryStore, private readonly now = Date.now) {}

  async assemble(input: PromptContextInput): Promise<{ style: string; memory: string; context: ContextMessage[] }> {
    const now = this.now(), today = localDate(now);
    const [style, memory] = await Promise.all([
      legacyExcerpt(input.legacyStylePath, input.mode, 2000), legacyExcerpt(input.legacyMemoryPath, input.mode, 1200),
    ]);
    const persona = entriesForPrompt(this.store.read({ kind: 'persona' }).entries, input.mode, today);
    const scoped = input.target ? entriesForPrompt(this.store.read(input.target).entries, input.mode, today) : [];
    const maxMessages = Math.min(input.mode === 'cloud' ? 12 : 64, Math.max(0, input.workingMaxMessages ?? 16));
    const since = now - (input.workingTtlMinutes ?? 30) * 60_000;
    const eligible = (input.working ?? []).filter(message => !message.recalled && message.kind !== 'recall' &&
      message.kind !== 'system' && !!message.text.trim() && (message.createdAt === undefined || message.createdAt >= since) &&
      (!input.target || ((message.accountId === undefined || message.accountId === input.target.accountId) &&
        (message.conversationId === undefined || message.conversationId === input.target.conversationId))) &&
      (input.mode === 'local' || guard.allowsCloud(message.text.replace(/\r?\n|\t/g, ' '))));
    let remaining = Math.max(0, input.workingMaxChars ?? WORKING_MAX);
    const context: ContextMessage[] = [];
    for (let index = eligible.length - 1; index >= 0 && context.length < maxMessages && remaining > 0; index--) {
      const message = eligible[index]!;
      if (context.length && message.text.length > remaining) break;
      const text = clip(message.text, remaining);
      if (!text) break;
      context.push({ from: message.from ?? (message.isSelf ? 'self' : 'peer'), text });
      remaining -= text.length;
    }
    return { style: profile(style, persona, STYLE_MAX), memory: profile(memory, scoped, MEMORY_MAX), context: context.reverse() };
  }
}
