import { afterEach, expect, test } from 'bun:test';
import { existsSync, lstatSync, mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { MemoryConsolidator } from '../src/memory/consolidator.ts';
import { PromptContextAssembler } from '../src/memory/context-assembler.ts';
import { MemoryGuard } from '../src/memory/guard.ts';
import { PersonaEvolver } from '../src/memory/persona.ts';
import { MemoryStore, parseMemoryMarkdown, serializeMemoryMarkdown, unifiedDiff } from '../src/memory/store.ts';
import { scopeKeyFor, type ScopeTarget } from '../src/memory/types.ts';
import { atomicWritePrivateFile, readPrivateFile } from '../src/storage/fs-safe.ts';
import { JournalV2 } from '../src/storage/journal-v2.ts';

const now = Date.parse('2026-11-23T12:00:00Z');
const persona = { kind: 'persona' } as const;
const scope: ScopeTarget = { kind: 'scope', accountId: 'account', conversationId: 'friend', scopeType: 'direct', label: '好友' };
const managed = (id: string, text: string, flags = 'vis=cloud-safe locked=false') => `<!-- mem:id=${id} ${flags} -->\n- ${text}\n`;
const cleanup: Array<() => void> = [];
afterEach(() => { while (cleanup.length) cleanup.pop()!(); });

function fixture() {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'wmb-memory-')));
  cleanup.push(() => rmSync(dir, { recursive: true }));
  const journal = new JournalV2(dir);
  cleanup.push(() => journal.close());
  return { dir, journal, store: new MemoryStore(join(dir, 'memory'), journal, () => now) };
}

test('Markdown 往返保留 BOM、CRLF、YAML、手写列表与段落；代码中的条目不是公开记忆', () => {
  const text = '\uFEFF' + [
    '---', 'schema: 2', 'scopeType: direct', 'conversationId: friend', 'label: "好友: 小明" # 留注释',
    'updatedAt: 2026-11-23T10:00:00+08:00', 'revision: 14', '---', '', '## 关系与背景',
    '<!-- mem:id=m_01 vis=cloud-safe locked=false src=auto updated=2026-11-22 expires=2026-12-07 -->',
    '- 喜欢科幻。  ', '', '* 手写列表', '  还有续行。', '', '普通段落。', '', '```md',
    '<!-- mem:id=m_example vis=cloud-safe locked=false -->', '- 只是示例。', '```',
  ].join('\r\n');
  const document = parseMemoryMarkdown(text);
  expect(document.metadata).toMatchObject({ schema: 2, label: '好友: 小明', revision: 14 });
  expect(document.entries.find(entry => entry.id === 'm_01')).toMatchObject({ content: '喜欢科幻。', source: 'auto', updated: '2026-11-22', expires: '2026-12-07' });
  expect(document.entries.filter(entry => entry.managed)).toHaveLength(1);
  expect(document.entries.filter(entry => !entry.managed).every(entry => entry.locked && entry.visibility === 'local-only')).toBe(true);
  expect(document.entries.find(entry => entry.content.includes('普通段落。'))).toBeDefined();
  expect(serializeMemoryMarkdown(document)).toBe(text);
  document.entries.find(entry => entry.id === 'm_01')!.locked = true;
  const modified = serializeMemoryMarkdown(document);
  expect(modified).toContain('id=m_01 vis=cloud-safe locked=true');
  expect(modified).toContain('label: "好友: 小明" # 留注释');
});

test('单条锁定和可见性操作留存快照，只保留最近 50 版', () => {
  const { store, journal } = fixture();
  const first = store.save(scope, '## 偏好与习惯\n' + managed('m_alpha', '喜欢喝茶。') +
    managed('m_beta', '账号密码示例。') + '- 不带注释的手写记忆。\n');
  expect(store.get(scope)).toStartWith('---\nschema: 2\nscopeType: direct\n');
  store.setEntryLock(scope, 'm_alpha', true);
  store.setEntryVisibility(scope, 'm_alpha', 'local-only');
  store.setEntryVisibility(scope, 'm_beta', 'cloud-safe');
  expect(store.read(scope).entries).toMatchObject([{ id: 'm_alpha', locked: true, visibility: 'local-only' },
    { id: 'm_beta', visibility: 'local-only' }, { managed: false, locked: true, visibility: 'local-only' }]);
  for (let n = 0; n < 49; n++) store.setEntryLock(scope, 'm_alpha', n % 2 === 0);
  const revisions = journal.listMemoryRevisions('scope', first.scope_key);
  expect(revisions).toHaveLength(50);
  expect(existsSync(first.snapshot_path)).toBe(false);
  expect(() => store.rollback(scope, first.rev_id)).toThrow('invalid-configuration');
  expect(() => store.rollback(persona, revisions[0]!.rev_id)).toThrow('invalid-configuration');
});

test('大版本变更保留真实 diff，预览限制为 8 KiB', () => {
  const { store } = fixture();
  const previous = Array.from({ length: 130 }, (_, n) => `- 原记忆第 ${n} 条：${'甲'.repeat(50)}`).join('\n');
  const next = Array.from({ length: 130 }, (_, n) => `- 新记忆第 ${n} 条：${'乙'.repeat(50)}`).join('\n');
  store.save(scope, previous);
  const revision = store.save(scope, next);
  expect(Buffer.byteLength(revision.diff_preview)).toBeLessThanOrEqual(8 * 1024);
  expect(revision.diff_preview).toContain('-- 原记忆第 0 条');
  expect(revision.diff_preview).toContain('+- 新记忆第 0 条');
  expect(unifiedDiff('起始\n分开\n旧末行', '起始\n分开\n新末行\n', 'persona.md')).toBe(
    '--- a/persona.md\n+++ b/persona.md\n@@ -1,3 +1,3 @@\n 起始\n 分开\n-旧末行\n\\ No newline at end of file\n+新末行\n');
});

test('连续更新后可按原始字节双向回滚，并写入实际 diff', () => {
  const { store, journal } = fixture();
  const file = store.pathFor(scope);
  const original = Buffer.from('\uFEFF---\r\nschema: 2\r\nrevision: 7\r\n---\r\n\r\n## 偏好与习惯\r\n- 手写。  ');
  atomicWritePrivateFile(file, original);
  const versions = Array.from({ length: 5 }, (_, index) => store.save(scope, `## 偏好与习惯\n- 版本 ${index}\n`));
  const beforeRollback = readPrivateFile(file);
  expect(versions[0]!.diff_preview).toContain('-' + '- 手写。  ');
  expect(versions[0]!.diff_preview).toContain('+' + '- 版本 0');
  expect(lstatSync(versions[0]!.snapshot_path).mode & 0o777).toBe(0o600);
  const rollback = store.rollback(scope, versions[0]!.rev_id);
  expect(rollback.source).toBe('rollback');
  expect(readPrivateFile(file).equals(original)).toBe(true);
  store.rollback(scope, rollback.rev_id);
  expect(readPrivateFile(file).equals(beforeRollback)).toBe(true);
  expect(journal.listMemoryRevisions('scope', scopeKeyFor(scope.accountId, scope.conversationId))).toHaveLength(7);
});

test('守卫保护锁定项，敏感内容降级，并拒绝控制字符和长度超限', () => {
  const guard = new MemoryGuard();
  const initial = parseMemoryMarkdown('## 偏好与习惯\n' + managed('m_lock', '喜欢喝茶。', 'vis=cloud-safe locked=true') + '- 手写偏好。\n');
  const privateText = ['手机号 13800138000', '6222 0212 3456 7890', '朝阳区幸福路 19 号', '预算 123.45 元', '复诊病历', '验证码 721004', '身份证 11010519491231002X'];
  const result = guard.applyPatch(initial.entries, [
    { op: 'update', entryId: 'm_lock', content: '改口喝咖啡', suggestedVisibility: 'cloud-safe' },
    { op: 'archive', entryId: 'm_lock', reason: '不应删除' },
    { op: 'archive', entryId: initial.entries[1]!.id, reason: '不应删除' },
    ...privateText.map(content => ({ op: 'add' as const, section: '偏好与习惯', content, suggestedVisibility: 'cloud-safe' as const })),
  ], { target: scope, source: 'auto', now });
  expect(result.slice(0, 2)).toEqual(initial.entries);
  expect(result.slice(2).map(entry => [entry.content, entry.visibility])).toEqual(privateText.map(text => [text, 'local-only']));
  expect(() => guard.assertEntry('合规开头\u202E伪造方向')).toThrow('invalid-configuration');
  expect(() => guard.assertEntry('字'.repeat(201))).toThrow('invalid-configuration');
  expect(() => guard.assertDocument('字'.repeat(16_385))).toThrow('invalid-configuration');
});

test('云端组装无私有或过期记忆；兼容两个外部档案且拒绝代码块和重复标记', async () => {
  const { store, dir } = fixture();
  const guard = new MemoryGuard();
  const document = parseMemoryMarkdown(managed('m_safe', '喜欢徒步。') +
    managed('m_expired', '旧活动。', 'vis=cloud-safe locked=false expires=2020-01-01') + '- 手写私有事实。\n');
  const sensitive = '13800138000';
  document.entries = guard.applyPatch(document.entries, [
    { op: 'add', section: '偏好与习惯', content: `手机号 ${sensitive}`, suggestedVisibility: 'cloud-safe' },
  ], { target: scope, source: 'auto', now });
  store.save(scope, serializeMemoryMarkdown(document), { source: 'auto' });
  store.save(persona, managed('p_public', '说话简短自然。') + managed('p_private', '人格私有配置。', 'vis=local-only locked=false'));
  const stylePath = join(dir, 'style-old.md'), memoryPath = join(dir, 'memory-old.md');
  const legacy = (body: string) => `未批准内容\n<!-- bridge-cloud:start -->\n${body}\n<!-- bridge-cloud:end -->\n`;
  atomicWritePrivateFile(stylePath, legacy('旧式已批准风格。'));
  atomicWritePrivateFile(memoryPath, legacy('旧式已批准记忆。'));
  const assembler = new PromptContextAssembler(store, () => now);
  const request = { mode: 'cloud' as const, target: scope, legacyStylePath: stylePath, legacyMemoryPath: memoryPath, workingMaxMessages: 1,
    working: [{ text: '较早消息', createdAt: now - 1, from: 'peer' as const }, { text: '有效最新消息', createdAt: now, from: 'self' as const },
      { text: '已撤回消息', from: 'peer' as const, recalled: true, createdAt: now }] };
  const result = await assembler.assemble(request);
  const payload = JSON.stringify(result);
  for (const text of [sensitive, '旧活动', '手写私有', '人格私有', '未批准内容', '已撤回消息', '较早消息']) expect(payload.split(text).length - 1).toBe(0);
  expect(result.style).toContain('说话简短自然。');
  expect(result.style).toContain('旧式已批准风格。');
  expect(result.memory).toContain('喜欢徒步。');
  expect(result.memory).toContain('旧式已批准记忆。');
  expect(result.context).toEqual([{ from: 'self', text: '有效最新消息' }]);
  atomicWritePrivateFile(stylePath, `\`\`\`md\n${legacy('不是授权。')}\`\`\`\n`);
  await expect(assembler.assemble(request)).rejects.toThrow('cloud-profile');
  atomicWritePrivateFile(stylePath, legacy('有效单独标记。'));
  atomicWritePrivateFile(memoryPath, legacy('看起来有效。') + '<!-- bridge-cloud:start -->');
  await expect(assembler.assemble(request)).rejects.toThrow('cloud-profile');
});

const message = (id: string, text: string, extra = {}) => ({ eventId: `event-${id}`, messageRef: id, text, isSelf: false, createdAt: now, ...extra });

test('整理历史时过滤撤回、消解冲突、归档过期、保留手写原文并写入动态和整理水位', async () => {
  const { store, journal } = fixture();
  const handwritten = '- 这是我的手写偏好。  \n以上请勿修改。';
  store.save(scope, '## 偏好与习惯\n' + managed('m_color', '喜欢红色。') + managed('m_old', '待参加音乐节。',
    'vis=cloud-safe locked=false expires=2020-01-01') + managed('m_locked', '本人确认过的条目。', 'vis=cloud-safe locked=true') + handwritten);
  const hidden = store.read(scope).entries.find(entry => entry.content.includes('手写偏好'))!;
  const prompts: string[] = [];
  const consolidator = new MemoryConsolidator({ store, journal, now: () => now, completeJson: async (_system, user) => {
    prompts.push(user);
    return JSON.stringify({ summary: '偏好从红色改为蓝色', operations: [
      { op: 'add', section: '偏好与习惯', content: '喜欢蓝色。', suggestedVisibility: 'cloud-safe' },
      { op: 'update', entryId: 'm_color', content: '喜欢蓝色。', suggestedVisibility: 'cloud-safe' },
      { op: 'archive', entryId: 'm_locked', reason: '不允许' },
      { op: 'archive', entryId: hidden.id, reason: '不允许' },
    ] });
  } });
  cleanup.push(() => consolidator.dispose());
  const revision = await consolidator.initializeFromHistory(scope, [message('A', '更喜欢蓝色。'),
    message('B', '不得学习的已撤内容一', { recalled: true }), message('C', '不得学习的已撤内容二'),
    message('recall', '', { kind: 'recall', recallTargetRef: 'C' })]);
  expect(prompts).toHaveLength(1);
  expect(prompts[0]).toContain('更喜欢蓝色。');
  expect(prompts[0]).not.toContain('不得学习');
  expect(store.get(scope)).toContain(handwritten);
  expect(store.read(scope).entries.map(entry => entry.content)).toEqual(['喜欢蓝色。', '本人确认过的条目。', '这是我的手写偏好。  ', '以上请勿修改。']);
  expect(store.read(scope).entries[0]?.id).toBe('m_color');
  expect(revision).toMatchObject({ source: 'backfill' });
  expect(journal.getMemoryRevision(revision!.rev_id)).toEqual(revision);
  expect(journal.listFeedItems()).toMatchObject([{ kind: 'memory_updated', ref_path: revision!.rev_id, conversation_id: scope.conversationId }]);
  expect(journal.getMemoryWatermark(revision!.scope_key)).toMatchObject({ pending_turns: 0, last_consolidated_at: now });
});

test('模型补丁不合规范不会写入，推理期间新撤回的消息也不会落盘', async () => {
  const { store, journal } = fixture();
  let respond!: (value: string) => void;
  const worker = new MemoryConsolidator({ store, journal, now: () => now, completeJson: () => new Promise(resolve => { respond = resolve; }) });
  cleanup.push(() => worker.dispose());
  worker.ingest(scope, message('A', '待撤回的消息。'));
  const first = worker.consolidateNow(scope);
  respond(JSON.stringify({ summary: '不支持', operations: [{ op: 'supersede', entryId: 'm_001' }] }));
  await expect(first).rejects.toThrow('model-format');
  expect(store.get(scope)).toBe('');
  const second = worker.consolidateNow(scope);
  worker.ingest(scope, message('recall', '', { kind: 'recall', recallTargetRef: 'A' }));
  respond(JSON.stringify({ summary: '不该写入', operations: [{ op: 'add', section: '偏好与习惯', content: '待撤回的消息。', suggestedVisibility: 'cloud-safe' }] }));
  await expect(second).resolves.toBeNull();
  expect(store.get(scope)).toBe('');
  expect(journal.listFeedItems()).toHaveLength(0);
});

test.each(['turn', 'idle'] as const)('整理器可按 %s 自动触发', async trigger => {
  const { store, journal } = fixture();
  const { promise: started, resolve } = Promise.withResolvers<void>();
  const worker = new MemoryConsolidator({ store, journal, now: () => now, autoConsolidateTurnThreshold: 2,
    autoConsolidateIdleMinutes: trigger === 'turn' ? 10 : 0.0001, completeJson: async () => {
      resolve();
      return JSON.stringify({ summary: '自动触发', operations: [{ op: 'add', section: '偏好与习惯', content: '喜欢徒步。', suggestedVisibility: 'cloud-safe' }] });
    } });
  cleanup.push(() => worker.dispose());
  worker.recordTurn(scope, [message('1', '第一轮上句。'), message('2', '第一轮下句。')]);
  expect(journal.getMemoryWatermark(scopeKeyFor(scope.accountId, scope.conversationId))?.pending_turns).toBe(1);
  if (trigger === 'turn') worker.recordTurn(scope, [message('3', '第二轮发言。')]);
  await started;
  await worker.consolidateNow(scope);
  expect(store.read(scope).entries.map(entry => entry.content)).toEqual(['喜欢徒步。']);
});

test('人格只采本人真消息和草稿修正；完整 Diff 支持采纳、编辑采纳和驳回', async () => {
  const { store, journal } = fixture();
  store.save(persona, '## 表达风格\n' + managed('p_locked', '说话自然。', 'vis=cloud-safe locked=true'));
  const peer = scopeKeyFor(scope.accountId, scope.conversationId);
  const ids = { accountId: scope.accountId, conversationId: scope.conversationId, identity: 'login', kind: 'text' as const };
  journal.reserve('our-request', peer, 'route', ids.identity, 'auto', now);
  journal.complete('our-request', { status: 'submitted', delivery: 'delivered', ref: 'ai-ref' });
  const prompts: string[] = [];
  const evolver = new PersonaEvolver({ store, journal, now: () => now, completeJson: async (_system, prompt) => {
    prompts.push(prompt);
    return JSON.stringify({ summary: '提议新的语气', operations: [
      { op: 'archive', entryId: 'p_locked', reason: '不允许' },
      { op: 'add', section: '从本人发言习得的习惯', content: `习惯表达第 ${prompts.length} 种语气。`, suggestedVisibility: 'cloud-safe' },
    ] });
  } });
  cleanup.push(() => evolver.dispose());
  expect(evolver.ingestSample({ ...message('ai-ref', '不得学习的 AI 原文'), ...ids, isSelf: true })).toBe(false);
  expect(evolver.ingestSample({ ...message('peer-ref', '不得学习的对方消息'), ...ids })).toBe(false);
  expect(evolver.ingestSample({ ...message('unknown', '未校验发送来源'), ...ids, identity: undefined, isSelf: true })).toBe(false);
  expect(evolver.ingestSample({ ...message('self-1', '本人手打内容。'), ...ids, isSelf: true })).toBe(true);
  expect(evolver.ingestSample({ kind: 'draft_correction', draftText: '不得学习的 AI 草稿', correctedText: '我手工替换的话。' })).toBe(true);
  const first = (await evolver.proposeNow())!;
  const proposal = evolver.getProposal(first.proposal_id);
  expect(prompts[0]).toContain('本人手打内容。');
  expect(prompts[0]).toContain('我手工替换的话。');
  expect(prompts[0]).not.toContain('不得学习');
  expect(first).toMatchObject({ status: 'pending', sample_count: 2 });
  expect(proposal.diff).toStartWith('--- a/persona.md\n+++ b/persona.md\n@@ ');
  expect(proposal.diff).toContain('+- 习惯表达第 1 种语气。');
  expect(lstatSync(first.file_path).mode & 0o777).toBe(0o600);
  expect(journal.getFeedItem(first.proposal_id)).toMatchObject({ kind: 'persona_proposal', read: 0 });
  expect(store.get(persona)).not.toContain('习惯表达');
  expect(evolver.decide(first.proposal_id, 'accept').status).toBe('accepted');
  expect(store.get(persona)).toContain('习惯表达第 1 种语气。');
  expect(journal.getFeedItem(first.proposal_id)?.read).toBe(1);

  evolver.ingestSample({ ...message('self-2', '另一条真实样本。'), ...ids, isSelf: true });
  const second = (await evolver.proposeNow())!;
  const draft = evolver.getProposal(second.proposal_id).proposedContent;
  expect(() => evolver.decide(second.proposal_id, 'accept_edited', draft.replace('说话自然。', '改了锁定内容。'))).toThrow('invalid-configuration');
  expect(evolver.decide(second.proposal_id, 'accept_edited', draft.replace('习惯表达第 2 种语气。', '人工编辑后的风格。')).status).toBe('accepted');
  expect(store.get(persona)).toContain('人工编辑后的风格。');
  expect(store.get(persona)).not.toContain('习惯表达第 2 种语气。');

  evolver.ingestSample({ ...message('self-3', '第三条真实样本。'), ...ids, isSelf: true });
  const third = (await evolver.proposeNow())!;
  const beforeReject = store.get(persona);
  expect(evolver.decide(third.proposal_id, 'reject').status).toBe('rejected');
  expect(store.get(persona)).toBe(beforeReject);
});

test('人格自动合并遵守锁定和隐私守卫，并可字节级回滚', async () => {
  const { store, journal } = fixture();
  store.save(persona, '## 表达风格\n' + managed('p_locked', '简洁直白。', 'vis=cloud-safe locked=true'));
  const path = store.pathFor(persona), original = readPrivateFile(path);
  const { promise: started, resolve } = Promise.withResolvers<void>();
  const evolver = new PersonaEvolver({ store, journal, autoMergePersona: true, sampleThreshold: 1, now: () => now, completeJson: async () => {
    resolve();
    return JSON.stringify({ summary: '低风险微调', operations: [
      { op: 'update', entryId: 'p_locked', content: '改写锁定内容。', suggestedVisibility: 'cloud-safe' },
      { op: 'add', section: '表达风格', content: '病历放在家里。', suggestedVisibility: 'cloud-safe' },
    ] });
  } });
  cleanup.push(() => evolver.dispose());
  evolver.ingestSample({ kind: 'draft_correction', draftText: '旧草稿', correctedText: '手工改过的草稿' });
  await started;
  const proposal = (await evolver.proposeNow())!;
  expect(proposal.status).toBe('accepted');
  expect(journal.listPersonaProposals('pending')).toHaveLength(0);
  expect(journal.listFeedItems()).toHaveLength(0);
  const entries = store.read(persona).entries;
  expect(entries.find(entry => entry.id === 'p_locked')?.content).toBe('简洁直白。');
  expect(entries.find(entry => entry.content === '病历放在家里。')?.visibility).toBe('local-only');
  const rev = journal.listMemoryRevisions('persona', 'global')[0]!;
  expect(rev.source).toBe('proposal_accepted');
  store.rollback(persona, rev.rev_id);
  expect(readPrivateFile(path).equals(original)).toBe(true);
});

test('人格提案不会覆盖生成后的人格编辑', async () => {
  const { store, journal } = fixture();
  const evolver = new PersonaEvolver({ store, journal, now: () => now, completeJson: async () =>
    JSON.stringify({ summary: '提案', operations: [{ op: 'add', section: '表达风格', content: '语气放松。', suggestedVisibility: 'cloud-safe' }] }) });
  cleanup.push(() => evolver.dispose());
  evolver.ingestSample({ kind: 'draft_correction', draftText: '旧草稿', correctedText: '手工改过的草稿' });
  const proposal = (await evolver.proposeNow())!;
  store.save(persona, '- 人工独立保存的段落。\n');
  expect(evolver.decide(proposal.proposal_id, 'accept').status).toBe('superseded');
  expect(store.get(persona)).toContain('人工独立保存的段落。');
  expect(store.get(persona)).not.toContain('语气放松。');
});
