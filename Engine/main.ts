import { z } from 'zod';
import { Bridge } from './engine.ts';
import { BridgeError, activeSchema, armSchema, checked, id, modelSchema, object, targetSchema } from './contracts.ts';
import { Xiaohe } from './mcp.ts';
import { ReplyModel } from './model.ts';
import { classifyText, sendable } from './policy.ts';
import { IPC_VERSION, MAX_FRAME_BYTES } from './src/contracts/ipc.ts';
import { V3EngineApp } from './src/ipc/v3-app.ts';
import { runPluginWorkerCli } from './src/plugins/worker-host.ts';

const errorCode = (e: unknown) => e instanceof BridgeError ? e.code : 'internal-error';

async function runLegacyV2(stateDir: string) {
  const VERSION = 2;
  const FRAME = 32_768;
  const mcpArgs = z.strictObject({ mcp: z.string().min(1).max(512) });
  const contactArgs = mcpArgs.extend({ account: z.string().refine(id), query: z.string().trim().min(1).max(100) });
  const receiptArgs = z.strictObject({ target: targetSchema, confirmed: z.literal(true) });
  const previewArgs = z.strictObject({ model: modelSchema, text: z.string().trim().min(1).max(400) });
  const pauseArgs = z.strictObject({ reason: z.enum(['user-paused', 'system-sleep', 'settings-changed']).optional() });

  let closing = false;
  let engine: Bridge;
  const pending = new Set<Promise<void>>();
  let preview: AbortController | undefined;

  function emit(data: unknown) {
    if (closing) return;
    const line = JSON.stringify(data) + '\n';
    if (Buffer.byteLength(line) > FRAME || process.stdout.writableLength > FRAME * 4) { void shutdown(1); return; }
    process.stdout.write(line);
  }

  async function withXiaohe<T>(url: string, run: (c: Xiaohe) => Promise<T>) {
    const client = new Xiaohe(url);
    try { return await run(client); } finally { void client.close(); }
  }

  async function command(method: string, input: unknown) {
    switch (method) {
      case 'status': return engine.status();
      case 'pause': preview?.abort(); engine.pause(checked(pauseArgs, input).reason); return true;
      case 'inspect': engine.inspect(input); return true;
      case 'arm': if (preview) throw new BridgeError('busy'); await engine.arm(checked(armSchema, input)); return true;
      case 'active': if (preview) throw new BridgeError('busy'); await engine.active(checked(activeSchema, input)); return true;
      case 'refresh': await engine.refresh(input); return true;
      case 'reset-read': engine.resetRead(checked(receiptArgs, input).target); return true;
      case 'restore-consent': engine.restoreConsent(checked(receiptArgs, input).target); return true;
      case 'acknowledge': engine.acknowledge(checked(receiptArgs, input).target); return true;
      case 'accounts': {
        const { mcp } = checked(mcpArgs, input);
        return withXiaohe(mcp, async c => (await c.accounts()).map(({ binding, ...v }) => v));
      }
      case 'contacts': {
        const { mcp, account, query } = checked(contactArgs, input);
        return withXiaohe(mcp, async c => c.contacts((await c.identify(account, undefined, false)).binding, query));
      }
      case 'preview': {
        const { model, text } = checked(previewArgs, input);
        const { running, inFlight } = engine.status();
        if (preview || running || inFlight) throw new BridgeError('busy');
        const controller = preview = new AbortController();
        try {
          const m = await ReplyModel.load(model);
          const rule = classifyText(text);
          const d = rule ? { action: rule } as const : await m.generate([text], [], controller.signal);
          controller.signal.throwIfAborted();
          try { return { action: d.action, text: sendable(d) }; } catch { return { action: 'manual' }; }
        } catch (e) { if (controller.signal.aborted) throw new BridgeError('stopped'); throw e; }
        finally { preview = undefined; }
      }
      default: throw new BridgeError('invalid-command');
    }
  }

  function frame(content: Uint8Array) {
    let r: Record<string, unknown> | undefined;
    try { r = object(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(content))); } catch { /* malformed frame */ }
    const reqId = r?.id;
    const method = r?.method;
    if (!Number.isSafeInteger(reqId) || typeof method !== 'string' || r?.v !== VERSION) {
      emit({ kind: 'error', code: 'invalid-frame' }); return;
    }
    if (pending.size >= 12 && method !== 'pause') { emit({ kind: 'reply', id: reqId, ok: false, code: 'busy' }); return; }
    const p = command(method, r?.params ?? {}).then(
      result => emit({ kind: 'reply', id: reqId, ok: true, result }),
      e => emit({ kind: 'reply', id: reqId, ok: false, code: errorCode(e) }),
    ).finally(() => pending.delete(p));
    pending.add(p);
  }

  async function shutdown(exit: number) {
    if (closing) return;
    closing = true;
    preview?.abort();
    const hard = setTimeout(() => process.exit(exit || 1), 5200);
    try { await engine?.close(); }
    finally { clearTimeout(hard); process.exit(exit); }
  }

  process.stdout.on('error', () => void shutdown(1));
  try {
    engine = new Bridge(stateDir, status => emit({ kind: 'state', status }));
    emit({ kind: 'hello', v: VERSION, status: engine.status() });
  } catch (e) {
    emit({ kind: 'fatal', code: errorCode(e) });
    process.exitCode = 1;
    return;
  }

  let line = Buffer.alloc(0);
  let dropping = false;
  process.stdin.on('data', (chunk: Buffer) => {
    for (let start = 0; start < chunk.length && !closing;) {
      const end = chunk.indexOf(10, start);
      const part = chunk.subarray(start, end < 0 ? undefined : end);
      if (!dropping) {
        if (part.length + line.length > FRAME) {
          line = Buffer.alloc(0); dropping = true;
          engine.pause();
          emit({ kind: 'error', code: 'invalid-frame' });
        } else line = Buffer.concat([line, part]);
      }
      if (end < 0) break;
      if (!dropping && line.length) frame(line);
      line = Buffer.alloc(0); dropping = false;
      start = end + 1;
    }
  });
  process.stdin.once('end', () => void shutdown(0));
  process.stdin.once('error', () => void shutdown(1));
  process.on('SIGTERM', () => void shutdown(0));
  process.on('SIGINT', () => void shutdown(0));
  process.on('unhandledRejection', () => void shutdown(1));
  process.on('uncaughtException', () => void shutdown(1));
}

async function runV3(stateDir: string) {
  let closing = false;
  let app: V3EngineApp | undefined;

  function writeLine(line: string) {
    if (closing) return;
    if (Buffer.byteLength(line) > MAX_FRAME_BYTES + 1 || process.stdout.writableLength > MAX_FRAME_BYTES * 8) {
      void shutdown(1);
      return;
    }
    process.stdout.write(line);
  }

  async function shutdown(exit: number) {
    if (closing) return;
    closing = true;
    const hard = setTimeout(() => process.exit(exit || 1), 5200);
    try { await app?.close(); }
    finally { clearTimeout(hard); process.exit(exit); }
  }

  process.stdout.on('error', () => void shutdown(1));
  try {
    app = new V3EngineApp(stateDir, writeLine);
    app.hello();
  } catch (e) {
    process.stdout.write(JSON.stringify({ v: IPC_VERSION, kind: 'fatal', code: errorCode(e) }) + '\n');
    process.exitCode = 1;
    return;
  }

  let line = Buffer.alloc(0);
  let dropping = false;
  process.stdin.on('data', (chunk: Buffer) => {
    for (let start = 0; start < chunk.length && !closing;) {
      const end = chunk.indexOf(10, start);
      const part = chunk.subarray(start, end < 0 ? undefined : end);
      if (!dropping) {
        if (part.length + line.length > MAX_FRAME_BYTES) {
          line = Buffer.alloc(0); dropping = true;
          app?.orchestrator.pauseAll('all', 'invalid-frame');
          writeLine(JSON.stringify({ v: IPC_VERSION, kind: 'error', code: 'invalid-frame' }) + '\n');
        } else line = Buffer.concat([line, part]);
      }
      if (end < 0) break;
      if (!dropping && line.length) void app?.route(line);
      line = Buffer.alloc(0); dropping = false;
      start = end + 1;
    }
  });
  process.stdin.once('end', () => void shutdown(0));
  process.stdin.once('error', () => void shutdown(1));
  process.on('SIGTERM', () => void shutdown(0));
  process.on('SIGINT', () => void shutdown(0));
  process.on('unhandledRejection', () => void shutdown(1));
  process.on('uncaughtException', () => void shutdown(1));
}

// 1. 最先检查是否为受控插件沙箱子进程，避免触碰主引擎 SQLite 独占锁。
if (await runPluginWorkerCli(process.argv.slice(2))) {
  process.exit(0);
}

process.umask(0o077);
const args = process.argv.slice(2);
const legacy = args.includes('--legacy-v2');
const filtered = args.filter(arg => arg !== '--legacy-v2');
if (filtered.length !== 2 || filtered[0] !== '--state-dir' || !filtered[1]) {
  process.stdout.write(JSON.stringify({ ...(legacy ? {} : { v: IPC_VERSION }), kind: 'fatal', code: 'invalid-command' }) + '\n');
  process.exitCode = 1;
} else if (legacy) {
  await runLegacyV2(filtered[1]);
} else {
  await runV3(filtered[1]);
}
