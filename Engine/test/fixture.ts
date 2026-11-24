import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { once } from 'node:events';

export const binding = { account_id: 'mock_account', instance_id: 'mock_instance', login_generation: 'mock_login' };
export const peer = 'wxid_fixture';
export const scope = { ...binding, conversation_id: peer };
export const reply = '哈哈，那挺好';
export const syntheticText = '测试留言：下楼刚好碰上有太阳';
export const secondPeer = 'custom_friend';
export const group = 'a-group@chatroom';
export const service = 'gh_fixture';
export const nowISO = () => new Date().toISOString();
export const event = (n: string, extra: Record<string, unknown> = {}) => ({
  ...scope, event_id: `event-${n}`, event_type: 'message.saved', message_ref: `ref-${n}`,
  text: syntheticText, type: 'text', sender_id: peer, is_self: false, created_at: nowISO(), observed_at: nowISO(), ...extra,
});
export type Call = { name: string; args: Record<string, any>; at: number; session?: string };

export function latch() {
  let release!: () => void;
  const promise = new Promise<void>(r => { release = r; });
  return { promise, release };
}

export async function until<T>(value: () => T | undefined | false, timeout = 4000): Promise<T> {
  const end = performance.now() + timeout;
  while (performance.now() < end) {
    const v = value();
    if (v !== undefined && v !== false) return v;
    await new Promise(r => setTimeout(r, 10));
  }
  throw new Error('fixture did not observe expected state');
}

const json = (res: ServerResponse, status: number, v: unknown) =>
  res.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify(v));

export async function mockNetwork(options: { v2?: boolean; token?: string } = {}) {
  const events: ReturnType<typeof event>[] = [];
  const calls: Call[] = [];
  const models: Record<string, any>[] = [];
  const wireFaults: string[] = [];
  const pending = new Set<() => void>();
  const sessions = new Set<string>();
  let serial = 0;
  const state = {
    gap: false, offline: false, writePermission: true, server: 'fixture-server', generation: binding.login_generation,
    invalidEvent: false, emptyCursor: false, cursorRepeat: false, shorterPage: 500, withheldSend: false, sendDrop: false,
    decision: { action: 'reply', text: reply } as unknown, modelHold: undefined as ReturnType<typeof latch> | undefined,
    sendHold: undefined as ReturnType<typeof latch> | undefined,
    operationsDelivery: 'unknown', metaHold: undefined as ReturnType<typeof latch> | undefined,
    readHold: undefined as ReturnType<typeof latch> | undefined, anchorOverride: undefined as unknown,
    modelStatus: 200, returnedRef: undefined as string | undefined, dropWait: false,
    waitHold: undefined as ReturnType<typeof latch> | undefined,
    afterReadSnapshot: undefined as (() => void) | undefined,
    accountWideEvents: true, historyEmptyPage: false, mediaUnavailable: false,
    sendConversations: [peer, secondPeer, group], failConversation: undefined as string | undefined,
    hideReplyTool: false, hideMentionSend: false,
  };
  const v2Scopes = [peer, secondPeer, group, service, 'another-group@chatroom'];
  const toolNames = ['system.status', 'accounts.list', 'contacts.search', 'conversations.list', 'groups.members',
    'events.read', 'events.wait', 'messages.query', 'messages.search', 'search.global', 'messages.count',
    'messages.get_context', 'messages.read_media', 'messages.send_text', 'messages.reply', 'operations.get'];
  const sessionId = (req: IncomingMessage) => req.headers['mcp-session-id'] as string;

  const server = createServer((req, res) => { void (async () => {
    let data = '';
    for await (const chunk of req) data += chunk;
    if (options.v2 && req.url === '/v1/audio/transcriptions') return json(res, 200, { text: '小禾语音转写' });
    const m = data ? JSON.parse(data) : {};
    if (req.url === '/v1/chat/completions') {
      models.push(m);
      await state.modelHold?.promise;
      if (options.v2 && Array.isArray(m.messages?.[1]?.content)) {
        return json(res, state.modelStatus, { choices: [{ finish_reason: 'stop', message: { content: '一张日落照片' } }] });
      }
      return json(res, state.modelStatus, { choices: [{ finish_reason: 'stop', message: { content: JSON.stringify(state.decision) } }] });
    }
    if (req.url !== '/mcp') return json(res, 404, {});
    if (state.offline) return json(res, 503, {});
    if (req.headers.authorization !== (options.token ? `Bearer ${options.token}` : undefined) || req.headers.cookie) {
      wireFaults.push('Unexpected credentials on MCP');
    }
    if (m.method === 'initialize') {
      const session = `fixture-${++serial}`;
      sessions.add(session);
      res.setHeader('Mcp-Session-Id', session);
      const result = { protocolVersion: '2025-11-25', serverInfo: { name: 'synthetic-xiaohe', version: '1.0' }, capabilities: { tools: {} } };
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      return res.end(`event: message\ndata: ${JSON.stringify({ jsonrpc: '2.0', id: m.id, result })}\n\n`);
    }
    if (!sessions.has(sessionId(req)) || req.headers['mcp-protocol-version'] !== '2025-11-25') {
      // MCP cancellation notifications may arrive after a concurrent DELETE; the session is already gone.
      if (m.method === 'notifications/cancelled' && /^fixture-\d+$/.test(sessionId(req)) &&
          req.headers['mcp-protocol-version'] === '2025-11-25') return json(res, 404, {});
      wireFaults.push(`MCP session or protocol header missing (${req.method}, ${m.method ?? 'session'})`);
      return json(res, 400, {});
    }
    if (req.method === 'DELETE') { sessions.delete(sessionId(req)); return res.writeHead(204).end(); }
    if (m.method?.startsWith('notifications/')) return res.writeHead(202).end();
    if (options.v2 && m.method === 'tools/list') {
      calls.push({ name: 'tools/list', args: m.params ?? {}, at: Date.now(), session: sessionId(req) });
      const tools = toolNames.filter(name => !(state.hideReplyTool && name === 'messages.reply')).map(name => {
        const events = name.startsWith('events.');
        const properties = { ...(events && { account_id: { type: 'string' }, conversation_id: { type: 'string' } }),
          ...((name === 'messages.send_text' || name === 'messages.reply') && !state.hideMentionSend && { mention_user_ids: { type: 'array' } }) };
        return { name, inputSchema: { type: 'object', properties, ...(events && {
          required: ['account_id', ...(!state.accountWideEvents ? ['conversation_id'] : [])],
        }) } };
      });
      return json(res, 200, { jsonrpc: '2.0', id: m.id, result: { tools } });
    }
    if (m.method !== 'tools/call') { wireFaults.push('Unexpected RPC method'); return json(res, 400, {}); }
    const { name, arguments: args } = m.params;
    calls.push({ name, args, at: Date.now(), session: sessionId(req) });
    const answer = (v: unknown, isError = false) => json(res, 200, { jsonrpc: '2.0', id: m.id, result: {
      ...(isError ? { isError: true } : {}), content: [{ type: 'text', text: JSON.stringify(v) }],
    } });
    const fail = (code: string) => answer({ ok: false, error: { code } }, true);
    const checked = name === 'contacts.search' || name.startsWith('events.') || name.startsWith('messages.') ||
      (options.v2 && ['conversations.list', 'groups.members'].includes(name));
    const effective = { ...binding, login_generation: state.generation };
    if (checked && Object.entries(effective).some(([k, v]) => args[k] !== v)) return fail('login_generation_mismatch');
    const allowed = options.v2 ? v2Scopes.includes(args.conversation_id) ||
      (state.accountWideEvents && name.startsWith('events.') && args.conversation_id === undefined) : args.conversation_id === peer;
    if ((name.startsWith('events.') || name.startsWith('messages.')) && !allowed) {
      wireFaults.push('Call outside selected conversation');
      return fail('permission_denied');
    }
    if (name === 'system.status') { await state.metaHold?.promise; return answer({ server_id: state.server }); }
    if (name === 'accounts.list') return answer({ accounts: [{ ...effective, display_name: '模拟账号', ready: true,
      permissions: ['events.read', ...(state.writePermission ? ['messages.send_text'] : [])],
      capabilities: { 'events.read': { ready: true }, 'messages.send_text': { ready: state.writePermission } },
      ...(options.v2 && { send_conversations: state.sendConversations }),
    }] });
    if (options.v2 && name === 'conversations.list') return answer({
      conversations: v2Scopes.filter(id => !args.query || id.includes(args.query)).map(id => ({
        conversation_id: id, display_name: id,
        type: id.endsWith('@chatroom') ? 'group' : id.startsWith('gh_') ? 'service' : 'direct',
      })), has_more: false, sync_status: 'synced',
    });
    if (options.v2 && name === 'groups.members') return answer({ members: [
      { user_id: secondPeer, display_name: '群成员' }, { user_id: binding.account_id, display_name: '本人' },
    ], has_more: false });
    if (name === 'contacts.search') return answer({ contacts: [{ user_id: peer, display_name: '模拟联系人' },
      { user_id: 'a-group@chatroom', display_name: '模拟群聊' }] });
    if (name === 'events.read' || name === 'events.wait') {
      if (name === 'events.read') await state.readHold?.promise;
      const selected = () => options.v2 && args.conversation_id !== undefined ?
        events.filter(row => row.conversation_id === args.conversation_id) : events;
      const offset = args.cursor === undefined ? 0 : /^c(\d+)$/.test(args.cursor) ? Number(args.cursor.slice(1)) : -1;
      if (state.gap || offset < 0 || offset > selected().length) return answer({ event_gap: true, gap_reason: 'synthetic-gap' });
      if (name === 'events.wait' && offset === selected().length && args.timeout_seconds > 0) {
        const wake = latch();
        pending.add(wake.release);
        const done = () => wake.release();
        res.once('close', done);
        const timeout = setTimeout(done, args.timeout_seconds * 1000);
        await wake.promise;
        clearTimeout(timeout);
        pending.delete(wake.release);
        if (res.destroyed) return;
      }
      if (name === 'events.wait') {
        await state.waitHold?.promise;
        if (state.dropWait) return res.destroy();
      }
      const rows = selected();
      const end = Math.min(offset + Math.min(state.shorterPage, args.page_size), rows.length);
      const snapshot = { ...effective, event_gap: false, has_more: end < rows.length,
        next_cursor: state.cursorRepeat ? args.cursor : state.emptyCursor && end === 0 ? '' : `c${end}`,
        events: state.invalidEvent ? { unexpected: true } : rows.slice(offset, end) };
      if (name === 'events.read' && state.afterReadSnapshot) {
        const after = state.afterReadSnapshot;
        state.afterReadSnapshot = undefined;
        after();
      }
      return answer(snapshot);
    }
    if (options.v2 && name === 'messages.query') {
      const rows = events.filter(row => row.conversation_id === args.conversation_id).slice().reverse()
        .filter(row => args.start_time === undefined ||
          (Date.parse(row.created_at) >= args.start_time * 1000 && Date.parse(row.created_at) <= args.end_time * 1000))
        .slice(0, args.recent_count);
      if (state.historyEmptyPage && !args.cursor) return answer({ messages: [], next_cursor: 'history-0', has_more: true });
      const offset = Number(args.cursor?.split('-')[1] ?? 0);
      const end = Math.min(rows.length, offset + args.page_size);
      return answer({ messages: rows.slice(offset, end), next_cursor: end < rows.length ? `history-${end}` : null, has_more: end < rows.length });
    }
    if (options.v2 && name === 'messages.read_media') {
      if (state.mediaUnavailable) return answer({ status: 'not_available' });
      const audio = args.media_ref.startsWith('voice');
      return json(res, 200, { jsonrpc: '2.0', id: m.id, result: { content: [
        { type: 'text', text: JSON.stringify({ status: 'ok' }) },
        { type: audio ? 'audio' : 'image', mimeType: audio ? 'audio/wav' : 'image/png', data: 'ZmFrZQ==' },
      ] } });
    }
    if (name === 'messages.get_context') {
      const anchor = events.find(e => e.message_ref === args.message_ref);
      return state.anchorOverride ? answer({ anchor: state.anchorOverride }) : anchor ? answer({ anchor }) : fail('message_not_found');
    }
    if (name === 'messages.send_text' || (options.v2 && name === 'messages.reply')) {
      if (!state.writePermission) return fail('permission_denied');
      await state.sendHold?.promise;
      if (state.sendDrop || (options.v2 && args.conversation_id === state.failConversation)) return res.destroy();
      if (state.withheldSend) return answer({ status: 'unknown', delivery: 'unknown', operation_id: 'mock-op' });
      return answer({ status: 'submitted', delivery: 'unknown', operation_id: 'mock-op', message_ref: state.returnedRef });
    }
    if (name === 'operations.get') return answer({ status: 'submitted', delivery: state.operationsDelivery, operation_id: args.operation_id });
    wireFaults.push(`unexpected tool ${name}`);
    return json(res, 400, {});
  })().catch(() => { wireFaults.push('mock endpoint threw'); if (!res.headersSent) json(res, 500, {}); else res.destroy(); }); });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('mock did not bind');
  const base = `http://127.0.0.1:${address.port}`;
  return { mcp: `${base}/mcp`, model: `${base}/v1/chat/completions`, stt: `${base}/v1/audio/transcriptions`, state, events, calls, models, wireFaults,
    push(...rows: typeof events) { events.push(...rows); for (const f of pending) f(); },
    close() { for (const f of pending) f(); state.modelHold?.release(); state.sendHold?.release(); state.metaHold?.release();
      state.readHold?.release(); state.waitHold?.release();
      server.closeAllConnections(); return new Promise<void>(r => server.close(() => r())); },
  };
}
