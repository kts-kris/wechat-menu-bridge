import { Database } from 'bun:sqlite';
import { lstatSync, mkdirSync, openSync, closeSync, constants } from 'node:fs';
import { join, isAbsolute } from 'node:path';
import { BridgeError, dayStart, sha, type Target } from './contracts.ts';
import type { Receipt } from './mcp.ts';

export const keys = (t: Target) => ({
  peer: sha(JSON.stringify([t.account, t.contact])), read: sha(JSON.stringify([t.mcp, t.account, t.contact])),
});
export type Timing = { ingest: number; batch: number; model: number; rpc: number; total: number };
type Attempt = { id: string; peer: string; route: string; identity: string; kind: 'auto' | 'active'; at: number;
  status: Receipt['status'] | 'trying'; delivery: Receipt['delivery']; operation: string | null };
type ReadState = { identity: string; cursor: string | null; fault: string | null };

function secureStat(path: string, dir: boolean) {
  const st = lstatSync(path);
  if (!(dir ? st.isDirectory() : st.isFile() && st.nlink === 1) || st.uid !== process.getuid?.() || (st.mode & 0o077)) {
    throw new BridgeError('storage-unavailable');
  }
}

export class Journal {
  private db: Database;

  constructor(dir: string) {
    if (!isAbsolute(dir)) throw new BridgeError('storage-unavailable');
    let db: Database | undefined;
    try {
      try { mkdirSync(dir, { mode: 0o700 }); } catch (e) { if ((e as NodeJS.ErrnoException).code !== 'EEXIST') throw e; }
      secureStat(dir, true);
      const path = join(dir, 'bridge.sqlite');
      const file = openSync(path, constants.O_CREAT | constants.O_RDWR | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
      closeSync(file);
      secureStat(path, false);
      db = new Database(path, { create: false, strict: true });
      // Keep the kernel-managed exclusive lock for this helper's lifetime, including across requests.
      db.exec(`PRAGMA busy_timeout=150; PRAGMA locking_mode=EXCLUSIVE; PRAGMA journal_mode=DELETE;
        PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA secure_delete=ON;
        BEGIN EXCLUSIVE;
        CREATE TABLE IF NOT EXISTS cursors (route TEXT PRIMARY KEY, identity TEXT NOT NULL, cursor TEXT, fault TEXT);
        CREATE TABLE IF NOT EXISTS pending_drains (route TEXT PRIMARY KEY, since INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS opted_out (peer TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS events (route TEXT, hash TEXT, at INTEGER NOT NULL, PRIMARY KEY(route,hash));
        CREATE INDEX IF NOT EXISTS events_at ON events(at);
        CREATE TABLE IF NOT EXISTS attempts (id TEXT PRIMARY KEY, peer TEXT NOT NULL, route TEXT NOT NULL, identity TEXT NOT NULL,
          kind TEXT NOT NULL, at INTEGER NOT NULL, status TEXT NOT NULL, delivery TEXT NOT NULL, operation TEXT,
          ref_hash TEXT, acknowledged INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS attempts_peer ON attempts(peer, at);
        CREATE INDEX IF NOT EXISTS attempts_ref ON attempts(peer, identity, ref_hash);
        CREATE TABLE IF NOT EXISTS timings (peer TEXT, at INTEGER, ingest INTEGER, batch INTEGER, model INTEGER, rpc INTEGER, total INTEGER);
        UPDATE attempts SET status='unknown' WHERE status='trying';
        COMMIT;`);
      this.db = db;
      const now = Date.now();
      this.db.run('DELETE FROM events WHERE at < ?', [now - 2 * 86_400_000]);
      this.db.run(`DELETE FROM attempts WHERE at < ? AND (status <> 'unknown' OR acknowledged = 1)`, [now - 30 * 86_400_000]);
    } catch (e) {
      db?.close();
      const code = (e as { code?: string })?.code;
      throw new BridgeError(code?.startsWith('SQLITE_BUSY') ? 'storage-in-use' : 'storage-unavailable');
    }
  }

  read(route: string) { return this.db.query<ReadState, [string]>('SELECT identity,cursor,fault FROM cursors WHERE route=?').get(route); }
  known(route: string, hash: string) { return !!this.db.query('SELECT 1 FROM events WHERE route=? AND hash=?').get(route, hash); }
  optedOut(peer: string) { return !!this.db.query('SELECT 1 FROM opted_out WHERE peer=?').get(peer); }
  optOut(peer: string) { this.db.run('INSERT OR IGNORE INTO opted_out VALUES(?)', [peer]); }
  restoreConsent(peer: string) { this.db.run('DELETE FROM opted_out WHERE peer=?', [peer]); }
  resetRead(route: string) {
    // A bounded backlog has a verified, advanced cursor. Keep it so a human's
    // explicit recovery can continue rather than start the same window again.
    if (this.read(route)?.fault === 'backlog-limit') this.db.run('UPDATE cursors SET fault=NULL WHERE route=?', [route]);
    else this.db.run('DELETE FROM cursors WHERE route=?', [route]);
  }

  beginDrain(route: string, since: number) {
    // Keep the earliest active-session cutoff across pauses and restarts: an
    // unread stop can arrive after a completed catch-up but before shutdown.
    this.db.run('INSERT OR IGNORE INTO pending_drains VALUES(?,?)', [route, since]);
    return this.db.query<{ since: number }, [string]>('SELECT since FROM pending_drains WHERE route=?').get(route)!.since;
  }

  holdRead(route: string, identity: string, fault: string) {
    this.db.run('INSERT INTO cursors VALUES(?,?,NULL,?) ON CONFLICT(route) DO UPDATE SET fault=excluded.fault', [route, identity, fault]);
  }

  advance(route: string, identity: string, cursor: string | null, hashes: Iterable<string>, at: number, stopPeer?: string) {
    this.db.transaction(() => {
      const statement = this.db.query('INSERT OR IGNORE INTO events VALUES(?,?,?)');
      for (const hash of hashes) statement.run(route, hash, at);
      if (stopPeer) this.optOut(stopPeer);
      this.db.run(`INSERT INTO cursors VALUES(?,?,?,NULL) ON CONFLICT(route) DO UPDATE SET cursor=excluded.cursor`, [route, identity, cursor]);
    })();
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

  own(peer: string, identity: string, request?: string, ref?: string) {
    return !!this.db.query(`SELECT 1 FROM attempts WHERE peer=? AND identity=? AND
      ((id=? AND status <> 'rejected') OR ref_hash=?)`).get(peer, identity, request ?? '', ref ? sha(ref) : '');
  }

  reserve(id: string, peer: string, route: string, identity: string, kind: Attempt['kind'], now: number) {
    this.db.transaction(() => {
      if (this.get(id)) throw new BridgeError('duplicate-attempt');
      if (this.uncertain(peer)) throw new BridgeError('send-unknown');
      if (this.optedOut(peer)) throw new BridgeError('peer-stopped');
      if (kind === 'active') {
        const count = this.db.query<{ n: number }, [string, number]>("SELECT count(*) AS n FROM attempts WHERE peer=? AND kind='active' AND at>=?")
          .get(peer, dayStart(now))?.n ?? 0;
        if (count >= 12) throw new BridgeError('active-limit');
      }
      this.db.run(`INSERT INTO attempts(id,peer,route,identity,kind,at,status,delivery) VALUES(?,?,?,?,?,?,'trying','unknown')`,
        [id, peer, route, identity, kind, now]);
    }).immediate();
  }

  complete(id: string, receipt: Receipt) {
    this.db.run(`UPDATE attempts SET status=?,delivery=?,operation=coalesce(?,operation),ref_hash=coalesce(?,ref_hash) WHERE id=?`,
      [receipt.status, receipt.delivery, receipt.operation ?? null, receipt.ref ? sha(receipt.ref) : null, id]);
  }

  addTiming(peer: string, now: number, t: Timing) {
    this.db.run('INSERT INTO timings VALUES(?,?,?,?,?,?,?)', [peer, now, t.ingest, t.batch, t.model, t.rpc, t.total]);
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

  close() { this.db.close(); }
}
