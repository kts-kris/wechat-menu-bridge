import { createHash, createPublicKey, verify } from 'node:crypto';
import { existsSync, lstatSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { z } from 'zod';
import { BridgeError } from '../contracts/errors.ts';
import type { RpcResult } from '../contracts/ipc.ts';
import { readPrivateFile, resolveContainedPath } from './fs-safe.ts';

const MAX_BUNDLE_BYTES = 256 * 1024;
const ALLOWED_EXT = /\.(?:json|md)$/i;

const manifestSchema = z.strictObject({
  version: z.string().trim().min(1).max(64).optional(),
  files: z.record(z.string().min(1).max(128), z.string().regex(/^[0-9a-f]{64}$/i)),
  signature: z.string().min(1).max(512).optional(),
  publicKeyPem: z.string().min(1).max(2048).optional(),
});

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

export class HotBundleManager {
  private readonly dir: string;
  private current: HotBundlesStatus = { loadedCount: 0, items: [] };
  private disabledUrls = new Set<string>();
  private promptAddon = '';

  constructor(stateDir: string) {
    this.dir = join(stateDir, 'bundles');
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
        if (!manifest.signature || !manifest.publicKeyPem) {
          signatureValid = false;
        } else {
          try {
            const payload = Buffer.from(canonicalManifestPayload(manifest.version, manifest.files), 'utf8');
            const key = createPublicKey(manifest.publicKeyPem);
            signatureValid = verify(null, payload, key, Buffer.from(manifest.signature, 'base64'));
          } catch {
            signatureValid = false;
          }
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
}
