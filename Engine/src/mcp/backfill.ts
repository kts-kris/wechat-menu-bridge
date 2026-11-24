import { BridgeError, checked } from '../../contracts.ts';
import { errorCode } from '../contracts/errors.ts';
import { backfillRequestSchema, type BackfillProgress, type BackfillRequest, type ScopeType } from '../contracts/events.ts';
import { type HistoryFilter, type Scope, type XiaoheClient } from './client.ts';
import { normalizeEvent, type EventInput } from './ingest.ts';

export class HistoryBackfiller {
  constructor(private readonly client: Pick<XiaoheClient, 'queryMessages'>) {}

  async run(jobId: string, request: BackfillRequest, scope: Scope, type: ScopeType, route: string, identity: string,
    options: { signal?: AbortSignal; onEvent: (input: EventInput) => void | Promise<void>; onProgress?: (p: BackfillProgress) => void }) {
    const req = checked(backfillRequestSchema, request);
    if (scope.conversation_id !== req.conversationId) throw new BridgeError('invalid-configuration');
    const filter: HistoryFilter = req.startTime === undefined ? { recent_count: req.recentCount ?? 10 } :
      { start_time: Math.floor(req.startTime / 1000), end_time: Math.floor(req.endTime! / 1000) };
    const { signal, onEvent, onProgress } = options;
    const cursors = new Set<string>(), refs = new Set<string>();
    let fetched = 0, cursor: string | null = null;
    const progress = (done: boolean, error?: string) => onProgress?.({ jobId, conversationId: req.conversationId, fetched, done, ...(error && { error }) });
    try {
      progress(false);
      while (true) {
        signal?.throwIfAborted();
        const page = await this.client.queryMessages(scope, filter, cursor, signal);
        signal?.throwIfAborted();
        for (const raw of page.rows) {
          signal?.throwIfAborted();
          const input = normalizeEvent(raw, scope, type, 'backfill', route, identity);
          if (!input || refs.has(input.event.messageRef)) continue;
          refs.add(input.event.messageRef);
          await onEvent(input);
          fetched++;
        }
        if (!page.more) break;
        if (!page.cursor || cursors.has(page.cursor) || cursors.size >= 500) throw new BridgeError('mcp-contract');
        cursors.add(page.cursor);
        cursor = page.cursor;
        progress(false);
      }
      progress(true);
      return fetched;
    } catch (error) {
      const failure = signal?.aborted ? new BridgeError('stopped') : error;
      progress(true, errorCode(failure));
      throw failure;
    }
  }
}
