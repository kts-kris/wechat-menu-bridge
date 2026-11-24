import { z } from 'zod';
import { modelSchema } from '../../contracts.ts';
import { errorCodeSchema } from './errors.ts';
import {
  backfillProgressSchema, backfillRequestSchema, identifierSchema, scopeTypeSchema, timestampSchema, xiaoheCapabilitiesSchema,
} from './events.ts';
import { declarativePluginConfigSchema, pluginManifestSchema, pluginPermissionSchema, webhookPlatformSchema } from './plugins.ts';
import { settingsV2Schema } from './settings.ts';

export const IPC_VERSION = 3;
export const MAX_FRAME_BYTES = 256 * 1024;
export const MAX_INLINE_DOCUMENT_BYTES = 64 * 1024;

const count = z.number().int().nonnegative();
const empty = z.strictObject({});
const ok = z.literal(true);
const session = z.strictObject({ conversationId: identifierSchema });
const plugin = z.strictObject({ pluginId: identifierSchema });
const page = { cursor: z.string().optional(), limit: z.number().int().min(1).max(500).optional() };
const paginated = <T extends z.ZodType>(item: T) => z.strictObject({
  items: z.array(item), nextCursor: z.string().nullable(),
});
const range = z.strictObject({ startTime: timestampSchema, endTime: timestampSchema })
  .refine(value => value.startTime <= value.endTime);
const secret = modelSchema.shape.apiKey;

export const receiptSchema = z.strictObject({
  status: z.enum(['trying', 'submitted', 'unknown', 'rejected']),
  delivery: z.enum(['delivered', 'failed', 'unknown']),
  operationId: identifierSchema.optional(),
});
export const sessionRuntimeStateSchema = z.strictObject({
  phase: z.enum(['idle', 'connecting', 'listening', 'retrying', 'generating', 'scheduled',
    'checking', 'sending', 'paused', 'cooldown', 'blocked-unknown', 'locked-opt-out']),
  replyMode: z.enum(['off', 'draft', 'auto']),
  reason: errorCodeSchema.optional(),
  draft: z.string().optional(),
  scheduledAt: timestampSchema.optional(),
  cooldownUntil: timestampSchema.optional(),
  receipt: receiptSchema.optional(),
});
export const pluginRuntimeStateSchema = z.strictObject({
  kind: z.enum(['declarative', 'module']),
  enabled: z.boolean(),
  approvedPermissions: z.array(pluginPermissionSchema),
  manifestHash: z.string().optional(),
  consecutiveFailures: count,
  circuitOpen: z.boolean(),
  lastRunAt: timestampSchema.optional(),
  lastError: errorCodeSchema.optional(),
});
export const feedItemSchema = z.strictObject({
  id: identifierSchema,
  kind: z.enum(['plugin_digest', 'persona_proposal', 'memory_updated', 'alert', 'schedule_cancelled']),
  title: z.string(),
  body: z.string().max(2000),
  conversationId: identifierSchema.optional(),
  pluginId: identifierSchema.optional(),
  refPath: z.string().optional(),
  createdAt: timestampSchema,
  read: z.boolean(),
});
const proposal = z.strictObject({
  proposalId: identifierSchema,
  status: z.enum(['pending', 'accepted', 'rejected', 'superseded']),
  filePath: z.string(),
  sampleCount: count,
  summary: z.string(),
  createdAt: timestampSchema,
  decidedAt: timestampSchema.optional(),
});
const globalState = z.strictObject({
  phase: z.enum(['idle', 'connecting', 'running', 'paused', 'error']),
  activeAutoCount: count, activePluginCount: count, inFlightCount: count, error: errorCodeSchema.optional(),
});
const status = z.strictObject({
  capabilities: xiaoheCapabilitiesSchema,
  globalPhase: globalState.shape.phase,
  sessions: z.record(identifierSchema, sessionRuntimeStateSchema),
  plugins: z.record(identifierSchema, pluginRuntimeStateSchema),
  unreadFeedCount: count,
  pendingProposalCount: count,
});

export const sessionTraceEntrySchema = z.strictObject({
  id: identifierSchema,
  conversationId: identifierSchema,
  at: timestampSchema,
  stage: z.enum(['inbound', 'policy', 'model', 'send', 'state']),
  level: z.enum(['info', 'warn', 'error']),
  summary: z.string().max(300),
  detail: z.string().max(500).optional(),
});
export type SessionTraceEntry = z.infer<typeof sessionTraceEntrySchema>;

export const healthCheckStepSchema = z.strictObject({
  id: z.enum(['xiaohe', 'whitelist', 'credentials', 'model']),
  label: z.string(),
  ok: z.boolean(),
  durationMs: count,
  detail: z.string().max(400),
});
export type HealthCheckStep = z.infer<typeof healthCheckStepSchema>;

export const pushPayloadSchemas = {
  hello: status.extend({ v: z.literal(IPC_VERSION) }),
  'session.updated': session.extend({ status: sessionRuntimeStateSchema }),
  'session.trace': z.strictObject({ entry: sessionTraceEntrySchema }),
  'global.updated': globalState,
  'feed.added': z.strictObject({ item: feedItemSchema, notifyDesktop: z.boolean() }),
  'plugin.updated': plugin.extend({ state: pluginRuntimeStateSchema }),
  'proposal.updated': z.strictObject({ pendingCount: count, latestProposal: proposal.optional() }),
  'backfill.progress': backfillProgressSchema.extend({ error: errorCodeSchema.optional() }),
} as const;

export const PUSH_TOPICS = Object.keys(pushPayloadSchemas) as (keyof typeof pushPayloadSchemas)[];
const envelope = z.strictObject({ v: z.literal(IPC_VERSION) });
export type PushTopic = keyof typeof pushPayloadSchemas;
export type PushPayload<T extends PushTopic> = z.infer<(typeof pushPayloadSchemas)[T]>;
export type PushFrame<T extends PushTopic = PushTopic> = {
  [K in T]: { v: 3; kind: 'event'; topic: K; payload: PushPayload<K> };
}[T];
export const pushFrameSchema = envelope.extend({
  kind: z.literal('event'),
  topic: z.enum(PUSH_TOPICS),
  payload: z.unknown(),
}).transform((frame, ctx) => {
  const parsed = pushPayloadSchemas[frame.topic].safeParse(frame.payload);
  if (!parsed.success) {
    ctx.addIssue({ code: 'custom', path: ['payload'], message: 'Invalid push payload' });
    return z.NEVER;
  }
  return { ...frame, payload: parsed.data } as PushFrame;
});

const account = z.strictObject({
  id: identifierSchema, label: z.string(), canRead: z.boolean(), canSend: z.boolean(),
  sendConversations: z.array(identifierSchema).optional(),
});
const conversation = z.strictObject({
  conversationId: identifierSchema, type: scopeTypeSchema, displayName: z.string(),
  nickname: z.string().optional(), remark: z.string().optional(), isSticky: z.boolean().optional(),
});
const groupMember = z.strictObject({ userId: identifierSchema, displayName: z.string() });
const pluginItem = z.discriminatedUnion('kind', [
  plugin.extend({ kind: z.literal('declarative'), config: declarativePluginConfigSchema, state: pluginRuntimeStateSchema }),
  plugin.extend({ kind: z.literal('module'), manifest: pluginManifestSchema, state: pluginRuntimeStateSchema }),
]);
const pluginRun = plugin.extend({
  runId: identifierSchema, triggerKind: z.enum(['realtime', 'window_time', 'window_count', 'manual']),
  startedAt: timestampSchema, finishedAt: timestampSchema.optional(),
  status: z.enum(['running', 'ok', 'skipped', 'error']), itemCount: count,
  summaryPreview: z.string().max(500).optional(), outputPaths: z.array(z.string()).optional(),
  errorCode: errorCodeSchema.optional(),
});
const memoryTarget = z.discriminatedUnion('kind', [
  z.strictObject({ kind: z.literal('persona') }),
  session.extend({ kind: z.literal('scope') }),
]);
const inlineText = z.string().refine(text => new TextEncoder().encode(text).byteLength <= MAX_INLINE_DOCUMENT_BYTES);
const memoryContent = z.union([
  z.strictObject({ text: inlineText, path: z.string().optional() }),
  z.strictObject({ path: z.string() }),
]);
const revision = z.strictObject({
  revId: identifierSchema, targetKind: z.enum(['persona', 'scope']), scopeKey: identifierSchema,
  snapshotPath: z.string(), source: z.enum(['auto', 'backfill', 'proposal_accepted', 'manual', 'rollback']),
  summary: z.string(), diffPreview: z.string(), createdAt: timestampSchema,
});

export const hotBundleItemSchema = z.strictObject({
  name: z.string(),
  sha256: z.string(),
  verified: z.boolean(),
});
export const hotBundlesStatusSchema = z.strictObject({
  loadedCount: count,
  version: z.string().optional(),
  lastReloadAt: timestampSchema.optional(),
  items: z.array(hotBundleItemSchema),
});

export const rpcSchemas = {
  'system.status': { params: empty, result: status },
  'system.bundles': {
    params: z.strictObject({
      action: z.enum(['status', 'reload', 'sync', 'reset']),
      manifestUrl: z.url({ protocol: /^https$/ }).optional(),
    }),
    result: hotBundlesStatusSchema,
  },
  'system.healthCheck': {
    params: z.strictObject({ presetId: identifierSchema.optional(), conversationId: identifierSchema.optional() }),
    result: z.strictObject({ ok: z.boolean(), steps: z.array(healthCheckStepSchema) }),
  },
  'system.pauseAll': { params: z.strictObject({ scope: z.enum(['sending_only', 'all']), reason: errorCodeSchema }), result: ok },
  'xiaohe.accounts': { params: z.strictObject({ mcpUrl: z.string().optional() }), result: z.array(account) },
  'xiaohe.conversations': {
    params: z.strictObject({ accountId: identifierSchema.optional(), query: z.string().optional(), type: scopeTypeSchema.optional(), ...page }),
    result: paginated(conversation).extend({ syncStatus: z.string().optional() }),
  },
  'xiaohe.groupMembers': { params: session, result: z.array(groupMember) },
  'xiaohe.capabilities': { params: empty, result: xiaoheCapabilitiesSchema },
  'settings.apply': {
    params: z.strictObject({
      settings: settingsV2Schema,
      cloudApiKeys: z.record(identifierSchema, z.string().regex(/^[\x21-\x7e]{1,4096}$/)).optional(),
    }),
    result: ok,
  },
  'model.preview': {
    params: z.strictObject({ model: modelSchema, text: z.string().trim().min(1).max(400) }),
    result: z.strictObject({ action: z.enum(['reply', 'skip', 'manual', 'stop', 'identity']), text: z.string().optional() }),
  },
  'session.arm': {
    params: session.extend({
      replyMode: z.enum(['draft', 'auto']), consent: z.literal(true), cloudApproved: z.boolean().optional(),
      groupConfirmed: z.boolean().optional(), apiKey: secret,
    }), result: ok,
  },
  'session.pause': { params: session.extend({ reason: errorCodeSchema.optional() }), result: ok },
  'session.resumeCooldown': { params: session, result: ok },
  'session.traces': {
    params: z.strictObject({ conversationId: identifierSchema, limit: z.number().int().min(1).max(100).optional() }),
    result: z.strictObject({ items: z.array(sessionTraceEntrySchema) }),
  },
  'session.sendOneShot': {
    params: session.extend({
      text: z.string().trim().min(1).max(500).regex(/^[^\p{Cc}]+$/u), request: z.uuid(), at: timestampSchema.optional(),
      consent: z.literal(true), groupConfirmed: z.boolean().optional(),
    }), result: ok,
  },
  'session.refreshReceipt': { params: session, result: receiptSchema },
  'session.recover': {
    params: session.extend({ action: z.enum(['reset-read', 'restore-consent', 'acknowledge']), confirmed: z.literal(true) }),
    result: ok,
  },
  'session.backfill': {
    params: z.discriminatedUnion('action', [
      z.strictObject({ action: z.literal('start'), request: backfillRequestSchema }),
      z.strictObject({ action: z.literal('cancel'), jobId: identifierSchema }),
    ]), result: z.strictObject({ jobId: identifierSchema }),
  },
  'plugins.list': { params: empty, result: z.array(pluginItem) },
  'plugins.saveDeclarative': { params: z.strictObject({ config: declarativePluginConfigSchema }), result: ok },
  'plugins.deleteDeclarative': { params: plugin, result: ok },
  'plugins.setEnabled': {
    params: plugin.extend({
      enabled: z.boolean(), approvedPermissions: z.array(pluginPermissionSchema).optional(), manifestHash: z.string().optional(),
    }), result: ok,
  },
  'plugins.runNow': {
    params: plugin.extend({ conversationId: identifierSchema.optional(), range: range.optional() }),
    result: z.strictObject({ runId: identifierSchema }),
  },
  'plugins.runs': { params: plugin.extend(page), result: paginated(pluginRun) },
  'plugins.testWebhook': {
    params: z.strictObject({
      pluginId: identifierSchema,
      sinkId: identifierSchema,
      url: z.url({ protocol: /^https?$/ }),
      platform: webhookPlatformSchema.optional(),
      secret: z.string().regex(/^[\x20-\x7e]{1,4096}$/).optional(),
    }),
    result: z.strictObject({
      ok: z.boolean(),
      statusCode: z.number().int().nonnegative().optional(),
      detail: z.string().max(300),
    }),
  },
  'memory.get': { params: z.strictObject({ target: memoryTarget }), result: memoryContent },
  'memory.save': { params: z.strictObject({ target: memoryTarget, content: memoryContent }), result: revision },
  'memory.setEntryLock': {
    params: z.strictObject({ target: memoryTarget, entryId: identifierSchema, locked: z.boolean() }), result: revision,
  },
  'memory.setEntryVisibility': {
    params: z.strictObject({ target: memoryTarget, entryId: identifierSchema, visibility: z.enum(['local-only', 'cloud-safe']) }),
    result: revision,
  },
  'memory.consolidateNow': { params: session.extend({ backfill: backfillRequestSchema.optional() }), result: revision.nullable() },
  'memory.revisions': { params: z.strictObject({ target: memoryTarget, ...page }), result: paginated(revision) },
  'memory.rollback': { params: z.strictObject({ target: memoryTarget, revId: identifierSchema }), result: revision },
  'persona.proposals': { params: z.strictObject(page), result: paginated(proposal) },
  'persona.decide': {
    params: z.discriminatedUnion('decision', [
      z.strictObject({ proposalId: identifierSchema, decision: z.enum(['accept', 'reject']) }),
      z.strictObject({ proposalId: identifierSchema, decision: z.literal('accept_edited'), content: memoryContent }),
    ]), result: proposal,
  },
  'feed.list': { params: z.strictObject({ ...page, unreadOnly: z.boolean().optional() }), result: paginated(feedItemSchema) },
  'feed.markRead': { params: z.strictObject({ ids: z.array(identifierSchema).min(1) }), result: ok },
} as const;

export type SessionRuntimeState = z.infer<typeof sessionRuntimeStateSchema>;
export type PluginRuntimeState = z.infer<typeof pluginRuntimeStateSchema>;
export type FeedItem = z.infer<typeof feedItemSchema>;
export type RpcMethod = keyof typeof rpcSchemas;
export const RPC_METHODS = Object.keys(rpcSchemas) as RpcMethod[];
export type RpcParams<M extends RpcMethod> = z.infer<(typeof rpcSchemas)[M]['params']>;
export type RpcResult<M extends RpcMethod> = z.infer<(typeof rpcSchemas)[M]['result']>;
export type RpcRequest<M extends RpcMethod = RpcMethod> = {
  [K in M]: { v: 3; id: number; method: K; params: RpcParams<K> };
}[M];
export const rpcRequestSchema = envelope.extend({
  id: z.number().int(), method: z.enum(RPC_METHODS), params: z.unknown(),
}).transform((frame, ctx) => {
  const parsed = rpcSchemas[frame.method].params.safeParse(frame.params);
  if (!parsed.success) {
    ctx.addIssue({ code: 'custom', path: ['params'], message: 'Invalid RPC parameters' });
    return z.NEVER;
  }
  return { ...frame, params: parsed.data } as RpcRequest;
});
export function rpcReplySchema<M extends RpcMethod>(method: M) {
  const reply = envelope.extend({ kind: z.literal('reply'), id: z.number().int() });
  return z.discriminatedUnion('ok', [
    reply.extend({ ok: z.literal(true), result: rpcSchemas[method].result }),
    reply.extend({ ok: z.literal(false), code: errorCodeSchema }),
  ]);
}
export type RpcReply<M extends RpcMethod> = z.infer<ReturnType<typeof rpcReplySchema<M>>>;
