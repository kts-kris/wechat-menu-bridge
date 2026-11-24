import { expect, test } from 'bun:test';
import { Xiaohe } from '../mcp.ts';
import { binding, event, mockNetwork, peer, scope, until } from './fixture.ts';

test('independent MCP long wait returns early at an event without blocking another authorized client', async () => {
  const f = await mockNetwork();
  const reader = new Xiaohe(f.mcp);
  const control = new Xiaohe(f.mcp);
  try {
    const status = await reader.identify(binding.account_id);
    expect(status).toEqual({ server: 'fixture-server', binding });
    expect(await reader.page(scope, null, false)).toMatchObject({ cursor: 'c0', events: [] });
    const start = performance.now();
    const wait = reader.page(scope, 'c0', true);
    await until(() => f.calls.find(c => c.name === 'events.wait'));
    expect((await control.accounts())[0]?.canSend).toBe(true);
    expect(await control.contacts(binding, '模拟')).toEqual([{ id: peer, label: '模拟联系人' }]);
    const incoming = event('first');
    f.push(incoming);
    expect(await wait).toEqual({ cursor: 'c1', more: false, events: [incoming] });
    expect(performance.now() - start).toBeLessThan(2000);
    expect(f.calls.find(c => c.name === 'events.wait')?.args.timeout_seconds).toBe(20);
    expect(f.wireFaults).toEqual([]);
  } finally { await Promise.all([reader.close(), control.close()]); await f.close(); }
});

test('private write capability must be granted and submitted is distinct from delivery', async () => {
  const f = await mockNetwork();
  const m = new Xiaohe(f.mcp);
  try {
    f.state.writePermission = false;
    await expect(m.identify(binding.account_id)).rejects.toMatchObject({ code: 'wechat-permission' });
    expect(f.calls.some(c => c.name === 'messages.send_text')).toBe(false);
    f.state.writePermission = true;
    await m.identify(binding.account_id);
    const send = await m.send(scope, 'synthetic-text', 'fixture-key');
    expect(send).toEqual({ status: 'submitted', delivery: 'unknown', operation: 'mock-op' });
    expect(f.calls.find(c => c.name === 'messages.send_text')?.args).toEqual({ ...scope, text: 'synthetic-text', client_request_id: 'fixture-key' });
    f.state.operationsDelivery = 'delivered';
    expect(await m.operation('mock-op')).toMatchObject({ status: 'submitted', delivery: 'delivered' });
  } finally { await m.close(); await f.close(); }
});
