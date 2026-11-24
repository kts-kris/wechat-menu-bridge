import { expect, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Bridge } from '../engine.ts';
import { event, mockNetwork, peer, binding, until, reply } from './fixture.ts';

test('新会话只回复范围内的新文字，合并连发且不重放旧事件', async () => {
  const f = await mockNetwork();
  const dir = await mkdtemp(join(tmpdir(), 'wmb-engine-'));
  const bridge = new Bridge(dir);
  try {
    const old = new Date(Date.now() - 60_000).toISOString();
    f.push(event('before-arm', { created_at: old, observed_at: old }));
    await bridge.arm({ target: { mcp: f.mcp, account: binding.account_id, contact: peer }, consent: true,
      dryRun: false,
      model: { mode: 'local', url: f.model, name: 'fixture', stylePath: '', memoryPath: '', cloudApproved: false } });
    await until(() => f.calls.find(c => c.name === 'events.wait'));
    const first = event('first', { text: '第一条合成闲聊' });
    f.push(first, first, event('foreign', { conversation_id: 'wxid_other', sender_id: 'wxid_other' }),
      event('wrong-sender', { sender_id: 'wxid_other' }), event('media', { type: 'image' }),
      event('second', { text: '第二条合成闲聊' }));
    await until(() => bridge.status().receipt?.status === 'submitted');
    expect(f.models).toHaveLength(1);
    expect(JSON.parse(f.models[0]!.messages[1].content).latest).toEqual(['第一条合成闲聊', '第二条合成闲聊']);
    const sends = f.calls.filter(c => c.name === 'messages.send_text');
    expect(sends).toHaveLength(1);
    expect(sends[0]!.args).toMatchObject({ conversation_id: peer, text: reply });
    expect(bridge.status().receipt?.delivery).toBe('unknown');
    expect(f.calls.filter(c => c.name === 'messages.get_context')).toHaveLength(0);
  } finally { await bridge.close(); await f.close(); await rm(dir, { recursive: true }); }
});
