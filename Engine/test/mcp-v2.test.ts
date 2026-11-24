import { expect, test } from 'bun:test';
import { existsSync, mkdtempSync, rmSync, statSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ModelClient } from '../src/llm/client.ts';
import { ModelRouter } from '../src/llm/router.ts';
import { HistoryBackfiller } from '../src/mcp/backfill.ts';
import { XiaoheClient } from '../src/mcp/client.ts';
import { normalizeEvent } from '../src/mcp/ingest.ts';
import { MediaEnricher } from '../src/mcp/media.ts';
import { binding, event, group, mockNetwork, peer, scope, secondPeer, service } from './fixture.ts';

test('探测工具及账号授权，账号流可读取非 wxid 私聊、群聊和服务号', async () => {
  const net = await mockNetwork({ v2: true, token: 'fixture-token' });
  const client = new XiaoheClient(net.mcp, { token: 'fixture-token' });
  try {
    const caps = await client.listTools(binding.account_id);
    expect(Object.values(caps).every(Boolean)).toBe(true);
    expect((await client.accounts())[0]?.sendConversations).toEqual([peer, secondPeer, group]);
    expect((await client.conversations(binding)).conversations.map(row => [row.conversation_id, row.type]))
      .toContainEqual([secondPeer, 'direct']);
    expect((await client.conversations(binding)).conversations.map(row => row.conversation_id)).toContain(service);
    net.push(event('direct', { conversation_id: secondPeer, sender_id: secondPeer }), event('group', { conversation_id: group }));
    const rows = await client.events(binding, null);
    expect(rows.events).toHaveLength(2);
    expect(net.calls.find(call => call.name === 'events.read')?.args.conversation_id).toBeUndefined();
    expect((await client.events({ ...binding, conversation_id: group }, null)).events).toHaveLength(1);
    net.state.accountWideEvents = false;
    expect((await client.listTools()).accountWideEvents).toBe(false);
    // 小禾 send_conversations 为 ["*"] 时应放行该账号下任意目标会话发信。
    net.state.sendConversations = ['*'];
    expect((await client.identify(binding.account_id, undefined, true, 'wxid_any_wildcard_target')).binding.account_id)
      .toBe(binding.account_id);
    expect(net.wireFaults).toEqual([]);
  } finally { await client.close(); await net.close(); }
});

test('群成员缓存按登录代际分域，保留最近使用项并在 30 分钟过期', async () => {
  const net = await mockNetwork({ v2: true });
  let now = Date.now();
  const client = new XiaoheClient(net.mcp, { groupCacheSize: 1, now: () => now });
  try {
    const scope = { ...binding, conversation_id: group };
    const first = await client.groupMembers(scope);
    expect(first[0]?.userId).toBe(secondPeer);
    first.pop();
    expect(await client.groupMembers(scope)).toHaveLength(2);
    expect(net.calls.filter(call => call.name === 'groups.members')).toHaveLength(1);
    await client.groupMembers({ ...scope, conversation_id: 'another-group@chatroom' });
    await client.groupMembers(scope);
    now += 30 * 60_000;
    await client.groupMembers(scope);
    net.state.generation = 'new-generation';
    await client.groupMembers({ ...scope, login_generation: net.state.generation });
    expect(net.calls.filter(call => call.name === 'groups.members')).toHaveLength(5);
    expect(net.wireFaults).toEqual([]);
  } finally { await client.close(); await net.close(); }
});

test('历史查询从空页继续，固定筛选条件，强制历史标记并支持取消', async () => {
  const net = await mockNetwork({ v2: true });
  const client = new XiaoheClient(net.mcp);
  try {
    net.state.historyEmptyPage = true;
    net.push(event('history', { origin: 'live' }));
    const backfill = new HistoryBackfiller(client);
    const origins: string[] = [], progress: number[] = [];
    expect(await backfill.run('job', { purpose: 'context', conversationId: peer, recentCount: 3 }, scope, 'direct', 'route', 'identity', {
      onEvent: input => { origins.push(input.event.origin); }, onProgress: p => { progress.push(p.fetched); },
    })).toBe(1);
    expect(origins).toEqual(['backfill']);
    expect(progress).toEqual([0, 0, 1]);
    expect(net.calls.filter(call => call.name === 'messages.query').map(call => [call.args.recent_count, call.args.cursor]))
      .toEqual([[3, undefined], [3, 'history-0']]);
    const controller = new AbortController();
    controller.abort();
    await expect(backfill.run('cancelled', { purpose: 'context', conversationId: peer }, scope, 'direct', 'route', 'identity', {
      signal: controller.signal, onEvent: () => { throw new Error('unexpected event'); },
    })).rejects.toThrow('stopped');
  } finally { await client.close(); await net.close(); }
});

test('订阅后解析图片和语音，缺失媒体降级，引用回复验证发送闸门', async () => {
  const net = await mockNetwork({ v2: true });
  const client = new XiaoheClient(net.mcp);
  const dir = mkdtempSync(join(tmpdir(), 'wmb-v2-media-'));
  const router = new ModelRouter([
    { id: 'vision', name: 'Vision', kind: 'vision', mode: 'local', url: net.model, modelName: 'fixture', maxTokens: 240, temperature: 0.35 },
    { id: 'stt', name: 'STT', kind: 'stt', mode: 'local', url: net.stt, modelName: 'fixture', maxTokens: 240, temperature: 0.35 },
  ]);
  let subscribed = false;
  const media = new MediaEnricher(dir, router, () => subscribed);
  const input = (kind: string) => normalizeEvent(event(kind, {
    type: kind, text: '', attachments: [{ media_ref: kind + '-preview' }],
  }), scope, 'direct', 'live', 'route', 'identity')!;
  try {
    await media.enrich(input('image'), scope, client, { visionPresetId: 'vision' });
    expect(net.calls).toHaveLength(0);
    subscribed = true;
    const image = (await media.enrich(input('image'), scope, client, { visionPresetId: 'vision' })).event;
    expect(image.text).toBe('一张日落照片');
    expect(statSync(join(dir, 'media-cache')).mode & 0o777).toBe(0o700);
    expect(statSync(image.media!.localTempPath!).mode & 0o777).toBe(0o600);
    const voice = (await media.enrich(input('voice'), scope, client, { sttPresetId: 'stt', allowDownload: true })).event;
    expect(voice.text).toBe('小禾语音转写');
    const expired = new Date(Date.now() - 25 * 60 * 60_000);
    utimesSync(image.media!.localTempPath!, expired, expired);
    media.prune();
    expect(existsSync(image.media!.localTempPath!)).toBe(false);
    expect(existsSync(voice.media!.localTempPath!)).toBe(true);
    expect(net.calls.find(call => call.args.media_ref === 'voice-preview')?.args.allow_download).toBe(false);
    net.state.mediaUnavailable = true;
    expect((await media.enrich(input('image'), scope, client, { visionPresetId: 'vision' })).event).toMatchObject({
      text: '[图片]', media: { enrichmentStatus: 'degraded' },
    });
    expect((await media.enrich(input('voice'), scope, client, { sttPresetId: 'stt' })).event.text).toBe('[语音]');
    let called = 0;
    expect(await client.reply({ ...scope, conversation_id: group }, 'group-ref', '你好', 'attempt', () => { called++; }, [secondPeer]))
      .toMatchObject({ status: 'submitted' });
    expect(called).toBe(1);
    expect(net.calls.find(c => c.name === 'messages.reply')?.args).toMatchObject({
      message_ref: 'group-ref', mention_user_ids: [secondPeer],
    });
    await expect(client.sendText(scope, 'blocked', 'denied', () => { throw new Error('gate rejected'); })).rejects.toThrow('gate rejected');
    expect(net.calls.filter(c => c.name === 'messages.send_text')).toHaveLength(0);
    expect(net.wireFaults).toEqual([]);
  } finally { await client.close(); await net.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('ModelClient 支持 Markdown JSON 围栏、放宽推理令牌上限并正确返回 model-timeout', async () => {
  const seenMaxTokens: number[] = [];
  let mode: 'fence' | 'slow' | 'summary' = 'fence';
  const server = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    async fetch(req) {
      const body = await req.json() as { max_tokens?: number };
      if (typeof body.max_tokens === 'number') seenMaxTokens.push(body.max_tokens);
      if (mode === 'slow') {
        await new Promise(resolve => setTimeout(resolve, 400));
      }
      const content = mode === 'summary' ? '摘要完成' : '```json\n{"action":"reply","text":"好呀，晚上见"}\n```';
      return Response.json({ choices: [{ finish_reason: 'stop', message: { content } }] });
    },
  });
  try {
    const preset = {
      id: 'local', name: 'Local', mode: 'local' as const, kind: 'chat' as const,
      url: `http://127.0.0.1:${server.port}/v1/chat/completions`, modelName: 'test-model', maxTokens: 320, temperature: 0.35,
    };
    const client = new ModelClient(preset);
    expect(await client.chat(['晚上吃什么'], [])).toEqual({ action: 'reply', text: '好呀，晚上见' });
    mode = 'summary';
    expect(await client.summarize([{ role: 'user', content: '总结一下' }])).toBe('摘要完成');
    expect(seenMaxTokens[0]).toBeGreaterThanOrEqual(1024);
    expect(seenMaxTokens[1]).toBeGreaterThanOrEqual(2048);
    mode = 'slow';
    await expect(client.chat(['慢响应'], [], undefined, undefined, 100)).rejects.toMatchObject({ code: 'model-timeout' });
  } finally {
    server.stop(true);
  }
});

test('ModelClient 支持 SSE 流式分片（含跨块 UTF-8、reasoning_content 与异常拦截）', async () => {
  let seenStream: boolean | undefined;
  let scenario: 'ok' | 'tool_calls' | 'length' = 'ok';
  const server = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    async fetch(req) {
      const body = await req.json() as { stream?: boolean };
      seenStream = body.stream;
      const enc = new TextEncoder();
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(enc.encode(': keep-alive\n\n'));
          controller.enqueue(enc.encode('data: {"choices":[{"delta":{"reasoning_content":"先想一下"}}]}\n\n'));
          if (scenario === 'tool_calls') {
            controller.enqueue(enc.encode('data: {"choices":[{"delta":{"tool_calls":[{"id":"1"}]}}]}\n\n'));
            controller.enqueue(enc.encode('data: [DONE]\n\n'));
            controller.close();
            return;
          }
          const line = enc.encode('data: {"choices":[{"delta":{"content":"{\\"action\\":\\"reply\\",\\"text\\":\\"晚上去吃火锅\\"}"}}]}\n\n');
          // 刻意在多字节中文 UTF-8 中间切块，验证流式解码器不乱码。
          const mid = Math.floor(line.length * 0.72);
          controller.enqueue(line.subarray(0, mid));
          controller.enqueue(line.subarray(mid));
          const finish = scenario === 'length' ? 'length' : 'stop';
          controller.enqueue(enc.encode(`data: {"choices":[{"delta":{},"finish_reason":"${finish}"}]}\n\n`));
          controller.enqueue(enc.encode('data: [DONE]\n\n'));
          controller.close();
        },
      });
      return new Response(stream, { headers: { 'content-type': 'text/event-stream; charset=utf-8' } });
    },
  });
  try {
    const preset = {
      id: 'local', name: 'Local', mode: 'local' as const, kind: 'chat' as const,
      url: `http://127.0.0.1:${server.port}/v1/chat/completions`, modelName: 'test-sse', maxTokens: 320, temperature: 0.35,
    };
    const client = new ModelClient(preset);
    expect(await client.chat(['晚上吃啥'], [])).toEqual({ action: 'reply', text: '晚上去吃火锅' });
    expect(seenStream).toBe(true);
    scenario = 'tool_calls';
    await expect(client.chat(['工具调用'], [])).rejects.toMatchObject({ code: 'model-format' });
    scenario = 'length';
    await expect(client.chat(['被截断'], [])).rejects.toMatchObject({ code: 'model-format' });
  } finally {
    server.stop(true);
  }
});
