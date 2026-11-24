import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import { object } from '../../contracts.ts';
import { BridgeError, isErrorCode } from '../contracts/errors.ts';
import { identifierSchema, timestampSchema } from '../contracts/events.ts';
import type { PluginHookInputs, PluginHookName, PluginPermission } from './sdk.ts';
import { MAX_WORKER_FRAME_BYTES, WORKER_FLAG, type WorkerMethod } from './worker-bootstrap.ts';

export { runPluginWorkerCli } from './worker-bootstrap.ts';

const text = z.string().min(1);
const rpc = {
  log: z.tuple([z.enum(['info', 'warn', 'error']), text.max(1000)]),
  'kv.get': z.tuple([identifierSchema]),
  'kv.set': z.tuple([identifierSchema, z.json()]),
  'llm.complete': z.tuple([z.strictObject({ presetId: identifierSchema.optional(), system: z.string(), user: z.string(), json: z.boolean().optional() })]),
  'history.fetch': z.tuple([identifierSchema, z.strictObject({ limit: z.number().int().min(1).max(500), since: timestampSchema.optional() })]),
  'emit.feed': z.tuple([z.strictObject({ title: text.max(500), body: text, conversationId: identifierSchema.optional(), notify: z.boolean().optional() })]),
  'emit.markdownFile': z.tuple([z.strictObject({ filename: text, content: z.string(), mode: z.enum(['append', 'overwrite']).optional() })]),
  'emit.wechat': z.tuple([z.strictObject({ conversationId: identifierSchema, text, dedupeKey: identifierSchema })]),
  'emit.webhook': z.tuple([z.strictObject({ url: z.url(), payload: z.json() })]),
} satisfies Record<WorkerMethod, z.ZodType>;
const permissions: Record<WorkerMethod, PluginPermission> = {
  log: 'notify', 'kv.get': 'kv_store', 'kv.set': 'kv_store', 'llm.complete': 'call_model',
  'history.fetch': 'read_history', 'emit.feed': 'notify', 'emit.markdownFile': 'write_output_file',
  'emit.wechat': 'send_wechat', 'emit.webhook': 'webhook_fetch',
};
export type PluginWorkerHandlers = {
  [M in WorkerMethod]?: (signal: AbortSignal, ...args: z.infer<(typeof rpc)[M]>) => unknown;
};

export interface PluginWorkerOptions {
  pluginId: string;
  entry: string;
  source: Uint8Array;
  approvedPermissions: readonly PluginPermission[];
  config?: Record<string, unknown>;
  handlers?: PluginWorkerHandlers;
  timeoutMs?: number;
}

type ActiveHook = {
  token: string;
  controller: AbortController;
  finish: (error?: string) => void;
  calls: number;
  historical: boolean;
};

function sandboxArgs(entry: string, config: string, pluginId: string) {
  if (process.platform !== 'darwin') throw new BridgeError('plugin-permission');
  const executable = realpathSync(process.execPath);
  const bootstrap = Bun.main.startsWith('/$bunfs/') ? undefined : fileURLToPath(new URL('./worker-bootstrap.ts', import.meta.url));
  const literal = (path: string) => `(literal ${JSON.stringify(path)})`;
  const profile = [
    '(version 1)', '(deny default)', `(allow process-exec ${literal(executable)})`,
    '(allow file-read-metadata)', '(allow sysctl-read)',
    '(allow mach-lookup (global-name "com.apple.system.logger"))',
    `(allow file-read-data (literal "/") (subpath "/System") (subpath "/usr/lib") (literal "/dev/null")
      (literal "/dev/urandom") ${[executable, entry, dirname(entry), ...(bootstrap ? [bootstrap, dirname(bootstrap)] : [])].map(literal).join(' ')})`,
  ].join('\n');
  return ['-p', profile, executable, ...(bootstrap ? [bootstrap] : []), WORKER_FLAG, entry, pluginId, config];
}

export class PluginWorkerHost {
  private readonly approved: ReadonlySet<PluginPermission>;
  private child?: ChildProcessWithoutNullStreams;
  private stage?: string;
  private active?: ActiveHook;
  private initialized = false;
  private busy = false;
  private disposed = false;

  constructor(private readonly options: PluginWorkerOptions) {
    this.approved = new Set(options.approvedPermissions);
  }

  async invoke<K extends PluginHookName>(hook: K, input?: PluginHookInputs[K], timeoutMs?: number): Promise<void> {
    if (this.disposed) throw new BridgeError('stopped');
    if (this.busy) throw new BridgeError('busy');
    if (['onMessage', 'onRecall', 'onFlush'].includes(hook) && !this.approved.has('read_events') ||
        hook === 'onManualRun' && !this.approved.has('read_history')) throw new BridgeError('permission-denied');
    const timeout = timeoutMs ?? this.options.timeoutMs ?? (hook === 'onFlush' ? 60_000 : 15_000);
    if (!Number.isSafeInteger(timeout) || timeout < 1 || timeout > 2_147_483_647) throw new BridgeError('invalid-configuration');
    const historical = hook === 'onManualRun' || hook === 'onRecall' ||
      (input as PluginHookInputs['onMessage'] | undefined)?.origin === 'backfill' ||
      !!(input as PluginHookInputs['onFlush'] | undefined)?.events?.some(event => event.origin === 'backfill');
    const deadline = performance.now() + timeout;
    this.busy = true;
    try {
      if (!this.child) this.start();
      if (!this.initialized) {
        await this.dispatch('onInit', undefined, deadline, historical);
        this.initialized = true;
      }
      if (hook !== 'onInit') await this.dispatch(hook, input, deadline, historical);
    } finally { this.busy = false; }
  }

  private start() {
    const { entry, source, config, pluginId } = this.options;
    const extension = extname(entry);
    if (!['.ts', '.js', '.mts', '.mjs', '.cjs'].includes(extension)) throw new BridgeError('invalid-configuration');
    try {
      this.stage = mkdtempSync(join(realpathSync(tmpdir()), 'wmb-plugin-'));
      const snapshot = join(this.stage, `index${extension}`);
      writeFileSync(snapshot, source, { mode: 0o600, flag: 'wx' });
      const args = sandboxArgs(snapshot, JSON.stringify(config ?? {}), pluginId);
      const child = this.child = spawn('/usr/bin/sandbox-exec', args, {
        cwd: this.stage, env: {}, stdio: 'pipe',
      });
      child.stderr.resume();
      let buffered = Buffer.alloc(0);
      child.stdout.on('data', (chunk: Buffer) => {
        if (this.child !== child) return;
        buffered = Buffer.concat([buffered, chunk]);
        let end: number;
        while ((end = buffered.indexOf(10)) >= 0) {
          if (end > MAX_WORKER_FRAME_BYTES) { this.terminate('plugin-limit'); return; }
          const line = buffered.subarray(0, end);
          buffered = buffered.subarray(end + 1);
          this.receive(line);
        }
        if (buffered.length > MAX_WORKER_FRAME_BYTES) this.terminate('plugin-limit');
      });
      const exited = () => { if (this.child === child) this.terminate('internal-error'); };
      child.on('error', exited);
      child.stdin.on('error', exited);
      child.on('exit', exited);
    } catch (error) {
      this.terminate();
      throw error instanceof BridgeError ? error : new BridgeError('internal-error');
    }
  }

  private dispatch(hook: PluginHookName, input: unknown, deadline: number, historical: boolean) {
    return new Promise<void>((resolve, reject) => {
      const remaining = Math.ceil(deadline - performance.now());
      if (remaining <= 0) { this.terminate('plugin-timeout'); reject(new BridgeError('plugin-timeout')); return; }
      const token = randomUUID();
      const controller = new AbortController();
      const timer = setTimeout(() => this.terminate('plugin-timeout'), remaining);
      this.active = { token, controller, historical, calls: 0, finish: error => {
        clearTimeout(timer);
        this.active = undefined;
        controller.abort();
        if (error) reject(new BridgeError(error));
        else resolve();
      } };
      this.write({ type: 'invoke', token, hook, input });
    });
  }

  private write(frame: unknown) {
    try {
      const line = JSON.stringify(frame);
      if (Buffer.byteLength(line) > MAX_WORKER_FRAME_BYTES) { this.terminate('plugin-limit'); return; }
      this.child?.stdin.write(line + '\n');
    } catch { this.terminate('internal-error'); }
  }

  private receive(line: Buffer) {
    const active = this.active;
    if (!active) return;
    let frame: Record<string, unknown> | undefined;
    try { frame = object(JSON.parse(line.toString('utf8'))); }
    catch { this.terminate('internal-error'); return; }
    if (frame?.token !== active.token) return;
    if (frame.type === 'done') {
      const code = frame.error;
      active.finish(code === undefined || code === 'permission-denied' || isErrorCode(code) ? code : 'internal-error');
      return;
    }
    if (frame.type !== 'call' || !Number.isSafeInteger(frame.id) || typeof frame.method !== 'string' ||
        !Object.hasOwn(rpc, frame.method)) { this.terminate('internal-error'); return; }
    if (++active.calls > 1024) { this.terminate('plugin-limit'); return; }
    void this.call(active, frame.id as number, frame.method as WorkerMethod, frame.params);
  }

  private async call<M extends WorkerMethod>(active: ActiveHook, id: number, method: M, params: unknown) {
    const reply = (result: unknown, error?: string) => {
      if (this.active === active) this.write({ type: 'reply', token: active.token, id, result, error });
    };
    try {
      const handler = this.options.handlers?.[method];
      if (!this.approved.has(permissions[method]) || !handler || (method === 'emit.wechat' && active.historical)) {
        throw new BridgeError('permission-denied');
      }
      const args = rpc[method].safeParse(params);
      if (!args.success) throw new BridgeError('invalid-configuration');
      if (method === 'history.fetch') active.historical = true;
      const run = handler as (signal: AbortSignal, ...args: unknown[]) => unknown;
      reply(await run(active.controller.signal, ...args.data));
    } catch (error) {
      const code = error instanceof BridgeError ? error.code : undefined;
      reply(undefined, code === 'permission-denied' || isErrorCode(code) ? code : 'internal-error');
    }
  }

  private terminate(error = 'stopped') {
    const child = this.child;
    this.child = undefined;
    this.initialized = false;
    this.active?.finish(error);
    if (child) child.kill('SIGKILL');
    if (this.stage) {
      rmSync(this.stage, { recursive: true, force: true });
      this.stage = undefined;
    }
  }

  dispose() {
    this.disposed = true;
    this.terminate();
  }
}
