import { Database } from 'bun:sqlite';
import { expect, test } from 'bun:test';
import { chmodSync, lstatSync, mkdtempSync, readdirSync, realpathSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { sha, tomorrow } from '../contracts.ts';
import { Journal } from '../journal.ts';
import { BridgeError, errorCode, isErrorCode } from '../src/contracts/errors.ts';
import { backfillRequestSchema, normalizedEventSchema, xiaoheAccountSchema, xiaoheEventSchema } from '../src/contracts/events.ts';
import { MAX_FRAME_BYTES, PUSH_TOPICS, RPC_METHODS, pushFrameSchema, rpcReplySchema, rpcRequestSchema } from '../src/contracts/ipc.ts';
import { declarativePluginConfigSchema, groupDigestOutputSchema, pluginManifestSchema } from '../src/contracts/plugins.ts';
import { loadSettingsV2, loadSettingsV2FromDisk, migrateSettingsV1ToV2, settingsV2Schema } from '../src/contracts/settings.ts';
import { atomicWritePrivateFile, ensurePrivateDir, readPrivateFile, resolveContainedPath } from '../src/storage/fs-safe.ts';
import { JournalV2, type FeedItem, type MemoryRevision, type PersonaProposal } from '../src/storage/journal-v2.ts';
import { syntheticText } from './fixture.ts';

function tempDir() {
  return realpathSync(mkdtempSync(join(tmpdir(), 'wmb-storage-v2-')));
}

const legacy = {
  mcp: 'http://127.0.0.1:21454/mcp', account: 'account-1', accountLabel: '测试账号',
  contact: { id: 'friend-alias', label: '联系人' }, mode: 'cloud',
  modelURL: 'https://model.example.invalid/proxy/v1/', modelName: 'fixture',
  stylePath: '/local/style.md', memoryPath: '/local/memory.md', autoReply: true,
};

test('旧配置保留会话、完整模型端点和档案路径，自动发送复位', () => {
  const settings = migrateSettingsV1ToV2(legacy);
  expect(settings).toMatchObject({
    schemaVersion: 2,
    xiaohe: { mcpUrl: legacy.mcp, accountId: legacy.account, accountLabel: legacy.accountLabel, hasAuthToken: false },
    models: [{ id: 'preset-legacy-default', mode: 'cloud', kind: 'chat', modelName: 'fixture',
      url: 'https://model.example.invalid/proxy/v1/chat/completions', maxTokens: 320, temperature: 0.35 }],
    defaultModels: { replyPresetId: 'preset-legacy-default' },
    conversations: { 'friend-alias': { label: '联系人', type: 'direct', replyMode: 'off', memoryEnabled: true } },
    memory: { legacyStylePath: legacy.stylePath, legacyMemoryPath: legacy.memoryPath, workingMaxMessages: 16, workingTtlMinutes: 30 },
  });
  settings.conversations['friend-alias']!.replyMode = 'auto';
  expect(loadSettingsV2(settings).conversations['friend-alias']?.replyMode).toBe('off');
  expect(settings.conversations['friend-alias']?.replyMode).toBe('auto');
  expect(migrateSettingsV1ToV2({ contact: null }).models).toEqual([]);
  const group = { conversationId: '123@chatroom', type: 'group', label: '群聊', enabled: true, replyMode: 'draft' };
  const service = { ...group, conversationId: 'gh_test', type: 'service' };
  const converted = loadSettingsV2({ ...settings, conversations: { [group.conversationId]: group, gh_test: service } });
  expect(converted.conversations['123@chatroom']).toMatchObject({ memoryEnabled: false, groupTrigger: 'mention_only', replyMode: 'draft' });
  expect(converted.conversations.gh_test?.memoryEnabled).toBe(false);
  expect(settingsV2Schema.safeParse({ ...settings, xiaohe: { ...settings.xiaohe, authToken: 'secret' } }).success).toBe(false);
  expect(settingsV2Schema.safeParse({ ...settings, openChamber: {} }).success).toBe(false);
  expect(settingsV2Schema.safeParse({ ...settings, conversations: { mismatched: group } }).success).toBe(false);
});

test('磁盘配置迁移先保存旧文件原始字节，重启时保留备份', () => {
  const dir = tempDir();
  try {
    expect(loadSettingsV2FromDisk(dir).xiaohe.accountId).toBe('');
    const settingsFile = join(dir, 'settings.json');
    const backup = join(dir, 'settings.v1.bak.json');
    const original = JSON.stringify(legacy, null, 2) + '\n';
    atomicWritePrivateFile(settingsFile, original);
    atomicWritePrivateFile(backup, 'previous backup');
    expect(() => loadSettingsV2FromDisk(dir)).toThrow('storage-unavailable');
    expect(readPrivateFile(settingsFile).toString()).toBe(original);
    atomicWritePrivateFile(backup, original);
    const settings = loadSettingsV2FromDisk(dir);
    expect(loadSettingsV2FromDisk(dir)).toEqual(settings);
    expect(JSON.parse(readPrivateFile(settingsFile).toString()).schemaVersion).toBe(2);
    expect(readPrivateFile(backup).toString()).toBe(original);
    rmSync(backup);
    atomicWritePrivateFile(settingsFile, original);
    expect(loadSettingsV2FromDisk(dir)).toEqual(settings);
    expect(readPrivateFile(backup).toString()).toBe(original);
    expect(lstatSync(backup).mode & 0o777).toBe(0o600);
  } finally { rmSync(dir, { recursive: true }); }
});

test('真实 v0.2.1 SQLite 原地迁移并重复开启，保留退订、去重和未知回执', () => {
  const dir = tempDir();
  const now = Date.now();
  const old = new Journal(dir);
  old.advance('route', 'identity', 'cursor-v1', ['kept-event'], now);
  old.optOut('stopped-peer');
  old.beginDrain('route', now - 100);
  old.reserve('trying-v1', 'peer-a', 'route', 'identity', 'auto', now - 35 * 86_400_000);
  old.reserve('unknown-v1', 'peer-b', 'route', 'identity', 'active', now);
  old.complete('unknown-v1', { status: 'unknown', delivery: 'unknown', operation: 'op-v1' });
  old.addTiming('peer-a', now, { ingest: 1, batch: 2, model: 3, rpc: 4, total: 10 });
  old.close();
  try {
    for (let i = 0; i < 2; i++) {
      const db = new JournalV2(dir);
      try {
        expect(db.read('route')).toMatchObject({ identity: 'identity', cursor: 'cursor-v1', scope_kind: 'conversation', updated_at: 0 });
        expect(db.beginDrain('route', now)).toBe(now - 100);
        expect(db.known('route', 'kept-event')).toBe(true);
        expect(db.statistics('peer-a')).toMatchObject({ count: 1, total: { p50: 10, p95: 10 } });
        expect(db.optedOut('stopped-peer')).toBe(true);
        expect(db.uncertain('peer-a')).toMatchObject({ id: 'trying-v1', status: 'unknown', plugin_id: null });
        expect(db.latest('peer-b')).toMatchObject({ id: 'unknown-v1', operation: 'op-v1' });
        expect(() => db.reserve('next', 'peer-a', 'route', 'new-identity', 'plugin', now, { pluginId: 'digest' })).toThrow('send-unknown');
        expect(() => db.reserve('next', 'stopped-peer', 'route', 'identity', 'active', now)).toThrow('peer-stopped');
        expect(() => new JournalV2(dir)).toThrow('storage-in-use');
      } finally { db.close(); }
    }
    const sqlite = new Database(join(dir, 'bridge.sqlite'));
    try {
      expect(sqlite.query("SELECT value FROM schema_meta WHERE key='version'").get()).toEqual({ value: '2' });
      expect(sqlite.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").values().flat())
        .toEqual(['attempts', 'cursors', 'events', 'feed_items', 'memory_revisions', 'memory_watermarks', 'opted_out',
          'pending_drains', 'persona_proposals', 'plugin_buffers', 'plugin_runs', 'plugin_state', 'schema_meta', 'timings', 'turn_metrics']);
      sqlite.run("UPDATE schema_meta SET value='3' WHERE key='version'");
    } finally { sqlite.close(); }
    expect(() => new JournalV2(dir)).toThrow('storage-unavailable');
  } finally { rmSync(dir, { recursive: true }); }
});

test('事件撤回与缓冲区撤回按会话隔离，flush 清理旧水位并保留新消息', () => {
  const dir = tempDir();
  const db = new JournalV2(dir);
  try {
    db.markRecalled('route-a', 'ref-hash', 1);
    db.advance('route-a', 'identity', 'cursor', ['ref-hash'], 2, undefined, { scope_kind: 'account' });
    db.advance('route-a', 'identity', 'cursor2', [], 3);
    expect(db.read('route-a')).toMatchObject({ scope_kind: 'account', conversation_id: null, updated_at: 3 });
    expect(db.isRecalled('route-a', 'ref-hash')).toBe(true);
    expect(db.isRecalled('route-b', 'ref-hash')).toBe(false);
    db.holdRead('route-a', 'identity', 'backlog-limit', undefined, 4);
    db.resetRead('route-a');
    expect(db.read('route-a')).toMatchObject({ cursor: 'cursor2', fault: null, updated_at: 4 });
    db.holdRead('route-b', 'identity', 'event-gap');
    db.resetRead('route-b');
    expect(db.read('route-b')).toBeNull();
    db.advance('route-a', 'identity', 'cursor3', [], 5, 'stopped-peer');
    expect(db.optedOut('stopped-peer')).toBe(true);
    db.restoreConsent('stopped-peer');
    expect(db.optedOut('stopped-peer')).toBe(false);
    const item = { plugin_id: 'digest', conversation_id: 'chat-a', event_id: 'event-a', message_ref: 'same-ref',
      sender_label: '成员', is_self: 0, kind: 'text', content: '测试内容', created_at: 1 } as const;
    expect(db.addPluginBuffer(item)).toBe(true);
    expect(db.addPluginBuffer(item)).toBe(false);
    db.addPluginBuffer({ ...item, plugin_id: 'other' });
    db.addPluginBuffer({ ...item, conversation_id: 'chat-b', event_id: 'event-b' });
    expect(db.markPluginBufferRecalled('chat-a', 'same-ref')).toBe(2);
    const snapshot = db.snapshotPluginBuffers('digest');
    expect(snapshot.items.map(row => row.event_id)).toEqual(['event-b']);
    db.addPluginBuffer({ ...item, event_id: 'event-c', message_ref: 'new-ref' });
    db.clearPluginBuffers('digest', snapshot.throughId);
    expect(db.flushPluginBuffers('digest').map(row => row.event_id)).toEqual(['event-c']);
    expect(db.flushPluginBuffers('other')).toEqual([]);
    expect(db.snapshotPluginBuffers('digest')).toEqual({ items: [], throughId: 0 });
    expect(db.snapshotPluginBuffers('other')).toEqual({ items: [], throughId: 0 });
  } finally { db.close(); rmSync(dir, { recursive: true }); }
});

test('插件尝试跨会话去重和计额，未知尝试阻止同一会话其他发信来源', () => {
  const dir = tempDir();
  const db = new JournalV2(dir);
  try {
    const now = Date.now();
    const options = { pluginId: 'digest', dailyLimit: 1 };
    db.reserve('send-1', 'peer-a', 'route', 'identity', 'plugin', now, options);
    expect(db.get('send-1')).toMatchObject({ kind: 'plugin', plugin_id: 'digest', status: 'trying' });
    expect(() => db.reserve('send-2', 'peer-a', 'route', 'identity', 'auto', now)).toThrow('send-unknown');
    db.complete('send-1', { status: 'unknown', delivery: 'unknown', operation: 'operation' });
    expect(() => db.reserve('send-2', 'peer-a', 'route', 'identity', 'active', now)).toThrow('send-unknown');
    db.acknowledge('send-1');
    expect(db.uncertain('peer-a')).toBeNull();
    expect(() => db.reserve('send-1', 'peer-b', 'route', 'identity', 'plugin', now, options)).toThrow('duplicate-attempt');
    expect(() => db.reserve('send-2', 'peer-b', 'route', 'identity', 'plugin', now, options)).toThrow('plugin-limit');
    expect(() => db.reserve('send-2', 'peer-b', 'route', 'identity', 'plugin', now)).toThrow('invalid-configuration');
    db.reserve('send-2', 'peer-b', 'route', 'identity', 'plugin', now, { pluginId: 'independent', dailyLimit: 1 });
    db.complete('send-2', { status: 'submitted', delivery: 'delivered', ref: 'sent-ref' });
    expect(db.own('peer-b', 'identity', undefined, 'sent-ref')).toBe(true);
    expect(db.get('send-2')?.ref_hash).toBe(sha('sent-ref'));
    db.reserve('send-3', 'peer-b', 'route', 'identity', 'plugin', tomorrow(now), options);
    for (let i = 0; i < 12; i++) {
      db.reserve(`active-${i}`, 'peer-a', 'route', 'identity', 'active', now);
      db.complete(`active-${i}`, { status: 'submitted', delivery: 'delivered' });
    }
    expect(() => db.reserve('active-12', 'peer-a', 'route', 'identity', 'active', now)).toThrow('active-limit');
  } finally { db.close(); rmSync(dir, { recursive: true }); }
});

test('插件状态、历史、动态和记忆索引支持增查改删', () => {
  const dir = tempDir();
  const db = new JournalV2(dir);
  try {
    db.savePluginState({ plugin_id: 'p', kind: 'module', enabled: 1, approved_permissions: ['read_events'],
      manifest_hash: 'hash', consecutive_failures: 0, circuit_open: 0, last_run_at: null, last_error: null });
    expect(db.getPluginState('p')?.approved_permissions).toEqual(['read_events']);
    db.deletePluginState('p');
    expect(db.getPluginState('p')).toBeNull();

    const run = { run_id: 'run', plugin_id: 'p', trigger_kind: 'manual', started_at: 1, finished_at: null,
      status: 'running', item_count: 0, summary_preview: null, output_paths: null, error_code: null } as const;
    db.savePluginRun(run);
    db.savePluginRun({ ...run, finished_at: 2, status: 'ok', output_paths: ['/output.md'] });
    expect(db.listPluginRuns('p')).toMatchObject([{ status: 'ok', output_paths: ['/output.md'] }]);

    const feed: FeedItem = { id: 'item', kind: 'plugin_digest', title: '标题', body: '摘要', plugin_id: 'p',
      conversation_id: null, ref_path: null, created_at: 1, read: 0 };
    db.saveFeedItem(feed);
    expect(db.getFeedItem('item')).toEqual(feed);
    expect(db.listFeedItems(1, 0, true)).toEqual([feed]);
    db.markFeedRead(['item']);
    db.saveFeedItem({ ...feed, title: '新标题' });
    expect(db.getFeedItem('item')).toMatchObject({ title: '新标题', read: 1 });
    expect(db.listFeedItems(1, 0, true)).toEqual([]);
    db.deleteFeedItem('item');
    expect(db.getFeedItem('item')).toBeNull();

    const revision: MemoryRevision = { rev_id: 'rev', target_kind: 'persona', scope_key: 'global', snapshot_path: '/snapshot.md',
      source: 'manual', summary: '摘要', diff_preview: '', created_at: 1 };
    db.saveMemoryRevision(revision);
    db.saveMemoryRevision({ ...revision, summary: '新摘要' });
    expect(db.getMemoryRevision('rev')?.summary).toBe('新摘要');
    expect(db.listMemoryRevisions('persona', 'global')).toHaveLength(1);
    db.deleteMemoryRevision('rev');
    expect(db.getMemoryRevision('rev')).toBeNull();

    const proposal: PersonaProposal = { proposal_id: 'proposal', status: 'pending', file_path: '/proposal.json',
      sample_count: 25, summary: '建议', created_at: 1, decided_at: null };
    db.savePersonaProposal(proposal);
    db.savePersonaProposal({ ...proposal, summary: '新建议' });
    expect(db.listPersonaProposals('pending')).toMatchObject([{ summary: '新建议' }]);
    expect(db.decidePersonaProposal('proposal', 'accepted', 100)).toBe(true);
    expect(db.decidePersonaProposal('proposal', 'rejected', 101)).toBe(false);
    expect(db.getPersonaProposal('proposal')).toMatchObject({ status: 'accepted', decided_at: 100 });
    db.deletePersonaProposal('proposal');
    expect(db.getPersonaProposal('proposal')).toBeNull();

    const watermark = { scope_key: 's', last_event_at: 1, pending_turns: 9, last_consolidated_at: 0 };
    db.saveMemoryWatermark(watermark);
    expect(db.getMemoryWatermark('s')).toEqual(watermark);
    db.saveMemoryWatermark({ ...watermark, pending_turns: 0, last_consolidated_at: 2 });
    expect(db.getMemoryWatermark('s')).toMatchObject({ pending_turns: 0, last_consolidated_at: 2 });
    db.deleteMemoryWatermark('s');
    expect(db.getMemoryWatermark('s')).toBeNull();
  } finally { db.close(); rmSync(dir, { recursive: true }); }
});

test('私有文件原子替换，并拒绝超限、宽松权限、符号链接和越界路径', () => {
  const root = tempDir();
  try {
    const dir = join(root, 'private');
    ensurePrivateDir(dir);
    ensurePrivateDir(dir);
    expect(lstatSync(dir).mode & 0o777).toBe(0o700);
    const file = resolveContainedPath(root, 'private/settings.json');
    atomicWritePrivateFile(file, 'old');
    const oldInode = lstatSync(file).ino;
    atomicWritePrivateFile(file, Buffer.from('new bytes'));
    expect(lstatSync(file).ino).not.toBe(oldInode);
    expect(lstatSync(file).mode & 0o777).toBe(0o600);
    expect(readPrivateFile(file, 9).toString()).toBe('new bytes');
    expect(readdirSync(dir)).toEqual(['settings.json']);
    expect(() => readPrivateFile(file, 8)).toThrow('storage-unavailable');
    const symlink = join(dir, 'linked.json');
    symlinkSync(file, symlink);
    expect(() => readPrivateFile(symlink)).toThrow('storage-unavailable');
    expect(() => atomicWritePrivateFile(symlink, 'overwrite')).toThrow('storage-unavailable');
    symlinkSync(dir, join(root, 'linked-dir'));
    expect(() => ensurePrivateDir(join(root, 'linked-dir') + '/.')).toThrow('storage-unavailable');
    for (const path of ['../outside', 'private/../outside', file, 'linked-dir/new.md', 'private/linked.json', 'private\\..\\outside']) {
      expect(() => resolveContainedPath(root, path)).toThrow('storage-unavailable');
    }
    chmodSync(file, 0o644);
    expect(() => readPrivateFile(file)).toThrow('storage-unavailable');
    expect(() => atomicWritePrivateFile(file, 'overwrite')).toThrow('storage-unavailable');
    chmodSync(dir, 0o755);
    expect(() => ensurePrivateDir(dir)).toThrow('storage-unavailable');
  } finally { rmSync(root, { recursive: true }); }
});

test('事件、插件与 IPC v3 契约保留实际字段并验证方法对应载荷', () => {
  expect(isErrorCode('send-unknown')).toBe(true);
  expect(errorCode(new BridgeError('plugin-limit'))).toBe('plugin-limit');
  expect(errorCode(new BridgeError('synthetic-detail'))).toBe('internal-error');
  expect(errorCode(new Error('synthetic-detail'))).toBe('internal-error');
  const event = xiaoheEventSchema.parse({
    event_id: 'event', event_type: 'message.saved', message_ref: 'ref', conversation_id: 'friend-alias', sender_id: 'friend-alias',
    sender_name: '成员', is_self: false, type: 'app', text: '', attachments: [{ media_ref: 'media' }],
    attachment_status: 'ready', reply_status: 'available', created_at_seconds: 123, observed_at: '2026-11-23T10:00:00Z',
  });
  expect(event).toMatchObject({ sender_name: '成员', attachments: [{ media_ref: 'media' }], attachment_status: 'ready',
    reply_status: 'available', created_at_seconds: 123 });
  expect(xiaoheAccountSchema.parse({ account_id: 'account', instance_id: 'instance', login_generation: '1',
    permissions: [], capabilities: {}, send_conversations: ['filehelper', '123@chatroom'] }).send_conversations)
    .toEqual(['filehelper', '123@chatroom']);
  expect(normalizedEventSchema.safeParse({ eventId: 'event', messageRef: 'ref', origin: 'backfill', accountId: 'account',
    conversationId: 'friend-alias', scopeType: 'direct', senderId: 'friend-alias', senderLabel: '联系人', isSelf: false,
    kind: 'text', text: '内容', mentions: { ids: [], mentionsSelf: false }, createdAt: 1, observedAt: 2, seenAt: 3 }).success)
    .toBe(true);
  expect(backfillRequestSchema.safeParse({ conversationId: 'friend-alias', purpose: 'context', recentCount: 501 }).success).toBe(false);
  expect(backfillRequestSchema.safeParse({ conversationId: 'friend-alias', purpose: 'memory', startTime: 5, endTime: 3 }).success).toBe(false);
  expect(pluginManifestSchema.safeParse({ id: 'p', name: '插件', version: '1.0', entry: 'index.ts', permissions: ['send_wechat'] }).success)
    .toBe(true);
  expect(declarativePluginConfigSchema.safeParse({
    id: 'p', name: '插件', description: '', enabled: false, scope: { conversationIds: [], includeTypes: ['group'] },
    trigger: { type: 'window_time', timesOfDay: ['12:30', '21:00'], minMessages: 5 },
    processor: { systemPrompt: '提炼', userPromptTemplate: '{{messages_markdown}}', outputFormat: 'structured_digest_json', skipWhenNoValue: true },
    sinks: [{ id: 'w', type: 'wechat', approved: false, targetConversationId: 'filehelper' }], rateLimit: { maxRunsPerHour: 3 },
  }).success).toBe(true);
  expect(groupDigestOutputSchema.safeParse({ skip: true }).success).toBe(true);
  expect(groupDigestOutputSchema.safeParse({ skip: false, headline: '缺少结构化字段' }).success).toBe(false);
  expect(MAX_FRAME_BYTES).toBe(262_144);
  expect(PUSH_TOPICS).toHaveLength(9);
  expect(PUSH_TOPICS).toContain('session.trace');
  expect(PUSH_TOPICS).toContain('metrics.updated');
  expect(RPC_METHODS).toHaveLength(38);
  expect(RPC_METHODS).toContain('policy.evaluate');
  expect(RPC_METHODS).toContain('system.metrics');
  expect(RPC_METHODS).toContain('system.bundles');
  expect(RPC_METHODS).toContain('plugins.testWebhook');
  expect(RPC_METHODS).toEqual(expect.arrayContaining(['session.traces', 'session.resumeCooldown', 'system.healthCheck']));
  expect(rpcRequestSchema.safeParse({ v: 3, id: 1, method: 'session.traces',
    params: { conversationId: 'friend-alias', limit: 101 } }).success).toBe(false);
  expect(rpcRequestSchema.safeParse({ v: 3, id: 1, method: 'system.healthCheck', params: {} }).success).toBe(true);
  expect(rpcRequestSchema.safeParse({ v: 3, id: 1, method: 'session.pause', params: { conversationId: 'friend-alias' } }).success).toBe(true);
  expect(rpcRequestSchema.safeParse({ v: 2, id: 1, method: 'session.pause', params: { conversationId: 'friend-alias' } }).success).toBe(false);
  expect(rpcRequestSchema.safeParse({ v: 3, id: 1, method: 'feed.markRead', params: { conversationId: 'friend-alias' } }).success).toBe(false);
  expect(rpcReplySchema('feed.markRead').safeParse({ v: 3, kind: 'reply', id: 1, ok: true, result: true }).success).toBe(true);
  expect(pushFrameSchema.safeParse({ v: 3, kind: 'event', topic: 'backfill.progress',
    payload: { jobId: 'job', conversationId: '123@chatroom', fetched: 5, done: false } }).success).toBe(true);
});

test('IPC v2 云端试拟校验同意、密钥、HTTPS 和档案后返回生成结果', async () => {
  const dir = tempDir();
  const preload = join(dir, 'mock-fetch.js');
  const stylePath = join(dir, 'style.md');
  const badStylePath = join(dir, 'unapproved.md');
  const endpoint = 'https://model.example.invalid/v1/chat/completions';
  atomicWritePrivateFile(stylePath, '本地风格\n<!-- bridge-cloud:start -->\n只用短句\n<!-- bridge-cloud:end -->');
  atomicWritePrivateFile(badStylePath, '没有云端标记');
  atomicWritePrivateFile(preload, `globalThis.fetch = async (url, request) => {
    const payload = JSON.parse(JSON.parse(request.body).messages[1].content);
    if (String(url) !== ${JSON.stringify(endpoint)} || request.headers.authorization !== 'Bearer synthetic-key' ||
        request.redirect !== 'error' || payload.style !== '只用短句' || payload.latest[0] !== ${JSON.stringify(syntheticText)}) {
      throw new Error('unexpected synthetic request');
    }
    return Response.json({ choices: [{ finish_reason: 'stop', message: { content: '{"action":"reply","text":"哈哈，那挺好"}' } }] });
  };`);
  const proc = Bun.spawn([process.execPath, '--preload', preload, join(import.meta.dir, '../main.ts'), '--legacy-v2', '--state-dir', dir],
    { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' });
  const reader = proc.stdout.pipeThrough(new TextDecoderStream()).getReader();
  let remaining = '';
  async function nextFrame() {
    while (!remaining.includes('\n')) {
      const next = await reader.read();
      if (next.done) throw new Error('Preview engine exited before replying');
      remaining += next.value;
    }
    const newline = remaining.indexOf('\n');
    const frame = JSON.parse(remaining.slice(0, newline));
    remaining = remaining.slice(newline + 1);
    return frame;
  }
  try {
    expect(await nextFrame()).toMatchObject({ kind: 'hello', v: 2 });
    const model = { mode: 'cloud', url: endpoint, name: 'fixture', stylePath, memoryPath: '', cloudApproved: true, apiKey: 'synthetic-key' };
    const previews = [
      [{ ...model, cloudApproved: false }, { ok: false, code: 'cloud-not-approved' }],
      [{ ...model, apiKey: undefined }, { ok: false, code: 'missing-key' }],
      [{ ...model, url: endpoint.replace('https:', 'http:') }, { ok: false, code: 'invalid-endpoint' }],
      [{ ...model, stylePath: badStylePath }, { ok: false, code: 'cloud-profile' }],
      [model, { ok: true, result: { action: 'reply', text: '哈哈，那挺好' } }],
    ] as const;
    for (const [index, [input, reply]] of previews.entries()) {
      const id = index + 1;
      proc.stdin.write(JSON.stringify({ v: 2, id, method: 'preview', params: { model: input, text: syntheticText } }) + '\n');
      proc.stdin.flush();
      expect(await nextFrame()).toEqual({ kind: 'reply', id, ...reply });
    }
    proc.stdin.end();
    expect(await proc.exited).toBe(0);
  } finally {
    proc.kill();
    await reader.cancel();
    await proc.exited;
    rmSync(dir, { recursive: true });
  }
});
