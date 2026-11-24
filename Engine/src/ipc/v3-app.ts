import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { BridgeError } from '../contracts/errors.ts';
import type { BackfillRequest, NormalizedEvent } from '../contracts/events.ts';
import { MAX_INLINE_DOCUMENT_BYTES, type PluginRuntimeState, type RpcResult } from '../contracts/ipc.ts';
import { loadSettingsV2FromDisk, type ConversationPolicy, type ModelPreset, type SettingsV2 } from '../contracts/settings.ts';
import { BridgeOrchestrator } from '../core/orchestrator.ts';
import { MemoryConsolidator } from '../memory/consolidator.ts';
import { PromptContextAssembler } from '../memory/context-assembler.ts';
import { PersonaEvolver } from '../memory/persona.ts';
import { MemoryStore } from '../memory/store.ts';
import { memoryScopeKey, type MemoryTarget, type ScopeTarget } from '../memory/types.ts';
import { PluginManager } from '../plugins/manager.ts';
import { ensurePrivateDir, readPrivateFile, resolveContainedPath } from '../storage/fs-safe.ts';
import { HotBundleManager } from '../storage/hot-bundles.ts';
import type { MemoryRevision, PersonaProposal } from '../storage/journal-v2.ts';
import { IpcV3Router, type IpcV3Extensions } from './router-v3.ts';

function toRpcRevision(row: MemoryRevision) {
  return {
    revId: row.rev_id, targetKind: row.target_kind, scopeKey: row.scope_key,
    snapshotPath: row.snapshot_path, source: row.source, summary: row.summary,
    diffPreview: row.diff_preview, createdAt: row.created_at,
  };
}

function toRpcProposal(row: PersonaProposal) {
  return {
    proposalId: row.proposal_id, status: row.status, filePath: row.file_path,
    sampleCount: row.sample_count, summary: row.summary, createdAt: row.created_at,
    ...(row.decided_at !== null && { decidedAt: row.decided_at }),
  };
}

function parseCursor(cursor?: string) {
  if (cursor === undefined) return 0;
  const offset = Number(cursor);
  if (!Number.isSafeInteger(offset) || offset < 0 || !/^\d+$/.test(cursor)) throw new BridgeError('invalid-configuration');
  return offset;
}

export class V3EngineApp {
  readonly orchestrator: BridgeOrchestrator;
  readonly plugins: PluginManager;
  readonly router: IpcV3Router;
  private memoryStore: MemoryStore;
  private consolidator: MemoryConsolidator;
  private persona: PersonaEvolver;
  private assembler: PromptContextAssembler;
  private readonly bundles: HotBundleManager;
  private memoryDir: string;
  private readonly cloudKeys = new Map<string, Pick<ModelPreset, 'url' | 'kind'> & { key: string }>();
  private readonly unsubscribes: (() => void)[] = [];
  private closed = false;

  constructor(private readonly stateDir: string, sink: (line: string) => void) {
    ensurePrivateDir(stateDir);
    const settings = loadSettingsV2FromDisk(stateDir);
    this.orchestrator = new BridgeOrchestrator(stateDir, {
      settings,
      getModelKey: preset => this.approvedCloudKey(preset),
      assemblePrompt: (policy, mode) => this.assemblePrompt(policy, mode),
      onSettingsApplied: (next, cloudApiKeys) => this.handleSettingsApplied(next, cloudApiKeys),
    });

    this.memoryDir = this.resolveMemoryDir(settings);
    this.memoryStore = new MemoryStore(this.memoryDir, this.orchestrator.journal);
    this.assembler = new PromptContextAssembler(this.memoryStore);
    this.bundles = new HotBundleManager(stateDir);
    this.orchestrator.modelRouter.setReasoningEffortDisabled(this.bundles.disabledReasoningEffortUrls());
    this.consolidator = this.createConsolidator(settings);
    this.persona = this.createPersona(settings);

    this.plugins = new PluginManager({
      journal: this.orchestrator.journal,
      baseDir: stateDir,
      modelRouter: this.orchestrator.modelRouter,
      defaultPresetId: () => this.orchestrator.currentSettings.defaultModels.pluginPresetId ??
        this.orchestrator.currentSettings.defaultModels.replyPresetId,
      cloudApproved: presetId => this.isCloudPresetApproved(presetId),
      getTransmit: () => {
        const transmitter = this.orchestrator.transmitter;
        const expectedIdentity = this.orchestrator.currentIdentity;
        return transmitter && expectedIdentity ? { transmitter, expectedIdentity } : undefined;
      },
      getHistoryContext: (conversationId, signal) => this.orchestrator.historyContext(conversationId, signal),
      scopeName: conversationId => this.orchestrator.currentSettings.conversations[conversationId]?.label,
      onFeedAdded: (item, notifyDesktop) => {
        void this.orchestrator.bus.publish('feed.added', {
          item: {
            id: item.id, kind: item.kind, title: item.title, body: item.body,
            ...(item.conversation_id !== null && { conversationId: item.conversation_id }),
            ...(item.plugin_id !== null && { pluginId: item.plugin_id }),
            ...(item.ref_path !== null && { refPath: item.ref_path }),
            createdAt: item.created_at, read: !!item.read,
          },
          notifyDesktop,
        });
      },
      onPluginUpdated: (pluginId, state) => {
        void this.orchestrator.bus.publish('plugin.updated', { pluginId, state });
        void this.syncPluginSubscriptions().catch(() => {});
      },
    });

    this.orchestrator.setStatusContributor(() => this.extraStatus());

    const memoryExtensions: IpcV3Extensions = {
      'memory.get': ({ target }) => {
        const resolved = this.resolveMemoryTarget(target);
        const text = this.memoryStore.get(resolved);
        const path = this.memoryStore.pathFor(resolved);
        if (Buffer.byteLength(text, 'utf8') <= MAX_INLINE_DOCUMENT_BYTES) return { text, path };
        return { path };
      },
      'memory.save': ({ target, content }) => {
        const resolved = this.resolveMemoryTarget(target);
        const text = this.extractMemoryContent(content);
        const rev = this.memoryStore.save(resolved, text, { source: 'manual', summary: '手动保存档案' });
        this.orchestrator.invalidatePromptCache();
        return toRpcRevision(rev);
      },
      'memory.setEntryLock': ({ target, entryId, locked }) => {
        const rev = this.memoryStore.setEntryLock(this.resolveMemoryTarget(target), entryId, locked);
        this.orchestrator.invalidatePromptCache();
        return toRpcRevision(rev);
      },
      'memory.setEntryVisibility': ({ target, entryId, visibility }) => {
        const rev = this.memoryStore.setEntryVisibility(this.resolveMemoryTarget(target), entryId, visibility);
        this.orchestrator.invalidatePromptCache();
        return toRpcRevision(rev);
      },
      'memory.consolidateNow': async ({ conversationId, backfill }) => {
        const target = this.scopeTarget(conversationId);
        let history: NormalizedEvent[] | undefined;
        if (backfill) {
          const req: BackfillRequest = { ...backfill, conversationId, purpose: 'memory' };
          history = await this.orchestrator.fetchBackfillEvents(req);
        }
        const rev = history
          ? await this.consolidator.initializeFromHistory(target, history)
          : await this.consolidator.consolidateNow(target);
        if (rev) this.orchestrator.invalidatePromptCache();
        return rev ? toRpcRevision(rev) : null;
      },
      'memory.revisions': ({ target, cursor, limit = 50 }) => {
        const resolved = this.resolveMemoryTarget(target);
        const offset = parseCursor(cursor);
        const rows = this.orchestrator.journal.listMemoryRevisions(resolved.kind, memoryScopeKey(resolved), limit + 1, offset);
        return {
          items: rows.slice(0, limit).map(toRpcRevision),
          nextCursor: rows.length > limit ? String(offset + limit) : null,
        };
      },
      'memory.rollback': ({ target, revId }) =>
        toRpcRevision(this.memoryStore.rollback(this.resolveMemoryTarget(target), revId)),
      'persona.proposals': ({ cursor, limit = 50 }) => {
        const offset = parseCursor(cursor);
        const rows = this.orchestrator.journal.listPersonaProposals(undefined, limit + 1, offset);
        return {
          items: rows.slice(0, limit).map(toRpcProposal),
          nextCursor: rows.length > limit ? String(offset + limit) : null,
        };
      },
      'persona.decide': params => {
        const updated = params.decision === 'accept_edited'
          ? this.persona.decide(params.proposalId, 'accept_edited', this.extractMemoryContent(params.content))
          : this.persona.decide(params.proposalId, params.decision);
        const result = toRpcProposal(updated);
        this.publishProposals(result);
        return result;
      },
    };

    const pluginExtensions: IpcV3Extensions = {
      ...this.plugins.extensions,
      'plugins.saveDeclarative': params => {
        const ok = this.plugins.saveDeclarative(params);
        void this.syncPluginSubscriptions().catch(() => {});
        return ok;
      },
      'plugins.deleteDeclarative': params => {
        const ok = this.plugins.deleteDeclarative(params);
        void this.syncPluginSubscriptions().catch(() => {});
        return ok;
      },
      'plugins.setEnabled': params => {
        const ok = this.plugins.setEnabled(params);
        void this.syncPluginSubscriptions().catch(() => {});
        return ok;
      },
    };

    const systemExtensions: IpcV3Extensions = {
      'system.bundles': ({ action }) => {
        if (action === 'reload') {
          const status = this.bundles.reload();
          this.orchestrator.modelRouter.setReasoningEffortDisabled(this.bundles.disabledReasoningEffortUrls());
          this.orchestrator.invalidatePromptCache();
          return status;
        }
        return this.bundles.status();
      },
    };

    this.router = new IpcV3Router(this.orchestrator, sink, { ...pluginExtensions, ...memoryExtensions, ...systemExtensions });

    // 监听事件总线，统一驱动后链路插件、L2 记忆整理和 L3 人格学习。
    this.unsubscribes.push(
      this.orchestrator.bus.subscribe('message', event => this.onNormalizedEvent(event)),
      this.orchestrator.bus.subscribe('recall', event => this.onNormalizedEvent(event)),
    );

    if (settings.runtime.autoResumeReadOnlyPlugins) {
      void this.syncPluginSubscriptions().catch(() => {});
    }
  }

  hello() { this.router.hello(); }

  route(line: string | Uint8Array) { return this.router.route(line); }

  private resolveMemoryDir(settings: SettingsV2) {
    return settings.memory.baseDir.trim() || join(this.stateDir, 'memory');
  }

  private memoryPresetId(settings: SettingsV2) {
    return settings.defaultModels.memoryPresetId ?? settings.defaultModels.replyPresetId;
  }

  private memoryMode(settings: SettingsV2): 'local' | 'cloud' {
    const id = this.memoryPresetId(settings);
    return settings.models.find(m => m.id === id)?.mode ?? 'local';
  }

  private isCloudPresetApproved(presetId?: string) {
    if (!presetId) return false;
    const settings = this.orchestrator.currentSettings;
    const preset = settings.models.find(m => m.id === presetId);
    if (!preset) return false;
    if (preset.mode === 'local') return true;
    return settings.runtime.approvedCloudPresetIds.includes(preset.id);
  }

  private approvedCloudKey(preset: ModelPreset) {
    const credential = this.cloudKeys.get(preset.id);
    if (preset.mode === 'cloud' && credential?.url === preset.url && credential.kind === preset.kind &&
      this.isCloudPresetApproved(preset.id)) return credential.key;
  }

  private handleSettingsApplied(next: SettingsV2, cloudApiKeys?: Record<string, string>) {
    const approved = new Set(next.runtime.approvedCloudPresetIds);
    const validCloudPresets = new Map(next.models.filter(m => m.mode === 'cloud' && approved.has(m.id)).map(m => [m.id, m]));
    for (const [id, credential] of this.cloudKeys) {
      const preset = validCloudPresets.get(id);
      if (preset?.url !== credential.url || preset.kind !== credential.kind) this.cloudKeys.delete(id);
    }
    if (cloudApiKeys) {
      for (const [id, key] of Object.entries(cloudApiKeys)) {
        const preset = validCloudPresets.get(id);
        if (preset) this.cloudKeys.set(id, { url: preset.url, kind: preset.kind, key });
      }
    }
    const nextDir = this.resolveMemoryDir(next);
    if (nextDir !== this.memoryDir) {
      this.memoryDir = nextDir;
      this.memoryStore = new MemoryStore(this.memoryDir, this.orchestrator.journal);
      this.assembler = new PromptContextAssembler(this.memoryStore);
    }
    this.consolidator.dispose();
    this.persona.dispose();
    this.consolidator = this.createConsolidator(next);
    this.persona = this.createPersona(next);
  }

  private completeMemoryJson = (system: string, user: string, signal?: AbortSignal) => {
    const settings = this.orchestrator.currentSettings;
    const presetId = this.memoryPresetId(settings);
    if (!presetId) throw new BridgeError('invalid-configuration');
    return this.orchestrator.modelRouter.summarize(presetId, system, user, {
      signal, priority: 'background', cloudApproved: this.isCloudPresetApproved(presetId),
    });
  };

  private createConsolidator(settings: SettingsV2) {
    return new MemoryConsolidator({
      store: this.memoryStore,
      journal: this.orchestrator.journal,
      completeJson: this.completeMemoryJson,
      mode: this.memoryMode(settings),
      autoConsolidateIdleMinutes: settings.memory.autoConsolidateIdleMinutes,
      autoConsolidateTurnThreshold: settings.memory.autoConsolidateTurnThreshold,
    });
  }

  private createPersona(settings: SettingsV2) {
    return new PersonaEvolver({
      store: this.memoryStore,
      journal: this.orchestrator.journal,
      completeJson: this.completeMemoryJson,
      mode: this.memoryMode(settings),
      autoMergePersona: settings.memory.autoMergePersona,
      resolveIdentity: () => this.orchestrator.currentIdentity,
    });
  }

  private resolveMemoryTarget(target: { kind: 'persona' } | { kind: 'scope'; conversationId: string }): MemoryTarget {
    if (target.kind === 'persona') return { kind: 'persona' };
    return this.scopeTarget(target.conversationId);
  }

  private scopeTarget(conversationId: string): ScopeTarget {
    const settings = this.orchestrator.currentSettings;
    const accountId = settings.xiaohe.accountId;
    if (!accountId) throw new BridgeError('invalid-configuration');
    const policy = settings.conversations[conversationId];
    return {
      kind: 'scope', accountId, conversationId,
      scopeType: policy?.type, label: policy?.label,
    };
  }

  private extractMemoryContent(content: { text?: string; path?: string }) {
    if (typeof content.text === 'string') return content.text;
    if (content.path) {
      const safe = resolveContainedPath(this.memoryDir, content.path);
      if (!existsSync(safe)) throw new BridgeError('profile-unreadable');
      return readPrivateFile(safe, 48 * 1024).toString('utf8');
    }
    throw new BridgeError('invalid-configuration');
  }

  private async assemblePrompt(policy: ConversationPolicy, mode: 'local' | 'cloud') {
    const settings = this.orchestrator.currentSettings;
    const accountId = settings.xiaohe.accountId;
    const target: ScopeTarget | undefined = accountId
      ? { kind: 'scope', accountId, conversationId: policy.conversationId, scopeType: policy.type, label: policy.label }
      : undefined;
    const base = {
      mode, target,
      workingMaxMessages: settings.memory.workingMaxMessages,
      workingTtlMinutes: settings.memory.workingTtlMinutes,
    };
    let assembled;
    try {
      assembled = await this.assembler.assemble({
        ...base,
        legacyStylePath: settings.memory.legacyStylePath || undefined,
        legacyMemoryPath: settings.memory.legacyMemoryPath || undefined,
      });
    } catch (error) {
      // 迁移遗留的旧版外部档案未加云端标记或不可读时，自动跳过旧档案并沿用 v2 托管记忆，不再误杀整条自动回复。
      const code = error instanceof BridgeError ? error.code : undefined;
      if (code === 'cloud-profile' || code === 'profile-unreadable') {
        assembled = await this.assembler.assemble(base);
      } else {
        throw error;
      }
    }
    const addon = this.bundles.replyPromptAddon();
    const style = [assembled.style, addon].filter(Boolean).join('\n').slice(0, 1500);
    return { style: style || undefined, memory: assembled.memory || undefined };
  }

  private onNormalizedEvent(event: NormalizedEvent) {
    if (this.closed) return;
    void this.plugins.handleEvent(event).catch(() => {});
    const policy = this.orchestrator.currentSettings.conversations[event.conversationId];
    if (policy?.memoryEnabled) {
      const target = this.scopeTarget(event.conversationId);
      this.consolidator.ingest(target, event);
    }
    if (event.isSelf || event.kind === 'recall') {
      this.persona.ingestSample({ ...event, identity: this.orchestrator.currentIdentity });
    }
  }

  private extraStatus(): { plugins: Record<string, PluginRuntimeState>; activePluginCount: number; pendingProposalCount: number } {
    if (this.closed) return { plugins: {}, activePluginCount: 0, pendingProposalCount: 0 };
    const list = this.plugins.list();
    const plugins: Record<string, PluginRuntimeState> = {};
    let activePluginCount = 0;
    for (const item of list) {
      plugins[item.pluginId] = item.state;
      if (item.state.enabled && !item.state.circuitOpen) activePluginCount++;
    }
    const pendingProposalCount = this.orchestrator.journal.listPersonaProposals('pending', 500, 0).length;
    return { plugins, activePluginCount, pendingProposalCount };
  }

  private publishProposals(latestProposal?: RpcResult<'persona.proposals'>['items'][number]) {
    const pendingCount = this.orchestrator.journal.listPersonaProposals('pending', 500, 0).length;
    void this.orchestrator.bus.publish('proposal.updated', { pendingCount, ...(latestProposal && { latestProposal }) });
  }

  private async syncPluginSubscriptions() {
    if (this.closed) return;
    const settings = this.orchestrator.currentSettings;
    if (!settings.xiaohe.mcpUrl || !settings.xiaohe.accountId) return;
    const needed = new Set<string>();
    for (const item of this.plugins.list()) {
      if (!item.state.enabled || item.state.circuitOpen) continue;
      for (const policy of Object.values(settings.conversations)) {
        if (!policy.enabled) continue;
        if (item.kind === 'module') {
          if (item.state.approvedPermissions.includes('read_events')) needed.add(policy.conversationId);
        } else {
          const scope = item.config.scope;
          if (scope.conversationIds.includes(policy.conversationId) || scope.includeTypes?.includes(policy.type) ||
              policy.pluginIds.includes(item.pluginId)) {
            needed.add(policy.conversationId);
          }
        }
      }
    }
    await this.orchestrator.setReadOnlySubscriptions(needed);
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    for (const unsub of this.unsubscribes) unsub();
    this.router.close();
    this.consolidator.dispose();
    this.persona.dispose();
    await this.plugins.dispose();
    await this.orchestrator.close();
  }
}
