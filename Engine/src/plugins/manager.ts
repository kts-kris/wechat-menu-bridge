import { createHash, randomUUID } from 'node:crypto';
import { readdirSync, unlinkSync } from 'node:fs';
import { identifierSchema, type BackfillRequest, type NormalizedEvent, type ScopeType } from '../contracts/events.ts';
import { BridgeError, errorCode } from '../contracts/errors.ts';
import type { PluginRuntimeState, RpcParams, RpcResult } from '../contracts/ipc.ts';
import { declarativePluginConfigSchema, pluginManifestSchema, type DeclarativePluginConfig, type PluginManifest } from '../contracts/plugins.ts';
import type { IpcV3Extensions } from '../ipc/router-v3.ts';
import type { ModelRouter } from '../llm/router.ts';
import type { HistoryBackfiller } from '../mcp/backfill.ts';
import type { Scope } from '../mcp/client.ts';
import { eventRefHash } from '../mcp/ingest.ts';
import { atomicWritePrivateFile, ensurePrivateDir, readPrivateFile, resolveContainedPath } from '../storage/fs-safe.ts';
import type { JournalV2, PluginRun, PluginState } from '../storage/journal-v2.ts';
import { DeclarativeRunner, type DeclarativeResult } from './declarative.ts';
import { matchesScope, messageForPlugin, validateTrigger, WindowScheduler, type PluginMessage, type WindowBatch } from './scheduler.ts';
import { checkWebhookUrl, SinkDispatcher, type SinkDispatcherOptions } from './sinks.ts';
import { PluginWorkerHost, type PluginWorkerHandlers } from './worker-host.ts';

type Entry = { kind: 'declarative'; config: DeclarativePluginConfig } |
  { kind: 'module'; manifest: PluginManifest; path: string; source: Buffer; hash: string };
type ModuleEntry = Extract<Entry, { kind: 'module' }>;
type HistoryContext = { backfiller: Pick<HistoryBackfiller, 'run'>; scope: Scope; type: ScopeType; route: string; identity: string };
type RunProgress = { count: number; title?: string; paths: string[]; skipped: boolean };
type RunWork = (signal: AbortSignal, progress: RunProgress) => Promise<void>;

export interface PluginManagerOptions extends SinkDispatcherOptions {
  modelRouter: Pick<ModelRouter, 'summarize'>;
  defaultPresetId?: () => string | undefined;
  cloudApproved?: (presetId: string, pluginId: string) => boolean;
  getHistoryContext?: (conversationId: string, signal: AbortSignal) => HistoryContext | Promise<HistoryContext>;
  scopeName?: (conversationId: string) => string | undefined;
  moduleConfig?: (manifest: PluginManifest) => Record<string, unknown>;
  onPluginUpdated?: (pluginId: string, state: PluginRuntimeState) => void;
  onLog?: (pluginId: string, level: 'info' | 'warn' | 'error', message: string) => void;
  pollIntervalMs?: number;
  workerTimeoutMs?: number;
}

const validFileId = (id: string) => /^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/.test(id);
const moduleEntryPattern = /\.(?:[cm]?js|[m]?ts)$/;
const readJson = (path: string): unknown => JSON.parse(readPrivateFile(path, 1024 * 1024).toString('utf8'));
const taskError = () => new BridgeError('invalid-configuration');
const entryId = (entry: Entry) => entry.kind === 'module' ? entry.manifest.id : entry.config.id;

function present(state: PluginState): PluginRuntimeState {
  return {
    kind: state.kind, enabled: !!state.enabled, approvedPermissions: state.approved_permissions,
    consecutiveFailures: state.consecutive_failures, circuitOpen: !!state.circuit_open,
    ...(state.manifest_hash !== null && { manifestHash: state.manifest_hash }),
    ...(state.last_run_at !== null && { lastRunAt: state.last_run_at }),
    ...(state.last_error !== null && { lastError: state.last_error }),
  };
}

export class PluginManager {
  private readonly journal: JournalV2;
  private readonly now: () => number;
  private readonly declarativeDir: string;
  private readonly modulesDir: string;
  private readonly dataDir: string;
  private readonly scheduler: WindowScheduler;
  private readonly sinks: SinkDispatcher;
  private readonly runner: DeclarativeRunner;
  private readonly entries = new Map<string, Entry>();
  private readonly workers = new Map<string, PluginWorkerHost>();
  private readonly active = new Map<string, { controller: AbortController; task: Promise<string> }>();
  private readonly queues = new Map<string, { task: Promise<void>; size: number }>();
  private readonly timer: ReturnType<typeof setInterval>;
  private disposed = false;

  constructor(private readonly options: PluginManagerOptions) {
    this.journal = options.journal;
    this.now = options.now ?? Date.now;
    ensurePrivateDir(options.baseDir);
    const root = resolveContainedPath(options.baseDir, 'plugins');
    ensurePrivateDir(root);
    this.declarativeDir = resolveContainedPath(root, 'declarative');
    this.modulesDir = resolveContainedPath(root, 'modules');
    this.dataDir = resolveContainedPath(root, 'data');
    for (const dir of [this.declarativeDir, this.modulesDir, this.dataDir]) ensurePrivateDir(dir);
    this.scheduler = new WindowScheduler(this.journal);
    this.sinks = new SinkDispatcher(options);
    this.runner = new DeclarativeRunner({
      models: options.modelRouter, defaultPresetId: options.defaultPresetId, cloudApproved: options.cloudApproved,
    });
    for (const file of readdirSync(this.declarativeDir).sort()) {
      if (!file.endsWith('.json')) continue;
      try {
        const config = this.validateConfig(readJson(resolveContainedPath(this.declarativeDir, file)));
        if (file === `${config.id}.json`) this.register({ kind: 'declarative', config });
      } catch { /* 一个无效配置不影响其他插件 */ }
    }
    this.refreshModules();
    this.timer = setInterval(() => { void this.tick().catch(() => {}); }, options.pollIntervalMs ?? 1000);
    this.timer.unref();
  }

  readonly extensions: IpcV3Extensions = {
    'plugins.list': () => this.list(),
    'plugins.saveDeclarative': params => this.saveDeclarative(params),
    'plugins.deleteDeclarative': params => this.deleteDeclarative(params),
    'plugins.setEnabled': params => this.setEnabled(params),
    'plugins.runNow': params => this.runNow(params),
    'plugins.runs': params => this.runs(params),
    'plugins.testWebhook': params => { this.available(); return this.sinks.testWebhook(params); },
  };

  list(_params?: RpcParams<'plugins.list'>): RpcResult<'plugins.list'> {
    this.available();
    this.refreshModules();
    return [...this.entries.values()].map(entry => {
      const pluginId = entryId(entry);
      const state = present(this.journal.getPluginState(pluginId)!);
      return entry.kind === 'module' ? { pluginId, state, kind: entry.kind, manifest: entry.manifest } :
        { pluginId, state, kind: entry.kind, config: { ...entry.config, enabled: state.enabled } };
    });
  }

  saveDeclarative({ config: input }: RpcParams<'plugins.saveDeclarative'>): true {
    this.available();
    const config = this.validateConfig(input);
    this.refreshModules();
    if (this.entries.get(config.id)?.kind === 'module') throw taskError();
    atomicWritePrivateFile(this.configPath(config.id), JSON.stringify(config, null, 2) + '\n');
    this.interrupt(config.id);
    this.scheduler.clear(config.id);
    const state = this.register({ kind: 'declarative', config });
    this.saveState({ ...state, enabled: config.enabled && !state.circuit_open ? 1 : 0 });
    return true;
  }

  deleteDeclarative({ pluginId }: RpcParams<'plugins.deleteDeclarative'>): true {
    this.available();
    if (this.entries.get(pluginId)?.kind !== 'declarative') throw taskError();
    unlinkSync(this.configPath(pluginId));
    this.interrupt(pluginId);
    this.scheduler.clear(pluginId);
    this.journal.deletePluginState(pluginId);
    this.entries.delete(pluginId);
    return true;
  }

  setEnabled({ pluginId, enabled, approvedPermissions, manifestHash }: RpcParams<'plugins.setEnabled'>): true {
    this.available();
    this.refreshModules();
    const entry = this.entries.get(pluginId);
    if (!entry) throw taskError();
    const state = this.journal.getPluginState(pluginId)!;
    if (entry.kind === 'module' && enabled) {
      if (approvedPermissions !== undefined || manifestHash !== undefined || state.last_error === 'plugin-permission') {
        if (manifestHash !== entry.hash || !approvedPermissions ||
            approvedPermissions.some(permission => !entry.manifest.permissions.includes(permission)) ||
            entry.manifest.permissions.some(permission => !approvedPermissions.includes(permission))) {
          throw new BridgeError('plugin-permission');
        }
        state.approved_permissions = [...new Set(approvedPermissions)];
      }
    }
    this.interrupt(pluginId);
    if (!enabled) this.scheduler.clear(pluginId);
    this.saveState({ ...state, enabled: enabled ? 1 : 0, ...(enabled && {
      circuit_open: 0, consecutive_failures: 0, last_error: null,
    }) });
    return true;
  }

  runs({ pluginId, cursor, limit = 100 }: RpcParams<'plugins.runs'>): RpcResult<'plugins.runs'> {
    this.available();
    const offset = cursor === undefined ? 0 : Number(cursor);
    if (!Number.isSafeInteger(offset) || offset < 0) throw taskError();
    const rows = this.journal.listPluginRuns(pluginId, limit + 1, offset);
    return {
      items: rows.slice(0, limit).map(row => ({
        pluginId: row.plugin_id, runId: row.run_id, triggerKind: row.trigger_kind, startedAt: row.started_at,
        status: row.status, itemCount: row.item_count, ...(row.finished_at !== null && { finishedAt: row.finished_at }),
        ...(row.summary_preview !== null && { summaryPreview: row.summary_preview }),
        ...(row.output_paths !== null && { outputPaths: row.output_paths }), ...(row.error_code !== null && { errorCode: row.error_code }),
      })),
      nextCursor: rows.length > limit ? String(offset + limit) : null,
    };
  }

  async handleEvent(event: NormalizedEvent): Promise<void> {
    if (this.disposed) return;
    if (event.kind === 'recall') this.scheduler.recall(event);
    if (event.origin === 'backfill') return;
    const tasks: (Promise<unknown> | undefined)[] = [];
    for (const [id, entry] of this.entries) {
      const state = this.journal.getPluginState(id);
      if (!state?.enabled || state.circuit_open) continue;
      if (entry.kind === 'module') {
        if (!state.approved_permissions.includes('read_events')) continue;
        const hook = event.kind === 'recall' ? 'onRecall' : 'onMessage';
        tasks.push(this.enqueue(id, async () => {
          const current = this.refreshModule(id);
          if (!current || current.hash !== entry.hash || !this.isEnabled(id)) return;
          await this.execute(id, 'realtime', async (_signal, progress) => {
            progress.count = 1;
            const { rawText: _raw, media, ...safeEvent } = event;
            const safeMedia = media && { ...media, localTempPath: undefined };
            await this.worker(current).invoke(hook, { ...safeEvent, media: safeMedia });
          });
        }));
        continue;
      }
      const realtime = this.scheduler.accept(entry.config, event);
      if (realtime) tasks.push(this.enqueue(id, async () => {
        if (this.entries.get(id) !== entry || !this.isEnabled(id)) return;
        await this.execute(id, 'realtime', (signal, progress) =>
          this.processMessages(entry.config, [realtime], signal, progress, 'live'));
      }));
    }
    tasks.push(this.tick());
    await Promise.allSettled(tasks);
  }

  async tick(): Promise<void> {
    if (this.disposed) return;
    const tasks: Promise<string>[] = [];
    for (const [id, entry] of this.entries) {
      if (entry.kind !== 'declarative' || this.active.has(id) || !this.isEnabled(id) || this.rateLimited(entry.config)) continue;
      const batch = this.scheduler.due(entry.config, this.now());
      if (batch) tasks.push(this.execute(id, batch.trigger, (signal, progress) =>
        this.flush(entry.config, batch, signal, progress)));
    }
    await Promise.allSettled(tasks);
  }

  async runNow({ pluginId, conversationId, range }: RpcParams<'plugins.runNow'>): Promise<RpcResult<'plugins.runNow'>> {
    this.available();
    this.refreshModules();
    const entry = this.entries.get(pluginId);
    if (!entry || (range && range.startTime > range.endTime)) throw taskError();
    if (this.journal.getPluginState(pluginId)?.circuit_open) throw new BridgeError('plugin-circuit-open');
    if (!this.isEnabled(pluginId) && entry.kind === 'module') throw new BridgeError('plugin-permission');
    if (entry.kind === 'module') {
      if (!conversationId || !range) throw taskError();
      if (!this.journal.getPluginState(pluginId)?.approved_permissions.includes('read_history')) throw new BridgeError('plugin-permission');
      return { runId: await this.execute(pluginId, 'manual', async () => {
        await this.worker(entry).invoke('onManualRun', { conversationId, since: range.startTime, until: range.endTime });
      }) };
    }
    const targets = conversationId ? [conversationId] : entry.config.scope.conversationIds;
    if (range && (!targets.length || !this.options.getHistoryContext)) throw taskError();
    if (this.rateLimited(entry.config)) throw new BridgeError('plugin-limit');
    const runId = await this.execute(pluginId, 'manual', async (signal, progress) => {
      if (targets.length && this.options.getHistoryContext) {
        const messages: PluginMessage[] = [];
        for (const target of targets) {
          const events = await this.history({ conversationId: target, purpose: 'plugin',
            ...(range ?? { recentCount: 50 }) }, signal);
          messages.push(...events.filter(event => matchesScope(entry.config, event) &&
            (!range || event.createdAt >= range.startTime && event.createdAt <= range.endTime)).map(messageForPlugin));
        }
        await this.processMessages(entry.config, messages, signal, progress, 'backfill', range);
      } else {
        const batch = this.journal.snapshotPluginBuffers(pluginId);
        if (conversationId) await this.processMessages(entry.config, batch.items.filter(item => item.conversation_id === conversationId),
          signal, progress, 'human');
        else await this.flush(entry.config, batch, signal, progress, 'human');
      }
    });
    return { runId };
  }

  async dispose() {
    if (this.disposed) return;
    this.disposed = true;
    clearInterval(this.timer);
    for (const id of this.entries.keys()) this.interrupt(id);
    await Promise.allSettled([...this.active.values()].map(job => job.task));
    await Promise.allSettled([...this.queues.values()].map(queue => queue.task));
  }

  private available() { if (this.disposed) throw new BridgeError('stopped'); }
  private configPath(id: string) { return resolveContainedPath(this.declarativeDir, `${id}.json`); }

  private validateConfig(input: unknown) {
    const result = declarativePluginConfigSchema.safeParse(input);
    if (!result.success || !validFileId(result.data.id)) throw taskError();
    validateTrigger(result.data.trigger);
    const sinkIds = new Set<string>();
    for (const sink of result.data.sinks) {
      if (sinkIds.has(sink.id)) throw taskError();
      sinkIds.add(sink.id);
      if (sink.type === 'webhook') checkWebhookUrl(sink.url);
    }
    return result.data;
  }

  private isEnabled(id: string) {
    const state = this.journal.getPluginState(id);
    return !!state?.enabled && !state.circuit_open;
  }

  private saveState(state: PluginState) {
    this.journal.savePluginState(state);
    try { this.options.onPluginUpdated?.(state.plugin_id, present(state)); } catch { /* 运行态已落盘 */ }
  }

  private register(entry: Entry) {
    const id = entryId(entry);
    this.entries.set(id, entry);
    const previous = this.journal.getPluginState(id);
    if (previous?.kind === entry.kind && (entry.kind === 'declarative' || previous.manifest_hash === entry.hash)) return previous;
    this.interrupt(id);
    const state: PluginState = {
      plugin_id: id, kind: entry.kind, enabled: entry.kind === 'declarative' && entry.config.enabled ? 1 : 0,
      approved_permissions: [], manifest_hash: entry.kind === 'module' ? entry.hash : null,
      consecutive_failures: 0, circuit_open: 0, last_run_at: previous?.last_run_at ?? null,
      last_error: entry.kind === 'module' ? 'plugin-permission' : null,
    };
    this.saveState(state);
    return state;
  }

  private refreshModule(id: string): ModuleEntry | undefined {
    if (!validFileId(id) || this.entries.get(id)?.kind === 'declarative') return;
    try {
      const directory = resolveContainedPath(this.modulesDir, id);
      const rawManifest = readPrivateFile(resolveContainedPath(directory, 'manifest.json'));
      const parsed = pluginManifestSchema.safeParse(JSON.parse(rawManifest.toString('utf8')));
      if (!parsed.success || parsed.data.id !== id || !moduleEntryPattern.test(parsed.data.entry)) throw taskError();
      const path = resolveContainedPath(directory, parsed.data.entry);
      const source = readPrivateFile(path, 1024 * 1024);
      const hash = createHash('sha256').update(String(rawManifest.length)).update(':').update(rawManifest).update(source).digest('hex');
      const previous = this.entries.get(id);
      if (previous?.kind === 'module' && previous.hash === hash) return previous;
      const entry = { kind: 'module', manifest: parsed.data, path, source, hash } as const;
      this.register(entry);
      return entry;
    } catch {
      const state = this.journal.getPluginState(id);
      if (state?.kind === 'module' && state.manifest_hash !== null) {
        this.interrupt(id);
        this.saveState({ ...state, enabled: 0, approved_permissions: [], manifest_hash: null, last_error: 'plugin-permission' });
      }
      this.entries.delete(id);
    }
  }

  private refreshModules() {
    const known = [...this.entries.values()].filter(entry => entry.kind === 'module').map(entryId);
    const names = readdirSync(this.modulesDir);
    for (const id of new Set([...known, ...names])) this.refreshModule(id);
  }

  private interrupt(id: string) {
    this.active.get(id)?.controller.abort();
    this.workers.get(id)?.dispose();
    this.workers.delete(id);
  }

  private queueRoom(id: string) {
    if (this.disposed) return undefined;
    const prior = this.queues.get(id);
    if (prior) return prior.size < 128 ? prior : undefined;
    const queue = { task: Promise.resolve(), size: 0 };
    this.queues.set(id, queue);
    return queue;
  }

  private enqueue(id: string, work: () => Promise<void>) {
    const queue = this.queueRoom(id);
    if (!queue) return;
    queue.size++;
    queue.task = queue.task.then(async () => {
      await this.active.get(id)?.task;
      if (!this.disposed) await work();
    }).catch(() => {}).finally(() => {
      if (--queue.size === 0) this.queues.delete(id);
    });
    return queue.task;
  }

  private rateLimited(config: DeclarativePluginConfig) {
    const limit = config.rateLimit.maxRunsPerHour;
    if (limit === 0) return true;
    const since = this.now() - 3_600_000;
    return this.journal.listPluginRuns(config.id, limit).filter(run => run.started_at > since).length >= limit;
  }

  private execute(id: string, trigger: PluginRun['trigger_kind'], work: RunWork): Promise<string> {
    this.available();
    if (this.active.has(id)) throw new BridgeError('busy');
    const entry = this.entries.get(id)!;
    if (entry.kind === 'declarative' && this.rateLimited(entry.config)) throw new BridgeError('plugin-limit');
    const controller = new AbortController();
    const run: PluginRun = {
      run_id: randomUUID(), plugin_id: id, trigger_kind: trigger, started_at: this.now(), finished_at: null,
      status: 'running', item_count: 0, summary_preview: null, output_paths: null, error_code: null,
    };
    this.journal.savePluginRun(run);
    const task = Promise.resolve().then(async () => {
      const progress: RunProgress = { count: 0, paths: [], skipped: true };
      try {
        if (controller.signal.aborted) throw new BridgeError('stopped');
        if (entry.kind === 'module') progress.skipped = false;
        await work(controller.signal, progress);
        run.status = progress.skipped ? 'skipped' : 'ok';
      } catch (error) {
        run.status = 'error';
        run.error_code = controller.signal.aborted ? 'stopped' :
          error instanceof BridgeError && error.code === 'permission-denied' ? 'plugin-permission' : errorCode(error);
      }
      Object.assign(run, {
        finished_at: this.now(), item_count: progress.count, summary_preview: progress.title?.slice(0, 500) ?? null,
        output_paths: progress.paths.length ? progress.paths : null,
      });
      this.journal.savePluginRun(run);
      if (this.entries.get(id) === entry && !controller.signal.aborted) this.updateAfterRun(id, run);
      return run.run_id;
    }).finally(() => { this.active.delete(id); });
    this.active.set(id, { controller, task });
    return task;
  }

  private updateAfterRun(id: string, run: PluginRun) {
    const state = this.journal.getPluginState(id);
    if (!state) return;
    state.last_run_at = run.finished_at;
    state.last_error = run.error_code;
    state.consecutive_failures = run.status === 'error' ? state.consecutive_failures + 1 : 0;
    const opened = state.consecutive_failures >= 3 && !state.circuit_open;
    if (opened) {
      state.circuit_open = 1;
      state.enabled = 0;
    }
    this.saveState(state);
    if (opened) {
      this.interrupt(id);
      this.scheduler.clear(id);
      this.sinks.feed({ pluginId: id, kind: 'alert', title: '插件已暂停', body: `插件 ${id} 连续失败 3 次，已自动暂停。`, notify: true });
    }
  }

  private async flush(config: DeclarativePluginConfig, batch: { throughId: number; items: WindowBatch['items'] },
    signal: AbortSignal, progress: RunProgress, origin: 'human' | 'live' = 'live') {
    const current = () => this.scheduler.current(config.id, batch.throughId);
    try { await this.processMessages(config, current(), signal, progress, origin, undefined, current); }
    finally { this.scheduler.clear(config.id, batch.throughId); }
  }

  private async processMessages(config: DeclarativePluginConfig, messages: readonly PluginMessage[],
    signal: AbortSignal, progress: RunProgress, origin: 'human' | 'live' | 'backfill',
    range?: { startTime: number; endTime: number }, current?: () => readonly PluginMessage[]) {
    const groups = new Map<string, PluginMessage[]>();
    for (const message of messages) {
      const group = groups.get(message.conversation_id) ?? [];
      group.push(message);
      groups.set(message.conversation_id, group);
    }
    const results = await Promise.allSettled([...groups].map(async ([conversationId, initial]) => {
      const scopeName = this.options.scopeName?.(conversationId) ?? conversationId;
      let selection = initial;
      let result: DeclarativeResult;
      const getCurrent = () => current?.().filter(item => item.conversation_id === conversationId) ?? selection;
      while (true) {
        result = await this.runner.run(config, { scopeName, messages: selection, range }, signal);
        const latest = getCurrent();
        if (latest.length === selection.length) break;
        selection = latest;
      }
      progress.count += selection.length;
      if (result.status === 'skipped') return;
      progress.skipped = false;
      progress.title ??= result.title;
      const dedupeKey = JSON.stringify([conversationId, selection.map(item => item.message_ref)]);
      const { outputPaths, errors } = await this.sinks.dispatch(config.sinks, {
        pluginId: config.id, conversationId, scopeName, title: result.title, markdown: result.markdown,
        dedupeKey, maxWeChatSendsPerDay: config.rateLimit.maxWeChatSendsPerDay, origin, signal,
        checkStillValid: () => {
          if (getCurrent().length !== selection.length) throw new BridgeError('stopped');
        },
      });
      progress.paths.push(...outputPaths);
      if (errors.length) throw new BridgeError(errors[0]!);
    }));
    const failure = results.find(result => result.status === 'rejected');
    if (failure) throw failure.reason;
  }

  private async history(request: BackfillRequest, signal: AbortSignal) {
    const context = await this.options.getHistoryContext?.(request.conversationId, signal);
    if (!context) throw new BridgeError('mcp-offline');
    const { backfiller, scope, type, route, identity } = context;
    const events: NormalizedEvent[] = [];
    const recalls = new Set<string>();
    await backfiller.run(randomUUID(), request, scope, type, route, identity, { signal, onEvent: input => {
      const { event } = input;
      if (event.kind === 'recall') {
        if (event.recallTargetRef) recalls.add(event.recallTargetRef);
      } else if (!this.journal.isRecalled(input.route, eventRefHash(input))) {
        const { rawText: _raw, media, ...safeEvent } = event;
        events.push({ ...safeEvent, ...(media && { media: { ...media, localTempPath: undefined } }) });
      }
    } });
    return events.filter(event => !recalls.has(event.messageRef));
  }

  private worker(entry: ModuleEntry) {
    const id = entry.manifest.id;
    const existing = this.workers.get(id);
    if (existing) return existing;
    const check = (signal: AbortSignal) => {
      if (signal.aborted || this.refreshModule(id)?.hash !== entry.hash || !this.isEnabled(id)) throw new BridgeError('stopped');
    };
    const dataPath = () => resolveContainedPath(this.dataDir, `${id}.json`);
    const kv = () => {
      const file = dataPath();
      if (!Bun.file(file).size) return new Map<string, unknown>();
      return new Map(Object.entries(readJson(file) as Record<string, unknown>));
    };
    const handlers: PluginWorkerHandlers = {
      log: (signal, level, message) => { check(signal); this.options.onLog?.(id, level, message); },
      'kv.get': (signal, key) => { check(signal); return kv().get(key) ?? null; },
      'kv.set': (signal, key, value) => {
        check(signal);
        const values = kv();
        values.set(key, value);
        const serialized = JSON.stringify(Object.fromEntries(values));
        if (Buffer.byteLength(serialized) > 1024 * 1024) throw new BridgeError('plugin-limit');
        atomicWritePrivateFile(dataPath(), serialized);
      },
      'llm.complete': (signal, request) => {
        check(signal);
        const presetId = request.presetId ?? this.options.defaultPresetId?.();
        if (!presetId) throw taskError();
        return this.options.modelRouter.summarize(presetId, request.system +
          (request.json ? '\nReturn a single JSON value.' : ''), request.user, {
          signal, priority: 'background', cloudApproved: this.options.cloudApproved?.(presetId, id) === true,
        });
      },
      'history.fetch': async (signal, conversationId, options) => {
        check(signal);
        const events = await this.history({ conversationId, purpose: 'plugin', recentCount: options.limit }, signal);
        return events.filter(event => options.since === undefined || event.createdAt >= options.since);
      },
      'emit.feed': (signal, item) => { check(signal); this.sinks.feed({ ...item, pluginId: id }); },
      'emit.markdownFile': (signal, item) => {
        check(signal);
        return this.sinks.markdownFile(item.filename, item.content, item.mode ?? 'overwrite', undefined, id);
      },
      'emit.wechat': (signal, item) => {
        check(signal);
        return this.sinks.moduleWeChat(id, item, signal);
      },
      'emit.webhook': (signal, item) => { check(signal); return this.sinks.webhook(item.url, item.payload, signal); },
    };
    const plugin = new PluginWorkerHost({
      pluginId: id, entry: entry.path, source: entry.source, config: this.options.moduleConfig?.(entry.manifest),
      approvedPermissions: this.journal.getPluginState(id)!.approved_permissions, handlers, timeoutMs: this.options.workerTimeoutMs,
    });
    this.workers.set(id, plugin);
    return plugin;
  }
}
