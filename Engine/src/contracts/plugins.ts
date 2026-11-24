import { z } from 'zod';
import { identifierSchema, messageKindSchema, scopeTypeSchema } from './events.ts';

const positiveInt = z.number().int().positive();
const nonnegativeInt = z.number().int().nonnegative();
const httpUrl = z.url({ protocol: /^https?$/ });
const clockTime = z.string().regex(/^(?:[01]\d|2[0-3]):[0-5]\d$/);

export const webhookPlatformSchema = z.enum(['generic', 'feishu', 'wecom', 'telegram', 'notion']);

export const pluginSinkConfigSchema = z.discriminatedUnion('type', [
  z.strictObject({ id: identifierSchema, type: z.literal('app_feed'), notifyDesktop: z.boolean() }),
  z.strictObject({
    id: identifierSchema, type: z.literal('markdown_file'), directory: z.string().optional(),
    filenameTemplate: z.string().min(1), mode: z.enum(['append', 'overwrite']),
  }),
  z.strictObject({
    id: identifierSchema, type: z.literal('wechat'), targetConversationId: identifierSchema, approved: z.boolean(),
  }),
  z.strictObject({ id: identifierSchema, type: z.literal('webhook'), url: httpUrl, hasSecret: z.boolean(),
    platform: webhookPlatformSchema.optional() }),
]);

const triggerSchema = z.discriminatedUnion('type', [
  z.strictObject({
    type: z.literal('realtime'), keywords: z.array(z.string().min(1)).optional(), regex: z.string().optional(),
    mentionSelfOnly: z.boolean().optional(),
  }),
  z.strictObject({
    type: z.literal('window_time'), cron: z.string().min(1).optional(), everyMinutes: positiveInt.optional(),
    timesOfDay: z.array(clockTime).min(1).optional(), minMessages: nonnegativeInt,
  }),
  z.strictObject({
    type: z.literal('window_count'), count: positiveInt, maxWaitMinutes: positiveInt, minMessages: nonnegativeInt,
  }),
  z.strictObject({ type: z.literal('manual_only') }),
]);

export const declarativePluginConfigSchema = z.strictObject({
  id: identifierSchema,
  name: z.string().min(1),
  description: z.string(),
  enabled: z.boolean(),
  builtinTemplate: z.enum(['group-digest', 'keyword-alert', 'daily-briefing', 'custom']).optional(),
  scope: z.strictObject({
    conversationIds: z.array(identifierSchema),
    includeTypes: z.array(scopeTypeSchema).optional(),
    excludeSelf: z.boolean().optional(),
    kinds: z.array(messageKindSchema).optional(),
  }),
  trigger: triggerSchema,
  processor: z.strictObject({
    modelPresetId: identifierSchema.optional(),
    systemPrompt: z.string(),
    userPromptTemplate: z.string(),
    outputFormat: z.enum(['markdown', 'structured_digest_json']),
    skipWhenNoValue: z.boolean(),
    maxInputChars: positiveInt.default(24_000),
  }),
  sinks: z.array(pluginSinkConfigSchema),
  rateLimit: z.strictObject({ maxRunsPerHour: nonnegativeInt, maxWeChatSendsPerDay: nonnegativeInt.default(20) }),
});

export const pluginPermissionSchema = z.enum([
  'read_events', 'read_history', 'call_model', 'kv_store',
  'notify', 'write_output_file', 'send_wechat', 'webhook_fetch',
]);

export const pluginManifestSchema = z.strictObject({
  id: identifierSchema,
  name: z.string().min(1),
  version: z.string().min(1),
  entry: z.string().min(1),
  permissions: z.array(pluginPermissionSchema),
  configSchema: z.record(z.string(), z.unknown()).optional(),
});

export const groupDigestOutputSchema = z.discriminatedUnion('skip', [
  z.strictObject({ skip: z.literal(true) }),
  z.strictObject({
    skip: z.literal(false),
    headline: z.string().min(1),
    topics: z.array(z.strictObject({ title: z.string(), conclusion: z.string(), participants: z.array(z.string()) })),
    actionItems: z.array(z.strictObject({ task: z.string(), owner: z.string(), deadline: z.string() })),
    links: z.array(z.strictObject({ title: z.string(), url: httpUrl })),
    mentionsMe: z.array(z.string()),
  }),
]);

export type DeclarativePluginConfig = z.infer<typeof declarativePluginConfigSchema>;
export type PluginSinkConfig = z.infer<typeof pluginSinkConfigSchema>;
export type PluginManifest = z.infer<typeof pluginManifestSchema>;
export type PluginPermission = z.infer<typeof pluginPermissionSchema>;
export type WebhookPlatform = z.infer<typeof webhookPlatformSchema>;
export type GroupDigestOutput = z.infer<typeof groupDigestOutputSchema>;
