import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';
import type { PluginContext, PluginHookName, WeChatBridgePlugin } from './sdk.ts';

export const WORKER_FLAG = '--plugin-worker';
export const MAX_WORKER_FRAME_BYTES = 1024 * 1024;
export type WorkerMethod =
  | 'log' | 'kv.get' | 'kv.set' | 'llm.complete' | 'history.fetch'
  | 'emit.feed' | 'emit.markdownFile' | 'emit.wechat' | 'emit.webhook';
type HostFrame =
  | { type: 'invoke'; token: string; hook: PluginHookName; input?: unknown }
  | { type: 'reply'; token: string; id: number; result?: unknown; error?: string };

/** 在 main.ts 的引擎初始化前调用。有插件参数时接管 stdin/stdout 并退出。 */
export async function runPluginWorkerCli(args = process.argv.slice(2)): Promise<boolean> {
  if (args[0] !== WORKER_FLAG) return false;
  const [, entry, pluginId, config] = args;
  if (!entry || !pluginId || config === undefined) process.exit(1);

  const write = process.stdout.write.bind(process.stdout);
  const send = (message: unknown) => write(JSON.stringify(message) + '\n');
  for (const level of ['log', 'info', 'warn', 'error', 'debug'] as const) console[level] = () => {};
  const lines = createInterface({ input: process.stdin });
  let plugin: WeChatBridgePlugin | undefined;
  let active: string | undefined;
  let nextId = 0;
  const pending = new Map<number, { resolve: (result: unknown) => void; reject: (error: Error) => void }>();

  const invoke = async (frame: Extract<HostFrame, { type: 'invoke' }>) => {
    const { token, hook, input } = frame;
    active = token;
    const request = <T>(method: WorkerMethod, ...params: unknown[]): Promise<T> =>
      new Promise((resolve, reject) => {
        if (active !== token) { reject(new Error('stopped')); return; }
        const id = ++nextId;
        const data = JSON.stringify({ type: 'call', token, id, method, params });
        if (Buffer.byteLength(data) > MAX_WORKER_FRAME_BYTES) { reject(new Error('plugin-limit')); return; }
        pending.set(id, { resolve: value => resolve(value as T), reject });
        write(data + '\n');
      });
    const ctx: PluginContext = {
      pluginId, config: JSON.parse(config),
      log: (level, message) => request('log', level, message),
      kv: { get: key => request('kv.get', key), set: (key, value) => request('kv.set', key, value) },
      llm: { complete: req => request('llm.complete', req) },
      history: { fetch: (conversationId, options) => request('history.fetch', conversationId, options) },
      emit: {
        feed: item => request('emit.feed', item),
        markdownFile: options => request('emit.markdownFile', options),
        wechat: options => request('emit.wechat', options),
        webhook: options => request('emit.webhook', options),
      },
    };
    let failure: string | undefined;
    try {
      if (!plugin) {
        const loaded = await import(pathToFileURL(entry).href);
        plugin = loaded.default ?? loaded;
      }
      const handler = plugin?.[hook];
      if (typeof handler === 'function') {
        if (hook === 'onInit') await (handler as NonNullable<WeChatBridgePlugin['onInit']>).call(plugin, ctx);
        else await (handler as (event: unknown, context: PluginContext) => unknown).call(plugin, input, ctx);
      }
    } catch (error) {
      failure = error instanceof Error && error.name === 'PluginRpcError' ? error.message : 'internal-error';
    } finally {
      active = undefined;
      for (const { reject } of pending.values()) reject(new Error('stopped'));
      pending.clear();
      send({ type: 'done', token, error: failure });
    }
  };

  lines.on('line', value => {
    const frame = JSON.parse(value) as HostFrame;
    if (frame.type === 'invoke' && !active) void invoke(frame).catch(() => process.exit(1));
    if (frame.type === 'reply' && frame.token === active) {
      const call = pending.get(frame.id);
      pending.delete(frame.id);
      if (frame.error) call?.reject(Object.assign(new Error(frame.error), { name: 'PluginRpcError' }));
      else call?.resolve(frame.result);
    }
  });
  await new Promise<void>(resolve => lines.once('close', resolve));
  process.exit(0);
}

if (import.meta.main && process.argv[2] === WORKER_FLAG) await runPluginWorkerCli();
