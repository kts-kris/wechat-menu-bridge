import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { BridgeError, directID, endpoint, id, object } from './contracts.ts';

export type Binding = { account_id: string; instance_id: string; login_generation: string };
export type Scope = Binding & { conversation_id: string };
export type Account = { id: string; label: string; canRead: boolean; canSend: boolean; binding?: Binding };
export type Contact = { id: string; label: string };
export type Page = { cursor: string | null; more: boolean; events: unknown[] };
export type Receipt = { status: 'submitted' | 'unknown' | 'rejected'; delivery: 'delivered' | 'failed' | 'unknown'; operation?: string; ref?: string };
type Tool = 'system.status' | 'accounts.list' | 'contacts.search' | 'events.read' | 'events.wait' |
  'messages.get_context' | 'messages.send_text' | 'operations.get';
// The public events.read/events.wait schema permits up to 500; fewer requests
// make a large retained window less likely to hit the bounded catch-up limit.
export const PAGE_SIZE = 500;
const errorText = (x: unknown): string => typeof x === 'string' ? x.slice(0, 500) : '';
const permission = (x: unknown) => /\b(?:401|403)\b|forbidden|unauthori|permission|account_not_ready|权限|未登录/i.test(errorText(x));
const scopeChanged = (x: unknown) => /(?:login_generation|instance_id|account_id).*mismatch|scope.changed|login_changed/i.test(errorText(x));
const permissionCode = (x: unknown) => scopeChanged(x) ? 'wechat-changed' : permission(x) ? 'wechat-permission' : undefined;
const classify = (e: unknown) => {
  if (e instanceof BridgeError) return e;
  const err = object(e);
  const code = err?.code;
  const hint = permissionCode(`${String(code ?? '')} ${errorText(err?.message)}`);
  if (hint) return new BridgeError(hint);
  return new BridgeError(code === -32601 || code === -32602 ? 'mcp-contract' : 'mcp-offline');
};
const label = (data: Record<string, unknown>, fallback: string) => {
  const name = [data.remark, data.display_name, data.nickname, data.name, data.alias, fallback].find(id)!;
  return name.slice(0, 100);
};
const hasPermission = (row: Record<string, unknown>, key: string) => row.ready === true &&
  Array.isArray(row.permissions) && row.permissions.includes(key) && object(object(row.capabilities)?.[key])?.ready === true;

export class Xiaohe {
  private readonly url: URL;
  private transport?: StreamableHTTPClientTransport;
  private client?: Client;
  private wiring?: Promise<Client>;
  private closed = false;
  private closing?: Promise<void>;
  private sendGate?: { before: () => void; used?: boolean; error?: unknown };

  constructor(url: string) { this.url = endpoint(url, 'mcp'); }

  private connect(signal?: AbortSignal) {
    if (this.closed) throw new BridgeError('stopped');
    if (this.client) return Promise.resolve(this.client);
    if (this.wiring) return this.wiring;
    const client = new Client({ name: 'wechat-menu-bridge', version: '0.2.1' });
    const transport = new StreamableHTTPClientTransport(this.url, { fetch: async (input, init) => {
      const url = input instanceof Request ? input.url : String(input);
      if (url !== this.url.href) throw new BridgeError('invalid-endpoint');
      if (init?.method === 'GET') return new Response(null, { status: 405 });
      const body = typeof init?.body === 'string' ? object(JSON.parse(init.body)) : undefined;
      const params = object(body?.params);
      const wait = body?.method === 'tools/call' && params?.name === 'events.wait';
      const deadline = AbortSignal.timeout(init?.method === 'DELETE' ? 700 : wait ? 23_000 : 4000);
      const opts = { ...init, credentials: 'omit' as const, redirect: 'error' as const, proxy: '',
        signal: init?.signal ? AbortSignal.any([init.signal, deadline]) : deadline };
      opts.signal.throwIfAborted();
      if (body?.method === 'tools/call' && params?.name === 'messages.send_text') {
        const gate = this.sendGate;
        if (!gate || gate.used) throw new BridgeError('send-not-authorized');
        gate.used = true;
        try { gate.before(); } catch (e) { gate.error = e; throw e; }
        return fetch(url, { ...opts, keepalive: false });
      }
      return fetch(url, opts);
    } });
    this.transport = transport;
    this.wiring = client.connect(transport, { signal, timeout: 3500 }).then(() => {
      if (this.closed) throw new BridgeError('stopped');
      this.client = client;
      return client;
    }).catch(async e => { await client.close().catch(() => {}); throw classify(e); }).finally(() => { this.wiring = undefined; });
    return this.wiring;
  }

  private async call(tool: Tool, args: Record<string, unknown>, signal?: AbortSignal) {
    try {
      signal?.throwIfAborted();
      const client = await this.connect(signal);
      signal?.throwIfAborted();
      const r = await client.callTool({ name: tool, arguments: args }, undefined,
        { signal, timeout: tool === 'events.wait' ? 23_500 : 4500 });
      let value = object(r.structuredContent);
      const item = Array.isArray(r.content) && r.content.length === 1 ? object(r.content[0]) : undefined;
      if (!value && item?.type === 'text' && typeof item.text === 'string') {
        try { value = object(JSON.parse(item.text)); } catch { /* safe, static diagnostics below */ }
      }
      const error = object(value?.error);
      if (r.isError || value?.ok === false || error) {
        const hint = `${errorText(error?.code)} ${errorText(error?.message)} ${errorText(item?.text)}`;
        if (tool === 'messages.get_context' && /message_not_found|message_recalled|撤回/i.test(hint) && !permissionCode(hint)) {
          throw new BridgeError('no-anchor');
        }
        // A general MCP error on a write is not proof that WeChat didn't accept the request.
        throw new BridgeError(permissionCode(hint) ?? 'mcp-contract');
      }
      if (!value) throw new BridgeError('mcp-contract');
      return object(value.data) ?? value;
    } catch (e) {
      if (signal?.aborted) throw new BridgeError('stopped');
      throw classify(e);
    }
  }

  async server(signal?: AbortSignal) {
    const r = await this.call('system.status', {}, signal);
    if (!id(r.server_id)) throw new BridgeError('mcp-contract');
    return r.server_id;
  }

  async accounts(signal?: AbortSignal): Promise<Account[]> {
    const r = await this.call('accounts.list', {}, signal);
    if (!Array.isArray(r.accounts)) throw new BridgeError('mcp-contract');
    return r.accounts.slice(0, 20).flatMap(raw => {
      const v = object(raw);
      if (!v || !id(v.account_id)) return [];
      const binding = id(v.instance_id) && id(v.login_generation)
        ? { account_id: v.account_id, instance_id: v.instance_id, login_generation: v.login_generation } : undefined;
      return [{ id: v.account_id, label: label(v, `账号 …${v.account_id.slice(-8)}`), binding,
        canRead: hasPermission(v, 'events.read'), canSend: hasPermission(v, 'messages.send_text') }];
    });
  }

  async identify(account: string, signal?: AbortSignal, requireWrite = true) {
    const server = await this.server(signal);
    const rows = (await this.accounts(signal)).filter(x => x.id === account);
    const row = rows.length === 1 ? rows[0] : undefined;
    if (!row?.binding || !row.canRead || (requireWrite && !row.canSend)) throw new BridgeError('wechat-permission');
    return { server, binding: row.binding };
  }

  async contacts(binding: Binding, query: string, signal?: AbortSignal): Promise<Contact[]> {
    const data = await this.call('contacts.search', { ...binding, query, page_size: 30 }, signal);
    const rows = data.contacts ?? data.items;
    if (!Array.isArray(rows)) throw new BridgeError('mcp-contract');
    const seen = new Set<string>();
    return rows.slice(0, 30).flatMap(raw => {
      const v = object(raw);
      // Only ordinary individual account IDs; no groups or service accounts.
      const user = v?.user_id ?? v?.wxid ?? v?.contact_id;
      if (!v || !directID(user) || seen.has(user) || /group|official|service|public|chatroom/i.test(String(v.type ?? v.contact_type ?? ''))) return [];
      seen.add(user);
      return [{ id: user, label: label(v, user) }];
    });
  }

  async page(scope: Scope, cursor: string | null, live: boolean, signal?: AbortSignal): Promise<Page> {
    const wait = cursor !== null && live;
    const r = await this.call(wait ? 'events.wait' : 'events.read', { ...scope, page_size: PAGE_SIZE,
      ...(cursor === null ? {} : { cursor }), ...(wait ? { timeout_seconds: 20 } : {}) }, signal);
    if (r.event_gap === true) throw new BridgeError('event-gap');
    if (r.account_id !== scope.account_id || r.instance_id !== scope.instance_id || r.login_generation !== scope.login_generation) {
      throw new BridgeError('wechat-changed');
    }
    if (r.event_gap !== false || typeof r.has_more !== 'boolean' || !Array.isArray(r.events) || r.events.length > PAGE_SIZE ||
        !(id(r.next_cursor) || (r.next_cursor === '' && cursor === null && !r.has_more && !r.events.length))) {
      throw new BridgeError('mcp-contract');
    }
    const next = id(r.next_cursor) ? r.next_cursor : null;
    if (next === cursor && (r.events.length > 0 || r.has_more)) throw new BridgeError('mcp-contract');
    return { cursor: next, more: r.has_more, events: r.events };
  }

  async anchor(scope: Scope, ref: string, signal?: AbortSignal) {
    const r = await this.call('messages.get_context', { ...scope, message_ref: ref, before: 0, after: 0 }, signal);
    const candidates = [r.anchor, r.anchor_message, r.message, r, ...(Array.isArray(r.messages) ? r.messages : []),
      ...(Array.isArray(r.items) ? r.items : [])];
    const m = candidates.map(object).find(x => x?.message_ref === ref);
    if (!m || !Object.entries(scope).every(([k, v]) => (r[k] === undefined || r[k] === v) && (m[k] === undefined || m[k] === v)) ||
        (m.conversation_id ?? r.conversation_id) !== scope.conversation_id || m.sender_id !== scope.conversation_id ||
        m.is_self !== false || m.type !== 'text') throw new BridgeError('wrong-anchor');
    if (m.recalled === true || m.is_recalled === true || typeof m.text !== 'string' || !m.text.trim()) throw new BridgeError('no-anchor');
    return m.text.trim();
  }

  async send(scope: Scope, text: string, attempt: string, before = () => {}) {
    if (this.sendGate) throw new BridgeError('busy');
    const gate: NonNullable<Xiaohe['sendGate']> = { before };
    this.sendGate = gate;
    try {
      return receipt(await this.call('messages.send_text', { ...scope, client_request_id: attempt, text }));
    } catch (e) { throw gate.error ?? e; }
    finally { this.sendGate = undefined; }
  }

  async operation(operation: string, signal?: AbortSignal) {
    const r = await this.call('operations.get', { operation_id: operation }, signal);
    const p = object(r.operation) ?? r;
    if (p.operation_id !== undefined && p.operation_id !== operation) throw new BridgeError('mcp-contract');
    return receipt(p);
  }

  async close() {
    if (this.closing) return this.closing;
    this.closed = true;
    const client = this.client;
    const transport = this.transport;
    this.client = undefined;
    this.closing = (async () => {
      if (transport) await transport.terminateSession().catch(() => {});
      await (client?.close() ?? transport?.close())?.catch(() => {});
    })();
    return this.closing;
  }
}

function receipt(r: Record<string, unknown>): Receipt {
  const status = r.status === 'submitted' ? 'submitted' : r.status === 'rejected' ? 'rejected' : 'unknown';
  const delivery = r.delivery === 'delivered' ? 'delivered' : r.delivery === 'failed' ? 'failed' : 'unknown';
  return { status, delivery: status !== 'rejected' ? delivery : 'failed', ...(id(r.operation_id) ? { operation: r.operation_id } : {}),
    ...(id(r.message_ref) ? { ref: r.message_ref } : {}) };
}
