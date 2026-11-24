import { BridgeError } from '../contracts/errors.ts';
import type { NormalizedEvent } from '../contracts/events.ts';
import type { DeclarativePluginConfig } from '../contracts/plugins.ts';
import type { JournalV2, PluginBuffer, PluginRun } from '../storage/journal-v2.ts';

const MINUTE = 60_000;
const messageKinds = ['text', 'image', 'voice', 'link', 'file'] as const;
export type PluginMessage = Omit<PluginBuffer, 'id' | 'recalled' | 'plugin_id'>;
export type WindowBatch = {
  items: PluginBuffer[];
  throughId: number;
  trigger: Extract<PluginRun['trigger_kind'], 'window_time' | 'window_count'>;
};

export function matchesScope(config: DeclarativePluginConfig, event: NormalizedEvent) {
  const { conversationIds, includeTypes, excludeSelf, kinds } = config.scope;
  const inScope = conversationIds.includes(event.conversationId) || !!includeTypes?.includes(event.scopeType);
  return inScope && !(excludeSelf && event.isSelf) &&
    event.kind !== 'recall' && (kinds ?? messageKinds).some(kind => kind === event.kind);
}

export function messageForPlugin(event: NormalizedEvent): PluginMessage {
  const content = [event.text, event.media?.caption, event.media?.transcript, event.link?.url]
    .filter((value): value is string => !!value?.trim());
  if (event.mentions.mentionsSelf) content.unshift('[@我]');
  return {
    conversation_id: event.conversationId, event_id: event.eventId, message_ref: event.messageRef,
    sender_label: event.senderLabel, is_self: event.isSelf ? 1 : 0, kind: event.kind,
    content: [...new Set(content)].join(' '), created_at: event.createdAt,
  };
}

export function validateTrigger(trigger: DeclarativePluginConfig['trigger']) {
  if (trigger.type === 'realtime' && trigger.regex !== undefined) {
    try { new RegExp(trigger.regex, 'u'); }
    catch { throw new BridgeError('invalid-configuration'); }
  }
  if (trigger.type === 'window_time' && !trigger.everyMinutes && !trigger.timesOfDay?.length) {
    throw new BridgeError('invalid-configuration');
  }
}

function hasClockBoundary(times: readonly string[], since: number, now: number) {
  const today = new Date(now);
  return times.some(time => {
    const [hour, minute] = time.split(':').map(Number);
    const boundary = new Date(today);
    boundary.setHours(hour!, minute!, 0, 0);
    if (boundary.getTime() > now) boundary.setDate(boundary.getDate() - 1);
    return boundary.getTime() >= since;
  });
}

export class WindowScheduler {
  constructor(private readonly journal: JournalV2) {}

  recall(event: NormalizedEvent) {
    if (event.kind === 'recall' && event.recallTargetRef) {
      this.journal.markPluginBufferRecalled(event.conversationId, event.recallTargetRef);
    }
  }

  accept(config: DeclarativePluginConfig, event: NormalizedEvent): PluginMessage | undefined {
    if (event.origin !== 'live' || !matchesScope(config, event)) return;
    const { trigger } = config;
    const message = messageForPlugin(event);
    if (trigger.type === 'realtime') {
      if (trigger.mentionSelfOnly && !event.mentions.mentionsSelf) return;
      if (trigger.keywords?.length && !trigger.keywords.some(word => message.content.includes(word))) return;
      if (trigger.regex !== undefined && !new RegExp(trigger.regex, 'u').test(message.content.slice(0, 8192))) return;
      return message;
    }
    if (trigger.type !== 'manual_only') this.journal.addPluginBuffer({ ...message, plugin_id: config.id });
  }

  due(config: DeclarativePluginConfig, now: number): WindowBatch | undefined {
    const { trigger } = config;
    if (trigger.type !== 'window_time' && trigger.type !== 'window_count') return;
    const snapshot = this.journal.snapshotPluginBuffers(config.id);
    const first = snapshot.items[0];
    if (!first) {
      if (snapshot.throughId) this.clear(config.id, snapshot.throughId);
      return;
    }
    if (snapshot.items.length < trigger.minMessages) return;
    const elapsed = now - first.created_at;
    const ready = trigger.type === 'window_count'
      ? snapshot.items.length >= trigger.count || elapsed >= trigger.maxWaitMinutes * MINUTE
      : (!!trigger.everyMinutes && elapsed >= trigger.everyMinutes * MINUTE) ||
        hasClockBoundary(trigger.timesOfDay ?? [], first.created_at, now);
    if (ready) return { ...snapshot, trigger: trigger.type };
  }

  current(pluginId: string, throughId: number) {
    return this.journal.listPluginBuffers(pluginId).filter(item => item.id <= throughId);
  }

  clear(pluginId: string, throughId?: number) { this.journal.clearPluginBuffers(pluginId, throughId); }
}
