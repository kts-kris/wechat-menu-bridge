import { expect, test } from 'bun:test';
import { generateKeyPairSync } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { HotBundleManager } from '../src/storage/hot-bundles.ts';

const REPO_ROOT = resolve(import.meta.dir, '../..');
const BUNDLES_SCRIPT = join(REPO_ROOT, 'scripts/release-bundles.sh');
const FEED_SCRIPT = join(REPO_ROOT, 'scripts/release-feed.sh');

function makeFixture() {
  const dir = mkdtempSync(join(tmpdir(), 'wmb-release-bundles-test-'));
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const keyPath = join(dir, 'test-ed25519.pem');
  writeFileSync(keyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(), { mode: 0o600 });
  const rawPub = (publicKey.export({ type: 'spki', format: 'der' }) as Buffer).subarray(-32).toString('base64');
  return {
    dir,
    keyPath,
    rawPub,
    cleanup() {
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

function runScript(script: string, args: string[]) {
  const proc = Bun.spawnSync(['bash', script, ...args], {
    cwd: REPO_ROOT,
    stdout: 'pipe',
    stderr: 'pipe',
  });
  return {
    exitCode: proc.exitCode,
    stdout: new TextDecoder().decode(proc.stdout),
    stderr: new TextDecoder().decode(proc.stderr),
  };
}

test('release-bundles.sh 签发默认空 model-compat.json 与自定义公开资产并通过 HotBundleManager 验签', () => {
  const fx = makeFixture();
  try {
    // 1. 默认空 model-compat.json
    const outDefault = join(fx.dir, 'out-default');
    const r1 = runScript(BUNDLES_SCRIPT, [
      '--version', '2.3.0',
      '--ed25519-key', fx.keyPath,
      '--out-dir', outDefault,
      '--allow-custom-key',
    ]);
    expect(r1.exitCode).toBe(0);
    expect(readdirSync(outDefault).sort()).toEqual(['bundles-manifest.json', 'model-compat.json']);
    const meta1 = JSON.parse(r1.stdout.trim());
    expect(meta1).toMatchObject({ ok: true, version: '2.3.0', verified: true, publicKey: fx.rawPub });

    // 2. 自定义公开 HTTPS 端点 + reply-prompt-addon.md
    const compatPath = join(fx.dir, 'compat.json');
    const addonPath = join(fx.dir, 'addon.md');
    writeFileSync(compatPath, JSON.stringify({
      disableReasoningEffortUrls: ['https://api.example.com/v1/chat/completions'],
    }, null, 2));
    writeFileSync(addonPath, '保持简洁自然口吻，避免机械感。\n');
    const outCustom = join(fx.dir, 'out-custom');
    const r2 = runScript(BUNDLES_SCRIPT, [
      '--version', '2.3.1',
      '--ed25519-key', fx.keyPath,
      '--out-dir', outCustom,
      '--compat', compatPath,
      '--addon', addonPath,
      '--allow-custom-key',
    ]);
    expect(r2.exitCode).toBe(0);
    expect(readdirSync(outCustom).sort()).toEqual([
      'bundles-manifest.json',
      'model-compat.json',
      'reply-prompt-addon.md',
    ]);

    // 用真实 HotBundleManager 加载确认内容与验签完全一致
    const stateDir = join(fx.dir, 'state');
    const bundlesDir = join(stateDir, 'bundles');
    mkdirSync(bundlesDir, { mode: 0o700, recursive: true });
    writeFileSync(join(bundlesDir, 'manifest.json'), readFileSync(join(outCustom, 'bundles-manifest.json')), { mode: 0o600 });
    writeFileSync(join(bundlesDir, 'model-compat.json'), readFileSync(join(outCustom, 'model-compat.json')), { mode: 0o600 });
    writeFileSync(join(bundlesDir, 'reply-prompt-addon.md'), readFileSync(join(outCustom, 'reply-prompt-addon.md')), { mode: 0o600 });

    const mgr = new HotBundleManager(stateDir, { pinnedPublicKeyBase64: fx.rawPub });
    expect(mgr.status().loadedCount).toBe(2);
    expect(mgr.status().items.every(i => i.verified)).toBe(true);
    expect(mgr.disabledReasoningEffortUrls()).toEqual(['https://api.example.com/v1/chat/completions']);
    expect(mgr.replyPromptAddon()).toBe('保持简洁自然口吻，避免机械感。');
  } finally {
    fx.cleanup();
  }
});

test('release-bundles.sh 防泄露扫描拦截非 HTTPS、内网/本地地址、带 query/userinfo URL 与文本凭据且零写入', () => {
  const fx = makeFixture();
  try {
    const badUrls = [
      'http://api.example.com/v1/chat/completions',
      'https://127.0.0.1:8080/v1/chat/completions',
      'https://localhost/v1/chat/completions',
      'https://192.168.1.10/v1/chat/completions',
      'https://10.0.0.5/v1/chat/completions',
      'https://172.16.0.9/v1/chat/completions',
      'https://169.254.169.254/latest/meta-data',
      'https://relay.internal/v1/chat/completions',
      'https://proxy.local/v1/chat/completions',
      'https://api.example.com/v1/chat/completions?api_key=secret123',
      'https://user:pass@api.example.com/v1/chat/completions',
    ];
    for (const [idx, badUrl] of badUrls.entries()) {
      const compatPath = join(fx.dir, `bad-${idx}.json`);
      const outDir = join(fx.dir, `out-bad-url-${idx}`);
      writeFileSync(compatPath, JSON.stringify({ disableReasoningEffortUrls: [badUrl] }));
      const res = runScript(BUNDLES_SCRIPT, [
        '--version', '2.3.0',
        '--ed25519-key', fx.keyPath,
        '--out-dir', outDir,
        '--compat', compatPath,
        '--allow-custom-key',
      ]);
      expect(res.exitCode).not.toBe(0);
      expect(existsSync(outDir)).toBe(false);
    }

    const badAddons = [
      '不要在提示词里写 sk-testsecret123456',
      'ghp_1234567890abcdef123456',
      'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9',
      '-----BEGIN PRIVATE KEY-----\nfake',
      '参考本机文件 /Users/alice/private.md',
    ];
    for (const [idx, text] of badAddons.entries()) {
      const addonPath = join(fx.dir, `bad-addon-${idx}.md`);
      const outDir = join(fx.dir, `out-bad-addon-${idx}`);
      writeFileSync(addonPath, text);
      const res = runScript(BUNDLES_SCRIPT, [
        '--version', '2.3.0',
        '--ed25519-key', fx.keyPath,
        '--out-dir', outDir,
        '--addon', addonPath,
        '--allow-custom-key',
      ]);
      expect(res.exitCode).not.toBe(0);
      expect(existsSync(outDir)).toBe(false);
    }
  } finally {
    fx.cleanup();
  }
});

test('release-bundles.sh 默认强制核对官方公钥匹配，不匹配时拒绝签发', () => {
  const fx = makeFixture();
  try {
    const outDir = join(fx.dir, 'out-mismatch');
    const res = runScript(BUNDLES_SCRIPT, [
      '--version', '2.3.0',
      '--ed25519-key', fx.keyPath,
      '--out-dir', outDir,
    ]);
    expect(res.exitCode).not.toBe(0);
    expect(res.stderr).toContain('Signing key mismatch');
    expect(existsSync(outDir)).toBe(false);
  } finally {
    fx.cleanup();
  }
});

test('release-feed.sh --with-bundles 一键联动生成全套 4 份签名更新与热更新资产', () => {
  const fx = makeFixture();
  try {
    const fakeZip = join(fx.dir, 'WeChatMenuBridge-arm64.zip');
    writeFileSync(fakeZip, Buffer.from('PK\x03\x04dummy-zip-payload'));
    const outDir = join(fx.dir, 'out-feed');
    const res = runScript(FEED_SCRIPT, [
      '--version', '2.3.0',
      '--build', '24',
      '--zip', fakeZip,
      '--url', 'https://github.com/kts-kris/wechat-menu-bridge/releases/download/v2.3.0/WeChatMenuBridge-arm64.zip',
      '--ed25519-key', fx.keyPath,
      '--out-dir', outDir,
      '--with-bundles',
      '--allow-custom-key',
    ]);
    expect(res.exitCode).toBe(0);
    expect(readdirSync(outDir).sort()).toEqual([
      'appcast.json',
      'appcast.xml',
      'bundles-manifest.json',
      'model-compat.json',
    ]);
    const appcast = JSON.parse(readFileSync(join(outDir, 'appcast.json'), 'utf8'));
    expect(appcast.items[0].shortVersionString).toBe('2.3.0');
    expect(typeof appcast.items[0].edSignature).toBe('string');
  } finally {
    fx.cleanup();
  }
});
