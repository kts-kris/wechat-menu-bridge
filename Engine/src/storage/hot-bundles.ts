import { createHash, createPublicKey, randomUUID, verify, type KeyObject } from 'node:crypto';
import { existsSync, lstatSync, readdirSync, renameSync, rmSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { z } from 'zod';
import { BridgeError } from '../contracts/errors.ts';
import type { RpcResult } from '../contracts/ipc.ts';
import { atomicWritePrivateFile, ensurePrivateDir, readPrivateFile, resolveContainedPath } from './fs-safe.ts';

const MAX_BUNDLE_BYTES = 256 * 1024;
const MAX_MANIFEST_BYTES = 64 * 1024;
const REMOTE_TIMEOUT_MS = 15_000;
const MAX_GITHUB_REDIRECTS = 3;
const ALLOWED_EXT = /\.(?:json|md)$/i;
const SAFE_NAME = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/;
const GITHUB_RELEASE_CDN_HOSTS = new Set([
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
]);

/** 仅允许 GitHub Releases 下载链路在受控 HTTPS 域名间跳转（所有资产仍须通过 SHA-256 与内置官方公钥验签）。 */
export function isAllowedGitHubReleaseRedirect(from: URL, to: URL): boolean {
  if (from.protocol !== 'https:' || to.protocol !== 'https:') return false;
  if (to.username || to.password || to.hash) return false;
  const fromHost = from.hostname.toLowerCase();
  const toHost = to.hostname.toLowerCase();
  const repoPrefix = (url: URL) => {
    const match = /^\/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/releases\//.exec(url.pathname);
    return match ? match[1]!.toLowerCase() : undefined;
  };
  if (fromHost === 'github.com') {
    const repo = repoPrefix(from);
    if (!repo) return false;
    if (toHost === 'github.com') return repoPrefix(to) === repo;
    return GITHUB_RELEASE_CDN_HOSTS.has(toHost);
  }
  if (GITHUB_RELEASE_CDN_HOSTS.has(fromHost)) {
    return GITHUB_RELEASE_CDN_HOSTS.has(toHost);
  }
  return false;
}

// 与 App/Info.plist 的 SUPublicEDKey 保持一致：远程热更新资产只认这把官方 Ed25519 公钥。
export const OFFICIAL_BUNDLE_PUBLIC_KEY = 'VStTm0b59AmB7fVgfgB5B7nS6u6OxOMVh3Hn616+ptY=';
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

const manifestSchema = z.strictObject({
  version: z.string().trim().min(1).max(64).optional(),
  files: z.record(z.string().min(1).max(128), z.string().regex(/^[0-9a-f]{64}$/i)),
  signature: z.string().min(1).max(512).optional(),
  publicKeyPem: z.string().min(1).max(2048).optional(),
  assetUrls: z.record(z.string().min(1).max(128), z.string().min(1).max(2048)).optional(),
});
type Manifest = z.infer<typeof manifestSchema>;

export interface HotBundleOptions {
  /** 仅供单元测试注入替代公钥（32 字节原始 Ed25519 公钥的 Base64）。 */
  pinnedPublicKeyBase64?: string;
  /** 仅供单元测试允许 http://127.0.0.1 源。 */
  allowLocalHttp?: boolean;
}

function ed25519Key(rawBase64: string): KeyObject {
  const raw = Buffer.from(rawBase64, 'base64');
  if (raw.length !== 32) throw new BridgeError('invalid-configuration');
  return createPublicKey({ key: Buffer.concat([ED25519_SPKI_PREFIX, raw]), format: 'der', type: 'spki' });
}

const modelCompatSchema = z.strictObject({
  disableReasoningEffortUrls: z.array(z.string().url()).max(128).default([]),
});

export type HotBundlesStatus = RpcResult<'system.bundles'>;

function sha256Hex(data: Buffer): string {
  return createHash('sha256').update(data).digest('hex');
}

function canonicalManifestPayload(version: string | undefined, files: Record<string, string>) {
  const sortedFiles = Object.fromEntries(Object.entries(files).sort(([a], [b]) => a.localeCompare(b)));
  return JSON.stringify({ ...(version !== undefined ? { version } : {}), files: sortedFiles });
}

function verifySignature(manifest: Manifest, key: KeyObject) {
  if (!manifest.signature) return false;
  try {
    const payload = Buffer.from(canonicalManifestPayload(manifest.version, manifest.files), 'utf8');
    return verify(null, payload, key, Buffer.from(manifest.signature, 'base64'));
  } catch {
    return false;
  }
}

async function readLimited(response: Response, limit: number): Promise<Buffer> {
  const declared = Number(response.headers.get('content-length') ?? '0');
  if (Number.isFinite(declared) && declared > limit) {
    await response.body?.cancel();
    throw new BridgeError('invalid-configuration');
  }
  const reader = response.body?.getReader();
  if (!reader) return Buffer.alloc(0);
  const chunks: Buffer[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      throw new BridgeError('invalid-configuration');
    }
    chunks.push(Buffer.from(value));
  }
  return Buffer.concat(chunks, size);
}

export class HotBundleManager {
  private readonly stateDir: string;
  private readonly dir: string;
  private readonly pinnedKey: KeyObject;
  private readonly allowLocalHttp: boolean;
  private current: HotBundlesStatus = { loadedCount: 0, items: [] };
  private disabledUrls = new Set<string>();
  private promptAddon = '';
  private syncing?: Promise<HotBundlesStatus>;

  constructor(stateDir: string, options: HotBundleOptions = {}) {
    this.stateDir = stateDir;
    this.dir = join(stateDir, 'bundles');
    this.pinnedKey = ed25519Key(options.pinnedPublicKeyBase64 ?? OFFICIAL_BUNDLE_PUBLIC_KEY);
    this.allowLocalHttp = options.allowLocalHttp === true;
    this.reload();
  }

  status(): HotBundlesStatus {
    return {
      loadedCount: this.current.loadedCount,
      ...(this.current.version !== undefined && { version: this.current.version }),
      ...(this.current.lastReloadAt !== undefined && { lastReloadAt: this.current.lastReloadAt }),
      items: this.current.items.map(item => ({ ...item })),
    };
  }

  disabledReasoningEffortUrls(): string[] {
    return [...this.disabledUrls];
  }

  replyPromptAddon(): string {
    return this.promptAddon;
  }

  reload(): HotBundlesStatus {
    const now = Date.now();
    this.disabledUrls = new Set();
    this.promptAddon = '';
    if (!existsSync(this.dir)) {
      this.current = { loadedCount: 0, lastReloadAt: now, items: [] };
      return this.status();
    }
    const dirStat = lstatSync(this.dir);
    if (dirStat.isSymbolicLink() || !dirStat.isDirectory()) {
      throw new BridgeError('storage-unavailable');
    }

    let manifest: z.infer<typeof manifestSchema> | undefined;
    let signatureValid = true;
    const manifestPath = resolveContainedPath(this.dir, 'manifest.json');
    if (existsSync(manifestPath)) {
      const raw = readPrivateFile(manifestPath, MAX_BUNDLE_BYTES).toString('utf8');
      let parsedJson: unknown;
      try { parsedJson = JSON.parse(raw); } catch { throw new BridgeError('invalid-configuration'); }
      const checked = manifestSchema.safeParse(parsedJson);
      if (!checked.success) throw new BridgeError('invalid-configuration');
      manifest = checked.data;
      if (manifest.signature || manifest.publicKeyPem) {
        // 优先使用内置官方公钥；兼容旧版本地自托管清单内嵌的 publicKeyPem。
        signatureValid = verifySignature(manifest, this.pinnedKey);
        if (!signatureValid && manifest.publicKeyPem) {
          try { signatureValid = verifySignature(manifest, createPublicKey(manifest.publicKeyPem)); }
          catch { signatureValid = false; }
        }
      }
    }

    const entries = readdirSync(this.dir).sort((a, b) => a.localeCompare(b));
    const items: HotBundlesStatus['items'] = [];
    for (const name of entries) {
      if (name === 'manifest.json' || name.startsWith('.') || !ALLOWED_EXT.test(name)) continue;
      const fullPath = resolveContainedPath(this.dir, name);
      const st = lstatSync(fullPath);
      if (st.isSymbolicLink() || !st.isFile()) throw new BridgeError('storage-unavailable');
      const data = readPrivateFile(fullPath, MAX_BUNDLE_BYTES);
      const digest = sha256Hex(data);
      const expected = manifest?.files[name]?.toLowerCase();
      const verified = manifest !== undefined ? (signatureValid && expected === digest) : false;
      items.push({ name, sha256: digest, verified });

      // 仅应用校验通过（或在无清单自托管模式下格式合法）的资产；若清单校验失败则绝不生效。
      const trusted = manifest ? verified : true;
      if (!trusted) continue;

      if (name === 'model-compat.json') {
        try {
          const parsed = modelCompatSchema.safeParse(JSON.parse(data.toString('utf8')));
          if (parsed.success) {
            for (const url of parsed.data.disableReasoningEffortUrls) this.disabledUrls.add(url);
          }
        } catch { /* 忽略畸形可选资产 */ }
      } else if (name === 'reply-prompt-addon.md') {
        const text = data.toString('utf8').trim();
        if (text && !/[\p{Cc}\p{Cf}]/u.test(text.replace(/\r?\n/g, ''))) {
          this.promptAddon = text.slice(0, 500);
        }
      }
    }

    this.current = {
      loadedCount: items.length,
      ...(manifest?.version && { version: manifest.version }),
      lastReloadAt: now,
      items,
    };
    return this.status();
  }

  /** 清理已下发的热更新资产，恢复内置默认状态。 */
  reset(): HotBundlesStatus {
    if (existsSync(this.dir) || this.isLink(this.dir)) {
      const st = lstatSync(this.dir);
      if (st.isSymbolicLink()) unlinkSync(this.dir);
      else rmSync(this.dir, { recursive: true, force: true });
    }
    return this.reload();
  }

  /** 从官方远端拉取已签名清单与资产；任何一步校验失败都不会改动本地既有资产。 */
  syncFromRemote(manifestUrl: string, signal?: AbortSignal): Promise<HotBundlesStatus> {
    if (this.syncing) return Promise.reject(new BridgeError('busy'));
    const task = this.runSync(manifestUrl, signal);
    this.syncing = task;
    return task.finally(() => { if (this.syncing === task) this.syncing = undefined; });
  }

  private isLink(path: string) {
    try { return lstatSync(path).isSymbolicLink(); } catch { return false; }
  }

  private checkRemoteUrl(raw: string, origin?: string) {
    let url: URL;
    try { url = new URL(raw); } catch { throw new BridgeError('invalid-endpoint'); }
    const local = this.allowLocalHttp && url.protocol === 'http:' && url.hostname === '127.0.0.1';
    if ((url.protocol !== 'https:' && !local) || url.username || url.password || url.hash) {
      throw new BridgeError('invalid-endpoint');
    }
    if (origin !== undefined && url.origin !== origin) throw new BridgeError('invalid-endpoint');
    return url;
  }

  private async download(url: URL, limit: number, signal: AbortSignal) {
    let current = url;
    let response: Response | undefined;
    for (let hop = 0; hop <= MAX_GITHUB_REDIRECTS; hop++) {
      try {
        response = await fetch(current, {
          method: 'GET', redirect: 'manual', credentials: 'omit', signal,
          headers: { Accept: 'application/json, text/markdown, application/octet-stream' },
          ...(current.hostname === '127.0.0.1' && { proxy: '' }),
        } as RequestInit);
      } catch (error) {
        if (error instanceof BridgeError) throw error;
        throw new BridgeError(signal.aborted ? 'stopped' : 'invalid-endpoint');
      }
      if (response.status >= 300 && response.status < 400) {
        const location = response.headers.get('location');
        await response.body?.cancel().catch(() => {});
        if (!location || hop === MAX_GITHUB_REDIRECTS) throw new BridgeError('invalid-endpoint');
        let next: URL;
        try { next = new URL(location, current); } catch { throw new BridgeError('invalid-endpoint'); }
        if (!isAllowedGitHubReleaseRedirect(current, next)) throw new BridgeError('invalid-endpoint');
        current = next;
        continue;
      }
      break;
    }
    if (!response || response.status < 200 || response.status >= 300) {
      await response?.body?.cancel().catch(() => {});
      throw new BridgeError('invalid-endpoint');
    }
    try { return await readLimited(response, limit); }
    catch (error) {
      if (error instanceof BridgeError) throw error;
      throw new BridgeError(signal.aborted ? 'stopped' : 'invalid-endpoint');
    }
  }

  private async runSync(manifestUrl: string, parent?: AbortSignal): Promise<HotBundlesStatus> {
    const base = this.checkRemoteUrl(manifestUrl);
    const signal = parent ? AbortSignal.any([parent, AbortSignal.timeout(REMOTE_TIMEOUT_MS)]) : AbortSignal.timeout(REMOTE_TIMEOUT_MS);

    const manifestBytes = await this.download(base, MAX_MANIFEST_BYTES, signal);
    let parsedJson: unknown;
    try { parsedJson = JSON.parse(manifestBytes.toString('utf8')); } catch { throw new BridgeError('invalid-configuration'); }
    const checked = manifestSchema.safeParse(parsedJson);
    if (!checked.success) throw new BridgeError('invalid-configuration');
    const manifest = checked.data;
    // 远程清单必须由内置官方公钥签名，绝不信任清单自带的公钥。
    if (!manifest.signature || !verifySignature(manifest, this.pinnedKey)) throw new BridgeError('invalid-configuration');

    const names = Object.keys(manifest.files).sort((a, b) => a.localeCompare(b));
    if (names.length > 32) throw new BridgeError('invalid-configuration');
    for (const name of names) {
      if (name === 'manifest.json' || !SAFE_NAME.test(name) || !ALLOWED_EXT.test(name)) throw new BridgeError('invalid-configuration');
    }
    for (const name of Object.keys(manifest.assetUrls ?? {})) {
      if (!Object.hasOwn(manifest.files, name)) throw new BridgeError('invalid-configuration');
    }

    const assets = new Map<string, Buffer>();
    for (const name of names) {
      const explicit = manifest.assetUrls?.[name];
      let target: string;
      try { target = explicit !== undefined ? new URL(explicit, base).href : new URL(name, base).href; }
      catch { throw new BridgeError('invalid-endpoint'); }
      const url = this.checkRemoteUrl(target, base.origin);
      const data = await this.download(url, MAX_BUNDLE_BYTES, signal);
      if (sha256Hex(data) !== manifest.files[name]!.toLowerCase()) throw new BridgeError('invalid-configuration');
      assets.set(name, data);
    }
    signal.throwIfAborted?.();

    // 全部校验通过后，先写入暂存目录，再整体替换 bundles/，避免出现半新半旧的资产。
    ensurePrivateDir(this.stateDir);
    const staging = resolveContainedPath(this.stateDir, `.bundles-staging-${randomUUID()}`);
    const backup = resolveContainedPath(this.stateDir, `.bundles-previous-${randomUUID()}`);
    let swapped = false;
    try {
      ensurePrivateDir(staging);
      for (const [name, data] of assets) atomicWritePrivateFile(resolveContainedPath(staging, name), data);
      const stored: Manifest = {
        ...(manifest.version !== undefined && { version: manifest.version }),
        files: manifest.files, signature: manifest.signature,
      };
      atomicWritePrivateFile(resolveContainedPath(staging, 'manifest.json'), JSON.stringify(stored, null, 2) + '\n');
      const hadPrevious = existsSync(this.dir) || this.isLink(this.dir);
      if (hadPrevious) {
        if (this.isLink(this.dir) || !lstatSync(this.dir).isDirectory()) throw new BridgeError('storage-unavailable');
        renameSync(this.dir, backup);
      }
      try {
        renameSync(staging, this.dir);
        swapped = true;
      } catch {
        if (hadPrevious) renameSync(backup, this.dir);
        throw new BridgeError('storage-unavailable');
      }
      try {
        const status = this.reload();
        rmSync(backup, { recursive: true, force: true });
        return status;
      } catch (error) {
        rmSync(this.dir, { recursive: true, force: true });
        if (hadPrevious) renameSync(backup, this.dir);
        this.reload();
        throw error;
      }
    } finally {
      if (!swapped) rmSync(staging, { recursive: true, force: true });
    }
  }
}
