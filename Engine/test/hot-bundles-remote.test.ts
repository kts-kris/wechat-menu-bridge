import { expect, test } from 'bun:test';
import { createHash, generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { rpcReplySchema, rpcSchemas } from '../src/contracts/ipc.ts';
import { V3EngineApp } from '../src/ipc/v3-app.ts';
import { HotBundleManager, isAllowedGitHubReleaseRedirect, OFFICIAL_BUNDLE_PUBLIC_KEY } from '../src/storage/hot-bundles.ts';

type Route = { status?: number; body?: string | Buffer; headers?: Record<string, string> };

const sha = (data: string | Buffer) => createHash('sha256').update(data).digest('hex');
const rawPublicKey = (key: KeyObject) => key.export({ format: 'der', type: 'spki' }).subarray(12).toString('base64');
const official = generateKeyPairSync('ed25519');
const attacker = generateKeyPairSync('ed25519');
const compat = JSON.stringify({ disableReasoningEffortUrls: ['https://compat.example.invalid/v1/chat/completions'] });
const addon = '回复保持简短自然。';

function signedManifest(files: Record<string, string>, privateKey: KeyObject, extra: Record<string, unknown> = {}, version = '2026.11.24') {
  const sorted = Object.fromEntries(Object.entries(files).sort(([a], [b]) => a.localeCompare(b)));
  const signature = sign(null, Buffer.from(JSON.stringify({ version, files: sorted }), 'utf8'), privateKey).toString('base64');
  return JSON.stringify({ version, files, signature, ...extra });
}

async function remote() {
  const routes = new Map<string, Route>();
  const hits: string[] = [];
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch(req) {
    const { pathname } = new URL(req.url);
    hits.push(pathname);
    if (req.headers.get('cookie') || req.headers.get('authorization')) return new Response('credentials leaked', { status: 400 });
    const route = routes.get(pathname);
    if (!route) return new Response('missing', { status: 404 });
    return new Response(typeof route.body === 'string' || route.body === undefined ? route.body ?? '' : new Uint8Array(route.body), { status: route.status ?? 200, headers: route.headers });
  } });
  const base = `http://127.0.0.1:${server.port}`;
  const publish = (manifest: string, assets: Record<string, string | Buffer> = { 'model-compat.json': compat, 'reply-prompt-addon.md': addon }) => {
    routes.set('/bundles/manifest.json', { body: manifest, headers: { 'Content-Type': 'application/json' } });
    for (const [name, body] of Object.entries(assets)) routes.set(`/bundles/${name}`, { body });
  };
  return { routes, hits, base, publish, manifestUrl: `${base}/bundles/manifest.json`, stop: () => server.stop(true) };
}

function setup(options: { allowLocalHttp?: boolean } = {}) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'wmb-bundles-')));
  const manager = new HotBundleManager(dir, { pinnedPublicKeyBase64: rawPublicKey(official.publicKey), allowLocalHttp: options.allowLocalHttp ?? true });
  return { dir, manager, close: () => rmSync(dir, { recursive: true, force: true }) };
}

const goodFiles = () => ({ 'model-compat.json': sha(compat), 'reply-prompt-addon.md': sha(addon) });
const snapshot = (dir: string) => {
  const bundles = join(dir, 'bundles');
  if (!existsSync(bundles)) return {};
  return Object.fromEntries(readdirSync(bundles).sort().map(name => [name, readFileSync(join(bundles, name), 'utf8')]));
};

test('v2.2 #5 内置官方公钥为 32 字节 Ed25519 原始公钥，默认构造可用', () => {
  expect(Buffer.from(OFFICIAL_BUNDLE_PUBLIC_KEY, 'base64')).toHaveLength(32);
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'wmb-bundles-')));
  try { expect(new HotBundleManager(dir).status().loadedCount).toBe(0); }
  finally { rmSync(dir, { recursive: true, force: true }); }
});

test('v2.2 #5 syncFromRemote 固定公钥验签通过后原子写入 0600 资产并零重启生效', async () => {
  const net = await remote();
  const t = setup();
  try {
    net.publish(signedManifest(goodFiles(), official.privateKey));
    const status = await t.manager.syncFromRemote(net.manifestUrl);
    expect(status).toMatchObject({ loadedCount: 2, version: '2026.11.24' });
    expect(status.items.every(item => item.verified)).toBe(true);
    expect(t.manager.disabledReasoningEffortUrls()).toEqual(['https://compat.example.invalid/v1/chat/completions']);
    expect(t.manager.replyPromptAddon()).toBe(addon);
    const bundles = join(t.dir, 'bundles');
    expect(statSync(bundles).mode & 0o777).toBe(0o700);
    for (const name of readdirSync(bundles)) expect(statSync(join(bundles, name)).mode & 0o777).toBe(0o600);
    expect(readdirSync(bundles).sort()).toEqual(['manifest.json', 'model-compat.json', 'reply-prompt-addon.md']);
    // 暂存/备份目录已清理。
    expect(readdirSync(t.dir).filter(name => name.startsWith('.bundles-'))).toEqual([]);
    // 重新加载（模拟重启）依旧由内置公钥验证通过。
    expect(new HotBundleManager(t.dir, { pinnedPublicKeyBase64: rawPublicKey(official.publicKey) }).status().items.every(i => i.verified)).toBe(true);

    // assetUrls 指向同源其他路径同样支持。
    net.routes.set('/cdn/addon-v2.md', { body: '第二版提示。' });
    net.publish(signedManifest({ 'reply-prompt-addon.md': sha('第二版提示。') }, official.privateKey,
      { assetUrls: { 'reply-prompt-addon.md': '/cdn/addon-v2.md' } }, '2026.11.25'), {});
    const next = await t.manager.syncFromRemote(net.manifestUrl);
    expect(next).toMatchObject({ loadedCount: 1, version: '2026.11.25' });
    expect(t.manager.replyPromptAddon()).toBe('第二版提示。');
    expect(t.manager.disabledReasoningEffortUrls()).toEqual([]);
  } finally { net.stop(); t.close(); }
});

test('v2.2 #5 篡改 SHA-256、伪造签名、缺签名、自带攻击者公钥均被拒绝且不破坏旧资产', async () => {
  const net = await remote();
  const t = setup();
  try {
    net.publish(signedManifest(goodFiles(), official.privateKey));
    await t.manager.syncFromRemote(net.manifestUrl);
    const before = snapshot(t.dir);
    const statusBefore = t.manager.status();

    const attempts: [string, () => void][] = [
      ['篡改资产内容', () => net.publish(signedManifest(goodFiles(), official.privateKey),
        { 'model-compat.json': compat, 'reply-prompt-addon.md': '被篡改的提示词' })],
      ['攻击者签名', () => net.publish(signedManifest(goodFiles(), attacker.privateKey))],
      ['清单自带攻击者公钥', () => net.publish(signedManifest(goodFiles(), attacker.privateKey,
        { publicKeyPem: attacker.publicKey.export({ type: 'spki', format: 'pem' }).toString() }))],
      ['缺少签名', () => net.publish(JSON.stringify({ version: 'x', files: goodFiles() }))],
      ['签名后改写清单', () => net.publish(signedManifest(goodFiles(), official.privateKey).replace('2026.11.24', '2099.01.01'))],
      ['非法文件名', () => net.publish(signedManifest({ '../escape.md': sha(addon) }, official.privateKey))],
      ['畸形 JSON', () => net.publish('{not json')],
    ];
    for (const [label, arrange] of attempts) {
      arrange();
      const failure = await t.manager.syncFromRemote(net.manifestUrl).then(() => `${label} 未被拒绝`, error => String(error));
      expect(failure).toContain('invalid-configuration');
      expect(snapshot(t.dir)).toEqual(before);
      expect(t.manager.status().items).toEqual(statusBefore.items);
      expect(t.manager.replyPromptAddon()).toBe(addon);
    }
    expect(readdirSync(t.dir).filter(name => name.startsWith('.bundles-'))).toEqual([]);
  } finally { net.stop(); t.close(); }
});

test('v2.2 #5 HTTP 降级、跳转、跨域资产与超限清单均被拒绝且不发送凭据', async () => {
  const net = await remote();
  const t = setup();
  const strict = setup({ allowLocalHttp: false });
  try {
    net.publish(signedManifest(goodFiles(), official.privateKey));
    await t.manager.syncFromRemote(net.manifestUrl);
    const before = snapshot(t.dir);

    // 未注入测试开关时，任何 http 源（含回环）都被拒绝；外部 http 源永远拒绝。
    await expect(strict.manager.syncFromRemote(net.manifestUrl)).rejects.toThrow('invalid-endpoint');
    await expect(t.manager.syncFromRemote('http://example.com/manifest.json')).rejects.toThrow('invalid-endpoint');
    await expect(t.manager.syncFromRemote('https://user:pass@example.com/manifest.json')).rejects.toThrow('invalid-endpoint');

    // 清单跳转。
    net.routes.set('/moved/manifest.json', { status: 302, headers: { Location: '/bundles/manifest.json' } });
    await expect(t.manager.syncFromRemote(`${net.base}/moved/manifest.json`)).rejects.toThrow('invalid-endpoint');

    // 资产跳转。
    net.routes.set('/bundles/reply-prompt-addon.md', { status: 307, headers: { Location: '/elsewhere.md' } });
    await expect(t.manager.syncFromRemote(net.manifestUrl)).rejects.toThrow('invalid-endpoint');
    expect(net.hits).not.toContain('/elsewhere.md');

    // 跨域资产地址。
    net.publish(signedManifest(goodFiles(), official.privateKey,
      { assetUrls: { 'reply-prompt-addon.md': 'https://evil.example.com/addon.md' } }));
    await expect(t.manager.syncFromRemote(net.manifestUrl)).rejects.toThrow('invalid-endpoint');

    // 超过 64 KiB 的清单与超过 256 KiB 的资产。
    net.routes.set('/big/manifest.json', { body: 'x'.repeat(64 * 1024 + 1) });
    await expect(t.manager.syncFromRemote(`${net.base}/big/manifest.json`)).rejects.toThrow('invalid-configuration');
    const huge = Buffer.alloc(256 * 1024 + 1, 0x61);
    net.publish(signedManifest({ 'reply-prompt-addon.md': sha(huge) }, official.privateKey), { 'reply-prompt-addon.md': huge });
    await expect(t.manager.syncFromRemote(net.manifestUrl)).rejects.toThrow('invalid-configuration');

    // 远端 404。
    await expect(t.manager.syncFromRemote(`${net.base}/nope/manifest.json`)).rejects.toThrow('invalid-endpoint');
    expect(snapshot(t.dir)).toEqual(before);
    expect(t.manager.replyPromptAddon()).toBe(addon);
  } finally { net.stop(); t.close(); strict.close(); }
});

test('v2.2 #5 reset 清理已下发资产并恢复内置默认状态', async () => {
  const net = await remote();
  const t = setup();
  try {
    net.publish(signedManifest(goodFiles(), official.privateKey));
    await t.manager.syncFromRemote(net.manifestUrl);
    expect(t.manager.status().loadedCount).toBe(2);
    const status = t.manager.reset();
    expect(status.loadedCount).toBe(0);
    expect(status.items).toEqual([]);
    expect(status.version).toBeUndefined();
    expect(existsSync(join(t.dir, 'bundles'))).toBe(false);
    expect(t.manager.disabledReasoningEffortUrls()).toEqual([]);
    expect(t.manager.replyPromptAddon()).toBe('');
    expect(t.manager.reset().loadedCount).toBe(0);
  } finally { net.stop(); t.close(); }
});

test('v2.2 #5 system.bundles IPC 支持 sync/reset，manifestUrl 只接受 HTTPS', async () => {
  const net = await remote();
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'wmb-bundles-ipc-')));
  const frames: unknown[] = [];
  const app = new V3EngineApp(dir, line => frames.push(JSON.parse(line)),
    { pinnedPublicKeyBase64: rawPublicKey(official.publicKey), allowLocalHttp: true });
  try {
    const params = rpcSchemas['system.bundles'].params;
    expect(params.safeParse({ action: 'sync' }).success).toBe(true);
    expect(params.safeParse({ action: 'sync', manifestUrl: 'https://example.com/m.json' }).success).toBe(true);
    expect(params.safeParse({ action: 'sync', manifestUrl: 'http://example.com/m.json' }).success).toBe(false);
    expect(params.safeParse({ action: 'reset', extra: true }).success).toBe(false);

    // 以本地服务模拟远端后写入资产，再通过 IPC reset 清理。
    net.publish(signedManifest(goodFiles(), official.privateKey));
    const bundles = (app as unknown as { bundles: HotBundleManager }).bundles;
    await bundles.syncFromRemote(net.manifestUrl);
    expect(app.orchestrator.modelRouter).toBeDefined();
    await app.route(JSON.stringify({ v: 3, id: 7, method: 'system.bundles', params: { action: 'status' } }));
    const loaded = () => {
      const reply = rpcReplySchema('system.bundles').parse(frames.at(-1));
      return reply.ok ? rpcSchemas['system.bundles'].result.parse(reply.result).loadedCount : undefined;
    };
    expect(loaded()).toBe(2);
    await app.route(JSON.stringify({ v: 3, id: 8, method: 'system.bundles', params: { action: 'reset' } }));
    expect(loaded()).toBe(0);

    // HTTPS 地址但无法连通：返回结构化错误而非崩溃。
    await app.route(JSON.stringify({ v: 3, id: 9, method: 'system.bundles',
      params: { action: 'sync', manifestUrl: 'https://127.0.0.1:1/manifest.json' } }));
    const reply = rpcReplySchema('system.bundles').parse(frames.at(-1));
    expect(reply.ok).toBe(false);
    if (!reply.ok) expect(reply.code).toBe('invalid-endpoint');
  } finally {
    await app.close();
    net.stop();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('v2.2 #5 仅放行官方 GitHub Releases 到资产 CDN 的 HTTPS 跳转，拒绝其他任意跳转', () => {
  const latest = new URL('https://github.com/kts-kris/wechat-menu-bridge/releases/latest/download/bundles-manifest.json');
  const tagged = new URL('https://github.com/kts-kris/wechat-menu-bridge/releases/download/v2.2.0/bundles-manifest.json');
  const cdn = new URL('https://objects.githubusercontent.com/github-production-release-asset-123/manifest.json');
  const releaseCdn = new URL('https://release-assets.githubusercontent.com/github-production-release-asset-123/manifest.json');

  expect(isAllowedGitHubReleaseRedirect(latest, tagged)).toBe(true);
  expect(isAllowedGitHubReleaseRedirect(tagged, cdn)).toBe(true);
  expect(isAllowedGitHubReleaseRedirect(tagged, releaseCdn)).toBe(true);
  expect(isAllowedGitHubReleaseRedirect(cdn, releaseCdn)).toBe(true);

  // 拒绝 HTTP 降级、跨仓库跳转、任意第三方站点与带凭据地址。
  expect(isAllowedGitHubReleaseRedirect(latest, new URL('http://objects.githubusercontent.com/x'))).toBe(false);
  expect(isAllowedGitHubReleaseRedirect(latest, new URL('https://github.com/other/repo/releases/download/v1/m.json'))).toBe(false);
  expect(isAllowedGitHubReleaseRedirect(latest, new URL('https://evil.example.com/m.json'))).toBe(false);
  expect(isAllowedGitHubReleaseRedirect(latest, new URL('https://user:pass@objects.githubusercontent.com/x'))).toBe(false);
  expect(isAllowedGitHubReleaseRedirect(new URL('https://example.com/manifest.json'), cdn)).toBe(false);
});
