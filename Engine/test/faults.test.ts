import { expect, setSystemTime, test } from 'bun:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { Bridge } from '../engine.ts';
import { binding, event, latch, mockNetwork, peer, reply, syntheticText, until } from './fixture.ts';

async function fixture(run: (h: Awaited<ReturnType<typeof harness>>) => Promise<void>) {
  const h = await harness();
  try { await run(h); expect(h.f.wireFaults).toEqual([]); }
  finally { await h.dispose(); }
}

async function harness() {
  const f = await mockNetwork();
  const dir = await mkdtemp(join(tmpdir(), 'wmb-fault-'));
  let b = new Bridge(dir);
  const target = { mcp: f.mcp, account: binding.account_id, contact: peer };
  const model = { mode: 'local', url: f.model, name: 'fixture', stylePath: '', memoryPath: '', cloudApproved: false };
  const grant = (patch: Record<string, unknown> = {}) => ({ target, model, dryRun: false, consent: true, ...patch });
  const active = (patch: { text?: string; at?: number; request?: string } = {}) => ({ target, consent: true, text: '合成的主动发送', request: randomUUID(), ...patch });
  const sends = () => f.calls.filter(c => c.name === 'messages.send_text');
  const waits = () => f.calls.filter(c => c.name === 'events.wait');
  async function arm(patch: Record<string, unknown> = {}) {
    const n = waits().length;
    await b.arm(grant(patch));
    await until(() => waits().length > n);
  }
  return { f, dir, get b() { return b; }, target, grant, active, sends, waits, arm,
    reason: (reason: string, ms?: number) => until(() => b.status().reason === reason, ms),
    async restart() { await b.close(); b = new Bridge(dir); b.inspect(target); },
    async dispose() { await b.close(); await f.close(); await rm(dir, { recursive: true }); },
  };
}

test('暂停发生在模型返回前，取消且不落正文；重启不恢复授权', async () => fixture(async h => {
  const model = h.f.state.modelHold = latch();
  await h.arm();
  h.f.push(event('private', { text: '合成留存检查原文：天气晴朗' }));
  await until(() => h.f.models.length === 1);
  h.b.pause();
  model.release();
  await h.restart();
  expect(h.b.status()).toMatchObject({ phase: 'idle', running: false, autoReply: false, inFlight: false, dryRun: false });
  expect(h.sends()).toHaveLength(0);
  expect((await readFile(join(h.dir, 'bridge.sqlite'))).includes(Buffer.from('合成留存检查原文'))).toBe(false);
}));

test('拟稿期间来了下一句，合并未回答的两句，只提交一次', async () => fixture(async h => {
  const hold = h.f.state.modelHold = latch();
  await h.arm();
  h.f.push(event('burst-first', { text: '刚出门' }));
  await until(() => h.f.models.length === 1);
  h.f.push(event('burst-next', { text: '外面下雨了' }));
  // The first response is still held: the coalesced request must not wait for it.
  await until(() => h.f.models.length === 2);
  hold.release();
  await until(() => h.b.status().statistics?.count === 1);
  expect(h.f.models.map(m => JSON.parse(m.messages[1].content).latest)).toEqual([
    ['刚出门'], ['刚出门', '外面下雨了'],
  ]);
  expect(h.sends()).toHaveLength(1);
}));

test('模型还未返回时收到对方叫停，不继续提交且不能直接再开', async () => fixture(async h => {
  const hold = h.f.state.modelHold = latch();
  await h.arm();
  h.f.push(event('generating'));
  await until(() => h.f.models.length === 1);
  h.f.push(event('stop-while-generating', { text: '关掉自动回复吧' }));
  await h.reason('peer-stopped');
  hold.release();
  expect(h.b.status()).toMatchObject({ peerStopped: true, autoReply: false });
  await expect(h.b.arm(h.grant())).rejects.toMatchObject({ code: 'peer-stopped' });
  expect(h.sends()).toHaveLength(0);
}));

test('对方明确禁止机器代聊时锁定联系人，不调用模型或提交并跨重启保留', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: '好呀，知道啦' };
  await h.arm();
  h.f.push(event('forbid-machine-chat', { text: '禁止机器代聊，不要再由它跟我说话' }));
  await h.reason('peer-stopped');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
  await h.restart();
  expect(h.b.status()).toMatchObject({ peerStopped: true, autoReply: false });
  await expect(h.b.arm(h.grant())).rejects.toMatchObject({ code: 'peer-stopped' });
}));

test('对方不愿 AI 替本人回复时停止，不依赖模型判断', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: '知道啦' };
  await h.arm();
  h.f.push(event('decline-ai', { text: '我不愿意让 AI 替你回复我' }));
  await h.reason('peer-stopped');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('对方要求别再找他时停止，不依赖模型判断', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: reply };
  await h.arm();
  h.f.push(event('stop-contacting', { text: '别再找我了' }));
  await h.reason('peer-stopped');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('对方不愿与机器人说话时停止，不依赖模型判断', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: reply };
  await h.arm();
  h.f.push(event('stop-bot-talk', { text: '我不愿意跟机器人说话' }));
  await h.reason('peer-stopped');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('对方要求不要再发任何消息时停止', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: reply };
  await h.arm();
  h.f.push(event('stop-any-message', { text: '请别再给我发任何消息了' }));
  await h.reason('peer-stopped');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('只说上个问题不用回复时暂停核对，不误记为全局拒绝', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: reply };
  await h.arm();
  h.f.push(event('scoped-no-reply', { text: '上次的问题不用回复了，我们聊聊风景吧' }));
  await h.reason('manual-review');
  expect(h.b.status()).toMatchObject({ peerStopped: false, autoReply: false });
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('限定话题不回复之外另有全局叫停时仍锁定联系人', async () => fixture(async h => {
  await h.arm();
  h.f.push(event('scoped-and-stop', { text: '上次的问题不用回复了，请别再联系我' }));
  await h.reason('peer-stopped');
  expect(h.b.status()).toMatchObject({ peerStopped: true, autoReply: false });
  expect(h.sends()).toHaveLength(0);
}));

test('超长来信末尾的叫停也锁定联系人，重启后不能直接重开', async () => fixture(async h => {
  await h.arm();
  h.f.push(event('long-stop', { text: '前言'.repeat(2100) + '别再给我发消息了' }));
  await h.reason('peer-stopped');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
  await h.restart();
  await expect(h.b.arm(h.grant())).rejects.toMatchObject({ code: 'peer-stopped' });
}));

test('发送前读到新来信，等监听游标跟上再合并，不提交旧稿', async () => fixture(async h => {
  await h.arm();
  const fence = h.f.state.readHold = latch();
  h.f.push(event('before-fence', { text: '这边天晴了' }));
  await until(() => h.waits().some(c => c.args.cursor === 'c1') && h.f.calls.filter(c => c.name === 'events.read').length >= 2);
  const reader = h.f.state.waitHold = latch();
  h.f.push(event('ahead-of-reader', { text: '风也停了' }));
  fence.release();
  await until(() => h.b.status().phase === 'listening');
  expect(h.sends()).toHaveLength(0);
  expect(h.f.models).toHaveLength(1);
  reader.release();
  await until(() => h.b.status().statistics?.count === 1);
  expect(h.f.models.map(m => JSON.parse(m.messages[1].content).latest)).toEqual([['这边天晴了'], ['这边天晴了', '风也停了']]);
  expect(h.sends()).toHaveLength(1);
}));

test('发送检查已看到新叫停时不提交，等待监听器处理并锁定', async () => fixture(async h => {
  await h.arm();
  const fence = h.f.state.readHold = latch();
  h.f.push(event('before-stop-fence', { text: '这边天晴了' }));
  await until(() => h.waits().some(c => c.args.cursor === 'c1') && h.f.calls.filter(c => c.name === 'events.read').length >= 2);
  const reader = h.f.state.waitHold = latch();
  h.f.push(event('stop-at-fence', { text: '不要再自动回复了' }));
  fence.release();
  await until(() => h.b.status().phase === 'listening');
  expect(h.sends()).toHaveLength(0);
  reader.release();
  await h.reason('peer-stopped');
  expect(h.b.status()).toMatchObject({ peerStopped: true, autoReply: false });
  expect(h.sends()).toHaveLength(0);
}));

test('检查快照之后才到的叫停可能晚于本次提交，随后仍锁定联系人', async () => fixture(async h => {
  const model = h.f.state.modelHold = latch();
  await h.arm();
  h.f.push(event('before-stale-snapshot', { text: '这边天晴了' }));
  await until(() => h.f.models.length === 1 && h.waits().some(c => c.args.cursor === 'c1'));
  const reader = h.f.state.waitHold = latch();
  let injected = false;
  h.f.state.afterReadSnapshot = () => {
    injected = true;
    h.f.push(event('stop-after-snapshot', { text: '不要再自动回复了' }));
  };
  model.release();
  await until(() => h.sends().length === 1);
  expect(injected).toBe(true);
  expect(h.b.status().peerStopped).toBe(false);
  reader.release();
  await h.reason('peer-stopped');
  expect(h.b.status()).toMatchObject({ peerStopped: true, autoReply: false });
  expect(h.sends()).toHaveLength(1);
}));

test('单次定时仍只在当天有效，过了零点尚未提交就取消', async () => fixture(async h => {
  const midnight = new Date(2026, 10, 20).getTime();
  setSystemTime(new Date(midnight - 1200));
  try {
    await expect(h.b.active(h.active({ at: midnight }))).rejects.toMatchObject({ code: 'invalid-expiry' });
    await h.b.active(h.active({ at: midnight - 200 }));
    expect(h.b.status()).toMatchObject({ phase: 'scheduled', running: true, autoReply: false });
    setSystemTime(new Date(midnight + 40));
    await h.reason('expired');
    expect(h.sends()).toHaveLength(0);
  } finally { setSystemTime(); }
}));

test('自动回复跨过本地零点后，不重新开启也会处理新来信', async () => fixture(async h => {
  const midnight = new Date(2026, 10, 20).getTime();
  setSystemTime(new Date(midnight - 1200));
  try {
    await h.arm();
    const listeningSession = h.waits()[0]!.session;
    setSystemTime(new Date(midnight + 40));
    h.f.push(event('after-midnight'));
    await until(() => (h.b.status().phase === 'listening' && h.b.status().receipt?.status === 'submitted') || h.b.status().reason === 'expired');
    expect(h.b.status()).toMatchObject({ phase: 'listening', autoReply: true, receipt: { status: 'submitted' } });
    expect(h.waits().filter(c => c.session !== listeningSession)).toHaveLength(0);
    expect(h.sends()).toHaveLength(1);
  } finally { setSystemTime(); }
}));

test('同一天超过旧版默认的 12 次仍可自动回复', async () => fixture(async h => {
  const start = new Date(2026, 10, 20, 12).getTime();
  setSystemTime(new Date(start));
  try {
    await h.arm();
    for (let i = 1; i <= 13; i++) {
      setSystemTime(new Date(start + i * 800));
      h.f.push(event(`uncapped-${i}`));
      await until(() => h.b.status().statistics?.count === i || !h.b.status().autoReply);
      expect(h.b.status().autoReply).toBe(true);
    }
    expect(h.sends()).toHaveLength(13);
  } finally { setSystemTime(); }
}), 15_000);

test('只拟稿不需要发送权限，只显示临时草稿', async () => fixture(async h => {
  h.f.state.writePermission = false;
  await h.arm({ dryRun: true });
  h.f.push(event('dry'));
  await h.reason('draft-ready');
  expect(h.b.status().draft).toBe(reply);
  expect(h.sends()).toHaveLength(0);
  h.b.pause();
  expect(h.b.status().draft).toBeUndefined();
  await expect(h.b.arm(h.grant())).rejects.toMatchObject({ code: 'wechat-permission' });
}));

test('正文不足只按引用取锚点；其他联系人返回的锚点不会进入模型', async () => fixture(async h => {
  await h.arm();
  const row = event('needs-anchor', { text: '' });
  h.f.state.anchorOverride = { ...row, text: syntheticText };
  h.f.push(row);
  await until(() => h.b.status().receipt?.status === 'submitted');
  const calls = h.f.calls.filter(c => c.name === 'messages.get_context');
  expect(calls.map(c => c.args)).toEqual([{ ...binding, conversation_id: peer, message_ref: row.message_ref, before: 0, after: 0 }]);
  const another = event('bad-anchor', { text: '' });
  h.f.state.anchorOverride = { ...another, sender_id: 'wxid_other', text: syntheticText };
  h.f.push(another);
  await h.reason('wrong-anchor');
  expect(h.sends()).toHaveLength(1);
  expect(h.f.models).toHaveLength(1);
}));

test('来信正文和锚点均不可用时暂停，不得跳过后续消息直接发送', async () => fixture(async h => {
  await h.arm();
  h.f.push(event('unavailable-anchor', { text: '' }), event('after-unavailable', { text: '今天的云真好看' }));
  await until(() => h.sends().length > 0 || h.b.status().reason === 'manual-review');
  expect(h.b.status()).toMatchObject({ reason: 'manual-review', autoReply: false });
  expect(h.f.calls.filter(c => c.name === 'messages.get_context')).toHaveLength(1);
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('同页先有取不到的正文，后有明确叫停时仍锁定联系人', async () => fixture(async h => {
  await h.arm();
  h.f.push(event('unavailable-before-stop', { text: '' }), event('stop-after-unavailable', { text: '不要再自动回复了' }));
  await h.reason('peer-stopped');
  await h.restart();
  expect(h.b.status()).toMatchObject({ peerStopped: true, autoReply: false });
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('真人接管优先于排队拟稿；可识别本 App 的发送事件', async () => fixture(async h => {
  await h.arm();
  h.f.push(event('own-check'));
  await until(() => h.b.status().receipt?.status === 'submitted');
  const request = h.sends()[0]!.args.client_request_id;
  h.f.push(event('own-saved', { is_self: true, client_request_id: request }), event('next'));
  await until(() => h.sends().length === 2);
  await until(() => !h.b.status().inFlight);
  h.f.push(event('queued'), event('human', { is_self: true, sender_id: 'wxid_self' }));
  await h.reason('manual-takeover');
  expect(h.sends()).toHaveLength(2);
}));

test('身份询问如实说明；对方叫停时取消发送并跨进程封存同意', async () => fixture(async h => {
  await h.arm();
  h.f.push(event('identity', { text: '你是机器人吗？' }));
  await until(() => h.b.status().receipt?.status === 'submitted');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends().map(c => c.args.text)).toEqual(['这是他设置的自动回复，不是本人在打字。']);
  h.f.push(event('stop', { text: '别再给我发消息了' }));
  await h.reason('peer-stopped');
  await h.restart();
  expect(h.b.status().peerStopped).toBe(true);
  await expect(h.b.active(h.active())).rejects.toMatchObject({ code: 'peer-stopped' });
  h.b.restoreConsent(h.target);
  expect(h.b.status().peerStopped).toBe(false);
  expect(h.sends()).toHaveLength(1);
}));

test('金钱请求转人工，不能因模型会给出付款承诺而提交', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: '下个礼拜给你' };
  await h.arm();
  h.f.push(event('payment-request', { text: '钱下个礼拜给我好不？' }));
  await h.reason('manual-review');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
  expect(h.b.status().autoReply).toBe(false);
}));

test('普通闲聊中提到姓钱的人，不因姓名直接拦截', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: reply };
  await h.arm();
  h.f.push(event('name-qian', { text: '小钱说今天的云真好看' }));
  await until(() => h.b.status().receipt?.status === 'submitted');
  expect(h.f.models).toHaveLength(1);
  expect(h.sends().map(c => c.args.text)).toEqual([reply]);
}));

test('提到姓钱的人同时仍有借钱请求，仍须转人工', async () => fixture(async h => {
  await h.arm();
  h.f.push(event('name-and-money', { text: '小钱说借钱给他' }));
  await h.reason('manual-review');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('普通闲聊中提到电影年份，不因年份直接拦截', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: reply };
  await h.arm();
  h.f.push(event('film-year', { text: '昨天看了一部1997年的电影，挺好看' }));
  await until(() => h.b.status().receipt?.status === 'submitted');
  expect(h.f.models).toHaveLength(1);
  expect(h.sends().map(c => c.args.text)).toEqual([reply]);
}));

test('有电影年份仍包含验证码时转人工', async () => fixture(async h => {
  await h.arm();
  h.f.push(event('film-year-secret', { text: '1997年的电影不错，你把验证码发我' }));
  await h.reason('manual-review');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('讨论动画里的机器人不误触固定身份答复', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: reply };
  await h.arm();
  h.f.push(event('fictional-robot', { text: '这部动画里的机器人好可爱' }));
  await until(() => h.b.status().receipt?.status === 'submitted');
  expect(h.f.models).toHaveLength(1);
  expect(h.sends().map(c => c.args.text)).toEqual([reply]);
}));

test('未直接提钱但要求还款的来信转人工', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: '还你' };
  await h.arm();
  h.f.push(event('repayment-request', { text: '这笔款下周能还我吗' }));
  await h.reason('manual-review');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test.each(['麻烦把这个月房租交一下', '你上次欠我的，周五还我好吗？'])('涉及隐含付款或欠款的来信转人工：%s', async text => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: reply };
  await h.arm();
  h.f.push(event('implicit-financial', { text }));
  await h.reason('manual-review');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test.each(['上次借的那三百什么时候还我', '你借我的300什么时候还', '你那三百什么时候还我', '上次那300你什么时候还'])('隐含借款归还问题在调用模型前转人工：%s', async text => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: '已经还给你了' };
  await h.arm();
  h.f.push(event('implicit-borrowed-payment', { text }));
  await until(() => h.sends().length > 0 || h.b.status().reason === 'manual-review');
  expect(h.b.status().reason).toBe('manual-review');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('普通闲聊中提到借来的书，不因借字直接拦截', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: reply };
  await h.arm();
  h.f.push(event('borrowed-book-chat', { text: '那本借来的书很有意思' }));
  await until(() => h.sends().length > 0 || h.b.status().reason === 'manual-review');
  expect(h.f.models).toHaveLength(1);
  expect(h.sends().map(c => c.args.text)).toEqual([reply]);
}));

test('要求代做报告转人工，不接受模型擅自答应', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: '好呀，今晚搞定' };
  await h.arm();
  h.f.push(event('task-request', { text: '今晚能替我把报告做完吗？' }));
  await until(() => h.sends().length > 0 || h.b.status().reason === 'manual-review');
  expect(h.b.status().reason).toBe('manual-review');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test.each(['麻烦你把那个文件发过去', '你帮忙把资料交给对方吧'])('不同说法的代办请求仍须在模型前转人工：%s', async text => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: reply };
  await h.arm();
  h.f.push(event('indirect-task-request', { text }));
  await until(() => h.sends().length > 0 || h.b.status().reason === 'manual-review');
  expect(h.b.status().reason).toBe('manual-review');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('普通闲聊中的礼貌表达仍可自然回复', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: reply };
  await h.arm();
  h.f.push(event('polite-chat', { text: '请你看看今天的晚霞，真好看' }));
  await until(() => h.sends().length > 0 || h.b.status().reason === 'manual-review');
  expect(h.sends().map(c => c.args.text)).toEqual([reply]);
  expect(h.f.models).toHaveLength(1);
}));

test.each(['今天的云真好看', '麻烦你把那个文件发过去'])('仅有“好的”的模型回复保守转人工：%s', async text => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: '好的' };
  await h.arm();
  h.f.push(event('ambiguous-acknowledgement', { text }));
  await until(() => h.sends().length > 0 || h.b.status().reason === 'manual-review');
  expect(h.b.status().reason).toBe('manual-review');
  expect(h.sends()).toHaveLength(0);
}));

test.each(['明早九点接我，别忘了', '明早九点接我', '别忘了把资料交给小王'])('约定或代办提醒转人工，不让模型擅自应承：%s', async text => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: '嗯，记得了' };
  await h.arm();
  h.f.push(event('reminder-request', { text }));
  await until(() => h.sends().length > 0 || h.b.status().reason === 'manual-review');
  expect(h.b.status().reason).toBe('manual-review');
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('普通闲聊里提到早上的阳光，仍可自然回复', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: reply };
  await h.arm();
  h.f.push(event('morning-chat', { text: '早上的阳光真好' }));
  await until(() => h.b.status().receipt?.status === 'submitted');
  expect(h.f.models).toHaveLength(1);
  expect(h.sends().map(c => c.args.text)).toEqual([reply]);
}));

test.each(['嗯，记得了', '嗯，记好了', '放心，我记着呢', '我记住这事了'])('普通来信生成未经核实的记忆或应承时暂停：%s', async text => fixture(async h => {
  h.f.state.decision = { action: 'reply', text };
  await h.arm();
  h.f.push(event('unverified-remembrance', { text: '今天的云真好看' }));
  await until(() => h.sends().length > 0 || h.b.status().reason === 'manual-review');
  expect(h.b.status().reason).toBe('manual-review');
  expect(h.f.models).toHaveLength(1);
  expect(h.sends()).toHaveLength(0);
}));

test('模型对普通来信错误生成约期给付承诺时，出站检查暂停且不提交', async () => fixture(async h => {
  h.f.state.decision = { action: 'reply', text: '下个礼拜给你' };
  await h.arm();
  h.f.push(event('unsafe-payment-promise', { text: '今天天气真好' }));
  await h.reason('manual-review');
  expect(h.f.models).toHaveLength(1);
  expect(h.sends()).toHaveLength(0);
  expect(h.b.status().autoReply).toBe(false);
}));

test.each(['已经还给你了', '早就还你了'])('普通来信生成未经核实的归还陈述时暂停：%s', async text => fixture(async h => {
  h.f.state.decision = { action: 'reply', text };
  await h.arm();
  h.f.push(event('unverified-repayment-output', { text: '今天天气真好' }));
  await until(() => h.sends().length > 0 || h.b.status().reason === 'manual-review');
  expect(h.b.status().reason).toBe('manual-review');
  expect(h.f.models).toHaveLength(1);
  expect(h.sends()).toHaveLength(0);
}));

test.each(['我明天一定会到', '那就这么说定了', '刚下班，正在回家的路上', '好呀，今晚搞定'])('普通来信生成不应代作的个人陈述时暂停：%s', async text => fixture(async h => {
  h.f.state.decision = { action: 'reply', text };
  await h.arm();
  h.f.push(event('unsafe-personal-output', { text: '今天天气真好' }));
  await until(() => h.sends().length > 0 || h.b.status().reason === 'manual-review');
  expect(h.b.status().reason).toBe('manual-review');
  expect(h.f.models).toHaveLength(1);
  expect(h.sends()).toHaveLength(0);
}));

test.each([
  { incoming: '可以把验证码发给我吗？', decision: { action: 'reply', text: reply }, calls: 0 },
  { incoming: '明天中午见吧', decision: { action: 'reply', text: reply }, calls: 0 },
  { incoming: syntheticText, decision: { action: 'manual' }, calls: 1 },
  { incoming: syntheticText, decision: { action: 'reply', text: '我马上过去' }, calls: 1 },
])('私密或承诺转人工，模型不能绕过出站限制 %#', async ({ incoming, decision, calls }) => fixture(async h => {
  h.f.state.decision = decision;
  await h.arm();
  h.f.push(event('manual', { text: incoming }));
  await h.reason('manual-review');
  expect(h.sends()).toHaveLength(0);
  expect(h.f.models).toHaveLength(calls);
}));

test('模型 401 与无效格式停止，不创建发信尝试', async () => fixture(async h => {
  h.f.state.modelStatus = 401;
  await h.arm();
  h.f.push(event('denied'));
  await h.reason('model-auth');
  h.f.state.modelStatus = 200;
  h.f.state.decision = { action: 'reply', text: reply, target: 'wxid_other' };
  await h.arm();
  h.f.push(event('invalid'));
  await h.reason('model-format');
  expect(h.sends()).toHaveLength(0);
}));

test('模型确实超时后无提交', async () => fixture(async h => {
  h.f.state.modelHold = latch();
  await h.arm();
  h.f.push(event('timeout'));
  await h.reason('model-timeout', 11_000);
  expect(h.sends()).toHaveLength(0);
}), 14_000);

test('在提交校验 RPC 期间暂停，未向小禾发送消息', async () => fixture(async h => {
  await h.arm();
  const hold = h.f.state.readHold = latch();
  h.f.push(event('fence'));
  await until(() => h.f.calls.filter(c => c.name === 'events.read').length >= 2);
  h.b.pause();
  hold.release();
  expect(h.b.status().inFlight).toBe(false);
  await h.restart();
  expect(h.sends()).toHaveLength(0);
}));

test('暂停时已发出的单次 RPC 不能撤回，之后没有新的发送', async () => fixture(async h => {
  const hold = h.f.state.sendHold = latch();
  await h.arm();
  h.f.push(event('in-flight'));
  await until(() => h.sends().length === 1);
  h.b.pause();
  expect(h.b.status()).toMatchObject({ phase: 'paused', autoReply: false, inFlight: true });
  h.f.push(event('must-not-reply'));
  hold.release();
  await until(() => !h.b.status().inFlight);
  expect(h.b.status().receipt).toMatchObject({ status: 'submitted', delivery: 'unknown' });
  expect(h.sends()).toHaveLength(1);
}));

test('提交在途时对方叫停，后到的消息不提交，回执不解除对方的停止', async () => fixture(async h => {
  const send = h.f.state.sendHold = latch();
  await h.arm();
  h.f.push(event('already-on-wire'));
  await until(() => h.sends().length === 1);
  h.f.push(event('stop-after-send', { text: '不要再自动回复了' }), event('queued-after-stop'));
  await h.reason('peer-stopped');
  expect(h.b.status()).toMatchObject({ inFlight: true, autoReply: false, peerStopped: true });
  send.release();
  await until(() => !h.b.status().inFlight);
  await h.restart();
  expect(h.b.status()).toMatchObject({ peerStopped: true, reason: 'peer-stopped', receipt: { status: 'submitted' } });
  expect(h.sends()).toHaveLength(1);
  expect(h.f.models).toHaveLength(1);
}));

test('回执丢失后不重发；重启仍阻止，确认结果未知不会重试旧请求', async () => fixture(async h => {
  h.f.state.sendDrop = true;
  const req = h.active();
  await h.b.active(req);
  await h.reason('send-unknown');
  expect(h.sends()).toHaveLength(1);
  await h.restart();
  expect(h.b.status()).toMatchObject({ uncertain: true, receipt: { status: 'unknown', hasOperation: false } });
  await expect(h.b.arm(h.grant())).rejects.toMatchObject({ code: 'send-unknown' });
  h.b.acknowledge(h.target);
  h.f.state.sendDrop = false;
  await h.b.active(req);
  await h.reason('duplicate-attempt');
  expect(h.sends()).toHaveLength(1);
}));

test('可查的小禾回执只更新状态，不把已提交误报成已送达或再次提交', async () => fixture(async h => {
  h.f.state.withheldSend = true;
  await h.b.active(h.active());
  await h.reason('send-unknown');
  expect(h.b.status().receipt).toMatchObject({ status: 'unknown', delivery: 'unknown', hasOperation: true });
  h.f.state.operationsDelivery = 'delivered';
  await h.b.refresh(h.target);
  expect(h.b.status().receipt).toMatchObject({ status: 'submitted', delivery: 'delivered' });
  expect(h.sends()).toHaveLength(1);
}));

test('缺口停住，重启仍需人工核对起点；重置不回复积压', async () => fixture(async h => {
  await h.arm();
  h.f.state.gap = true;
  h.f.push(event('gap'));
  await h.reason('event-gap');
  await h.restart();
  expect(h.b.status().reason).toBe('event-gap');
  h.f.state.gap = false;
  h.b.resetRead(h.target);
  await h.arm();
  expect(h.sends()).toHaveLength(0);
  expect(h.f.models).toHaveLength(0);
}));

test('缺口仍在时重置不能恢复发送，重启后仍须核对', async () => fixture(async h => {
  await h.arm();
  h.f.state.gap = true;
  h.f.push(event('gap-before-reset'));
  await h.reason('event-gap');
  h.b.resetRead(h.target);
  await expect(h.b.arm(h.grant())).rejects.toMatchObject({ code: 'event-gap' });
  await h.restart();
  expect(h.b.status()).toMatchObject({ reason: 'event-gap', autoReply: false });
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('缺口锁定期间收到的叫停，重置后仍能识别', async () => fixture(async h => {
  const start = Date.now();
  setSystemTime(new Date(start));
  try {
    await h.arm();
    h.f.state.gap = true;
    h.f.push(event('trigger-gap'));
    await h.reason('event-gap');
    setSystemTime(new Date(start + 1000));
    h.f.push(event('stop-before-gap-reset', { text: '不要再自动回复了' }));
    await h.restart();
    setSystemTime(new Date(start + 5000));
    h.f.state.gap = false;
    h.b.resetRead(h.target);
    await expect(h.b.arm(h.grant())).rejects.toMatchObject({ code: 'stopped' });
    expect(h.b.status()).toMatchObject({ peerStopped: true, autoReply: false });
    expect(h.f.models).toHaveLength(0);
    expect(h.sends()).toHaveLength(0);
  } finally { setSystemTime(); }
}));

test('可恢复的断线换会话、按游标继续且不回离线积压，登录世代变化停止', async () => fixture(async h => {
  await h.arm();
  const firstSession = h.waits()[0]!.session;
  h.f.state.dropWait = true;
  h.f.push(event('outage'));
  await h.reason('mcp-offline');
  h.f.state.dropWait = false;
  const newWait = await until(() => h.waits().find(c => c.session !== firstSession));
  expect(newWait.args.cursor).toBe('c1');
  expect(h.f.models).toHaveLength(0);
  h.f.push(event('online'));
  await until(() => h.b.status().receipt?.status === 'submitted');
  h.f.state.generation = 'changed-login';
  h.f.push(event('wrong-generation', { login_generation: 'changed-login' }));
  await h.reason('wechat-changed');
  expect(h.sends()).toHaveLength(1);
}));

test('分页只处理有限积压，空起点和重复游标不会导致重复回复', async () => fixture(async h => {
  h.f.state.emptyCursor = true;
  h.f.state.shorterPage = 1;
  await h.b.arm(h.grant());
  h.f.push(event('page-one'), event('page-two'));
  await until(() => h.b.status().receipt?.status === 'submitted');
  const payload = JSON.parse(h.f.models[0]!.messages[1].content);
  expect(payload.latest).toEqual([syntheticText, syntheticText]);
  h.f.state.cursorRepeat = true;
  h.f.push(event('cursor-stuck'));
  await h.reason('mcp-contract');
  expect(h.sends()).toHaveLength(1);
}));

test('超过旧分页上限的保留旧事件可建立起点，不生成回复', async () => fixture(async h => {
  const old = new Date(Date.now() - 120_000).toISOString();
  h.f.push(...Array.from({ length: 9601 }, (_, i) => event(`old-retained-${i}`, { created_at: old, observed_at: old })));
  await h.arm();
  expect(h.b.status()).toMatchObject({ running: true, autoReply: true });
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}), 20_000);

test('处理大量旧保留事件期间收到叫停，不能跳过并开启自动回复', async () => fixture(async h => {
  const old = new Date(Date.now() - 120_000).toISOString();
  h.f.push(...Array.from({ length: 9601 }, (_, i) => event(`old-before-stop-${i}`, { created_at: old, observed_at: old })));
  h.f.state.afterReadSnapshot = () => h.f.push(event('stop-during-catch-up', { text: '不要再自动回复了' }));
  await expect(h.b.arm(h.grant())).rejects.toMatchObject({ code: 'stopped' });
  expect(h.b.status()).toMatchObject({ peerStopped: true, autoReply: false });
  await h.restart();
  await expect(h.b.arm(h.grant())).rejects.toMatchObject({ code: 'peer-stopped' });
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}), 20_000);

test('积压中途失败重启后继续读取，不能因重新开启时间跳过之前的叫停', async () => fixture(async h => {
  const start = Date.now();
  setSystemTime(new Date(start));
  try {
    const old = new Date(start - 120_000).toISOString();
    h.f.state.shorterPage = 1;
    h.f.push(...Array.from({ length: 161 }, (_, i) => event(`limited-old-${i}`, { created_at: old, observed_at: old })));
    h.f.state.afterReadSnapshot = () => h.f.push(event('stop-before-limit', { text: '不要再自动回复了' }));
    await expect(h.b.arm(h.grant())).rejects.toMatchObject({ code: 'backlog-limit' });
    await h.restart();
    expect(h.b.status()).toMatchObject({ reason: 'backlog-limit', autoReply: false });
    setSystemTime(new Date(start + 5000));
    h.b.resetRead(h.target);
    await expect(h.b.arm(h.grant())).rejects.toMatchObject({ code: 'stopped' });
    expect(h.f.calls.filter(c => c.name === 'events.read').some(c => c.args.cursor === 'c160')).toBe(true);
    expect(h.b.status()).toMatchObject({ peerStopped: true, autoReply: false });
    expect(h.f.models).toHaveLength(0);
    expect(h.sends()).toHaveLength(0);
  } finally { setSystemTime(); }
}), 20_000);

test('监听期间未处理的叫停在暂停和重启后仍要检查', async () => fixture(async h => {
  const start = Date.now();
  setSystemTime(new Date(start));
  try {
    await h.arm();
    const held = h.f.state.waitHold = latch();
    setSystemTime(new Date(start + 1000));
    h.f.push(event('stop-before-interruption', { text: '不要再自动回复了' }));
    h.b.pause();
    held.release();
    await h.restart();
    setSystemTime(new Date(start + 5000));
    await expect(h.b.arm(h.grant())).rejects.toMatchObject({ code: 'stopped' });
    expect(h.b.status()).toMatchObject({ peerStopped: true, autoReply: false });
    expect(h.f.models).toHaveLength(0);
    expect(h.sends()).toHaveLength(0);
  } finally { setSystemTime(); }
}));

test('监听期间才观察到的较早消息如含叫停仍要锁定', async () => fixture(async h => {
  const start = Date.now();
  setSystemTime(new Date(start));
  try {
    await h.arm();
    setSystemTime(new Date(start + 1000));
    h.f.push(event('late-observed-stop', {
      text: '不要再自动回复了', created_at: new Date(start - 5000).toISOString(),
    }));
    await h.reason('peer-stopped');
    expect(h.f.models).toHaveLength(0);
    expect(h.sends()).toHaveLength(0);
  } finally { setSystemTime(); }
}));

test('开启前创建且观察到的旧叫停不追溯锁定', async () => fixture(async h => {
  const old = new Date(Date.now() - 120_000).toISOString();
  h.f.push(event('old-stop', { text: '不要再自动回复了', created_at: old, observed_at: old }));
  await h.arm();
  expect(h.b.status()).toMatchObject({ peerStopped: false, autoReply: true });
  expect(h.f.models).toHaveLength(0);
  expect(h.sends()).toHaveLength(0);
}));

test('积压恢复后不追答上次未完成开启期间的普通消息', async () => fixture(async h => {
  const start = Date.now();
  setSystemTime(new Date(start));
  try {
    const old = new Date(start - 120_000).toISOString();
    h.f.state.shorterPage = 1;
    h.f.push(...Array.from({ length: 161 }, (_, i) => event(`limited-normal-${i}`, { created_at: old, observed_at: old })));
    h.f.state.afterReadSnapshot = () => h.f.push(event('normal-before-limit', { text: '今天的云真好看' }));
    await expect(h.b.arm(h.grant())).rejects.toMatchObject({ code: 'backlog-limit' });
    await h.restart();
    setSystemTime(new Date(start + 5000));
    h.b.resetRead(h.target);
    await h.arm();
    expect(h.b.status()).toMatchObject({ running: true, autoReply: true });
    expect(h.f.models).toHaveLength(0);
    expect(h.sends()).toHaveLength(0);
  } finally { setSystemTime(); }
}), 20_000);

test('定时只发一次、不调用模型；取消时不发送', async () => fixture(async h => {
  const canceled = h.active({ at: Date.now() + 850 });
  await h.b.active(canceled);
  expect(h.b.status().scheduledAt).toBe(canceled.at);
  h.b.pause('system-sleep');
  const allowed = h.active({ at: Date.now() + 900, text: '确认允许的合成消息' });
  await h.b.active(allowed);
  await h.reason('one-shot-complete');
  expect(h.sends().map(c => c.args.text)).toEqual([allowed.text]);
  expect(h.f.models).toHaveLength(0);
}));

test('连续两次完整的 20 秒空等待后，原会话仍收信并只回一次', async () => fixture(async h => {
  await h.arm();
  const first = h.waits()[0]!;
  await until(() => h.waits().length >= 3 || !h.b.status().autoReply, 46_000);
  expect(h.b.status().autoReply).toBe(true);
  expect(h.waits().slice(0, 3).map(c => c.args.timeout_seconds)).toEqual([20, 20, 20]);
  expect(h.waits()[2]!.at - first.at).toBeGreaterThanOrEqual(39_000);
  expect(h.waits().every(c => c.session === first.session && c.args.cursor === first.args.cursor)).toBe(true);
  expect(h.f.models).toHaveLength(0);
  h.f.push(event('after-idle'));
  await until(() => h.b.status().statistics?.count === 1);
  expect(h.sends()).toHaveLength(1);
}), 52_000);
