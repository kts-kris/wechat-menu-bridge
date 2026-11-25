import { existsSync } from 'node:fs';
import { z } from 'zod';
import { checked } from '../../contracts.ts';
import { atomicWritePrivateFile, ensurePrivateDir, readPrivateFile, resolveContainedPath } from '../storage/fs-safe.ts';
import { BridgeError } from './errors.ts';
import { identifierSchema, scopeTypeSchema } from './events.ts';

const positiveInt = z.number().int().positive();
const modeSchema = z.enum(['local', 'cloud']);
const modelKindSchema = z.enum(['chat', 'vision', 'stt']);
const addressSchema = z.url({ protocol: /^https?$/ }).refine(value => {
  const address = URL.parse(value);
  return address !== null && !address.username && !address.password && !address.search && !address.hash;
});

// 保留端口和路径前缀，使既有钥匙串的完整端点索引继续生效。
function modelEndpoint(value: string, kind: z.infer<typeof modelKindSchema>) {
  const base = value.trim().replace(/\/$/, '');
  if (!base.endsWith('/v1')) return base;
  return base + (kind === 'stt' ? '/audio/transcriptions' : '/chat/completions');
}

export const modelPresetSchema = z.strictObject({
  id: identifierSchema,
  name: z.string().min(1),
  mode: modeSchema,
  kind: modelKindSchema,
  url: addressSchema,
  modelName: z.string().trim().min(1),
  reasoningEffort: z.enum(['default', 'low', 'medium', 'high', 'max']).optional(),
  maxTokens: positiveInt.default(320),
  temperature: z.number().min(0).max(2).default(0.35),
}).transform(preset => ({ ...preset, url: modelEndpoint(preset.url, preset.kind) }));

const clockTimeSchema = z.string().regex(/^(?:[01]\d|2[0-3]):[0-5]\d$/, 'Expected HH:mm');
export const quietHoursSchema = z.strictObject({
  enabled: z.boolean().default(false),
  start: clockTimeSchema.default('23:00'),
  end: clockTimeSchema.default('08:00'),
  action: z.enum(['skip_turn', 'draft_only']).default('skip_turn'),
});
export type QuietHoursConfig = z.infer<typeof quietHoursSchema>;

const riskLevelSchema = z.enum(['recommended', 'strict', 'minimal']);
const riskProfileSchema = z.strictObject({
  level: riskLevelSchema.optional(),
  busyChatAction: z.enum(['skip_turn', 'pause_session']).default('skip_turn'),
  unparsedMediaAction: z.enum(['skip_turn', 'pause_session']).default('skip_turn'),
  takeoverAction: z.enum(['pause_session', 'cooldown', 'ignore']).default('pause_session'),
  takeoverCooldownMinutes: positiveInt.default(15),
  strictLegacyRules: z.boolean().default(false),
});

export const conversationPolicySchema = z.strictObject({
  conversationId: identifierSchema,
  label: z.string(),
  type: scopeTypeSchema,
  enabled: z.boolean(),
  replyMode: z.enum(['off', 'draft', 'auto']),
  replyPresetId: identifierSchema.optional(),
  groupTrigger: z.enum(['mention_only', 'all']).default('mention_only'),
  riskProfile: riskProfileSchema.prefault({}),
  backfillOnArmCount: z.number().int().min(0).max(500).default(10),
  memoryEnabled: z.boolean().optional(),
  pluginIds: z.array(identifierSchema).default([]),
  useNativeReply: z.boolean().default(false),
  mentionReplySender: z.boolean().default(false),
  ignoreQuietHours: z.boolean().default(false),
}).transform(policy => ({ ...policy, memoryEnabled: policy.memoryEnabled ?? policy.type === 'direct' }));

export const settingsV2Schema = z.strictObject({
  schemaVersion: z.literal(2),
  xiaohe: z.strictObject({
    mcpUrl: z.union([z.literal(''), addressSchema]),
    hasAuthToken: z.boolean().default(false),
    accountId: z.union([z.literal(''), identifierSchema]),
    accountLabel: z.string(),
  }),
  models: z.array(modelPresetSchema),
  defaultModels: z.strictObject({
    replyPresetId: identifierSchema.optional(),
    fallbackReplyPresetId: identifierSchema.optional(),
    pluginPresetId: identifierSchema.optional(),
    memoryPresetId: identifierSchema.optional(),
    visionPresetId: identifierSchema.optional(),
    sttPresetId: identifierSchema.optional(),
  }),
  conversations: z.record(identifierSchema, conversationPolicySchema),
  memory: z.strictObject({
    baseDir: z.string().default(''),
    legacyStylePath: z.string().optional(),
    legacyMemoryPath: z.string().optional(),
    workingMaxMessages: z.number().int().min(4).max(64).default(16),
    workingTtlMinutes: z.number().int().min(3).max(240).default(30),
    autoConsolidateIdleMinutes: positiveInt.default(10),
    autoConsolidateTurnThreshold: positiveInt.default(12),
    autoMergePersona: z.boolean().default(false),
  }),
  runtime: z.strictObject({
    autoResumeReadOnlyPlugins: z.boolean().default(false),
    pinnedConversationIds: z.array(identifierSchema).max(4).default([]),
    approvedCloudPresetIds: z.array(identifierSchema).default([]),
    maxConcurrentLlmCalls: positiveInt.default(3),
    fastReplyMode: z.boolean().default(false),
    quietHours: quietHoursSchema.prefault({}),
  }),
}).refine(settings => Object.entries(settings.conversations).every(([key, value]) => key === value.conversationId), {
  path: ['conversations'],
  message: 'Conversation keys must match conversationId',
});

export type ModelPreset = z.infer<typeof modelPresetSchema>;
export type ConversationPolicy = z.infer<typeof conversationPolicySchema>;
export type SettingsV2 = z.infer<typeof settingsV2Schema>;
export type RiskLevel = z.infer<typeof riskLevelSchema> | 'legacy';

// 旧版关闭 strictLegacyRules 仍会用保守的文本规则，只是不暂停整个会话。
export function riskLevel(profile: ConversationPolicy['riskProfile']): RiskLevel {
  return profile.level ?? (profile.strictLegacyRules ? 'strict' : 'legacy');
}

const SETTINGS_BYTES = 256 * 1024;

const legacySettingsSchema = z.object({
  schemaVersion: z.literal(1).optional(),
  mcp: z.string().default(''),
  account: z.string().default(''),
  accountLabel: z.string().default(''),
  contact: z.object({ id: identifierSchema, label: z.string() }).nullish(),
  mode: modeSchema.default('local'),
  modelURL: z.string().trim().default(''),
  modelName: z.string().trim().default(''),
  stylePath: z.string().optional(),
  memoryPath: z.string().optional(),
});

export function migrateSettingsV1ToV2(raw: unknown): SettingsV2 {
  const old = checked(legacySettingsSchema, raw);
  const preset = old.modelURL && old.modelName ? {
    id: 'preset-legacy-default', name: old.modelName, mode: old.mode, kind: 'chat',
    url: old.modelURL, modelName: old.modelName,
  } : undefined;
  const conversations = old.contact ? {
    [old.contact.id]: {
      conversationId: old.contact.id, label: old.contact.label, type: 'direct', enabled: false, replyMode: 'off',
    },
  } : {};
  return checked(settingsV2Schema, {
    schemaVersion: 2,
    xiaohe: { mcpUrl: old.mcp, accountId: old.account, accountLabel: old.accountLabel },
    models: preset ? [preset] : [],
    defaultModels: preset ? { replyPresetId: preset.id } : {},
    conversations,
    memory: { legacyStylePath: old.stylePath, legacyMemoryPath: old.memoryPath },
    runtime: {},
  });
}

function isLegacySettings(raw: unknown) {
  return raw === null || typeof raw !== 'object' || !('schemaVersion' in raw) || raw.schemaVersion === 1;
}

export function loadSettingsV2(raw: unknown): SettingsV2 {
  if (isLegacySettings(raw)) return migrateSettingsV1ToV2(raw);
  const settings = checked(settingsV2Schema, raw);
  for (const policy of Object.values(settings.conversations)) {
    if (policy.replyMode === 'auto') policy.replyMode = 'off';
  }
  return settings;
}

// 启动入口可调用此方法，先保全旧文件的原始字节，再原子写回新结构。
export function loadSettingsV2FromDisk(dir: string): SettingsV2 {
  ensurePrivateDir(dir);
  const path = resolveContainedPath(dir, 'settings.json');
  if (!existsSync(path)) return migrateSettingsV1ToV2({});
  const original = readPrivateFile(path, SETTINGS_BYTES);
  let raw: unknown;
  try { raw = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(original)); }
  catch { throw new BridgeError('config-unreadable'); }
  const settings = loadSettingsV2(raw);
  if (isLegacySettings(raw)) {
    const data = Buffer.from(JSON.stringify(settings) + '\n');
    if (data.length > SETTINGS_BYTES) throw new BridgeError('invalid-configuration');
    const backup = resolveContainedPath(dir, 'settings.v1.bak.json');
    if (!existsSync(backup)) atomicWritePrivateFile(backup, original);
    else if (!readPrivateFile(backup, SETTINGS_BYTES).equals(original)) throw new BridgeError('storage-unavailable');
    atomicWritePrivateFile(path, data);
  }
  return settings;
}
