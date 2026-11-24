import { sha } from '../../contracts.ts';
import type { MessageKind, ScopeType } from '../contracts/events.ts';
import type { MemoryRevision } from '../storage/journal-v2.ts';

export const MAX_MEMORY_BYTES = 48 * 1024;
export const MAX_ENTRY_CHARS = 200;
export const MAX_DIFF_BYTES = 8 * 1024;
export const MAX_SNAPSHOTS = 50;
export const SCOPE_SECTIONS = ['关系与背景', '偏好与习惯', '近期事件'] as const;
export const PERSONA_SECTIONS = ['表达风格', '从本人发言习得的习惯', '沟通边界'] as const;

export type Visibility = 'cloud-safe' | 'local-only';
export type RevisionSource = MemoryRevision['source'];
export type ScopeTarget = {
  kind: 'scope'; accountId: string; conversationId: string; scopeType?: ScopeType; label?: string;
};
export type MemoryTarget = { kind: 'persona' } | ScopeTarget;
export const scopeKeyFor = (accountId: string, conversationId: string) => sha(JSON.stringify([accountId, conversationId]));
export const memoryScopeKey = (target: MemoryTarget) => target.kind === 'persona' ? 'global' : scopeKeyFor(target.accountId, target.conversationId);

export type MemoryEntry = {
  id: string; section: string; content: string; visibility: Visibility; locked: boolean; managed: boolean;
  source?: string; updated?: string; expires?: string;
};
export type MemoryMetadata = Record<string, unknown> & {
  schema?: number; scopeType?: ScopeType; conversationId?: string; label?: string; updatedAt?: string; revision?: number;
};
export type MemoryBlock = { raw: string; section: string; heading?: string; entry?: MemoryEntry };
export type MemoryDocument = {
  metadata: MemoryMetadata; entries: MemoryEntry[]; blocks: MemoryBlock[]; eol: string; bom: string;
  frontmatter: { raw: string; original: MemoryMetadata } | null;
};

export type PatchOperation =
  | { op: 'add'; section: string; content: string; suggestedVisibility: Visibility; ttlDays?: number }
  | { op: 'update'; entryId: string; content: string; suggestedVisibility: Visibility }
  | { op: 'archive'; entryId: string; reason: string };
export type CompleteJson = (system: string, user: string, signal?: AbortSignal) => Promise<string>;
export type MemoryMessage = {
  eventId: string; messageRef: string; createdAt: number; text: string; isSelf: boolean;
  kind?: MessageKind; senderLabel?: string; recalled?: boolean; recallTargetRef?: string; route?: string;
  accountId?: string; conversationId?: string;
};

export const ENTRY_ID = /^(?!hand_)[A-Za-z0-9_-]{2,32}$/;
export const SOURCE_TOKEN = /^[A-Za-z0-9_-]+$/;
export const charCount = (text: string) => Array.from(text).length;
export const takeChars = (text: string, count: number) => Array.from(text).slice(0, count).join('');
const pad = (n: number) => String(n).padStart(2, '0');
export function localDate(now: number, days = 0) {
  const date = new Date(now);
  if (days) date.setDate(date.getDate() + days);
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}
export function validDate(value: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(+date) && date.toISOString().slice(0, 10) === value;
}
export const expired = (entry: MemoryEntry, today: string) => !!entry.expires && entry.expires < today;
