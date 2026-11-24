import { createHmac, randomUUID } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { lstatSync } from 'node:fs';
import { request } from 'node:https';
import { isIP } from 'node:net';
import { join } from 'node:path';
import { id, sha } from '../../contracts.ts';
import { BridgeError, errorCode } from '../contracts/errors.ts';
import type { RpcParams, RpcResult } from '../contracts/ipc.ts';
import type { PluginSinkConfig, WebhookPlatform } from '../contracts/plugins.ts';
import type { TransmitService } from '../core/transmit.ts';
import { atomicWritePrivateFile, ensurePrivateDir, readPrivateFile, resolveContainedPath } from '../storage/fs-safe.ts';
import type { FeedItem, JournalV2 } from '../storage/journal-v2.ts';

export interface SinkDispatcherOptions {
  journal: JournalV2;
  baseDir: string;
  getTransmit?: () => { transmitter: Pick<TransmitService, 'send'>; expectedIdentity: string } | undefined;
  authorizeOutputDirectory?: (directory: string) => boolean;
  authorizeModuleWeChatTarget?: (pluginId: string, conversationId: string) => boolean;
  resolveWebhookSecret?: (pluginId: string, sinkId: string, url: string) => string | undefined | Promise<string | undefined>;
  onFeedAdded?: (item: FeedItem, notifyDesktop: boolean) => void;
  now?: () => number;
}

export interface SinkOutput {
  pluginId: string;
  conversationId: string;
  scopeName: string;
  title: string;
  markdown: string;
  dedupeKey: string;
  maxWeChatSendsPerDay: number;
  origin: 'live' | 'human' | 'backfill';
  signal: AbortSignal;
  checkStillValid?: () => void;
}

function publicAddress(address: string) {
  if (isIP(address) === 6) {
    const prefix = Number.parseInt(address.split(':')[0]!, 16);
    const second = Number.parseInt(address.split(':')[1]!, 16) || 0;
    return prefix >= 0x2000 && prefix < 0x4000 && prefix !== 0x2002 && prefix !== 0x3fff &&
      !(prefix === 0x2001 && (second < 0x200 || second === 0xdb8));
  }
  if (isIP(address) !== 4) return false;
  const [a, b, c] = address.split('.').map(Number) as [number, number, number, number];
  return a > 0 && a < 224 && a !== 10 && a !== 127 && !(a === 100 && b >= 64 && b <= 127) &&
    !(a === 169 && b === 254) && !(a === 172 && b >= 16 && b <= 31) &&
    !(a === 192 && (b === 168 || (b === 0 && c <= 2) || (b === 88 && c === 99))) &&
    !(a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) &&
    !(a === 203 && b === 0 && c === 113);
}

export function checkWebhookUrl(raw: string) {
  let url: URL;
  try { url = new URL(raw); } catch { throw new BridgeError('invalid-endpoint'); }
  const { protocol, hostname, username, password, hash } = url;
  const name = hostname.replace(/\.$/, '');
  if (username || password || hash || hostname.startsWith('[') ||
      (protocol !== 'https:' && !(protocol === 'http:' && hostname === '127.0.0.1')) ||
      name === 'localhost' || name.endsWith('.localhost') || name.endsWith('.local') ||
      (isIP(name) !== 0 && name !== '127.0.0.1' && !publicAddress(name))) throw new BridgeError('invalid-endpoint');
  return url;
}

type WebhookResponse = { status: number; text: string };
type WebhookRequest = { method: 'POST' | 'PATCH'; headers: Record<string, string>; body: string };
export interface WebhookMessage { pluginId: string; conversationId: string; title: string; markdown: string }
const RESPONSE_PREVIEW_BYTES = 4096;

function pinnedRequest(url: URL, request_: WebhookRequest, signal: AbortSignal, hostname: string) {
  return new Promise<WebhookResponse>((resolve, reject) => {
    const req = request(url, { method: request_.method, headers: request_.headers, signal, agent: false,
      ...(isIP(hostname) === 0 && { servername: hostname }) }, response => {
      const chunks: Buffer[] = [];
      let size = 0;
      const finish = () => {
        response.destroy();
        resolve({ status: response.statusCode ?? 0, text: Buffer.concat(chunks).toString('utf8') });
      };
      response.on('data', (chunk: Buffer) => {
        if (size < RESPONSE_PREVIEW_BYTES) chunks.push(chunk.subarray(0, RESPONSE_PREVIEW_BYTES - size));
        size += chunk.length;
        if (size >= RESPONSE_PREVIEW_BYTES) finish();
      });
      response.on('end', finish);
      response.on('close', finish);
      response.on('error', finish);
    });
    req.on('error', reject);
    req.end(request_.body);
  });
}

async function previewText(response: Response) {
  const reader = response.body?.getReader();
  if (!reader) return '';
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (size < RESPONSE_PREVIEW_BYTES) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    size += value.byteLength;
  }
  await reader.cancel().catch(() => {});
  return Buffer.concat(chunks).subarray(0, RESPONSE_PREVIEW_BYTES).toString('utf8');
}

function clip(text: string, max: number) {
  if (text.length <= max) return text;
  let value = text.slice(0, max - 1);
  if (/[\uD800-\uDBFF]$/u.test(value)) value = value.slice(0, -1);
  return `${value}…`;
}

function clipBytes(text: string, maxBytes: number) {
  if (Buffer.byteLength(text, 'utf8') <= maxBytes) return text;
  let value = text;
  while (Buffer.byteLength(value, 'utf8') > maxBytes - 3) value = value.slice(0, Math.floor(value.length * 0.9));
  if (/[\uD800-\uDBFF]$/u.test(value)) value = value.slice(0, -1);
  return `${value}…`;
}

const hmacHex = (key: string, body: string) => `sha256=${createHmac('sha256', key).update(body).digest('hex')}`;

/** 飞书自定义机器人签名：以 `timestamp\nsecret` 为 HMAC-SHA256 密钥，对空串签名后 Base64。 */
export function feishuSign(timestamp: string, secret: string) {
  return createHmac('sha256', `${timestamp}\n${secret}`).update('').digest('base64');
}

function notionBlocks(title: string, markdown: string) {
  const text = (content: string) => [{ type: 'text', text: { content } }];
  const chunks: string[] = [];
  for (const paragraph of markdown.split(/\n{2,}/u).map(part => part.trim()).filter(Boolean)) {
    for (let index = 0; index < paragraph.length && chunks.length < 90; index += 1900) {
      chunks.push(paragraph.slice(index, index + 1900));
    }
  }
  return [
    { object: 'block', type: 'heading_2', heading_2: { rich_text: text(clip(title, 1900)) } },
    ...chunks.map(content => ({ object: 'block', type: 'paragraph', paragraph: { rich_text: text(content) } })),
  ];
}

/** 按平台构造请求体与签名头；纯函数，便于单测核对。 */
export function buildWebhookRequest(platform: WebhookPlatform, url: URL, message: WebhookMessage,
  secret: string | undefined, now: number): WebhookRequest {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  const title = clip(message.title.trim() || '微信桥通知', 200);
  switch (platform) {
    case 'feishu': {
      const payload: Record<string, unknown> = {
        msg_type: 'interactive',
        card: {
          config: { wide_screen_mode: true },
          header: { title: { tag: 'plain_text', content: title } },
          elements: [{ tag: 'markdown', content: clip(message.markdown, 4000) }],
        },
      };
      if (secret) {
        const timestamp = String(Math.floor(now / 1000));
        payload.timestamp = timestamp;
        payload.sign = feishuSign(timestamp, secret);
      }
      return { method: 'POST', headers, body: JSON.stringify(payload) };
    }
    case 'wecom':
      return { method: 'POST', headers, body: JSON.stringify({
        msgtype: 'markdown', markdown: { content: clipBytes(`**${title}**\n\n${message.markdown}`, 4096) },
      }) };
    case 'telegram':
      // chat_id 等查询参数保留在 URL 上，正文只携带文本。
      return { method: 'POST', headers, body: JSON.stringify({
        text: clip(`${title}\n\n${message.markdown}`, 4096), disable_web_page_preview: true,
      }) };
    case 'notion': {
      if (!secret) throw new BridgeError('missing-key');
      headers.Authorization = `Bearer ${secret}`;
      headers['Notion-Version'] = '2022-06-28';
      const append = /\/children\/?$/.test(url.pathname);
      return { method: append ? 'PATCH' : 'POST', headers, body: JSON.stringify({ children: notionBlocks(title, message.markdown) }) };
    }
    case 'generic': {
      const body = JSON.stringify({ pluginId: message.pluginId, conversationId: message.conversationId,
        title: message.title, markdown: message.markdown });
      if (secret) {
        const signature = hmacHex(secret, body);
        headers['X-Webhook-Signature'] = signature;
        headers['X-WeChatBridge-Signature'] = signature;
      }
      return { method: 'POST', headers, body };
    }
  }
}

/** 部分平台以 HTTP 200 + 业务错误码返回失败，需解析正文判定。 */
function platformAccepted(platform: WebhookPlatform, response: WebhookResponse) {
  if (response.status < 200 || response.status >= 300) return false;
  let body: Record<string, unknown> | undefined;
  try {
    const parsed: unknown = JSON.parse(response.text);
    body = parsed && typeof parsed === 'object' ? parsed as Record<string, unknown> : undefined;
  } catch { return true; }
  if (!body) return true;
  if (platform === 'feishu') return (body.code ?? body.StatusCode ?? 0) === 0;
  if (platform === 'wecom') return (body.errcode ?? 0) === 0;
  if (platform === 'telegram') return body.ok !== false;
  return true;
}

function abortable<T>(work: T | Promise<T>, signal: AbortSignal): Promise<T> {
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason);
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) abort();
    void Promise.resolve(work).then(resolve, reject).finally(() => signal.removeEventListener('abort', abort));
  });
}

const safeSegment = (value: string) => value.replace(/[\\/\p{Cc}\p{Cf}]/gu, '_').replace(/^\.+$/, '_').slice(0, 100) || '_';
const localDate = (now: number) => {
  const date = new Date(now);
  return [date.getFullYear(), date.getMonth() + 1, date.getDate()].map(part => String(part).padStart(2, '0')).join('-');
};

export class SinkDispatcher {
  private readonly now: () => number;

  constructor(private readonly options: SinkDispatcherOptions) {
    this.now = options.now ?? Date.now;
  }

  async dispatch(sinks: readonly PluginSinkConfig[], output: SinkOutput) {
    const results = await Promise.allSettled(sinks.map(async sink => {
      this.check(output);
      switch (sink.type) {
        case 'app_feed':
          this.feed({ pluginId: output.pluginId, conversationId: output.conversationId,
            title: output.title, body: output.markdown, notify: sink.notifyDesktop });
          return;
        case 'markdown_file': {
          const filename = sink.filenameTemplate.replace(/\{\{(date|scope_name)\}\}/g, (_, key: string) =>
            key === 'date' ? localDate(this.now()) : safeSegment(output.scopeName));
          return this.markdownFile(filename, output.markdown, sink.mode, sink.directory);
        }
        case 'wechat':
          if (output.origin !== 'backfill') await this.wechat(sink.targetConversationId, output.markdown, sink.approved, output);
          return;
        case 'webhook':
          await this.notify(sink, { pluginId: output.pluginId, conversationId: output.conversationId,
            title: output.title, markdown: output.markdown }, output.signal);
      }
    }));
    return {
      outputPaths: results.flatMap(result => result.status === 'fulfilled' && typeof result.value === 'string' ? [result.value] : []),
      errors: results.flatMap(result => result.status === 'rejected' ? [errorCode(result.reason)] : []),
    };
  }

  feed(item: { pluginId: string; title: string; body: string; notify?: boolean; conversationId?: string; kind?: FeedItem['kind'] }) {
    const entry: FeedItem = {
      id: randomUUID(), kind: item.kind ?? 'plugin_digest', title: item.title.slice(0, 500), body: item.body.slice(0, 2000),
      conversation_id: item.conversationId || null, plugin_id: item.pluginId, ref_path: null, created_at: this.now(), read: 0,
    };
    this.options.journal.saveFeedItem(entry);
    try { this.options.onFeedAdded?.(entry, item.notify === true); } catch { /* 通知监听器独立于已持久化的卡片 */ }
  }

  markdownFile(filename: string, content: string, mode: 'append' | 'overwrite', directory?: string, moduleId?: string) {
    const defaultDir = resolveContainedPath(this.options.baseDir, 'outputs');
    const root = directory || defaultDir;
    if (root !== defaultDir && !this.options.authorizeOutputDirectory?.(root)) throw new BridgeError('plugin-permission');
    ensurePrivateDir(root);
    const relative = moduleId ? `${moduleId}/${filename}` : filename;
    const path = resolveContainedPath(root, relative);
    const parts = relative.split('/');
    let parent = root;
    for (const part of parts.slice(0, -1)) {
      parent = resolveContainedPath(parent, part);
      ensurePrivateDir(parent);
    }
    const target = resolveContainedPath(root, relative);
    if (target !== path) throw new BridgeError('storage-unavailable');
    let previous = '';
    if (mode === 'append') {
      let exists = true;
      try { lstatSync(target); } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw new BridgeError('storage-unavailable');
        exists = false;
      }
      if (exists) previous = readPrivateFile(target, 16 * 1024 * 1024).toString('utf8');
    }
    atomicWritePrivateFile(target, [previous, content.trimEnd(), ''].filter((part, index) => part || index > 0).join('\n'));
    return target;
  }

  private check(output: Pick<SinkOutput, 'signal' | 'checkStillValid'>) {
    if (output.signal.aborted) throw new BridgeError('stopped');
    output.checkStillValid?.();
  }

  async wechat(conversationId: string, markdown: string, approved: boolean,
    output: Pick<SinkOutput, 'pluginId' | 'dedupeKey' | 'maxWeChatSendsPerDay' | 'origin' | 'signal' | 'checkStillValid'>) {
    this.check(output);
    if (approved !== true || !id(conversationId) || output.origin === 'backfill') throw new BridgeError('send-not-authorized');
    if (!output.maxWeChatSendsPerDay) throw new BridgeError('plugin-limit');
    const live = this.options.getTransmit?.();
    if (!live) throw new BridgeError('mcp-offline');
    const text = markdown.replace(/[\p{Cc}\p{Cf}]+/gu, ' ').replace(/\s+/gu, ' ').trim();
    if (!text) throw new BridgeError('invalid-configuration');
    let brief = text.slice(0, 500);
    if (/[\uD800-\uDBFF]$/u.test(brief)) brief = brief.slice(0, -1);
    const attemptId = `plugin-${sha(JSON.stringify([output.pluginId, conversationId, output.dedupeKey]))}`;
    const receipt = await live.transmitter.send({
      sourceKind: 'plugin', pluginId: output.pluginId, pluginDailyLimit: output.maxWeChatSendsPerDay,
      expectedIdentity: live.expectedIdentity, conversationId, text: brief, attemptId,
      originGuard: 'live_or_human', origin: output.origin, checkStillValid: () => this.check(output),
    });
    if (receipt.status === 'unknown') throw new BridgeError('send-unknown');
    return { status: receipt.status };
  }

  moduleWeChat(pluginId: string, options: { conversationId: string; text: string; dedupeKey: string }, signal: AbortSignal) {
    const { conversationId, text, dedupeKey } = options;
    const approved = conversationId === 'filehelper' || this.options.authorizeModuleWeChatTarget?.(pluginId, conversationId) === true;
    return this.wechat(conversationId, text, approved, { pluginId, dedupeKey, maxWeChatSendsPerDay: 20, origin: 'live', signal });
  }

  async webhook(raw: string, payload: unknown, parent: AbortSignal, signature?: { pluginId: string; sinkId: string }) {
    const url = checkWebhookUrl(raw);
    const body = JSON.stringify(payload);
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (signature) {
      const key = await this.secret(signature.pluginId, signature.sinkId, url, parent);
      if (!key) throw new BridgeError('missing-key');
      headers['X-Webhook-Signature'] = hmacHex(key, body);
      headers['X-WeChatBridge-Signature'] = headers['X-Webhook-Signature'];
    }
    const response = await this.deliver(url, { method: 'POST', headers, body }, parent);
    if (!platformAccepted('generic', response)) throw new BridgeError('invalid-endpoint');
    return { status: response.status };
  }

  /** 按出口平台格式投递一条通知；所有平台统一经过 SSRF 校验、拒绝跳转并固定解析后的公网 IP。 */
  async notify(sink: Pick<Extract<PluginSinkConfig, { type: 'webhook' }>, 'id' | 'url' | 'hasSecret' | 'platform'>,
    message: WebhookMessage, parent: AbortSignal) {
    const platform = sink.platform ?? 'generic';
    const url = checkWebhookUrl(sink.url);
    if (platform === 'generic') {
      return this.webhook(url.href, message, parent, sink.hasSecret ? { pluginId: message.pluginId, sinkId: sink.id } : undefined);
    }
    const key = sink.hasSecret ? await this.secret(message.pluginId, sink.id, url, parent) : undefined;
    if (sink.hasSecret && !key) throw new BridgeError('missing-key');
    const response = await this.deliver(url, buildWebhookRequest(platform, url, message, key, this.now()), parent);
    if (!platformAccepted(platform, response)) throw new BridgeError('invalid-endpoint');
    return { status: response.status };
  }

  /** 发送一条无害的连通性测试通知；只走 HTTP 出口，绝不触发任何微信发信。 */
  async testWebhook(params: RpcParams<'plugins.testWebhook'>, parent = new AbortController().signal): Promise<RpcResult<'plugins.testWebhook'>> {
    const platform = params.platform ?? 'generic';
    const message: WebhookMessage = { pluginId: params.pluginId, conversationId: 'wechat-bridge-test',
      title: '微信桥通知测试', markdown: '这是一条连通性测试消息。' };
    let statusCode: number | undefined;
    try {
      const url = checkWebhookUrl(params.url);
      const key = params.secret ?? await this.secret(params.pluginId, params.sinkId, url, parent);
      const response = await this.deliver(url, buildWebhookRequest(platform, url, message, key || undefined, this.now()), parent);
      statusCode = response.status;
      if (!platformAccepted(platform, response)) {
        return { ok: false, statusCode, detail: clip(`服务端拒绝了测试通知（HTTP ${statusCode}）：${response.text.replace(/\s+/gu, ' ').trim() || '无响应正文'}`, 300) };
      }
      return { ok: true, statusCode, detail: `测试通知已送达（HTTP ${statusCode}）` };
    } catch (error) {
      const code = errorCode(error);
      const reason = code === 'invalid-endpoint' ? '地址无效、被安全策略拦截或无法连接' :
        code === 'missing-key' ? '缺少该平台所需的密钥或令牌' : code === 'stopped' ? '测试已取消或超时' : '测试通知发送失败';
      return { ok: false, ...(statusCode !== undefined && { statusCode }), detail: `${reason}（${code}）` };
    }
  }

  private async secret(pluginId: string, sinkId: string, url: URL, signal: AbortSignal) {
    try {
      return await abortable(this.options.resolveWebhookSecret?.(pluginId, sinkId, url.href),
        AbortSignal.any([signal, AbortSignal.timeout(5000)]));
    } catch (error) {
      if (error instanceof BridgeError) throw error;
      throw new BridgeError(signal.aborted ? 'stopped' : 'invalid-endpoint');
    }
  }

  private async deliver(url: URL, outgoing: WebhookRequest, parent: AbortSignal): Promise<WebhookResponse> {
    const signal = AbortSignal.any([parent, AbortSignal.timeout(5000)]);
    try {
      if (url.hostname === '127.0.0.1') {
        const response = await fetch(url, { method: outgoing.method, headers: outgoing.headers, body: outgoing.body, signal,
          redirect: 'error', credentials: 'omit', proxy: '' });
        return { status: response.status, text: await previewText(response) };
      }
      const { hostname } = url;
      const addresses = isIP(hostname) ? [{ address: hostname, family: 4 }] : await abortable(lookup(hostname, { all: true }), signal);
      const first = addresses[0];
      if (!first || !addresses.every(({ address }) => publicAddress(address))) throw new BridgeError('invalid-endpoint');
      // 固定已验证的 IP，TLS 仍使用原域名，避免连接时再次解析导致 DNS 重绑定。
      const pinned = new URL(url);
      pinned.hostname = first.family === 6 ? `[${first.address}]` : first.address;
      return await pinnedRequest(pinned, { ...outgoing, headers: { ...outgoing.headers, Host: url.host } }, signal, hostname);
    } catch (error) {
      if (error instanceof BridgeError) throw error;
      throw new BridgeError(parent.aborted ? 'stopped' : 'invalid-endpoint');
    }
  }
}
