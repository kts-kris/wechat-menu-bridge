import { createHmac, randomUUID } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { lstatSync } from 'node:fs';
import { request } from 'node:https';
import { isIP } from 'node:net';
import { join } from 'node:path';
import { id, sha } from '../../contracts.ts';
import { BridgeError, errorCode } from '../contracts/errors.ts';
import type { PluginSinkConfig } from '../contracts/plugins.ts';
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

function pinnedPost(url: URL, headers: Record<string, string>, body: string, signal: AbortSignal, hostname: string) {
  return new Promise<number>((resolve, reject) => {
    const req = request(url, { method: 'POST', headers, signal, agent: false,
      ...(isIP(hostname) === 0 && { servername: hostname }) }, response => {
      response.destroy();
      resolve(response.statusCode ?? 0);
    });
    req.on('error', reject);
    req.end(body);
  });
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
          await this.webhook(sink.url, { pluginId: output.pluginId, conversationId: output.conversationId,
            title: output.title, markdown: output.markdown }, output.signal,
          sink.hasSecret ? { pluginId: output.pluginId, sinkId: sink.id } : undefined);
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
    const signal = AbortSignal.any([parent, AbortSignal.timeout(5000)]);
    const body = JSON.stringify(payload);
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    let status: number;
    try {
      if (signature) {
        const key = await abortable(this.options.resolveWebhookSecret?.(signature.pluginId, signature.sinkId, url.href), signal);
        if (!key) throw new BridgeError('missing-key');
        headers['X-Webhook-Signature'] = `sha256=${createHmac('sha256', key).update(body).digest('hex')}`;
      }
      if (url.hostname === '127.0.0.1') {
        const response = await fetch(url, { method: 'POST', headers, body, signal, redirect: 'error', credentials: 'omit', proxy: '' });
        status = response.status;
        await response.body?.cancel();
      } else {
        const { hostname } = url;
        const addresses = isIP(hostname) ? [{ address: hostname, family: 4 }] : await abortable(lookup(hostname, { all: true }), signal);
        const first = addresses[0];
        if (!first || !addresses.every(({ address }) => publicAddress(address))) throw new BridgeError('invalid-endpoint');
        // 固定已验证的 IP，TLS 仍使用原域名，避免连接时再次解析导致 DNS 重绑定。
        const pinned = new URL(url);
        pinned.hostname = first.family === 6 ? `[${first.address}]` : first.address;
        status = await pinnedPost(pinned, { ...headers, Host: url.host }, body, signal, hostname);
      }
    } catch (error) {
      if (error instanceof BridgeError) throw error;
      throw new BridgeError(parent.aborted ? 'stopped' : 'invalid-endpoint');
    }
    if (status < 200 || status >= 300) throw new BridgeError('invalid-endpoint');
    return { status };
  }
}
