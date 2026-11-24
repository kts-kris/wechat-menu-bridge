import { Database } from 'bun:sqlite';
import { closeSync, constants, fstatSync, lstatSync, openSync } from 'node:fs';
import { join } from 'node:path';
import { dayStart, sha, tomorrow } from '../../contracts.ts';
import type { Timing } from '../../journal.ts';
import type { Receipt } from '../../mcp.ts';
import { BridgeError, type ErrorCode } from '../contracts/errors.ts';
import type { MessageKind } from '../contracts/events.ts';
import type { PluginPermission } from '../contracts/plugins.ts';
import { assertPrivateFile, ensurePrivateDir } from './fs-safe.ts';
import { migrateJournalToV2 } from './migrations.ts';

export type AttemptKind = 'auto' | 'active' | 'plugin';
export type Attempt = {
  id: string; peer: string; route: string; identity: string; kind: AttemptKind; plugin_id: string | null; at: number;
  status: Receipt['status'] | 'trying'; delivery: Receipt['delivery']; operation: string | null;
  ref_hash: string | null; acknowledged: 0 | 1;
};
type CursorScope = { scope_kind: 'account' | 'conversation'; conversation_id?: string | null };
export type ReadState = Required<CursorScope> & {
  identity: string; cursor: string | null; fault: string | null; updated_at: number;
};
export type PluginState = {
  plugin_id: string; kind: 'declarative' | 'module'; enabled: 0 | 1; approved_permissions: PluginPermission[];
  manifest_hash: string | null; consecutive_failures: number; circuit_open: 0 | 1;
  last_run_at: number | null; last_error: ErrorCode | null;
};
export type PluginBuffer = {
  id: number; plugin_id: string; conversation_id: string; event_id: string; message_ref: string;
  sender_label: string; is_self: 0 | 1; kind: MessageKind; content: string; created_at: number; recalled: 0 | 1;
};
export type PluginRun = {
  run_id: string; plugin_id: string; trigger_kind: 'realtime' | 'window_time' | 'window_count' | 'manual';
  started_at: number; finished_at: number | null; status: 'running' | 'ok' | 'skipped' | 'error';
  item_count: number; summary_preview: string | null; output_paths: string[] | null; error_code: ErrorCode | null;
};
export type FeedItem = {
  id: string; kind: 'plugin_digest' | 'persona_proposal' | 'memory_updated' | 'alert' | 'schedule_cancelled';
  title: string; body: string; conversation_id: string | null; plugin_id: string | null;
  ref_path: string | null; created_at: number; read: 0 | 1;
};
export type MemoryRevision = {
  rev_id: string; target_kind: 'persona' | 'scope'; scope_key: string; snapshot_path: string;
  source: 'auto' | 'backfill' | 'proposal_accepted' | 'manual' | 'rollback';
  summary: string; diff_preview: string; created_at: number;
};
export type PersonaProposal = {
  proposal_id: string; status: 'pending' | 'accepted' | 'rejected' | 'superseded';
  file_path: string; sample_count: number; summary: string; created_at: number; decided_at: number | null;
};
export type MemoryWatermark = {
  scope_key: string; last_event_at: number; pending_turns: number; last_consolidated_at: number;
};

const DAY = 86_400_000;

export class JournalV2 {
  private readonly db: Database;

  constructor(dir: string) {
    let db: Database | undefined;
    try {
      ensurePrivateDir(dir);
      const path = join(dir, 'bridge.sqlite');
      try { assertPrivateFile(lstatSync(`${path}-journal`)); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
      const file = openSync(path, constants.O_CREAT | constants.O_RDWR | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
      try { assertPrivateFile(fstatSync(file)); } finally { closeSync(file); }
      db = new Database(path, { create: false, strict: true });
      db.exec(`PRAGMA busy_timeout=150; PRAGMA locking_mode=EXCLUSIVE; PRAGMA journal_mode=DELETE;
        PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA secure_delete=ON;`);
      migrateJournalToV2(db);
      this.db = db;
      const now = Date.now();
      this.db.transaction(() => {
        this.db.run("UPDATE attempts SET status='unknown' WHERE status='trying'");
        this.db.run('DELETE FROM events WHERE at < ?', [now - 7 * DAY]);
        this.db.run("DELETE FROM attempts WHERE at < ? AND (status <> 'unknown' OR acknowledged=1)", [now - 30 * DAY]);
        this.db.run('DELETE FROM plugin_runs WHERE rowid IN (SELECT rowid FROM plugin_runs ORDER BY started_at DESC, rowid DESC LIMIT -1 OFFSET 500)');
        this.db.run('DELETE FROM feed_items WHERE rowid IN (SELECT rowid FROM feed_items ORDER BY created_at DESC, rowid DESC LIMIT -1 OFFSET 200)');
      }).immediate();
    } catch (error) {
      db?.close();
      const code = (error as { code?: string }).code;
      throw new BridgeError(code?.startsWith('SQLITE_BUSY') || code?.startsWith('SQLITE_LOCKED') ? 'storage-in-use' : 'storage-unavailable');
    }
  }

  read(route: string) { return this.db.query<ReadState, [string]>('SELECT identity,cursor,fault,scope_kind,conversation_id,updated_at FROM cursors WHERE route=?').get(route); }
  known(route: string, hash: string) { return !!this.db.query('SELECT 1 FROM events WHERE route=? AND hash=?').get(route, hash); }
  optedOut(peer: string) { return !!this.db.query('SELECT 1 FROM opted_out WHERE peer=?').get(peer); }
  optOut(peer: string, at = Date.now()) { this.db.run('INSERT OR IGNORE INTO opted_out(peer,at) VALUES(?,?)', [peer, at]); }
  restoreConsent(peer: string) { this.db.run('DELETE FROM opted_out WHERE peer=?', [peer]); }
  resetRead(route: string) {
    // 积压超限时保留已核验的游标，人工恢复后从该位置继续。
    if (this.read(route)?.fault === 'backlog-limit') this.db.run('UPDATE cursors SET fault=NULL WHERE route=?', [route]);
    else this.db.run('DELETE FROM cursors WHERE route=?', [route]);
  }

  beginDrain(route: string, since: number) {
    // 跨暂停与重启保留最早的开启水位，避免遗漏未读的叫停消息。
    this.db.run('INSERT OR IGNORE INTO pending_drains VALUES(?,?)', [route, since]);
    return this.db.query<{ since: number }, [string]>('SELECT since FROM pending_drains WHERE route=?').get(route)!.since;
  }

  holdRead(route: string, identity: string, fault: string, scope?: CursorScope, at = Date.now()) {
    this.db.run(`INSERT INTO cursors(route,identity,fault,scope_kind,conversation_id,updated_at) VALUES(?,?,?,?,?,?)
      ON CONFLICT(route) DO UPDATE SET fault=excluded.fault,updated_at=excluded.updated_at`,
    [route, identity, fault, scope?.scope_kind ?? 'conversation', scope?.conversation_id ?? null, at]);
  }

  advance(route: string, identity: string, cursor: string | null, hashes: Iterable<string>, at: number,
    stopPeer?: string, scope?: CursorScope) {
    this.db.transaction(() => {
      const statement = this.db.query('INSERT OR IGNORE INTO events(route,hash,at) VALUES(?,?,?)');
      for (const hash of hashes) statement.run(route, hash, at);
      if (stopPeer) this.optOut(stopPeer, at);
      this.db.run(`INSERT INTO cursors(route,identity,cursor,scope_kind,conversation_id,updated_at) VALUES(?,?,?,?,?,?)
        ON CONFLICT(route) DO UPDATE SET cursor=excluded.cursor,updated_at=excluded.updated_at,
        scope_kind=coalesce(?,scope_kind),conversation_id=CASE WHEN ? IS NULL THEN conversation_id ELSE excluded.conversation_id END`,
      [route, identity, cursor, scope?.scope_kind ?? 'conversation', scope?.conversation_id ?? null, at,
        scope?.scope_kind ?? null, scope?.scope_kind ?? null]);
    }).immediate();
  }

  markRecalled(route: string, hash: string, at = Date.now()) {
    this.db.run(`INSERT INTO events(route,hash,at,recalled) VALUES(?,?,?,1)
      ON CONFLICT(route,hash) DO UPDATE SET recalled=1,at=max(events.at,excluded.at)`, [route, hash, at]);
  }

  isRecalled(route: string, hash: string) {
    return !!this.db.query('SELECT 1 FROM events WHERE route=? AND hash=? AND recalled=1').get(route, hash);
  }

  get(id: string) { return this.db.query<Attempt, [string]>('SELECT * FROM attempts WHERE id=?').get(id); }
  latest(peer: string) {
    return this.uncertain(peer) ?? this.db.query<Attempt, [string]>('SELECT * FROM attempts WHERE peer=? ORDER BY at DESC, rowid DESC LIMIT 1').get(peer);
  }
  uncertain(peer: string) {
    return this.db.query<Attempt, [string]>(`SELECT * FROM attempts WHERE peer=? AND status IN ('unknown','trying') AND acknowledged=0
      ORDER BY at DESC, rowid DESC LIMIT 1`).get(peer);
  }
  acknowledge(id: string) { this.db.run(`UPDATE attempts SET acknowledged=1 WHERE id=? AND status='unknown'`, [id]); }

  markUnknown(id: string, operation?: string) {
    return this.db.transaction(() => {
      const row = this.get(id);
      if (!row || row.status === 'rejected') return false;
      this.db.run(`UPDATE attempts SET status='unknown',delivery='unknown',acknowledged=0,operation=coalesce(?,operation) WHERE id=?`,
        [operation ?? null, id]);
      return true;
    }).immediate();
  }

  own(peer: string, identity: string, request?: string, ref?: string) {
    return !!this.db.query(`SELECT 1 FROM attempts WHERE peer=? AND identity=? AND
      ((id=? AND status <> 'rejected') OR ref_hash=?)`).get(peer, identity, request ?? '', ref ? sha(ref) : '');
  }

  reserve(id: string, peer: string, route: string, identity: string, kind: AttemptKind, now: number,
    options?: { pluginId: string; dailyLimit?: number }) {
    if (kind === 'plugin' ? !options?.pluginId : options !== undefined) throw new BridgeError('invalid-configuration');
    const pluginId = options?.pluginId ?? null;
    const pluginLimit = options?.dailyLimit ?? 20;
    if (!Number.isSafeInteger(pluginLimit) || pluginLimit < 0) throw new BridgeError('invalid-configuration');
    this.db.transaction(() => {
      if (this.get(id)) throw new BridgeError('duplicate-attempt');
      if (this.uncertain(peer)) throw new BridgeError('send-unknown');
      if (this.optedOut(peer)) throw new BridgeError('peer-stopped');
      const start = dayStart(now), end = tomorrow(now);
      if (kind === 'active') {
        const { n } = this.db.query<{ n: number }, [string, number, number]>(
          "SELECT count(*) AS n FROM attempts WHERE peer=? AND kind='active' AND at>=? AND at<?").get(peer, start, end)!;
        if (n >= 12) throw new BridgeError('active-limit');
      } else if (kind === 'plugin') {
        const { n } = this.db.query<{ n: number }, [string | null, number, number]>(
          "SELECT count(*) AS n FROM attempts WHERE plugin_id=? AND kind='plugin' AND at>=? AND at<?").get(pluginId, start, end)!;
        if (n >= pluginLimit) throw new BridgeError('plugin-limit');
      }
      this.db.run(`INSERT INTO attempts(id,peer,route,identity,kind,plugin_id,at,status,delivery)
        VALUES(?,?,?,?,?,?,?,'trying','unknown')`, [id, peer, route, identity, kind, pluginId, now]);
    }).immediate();
  }

  complete(id: string, receipt: Receipt) {
    this.db.run(`UPDATE attempts SET status=?,delivery=?,operation=coalesce(?,operation),ref_hash=coalesce(?,ref_hash) WHERE id=?`,
      [receipt.status, receipt.delivery, receipt.operation ?? null, receipt.ref ? sha(receipt.ref) : null, id]);
  }

  addTiming(peer: string, now: number, t: Timing) {
    this.db.run('INSERT INTO timings(peer,at,ingest,batch,model,rpc,total) VALUES(?,?,?,?,?,?,?)', [peer, now, t.ingest, t.batch, t.model, t.rpc, t.total]);
    this.db.run('DELETE FROM timings WHERE rowid NOT IN (SELECT rowid FROM timings ORDER BY rowid DESC LIMIT 200)');
  }

  statistics(peer: string) {
    const rows = this.db.query<Timing, [string]>('SELECT ingest,batch,model,rpc,total FROM timings WHERE peer=?').all(peer);
    const quantiles = (field: keyof Timing) => {
      const sorted = rows.map(t => t[field]).sort((a, b) => a - b);
      return { p50: sorted[Math.ceil(sorted.length * 0.5) - 1] ?? 0, p95: sorted[Math.ceil(sorted.length * 0.95) - 1] ?? 0 };
    };
    return rows.length ? { count: rows.length, ingest: quantiles('ingest'), batch: quantiles('batch'), model: quantiles('model'),
      rpc: quantiles('rpc'), total: quantiles('total') } : undefined;
  }

  savePluginState(state: PluginState) {
    this.db.query(`INSERT INTO plugin_state(plugin_id,kind,enabled,approved_permissions,manifest_hash,consecutive_failures,
      circuit_open,last_run_at,last_error) VALUES($plugin_id,$kind,$enabled,$approved_permissions,$manifest_hash,
      $consecutive_failures,$circuit_open,$last_run_at,$last_error)
      ON CONFLICT(plugin_id) DO UPDATE SET kind=excluded.kind,enabled=excluded.enabled,
      approved_permissions=excluded.approved_permissions,manifest_hash=excluded.manifest_hash,
      consecutive_failures=excluded.consecutive_failures,circuit_open=excluded.circuit_open,
      last_run_at=excluded.last_run_at,last_error=excluded.last_error`).run(
    { ...state, approved_permissions: JSON.stringify(state.approved_permissions) });
  }

  getPluginState(pluginId: string): PluginState | null {
    const row = this.db.query<Omit<PluginState, 'approved_permissions'> & { approved_permissions: string }, [string]>(
      'SELECT * FROM plugin_state WHERE plugin_id=?').get(pluginId);
    return row && { ...row, approved_permissions: JSON.parse(row.approved_permissions) };
  }

  deletePluginState(pluginId: string) { this.db.run('DELETE FROM plugin_state WHERE plugin_id=?', [pluginId]); }

  addPluginBuffer(item: Omit<PluginBuffer, 'id' | 'recalled'>): boolean {
    return this.db.query(`INSERT INTO plugin_buffers(plugin_id,conversation_id,event_id,message_ref,sender_label,is_self,kind,content,created_at)
      VALUES($plugin_id,$conversation_id,$event_id,$message_ref,$sender_label,$is_self,$kind,$content,$created_at)
      ON CONFLICT(plugin_id,event_id) DO NOTHING`).run(item).changes > 0;
  }

  markPluginBufferRecalled(conversationId: string, messageRef: string): number {
    return this.db.run('UPDATE plugin_buffers SET recalled=1 WHERE conversation_id=? AND message_ref=? AND recalled=0',
      [conversationId, messageRef]).changes;
  }

  listPluginBuffers(pluginId: string): PluginBuffer[] {
    return this.db.query<PluginBuffer, [string]>(
      'SELECT * FROM plugin_buffers WHERE plugin_id=? AND recalled=0 ORDER BY created_at, id').all(pluginId);
  }

  snapshotPluginBuffers(pluginId: string) {
    const { throughId } = this.db.query<{ throughId: number }, [string]>(
      'SELECT coalesce(max(id),0) AS throughId FROM plugin_buffers WHERE plugin_id=?').get(pluginId)!;
    return { items: this.listPluginBuffers(pluginId), throughId };
  }

  // 传入 flush 快照的水位时，保留异步产出期间新入队的消息。
  clearPluginBuffers(pluginId: string, throughId = Number.MAX_SAFE_INTEGER) {
    this.db.run('DELETE FROM plugin_buffers WHERE plugin_id=? AND id<=?', [pluginId, throughId]);
  }

  flushPluginBuffers(pluginId: string): PluginBuffer[] {
    return this.db.transaction(() => {
      const items = this.listPluginBuffers(pluginId);
      this.clearPluginBuffers(pluginId);
      return items;
    }).immediate();
  }

  savePluginRun(run: PluginRun) {
    this.db.query(`INSERT INTO plugin_runs(run_id,plugin_id,trigger_kind,started_at,finished_at,status,item_count,summary_preview,
      output_paths,error_code) VALUES($run_id,$plugin_id,$trigger_kind,$started_at,$finished_at,$status,$item_count,
      $summary_preview,$output_paths,$error_code)
      ON CONFLICT(run_id) DO UPDATE SET finished_at=excluded.finished_at,status=excluded.status,
      item_count=excluded.item_count,summary_preview=excluded.summary_preview,output_paths=excluded.output_paths,error_code=excluded.error_code`).run(
    { ...run, summary_preview: run.summary_preview?.slice(0, 500) ?? null,
      output_paths: run.output_paths === null ? null : JSON.stringify(run.output_paths) });
  }

  listPluginRuns(pluginId: string, limit = 100, offset = 0): PluginRun[] {
    return this.db.query<Omit<PluginRun, 'output_paths'> & { output_paths: string | null }, [string, number, number]>(
      'SELECT * FROM plugin_runs WHERE plugin_id=? ORDER BY started_at DESC, rowid DESC LIMIT ? OFFSET ?').all(pluginId, limit, offset)
      .map(run => ({ ...run, output_paths: run.output_paths === null ? null : JSON.parse(run.output_paths) }));
  }

  saveFeedItem(item: FeedItem) {
    this.db.query(`INSERT INTO feed_items(id,kind,title,body,conversation_id,plugin_id,ref_path,created_at,read)
      VALUES($id,$kind,$title,$body,$conversation_id,$plugin_id,$ref_path,$created_at,$read)
      ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,title=excluded.title,body=excluded.body,
      conversation_id=excluded.conversation_id,plugin_id=excluded.plugin_id,ref_path=excluded.ref_path,
      created_at=excluded.created_at,read=max(feed_items.read,excluded.read)`).run({ ...item, body: item.body.slice(0, 2000) });
  }

  getFeedItem(id: string) { return this.db.query<FeedItem, [string]>('SELECT * FROM feed_items WHERE id=?').get(id); }
  listFeedItems(limit = 100, offset = 0, unreadOnly = false) {
    return this.db.query<FeedItem, [number, number, number]>(
      'SELECT * FROM feed_items WHERE (?=0 OR read=0) ORDER BY created_at DESC, rowid DESC LIMIT ? OFFSET ?')
      .all(Number(unreadOnly), limit, offset);
  }
  markFeedRead(ids: Iterable<string>) {
    this.db.transaction(() => {
      const mark = this.db.query('UPDATE feed_items SET read=1 WHERE id=?');
      for (const id of ids) mark.run(id);
    }).immediate();
  }
  deleteFeedItem(id: string) { this.db.run('DELETE FROM feed_items WHERE id=?', [id]); }

  saveMemoryRevision(revision: MemoryRevision) {
    if (Buffer.byteLength(revision.diff_preview) > 8 * 1024) throw new BridgeError('invalid-configuration');
    this.db.query(`INSERT INTO memory_revisions(rev_id,target_kind,scope_key,snapshot_path,source,summary,diff_preview,created_at)
      VALUES($rev_id,$target_kind,$scope_key,$snapshot_path,$source,$summary,$diff_preview,$created_at)
      ON CONFLICT(rev_id) DO UPDATE SET summary=excluded.summary,diff_preview=excluded.diff_preview`).run(revision);
  }
  getMemoryRevision(revId: string) {
    return this.db.query<MemoryRevision, [string]>('SELECT * FROM memory_revisions WHERE rev_id=?').get(revId);
  }
  listMemoryRevisions(targetKind: MemoryRevision['target_kind'], scopeKey: string, limit = 100, offset = 0) {
    return this.db.query<MemoryRevision, [string, string, number, number]>(`SELECT * FROM memory_revisions
      WHERE target_kind=? AND scope_key=? ORDER BY created_at DESC, rowid DESC LIMIT ? OFFSET ?`).all(targetKind, scopeKey, limit, offset);
  }
  deleteMemoryRevision(revId: string) { this.db.run('DELETE FROM memory_revisions WHERE rev_id=?', [revId]); }

  savePersonaProposal(proposal: PersonaProposal) {
    this.db.query(`INSERT INTO persona_proposals(proposal_id,status,file_path,sample_count,summary,created_at,decided_at)
      VALUES($proposal_id,$status,$file_path,$sample_count,$summary,$created_at,$decided_at)
      ON CONFLICT(proposal_id) DO UPDATE SET file_path=excluded.file_path,sample_count=excluded.sample_count,summary=excluded.summary
      WHERE persona_proposals.status='pending'`).run(proposal);
  }
  getPersonaProposal(proposalId: string) {
    return this.db.query<PersonaProposal, [string]>('SELECT * FROM persona_proposals WHERE proposal_id=?').get(proposalId);
  }
  listPersonaProposals(status?: PersonaProposal['status'], limit = 100, offset = 0) {
    return this.db.query<PersonaProposal, [string | null, string | null, number, number]>(`SELECT * FROM persona_proposals
      WHERE (? IS NULL OR status=?) ORDER BY created_at DESC, rowid DESC LIMIT ? OFFSET ?`).all(status ?? null, status ?? null, limit, offset);
  }
  decidePersonaProposal(proposalId: string, status: Exclude<PersonaProposal['status'], 'pending'>, at = Date.now()): boolean {
    return this.db.run("UPDATE persona_proposals SET status=?,decided_at=? WHERE proposal_id=? AND status='pending'",
      [status, at, proposalId]).changes > 0;
  }
  deletePersonaProposal(proposalId: string) { this.db.run('DELETE FROM persona_proposals WHERE proposal_id=?', [proposalId]); }

  saveMemoryWatermark(watermark: MemoryWatermark) {
    this.db.query(`INSERT INTO memory_watermarks(scope_key,last_event_at,pending_turns,last_consolidated_at)
      VALUES($scope_key,$last_event_at,$pending_turns,$last_consolidated_at)
      ON CONFLICT(scope_key) DO UPDATE SET last_event_at=excluded.last_event_at,pending_turns=excluded.pending_turns,
      last_consolidated_at=excluded.last_consolidated_at`).run(watermark);
  }
  getMemoryWatermark(scopeKey: string) {
    return this.db.query<MemoryWatermark, [string]>('SELECT * FROM memory_watermarks WHERE scope_key=?').get(scopeKey);
  }
  deleteMemoryWatermark(scopeKey: string) { this.db.run('DELETE FROM memory_watermarks WHERE scope_key=?', [scopeKey]); }

  close() { this.db.close(); }
}
