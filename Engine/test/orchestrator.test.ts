import { expect, spyOn, test } from 'bun:test';
import { createHash, generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { BridgeError } from '../contracts.ts';
import type { NormalizedEvent } from '../src/contracts/events.ts';
import { pushFrameSchema, rpcReplySchema, rpcSchemas } from '../src/contracts/ipc.ts';
import { conversationPolicySchema, settingsV2Schema, type QuietHoursConfig } from '../src/contracts/settings.ts';
import { ConversationActor } from '../src/core/actor.ts';
import { BridgeOrchestrator } from '../src/core/orchestrator.ts';
import { isInQuietHours, PolicyEngine } from '../src/core/policy.ts';
import { TransmitService } from '../src/core/transmit.ts';
import { IpcV3Router } from '../src/ipc/router-v3.ts';
import { V3EngineApp } from '../src/ipc/v3-app.ts';
import { ModelRouter } from '../src/llm/router.ts';
import { normalizeEvent, refHash } from '../src/mcp/ingest.ts';
import { identityKey, peerKey, routeKey, XiaoheClient } from '../src/mcp/client.ts';
import { DiagnosticLog } from '../src/storage/diag-log.ts';
import { HotBundleManager } from '../src/storage/hot-bundles.ts';
import { JournalV2 } from '../src/storage/journal-v2.ts';
import { binding, event, group, latch, mockNetwork, peer, scope, secondPeer, service, syntheticText, until } from './fixture.ts';

const testDir = () => mkdtempSync(join(tmpdir(), 'wmb-v2-'));
const session = (id: string, extra = {}) => conversationPolicySchema.parse({
  conversationId: id, label: id, type: id === group ? 'group' : id === service ? 'service' : 'direct',
  enabled: true, replyMode: 'off', backfillOnArmCount: 0, ...extra,
});

async function setup(config: {
  backfill?: number; fallback?: boolean; strictMedia?: boolean; cloudKey?: string;
  quietHours?: Partial<QuietHoursConfig>; quietHoursNow?: () => number;
} = {}) {
  const net = await mockNetwork({ v2: true });
  net.state.accountWideEvents = !config.fallback;
  const dir = testDir();
  const bridge = new BridgeOrchestrator(dir, {
    settings: settingsV2Schema.parse({
      schemaVersion: 2, xiaohe: { mcpUrl: net.mcp, accountId: binding.account_id, accountLabel: '测试' },
      models: [{ id: 'chat', name: 'Chat', kind: 'chat', mode: 'local', url: net.model, modelName: 'fixture' },
        { id: 'vision', name: 'Vision', kind: 'vision', mode: 'local', url: net.model, modelName: 'fixture' }],
      defaultModels: { replyPresetId: 'chat', visionPresetId: 'vision' }, memory: {},
      runtime: config.quietHours ? { quietHours: config.quietHours } : {},
      conversations: { [peer]: session(peer, { backfillOnArmCount: config.backfill ?? 0,
        riskProfile: { strictLegacyRules: !!config.strictMedia } }),
        [secondPeer]: session(secondPeer), [group]: session(group), [service]: session(service) },
    }),
    getModelKey: () => config.cloudKey,
    quietHoursNow: config.quietHoursNow,
    actorTiming: { debounceMs: 120, batchMaxMs: 400 }, shortPollMs: 25,
  });
  return {
    ...net, bridge, dir,
    arm: (id: string) => bridge.arm({ conversationId: id, replyMode: 'auto', consent: true, groupConfirmed: id === group }),
    phase: (id: string) => bridge.status().sessions[id]?.phase,
    sends: (id?: string) => net.calls.filter(c => c.name === 'messages.send_text' && (!id || c.args.conversation_id === id)),
    async close() { await bridge.close(); await net.close(); rmSync(dir, { recursive: true, force: true }); },
  };
}
const incoming = (n: string, id: string, extra: Record<string, unknown> = {}) =>
  event(n, { conversation_id: id, sender_id: id, ...extra });
const picture = (id: string) => incoming(id, peer, { type: 'image', text: '', attachments: [{ media_ref: id }] });

for (const failure of ['peer-stopped', 'send-unknown'] as const) {
  test(`会话 A ${failure}，会话 B 和多个只读消费者继续工作`, async () => {
    const t = await setup();
    const read: string[] = [];
    t.bridge.bus.subscribe('message', () => { throw new Error('subscriber failure'); });
    t.bridge.bus.subscribe('message', event => { read.push(event.messageRef); });
    try {
      await t.bridge.setReadOnlySubscriptions([peer, group]);
      await t.arm(peer);
      await t.arm(secondPeer);
      await until(() => t.phase(peer) === 'listening' && t.phase(secondPeer) === 'listening');
      if (failure === 'send-unknown') t.state.failConversation = peer;
      t.push(incoming('a', peer, failure === 'peer-stopped' ? { text: '别再给我发消息了' } : {}));
      await until(() => t.phase(peer) === (failure === 'peer-stopped' ? 'locked-opt-out' : 'blocked-unknown'));
      t.push(incoming('b', secondPeer));
      await until(() => t.sends(secondPeer).length === 1);
      await until(() => read.includes('ref-b') && read.includes('ref-a'));
      expect(t.sends(peer)).toHaveLength(failure === 'peer-stopped' ? 0 : 1);
      expect(t.calls.filter(c => c.name === 'events.wait').every(c => c.args.conversation_id === undefined)).toBe(true);
      if (failure === 'send-unknown') {
        expect(t.bridge.listFeed({}).items.some(item => item.kind === 'alert')).toBe(true);
        await expect(t.arm(peer)).rejects.toThrow('send-unknown');
      }
      expect(t.wireFaults).toEqual([]);
    } finally { await t.close(); }
  });
}

test('开启历史填充以及独立补扫都产生零发信，发送服务硬拒绝历史来源', async () => {
  const t = await setup({ backfill: 3 });
  try {
    const old = new Date(Date.now() - 60_000).toISOString();
    t.push(incoming('history', peer, { created_at: old, observed_at: old }));
    const origins: string[] = [];
    t.bridge.bus.subscribe('history', ({ event }) => { origins.push(event.origin); });
    await t.arm(peer);
    await until(() => origins.length === 1);
    await t.bridge.backfill({ action: 'start', request: { conversationId: peer, purpose: 'memory' } });
    await until(() => origins.length === 2);
    await delay(200);
    const tx = t.bridge.transmitter!;
    await expect(tx.send({ sourceKind: 'plugin', conversationId: peer, originGuard: 'live_or_human', origin: 'backfill',
      pluginId: 'plugin', text: 'historical', attemptId: randomUUID(), expectedIdentity: 'identity', checkStillValid: () => {} }))
      .rejects.toThrow('send-not-authorized');
    expect(origins).toEqual(['backfill', 'backfill']);
    expect(t.sends()).toHaveLength(0);
    expect(t.models).toHaveLength(0);
  } finally { await t.close(); }
});

test('撤回精确清除待回消息，同时保留同一防抖窗口的其他来信', async () => {
  const t = await setup();
  const recalls: string[] = [];
  t.bridge.bus.subscribe('recall', event => { if (event.recallTargetRef) recalls.push(event.recallTargetRef); });
  try {
    await t.arm(peer);
    await until(() => t.phase(peer) === 'listening');
    t.push(incoming('r', peer, { text: '这条待撤回' }));
    await until(() => t.bridge.journal.known(routeKey(t.mcp, binding.account_id), refHash('ref-r', peer)));
    t.push(incoming('other', peer, { text: '这条保留' }),
      incoming('recall', peer, { event_type: 'message.recalled', type: 'recall', recall_target_ref: 'ref-r' }));
    await until(() => t.sends(peer).length === 1);
    expect(recalls).toEqual(['ref-r']);
    expect(JSON.parse(t.models[0]?.messages[1].content).latest).toEqual(['这条保留']);
    expect(t.bridge.journal.isRecalled(routeKey(t.mcp, binding.account_id), refHash('ref-r', peer))).toBe(true);
    expect(t.bridge.journal.isRecalled(routeKey(t.mcp, binding.account_id), refHash('ref-r', secondPeer))).toBe(false);
  } finally { await t.close(); }
});

test('严格模式先尝试解析已订阅图片，解析失败再暂停会话', async () => {
  const t = await setup({ strictMedia: true });
  try {
    await t.arm(peer);
    await until(() => t.phase(peer) === 'listening');
    t.push(picture('image-first'));
    await until(() => t.sends(peer).length === 1 && t.phase(peer) === 'listening');
    t.state.mediaUnavailable = true;
    t.push(picture('image-second'));
    await until(() => t.phase(peer) === 'paused');
    expect(t.sends()).toHaveLength(1);
    expect(t.calls.filter(call => call.name === 'messages.read_media')).toHaveLength(2);
  } finally { await t.close(); }
});

for (const { label, imagePreset } of [
  { label: '仅配置主回复预设时复用 chat 模型' },
  { label: '显式配置独立 chat 预设时优先使用该模型', imagePreset: { id: 'image-chat', kind: 'chat', modelName: 'image-chat-fixture' } },
  { label: '显式配置 vision 预设时继续优先使用该模型', imagePreset: { id: 'vision', kind: 'vision', modelName: 'vision-fixture' } },
] as const) {
  test(`图片富化：${label}`, async () => {
    const t = await setup();
    const events: NormalizedEvent[] = [];
    t.bridge.bus.subscribe('message', event => { events.push(event); });
    try {
      const settings = t.bridge.currentSettings;
      const reply = { ...settings.models[0]!, modelName: 'reply-fixture' };
      const models = imagePreset ? [reply, { ...reply, ...imagePreset }] : [reply];
      await t.bridge.applySettings({ ...settings, models, defaultModels: { replyPresetId: reply.id, visionPresetId: imagePreset?.id } });
      await t.bridge.setReadOnlySubscriptions([peer]);
      await until(() => t.calls.some(call => call.name === 'events.wait'));
      t.push(picture('image-selected'));
      const image = await until(() => events.find(event => event.messageRef === 'ref-image-selected'));
      expect(image).toMatchObject({ text: '一张日落照片', media: { enrichmentStatus: 'ok', caption: '一张日落照片' } });
      expect(t.models).toHaveLength(1);
      expect(t.models[0]).toMatchObject({ model: imagePreset?.modelName ?? reply.modelName, messages: [expect.any(Object), {
        role: 'user', content: [{ type: 'image_url', image_url: { url: 'data:image/png;base64,ZmFrZQ==' } }],
      }] });
    } finally { await t.close(); }
  });
}

test('只读订阅回退到云端主模型时按主预设 ID 检查授权', async () => {
  const t = await setup({ cloudKey: 'synthetic-cloud-key' });
  const events: NormalizedEvent[] = [];
  t.bridge.bus.subscribe('message', event => { events.push(event); });
  const url = 'https://vision-fallback.example.invalid/v1/chat/completions';
  const originalFetch = globalThis.fetch;
  const fetchStub = spyOn(globalThis, 'fetch').mockImplementation(Object.assign(
    async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) =>
      String(input) === url ? originalFetch(t.model, init) : originalFetch(input, init),
    { preconnect: originalFetch.preconnect },
  ));
  try {
    const settings = t.bridge.currentSettings;
    const reply = { ...settings.models[0]!, mode: 'cloud' as const, url };
    const next = { ...settings, models: [reply], defaultModels: { replyPresetId: reply.id } };
    await t.bridge.applySettings(next);
    await t.bridge.setReadOnlySubscriptions([peer]);
    await until(() => t.calls.some(call => call.name === 'events.wait'));
    t.push(picture('image-unapproved'));
    const unapproved = await until(() => events.find(event => event.messageRef === 'ref-image-unapproved'));
    expect(unapproved).toMatchObject({ text: '[图片]', media: { enrichmentStatus: 'degraded' } });
    expect(fetchStub.mock.calls.filter(([input]) => String(input) === url)).toHaveLength(0);

    await t.bridge.applySettings({ ...next, runtime: { ...next.runtime, approvedCloudPresetIds: [reply.id] } });
    t.push(picture('image-approved'));
    const approved = await until(() => events.find(event => event.messageRef === 'ref-image-approved'));
    expect(approved).toMatchObject({ text: '一张日落照片', media: { enrichmentStatus: 'ok', caption: '一张日落照片' } });
    const cloudCalls = fetchStub.mock.calls.filter(([input]) => String(input) === url);
    expect(cloudCalls).toHaveLength(1);
    expect(new Headers(cloudCalls[0]?.[1]?.headers).get('authorization')).toBe('Bearer synthetic-cloud-key');
  } finally { fetchStub.mockRestore(); await t.close(); }
});

test('长轮询断开后恢复游标，并丢弃未启用会话的消息', async () => {
  const t = await setup();
  const delivered: string[] = [];
  t.bridge.bus.subscribe('message', event => { delivered.push(event.conversationId); });
  try {
    await t.arm(peer);
    const first = await until(() => t.calls.find(call => call.name === 'events.wait'));
    t.state.dropWait = true;
    t.push(incoming('filtered', service));
    await until(() => t.phase(peer) === 'retrying');
    t.state.dropWait = false;
    await until(() => t.phase(peer) === 'listening');
    await until(() => t.calls.find(call => call.name === 'events.wait' && call.session !== first.session));
    t.push(incoming('new', peer));
    await until(() => t.sends(peer).length === 1);
    expect(delivered).toEqual([peer]);
    expect(t.bridge.journal.known(routeKey(t.mcp, binding.account_id), refHash('ref-filtered', service))).toBe(false);
  } finally { await t.close(); }
});

test('本人插话按会话分别进入短暂冷却或持续暂停', async () => {
  const dir = testDir();
  const journal = new JournalV2(dir);
  const tx = new TransmitService({ accountId: binding.account_id, mcpUrl: 'http://127.0.0.1:1/mcp', journal,
    createWriter: () => { throw new Error('unexpected send'); } });
  const make = (id: string, cooldown: boolean) => {
    const policy = session(id, { riskProfile: { takeoverAction: cooldown ? 'cooldown' : 'pause_session' } });
    policy.riskProfile.takeoverCooldownMinutes = 0.001;
    return new ConversationActor(policy, { accountId: binding.account_id, journal, transmitter: tx,
      fence: () => { throw new Error('unexpected fence'); }, generate: async () => ({ action: 'skip' }) });
  };
  const a = make(peer, true), b = make(secondPeer, false);
  try {
    for (const actor of [a, b]) {
      const id = actor.policy.conversationId;
      actor.beginDrain(id);
      actor.arm({ mode: 'draft' });
      actor.ingestState('listening');
      actor.observe(normalizeEvent(incoming(id, id, { is_self: true }), { ...scope, conversation_id: id },
        'direct', 'live', id, 'identity')!);
    }
    expect(a.status.phase).toBe('cooldown');
    expect(b.status.phase).toBe('paused');
    await until(() => a.status.phase === 'listening');
    expect(a.status.replyMode).toBe('draft');
    expect(b.status.replyMode).toBe('off');
  } finally { a.pause(); b.pause(); journal.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('人工插话按 ignore 跳过，热更新冷静期策略后可通过 IPC 手动解除并继续回复', async () => {
  const t = await setup();
  const frames: unknown[] = [];
  const ipc = new IpcV3Router(t.bridge, line => frames.push(JSON.parse(line)));
  const updateTakeover = async (takeoverAction: 'ignore' | 'cooldown') => {
    const next = structuredClone(t.bridge.currentSettings);
    const old = next.conversations[peer]!;
    next.conversations[peer] = { ...old, riskProfile: { ...old.riskProfile, takeoverAction } };
    await t.bridge.applySettings(next);
  };
  try {
    await updateTakeover('ignore');
    const self = incoming('self-ignored', peer, { is_self: true });
    const policy = t.bridge.currentSettings.conversations[peer]!;
    const normalized = normalizeEvent(self, { ...scope, conversation_id: peer }, 'direct', 'live', peer, 'identity')!;
    expect(new PolicyEngine().inbound(normalized.event, policy, false)).toEqual({ action: 'skip_turn' });
    await t.arm(peer);
    await until(() => t.phase(peer) === 'listening');
    t.push(self);
    await until(() => t.bridge.sessionTraces({ conversationId: peer }).items.some(entry => entry.summary === '收到本人发言'));
    expect(t.phase(peer)).toBe('listening');

    await updateTakeover('cooldown');
    expect(t.bridge.status().sessions[peer]?.replyMode).toBe('auto');
    t.push(incoming('self-cooldown', peer, { is_self: true }));
    await until(() => t.phase(peer) === 'cooldown');
    t.push(incoming('while-cooling', peer));
    await until(() => t.bridge.sessionTraces({ conversationId: peer }).items.some(entry => entry.summary.includes('冷静期中跳过')));
    expect(t.models).toHaveLength(0);
    await ipc.route(JSON.stringify({ v: 3, id: 20, method: 'session.resumeCooldown', params: { conversationId: peer } }));
    expect(rpcReplySchema('session.resumeCooldown').parse(frames.at(-1))).toEqual({ v: 3, kind: 'reply', id: 20, ok: true, result: true });
    expect(t.phase(peer)).toBe('listening');
    expect(t.bridge.status().sessions[peer]?.cooldownUntil).toBeUndefined();
    await delay(10);
    t.push(incoming('after-resume', peer));
    await until(() => t.sends(peer).length === 1 && t.phase(peer) === 'listening');
    const traces = t.bridge.sessionTraces({ conversationId: peer }).items;
    expect(traces.map(entry => entry.summary).join(' ')).toContain('已手动解除冷静期恢复监听');
    expect(traces.map(entry => entry.stage)).toEqual(expect.arrayContaining(['inbound', 'policy', 'model', 'send', 'state']));
    const logPath = join(t.dir, 'engine.log');
    expect(statSync(logPath).mode & 0o777).toBe(0o600);
    expect(readFileSync(logPath, 'utf8')).not.toContain(syntheticText);
  } finally { ipc.close(); await t.close(); }
});

test('群聊触发策略热更新后复用会话授权，放开触发即可回复未 @ 的消息', async () => {
  const t = await setup();
  try {
    await t.arm(group);
    await until(() => t.phase(group) === 'listening');
    t.push(incoming('before-policy-update', group, { sender_id: secondPeer }));
    await until(() => t.bridge.sessionTraces({ conversationId: group }).items.some(entry => entry.summary.includes('未提及本人')));
    expect(t.models).toHaveLength(0);
    const next = structuredClone(t.bridge.currentSettings);
    next.conversations[group] = { ...next.conversations[group]!, groupTrigger: 'all' };
    await t.bridge.applySettings(next);
    expect(t.bridge.status().sessions[group]).toMatchObject({ phase: 'listening', replyMode: 'auto' });
    t.push(incoming('after-policy-update', group, { sender_id: secondPeer }));
    await until(() => t.sends(group).length === 1);
  } finally { await t.close(); }
});

test('会话轨迹 IPC 实时推送，查询默认最近 30 条、按会话隔离且最多保留 40 条', async () => {
  const t = await setup();
  const frames: unknown[] = [];
  const ipc = new IpcV3Router(t.bridge, line => frames.push(JSON.parse(line)));
  const query = async (params: { conversationId: string; limit?: number }) => {
    await ipc.route(JSON.stringify({ v: 3, id: 30, method: 'session.traces', params }));
    const frame = rpcReplySchema('session.traces').parse(frames.at(-1));
    if (!frame.ok) throw new Error(frame.code);
    return rpcSchemas['session.traces'].result.parse(frame.result).items;
  };
  try {
    for (let i = 0; i < 45; i++) t.bridge.emitTrace(peer, 'state', 'info', `状态 ${i}`);
    t.bridge.emitTrace(secondPeer, 'state', 'warn', '另一会话');
    const pushed = pushFrameSchema.parse(frames[44]);
    expect(pushed).toMatchObject({ topic: 'session.trace', payload: { entry: { summary: '状态 44', conversationId: peer } } });
    const latest = await query({ conversationId: peer });
    expect(latest).toHaveLength(30);
    expect(latest[0]?.summary).toBe('状态 44');
    const retained = await query({ conversationId: peer, limit: 100 });
    expect(retained).toHaveLength(40);
    expect(retained.at(-1)?.summary).toBe('状态 5');
    expect((await query({ conversationId: secondPeer, limit: 1 }))[0]?.summary).toBe('另一会话');
    expect(await query({ conversationId: group })).toEqual([]);
  } finally { ipc.close(); await t.close(); }
});

test('诊断日志保留后半截完整 JSON 行，并过滤原始详情和会话全名', () => {
  const dir = testDir();
  const path = join(dir, 'engine.log');
  const log = new DiagnosticLog(dir);
  try {
    writeFileSync(path, `${JSON.stringify({ previous: 'old' })}\n`.repeat(16_000), { mode: 0o600 });
    const entry = { id: 'trace', conversationId: 'private-conversation-id', at: 1, stage: 'model', level: 'warn' } as const;
    log.append({ ...entry, summary: '模型请求失败', detail: '不应落盘的合成凭据和私密正文' });
    log.append({ ...entry, summary: '模型请求结束', detail: 'model-unavailable' });
    const data = readFileSync(path, 'utf8');
    expect(statSync(path).size).toBeLessThan(132 * 1024);
    expect(data).not.toContain(entry.conversationId);
    expect(data).not.toContain('合成凭据');
    const entries = data.trimEnd().split('\n').map(line => JSON.parse(line));
    expect(entries[0]).toEqual({ previous: 'old' });
    expect(entries.at(-1)).toEqual({ at: 1, session: 'ation-id', stage: 'model', level: 'warn',
      summary: '模型请求结束', code: 'model-unavailable' });
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('V3EngineApp 体检串行返回四步，支持单会话与通配白名单，并继续报告独立故障', async () => {
  const net = await mockNetwork({ v2: true });
  const dir = testDir();
  const frames: unknown[] = [];
  const app = new V3EngineApp(dir, line => frames.push(JSON.parse(line)));
  const settings = settingsV2Schema.parse({
    schemaVersion: 2, xiaohe: { mcpUrl: net.mcp, accountId: binding.account_id, accountLabel: '测试' },
    models: [
      { id: 'local', name: 'Local', kind: 'chat', mode: 'local', url: net.model, modelName: 'fixture' },
      { id: 'cloud', name: 'Cloud', kind: 'chat', mode: 'cloud', url: 'https://health.example.invalid/v1/chat/completions', modelName: 'fixture' },
    ],
    defaultModels: { replyPresetId: 'local' }, memory: {}, runtime: {},
    conversations: { [peer]: session(peer), [secondPeer]: session(secondPeer) },
  });
  const check = async (params: { presetId?: string; conversationId?: string } = {}) => {
    await app.route(JSON.stringify({ v: 3, id: 31, method: 'system.healthCheck', params }));
    const reply = rpcReplySchema('system.healthCheck').parse(frames.at(-1));
    if (!reply.ok) throw new Error(reply.code);
    return rpcSchemas['system.healthCheck'].result.parse(reply.result);
  };
  try {
    await app.orchestrator.applySettings(settings);
    net.state.sendConversations = [peer];
    const single = await check({ conversationId: peer });
    expect(single.ok).toBe(true);
    expect(single.steps.map(step => step.id)).toEqual(['xiaohe', 'whitelist', 'credentials', 'model']);
    expect(single.steps[3]?.detail).toContain('模型决策：回复');
    expect(JSON.parse(net.models[0]?.messages[1].content)).toEqual({ context: [], latest: ['你好'] });
    expect((await check()).steps.map(step => step.ok)).toEqual([true, false, true, true]);
    net.state.sendConversations = ['*'];
    expect((await check()).ok).toBe(true);
    net.state.writePermission = false;
    const denied = await check({ presetId: 'cloud', conversationId: peer });
    expect(denied.steps.map(step => step.ok)).toEqual([true, false, false, false]);
    expect(denied.steps[2]?.detail).toContain('请先授权');
    expect(net.models).toHaveLength(3);
    const approvedSettings = { ...settings, runtime: { ...settings.runtime, approvedCloudPresetIds: ['cloud'] } };
    await app.orchestrator.applySettings(approvedSettings);
    expect((await check({ presetId: 'cloud' })).steps[2]?.detail).toContain('missing-key');
    await app.orchestrator.applySettings(approvedSettings, { cloud: 'synthetic-cloud-key' });
    await app.orchestrator.modelRouter.checkChatCredentials('cloud', true);
    await app.orchestrator.applySettings({ ...approvedSettings, models: approvedSettings.models.map(preset => preset.id === 'cloud'
      ? { ...preset, url: 'https://other-health.example.invalid/v1/chat/completions' } : preset) });
    expect((await check({ presetId: 'cloud' })).steps[2]?.detail).toContain('missing-key');
    net.state.offline = true;
    expect((await check()).steps.map(step => step.ok)).toEqual([false, false, true, true]);
    net.state.offline = false;
    net.state.modelStatus = 503;
    const upstream = await check({ conversationId: peer });
    expect(upstream.steps[3]).toMatchObject({ ok: false, detail: expect.stringContaining('正在第 2 次重试') });
    expect(net.calls.filter(call => call.name === 'messages.send_text')).toHaveLength(0);
  } finally { await app.close(); await net.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('群聊 mention_only 门禁，能力缺失时用会话级长轮询与共享短轮询', async () => {
  const t = await setup({ fallback: true });
  try {
    await t.bridge.setReadOnlySubscriptions([service]);
    await t.arm(group);
    await until(() => t.phase(group) === 'listening');
    t.push(incoming('unmentioned', group, { sender_id: secondPeer }));
    await delay(180);
    expect(t.sends()).toHaveLength(0);
    t.push(incoming('mentioned', group, { sender_id: secondPeer, mention_user_ids: [binding.account_id] }));
    await until(() => t.sends(group).length === 1);
    expect(t.calls.some(c => c.name === 'events.wait' && c.args.conversation_id === group)).toBe(true);
    expect(t.calls.some(c => c.name === 'events.read' && c.args.conversation_id === service)).toBe(true);
    expect(t.calls.some(c => c.name === 'events.wait' && c.args.conversation_id === service)).toBe(false);
  } finally { await t.close(); }
});

test('两个会话的单次定时可同时通过发送闸门，且各自仅发送一次', async () => {
  const t = await setup();
  try {
    const at = Date.now() + 500;
    t.state.sendHold = latch();
    await Promise.all([peer, secondPeer].map(conversationId => t.bridge.sendOneShot({
      conversationId, at, text: '提醒自己看日落', request: randomUUID(), consent: true,
    })));
    await until(() => t.sends().length === 2);
    expect(t.bridge.transmitter?.inFlight).toBe(2);
    t.state.sendHold.release();
    await until(() => t.phase(peer) === 'idle' && t.phase(secondPeer) === 'idle');
    expect(t.sends(peer)).toHaveLength(1);
    expect(t.sends(secondPeer)).toHaveLength(1);
  } finally { t.state.sendHold?.release(); await t.close(); }
});

test('两个后台任务占用槽位时，实时回复可以使用预留槽位，取消任务不占槽', async () => {
  const router = new ModelRouter();
  const hold = latch();
  let background = 0;
  const queue = () => router.run('background', async () => { background++; await hold.promise; });
  const two = [queue(), queue()];
  const abort = new AbortController();
  const third = router.run('background', async () => { background++; }, abort.signal);
  try {
    expect(await router.run('reply', async () => background)).toBe(2);
    abort.abort();
    await expect(third).rejects.toThrow('stopped');
    expect(background).toBe(2);
  } finally { hold.release(); await Promise.all(two); }
});

test('IPC v3 校验协议、字节边界、参数、扩展路由与推送', async () => {
  const t = await setup();
  const output: Record<string, unknown>[] = [];
  const ipc = new IpcV3Router(t.bridge, line => { output.push(JSON.parse(line)); }, { 'plugins.list': () => [] });
  const call = (id: number, method: string, params = {}, v = 3) => ipc.route(JSON.stringify({ id, v, method, params }));
  try {
    ipc.hello();
    expect(output[0]).toMatchObject({ v: 3, topic: 'hello', kind: 'event' });
    await call(1, 'system.status', {}, 2);
    await call(2, 'session.arm', { conversationId: peer, replyMode: 'auto' });
    await call(3, 'plugins.list');
    await call(4, 'memory.get', { target: { kind: 'persona' } });
    const frame = JSON.stringify({ v: 3, id: 5, method: 'system.status', params: {} });
    await ipc.route(frame.padEnd(256 * 1024, ' ') + '\n');
    await ipc.route(frame.padEnd(256 * 1024 + 1, ' '));
    expect(output.slice(1)).toMatchObject([
      { id: 1, code: 'engine-protocol' }, { id: 2, code: 'invalid-frame' }, { id: 3, result: [] },
      { id: 4, code: 'engine-not-ready' }, { id: 5, ok: true }, { kind: 'error', code: 'invalid-frame' },
    ]);
  } finally { ipc.close(); await t.close(); }
});

test('登录代际变化之前提交的发信不能绕过 Send Fence', async () => {
  const t = await setup();
  const client = new XiaoheClient(t.mcp);
  try {
    const identity = identityKey(await client.identify(binding.account_id));
    const route = routeKey(t.mcp, binding.account_id);
    t.bridge.journal.advance(route, identity, 'c0', [], Date.now());
    t.state.generation = 'new-generation';
    const tx = new TransmitService({ accountId: binding.account_id, mcpUrl: t.mcp, journal: t.bridge.journal,
      createWriter: () => new XiaoheClient(t.mcp) });
    await expect(tx.send({ sourceKind: 'active', conversationId: peer, text: '看日落', attemptId: randomUUID(),
      expectedIdentity: identity, fenceCursor: { route, cursor: 'c0', scope: binding }, originGuard: 'live_or_human',
      checkStillValid: () => {} })).rejects.toBeInstanceOf(BridgeError);
    expect(t.sends()).toHaveLength(0);
  } finally { await client.close(); await t.close(); }
});

test('全局停止取消仍在验证权限的开启请求', async () => {
  const t = await setup();
  try {
    await t.bridge.discoverCapabilities();
    t.state.metaHold = latch();
    const arming = t.arm(peer).catch((error: unknown) => error);
    await until(() => t.calls.some(call => call.name === 'system.status'));
    t.bridge.pauseAll('all', 'system-sleep');
    t.state.metaHold.release();
    expect(await arming).toMatchObject({ code: 'stopped' });
    expect(t.bridge.status().sessions[peer]?.replyMode).toBe('off');
    expect(t.sends()).toHaveLength(0);
  } finally { t.state.metaHold?.release(); await t.close(); }
});

test('单次额度、插件额度和跨来源未知锁在发信前拒绝', async () => {
  const t = await setup();
  const client = new XiaoheClient(t.mcp);
  try {
    const journal = t.bridge.journal;
    const identity = identityKey(await client.identify(binding.account_id));
    const route = routeKey(t.mcp, binding.account_id);
    const first = peerKey(binding.account_id, peer), second = peerKey(binding.account_id, secondPeer);
    const now = Date.now();
    journal.advance(route, identity, 'c0', [], now);
    for (let i = 0; i < 12; i++) {
      journal.reserve(`active-${i}`, first, route, identity, 'active', now);
      journal.complete(`active-${i}`, { status: 'submitted', delivery: 'unknown' });
    }
    journal.reserve('plugin-existing', second, route, identity, 'plugin', now, { pluginId: 'summary' });
    journal.complete('plugin-existing', { status: 'submitted', delivery: 'unknown' });
    const tx = new TransmitService({ accountId: binding.account_id, mcpUrl: t.mcp, journal,
      createWriter: () => new XiaoheClient(t.mcp) });
    const args = { conversationId: peer, text: '看日落', attemptId: randomUUID(), expectedIdentity: identity,
      originGuard: 'live_or_human' as const, checkStillValid: () => {} };
    await expect(tx.send({ ...args, sourceKind: 'active', fenceCursor: { route, cursor: 'c0', scope: binding } }))
      .rejects.toThrow('active-limit');
    await expect(tx.send({ ...args, sourceKind: 'plugin', pluginId: 'summary', pluginDailyLimit: 1 }))
      .rejects.toThrow('plugin-limit');
    journal.reserve('uncertain', second, route, identity, 'auto', now);
    journal.complete('uncertain', { status: 'unknown', delivery: 'unknown' });
    await expect(tx.send({ ...args, conversationId: secondPeer, sourceKind: 'plugin', pluginId: 'summary' }))
      .rejects.toThrow('send-unknown');
    expect(t.sends()).toHaveLength(0);
  } finally { await client.close(); await t.close(); }
});

test('安全规则保留借还、委托和承诺检查，并收窄普通数字误报', () => {
  const policy = new PolicyEngine();
  for (const text of ['5000还我', '记得带文件', '请帮我安排一下', '下周见面', '验证码 123456',
    '12345678901234567X', '13800138000', '6222021234567890123']) expect(policy.classify(text)).toBe('manual');
  expect(policy.classify('2026 年秋天，今天走了 12500 步')).toBeUndefined();
  expect(policy.classify('嗯'.repeat(500) + '。别再回。')).toBe('stop');
  expect(policy.outbound({ action: 'reply', text: '我会给你' }).action).toBe('pause_session');
  expect(policy.outbound({ action: 'reply', text: '刚下班' }).action).toBe('pause_session');
});

test('风控档位读取旧版开关，显式档位优先，拒绝未知档位或 null', () => {
  expect(session(peer).riskProfile.level).toBeUndefined();
  expect(session(peer, { riskProfile: { strictLegacyRules: true } }).riskProfile.strictLegacyRules).toBe(true);
  expect(session(peer, { riskProfile: { strictLegacyRules: true, level: 'minimal' } }).riskProfile.level).toBe('minimal');
  for (const level of [null, 'off']) expect(() => session(peer, { riskProfile: { level } })).toThrow();
});

test('日常只拦高风险来信，严格/兼容保留旧规则，极简仍保护叫停和身份', () => {
  const engine = new PolicyEngine();
  const inbound = (text: string, riskProfile: object) => engine.inbound(
    normalizeEvent(incoming('sample', peer, { text }), scope, 'direct', 'live', 'route', 'identity')!.event,
    session(peer, { riskProfile }), false);
  for (const text of ['今晚一起去吃饭吗', '记得带文件', '这个链接 https://example.invalid', '2026 年上映的电影']) {
    expect(inbound(text, { level: 'recommended' }).action).toBe('allow');
  }
  expect(inbound('记得带文件', { strictLegacyRules: false }).action).toBe('skip_turn');
  expect(inbound('记得带文件', { strictLegacyRules: true }).action).toBe('pause_session');
  expect(inbound('记得带文件', { level: 'strict' }).action).toBe('pause_session');
  for (const text of ['验证码 123456', '动态码 123456', '5000还我', '请签合同', '13800138000', '这药怎么用', '我不想活了']) {
    expect(inbound(text, { level: 'recommended' })).toMatchObject({ action: 'skip_turn', reason: 'manual-review' });
    expect(inbound(text, { level: 'minimal', strictLegacyRules: true }).action).toBe('allow');
  }
  for (const level of ['recommended', 'strict', 'minimal'] as const) {
    expect(inbound('嗯'.repeat(500) + '。别再回。', { level }).action).toBe('lock_peer');
    expect(inbound('这个话题不用回复', { level }).action).toBe(level === 'strict' ? 'pause_session' : 'skip_turn');
    expect(inbound('你是机器人吗？', { level })).toMatchObject({ action: 'identity' });
    for (const text of ['我就是本人', '是本人呀', '不是机器人']) {
      expect(engine.outbound({ action: 'reply', text }, level)).toMatchObject({ reason: 'manual-review' });
    }
    expect(engine.outbound({ action: 'reply', text: '哈\u0000哈' }, level)).toMatchObject({ reason: 'manual-review' });
    expect(engine.outbound({ action: 'manual' }, level).action).toBe(level === 'strict' ? 'pause_session' : 'skip_turn');
    expect(engine.outbound({ action: 'reply', text: '今晚一起去吃个饭' }, level).action)
      .toBe(level === 'strict' ? 'pause_session' : 'allow');
  }
});

test('轨迹分清入站凭据、模型转人工与出站承诺，并不记录命中正文', async () => {
  const t = await setup();
  const setLevel = async (level: 'recommended' | 'strict') => {
    const settings = structuredClone(t.bridge.currentSettings);
    settings.conversations[peer]!.riskProfile.level = level;
    await t.bridge.applySettings(settings);
  };
  const summaries = () => t.bridge.sessionTraces({ conversationId: peer }).items.map(entry => entry.summary);
  try {
    await setLevel('recommended');
    await t.arm(peer);
    await until(() => t.phase(peer) === 'listening');
    t.push(incoming('review-in', peer, { text: '验证码 612345' }));
    await until(() => summaries().some(line => line.includes('入站规则') && line.includes('凭据') && line.includes('跳过本轮')));
    expect(t.models).toHaveLength(0);
    t.state.decision = { action: 'manual' };
    t.push(incoming('review-model', peer));
    await until(() => summaries().some(line => line.includes('模型建议转人工') && line.includes('跳过本轮')));
    expect(t.phase(peer)).toBe('listening');
    await setLevel('strict');
    t.state.decision = { action: 'reply', text: '我帮你' };
    t.push(incoming('review-out', peer));
    await until(() => t.phase(peer) === 'paused');
    expect(summaries().some(line => line.includes('出站草稿规则') && line.includes('承诺') && line.includes('暂停会话'))).toBe(true);
    expect(JSON.stringify(t.bridge.sessionTraces({ conversationId: peer }).items)).not.toMatch(/612345|我帮你/);
    expect(t.sends()).toHaveLength(0);
  } finally { await t.close(); }
});

test('极简档按固定文本披露身份，明确叫停仍锁定且不能靠换档解除', async () => {
  const t = await setup();
  const setLevel = async (level: 'minimal' | 'recommended') => {
    const settings = structuredClone(t.bridge.currentSettings);
    settings.conversations[peer]!.riskProfile.level = level;
    await t.bridge.applySettings(settings);
  };
  try {
    await setLevel('minimal');
    await t.arm(peer);
    await until(() => t.phase(peer) === 'listening');
    t.push(incoming('ask-identity', peer, { text: '你是机器人吗？' }));
    await until(() => t.sends(peer).length === 1 && t.phase(peer) === 'listening');
    expect(t.sends(peer)[0]?.args.text).toContain('不是本人在打字');
    expect(t.models).toHaveLength(0);
    t.push(incoming('ask-stop', peer, { text: '请不要再回复' }));
    await until(() => t.phase(peer) === 'locked-opt-out');
    expect(t.bridge.sessionTraces({ conversationId: peer }).items.some(entry => entry.summary === '命中叫停 → 锁定会话')).toBe(true);
    await setLevel('recommended');
    await expect(t.arm(peer)).rejects.toThrow('peer-stopped');
    expect(t.sends(peer)).toHaveLength(1);
  } finally { await t.close(); }
});

test('升级到严格档时废弃已开始生成的旧回合，保留授权与未知发信保护', async () => {
  const t = await setup();
  const hold = t.state.modelHold = latch();
  const setLevel = async (level: 'minimal' | 'strict') => {
    const settings = structuredClone(t.bridge.currentSettings);
    settings.conversations[peer]!.riskProfile.level = level;
    await t.bridge.applySettings(settings);
  };
  try {
    await setLevel('minimal');
    await t.arm(peer);
    await until(() => t.phase(peer) === 'listening');
    t.push(incoming('old-level', peer, { text: '记得带文件' }));
    await until(() => t.models.length === 1);
    await setLevel('strict');
    hold.release();
    await until(() => t.phase(peer) === 'listening');
    t.state.failConversation = peer;
    t.push(incoming('after-level', peer));
    await until(() => t.phase(peer) === 'blocked-unknown');
    expect(t.sends(peer)).toHaveLength(1);
    await setLevel('minimal');
    await expect(t.arm(peer)).rejects.toThrow('send-unknown');
  } finally { hold.release(); await t.close(); }
});

test('P0-1: 查回执从 submitted 变为 unknown 立即持久化锁定当前会话并跨重启生效，不影响其他会话', async () => {
  const net = await mockNetwork({ v2: true });
  net.state.accountWideEvents = true;
  const dir = testDir();
  const makeSettings = () => settingsV2Schema.parse({
    schemaVersion: 2, xiaohe: { mcpUrl: net.mcp, accountId: binding.account_id, accountLabel: '测试' },
    models: [{ id: 'chat', name: 'Chat', kind: 'chat', mode: 'local', url: net.model, modelName: 'fixture' }],
    defaultModels: { replyPresetId: 'chat' }, memory: {}, runtime: {},
    conversations: { [peer]: session(peer), [secondPeer]: session(secondPeer) },
  });
  let forceUnknownOp = false;
  const createClient = (url: string) => {
    const client = new XiaoheClient(url);
    const origOp = client.operation.bind(client);
    client.operation = async (op, signal) => forceUnknownOp ? { status: 'unknown', delivery: 'unknown', operation: op } : origOp(op, signal);
    return client;
  };
  let bridge = new BridgeOrchestrator(dir, { settings: makeSettings(), createClient, actorTiming: { debounceMs: 80, batchMaxMs: 250 } });
  try {
    await bridge.arm({ conversationId: peer, replyMode: 'auto', consent: true });
    await bridge.arm({ conversationId: secondPeer, replyMode: 'auto', consent: true });
    await until(() => bridge.status().sessions[peer]?.phase === 'listening' && bridge.status().sessions[secondPeer]?.phase === 'listening');
    net.push(incoming('ok1', peer));
    await until(() => net.calls.filter(c => c.name === 'messages.send_text' && c.args.conversation_id === peer).length === 1);
    forceUnknownOp = true;
    const receipt = await bridge.refreshReceipt(peer);
    expect(receipt.status).toBe('unknown');
    expect(bridge.status().sessions[peer]?.phase).toBe('blocked-unknown');
    expect(bridge.status().sessions[secondPeer]?.phase).toBe('listening');
    await expect(bridge.arm({ conversationId: peer, replyMode: 'auto', consent: true })).rejects.toThrow('send-unknown');
    await bridge.close();

    // 重启后无需触发 actor，首个 status() 即应投影出 blocked-unknown
    bridge = new BridgeOrchestrator(dir, { settings: makeSettings(), createClient, actorTiming: { debounceMs: 80, batchMaxMs: 250 } });
    expect(bridge.status().sessions[peer]?.phase).toBe('blocked-unknown');
    expect(bridge.status().sessions[peer]?.reason).toBe('send-unknown');
    expect(bridge.status().sessions[secondPeer]?.phase).toBe('idle');
    await expect(bridge.arm({ conversationId: peer, replyMode: 'auto', consent: true })).rejects.toThrow('send-unknown');
  } finally { await bridge.close(); await net.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('P0-2: 账号级共享游标越过暂停会话 A 时仍捕获叫停并跨重启锁定，不分发正文且不影响 B', async () => {
  const net = await mockNetwork({ v2: true });
  net.state.accountWideEvents = true;
  const dir = testDir();
  const makeSettings = () => settingsV2Schema.parse({
    schemaVersion: 2, xiaohe: { mcpUrl: net.mcp, accountId: binding.account_id, accountLabel: '测试' },
    models: [{ id: 'chat', name: 'Chat', kind: 'chat', mode: 'local', url: net.model, modelName: 'fixture' }],
    defaultModels: { replyPresetId: 'chat' }, memory: {}, runtime: {},
    conversations: { [peer]: session(peer), [secondPeer]: session(secondPeer) },
  });
  let bridge = new BridgeOrchestrator(dir, { settings: makeSettings(), actorTiming: { debounceMs: 80, batchMaxMs: 250 } });
  const received: string[] = [];
  bridge.bus.subscribe('message', ev => { received.push(ev.conversationId); });
  try {
    await bridge.arm({ conversationId: peer, replyMode: 'auto', consent: true });
    await bridge.arm({ conversationId: secondPeer, replyMode: 'auto', consent: true });
    await until(() => bridge.status().sessions[peer]?.phase === 'listening' && bridge.status().sessions[secondPeer]?.phase === 'listening');
    // 暂停 A（且无只读订阅），保持 B 监听
    bridge.pause(peer, 'user-paused');
    await until(() => bridge.status().sessions[peer]?.phase === 'paused');
    // A 收到叫停，B 收到正常闲聊；共享账号游标会推进越过两者
    net.push(incoming('stop-while-paused', peer, { text: '请别再给我发消息了' }), incoming('b-chat', secondPeer, { text: '今天天气不错' }));
    await until(() => net.calls.filter(c => c.name === 'messages.send_text' && c.args.conversation_id === secondPeer).length === 1);
    // A 的正文未被分发，但叫停已被持久化锁定
    expect(received).not.toContain(peer);
    expect(received).toContain(secondPeer);
    await expect(bridge.arm({ conversationId: peer, replyMode: 'auto', consent: true })).rejects.toThrow('peer-stopped');
    await bridge.close();

    // 重启后 status() 直接投影 locked-opt-out
    bridge = new BridgeOrchestrator(dir, { settings: makeSettings(), actorTiming: { debounceMs: 80, batchMaxMs: 250 } });
    expect(bridge.status().sessions[peer]?.phase).toBe('locked-opt-out');
    expect(bridge.status().sessions[peer]?.reason).toBe('peer-stopped');
    await expect(bridge.arm({ conversationId: peer, replyMode: 'auto', consent: true })).rejects.toThrow('peer-stopped');
  } finally { await bridge.close(); await net.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('小禾空读随机轮换游标、无关会话来信与群聊 @昵称 文本均能正常发信', async () => {
  const net = await mockNetwork({ v2: true });
  net.state.accountWideEvents = true;
  const dir = testDir();
  const accountLabel = '测试昵称';
  let nonce = 0;
  const realCursor = new Map<string, string | null>();
  // 模拟真实小禾 opaque1.* 游标：即使 0 条新事件，每次 events.read 也会返回新随机密文游标
  const createClient = (url: string, token?: string) => {
    const client = new XiaoheClient(url, { token });
    const origEvents = client.events.bind(client);
    client.events = async (scope, cursor, wait, signal) => {
      const underlying = cursor !== null && realCursor.has(cursor) ? realCursor.get(cursor)! : cursor;
      const page = await origEvents(scope, underlying, wait, signal);
      const rotated = `opaque1.rotated-${++nonce}`;
      realCursor.set(rotated, page.cursor);
      return { ...page, cursor: rotated };
    };
    return client;
  };
  const settings = settingsV2Schema.parse({
    schemaVersion: 2, xiaohe: { mcpUrl: net.mcp, accountId: binding.account_id, accountLabel },
    models: [{ id: 'chat', name: 'Chat', kind: 'chat', mode: 'local', url: net.model, modelName: 'fixture' }],
    defaultModels: { replyPresetId: 'chat' }, memory: {}, runtime: {},
    conversations: {
      [peer]: session(peer),
      [group]: session(group, { type: 'group', groupTrigger: 'mention_only' }),
    },
  });
  const bridge = new BridgeOrchestrator(dir, { settings, createClient, actorTiming: { debounceMs: 80, batchMaxMs: 250 } });
  try {
    // 1. 单独发送一条在空读游标每次轮换的情况下不应误报 send-fence
    await bridge.sendOneShot({ conversationId: peer, text: '测试单条发送', request: randomUUID(), consent: true });
    await until(() => net.calls.filter(c => c.name === 'messages.send_text' && c.args.conversation_id === peer).length === 1);

    // 2. 群聊 mention_only 识别小禾格式的 @昵称 文本（无 mentions 字段且 sender_name 为空）并成功回信
    await bridge.arm({ conversationId: group, replyMode: 'auto', consent: true, groupConfirmed: true });
    await until(() => bridge.status().sessions[group]?.phase === 'listening');
    // 3. 含敏感词/链接的普通消息在非严格模式下只跳过本轮，不会关闭群聊自动回复开关，下一条闲聊仍能正常回复
    net.push(incoming('group-manual', group, { sender_id: 'member_a', sender_name: '', text: `@${accountLabel}\u2005看看这个 https://example.com` }));
    await new Promise(r => setTimeout(r, 180));
    expect(bridge.status().sessions[group]?.phase).toBe('listening');
    expect(bridge.status().sessions[group]?.replyMode).toBe('auto');
    net.push(incoming('group-at-me', group, { sender_id: 'member_a', sender_name: '', text: `@${accountLabel}\u2005今天吃饭吗` }));
    await until(() => net.calls.filter(c => c.name === 'messages.send_text' && c.args.conversation_id === group).length === 1);
  } finally { await bridge.close(); await net.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('V3EngineApp: 迁移遗留旧版档案未含云端标记时不抛出 cloud-profile，平滑回退到 v2 托管记忆', async () => {
  const dir = testDir();
  const legacyFile = join(dir, 'legacy-persona.md');
  writeFileSync(legacyFile, '# 旧版私密档案\n没有任何 bridge-cloud 标记。\n', { mode: 0o600 });
  const app = new V3EngineApp(dir, () => {});
  try {
    const policy = session(peer);
    await app.orchestrator.applySettings(settingsV2Schema.parse({
      schemaVersion: 2,
      xiaohe: { mcpUrl: 'http://127.0.0.1:21454/mcp', accountId: binding.account_id, accountLabel: '测试' },
      models: [{ id: 'cloud', name: 'Cloud', kind: 'chat', mode: 'cloud', url: 'https://example.invalid/v1/chat/completions', modelName: 'gpt-test' }],
      defaultModels: { replyPresetId: 'cloud' },
      memory: { legacyStylePath: legacyFile, legacyMemoryPath: legacyFile },
      runtime: { approvedCloudPresetIds: ['cloud'] },
      conversations: { [peer]: policy },
    }));
    const assembler = app as unknown as {
      assemblePrompt: (p: typeof policy, mode: 'local' | 'cloud') => Promise<{ style?: string; memory?: string }>;
    };
    const result = await assembler.assemblePrompt(policy, 'cloud');
    expect(result.style ?? '').not.toContain('旧版私密档案');
    expect(result.memory ?? '').not.toContain('旧版私密档案');
  } finally {
    await app.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('HotBundleManager 校验 SHA-256 与 Ed25519 签名，拒绝篡改和符号链接，并接入 system.bundles IPC', async () => {
  const dir = testDir();
  const bundlesDir = join(dir, 'bundles');
  mkdirSync(bundlesDir, { mode: 0o700, recursive: true });
  const compatBody = Buffer.from(JSON.stringify({ disableReasoningEffortUrls: ['https://compat.example.invalid/v1/chat/completions'] }), 'utf8');
  const addonBody = Buffer.from('保持轻松口吻。', 'utf8');
  writeFileSync(join(bundlesDir, 'model-compat.json'), compatBody, { mode: 0o600 });
  writeFileSync(join(bundlesDir, 'reply-prompt-addon.md'), addonBody, { mode: 0o600 });
  const files = {
    'model-compat.json': createHash('sha256').update(compatBody).digest('hex'),
    'reply-prompt-addon.md': createHash('sha256').update(addonBody).digest('hex'),
  };
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const payload = JSON.stringify({ version: '2026.11.24', files });
  const signature = sign(null, Buffer.from(payload, 'utf8'), privateKey).toString('base64');
  const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' }).toString();
  writeFileSync(join(bundlesDir, 'manifest.json'), JSON.stringify({ version: '2026.11.24', files, signature, publicKeyPem }), { mode: 0o600 });

  const frames: unknown[] = [];
  const app = new V3EngineApp(dir, line => frames.push(JSON.parse(line)));
  try {
    await app.route(JSON.stringify({ v: 3, id: 91, method: 'system.bundles', params: { action: 'status' } }));
    const statusReply = rpcReplySchema('system.bundles').parse(frames.at(-1));
    expect(statusReply.ok).toBe(true);
    if (statusReply.ok) {
      const res = rpcSchemas['system.bundles'].result.parse(statusReply.result);
      expect(res.loadedCount).toBe(2);
      expect(res.version).toBe('2026.11.24');
      expect(res.items.every(i => i.verified)).toBe(true);
    }

    // 篡改资产后 reload 标记为 verified: false，且不应用其中的配置
    writeFileSync(join(bundlesDir, 'reply-prompt-addon.md'), '被篡改内容', { mode: 0o600 });
    await app.route(JSON.stringify({ v: 3, id: 92, method: 'system.bundles', params: { action: 'reload' } }));
    const reloadReply = rpcReplySchema('system.bundles').parse(frames.at(-1));
    expect(reloadReply.ok).toBe(true);
    if (reloadReply.ok) {
      const res = rpcSchemas['system.bundles'].result.parse(reloadReply.result);
      const addonItem = res.items.find(i => i.name === 'reply-prompt-addon.md');
      expect(addonItem?.verified).toBe(false);
    }

    // 符号链接被硬拒绝
    const outside = join(dir, 'outside.md');
    writeFileSync(outside, 'secret', { mode: 0o600 });
    symlinkSync(outside, join(bundlesDir, 'evil.md'));
    expect(() => new HotBundleManager(dir)).toThrow('storage-unavailable');
  } finally {
    await app.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('波次 B: 自适应防抖、防抖期并行预热上下文与 fastReplyMode 降档加速', async () => {
  const net = await mockNetwork({ v2: true });
  const dir = testDir();
  let assembleCalls = 0;
  const settings = settingsV2Schema.parse({
    schemaVersion: 2, xiaohe: { mcpUrl: net.mcp, accountId: binding.account_id, accountLabel: '测试' },
    models: [{ id: 'chat', name: 'Chat', kind: 'chat', mode: 'local', url: net.model, modelName: 'fixture' }],
    defaultModels: { replyPresetId: 'chat' }, memory: {}, runtime: { fastReplyMode: true },
    conversations: { [peer]: session(peer) },
  });
  // 不传 debounceMs，验证默认自适应防抖 260ms 快路径 + prewarm 缓存命中（assemblePrompt 只调 1 次）
  const bridge = new BridgeOrchestrator(dir, {
    settings,
    assemblePrompt: async () => { assembleCalls++; return { style: '简洁风格' }; },
  });
  try {
    await bridge.arm({ conversationId: peer, replyMode: 'auto', consent: true });
    await until(() => bridge.status().sessions[peer]?.phase === 'listening');
    const t0 = performance.now();
    net.push(incoming('fast-1', peer, { text: '今天天气怎么样？' }));
    await until(() => net.calls.filter(c => c.name === 'messages.send_text' && c.args.conversation_id === peer).length === 1);
    const elapsed = performance.now() - t0;
    expect(elapsed).toBeLessThan(2000);
    expect(assembleCalls).toBe(1);
    expect(net.models[0]?.reasoning_effort).toBe('low');
    expect(JSON.parse(net.models[0]?.messages[1].content)).not.toHaveProperty('context');
    const traces = bridge.sessionTraces({ conversationId: peer, limit: 20 }).items;
    expect(traces.some(item => item.stage === 'model' && item.summary.includes('首包') && item.summary.includes('effort=low'))).toBe(true);
  } finally {
    await bridge.close();
    await net.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

// ---- v2.2.0 #7：多模态实时闭环 + 原生引用回复 & 精准 @成员 ----

async function withPolicy(t: Awaited<ReturnType<typeof setup>>, id: string, extra: Record<string, unknown>) {
  const next = structuredClone(t.bridge.currentSettings);
  next.conversations[id] = { ...next.conversations[id]!, ...extra };
  await t.bridge.applySettings(next);
}
const replies = (t: Awaited<ReturnType<typeof setup>>, id: string) =>
  t.calls.filter(c => c.name === 'messages.reply' && c.args.conversation_id === id);

test('v2.2 #7 会话策略新字段向后兼容，默认关闭原生引用回复与 @ 发言人', () => {
  const legacy = conversationPolicySchema.parse({ conversationId: peer, label: peer, type: 'direct', enabled: true, replyMode: 'off' });
  expect(legacy.useNativeReply).toBe(false);
  expect(legacy.mentionReplySender).toBe(false);
});

test('v2.2 #7 useNativeReply 热更新后改用 messages.reply 并携带本轮最新来信 message_ref', async () => {
  const t = await setup();
  try {
    await t.arm(peer);
    await until(() => t.phase(peer) === 'listening');
    t.push(incoming('plain-1', peer));
    await until(() => t.sends(peer).length === 1);
    await until(() => t.phase(peer) === 'listening');
    expect(replies(t, peer)).toHaveLength(0);
    expect(t.sends(peer)[0]!.args.message_ref).toBeUndefined();

    await withPolicy(t, peer, { useNativeReply: true });
    // 热更新不暂停自动回复。
    expect(t.bridge.status().sessions[peer]).toMatchObject({ phase: 'listening', replyMode: 'auto' });
    t.push(incoming('native-1', peer));
    await until(() => replies(t, peer).length === 1);
    expect(replies(t, peer)[0]!.args).toMatchObject({ conversation_id: peer, message_ref: 'ref-native-1' });
    expect(replies(t, peer)[0]!.args.mention_user_ids).toBeUndefined();
    expect(t.sends(peer)).toHaveLength(1);
    expect(t.wireFaults).toEqual([]);
  } finally { await t.close(); }
});

test('v2.2 #7 群聊 mentionReplySender 传递去重后的本轮发言人 mention_user_ids', async () => {
  const t = await setup();
  try {
    await withPolicy(t, group, { groupTrigger: 'all', mentionReplySender: true });
    await t.arm(group);
    await until(() => t.phase(group) === 'listening');
    t.push(incoming('g-a1', group, { sender_id: 'member_a', text: '大家早' }),
      incoming('g-b1', group, { sender_id: 'member_b', text: '早上好' }),
      incoming('g-a2', group, { sender_id: 'member_a', text: '今天天气不错' }));
    await until(() => t.sends(group).length === 1);
    const ids = t.sends(group)[0]!.args.mention_user_ids as string[];
    expect([...ids].sort()).toEqual(['member_a', 'member_b']);
    expect(replies(t, group)).toHaveLength(0);
  } finally { await t.close(); }
});

test('v2.2 #7 群聊同时开启原生引用与 @ 发言人时走 messages.reply 并携带两者', async () => {
  const t = await setup();
  try {
    await withPolicy(t, group, { groupTrigger: 'all', mentionReplySender: true, useNativeReply: true });
    await t.arm(group);
    await until(() => t.phase(group) === 'listening');
    t.push(incoming('g-both', group, { sender_id: 'member_c', text: '这事怎么看？' }));
    await until(() => replies(t, group).length === 1);
    expect(replies(t, group)[0]!.args).toMatchObject({ message_ref: 'ref-g-both', mention_user_ids: ['member_c'] });
  } finally { await t.close(); }
});

test('v2.2 #7 小禾缺少 messages.reply 与 mention_user_ids 能力时自动降级为普通 messages.send_text', async () => {
  const t = await setup();
  t.state.hideReplyTool = true;
  t.state.hideMentionSend = true;
  try {
    await withPolicy(t, group, { groupTrigger: 'all', mentionReplySender: true, useNativeReply: true });
    await t.arm(group);
    await until(() => t.phase(group) === 'listening');
    expect(t.bridge.status().capabilities).toMatchObject({ nativeReply: false, mentionSend: false });
    t.push(incoming('g-degrade', group, { sender_id: 'member_d', text: '在吗？' }));
    await until(() => t.sends(group).length === 1);
    expect(t.calls.some(c => c.name === 'messages.reply')).toBe(false);
    expect(t.sends(group)[0]!.args.message_ref).toBeUndefined();
    expect(t.sends(group)[0]!.args.mention_user_ids).toBeUndefined();
  } finally { await t.close(); }
});

test('v2.2 #7 图片/语音富化写入耗时与失败原因轨迹，不记录解析正文', async () => {
  const t = await setup();
  try {
    await t.arm(peer);
    await until(() => t.phase(peer) === 'listening');
    const traces = () => t.bridge.sessionTraces({ conversationId: peer, limit: 100 }).items;
    t.push(picture('image-trace-ok'));
    await until(() => traces().some(entry => /^图片解析完成（耗时 \d+ms）$/.test(entry.summary)));
    await until(() => t.sends(peer).length === 1);

    t.state.mediaUnavailable = true;
    t.push(picture('image-trace-fail'));
    await until(() => traces().some(entry => entry.summary === '图片解析失败（mcp-contract）' && entry.level === 'warn'));

    // 未配置语音转写预设：降级并写出原因码。
    t.push(incoming('voice-trace', peer, { type: 'voice', text: '', attachments: [{ media_ref: 'voice-trace' }] }));
    await until(() => traces().some(entry => entry.summary === '语音解析失败（invalid-configuration）'));

    const serialized = JSON.stringify(traces());
    expect(serialized).not.toContain('一张日落照片');
    expect(serialized).not.toContain('ZmFrZQ==');
  } finally { await t.close(); }
});

test('设置页默认模型试拟例句不被风控拦截，真实调用试拟模型', async () => {
  const t = await setup();
  try {
    const res = await t.bridge.preview({
      model: { mode: 'local', url: t.model, name: 'fixture', stylePath: '', memoryPath: '', cloudApproved: false },
      text: '下楼刚好碰上有太阳',
    });
    expect(res).toEqual({ action: 'reply', text: '哈哈，那挺好' });
    expect(t.models.length).toBe(1);
    expect(t.sends(peer).length).toBe(0);
  } finally { await t.close(); }
});

// ---- v2.3.0 #21：勿扰时段控制 ----

const localClock = (h: number, m: number) => new Date(2026, 10, 25, h, m, 0).getTime();

test('v2.3 #21 isInQuietHours 正确判定同日、跨零点、关闭与空窗口', () => {
  expect(isInQuietHours(undefined, localClock(23, 30))).toBe(false);
  expect(isInQuietHours({ enabled: false, start: '23:00', end: '08:00', action: 'skip_turn' }, localClock(23, 30))).toBe(false);
  expect(isInQuietHours({ enabled: true, start: '23:00', end: '23:00', action: 'skip_turn' }, localClock(23, 0))).toBe(false);

  const overnight: QuietHoursConfig = { enabled: true, start: '23:00', end: '08:00', action: 'skip_turn' };
  expect(isInQuietHours(overnight, localClock(22, 59))).toBe(false);
  expect(isInQuietHours(overnight, localClock(23, 0))).toBe(true);
  expect(isInQuietHours(overnight, localClock(2, 15))).toBe(true);
  expect(isInQuietHours(overnight, localClock(7, 59))).toBe(true);
  expect(isInQuietHours(overnight, localClock(8, 0))).toBe(false);

  const midday: QuietHoursConfig = { enabled: true, start: '12:00', end: '14:00', action: 'draft_only' };
  expect(isInQuietHours(midday, localClock(11, 59))).toBe(false);
  expect(isInQuietHours(midday, localClock(12, 30))).toBe(true);
  expect(isInQuietHours(midday, localClock(14, 0))).toBe(false);
});

test('v2.3 #21 勿扰时段 skip_turn 跳过不调模型、draft_only 降级仅拟稿、豁免放行且不削弱叫停锁', async () => {
  let fakeNow = localClock(23, 30);
  const t = await setup({
    quietHours: { enabled: true, start: '23:00', end: '08:00', action: 'skip_turn' },
    quietHoursNow: () => fakeNow,
  });
  try {
    await t.arm(peer);
    await t.arm(secondPeer);
    await until(() => t.phase(peer) === 'listening' && t.phase(secondPeer) === 'listening');

    // 1. skip_turn：不调模型、不发信、写脱敏轨迹
    t.push(incoming('qh-skip-1', peer, { text: '深夜冒泡' }));
    await until(() => t.bridge.sessionTraces({ conversationId: peer, limit: 20 }).items.some(e => e.summary === '命中勿扰时段，已跳过本轮'));
    expect(t.models.length).toBe(0);
    expect(t.sends(peer).length).toBe(0);

    // 2. 热更新为 draft_only + 为 secondPeer 开启 ignoreQuietHours 豁免
    const next = structuredClone(t.bridge.currentSettings);
    next.runtime.quietHours.action = 'draft_only';
    next.conversations[secondPeer]!.ignoreQuietHours = true;
    await t.bridge.applySettings(next);

    // peer 命中勿扰并降级为只拟稿（调模型生成草稿，但绝不发信）
    t.push(incoming('qh-draft-1', peer, { text: '今天天气不错' }));
    await until(() => t.bridge.status().sessions[peer]?.draft === '哈哈，那挺好');
    expect(t.sends(peer).length).toBe(0);
    expect(t.bridge.sessionTraces({ conversationId: peer, limit: 20 }).items.some(e => e.summary === '命中勿扰时段，已降级为只拟稿')).toBe(true);

    // secondPeer 开启了 ignoreQuietHours 豁免，即使 23:30 也正常自动回复
    t.push(incoming('qh-exempt-1', secondPeer, { text: '下楼刚好碰上有太阳' }));
    await until(() => t.sends(secondPeer).length === 1);

    // 3. 安全铁律：勿扰时段（切回 skip_turn）收到对方叫停仍必须永久锁定 peer-stopped
    const nextSkip = structuredClone(t.bridge.currentSettings);
    nextSkip.runtime.quietHours.action = 'skip_turn';
    await t.bridge.applySettings(nextSkip);
    t.push(incoming('qh-stop-1', peer, { text: '别再自动回复了' }));
    await until(() => t.phase(peer) === 'locked-opt-out');
    expect(t.sends(peer).length).toBe(0);

    // 4. 离开勿扰时段（09:00）恢复正常
    fakeNow = localClock(9, 0);
    expect(isInQuietHours(t.bridge.currentSettings.runtime.quietHours, fakeNow)).toBe(false);
  } finally { await t.close(); }
});

// ---- v2.3.0 #22：会话级关键词触发白名单与忽略黑名单 ----

test('v2.3 #22 忽略词跳过、私聊白名单过滤、群聊被 @ 或命中触发词放行且不绕过叫停与风控', async () => {
  const t = await setup();
  try {
    // 配置私聊白名单+忽略词、群聊 mention_only + 触发词
    const next = structuredClone(t.bridge.currentSettings);
    next.conversations[peer]!.triggerKeywords = ['项目进度', 'BUG'];
    next.conversations[peer]!.ignoreKeywords = ['每日打卡', '+1'];
    next.conversations[group]!.groupTrigger = 'mention_only';
    next.conversations[group]!.triggerKeywords = ['上线'];
    await t.bridge.applySettings(next);

    await t.arm(peer);
    await t.arm(group);
    await until(() => t.phase(peer) === 'listening' && t.phase(group) === 'listening');

    // 1. 私聊命中忽略词（即使同时含触发词，忽略词优先跳过且零模型调用、轨迹不记词条或原文）
    t.push(incoming('kw-ign-1', peer, { text: '每日打卡项目进度，秘密内容XYZ' }));
    await until(() => t.bridge.sessionTraces({ conversationId: peer, limit: 20 }).items.some(e => e.summary === '命中忽略词，已跳过本轮'));
    expect(t.models.length).toBe(0);
    expect(t.sends(peer).length).toBe(0);
    const serializedTraces = JSON.stringify(t.bridge.sessionTraces({ conversationId: peer, limit: 20 }).items);
    expect(serializedTraces).not.toContain('每日打卡');
    expect(serializedTraces).not.toContain('秘密内容XYZ');

    // 2. 私聊未命中触发白名单 → 跳过不调模型
    t.push(incoming('kw-miss-1', peer, { text: '今天太阳不错' }));
    await until(() => t.bridge.sessionTraces({ conversationId: peer, limit: 20 }).items.some(e => e.summary === '未命中触发白名单词，已跳过本轮'));
    expect(t.models.length).toBe(0);

    // 3. 私聊命中白名单（大小写不敏感 'bug' 匹配 'BUG'）→ 正常回复
    t.push(incoming('kw-hit-1', peer, { text: '看下这个 bug 怎么修' }));
    await until(() => t.sends(peer).length === 1);

    // 4. 群聊 mention_only 下未 @ 但命中触发词 '上线' → 放行回复
    t.push(incoming('kw-grp-hit', group, { sender_id: secondPeer, text: '今晚准备上线了' }));
    await until(() => t.sends(group).length === 1);

    // 5. 群聊 mention_only 下既未 @ 也未命中触发词 → 跳过
    t.push(incoming('kw-grp-miss', group, { sender_id: secondPeer, text: '大家中午好' }));
    await until(() => t.bridge.sessionTraces({ conversationId: group, limit: 20 }).items.some(e => e.summary.includes('仅被 @ 或命中触发词时触发')));
    expect(t.sends(group).length).toBe(1);

    // 6. 安全铁律：即使命中白名单或忽略词，对方叫停仍永久锁定 peer-stopped
    t.push(incoming('kw-stop-1', peer, { text: '每日打卡，别再自动回复了' }));
    await until(() => t.phase(peer) === 'locked-opt-out');
  } finally { await t.close(); }
});
