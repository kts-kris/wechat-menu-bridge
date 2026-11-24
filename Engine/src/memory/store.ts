import { randomUUID } from 'node:crypto';
import { lstatSync, unlinkSync } from 'node:fs';
import { basename, join } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { sha } from '../../contracts.ts';
import { BridgeError } from '../contracts/errors.ts';
import { assertPrivateFile, atomicWritePrivateFile, ensurePrivateDir, readPrivateFile, resolveContainedPath } from '../storage/fs-safe.ts';
import type { JournalV2, MemoryRevision } from '../storage/journal-v2.ts';
import { MemoryGuard } from './guard.ts';
import {
  ENTRY_ID, MAX_DIFF_BYTES, MAX_MEMORY_BYTES, MAX_SNAPSHOTS, SOURCE_TOKEN, memoryScopeKey, validDate,
  type MemoryBlock, type MemoryDocument, type MemoryEntry, type MemoryMetadata, type MemoryTarget, type RevisionSource, type Visibility,
} from './types.ts';

const missing = (error: unknown) => (error as NodeJS.ErrnoException).code === 'ENOENT';
const invalid = () => new BridgeError('invalid-configuration');
const splitLines = (text: string) => text.match(/[^\n]*\n|[^\n]+$/g) ?? [];
const withoutEol = (line: string) => line.replace(/\r?\n$/, '');
const snapshotName = /^\d+-([0-9a-f-]{36})\.md$/;

function decode(bytes: Uint8Array) {
  try { return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes); }
  catch { throw new BridgeError('profile-unreadable'); }
}

export function nextFence(line: string, fence: string | undefined) {
  const boundary = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
  if (!boundary) return fence;
  if (!fence) return boundary[1];
  return boundary[1]!.startsWith(fence) && !boundary[2]!.trim() ? undefined : fence;
}

function parseFields(line: string): Omit<MemoryEntry, 'section' | 'content'> | undefined {
  const match = /^<!-- mem:(\S+(?: +\S+)*) -->$/.exec(line);
  if (!match) return;
  const fields = new Map<string, string>();
  for (const token of match[1]!.split(/ +/)) {
    const field = /^(id|vis|locked|src|updated|expires)=([^=]+)$/.exec(token);
    if (!field || fields.has(field[1]!)) return;
    fields.set(field[1]!, field[2]!);
  }
  const id = fields.get('id'), visibility = fields.get('vis'), locked = fields.get('locked');
  const source = fields.get('src'), updated = fields.get('updated'), expires = fields.get('expires');
  if (!id || !ENTRY_ID.test(id) || (visibility !== 'cloud-safe' && visibility !== 'local-only') ||
      (locked !== 'true' && locked !== 'false') || (source && !SOURCE_TOKEN.test(source)) ||
      (updated && !validDate(updated)) || (expires && !validDate(expires))) return;
  return { id, visibility, locked: locked === 'true', managed: true, source, updated, expires };
}

function parseMetadata(text: string): MemoryMetadata {
  try {
    const value: unknown = Bun.YAML.parse(text);
    if (value == null) return {};
    if (typeof value === 'object' && !Array.isArray(value)) return value as MemoryMetadata;
  } catch { /* 不把无法解析的头部当作可发送的正文。 */ }
  throw invalid();
}

export function parseMemoryMarkdown(text: string): MemoryDocument {
  const bom = text.startsWith('\uFEFF') ? '\uFEFF' : '';
  const lines = splitLines(text.slice(bom.length));
  const eol = lines.find(line => line.endsWith('\n'))?.endsWith('\r\n') ? '\r\n' : '\n';
  const blocks: MemoryBlock[] = [], entries: MemoryEntry[] = [];
  const document: MemoryDocument = { metadata: {}, blocks, entries, eol, bom, frontmatter: null };
  let index = 0;
  if (lines[0] && withoutEol(lines[0]) === '---') {
    const end = lines.findIndex((line, i) => i > 0 && /^(?:---|\.\.\.)$/.test(withoutEol(line)));
    const possibleYaml = end > 0 ? lines.slice(1, end) : lines.slice(1);
    const hasSchemaFields = possibleYaml.some(line => /^(?:schema|scopeType|conversationId|updatedAt|revision):/.test(line));
    if (end < 0 && hasSchemaFields) throw invalid();
    if (end > 0) {
      try {
        const original = parseMetadata(possibleYaml.join(''));
        document.metadata = structuredClone(original);
        document.frontmatter = { original, raw: lines.slice(0, end + 1).join('') };
        index = end + 1;
      } catch (error) {
        // 单独的 Markdown 分隔线不是 YAML 头部；只有疑似规范头部才报格式错误。
        if (hasSchemaFields) throw error;
      }
    }
  }
  let section = '', fence: string | undefined, comment = false;
  const counts = new Map<string, number>();
  const handwritten = (raw: string, content = withoutEol(raw)) => {
    const hash = sha(`${section}\0${withoutEol(raw)}`).slice(0, 21);
    const occurrence = (counts.get(hash) ?? 0) + 1;
    counts.set(hash, occurrence);
    const entry: MemoryEntry = { id: `hand_${hash}_${occurrence}`, section, content, managed: false, locked: true, visibility: 'local-only' };
    blocks.push({ raw, entry, section });
    entries.push(entry);
  };
  for (; index < lines.length; index++) {
    const raw = lines[index]!, line = withoutEol(raw);
    const boundary = comment ? undefined : nextFence(line, fence);
    if (fence || boundary) {
      handwritten(raw);
      fence = boundary;
      continue;
    }
    const heading = !comment && /^ {0,3}#{1,6}[ \t]+(.+?)[ \t]*#*[ \t]*$/.exec(line);
    if (heading) {
      section = heading[1]!;
      blocks.push({ raw, section, heading: section });
      continue;
    }
    const fields = !comment && parseFields(line);
    const next = lines[index + 1];
    const bullet = next && /^- +(.+)$/.exec(withoutEol(next));
    if (fields && next && bullet && bullet[1]!.trim()) {
      const entry = { ...fields, section, content: bullet[1]!.trim() };
      blocks.push({ raw: raw + next, entry, section });
      entries.push(entry);
      index++;
      continue;
    }
    // 注释块中的伪条目标记不参与解析；原文仍保留。
    for (const token of line.matchAll(/<!--|-->/g)) {
      if (!comment && token[0] === '<!--') comment = true;
      else if (comment && token[0] === '-->') comment = false;
    }
    if (line.trim()) handwritten(raw, line.replace(/^ {0,3}(?:[-*+]|\d+[.)]) +/, ''));
    else blocks.push({ raw, section });
  }
  const ids = new Map<string, number>();
  for (const entry of entries) ids.set(entry.id, (ids.get(entry.id) ?? 0) + 1);
  // 重复 ID 无法明确指向条目，将每个副本保留为隐私手写块。
  for (const block of blocks) {
    const entry = block.entry;
    if (!entry || !entry.managed || ids.get(entry.id) === 1) continue;
    const hash = sha(`${entry.section}\0${block.raw}`).slice(0, 21);
    const occurrence = (counts.get(hash) ?? 0) + 1;
    counts.set(hash, occurrence);
    Object.assign(entry, { id: `hand_${hash}_${occurrence}`, locked: true, managed: false, visibility: 'local-only' });
  }
  document.entries = entries.map(entry => ({ ...entry }));
  return document;
}

function serializeFrontmatter(document: MemoryDocument) {
  const { metadata, frontmatter, eol } = document;
  if (frontmatter && isDeepStrictEqual(metadata, frontmatter.original)) return frontmatter.raw;
  if (!frontmatter && Object.keys(metadata).length === 0) return '';
  if (frontmatter) {
    const lines = splitLines(frontmatter.raw);
    const start = lines.shift()!, end = lines.pop()!;
    const fields = new Set([...Object.keys(frontmatter.original), ...Object.keys(metadata)].filter(key =>
      !isDeepStrictEqual(metadata[key], frontmatter.original[key])));
    const patched = lines.map(line => {
      const match = /^([\w]+):[ \t]*([^#\r\n]*?)([ \t]+#.*)?(\r?\n)?$/.exec(line);
      if (!match || !fields.delete(match[1]!)) return line;
      const value = metadata[match[1]!];
      return value === undefined ? '' : `${match[1]}: ${JSON.stringify(value)}${match[3] ?? ''}${match[4] ?? eol}`;
    });
    for (const key of fields) if (metadata[key] !== undefined) patched.push(`${/^\w+$/.test(key) ? key : JSON.stringify(key)}: ${JSON.stringify(metadata[key])}${eol}`);
    try { if (isDeepStrictEqual(parseMetadata(patched.join('')), metadata)) return start + patched.join('') + end; }
    catch { /* 复杂 YAML 值改用标准序列化，避免生成不合法的头部。 */ }
  }
  const yaml = Bun.YAML.stringify(metadata, null, 2).trimEnd().replace(/\n/g, eol);
  return `---${eol}${yaml}${eol}---${eol}`;
}

export function serializeMemoryMarkdown(document: MemoryDocument): string {
  const { eol, blocks } = document;
  const byId = new Map(document.entries.map(entry => [entry.id, entry]));
  const existing = new Set(blocks.flatMap(block => block.entry ? [block.entry.id] : []));
  const added = new Map<string, MemoryEntry[]>();
  for (const entry of document.entries) if (!existing.has(entry.id)) {
    if (!added.has(entry.section)) added.set(entry.section, []);
    added.get(entry.section)!.push(entry);
  }
  const encode = (entry: MemoryEntry) => {
    if (!entry.managed || !ENTRY_ID.test(entry.id) || (entry.source && !SOURCE_TOKEN.test(entry.source)) ||
        (entry.updated && !validDate(entry.updated)) || (entry.expires && !validDate(entry.expires))) throw invalid();
    const extra = [entry.source && ` src=${entry.source}`, entry.updated && ` updated=${entry.updated}`,
      entry.expires && ` expires=${entry.expires}`].filter(Boolean).join('');
    return `<!-- mem:id=${entry.id} vis=${entry.visibility} locked=${entry.locked}${extra} -->${eol}- ${entry.content}${eol}`;
  };
  let text = serializeFrontmatter(document);
  let section = '';
  const append = (value: string) => {
    if (text && !text.endsWith('\n')) text += eol;
    text += value;
  };
  const insert = () => {
    for (const entry of added.get(section) ?? []) append(encode(entry));
    added.delete(section);
  };
  for (const block of blocks) {
    if (block.heading !== undefined) { insert(); section = block.heading; }
    if (!block.entry) { text += block.raw; continue; }
    const entry = byId.get(block.entry.id);
    if (!entry) continue;
    if (isDeepStrictEqual(entry, block.entry)) text += block.raw;
    else text += encode(entry);
  }
  insert();
  for (const [name, entries] of added) {
    if (!name || /[\p{Cc}\p{Cf}]/u.test(name)) throw invalid();
    append(`${eol}## ${name}${eol}`);
    for (const entry of entries) append(encode(entry));
  }
  return document.bom + text;
}

type DiffLine = { sign: ' ' | '+' | '-'; text: string };

// 优先复用共同前后缀，中段使用有界 LCS，极端大差异退化为单次替换。
function diffLines(before: string, after: string): DiffLine[] {
  const a = splitLines(before), b = splitLines(after), result: DiffLine[] = [];
  let start = 0, end = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) result.push({ sign: ' ', text: a[start++]! });
  while (end < a.length - start && end < b.length - start && a[a.length - 1 - end] === b[b.length - 1 - end]) end++;
  const n = a.length - start - end, m = b.length - start - end;
  if (n && m && (n + 1) * (m + 1) <= 1_000_000) {
    const width = m + 1, lcs = new Uint32Array((n + 1) * width);
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) {
      const index = i * width + j;
      lcs[index] = a[start + i] === b[start + j] ? lcs[index + width + 1]! + 1 : Math.max(lcs[index + width]!, lcs[index + 1]!);
    }
    for (let i = 0, j = 0; i < n || j < m;) {
      if (i < n && j < m && a[start + i] === b[start + j]) { result.push({ sign: ' ', text: a[start + i++]! }); j++; }
      else if (i < n && (j === m || lcs[(i + 1) * width + j]! >= lcs[i * width + j + 1]!)) result.push({ sign: '-', text: a[start + i++]! });
      else result.push({ sign: '+', text: b[start + j++]! });
    }
  } else {
    for (const text of a.slice(start, start + n)) result.push({ sign: '-', text });
    for (const text of b.slice(start, start + m)) result.push({ sign: '+', text });
  }
  for (const text of a.slice(a.length - end)) result.push({ sign: ' ', text });
  return result;
}

function balancePreview(lines: DiffLine[]): DiffLine[] {
  const result: DiffLine[] = [];
  for (let index = 0; index < lines.length;) {
    const line = lines[index]!;
    if (line.sign === ' ') { result.push(line); index++; continue; }
    const removed: DiffLine[] = [], added: DiffLine[] = [];
    while (index < lines.length && lines[index]!.sign !== ' ') {
      const change = lines[index++]!;
      (change.sign === '-' ? removed : added).push(change);
    }
    // 预览截断整段替换时同时显示删除和新增，两侧各自的行序保持不变。
    for (let offset = 0; offset < Math.max(removed.length, added.length); offset++) {
      if (removed[offset]) result.push(removed[offset]!);
      if (added[offset]) result.push(added[offset]!);
    }
  }
  return result;
}

export function unifiedDiff(before: string, after: string, name: string, maxBytes = Infinity): string {
  if (before === after) return '';
  const changes = diffLines(before, after);
  const lines = Number.isFinite(maxBytes) ? balancePreview(changes) : changes;
  const groups: Array<{ start: number; end: number }> = [];
  for (const [index, line] of lines.entries()) if (line.sign !== ' ') {
    const start = Math.max(0, index - 3), end = Math.min(lines.length, index + 4);
    const last = groups.at(-1);
    if (last && last.end >= start) last.end = end;
    else groups.push({ start, end });
  }
  let diff = `--- a/${name}\n+++ b/${name}\n`, i = 0, oldAt = 1, newAt = 1;
  const headerBytes = Buffer.byteLength(diff);
  let diffBytes = headerBytes;
  const range = (at: number, count: number) => count === 1 ? `${at}` : `${count ? at : at - 1},${count}`;
  const advance = (line: DiffLine) => { if (line.sign !== '+') oldAt++; if (line.sign !== '-') newAt++; };
  for (const { start, end } of groups) {
    while (i < start) advance(lines[i++]!);
    const body: string[] = [];
    let header = '', bodyBytes = 0, a = 0, b = 0, changed = false;
    for (let k = start; k < end; k++) {
      const { sign, text } = lines[k]!;
      const rendered = sign + (text.endsWith('\n') ? text : `${text}\n\\ No newline at end of file\n`);
      const bytes = Buffer.byteLength(rendered);
      const nextA = a + Number(sign !== '+'), nextB = b + Number(sign !== '-');
      const nextHeader = `@@ -${range(oldAt, nextA)} +${range(newAt, nextB)} @@\n`;
      if (diffBytes + nextHeader.length + bodyBytes + bytes > maxBytes) break;
      changed ||= sign !== ' ';
      body.push(rendered);
      header = nextHeader;
      bodyBytes += bytes;
      a = nextA;
      b = nextB;
    }
    if (changed) { diff += header + body.join(''); diffBytes += header.length + bodyBytes; }
    while (i < end) advance(lines[i++]!);
  }
  return headerBytes <= maxBytes ? diff : '';
}

type SaveOptions = { source?: RevisionSource; summary?: string; expectedText?: string };

export class MemoryStore {
  private readonly guard = new MemoryGuard();

  constructor(readonly baseDir: string, private readonly journal: JournalV2, private readonly now = Date.now) {
    ensurePrivateDir(baseDir);
    for (const dir of ['scopes', 'history', 'history/scopes', 'history/persona', 'proposals']) {
      ensurePrivateDir(resolveContainedPath(baseDir, dir));
    }
  }

  pathFor(target: MemoryTarget) {
    const relative = target.kind === 'persona' ? 'persona.md' : `scopes/${memoryScopeKey(target)}.md`;
    return resolveContainedPath(this.baseDir, relative);
  }

  proposalPath(proposalId: string) {
    if (!/^[0-9a-f-]{36}$/.test(proposalId)) throw invalid();
    return resolveContainedPath(this.baseDir, `proposals/${proposalId}.json`);
  }

  private readBytes(path: string) {
    try { lstatSync(path); }
    catch (error) { if (missing(error)) return null; throw new BridgeError('storage-unavailable'); }
    return readPrivateFile(path, MAX_MEMORY_BYTES);
  }

  get(target: MemoryTarget) { return decode(this.readBytes(this.pathFor(target)) ?? Buffer.alloc(0)); }
  read(target: MemoryTarget) { return parseMemoryMarkdown(this.get(target)); }

  prepare(target: MemoryTarget, candidate: string, previous: string, source: RevisionSource, now = this.now()) {
    this.guard.assertDocument(candidate);
    const current = parseMemoryMarkdown(previous), document = parseMemoryMarkdown(candidate);
    const before = new Map(current.entries.map(entry => [entry.id, entry]));
    for (const entry of document.entries) {
      const old = before.get(entry.id);
      if (!entry.managed && !old) this.guard.assertHandwritten(entry.content);
      else if (entry.managed && old?.content !== entry.content) this.guard.assertEntry(entry.content);
    }
    if (source !== 'manual') {
      const protectedBlocks = (doc: MemoryDocument) => new Map(doc.blocks.filter(block => block.entry?.locked)
        .map(block => [block.entry!.id, block]));
      const after = protectedBlocks(document);
      for (const [id, block] of protectedBlocks(current)) {
        const next = after.get(id);
        // 新增行可为手写末行补换行，但不能更改已有内容。
        if (!next || !isDeepStrictEqual(block.entry, next.entry) || withoutEol(block.raw) !== withoutEol(next.raw)) throw invalid();
      }
    }
    document.entries = document.entries.map(entry => entry.visibility === 'cloud-safe' && !this.guard.allowsCloud(entry.content) &&
      (source === 'manual' || !before.get(entry.id)?.locked)
      ? { ...entry, visibility: 'local-only' } : entry);
    const revision = current.metadata.revision;
    document.metadata = { ...document.metadata, schema: 2,
      ...(target.kind === 'scope' ? {
        scopeType: target.scopeType ?? current.metadata.scopeType ?? 'direct', conversationId: target.conversationId,
        label: target.label ?? current.metadata.label ?? target.conversationId,
      } : {}),
      updatedAt: new Date(now).toISOString(),
      revision: (typeof revision === 'number' && Number.isSafeInteger(revision) && revision >= 0 && revision < Number.MAX_SAFE_INTEGER ? revision : 0) + 1,
    };
    const text = serializeMemoryMarkdown(document);
    this.guard.assertDocument(text);
    return text;
  }

  save(target: MemoryTarget, candidate: string, options: SaveOptions = {}): MemoryRevision {
    const path = this.pathFor(target), previous = this.readBytes(path), text = decode(previous ?? Buffer.alloc(0));
    if (options.expectedText !== undefined && text !== options.expectedText) throw new BridgeError('settings-changed');
    const now = this.now(), source = options.source ?? 'manual';
    const prepared = this.prepare(target, candidate, text, source, now);
    return this.commit(target, path, previous, Buffer.from(prepared), source, options.summary ?? '手动更新记忆', now);
  }

  setEntryLock(target: MemoryTarget, entryId: string, locked: boolean) {
    return this.editEntry(target, entryId, { locked }, '更新记忆锁定状态');
  }

  setEntryVisibility(target: MemoryTarget, entryId: string, visibility: Visibility) {
    return this.editEntry(target, entryId, { visibility }, '更新记忆可见性');
  }

  private editEntry(target: MemoryTarget, entryId: string, values: Partial<MemoryEntry>, summary: string) {
    const text = this.get(target), document = parseMemoryMarkdown(text);
    if (!document.entries.some(entry => entry.managed && entry.id === entryId)) throw invalid();
    document.entries = document.entries.map(entry => entry.id === entryId ? { ...entry, ...values } : entry);
    return this.save(target, serializeMemoryMarkdown(document), { expectedText: text, summary });
  }

  private historyPath(target: MemoryTarget) {
    const relative = target.kind === 'persona' ? 'history/persona' : `history/scopes/${memoryScopeKey(target)}`;
    const path = resolveContainedPath(this.baseDir, relative);
    ensurePrivateDir(path);
    return path;
  }

  rollback(target: MemoryTarget, revId: string): MemoryRevision {
    const revision = this.journal.getMemoryRevision(revId);
    if (!revision || revision.target_kind !== target.kind || revision.scope_key !== memoryScopeKey(target)) throw invalid();
    const name = basename(revision.snapshot_path), history = this.historyPath(target);
    if (snapshotName.exec(name)?.[1] !== revId || join(history, name) !== revision.snapshot_path) throw invalid();
    const bytes = readPrivateFile(resolveContainedPath(history, name), MAX_MEMORY_BYTES);
    const path = this.pathFor(target);
    return this.commit(target, path, this.readBytes(path), bytes, 'rollback', `回滚至 ${revId}`, this.now());
  }

  private commit(target: MemoryTarget, path: string, previous: Buffer | null, next: Buffer,
    source: RevisionSource, summary: string, now: number): MemoryRevision {
    const old = previous ?? Buffer.alloc(0), revId = randomUUID(), history = this.historyPath(target);
    const snapshot = resolveContainedPath(history, `${now}-${revId}.md`);
    const revision: MemoryRevision = {
      rev_id: revId, target_kind: target.kind, scope_key: memoryScopeKey(target), snapshot_path: snapshot, source, summary,
      diff_preview: unifiedDiff(decode(old), decode(next), basename(path), MAX_DIFF_BYTES), created_at: now,
    };
    atomicWritePrivateFile(snapshot, old);
    try {
      atomicWritePrivateFile(path, next);
      this.journal.saveMemoryRevision(revision);
    } catch (error) {
      // 文件和 SQLite 各自原子；索引写入失败时恢复原件，恢复失败则保留快照。
      const actual = this.readBytes(path);
      if (actual?.equals(next)) {
        if (previous === null) unlinkSync(path);
        else atomicWritePrivateFile(path, previous);
      }
      unlinkSync(snapshot);
      throw error;
    }
    for (const obsolete of this.journal.listMemoryRevisions(target.kind, revision.scope_key, 100, MAX_SNAPSHOTS)) {
      const name = basename(obsolete.snapshot_path);
      if (snapshotName.exec(name)?.[1] !== obsolete.rev_id || join(history, name) !== obsolete.snapshot_path) continue;
      const file = resolveContainedPath(history, name);
      try { assertPrivateFile(lstatSync(file)); unlinkSync(file); }
      catch (error) { if (!missing(error)) throw error; }
      this.journal.deleteMemoryRevision(obsolete.rev_id);
    }
    return revision;
  }
}
