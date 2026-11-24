import type { NormalizedEvent } from '../contracts/events.ts';

export type PluginPermission =
  | 'read_events' | 'read_history' | 'call_model' | 'kv_store'
  | 'notify' | 'write_output_file' | 'send_wechat' | 'webhook_fetch';

export interface PluginContext {
  readonly pluginId: string;
  readonly config: Readonly<Record<string, unknown>>;
  readonly log: (level: 'info' | 'warn' | 'error', message: string) => Promise<void>;
  readonly kv: {
    get<T>(key: string): Promise<T | null>;
    set(key: string, value: unknown): Promise<void>;
  };
  readonly llm: {
    complete(request: { presetId?: string; system: string; user: string; json?: boolean }): Promise<string>;
  };
  readonly history: {
    fetch(conversationId: string, options: { limit: number; since?: number }): Promise<NormalizedEvent[]>;
  };
  readonly emit: {
    feed(item: { title: string; body: string; notify?: boolean; conversationId?: string }): Promise<void>;
    markdownFile(options: { filename: string; content: string; mode?: 'append' | 'overwrite' }): Promise<string>;
    wechat(options: { conversationId: string; text: string; dedupeKey: string }): Promise<{ status: string }>;
    webhook(options: { url: string; payload: unknown }): Promise<{ status: number }>;
  };
}

export interface PluginHookInputs {
  onInit: undefined;
  onMessage: NormalizedEvent;
  onRecall: NormalizedEvent;
  onFlush: { conversationId: string; events: NormalizedEvent[] };
  onManualRun: { conversationId: string; since: number; until: number };
}

export type PluginHookName = keyof PluginHookInputs;

export interface WeChatBridgePlugin {
  onInit?(ctx: PluginContext): Promise<void> | void;
  onMessage?(event: PluginHookInputs['onMessage'], ctx: PluginContext): Promise<void> | void;
  onRecall?(event: PluginHookInputs['onRecall'], ctx: PluginContext): Promise<void> | void;
  onFlush?(batch: PluginHookInputs['onFlush'], ctx: PluginContext): Promise<void> | void;
  onManualRun?(range: PluginHookInputs['onManualRun'], ctx: PluginContext): Promise<void> | void;
}
