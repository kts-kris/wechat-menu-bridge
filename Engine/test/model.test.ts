import { expect, spyOn, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { ReplyModel } from '../model.ts';
import { ModelClient, resetEndpointCapabilities } from '../src/llm/client.ts';
import { requestModel } from '../src/llm/request.ts';
import { ModelRouter } from '../src/llm/router.ts';
import { extractJsonObject, extractTokenUsage, readCompletionContent } from '../src/llm/sse.ts';
import { mockNetwork, syntheticText } from './fixture.ts';

function stubFetch(implementation: (...args: Parameters<typeof fetch>) => Promise<Response>) {
  const preconnect = () => { throw new Error('unexpected preconnection'); };
  return spyOn(globalThis, 'fetch').mockImplementation(Object.assign(implementation, { preconnect }));
}

test('模型只生成结构化决定，不接收会话标识、选择收件人或调用工具', async () => {
  const f = await mockNetwork();
  const dir = await mkdtemp(join(tmpdir(), 'wmb-model-'));
  try {
    const stylePath = join(dir, 'style.md');
    const memoryPath = join(dir, 'memory.md');
    await writeFile(stylePath, '合成风格：用短句', { mode: 0o600 });
    await writeFile(memoryPath, '合成记忆：不使用固定开头', { mode: 0o600 });
    const model = await ReplyModel.load({ mode: 'local', url: f.model, name: 'fixture', stylePath, memoryPath, cloudApproved: false });
    expect(await model.generate([syntheticText], [], new AbortController().signal)).toEqual({ action: 'reply', text: '哈哈，那挺好' });
    const body = f.models[0]!;
    expect(body.tools).toBeUndefined();
    const wire = JSON.stringify(body);
    for (const value of [syntheticText, '合成风格：用短句', '合成记忆：不使用固定开头']) expect(wire).toContain(value);
    for (const value of [stylePath, memoryPath, 'wxid_fixture', 'mock_account']) expect(wire).not.toContain(value);
    f.state.decision = { action: 'reply', text: '好哦', recipient: 'elsewhere' };
    await expect(model.generate([syntheticText], [], new AbortController().signal)).rejects.toMatchObject({ code: 'model-format' });
    await expect(ReplyModel.load({ mode: 'cloud', url: 'https://example.invalid/v1/chat/completions', name: 'fixture',
      stylePath, memoryPath, cloudApproved: false, apiKey: 'synthetic' })).rejects.toMatchObject({ code: 'cloud-not-approved' });
  } finally { await f.close(); await rm(dir, { recursive: true }); }
});

test('云端未获同意、缺密钥或档案标记不完整时不发请求', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'wmb-cloud-guard-'));
  const fetchStub = stubFetch(async () => { throw new Error('unexpected request'); });
  try {
    const stylePath = join(dir, 'style.md');
    const base = { mode: 'cloud', url: 'https://model.example.invalid/v1/chat/completions', name: 'fixture',
      stylePath, memoryPath: '', apiKey: 'synthetic-key-not-a-credential', cloudApproved: true };
    await expect(ReplyModel.load({ ...base, cloudApproved: false })).rejects.toMatchObject({ code: 'cloud-not-approved' });
    await expect(ReplyModel.load({ ...base, apiKey: undefined })).rejects.toMatchObject({ code: 'missing-key' });
    for (const document of [
      '本地内容，不上传',
      '示例语法：<!-- bridge-cloud:start --> 这段只是演示 <!-- bridge-cloud:end -->，不是许可。',
      '<!-- bridge-cloud:start -->\n<!-- bridge-cloud:end -->',
      '<!-- bridge-cloud:end -->\n句子\n<!-- bridge-cloud:start -->',
      '<!-- bridge-cloud:start -->\n未结束',
      '<!-- bridge-cloud:start -->\n<!-- bridge-cloud:start -->\n句子\n<!-- bridge-cloud:end -->',
      '```md\n<!-- bridge-cloud:start -->\n标记写法示例\n<!-- bridge-cloud:end -->\n```',
    ]) {
      await writeFile(stylePath, document, { mode: 0o600 });
      await expect(ReplyModel.load(base)).rejects.toMatchObject({ code: 'cloud-profile' });
    }
    expect(fetchStub).not.toHaveBeenCalled();
  } finally { fetchStub.mockRestore(); await rm(dir, { recursive: true }); }
});

test('已同意的云端请求只包含标记段和必要内容，凭据只归指定端点', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'wmb-cloud-wire-'));
  const fetchStub = stubFetch(async () => Response.json({
    choices: [{ finish_reason: 'stop', message: { content: JSON.stringify({ action: 'reply', text: '哈哈，那挺好' }) } }],
  }));
  try {
    const endpoint = 'https://model.example.invalid/route/v1/chat/completions';
    const stylePath = join(dir, 'style.md');
    const memoryPath = join(dir, 'memory.md');
    const key = 'synthetic-key-not-a-credential';
    await writeFile(stylePath, 'synthetic-local-only-before\n<!-- bridge-cloud:start -->\n回复自然一点\n<!-- bridge-cloud:end -->');
    await writeFile(memoryPath, '<!-- bridge-cloud:start -->\r\n不用固定称呼\r\n<!-- bridge-cloud:end -->\r\nsynthetic-local-only-after');
    const model = await ReplyModel.load({ mode: 'cloud', url: endpoint, name: 'fixture', stylePath, memoryPath, cloudApproved: true, apiKey: key });
    const context = ['过旧的合成上下文', '第一条', '第二条', '第三条', '第四条'].map(text => ({ from: 'peer' as const, text }));
    expect(await model.generate([syntheticText], context, new AbortController().signal)).toEqual({ action: 'reply', text: '哈哈，那挺好' });
    expect(fetchStub).toHaveBeenCalledTimes(1);
    const [url, request] = fetchStub.mock.calls[0]!;
    expect(String(url)).toBe(endpoint);
    expect(request).toMatchObject({ method: 'POST', redirect: 'error', credentials: 'omit' });
    expect(new Headers(request?.headers).get('authorization')).toBe(`Bearer ${key}`);
    const body = String(request?.body);
    expect(JSON.parse(JSON.parse(body).messages[1].content)).toEqual({
      style: '回复自然一点', memory: '不用固定称呼', context: context.slice(1), latest: [syntheticText],
    });
    for (const privateValue of [key, stylePath, memoryPath, 'synthetic-local-only-before', 'synthetic-local-only-after']) {
      expect(body).not.toContain(privateValue);
    }
    expect(JSON.parse(body).reasoning_effort).toBe('max');
  } finally { fetchStub.mockRestore(); await rm(dir, { recursive: true }); }
});

test('ModelClient 发送 reasoning_effort=max，遇 503 瞬时容量不足自动重试并在不支持该字段时回退', async () => {
  resetEndpointCapabilities();
  const seen: Record<string, unknown>[] = [];
  let calls = 0;
  const fetchStub = stubFetch(async (_url, init) => {
    calls++;
    seen.push(JSON.parse(String(init?.body)));
    if (calls === 1) {
      return Response.json({ error: { code: 'account_capacity_unavailable' } }, { status: 503 });
    }
    if (calls === 2) {
      return Response.json({ error: { message: 'unsupported parameter: reasoning_effort' } }, { status: 400 });
    }
    const sse = [
      'data: {"choices":[{"index":0,"delta":{"content":"{\\"action\\":\\"reply\\",\\"text\\":\\"收到，这就看看\\"}"}}]}',
      '',
      'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
      '',
      'data: [DONE]',
      '',
    ].join('\n');
    return new Response(sse, { status: 200, headers: { 'content-type': 'text/event-stream' } });
  });
  try {
    const client = new ModelClient({
      id: 'cloud-1', name: 'Cloud', kind: 'chat', mode: 'cloud',
      url: 'https://model.example.invalid/v1/chat/completions', modelName: 'gpt-6.1-sol',
      maxTokens: 320, temperature: 0.35,
    }, 'synthetic-key');
    const decision = await client.chat(['朱晓哲@运维: 随便看？'], [{ from: 'auto', text: '已经开源了' }]);
    expect(decision).toEqual({ action: 'reply', text: '收到，这就看看' });
    expect(calls).toBe(3);
    expect(seen[0]?.reasoning_effort).toBe('max');
    expect(seen[0]?.stream).toBe(true);
    expect(seen[0]?.max_tokens).toBe(4096);
    expect(seen[1]?.reasoning_effort).toBe('max');
    expect(seen[2]?.reasoning_effort).toBeUndefined();
    expect(await client.chat(['下一轮'], [])).toEqual(decision);
    expect(calls).toBe(4);
    expect(seen[3]?.reasoning_effort).toBeUndefined();
  } finally { fetchStub.mockRestore(); resetEndpointCapabilities(); }
});

const modelResponse = (content: string) => Response.json({
  choices: [{ finish_reason: 'stop', message: { content } }],
});
const testPreset = { id: 'primary', name: 'Primary', mode: 'cloud', kind: 'chat',
  url: 'https://resilience.example.invalid/v1/chat/completions', modelName: 'fixture',
  maxTokens: 320, temperature: 0.35 } as const;
const encoder = new TextEncoder();
const sseHeaders = { 'content-type': 'text/event-stream' };
const sseChunk = (content: string) => encoder.encode(`data: ${JSON.stringify({ choices: [{ delta: { content } }] })}\n\n`);

test('SSE 空闲超时会取消读取，即使已经收到部分正文', async () => {
  let cancelled = false;
  const response = new Response(new ReadableStream({
    start(controller) { controller.enqueue(sseChunk('部分正文')); },
    cancel() { cancelled = true; },
  }), { headers: sseHeaders });
  await expect(readCompletionContent(response, 1024, { idleTimeoutMs: 25 })).rejects.toMatchObject({ code: 'model-timeout' });
  expect(cancelled).toBe(true);
});

test('SSE 连续分块刷新空闲计时器，整条流可以超过一次空闲上限', async () => {
  let timer: ReturnType<typeof setInterval>;
  const response = new Response(new ReadableStream({
    start(controller) {
      let count = 0;
      timer = setInterval(() => {
        if (++count <= 6) controller.enqueue(sseChunk(String(count)));
        else { clearInterval(timer); controller.enqueue(encoder.encode('data: [DONE]\n\n')); controller.close(); }
      }, 20);
    },
    cancel() { clearInterval(timer); },
  }), { headers: sseHeaders });
  expect(await readCompletionContent(response, 2048, { idleTimeoutMs: 100 })).toBe('123456');
});

test('提取第一个合法顶层 JSON 对象并正确处理围栏、引号、转义和嵌套', () => {
  const payload = JSON.stringify({ nested: { text: '大括号 } 和转义引号 "' }, action: 'skip' });
  expect(extractJsonObject(`\`\`\`json\n${payload}\n\`\`\``)).toBe(payload);
  expect(extractJsonObject(`解释 {无效} {"坏":} ${payload} 结束 {"action":"manual"}`)).toBe(payload);
  expect(extractJsonObject(`解释 [{"action":"manual"}] ${payload}`)).toBe(payload);
  expect(() => extractJsonObject('[{"action":"skip"}]')).toThrow('model-format');
  expect(() => extractJsonObject('{"action":')).toThrow('model-format');
});

test('429 使用 Retry-After 秒数并最多重试两次，default 省略 reasoning_effort', async () => {
  const attempts: Record<string, unknown>[] = [], trace: string[] = [];
  const fetchStub = stubFetch(async (_url, init) => {
    attempts.push(JSON.parse(String(init?.body)));
    return new Response(null, { status: 429, headers: { 'retry-after': '0.001' } });
  });
  try {
    const client = new ModelClient({ ...testPreset, reasoningEffort: 'default' }, 'synthetic-key');
    const start = performance.now();
    await expect(client.chat(['你好'], [], undefined, undefined, 4000, (_level, summary) => trace.push(summary)))
      .rejects.toMatchObject({ code: 'model-limit' });
    expect(performance.now() - start).toBeGreaterThanOrEqual(950);
    expect(attempts).toHaveLength(3);
    expect(attempts.every(body => !Object.hasOwn(body, 'reasoning_effort'))).toBe(true);
    expect(trace.filter(summary => summary.includes('等待 500 ms'))).toHaveLength(2);
  } finally { fetchStub.mockRestore(); }
});

test('瞬时网络故障与 SSE 中途断流共享两次重试，最终可解析带说明的 JSON', async () => {
  const fetchStub = stubFetch(async () => {
    const count = fetchStub.mock.calls.length;
    if (count === 1) throw new TypeError('connection dropped');
    if (count === 2) return new Response(sseChunk('未结束的正文'), { headers: sseHeaders });
    return modelResponse('输出如下：{"action":"skip"}。');
  });
  try {
    const client = new ModelClient({ ...testPreset, reasoningEffort: 'low' }, 'synthetic-key');
    expect(await client.chat(['你好'], [])).toEqual({ action: 'skip' });
    expect(fetchStub).toHaveBeenCalledTimes(3);
    expect(JSON.parse(String(fetchStub.mock.calls[2]?.[1]?.body)).reasoning_effort).toBe('low');
  } finally { fetchStub.mockRestore(); }
});

test('格式纠错仅请求一次并保留原始问题', async () => {
  const fetchStub = stubFetch(async () => modelResponse('{"action":"invalid"}'));
  try {
    const client = new ModelClient(testPreset, 'synthetic-key');
    await expect(client.chat(['你好'], [])).rejects.toMatchObject({ code: 'model-format' });
    expect(fetchStub).toHaveBeenCalledTimes(2);
    const attempts = fetchStub.mock.calls.map(([, init]) => JSON.parse(String(init?.body)).messages);
    expect(attempts[1].slice(0, 2)).toEqual(attempts[0]);
    expect(attempts[1][2].content).toContain('决策 JSON 对象');
  } finally { fetchStub.mockRestore(); }
});

test('首次 SSE 空闲超时后从 max 降档到 high，且耗时受原有截止时间约束', async () => {
  const efforts: (string | undefined)[] = [], trace: string[] = [];
  const fetchStub = stubFetch(async (_url, init) => {
    efforts.push(JSON.parse(String(init?.body)).reasoning_effort);
    if (efforts.length === 1) return new Response(new ReadableStream(), { headers: sseHeaders });
    return modelResponse('{"action":"skip"}');
  });
  try {
    const text = await requestModel({ url: new URL(testPreset.url), mode: 'cloud', effort: 'max', timeoutMs: 1500,
      body: effort => JSON.stringify({ reasoning_effort: effort }),
      parse: (response, signal) => readCompletionContent(response, 1024, { idleTimeoutMs: 20, signal }),
      onTrace: (_level, summary) => trace.push(summary),
    });
    expect(text).toBe('{"action":"skip"}');
    expect(efforts).toEqual(['max', 'high']);
    expect(trace.some(summary => summary.includes('降为 high'))).toBe(true);
  } finally { fetchStub.mockRestore(); }
});

test('主模型三次 503 后切换到本地备用预设，且清除云端 API Key', async () => {
  const backups = 'http://127.0.0.1:53535/v1/chat/completions';
  const fetchStub = stubFetch(async url => String(url) === backups ? modelResponse('{"action":"manual"}') :
    new Response(null, { status: 503 }));
  try {
    const router = new ModelRouter([testPreset, { ...testPreset, id: 'backup', url: backups, mode: 'local' }]);
    const trace: string[] = [];
    expect(await router.chat('primary', ['你好'], [], { cloudApproved: true, apiKey: 'primary-secret',
      fallbackPresetId: 'backup', onTrace: (_level, summary) => trace.push(summary) })).toEqual({ action: 'manual' });
    expect(fetchStub.mock.calls.map(([url]) => String(url))).toEqual([testPreset.url, testPreset.url, testPreset.url, backups]);
    expect(new Headers(fetchStub.mock.calls[0]?.[1]?.headers).get('authorization')).toBe('Bearer primary-secret');
    expect(new Headers(fetchStub.mock.calls[3]?.[1]?.headers).get('authorization')).toBeNull();
    expect(trace.some(summary => summary.includes('切换备用模型'))).toBe(true);
  } finally { fetchStub.mockRestore(); }
});

test('fastReplyMode 仅将实时对话降档为 low，后台 summarize 仍保持 max 推理强度', async () => {
  const seen: Record<string, unknown>[] = [];
  const fetchStub = stubFetch(async (_url, init) => {
    seen.push(JSON.parse(String(init?.body)));
    return modelResponse(seen.length === 1 ? '{"action":"reply","text":"没问题哦"}' : '{"summary":"ok","operations":[]}');
  });
  try {
    const router = new ModelRouter([testPreset], () => 'synthetic-key');
    await router.chat('primary', ['你好呀'], [], { cloudApproved: true, fastReplyMode: true });
    await router.summarize('primary', 'sys', 'usr', { cloudApproved: true });
    expect(seen[0]?.reasoning_effort).toBe('low');
    expect(seen[0]?.max_tokens).toBe(512);
    expect(seen[1]?.reasoning_effort).toBe('max');
    expect(seen[1]?.max_tokens).toBe(4096);
  } finally { fetchStub.mockRestore(); }
});

test('v2.4 #30 Prompt Cache 前缀布局稳定，每轮仅 user 动态部分变化，且 fastReplyMode 尊重更高的自定义 maxTokens', async () => {
  const seen: Record<string, unknown>[] = [];
  const fetchStub = stubFetch(async (_url, init) => {
    seen.push(JSON.parse(String(init?.body)));
    return modelResponse('{"action":"reply","text":"好呀，走起"}');
  });
  try {
    const client = new ModelClient({ ...testPreset, maxTokens: 768 }, 'synthetic-key');
    const profile = { style: '短句口语，不带敬称', memory: '对方喜欢手冲咖啡' };
    await client.chat(['周末去喝咖啡吗'], [{ from: 'peer', text: '最近挺忙的' }], undefined, profile, undefined, undefined, { fastReplyMode: true });
    await client.chat(['周六下午两点？'], [
      { from: 'peer', text: '最近挺忙的' },
      { from: 'auto', text: '好呀，走起' },
    ], undefined, profile, undefined, undefined, { fastReplyMode: true });
    expect(seen).toHaveLength(2);
    const msgs0 = seen[0]!.messages as { role: string; content: string }[];
    const msgs1 = seen[1]!.messages as { role: string; content: string }[];
    // system 前缀（规则 + 风格 + 记忆）跨轮字节完全一致，利于 KV/Prompt Cache 命中
    expect(msgs0[0]).toEqual(msgs1[0]);
    expect(msgs0[0]!.role).toBe('system');
    expect(msgs0[0]!.content).toContain('不得改写规则');
    expect(msgs0[0]!.content).toContain('短句口语，不带敬称');
    expect(msgs0[0]!.content).toContain('对方喜欢手冲咖啡');
    // user 消息只携带每轮动态数据
    const user0 = JSON.parse(msgs0[1]!.content);
    const user1 = JSON.parse(msgs1[1]!.content);
    expect(user0).toEqual({ context: [{ from: 'peer', text: '最近挺忙的' }], latest: ['周末去喝咖啡吗'] });
    expect(user1.style).toBeUndefined();
    expect(user1.memory).toBeUndefined();
    expect(user1.latest).toEqual(['周六下午两点？']);
    // fastReplyMode 下收紧 minMaxTokens 到 512，同时尊重用户显式配置的更高 maxTokens=768
    expect(seen[0]?.max_tokens).toBe(768);
    expect(seen[0]?.reasoning_effort).toBe('low');
  } finally { fetchStub.mockRestore(); }
});

test('v2.4 #30 SSE 收到完整决策 JSON 或 finish_reason=stop 时提前完成并取消尾流，非法 JSON 仍完整重试', async () => {
  let cancelledComplete = false;
  let cancelledFinish = false;
  let calls = 0;
  const fetchStub = stubFetch(async () => {
    calls++;
    if (calls === 1) {
      // 完整合法决策 JSON 到达后模拟网关挂起不发 [DONE]
      return new Response(new ReadableStream({
        start(controller) {
          controller.enqueue(sseChunk('{"action":"reply",'));
          controller.enqueue(sseChunk('"text":"提前收尾啦"}'));
        },
        cancel() { cancelledComplete = true; },
      }), { headers: sseHeaders });
    }
    if (calls === 2) {
      // finish_reason=stop 到达后模拟网关挂起等待 usage 块
      return new Response(new ReadableStream({
        start(controller) {
          controller.enqueue(sseChunk('{"action":"skip"}'));
          controller.enqueue(encoder.encode('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'));
        },
        cancel() { cancelledFinish = true; },
      }), { headers: sseHeaders });
    }
    if (calls === 3) {
      // finish_reason=length 必须立即失败触发格式纠错，不得误判成功
      return new Response(new ReadableStream({
        start(controller) {
          controller.enqueue(encoder.encode('data: {"choices":[{"delta":{"content":"{\\"action\\":\\"reply\\","},"finish_reason":"length"}]}\n\n'));
        },
      }), { headers: sseHeaders });
    }
    return modelResponse('{"action":"skip"}');
  });
  try {
    const client = new ModelClient({ ...testPreset, reasoningEffort: 'low' }, 'synthetic-key');
    const t0 = performance.now();
    expect(await client.chat(['你好'], [])).toEqual({ action: 'reply', text: '提前收尾啦' });
    expect(performance.now() - t0).toBeLessThan(500);
    expect(cancelledComplete).toBe(true);

    const t1 = performance.now();
    expect(await client.chat(['再见'], [])).toEqual({ action: 'skip' });
    expect(performance.now() - t1).toBeLessThan(500);
    expect(cancelledFinish).toBe(true);

    // 独立验证 stopOnFinishReason 对非 JSON 正文在 finish_reason=stop 时同样提前取消尾流
    let cancelledPlain = false;
    const plainRes = new Response(new ReadableStream({
      start(controller) {
        controller.enqueue(sseChunk('普通正文'));
        controller.enqueue(encoder.encode('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'));
      },
      cancel() { cancelledPlain = true; },
    }), { headers: sseHeaders });
    const t2 = performance.now();
    expect(await readCompletionContent(plainRes, 1024, { idleTimeoutMs: 5000, stopOnFinishReason: true })).toBe('普通正文');
    expect(performance.now() - t2).toBeLessThan(500);
    expect(cancelledPlain).toBe(true);

    expect(await client.chat(['试试截断恢复'], [])).toEqual({ action: 'skip' });
    expect(calls).toBe(4);
  } finally { fetchStub.mockRestore(); }
});

test('v2.5 #36 usage 解析兼容 OpenAI/DeepSeek/Anthropic 缓存字段，SSE 尾包采集与 stream_options 400 自动降级', async () => {
  expect(extractTokenUsage({
    prompt_tokens: 1200, completion_tokens: 45, prompt_tokens_details: { cached_tokens: 960 },
  })).toEqual({ promptTokens: 1200, cachedTokens: 960, completionTokens: 45 });
  expect(extractTokenUsage({
    prompt_tokens: 500, completion_tokens: 30, prompt_cache_hit_tokens: 400,
  })).toEqual({ promptTokens: 500, cachedTokens: 400, completionTokens: 30 });
  expect(extractTokenUsage({
    input_tokens: 300, output_tokens: 20, cache_read_input_tokens: 999,
  })).toEqual({ promptTokens: 300, cachedTokens: 300, completionTokens: 20 });

  resetEndpointCapabilities();
  const seen: Record<string, unknown>[] = [];
  let calls = 0;
  const fetchStub = stubFetch(async (_url, init) => {
    calls++;
    seen.push(JSON.parse(String(init?.body)));
    if (calls === 1) {
      // 模拟 OpenAI 兼容流：先 content -> finish_reason=stop -> 尾包 usage（不含 [DONE] 且挂起）
      return new Response(new ReadableStream({
        start(controller) {
          controller.enqueue(sseChunk('{"action":"reply","text":"收到啦"}'));
          controller.enqueue(encoder.encode('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'));
          controller.enqueue(encoder.encode('data: {"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":28,"prompt_tokens_details":{"cached_tokens":750}}}\n\n'));
        },
      }), { headers: sseHeaders });
    }
    if (calls === 2) {
      return Response.json({ error: { message: 'unknown parameter: stream_options' } }, { status: 400 });
    }
    return Response.json({
      choices: [{ finish_reason: 'stop', message: { content: '{"action":"skip"}' } }],
      usage: { prompt_tokens: 400, completion_tokens: 12, prompt_cache_hit_tokens: 200 },
    });
  });
  try {
    const clientA = new ModelClient({ ...testPreset, url: 'https://usage-a.example.invalid/v1/chat/completions', reasoningEffort: 'low' }, 'synthetic-key');
    let timingA: { usage?: { promptTokens: number; cachedTokens: number; completionTokens: number } } | undefined;
    expect(await clientA.chat(['你好'], [], undefined, undefined, undefined, undefined, { onTiming: v => { timingA = v; } }))
      .toEqual({ action: 'reply', text: '收到啦' });
    expect(seen[0]?.stream_options).toEqual({ include_usage: true });
    expect(timingA?.usage).toEqual({ promptTokens: 1000, cachedTokens: 750, completionTokens: 28 });

    // 另一端点返回 400 不支持 stream_options → 自动移除并缓存端点能力
    const clientB = new ModelClient({ ...testPreset, url: 'https://usage-b.example.invalid/v1/chat/completions', reasoningEffort: 'low' }, 'synthetic-key');
    let timingB: { usage?: { promptTokens: number; cachedTokens: number; completionTokens: number } } | undefined;
    expect(await clientB.chat(['hi'], [], undefined, undefined, undefined, undefined, { onTiming: v => { timingB = v; } }))
      .toEqual({ action: 'skip' });
    expect(seen[1]?.stream_options).toEqual({ include_usage: true });
    expect(seen[2]?.stream_options).toBeUndefined();
    expect(timingB?.usage).toEqual({ promptTokens: 400, cachedTokens: 200, completionTokens: 12 });

    // 下一轮直接省略 stream_options，不再触发 400
    expect(await clientB.chat(['hi2'], [])).toEqual({ action: 'skip' });
    expect(seen[3]?.stream_options).toBeUndefined();
  } finally { fetchStub.mockRestore(); resetEndpointCapabilities(); }
});
