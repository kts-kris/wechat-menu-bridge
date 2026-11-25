import type { Database } from 'bun:sqlite';
import { BridgeError } from '../contracts/errors.ts';

export const JOURNAL_SCHEMA_VERSION = 2;

const schema = `
CREATE TABLE IF NOT EXISTS schema_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS cursors (
  route TEXT PRIMARY KEY,
  scope_kind TEXT NOT NULL DEFAULT 'conversation',
  conversation_id TEXT,
  identity TEXT NOT NULL,
  cursor TEXT,
  fault TEXT,
  updated_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS pending_drains (
  route TEXT PRIMARY KEY,
  since INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS opted_out (
  peer TEXT PRIMARY KEY,
  at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS events (
  route TEXT NOT NULL,
  hash TEXT NOT NULL,
  at INTEGER NOT NULL,
  recalled INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (route, hash)
);
CREATE INDEX IF NOT EXISTS events_at ON events(at);

CREATE TABLE IF NOT EXISTS attempts (
  id TEXT PRIMARY KEY,
  peer TEXT NOT NULL,
  route TEXT NOT NULL,
  identity TEXT NOT NULL,
  kind TEXT NOT NULL,
  plugin_id TEXT,
  at INTEGER NOT NULL,
  status TEXT NOT NULL,
  delivery TEXT NOT NULL,
  operation TEXT,
  ref_hash TEXT,
  acknowledged INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS attempts_peer ON attempts(peer, at);
CREATE INDEX IF NOT EXISTS attempts_ref ON attempts(peer, identity, ref_hash);

CREATE TABLE IF NOT EXISTS timings (
  peer TEXT NOT NULL,
  at INTEGER NOT NULL,
  ingest INTEGER NOT NULL,
  batch INTEGER NOT NULL,
  model INTEGER NOT NULL,
  rpc INTEGER NOT NULL,
  total INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS timings_peer ON timings(peer, at);

CREATE TABLE IF NOT EXISTS plugin_state (
  plugin_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 0,
  approved_permissions TEXT NOT NULL DEFAULT '[]',
  manifest_hash TEXT,
  consecutive_failures INTEGER NOT NULL DEFAULT 0,
  circuit_open INTEGER NOT NULL DEFAULT 0,
  last_run_at INTEGER,
  last_error TEXT
);

CREATE TABLE IF NOT EXISTS plugin_buffers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  plugin_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  event_id TEXT NOT NULL,
  message_ref TEXT NOT NULL,
  sender_label TEXT NOT NULL,
  is_self INTEGER NOT NULL,
  kind TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  recalled INTEGER NOT NULL DEFAULT 0,
  UNIQUE(plugin_id, event_id)
);
CREATE INDEX IF NOT EXISTS plugin_buffers_lookup ON plugin_buffers(plugin_id, created_at);
CREATE INDEX IF NOT EXISTS plugin_buffers_ref ON plugin_buffers(conversation_id, message_ref);

CREATE TABLE IF NOT EXISTS plugin_runs (
  run_id TEXT PRIMARY KEY,
  plugin_id TEXT NOT NULL,
  trigger_kind TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  status TEXT NOT NULL,
  item_count INTEGER NOT NULL DEFAULT 0,
  summary_preview TEXT,
  output_paths TEXT,
  error_code TEXT
);
CREATE INDEX IF NOT EXISTS plugin_runs_time ON plugin_runs(plugin_id, started_at DESC);

CREATE TABLE IF NOT EXISTS feed_items (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  conversation_id TEXT,
  plugin_id TEXT,
  ref_path TEXT,
  created_at INTEGER NOT NULL,
  read INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS feed_items_time ON feed_items(created_at DESC);

CREATE TABLE IF NOT EXISTS memory_revisions (
  rev_id TEXT PRIMARY KEY,
  target_kind TEXT NOT NULL,
  scope_key TEXT NOT NULL,
  snapshot_path TEXT NOT NULL,
  source TEXT NOT NULL,
  summary TEXT NOT NULL,
  diff_preview TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS memory_rev_scope ON memory_revisions(target_kind, scope_key, created_at DESC);

CREATE TABLE IF NOT EXISTS persona_proposals (
  proposal_id TEXT PRIMARY KEY,
  status TEXT NOT NULL,
  file_path TEXT NOT NULL,
  sample_count INTEGER NOT NULL,
  summary TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  decided_at INTEGER
);

CREATE TABLE IF NOT EXISTS memory_watermarks (
  scope_key TEXT PRIMARY KEY,
  last_event_at INTEGER NOT NULL DEFAULT 0,
  pending_turns INTEGER NOT NULL DEFAULT 0,
  last_consolidated_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS turn_metrics (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  outcome TEXT NOT NULL,
  ingest_ms INTEGER NOT NULL,
  debounce_ms INTEGER NOT NULL,
  prompt_ms INTEGER NOT NULL,
  prompt_cache_hit INTEGER NOT NULL DEFAULT 0,
  model_ttft_ms INTEGER NOT NULL,
  model_total_ms INTEGER NOT NULL,
  fence_ms INTEGER NOT NULL,
  send_wire_ms INTEGER NOT NULL,
  total_ms INTEGER NOT NULL,
  bottleneck TEXT NOT NULL,
  model_mode TEXT,
  effort TEXT,
  fallback_used INTEGER NOT NULL DEFAULT 0,
  error_code TEXT
);
CREATE INDEX IF NOT EXISTS turn_metrics_time ON turn_metrics(at DESC);
CREATE INDEX IF NOT EXISTS turn_metrics_conv ON turn_metrics(conversation_id, at DESC);
`;

const addedColumns = {
  cursors: [
    ['scope_kind', "TEXT NOT NULL DEFAULT 'conversation'"],
    ['conversation_id', 'TEXT'],
    ['updated_at', 'INTEGER NOT NULL DEFAULT 0'],
  ],
  opted_out: [['at', 'INTEGER NOT NULL DEFAULT 0']],
  events: [['recalled', 'INTEGER NOT NULL DEFAULT 0']],
  attempts: [['plugin_id', 'TEXT']],
} as const;

export function migrateJournalToV2(db: Database): void {
  db.transaction(() => {
    db.exec('CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    const version = db.query<{ value: string }, []>("SELECT value FROM schema_meta WHERE key='version'").get()?.value;
    if (version !== undefined && version !== '1' && version !== String(JOURNAL_SCHEMA_VERSION)) {
      throw new BridgeError('storage-unavailable');
    }
    db.exec(schema);
    for (const [table, additions] of Object.entries(addedColumns)) {
      const columns = new Set(db.query<{ name: string }, []>(`PRAGMA table_info(${table})`).all().map(row => row.name));
      for (const [column, definition] of additions) {
        if (!columns.has(column)) db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
      }
    }
    db.exec("CREATE INDEX IF NOT EXISTS attempts_plugin_day ON attempts(plugin_id, at) WHERE kind='plugin'");
    db.run(`INSERT INTO schema_meta(key, value) VALUES('version', ?)
      ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value <> excluded.value`, [String(JOURNAL_SCHEMA_VERSION)]);
  }).exclusive();
}
