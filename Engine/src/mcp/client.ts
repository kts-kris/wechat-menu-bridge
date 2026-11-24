import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { BridgeError, endpoint, id, object, sha } from '../../contracts.ts';
import type { Binding, Receipt, Scope } from '../../mcp.ts';
import { xiaoheAccountSchema, xiaoheConversationPageSchema } from '../contracts/events.ts';
import { CapabilityRegistry } from './capabilities.ts';

export type { Binding, Receipt, Scope };
export type EventScope = Binding & { conversation_id?: string };
export type RemoteIdentity = { server: string; binding: Binding };
export const identityKey = (remote: RemoteIdentity) => sha(JSON.stringify(remote));
export const routeKey = (url: string, account: string, conversation = '*') => sha(JSON.stringify([url, account, conversation]));
export const peerKey = (account: string, conversation: string) => sha(JSON.stringify([account, conversation]));
export type XiaoheClientOptions = { token?: string; groupCacheSize?: number; now?: () => number };
export type Account = { id: string; label: string; canRead: boolean; canSend: boolean; sendConversations?: string[]; binding?: Binding };
export type GroupMember = { userId: string; displayName: string };
export type HistoryFilter = { recent_count: number } | { start_time: number; end_time: number };
export type MediaBlock = { type: 'image' | 'audio'; data: string; mimeType: string };
type Page = { cursor: string | null; more: boolean; rows: unknown[] };
type SendGate = { before: () => void; fingerprint: string; used?: boolean; error?: unknown };
const writeTools = new Set(['messages.send_text', 'messages.reply']);
const asText = (value: unknown) => typeof value === 'string' ? value.slice(0, 500) : '';
const classify = (error: unknown) => {
  if (error instanceof BridgeError) return error;
  const raw = object(error);
  const hint = [raw?.code, raw?.message].map(v => String(v ?? '').slice(0, 500)).join(' ');
  if (/(?:login_generation|instance_id|account_id).*mismatch|scope.changed|login_changed/i.test(hint)) return new BridgeError('wechat-changed');
  if (/\b(?:401|403)\b|forbidden|unauthori|permission|account_not_ready|权限|未登录/i.test(hint)) return new BridgeError('wechat-permission');
  return new BridgeError(raw?.code === -32601 || raw?.code === -32602 ? 'mcp-contract' : 'mcp-offline');
};
const fault = () => new BridgeError('mcp-contract');
const label = (row: Record<string, unknown>, fallback: string) =>
  [row.remark, row.display_name, row.nickname, row.name, fallback].find(id)!.slice(0, 100);

function page(data: Record<string, unknown>, rows: unknown, cursor: string | null, max: number, event = false): Page {
  const { has_more: more, next_cursor: next } = data;
  if (typeof more !== 'boolean' || !Array.isArray(rows) || rows.length > max ||
      !(id(next) || (!more && (next == null || next === '') && (!event || (!rows.length && cursor === null)))) ||
      (next === cursor && (more || (event && rows.length > 0)))) throw fault();
  return { cursor: id(next) ? next : null, more, rows };
}
function receipt(data: Record<string, unknown>): Receipt {
  const status = data.status === 'submitted' || data.status === 'rejected' ? data.status : 'unknown';
  return { status, delivery: status === 'rejected' ? 'failed' :
    data.delivery === 'delivered' || data.delivery === 'failed' ? data.delivery : 'unknown',
    ...(id(data.operation_id) ? { operation: data.operation_id } : {}),
    ...(id(data.message_ref) ? { ref: data.message_ref } : {}) };
}

export class XiaoheClient {
  readonly url: string;
  private client?: Client;
  private transport?: StreamableHTTPClientTransport;
  private wiring?: Promise<Client>;
  private closing?: Promise<void>;
  private readonly gates = new Map<string, SendGate>();
  private readonly members = new Map<string, { expires: number; rows: GroupMember[] }>();

  constructor(url: string, private readonly options: XiaoheClientOptions = {}) {
    this.url = endpoint(url, 'mcp').href;
    if (options.token !== undefined && !/^[\x21-\x7e]{1,4096}$/.test(options.token)) throw new BridgeError('invalid-key');
  }

  private connect() {
    if (this.closing) throw new BridgeError('stopped');
    if (this.client) return Promise.resolve(this.client);
    if (this.wiring) return this.wiring;
    const client = new Client({ name: 'wechat-menu-bridge', version: '2.0.0' });
    const transport = new StreamableHTTPClientTransport(new URL(this.url), {
      fetch: async (input, init) => {
        const url = input instanceof Request ? input.url : String(input);
        if (url !== this.url) throw new BridgeError('invalid-endpoint');
        if (init?.method === 'GET') return new Response(null, { status: 405 });
        const body = typeof init?.body === 'string' ? object(JSON.parse(init.body)) : undefined;
        const params = object(body?.params);
        const tool = body?.method === 'tools/call' ? params?.name : undefined;
        const deadline = AbortSignal.timeout(init?.method === 'DELETE' ? 700 : tool === 'events.wait' ? 23_000 : 4500);
        const signal = init?.signal ? AbortSignal.any([init.signal, deadline]) : deadline;
        const headers = new Headers(init?.headers);
        if (this.options.token) headers.set('Authorization', `Bearer ${this.options.token}`);
        signal.throwIfAborted();
        if (typeof tool === 'string' && writeTools.has(tool)) {
          const args = object(params?.arguments);
          const gate = id(args?.client_request_id) ? this.gates.get(args.client_request_id) : undefined;
          if (!gate || gate.used || gate.fingerprint !== JSON.stringify([tool, args])) throw new BridgeError('send-not-authorized');
          gate.used = true;
          try { gate.before(); } catch (error) { gate.error = error; throw error; }
        }
        return fetch(url, { ...init, headers, signal, credentials: 'omit', redirect: 'error', proxy: '', keepalive: false });
      },
    });
    this.transport = transport;
    this.wiring = client.connect(transport, { timeout: 3500 }).then(() => {
      if (this.closing) throw new BridgeError('stopped');
      this.client = client;
      return client;
    }).catch(async error => {
      await client.close().catch(() => {});
      throw classify(error);
    }).finally(() => { this.wiring = undefined; });
    return this.wiring;
  }

  private async call(name: string, args: Record<string, unknown>, signal?: AbortSignal) {
    try {
      signal?.throwIfAborted();
      const client = await this.connect();
      signal?.throwIfAborted();
      const result = await client.callTool({ name, arguments: args }, undefined, {
        signal, timeout: name === 'events.wait' ? 23_500 : 5000,
      });
      const content = Array.isArray(result.content) ? result.content : [];
      let value = object(result.structuredContent);
      for (const block of content) {
        const item = object(block);
        if (!value && item?.type === 'text' && typeof item.text === 'string') {
          try { value = object(JSON.parse(item.text)); } catch { /* 保留结构化诊断 */ }
        }
      }
      const error = object(value?.error);
      if (result.isError || value?.ok === false || error) {
        const hint = [error?.code, error?.message, object(content[0])?.text].map(asText).join(' ');
        // 传输超时或普通 RPC 错误不能作为微信明确拒收的依据。
        if (error && /^(?:permission_denied|account_not_ready|login_generation_mismatch|instance_id_mismatch|account_id_mismatch)$/.test(asText(error.code))) {
          throw classify({ message: error.code });
        }
        if (name === 'messages.get_context' && /message_not_found|message_recalled/.test(hint)) throw new BridgeError('no-anchor');
        throw fault();
      }
      if (!value && name !== 'messages.read_media') throw fault();
      return { data: object(value?.data) ?? value ?? {}, content };
    } catch (error) {
      if (signal?.aborted) throw new BridgeError('stopped');
      const coded = classify(error);
      // HTTP 状态或客户端诊断不等于工具返回的明确拒收。
      if (writeTools.has(name) && !(error instanceof BridgeError)) throw new BridgeError('mcp-offline');
      throw coded;
    }
  }

  async listTools(accountId?: string, signal?: AbortSignal) {
    try {
      const client = await this.connect();
      const tools: { name: string; inputSchema: unknown }[] = [];
      const seen = new Set<string>();
      let cursor: string | undefined;
      do {
        signal?.throwIfAborted();
        const next = await client.listTools(cursor ? { cursor } : {}, { signal, timeout: 5000 });
        tools.push(...next.tools);
        cursor = next.nextCursor;
        if (cursor && (seen.has(cursor) || seen.size >= 100)) throw fault();
        if (cursor) seen.add(cursor);
      } while (cursor);
      const accounts = await this.accounts(signal);
      return new CapabilityRegistry(tools).detect(accounts.some(row => (!accountId || row.id === accountId) && row.canSend));
    } catch (error) {
      if (signal?.aborted) throw new BridgeError('stopped');
      throw classify(error);
    }
  }

  async systemStatus(signal?: AbortSignal) {
    const { data } = await this.call('system.status', {}, signal);
    if (!id(data.server_id)) throw fault();
    return { server: data.server_id };
  }

  async accounts(signal?: AbortSignal): Promise<Account[]> {
    const { data } = await this.call('accounts.list', {}, signal);
    if (!Array.isArray(data.accounts)) throw fault();
    return data.accounts.slice(0, 20).flatMap(raw => {
      const row = object(raw);
      if (!row || !id(row.account_id)) return [];
      const parsed = xiaoheAccountSchema.safeParse(raw);
      const valid = parsed.success ? parsed.data : undefined;
      const permission = (key: string) => !!valid && row.ready === true && valid.permissions.includes(key) &&
        object(valid.capabilities[key])?.ready === true;
      return [{ id: row.account_id, label: label(row, row.account_id), canRead: permission('events.read'),
        canSend: permission('messages.send_text'), sendConversations: valid?.send_conversations,
        binding: valid && { account_id: valid.account_id, instance_id: valid.instance_id, login_generation: valid.login_generation } }];
    });
  }

  async identify(accountId: string, signal?: AbortSignal, requireWrite = false, conversationId?: string): Promise<RemoteIdentity> {
    const { server } = await this.systemStatus(signal);
    const rows = (await this.accounts(signal)).filter(row => row.id === accountId);
    const row = rows.length === 1 ? rows[0] : undefined;
    if (!row?.binding || !row.canRead || (requireWrite && (!row.canSend ||
      (conversationId && row.sendConversations && !row.sendConversations.includes('*') && !row.sendConversations.includes(conversationId))))) throw new BridgeError('wechat-permission');
    return { server, binding: row.binding };
  }

  async conversations(binding: Binding, options: { cursor?: string; query?: string; limit?: number } = {}, signal?: AbortSignal) {
    const { cursor, query, limit } = options;
    const { data } = await this.call('conversations.list', { ...binding, cursor, query, page_size: limit }, signal);
    const parsed = xiaoheConversationPageSchema.safeParse(data);
    if (!parsed.success || (parsed.data.has_more && (!id(parsed.data.next_cursor) || parsed.data.next_cursor === cursor))) throw fault();
    return parsed.data;
  }

  async contacts(binding: Binding, query: string, signal?: AbortSignal) {
    const { data } = await this.call('contacts.search', { ...binding, query, page_size: 30 }, signal);
    const rows = data.contacts ?? data.items;
    if (!Array.isArray(rows)) throw fault();
    return rows.slice(0, 30).flatMap(raw => {
      const row = object(raw);
      const userId = row?.user_id ?? row?.wxid ?? row?.contact_id;
      return row && id(userId) ? [{ userId, displayName: label(row, userId) }] : [];
    });
  }

  async groupMembers(scope: Scope, signal?: AbortSignal): Promise<GroupMember[]> {
    if (!scope.conversation_id.endsWith('@chatroom')) throw new BridgeError('invalid-configuration');
    signal?.throwIfAborted();
    const key = JSON.stringify([scope.account_id, scope.instance_id, scope.login_generation, scope.conversation_id]);
    const now = this.options.now ?? Date.now;
    const old = this.members.get(key);
    this.members.delete(key);
    if (old && old.expires > now()) {
      this.members.set(key, old);
      return old.rows.map(row => ({ ...row }));
    }
    const rows = new Map<string, GroupMember>();
    const cursors = new Set<string>();
    let cursor: string | null = null;
    while (true) {
      const { data } = await this.call('groups.members', { ...scope, cursor: cursor ?? undefined, page_size: 500 }, signal);
      const next = page(data, data.members, cursor, 500);
      for (const raw of next.rows) {
        const row = object(raw);
        if (!row || !id(row.user_id)) throw fault();
        rows.set(row.user_id, { userId: row.user_id, displayName: label(row, row.user_id) });
      }
      if (!next.more) break;
      if (!next.cursor || cursors.has(next.cursor) || cursors.size >= 100) throw fault();
      cursor = next.cursor;
      cursors.add(cursor);
    }
    const result = [...rows.values()];
    this.members.set(key, { expires: now() + 30 * 60_000, rows: result });
    const max = Math.max(1, this.options.groupCacheSize ?? 64);
    while (this.members.size > max) this.members.delete(this.members.keys().next().value!);
    return result.map(row => ({ ...row }));
  }

  async events(scope: EventScope, cursor: string | null, wait = false, signal?: AbortSignal) {
    const { data } = await this.call(wait ? 'events.wait' : 'events.read', {
      ...scope, cursor: cursor ?? undefined, page_size: 500, ...(wait ? { timeout_seconds: 20 } : {}),
    }, signal);
    if (data.event_gap === true) throw new BridgeError('event-gap');
    if (data.account_id !== scope.account_id || data.instance_id !== scope.instance_id || data.login_generation !== scope.login_generation) {
      throw new BridgeError('wechat-changed');
    }
    if (data.event_gap !== false) throw fault();
    const result = page(data, data.events, cursor, 500, true);
    return { cursor: result.cursor, more: result.more, events: result.rows };
  }

  async queryMessages(scope: Scope, filter: HistoryFilter, cursor: string | null, signal?: AbortSignal) {
    const { data } = await this.call('messages.query', { ...scope, ...filter, page_size: 100, cursor: cursor ?? undefined }, signal);
    return page(data, data.messages ?? data.items, cursor, 100);
  }

  async messageContext(scope: Scope, messageRef: string, signal?: AbortSignal) {
    const { data } = await this.call('messages.get_context', { ...scope, message_ref: messageRef, before: 0, after: 0 }, signal);
    const rows = [data.anchor, data.anchor_message, data.message, data,
      ...(Array.isArray(data.messages) ? data.messages : []), ...(Array.isArray(data.items) ? data.items : [])];
    const row = rows.map(object).find(item => item?.message_ref === messageRef);
    if (!row || (row.conversation_id ?? data.conversation_id) !== scope.conversation_id ||
      Object.entries(scope).some(([key, value]) => [data[key], row[key]].some(v => v !== undefined && v !== value))) {
      throw new BridgeError('wrong-anchor');
    }
    if (row.is_recalled === true || row.recalled === true) throw new BridgeError('no-anchor');
    return row;
  }

  async readMedia(scope: Scope, mediaRef: string, options: { representation?: 'preview' | 'source'; allowDownload?: boolean;
    maxDimension?: number; frameCount?: number } = {}, signal?: AbortSignal) {
    const { data, content } = await this.call('messages.read_media', { ...scope, media_ref: mediaRef,
      representation: options.representation ?? 'preview', allow_download: options.allowDownload ?? false,
      max_dimension: options.maxDimension, frame_count: options.frameCount }, signal);
    const blocks = content.flatMap((raw): MediaBlock[] => {
      const row = object(raw);
      return (row?.type === 'image' || row?.type === 'audio') && typeof row.data === 'string' && typeof row.mimeType === 'string'
        ? [{ type: row.type, data: row.data, mimeType: row.mimeType }] : [];
    });
    return { data, blocks };
  }

  sendText(scope: Scope, text: string, attemptId: string, before: () => void, mentions?: string[]) {
    return this.send('messages.send_text', { ...scope, text, client_request_id: attemptId,
      ...(mentions?.length ? { mention_user_ids: mentions } : {}) }, before);
  }

  reply(scope: Scope, messageRef: string, text: string, attemptId: string, before: () => void, mentions?: string[]) {
    return this.send('messages.reply', { ...scope, message_ref: messageRef, text, client_request_id: attemptId,
      ...(mentions?.length ? { mention_user_ids: mentions } : {}) }, before);
  }

  private async send(tool: string, args: Record<string, unknown>, before: () => void) {
    const key = args.client_request_id;
    if (!id(key) || typeof before !== 'function') throw new BridgeError('send-not-authorized');
    if (this.gates.has(key)) throw new BridgeError('busy');
    const gate: SendGate = { before, fingerprint: JSON.stringify([tool, args]) };
    this.gates.set(key, gate);
    try { return receipt((await this.call(tool, args)).data); }
    catch (error) { throw gate.error ?? error; }
    finally { this.gates.delete(key); }
  }

  async operation(operationId: string, signal?: AbortSignal) {
    const { data } = await this.call('operations.get', { operation_id: operationId }, signal);
    const result = object(data.operation) ?? data;
    if (result.operation_id !== undefined && result.operation_id !== operationId) throw fault();
    return receipt(result);
  }

  close() {
    return this.closing ??= (async () => {
      await this.wiring?.catch(() => {});
      await this.transport?.terminateSession().catch(() => {});
      await this.transport?.close().catch(() => {});
      this.members.clear();
    })();
  }
}
