import { z } from 'zod';
import { id } from '../../contracts.ts';

export const identifierSchema = z.string().refine(id);
export const scopeTypeSchema = z.enum(['direct', 'group', 'service']);
export const eventOriginSchema = z.enum(['live', 'backfill']);
export const messageKindSchema = z.enum(['text', 'image', 'voice', 'link', 'file', 'recall', 'system']);
export const timestampSchema = z.number().int().nonnegative();

export const normalizedEventSchema = z.strictObject({
  eventId: identifierSchema,
  messageRef: identifierSchema,
  origin: eventOriginSchema,
  accountId: identifierSchema,
  conversationId: identifierSchema,
  scopeType: scopeTypeSchema,
  senderId: z.string(),
  senderLabel: z.string(),
  isSelf: z.boolean(),
  clientRequestId: identifierSchema.optional(),
  kind: messageKindSchema,
  text: z.string(),
  rawText: z.string().optional(),
  media: z.strictObject({
    mimeType: z.string().optional(),
    localTempPath: z.string().optional(),
    caption: z.string().optional(),
    transcript: z.string().optional(),
    enrichmentStatus: z.enum(['none', 'ok', 'degraded', 'failed']),
  }).optional(),
  link: z.strictObject({ title: z.string().optional(), url: z.string().optional(), description: z.string().optional() }).optional(),
  quote: z.strictObject({ targetRef: identifierSchema.optional(), excerpt: z.string().optional() }).optional(),
  mentions: z.strictObject({ ids: z.array(identifierSchema), mentionsSelf: z.boolean() }),
  recallTargetRef: identifierSchema.optional(),
  createdAt: timestampSchema,
  observedAt: timestampSchema,
  seenAt: timestampSchema,
});

export const xiaoheCapabilitiesSchema = z.strictObject({
  accountWideEvents: z.boolean(),
  listConversations: z.boolean(),
  groupMembers: z.boolean(),
  historyQuery: z.boolean(),
  historySearch: z.boolean(),
  readMedia: z.boolean(),
  nativeReply: z.boolean(),
  mentionSend: z.boolean(),
  canSendText: z.boolean(),
});

// 小禾可增添字段。保留原始附件元数据，归一化之前仍需按媒体类型检查。
export const xiaoheEventSchema = z.looseObject({
  event_id: identifierSchema,
  event_type: identifierSchema,
  message_ref: identifierSchema,
  conversation_id: identifierSchema,
  account_id: identifierSchema.optional(),
  sender_id: z.string().nullish(),
  sender_name: z.string().nullish(),
  is_self: z.boolean(),
  type: z.string(),
  text: z.string().nullish(),
  attachments: z.array(z.record(z.string(), z.unknown())).nullish(),
  attachment_status: z.string().nullish(),
  reply_status: z.string().nullish(),
  created_at: z.string().nullish(),
  created_at_seconds: timestampSchema.nullish(),
  observed_at: z.string(),
  status: z.string().optional(),
  client_request_id: identifierSchema.nullish(),
  recall_target_ref: identifierSchema.nullish(),
});

export const xiaoheAccountSchema = z.looseObject({
  account_id: identifierSchema,
  instance_id: identifierSchema,
  login_generation: identifierSchema,
  permissions: z.array(z.string()),
  capabilities: z.record(z.string(), z.unknown()),
  send_conversations: z.array(identifierSchema).optional(),
});

export const xiaoheConversationSchema = z.looseObject({
  conversation_id: identifierSchema,
  type: scopeTypeSchema,
  display_name: z.string().nullish(),
  nickname: z.string().nullish(),
  remark: z.string().nullish(),
  is_sticky: z.boolean().optional(),
});

export const xiaoheConversationPageSchema = z.looseObject({
  conversations: z.array(xiaoheConversationSchema),
  has_more: z.boolean(),
  next_cursor: z.string().nullish(),
  sync_status: z.string().optional(),
});

export const backfillRequestSchema = z.strictObject({
  conversationId: identifierSchema,
  recentCount: z.number().int().min(1).max(500).optional(),
  startTime: timestampSchema.optional(),
  endTime: timestampSchema.optional(),
  purpose: z.enum(['context', 'plugin', 'memory']),
}).refine(({ recentCount, startTime, endTime }) => {
  if (startTime === undefined && endTime === undefined) return true;
  return recentCount === undefined && startTime !== undefined && endTime !== undefined && endTime >= startTime;
}, { message: 'Provide a complete time range or a recent count' });

export const backfillProgressSchema = z.strictObject({
  jobId: identifierSchema,
  conversationId: identifierSchema,
  fetched: z.number().int().nonnegative(),
  done: z.boolean(),
  error: z.string().optional(),
});

export type ScopeType = z.infer<typeof scopeTypeSchema>;
export type EventOrigin = z.infer<typeof eventOriginSchema>;
export type MessageKind = z.infer<typeof messageKindSchema>;
export type NormalizedEvent = z.infer<typeof normalizedEventSchema>;
export type XiaoheCapabilities = z.infer<typeof xiaoheCapabilitiesSchema>;
export type XiaoheEvent = z.infer<typeof xiaoheEventSchema>;
export type XiaoheAccount = z.infer<typeof xiaoheAccountSchema>;
export type XiaoheConversationPage = z.infer<typeof xiaoheConversationPageSchema>;
export type BackfillRequest = z.infer<typeof backfillRequestSchema>;
export type BackfillProgress = z.infer<typeof backfillProgressSchema>;
