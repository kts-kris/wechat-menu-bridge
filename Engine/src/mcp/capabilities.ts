import { object } from '../../contracts.ts';
import type { XiaoheCapabilities } from '../contracts/events.ts';

export class CapabilityRegistry {
  private readonly schemas = new Map<string, Record<string, unknown>>();

  constructor(tools: readonly { name: string; inputSchema: unknown }[] = []) {
    for (const tool of tools) this.schemas.set(tool.name, object(tool.inputSchema) ?? {});
  }

  has(name: string) { return this.schemas.has(name); }

  private property(name: string, key: string) {
    return Object.hasOwn(object(this.schemas.get(name)?.properties) ?? {}, key);
  }

  detect(canSendText = false): XiaoheCapabilities {
    return {
      accountWideEvents: ['events.read', 'events.wait'].every(name =>
        this.property(name, 'conversation_id') &&
        !(Array.isArray(this.schemas.get(name)?.required) && (this.schemas.get(name)!.required as unknown[]).includes('conversation_id'))),
      listConversations: this.has('conversations.list'),
      groupMembers: this.has('groups.members'),
      historyQuery: this.has('messages.query'),
      historySearch: ['messages.search', 'search.global', 'messages.count'].every(name => this.has(name)),
      readMedia: this.has('messages.read_media'),
      nativeReply: this.has('messages.reply'),
      mentionSend: this.property('messages.send_text', 'mention_user_ids'),
      canSendText: this.has('messages.send_text') && canSendText,
    };
  }
}
