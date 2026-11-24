import { expect, test } from 'bun:test';
import { createHmac } from 'node:crypto';
import { lstatSync, mkdtempSync, readdirSync, realpathSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { NormalizedEvent } from '../src/contracts/events.ts';
import { rpcSchemas } from '../src/contracts/ipc.ts';
import type { DeclarativePluginConfig, PluginPermission } from '../src/contracts/plugins.ts';
import { TransmitService } from '../src/core/transmit.ts';
import { HistoryBackfiller } from '../src/mcp/backfill.ts';
import { identityKey, peerKey, routeKey, type HistoryFilter, type Receipt, type XiaoheClient } from '../src/mcp/client.ts';
import { refHash } from '../src/mcp/ingest.ts';
import { createGroupDigestPluginTemplate } from '../src/plugins/declarative.ts';
import { PluginManager, type PluginManagerOptions } from '../src/plugins/manager.ts';
import { SinkDispatcher, type SinkOutput } from '../src/plugins/sinks.ts';
import { atomicWritePrivateFile, ensurePrivateDir, readPrivateFile } from '../src/storage/fs-safe.ts';
import { JournalV2 } from '../src/storage/journal-v2.ts';

const group = 'project@chatroom';
const anotherGroup = 'another@chatroom';
const localMcp = 'http://127.0.0.1:21454/mcp';
const binding = { account_id: 'demo', instance_id: 'sandbox', login_generation: '1' };
const remote = { binding, server: 'fixture' };
const identity = identityKey(remote);
const epoch = new Date(2026, 10, 23, 10).getTime();
const digest = JSON.stringify({
  skip: false, headline: '版本发布已确认',
  topics: [{ title: '发布计划', conclusion: '周三上线', participants: ['李工'] }],
  actionItems: [{ task: '准备测试报告', owner: '赵工', deadline: '周二' }],
  links: [{ title: '发布文档', url: 'https://example.org/release' }],
  mentionsMe: ['复核发布清单'],
});
const feedSink = { id: 'feed', type: 'app_feed', notifyDesktop: true } as const;
const wechatSink = { id: 'wechat', type: 'wechat', targetConversationId: 'filehelper', approved: true } as const;

function message(index: number, changes: Partial<NormalizedEvent> = {}): NormalizedEvent {
  return {
    eventId: `event-${index}`, messageRef: `ref-${index}`, origin: 'live', accountId: binding.account_id,
    conversationId: group, scopeType: 'group', senderId: 'staff', senderLabel: '李工', isSelf: false,
    kind: 'text', text: `讨论条目 ${index}`, mentions: { ids: [], mentionsSelf: false },
    createdAt: epoch + index * 1000, observedAt: epoch + index * 1000, seenAt: epoch + index * 1000,
    ...changes,
  };
}

function config(id: string, changes: Partial<DeclarativePluginConfig> = {}) {
  return { ...createGroupDigestPluginTemplate({ id, conversationIds: [group], enabled: true }), ...changes };
}

function setup(options: Partial<PluginManagerOptions> = {}, receipt: Receipt = { status: 'submitted', delivery: 'delivered' }) {
  const baseDir = realpathSync(mkdtempSync(join(tmpdir(), 'wmb-plugins-test-')));
  const journal = new JournalV2(baseDir);
  let journalClosed = false;
  let time = epoch;
  const wire: { target: string; text: string; attemptId: string }[] = [];
  const feeds: { kind: string; notify: boolean }[] = [];
  const prompts: { system: string; user: string }[] = [];
  const writer: Pick<XiaoheClient, 'identify' | 'sendText' | 'close'> = {
    identify: async () => remote,
    sendText: async (scope, text, attemptId, gate) => {
      gate();
      wire.push({ target: scope.conversation_id, text, attemptId });
      return receipt;
    },
    close: async () => {},
  };
  const transmitterFor = (storage: JournalV2) => new TransmitService({
    accountId: binding.account_id, mcpUrl: localMcp, journal: storage, now: () => time, createWriter: () => writer as XiaoheClient,
  });
  const transmitter = transmitterFor(journal);
  const dependencies: PluginManagerOptions = {
    baseDir, journal, now: () => time, getTransmit: () => ({ transmitter, expectedIdentity: identity }),
    defaultPresetId: () => 'test-model', scopeName: id => id === group ? '发布群' : undefined,
    modelRouter: { summarize: async (_id, system, user) => { prompts.push({ system, user }); return digest; } },
    onFeedAdded: (item, notify) => { feeds.push({ kind: item.kind, notify }); },
    ...options,
  };
  const manager = new PluginManager(dependencies);
  return {
    baseDir, journal, wire, feeds, prompts, dependencies, manager, setTime: (next: number) => { time = next; },
    async restartSinks() {
      await manager.dispose();
      journal.close();
      journalClosed = true;
      const storage = new JournalV2(baseDir);
      const transmitter = transmitterFor(storage);
      return { dispatcher: new SinkDispatcher({ ...dependencies, journal: storage,
        getTransmit: () => ({ transmitter, expectedIdentity: identity }) }), close: () => storage.close() };
    },
    async close() {
      await manager.dispose();
      if (!journalClosed) journal.close();
      rmSync(baseDir, { recursive: true, force: true });
    },
  };
}

test('50 条群聊消息按窗口归集，精准剔除撤回，投递动态、Markdown 和微信', async () => {
  const t = setup();
  try {
    const id = 'digest';
    t.manager.saveDeclarative({ config: config(id, {
      trigger: { type: 'window_count', count: 48, minMessages: 3, maxWaitMinutes: 10 },
      sinks: [feedSink, { id: 'day', type: 'markdown_file', filenameTemplate: '{{date}}/{{scope_name}}.md', mode: 'append' }, wechatSink],
      rateLimit: { maxRunsPerHour: 5, maxWeChatSendsPerDay: 1 },
    }) });
    for (let i = 1; i <= 49; i++) {
      const changes: Partial<NormalizedEvent> = i === 2 ? { text: '', kind: 'image', media: { enrichmentStatus: 'ok', caption: '图片中的排期' } } :
        i === 3 ? { text: '', kind: 'voice', media: { enrichmentStatus: 'ok', transcript: '语音中的复核事项' } } :
        i === 4 ? { text: '已撤回的敏感正文' } : i === 5 ?
          { kind: 'recall', recallTargetRef: 'ref-4' } : i === 6 ? { text: '表情包和闲聊' } : {};
      await t.manager.handleEvent(message(i, changes));
    }
    expect(t.journal.listPluginBuffers(id)).toHaveLength(47);
    expect(t.prompts).toHaveLength(0);
    await t.manager.handleEvent(message(50, { mentions: { ids: ['demo'], mentionsSelf: true } }));
    expect(t.prompts).toHaveLength(1);
    expect(t.prompts[0]?.user).toContain('发布群');
    expect(t.prompts[0]?.user).toContain('图片中的排期');
    expect(t.prompts[0]?.user).toContain('语音中的复核事项');
    expect(t.prompts[0]?.user).toContain('[@我]');
    expect(t.prompts[0]?.user).not.toContain('已撤回的敏感正文');
    expect(t.prompts[0]?.system).toContain('闲聊');
    const path = join(t.baseDir, 'outputs', '2026-11-23', '发布群.md');
    const archive = readPrivateFile(path).toString();
    for (const heading of ['概览', '核心议题与结论', '待办事项', '重要链接', '与我相关']) expect(archive).toContain(`## ${heading}`);
    expect(archive).not.toContain('表情包和闲聊');
    expect(lstatSync(path).mode & 0o777).toBe(0o600);
    expect(t.journal.listFeedItems()).toMatchObject([{ kind: 'plugin_digest', title: '版本发布已确认', conversation_id: group }]);
    expect(t.feeds).toEqual([{ kind: 'plugin_digest', notify: true }]);
    expect(t.wire).toMatchObject([{ target: 'filehelper', text: expect.stringContaining('周三上线') }]);
    expect(t.journal.get(t.wire[0]!.attemptId)).toMatchObject({ status: 'submitted', plugin_id: id, kind: 'plugin' });
    expect(t.manager.runs({ pluginId: id }).items).toMatchObject([{ status: 'ok', itemCount: 48, outputPaths: [path] }]);
    expect(t.journal.snapshotPluginBuffers(id)).toEqual({ items: [], throughId: 0 });
    expect(rpcSchemas['plugins.list'].result.safeParse(t.manager.list()).success).toBe(true);
  } finally { await t.close(); }
});

test('实时过滤关键词、正则和 @我，NO_OP、JSON 跳过和空白响应均静默', async () => {
  const answers = ['NO_OP', '{"skip":true}', '   '];
  let calls = 0;
  const t = setup({ modelRouter: { summarize: async () => answers[calls++]! } });
  try {
    t.manager.saveDeclarative({ config: config('noise', {
      trigger: { type: 'realtime', keywords: ['测试'], regex: '水聊\\d', mentionSelfOnly: true },
      sinks: [feedSink, wechatSink],
    }) });
    const mention = { ids: ['demo'], mentionsSelf: true };
    await t.manager.handleEvent(message(1, { text: '测试水聊1' }));
    await t.manager.handleEvent(message(2, { text: '普通水聊1', mentions: mention }));
    await t.manager.handleEvent(message(3, { text: '测试水聊', mentions: mention }));
    for (const i of [4, 5, 6]) await t.manager.handleEvent(message(i, { text: `测试水聊${i}`, mentions: mention }));
    expect(calls).toBe(3);
    expect(t.manager.runs({ pluginId: 'noise' }).items.map(run => run.status)).toEqual(['skipped', 'skipped', 'skipped']);
    expect(t.feeds).toEqual([]);
    expect(t.wire).toEqual([]);
    expect(t.journal.listFeedItems()).toEqual([]);
  } finally { await t.close(); }
});

test('超长时间窗分片归集，模型调用顺序覆盖 Map 与最终 JSON Reduce', async () => {
  const requests: { system: string; user: string }[] = [];
  const t = setup({ modelRouter: { summarize: async (_id, system, user) => {
    requests.push({ system, user });
    return system.includes('仅输出一个 JSON 对象') ? digest :
      user.includes('最后一条') ? '发布片段 C' : user.includes('第一条') ? '发布片段 A' : '发布片段 B';
  } } });
  try {
    const p = config('map', { trigger: { type: 'window_time', everyMinutes: 2, minMessages: 2 }, sinks: [feedSink] });
    p.processor.maxInputChars = 120;
    t.manager.saveDeclarative({ config: p });
    await t.manager.handleEvent(message(1, { text: '第一条' + '长'.repeat(180) }));
    await t.manager.handleEvent(message(2, { text: '最后一条' + '长'.repeat(180) }));
    await t.manager.tick();
    expect(requests).toHaveLength(0);
    t.setTime(epoch + 121_000);
    await t.manager.tick();
    expect(requests.length).toBeGreaterThan(3);
    const map = requests.slice(0, -1);
    expect(map.every(call => call.user.length <= 120)).toBe(true);
    expect(map.some(call => call.user.includes('第一条'))).toBe(true);
    expect(map.some(call => call.user.includes('最后一条'))).toBe(true);
    expect(requests.at(-1)?.user).toContain('发布片段 A');
    expect(requests.at(-1)?.user).toContain('发布片段 C');
    expect(requests.at(-1)?.user).not.toContain('长'.repeat(120));
    expect(t.manager.runs({ pluginId: 'map' }).items).toMatchObject([{ status: 'ok', triggerKind: 'window_time', itemCount: 2 }]);
  } finally { await t.close(); }
});

test('时间触发、最大等待兜底与推理中撤回保持一致', async () => {
  let release!: () => void;
  const pending = new Promise<void>(resolve => { release = resolve; });
  let started!: () => void;
  const reachedModel = new Promise<void>(resolve => { started = resolve; });
  const inputs: string[] = [];
  const t = setup({ modelRouter: { summarize: async (_id, _sys, input) => {
    inputs.push(input);
    if (inputs.length === 1) { started(); await pending; }
    return digest;
  } } });
  try {
    t.manager.saveDeclarative({ config: config('clock', { trigger: { type: 'window_time', timesOfDay: ['10:01'], minMessages: 1 }, sinks: [] }) });
    await t.manager.handleEvent(message(1, { text: '建模期间撤回' }));
    await t.manager.handleEvent(message(2));
    t.setTime(epoch + 60_000);
    const flush = t.manager.tick();
    await reachedModel;
    await t.manager.handleEvent(message(3, { kind: 'recall', recallTargetRef: 'ref-1' }));
    await t.manager.handleEvent(message(4, { createdAt: epoch + 60_001 }));
    release();
    await flush;
    expect(inputs).toHaveLength(2);
    expect(inputs[0]).toContain('建模期间撤回');
    expect(inputs[1]).not.toContain('建模期间撤回');
    expect(t.journal.listPluginBuffers('clock').map(item => item.message_ref)).toEqual(['ref-4']);
    t.manager.saveDeclarative({ config: config('wait', { trigger: { type: 'window_count', count: 20, minMessages: 1, maxWaitMinutes: 2 }, sinks: [] }) });
    await t.manager.handleEvent(message(5, { createdAt: epoch + 60_005 }));
    t.setTime(epoch + 180_005);
    await t.manager.tick();
    expect(t.manager.runs({ pluginId: 'wait' }).items).toMatchObject([{ status: 'ok', triggerKind: 'window_count', itemCount: 1 }]);
  } finally { release(); await t.close(); }
});

test('Markdown 路径穿越、符号链接和未授权目录均被拦截', async () => {
  const t = setup();
  try {
    const sinks = new SinkDispatcher(t.dependencies);
    expect(() => sinks.markdownFile('../private.md', '正文', 'overwrite')).toThrow('storage-unavailable');
    expect(() => sinks.markdownFile('/private.md', '正文', 'overwrite')).toThrow('storage-unavailable');
    expect(() => sinks.markdownFile('x.md', '正文', 'overwrite', t.baseDir)).toThrow('plugin-permission');
    const root = join(t.baseDir, 'outputs');
    const outside = join(t.baseDir, 'private');
    ensurePrivateDir(outside);
    symlinkSync(outside, join(root, 'link'));
    expect(() => sinks.markdownFile('link/x.md', '正文', 'overwrite')).toThrow('storage-unavailable');
    const marker = join(outside, 'marker.md');
    atomicWritePrivateFile(marker, '原有内容');
    symlinkSync(marker, join(root, 'file.md'));
    expect(() => sinks.markdownFile('file.md', '正文', 'append')).toThrow('storage-unavailable');
    expect(readdirSync(outside)).toEqual(['marker.md']);
    expect(readPrivateFile(marker).toString()).toBe('原有内容');
    const path = sinks.markdownFile('archive/out.md', '第一段', 'overwrite');
    sinks.markdownFile('archive/out.md', '第二段', 'append');
    expect(readPrivateFile(path).toString()).toBe('第一段\n\n第二段\n');
  } finally { await t.close(); }
});

test('Webhook 拦截 SSRF，回环目标支持 HMAC 并拒绝跳转', async () => {
  const captured: { body: string; signature: string | null; cookie: string | null }[] = [];
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, async fetch(req) {
    if (new URL(req.url).pathname === '/redirect') return Response.redirect(new URL('/hook', req.url), 307);
    captured.push({ body: await req.text(), signature: req.headers.get('X-Webhook-Signature'), cookie: req.headers.get('Cookie') });
    return new Response(null, { status: 204 });
  } });
  const t = setup({ resolveWebhookSecret: (id, sink, url) => {
    expect([id, sink, url]).toEqual(['plugin', 'hook', `http://127.0.0.1:${server.port}/hook`]);
    return 'fixture-secret';
  } });
  try {
    const sinks = new SinkDispatcher(t.dependencies);
    const signal = new AbortController().signal;
    for (const url of ['https://169.254.169.254', 'https://10.0.0.2', 'https://172.31.0.1', 'https://192.168.0.1',
      'https://localhost.', 'https://[::1]', 'https://[::ffff:127.0.0.1]', 'https://127.0.0.2', 'http://example.org']) {
      await expect(sinks.webhook(url, {}, signal)).rejects.toThrow('invalid-endpoint');
    }
    const url = `http://127.0.0.1:${server.port}`;
    await expect(sinks.webhook(`${url}/redirect`, {}, signal)).rejects.toThrow('invalid-endpoint');
    expect(captured).toEqual([]);
    await expect(sinks.webhook(`${url}/hook`, { ok: true }, signal, { pluginId: 'plugin', sinkId: 'hook' })).resolves.toEqual({ status: 204 });
    const body = '{"ok":true}';
    expect(captured).toEqual([{ body, signature: `sha256=${createHmac('sha256', 'fixture-secret').update(body).digest('hex')}`, cookie: null }]);
  } finally { server.stop(true); await t.close(); }
});

test('微信出口先检查授权，send-unknown 只发一次并永久留在账本', async () => {
  const t = setup({}, { status: 'unknown', delivery: 'unknown' });
  try {
    const output: SinkOutput = {
      pluginId: 'send-guard', conversationId: group, scopeName: '发布群', title: '摘要', markdown: '群聊摘要',
      dedupeKey: 'window-1', maxWeChatSendsPerDay: 3, origin: 'live', signal: new AbortController().signal,
    };
    const sinks = new SinkDispatcher(t.dependencies);
    await expect(sinks.wechat('filehelper', output.markdown, false, output)).rejects.toThrow('send-not-authorized');
    expect(t.wire).toEqual([]);
    const deliver = () => sinks.dispatch([wechatSink], output);
    expect((await deliver()).errors).toEqual(['send-unknown']);
    expect(t.wire).toHaveLength(1);
    expect(t.journal.get(t.wire[0]!.attemptId)?.status).toBe('unknown');
    expect(t.journal.uncertain(peerKey(binding.account_id, 'filehelper'))?.id).toBe(t.wire[0]!.attemptId);
    expect((await deliver()).errors).toEqual(['send-unknown']);
    const restarted = await t.restartSinks();
    try {
      expect((await restarted.dispatcher.dispatch([wechatSink], { ...output, dedupeKey: 'next-window' })).errors).toEqual(['send-unknown']);
    } finally { restarted.close(); }
    expect(t.wire).toHaveLength(1);
  } finally { await t.close(); }
});

test('同一插件的微信日配额跨目标生效，另一插件独立计数', async () => {
  const t = setup();
  try {
    const sinks = new SinkDispatcher(t.dependencies);
    const output = { pluginId: 'limited', dedupeKey: 'window-1', maxWeChatSendsPerDay: 1,
      origin: 'live' as const, signal: new AbortController().signal };
    await expect(sinks.wechat('filehelper', '第一条', true, output)).resolves.toEqual({ status: 'submitted' });
    await expect(sinks.wechat(group, '超额消息', true, { ...output, dedupeKey: 'window-2' })).rejects.toThrow('plugin-limit');
    await expect(sinks.wechat(group, '独立配额', true, { ...output, pluginId: 'another' })).resolves.toEqual({ status: 'submitted' });
    expect(t.wire.map(item => item.text)).toEqual(['第一条', '独立配额']);
  } finally { await t.close(); }
});

function installModule(baseDir: string, id: string, permissions: PluginPermission[], code: string) {
  const dir = join(baseDir, 'plugins', 'modules', id);
  ensurePrivateDir(dir);
  atomicWritePrivateFile(join(dir, 'manifest.json'), JSON.stringify({ id, name: id, version: '1.0.0', entry: 'index.ts', permissions }));
  atomicWritePrivateFile(join(dir, 'index.ts'), code);
}

test('代码变动和扩权要求重审，三次失败只熔断对应插件', async () => {
  const t = setup({ workerTimeoutMs: 1200 });
  const readPermissions: PluginPermission[] = ['read_events', 'notify'];
  const healthy = 'export default { onMessage(event: any, ctx: any) { return ctx.emit.feed({title: "healthy", body: event.text}); } };';
  const faulty = 'export default { onMessage() { throw new Error("fixture crash"); } };';
  const current = (id: string) => t.manager.list().find(item => item.pluginId === id)!.state;
  const approve = (id: string, approvedPermissions: PluginPermission[]) => t.manager.setEnabled({
    pluginId: id, enabled: true, approvedPermissions, manifestHash: current(id).manifestHash,
  });
  try {
    installModule(t.baseDir, 'stable', readPermissions, healthy);
    installModule(t.baseDir, 'mutable', readPermissions, healthy);
    const before = current('mutable');
    expect(before).toMatchObject({ enabled: false, approvedPermissions: [], lastError: 'plugin-permission' });
    approve('stable', readPermissions);
    approve('mutable', readPermissions);
    await t.manager.handleEvent(message(1));
    expect(t.journal.listFeedItems().filter(item => item.kind === 'plugin_digest')).toHaveLength(2);
    installModule(t.baseDir, 'mutable', readPermissions, faulty);
    expect(current('mutable')).toMatchObject({ enabled: false, approvedPermissions: [], lastError: 'plugin-permission' });
    expect(current('mutable').manifestHash).not.toBe(before.manifestHash);
    expect(() => t.manager.setEnabled({ pluginId: 'mutable', enabled: true, manifestHash: before.manifestHash, approvedPermissions: readPermissions }))
      .toThrow('plugin-permission');
    const expanded: PluginPermission[] = [...readPermissions, 'send_wechat'];
    installModule(t.baseDir, 'mutable', expanded, faulty);
    expect(() => approve('mutable', readPermissions)).toThrow('plugin-permission');
    approve('mutable', expanded);
    for (const i of [2, 3, 4, 5]) await t.manager.handleEvent(message(i));
    expect(current('mutable')).toMatchObject({ enabled: false, circuitOpen: true, consecutiveFailures: 3, lastError: 'internal-error' });
    expect(current('stable')).toMatchObject({ enabled: true, circuitOpen: false, consecutiveFailures: 0 });
    expect(t.manager.runs({ pluginId: 'mutable' }).items.map(run => run.status)).toEqual(['error', 'error', 'error', 'ok']);
    expect(t.manager.runs({ pluginId: 'stable' }).items.map(run => run.status)).toEqual(['ok', 'ok', 'ok', 'ok', 'ok']);
    expect(t.journal.listFeedItems().filter(item => item.kind === 'alert')).toMatchObject([{ plugin_id: 'mutable' }]);
    expect(t.journal.listFeedItems().filter(item => item.plugin_id === 'stable')).toHaveLength(5);
  } finally { await t.close(); }
});

test('手动 runNow 通过 HistoryBackfiller 补扫时间范围，撤回和回放均不触发微信', async () => {
  const route = routeKey(localMcp, binding.account_id, group);
  const calls: HistoryFilter[] = [];
  const row = (id: string, at: number, text: string) => ({
    message_ref: id, conversation_id: group, sender_id: 'staff', sender_name: '李工', is_self: false,
    type: 'text', observed_at: new Date(at).toISOString(), created_at: new Date(at).toISOString(), text,
  });
  const backfiller = new HistoryBackfiller({
    queryMessages: async (_scope, filter, cursor) => {
      calls.push(filter);
      if (!cursor) return { more: true, cursor: 'second', rows: [
        row('checked', epoch + 2000, '历史计划确认'),
        row('will-recall', epoch + 3000, '补扫页间撤回'),
        row('known-recall', epoch + 4000, '此前已撤回正文'),
      ] };
      return { more: false, cursor: null, rows: [
        { ...row('recall', epoch + 5000, ''), status: 'recalled', recall_target_ref: 'will-recall' },
        row('outside', epoch - 1000, '时间窗以外'),
      ] };
    },
  });
  const t = setup({ getHistoryContext: () => ({
    backfiller, scope: { ...binding, conversation_id: group }, type: 'group', route, identity,
  }) });
  try {
    t.journal.markRecalled(route, refHash('known-recall'), epoch);
    t.manager.saveDeclarative({ config: config('history', { trigger: { type: 'manual_only' }, sinks: [feedSink, wechatSink] }) });
    await t.manager.handleEvent(message(1));
    await t.manager.handleEvent(message(2, { origin: 'backfill' }));
    await t.manager.handleEvent(message(3, { conversationId: anotherGroup }));
    expect(t.manager.runs({ pluginId: 'history' }).items).toEqual([]);
    const range = { startTime: epoch + 1000, endTime: epoch + 6000 };
    const response = await t.manager.runNow({ pluginId: 'history', conversationId: group, range });
    expect(calls).toEqual(Array(2).fill({ start_time: range.startTime / 1000, end_time: range.endTime / 1000 }));
    expect(t.prompts).toHaveLength(1);
    expect(t.prompts[0]?.user).toContain('历史计划确认');
    for (const text of ['补扫页间撤回', '此前已撤回正文', '时间窗以外']) expect(t.prompts[0]?.user).not.toContain(text);
    const history = t.manager.runs({ pluginId: 'history', limit: 1 });
    expect(history.items).toMatchObject([{ runId: response.runId, triggerKind: 'manual', itemCount: 1, status: 'ok' }]);
    expect(rpcSchemas['plugins.runs'].result.safeParse(history).success).toBe(true);
    expect(t.wire).toEqual([]);
    expect(t.feeds).toEqual([{ kind: 'plugin_digest', notify: true }]);
  } finally { await t.close(); }
});
