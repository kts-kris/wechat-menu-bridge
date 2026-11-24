import { setTimeout as delay } from 'node:timers/promises';
import { BridgeError, activeSchema, armSchema, checked, dayStart, endpoint, sha, targetSchema, tomorrow, type Target } from './contracts.ts';
import { Journal, keys } from './journal.ts';
import { Xiaohe, type Page, type Receipt, type Scope } from './mcp.ts';
import { ReplyModel, type Context, type Decision } from './model.ts';
import { classifyText, MAX_AGE, message, sendable, type Incoming } from './policy.ts';

type Grant = { kind: 'auto'; dry: boolean; model?: ReplyModel } |
  { kind: 'active'; at: number; deadline: number; day: number; request: string; text: string };
type Phase = 'idle' | 'connecting' | 'listening' | 'retrying' | 'generating' | 'scheduled' | 'checking' | 'sending' | 'paused';
type Run = {
  grant: Grant; target: Target; peer: string; route: string; abort: AbortController; phase: Phase; since: number;
  replyAfter: number; identity: string; scope?: Scope; cursor: string | null; reader: Xiaohe; writer: Xiaohe;
  synced: boolean; processing: boolean; version: number; queue: Incoming[]; context: Context[]; contextAt: number;
  generation?: AbortController;
  work?: Promise<void>; poll?: Promise<void>; timer?: ReturnType<typeof setTimeout>; expiry?: ReturnType<typeof setTimeout>;
  guardTimer?: ReturnType<typeof setInterval>; clockAt: number;
};
const READ_FAILURE = new Set(['wechat-changed', 'event-gap', 'mcp-contract', 'wrong-anchor', 'backlog-limit']);
const code = (e: unknown) => e instanceof BridgeError ? e.code : 'internal-error';
const unknownReceipt = { status: 'unknown', delivery: 'unknown' } as const;
const received = (r: Receipt) => ({ status: r.status, delivery: r.delivery, hasOperation: !!r.operation });
const remoteIdentity = (r: Awaited<ReturnType<Xiaohe['identify']>>) => sha(JSON.stringify(r));

export class Bridge {
  private readonly journal: Journal;
  private run?: Run;
  private waiting?: { run: Run; done: Promise<void> };
  private target?: Target;
  private phase: Phase = 'idle';
  private reason?: string;
  private draft?: { text: string; until: number };
  private draftTimer?: ReturnType<typeof setTimeout>;
  private closed = false;
  private lookup?: AbortController;

  constructor(dir: string, private update: (v: ReturnType<Bridge['status']>) => void = () => {}) {
    this.journal = new Journal(dir);
  }

  status() {
    const k = this.target ? keys(this.target) : undefined;
    const a = k && this.journal.latest(k.peer);
    const r = this.run;
    return { phase: r?.phase ?? this.phase, reason: this.reason, running: !!r, autoReply: r?.grant.kind === 'auto' && !r.grant.dry,
      dryRun: r?.grant.kind === 'auto' && r.grant.dry, scheduledAt: r?.grant.kind === 'active' ? r.grant.at : undefined,
      draft: this.draft && this.draft.until > Date.now() ? this.draft.text : undefined,
      inFlight: !!this.waiting, peerStopped: !!k && this.journal.optedOut(k.peer),
      uncertain: !!k && !!this.journal.uncertain(k.peer) && !this.waiting,
      receipt: a ? { ...received(a.status === 'trying' ? { ...a, status: 'unknown', operation: a.operation ?? undefined } :
        { ...a, status: a.status, operation: a.operation ?? undefined }), pending: a.status === 'trying' } : undefined,
      statistics: k ? this.journal.statistics(k.peer) : undefined,
    };
  }

  private publish() { if (!this.closed) this.update(this.status()); }
  private show(r: Run, phase: Phase, reason?: string) {
    if (this.run !== r) return;
    if (r.phase === phase && this.reason === reason) return;
    r.phase = phase; this.reason = reason; this.publish();
  }

  pause(reason = 'user-paused') {
    const r = this.run;
    this.run = undefined;
    clearTimeout(this.draftTimer);
    this.draft = undefined;
    this.phase = 'paused';
    this.reason = reason;
    if (r) {
      r.abort.abort();
      clearTimeout(r.timer); clearTimeout(r.expiry); clearInterval(r.guardTimer);
      r.queue = []; r.context = [];
      if (r.grant.kind === 'active') r.grant.text = '';
      else r.grant.model = undefined;
      void r.reader.close();
      if (this.waiting?.run !== r) void r.writer.close();
    }
    this.publish();
  }

  private inactive() {
    if (this.closed) throw new BridgeError('stopped');
    if (this.run || this.waiting || this.lookup) throw new BridgeError('busy');
  }

  private targetOf(value: unknown) {
    const target = checked(targetSchema, value);
    endpoint(target.mcp, 'mcp');
    return target;
  }

  inspect(value: unknown) {
    this.inactive();
    this.target = this.targetOf(value);
    clearTimeout(this.draftTimer); this.draft = undefined;
    const k = keys(this.target);
    const fault = this.journal.read(k.read)?.fault;
    this.reason = this.journal.optedOut(k.peer) ? 'peer-stopped' : this.journal.uncertain(k.peer) ? 'send-unknown' : fault ?? undefined;
    this.phase = this.reason ? 'paused' : 'idle';
    this.publish();
  }

  resetRead(value: unknown) { this.inactive(); this.journal.resetRead(keys(this.targetOf(value)).read); this.inspect(value); }
  restoreConsent(value: unknown) { this.inactive(); this.journal.restoreConsent(keys(this.targetOf(value)).peer); this.inspect(value); }
  acknowledge(value: unknown) {
    this.inactive();
    const a = this.journal.uncertain(keys(this.targetOf(value)).peer);
    if (a?.status === 'unknown') this.journal.acknowledge(a.id);
    this.inspect(value);
  }

  async refresh(value: unknown) {
    this.inactive();
    const target = this.targetOf(value);
    const k = keys(target);
    const a = this.journal.latest(k.peer);
    if (!a?.operation) throw new BridgeError('no-operation');
    if (a.route !== k.read) throw new BridgeError('wechat-changed');
    const lookup = this.lookup = new AbortController();
    const c = new Xiaohe(target.mcp);
    try {
      const v = await c.identify(target.account, lookup.signal, false);
      if (a.identity !== remoteIdentity(v)) throw new BridgeError('wechat-changed');
      const result = await c.operation(a.operation, lookup.signal);
      if (this.closed || lookup.signal.aborted) throw new BridgeError('stopped');
      if ((result.delivery !== 'unknown' || a.delivery === 'unknown') && (result.status !== 'unknown' || a.status === 'unknown')) {
        this.journal.complete(a.id, result);
      }
    } finally { this.lookup = undefined; void c.close(); }
    this.inspect(target);
  }

  async arm(value: unknown) {
    const c = checked(armSchema, value);
    const r = this.begin(c.target, { kind: 'auto', dry: c.dryRun }, Date.now());
    try {
      const model = await ReplyModel.load(c.model);
      this.valid(r);
      if (r.grant.kind === 'auto') r.grant.model = model;
      await this.connect(r);
    } catch (e) { this.hold(r, code(e)); throw new BridgeError(code(e)); }
  }

  async active(value: unknown) {
    const c = checked(activeSchema, value);
    const now = Date.now();
    const at = c.at ?? now;
    const midnight = tomorrow(now);
    if (at < now || at >= midnight) throw new BridgeError('invalid-expiry');
    const r = this.begin(c.target, { kind: 'active', at, deadline: Math.min(at + 12_000, midnight), day: dayStart(now),
      request: c.request, text: c.text }, now);
    try { await this.connect(r); }
    catch (e) { this.hold(r, code(e)); throw new BridgeError(code(e)); }
  }

  private begin(t: Target, grant: Grant, now: number) {
    this.inactive();
    const target = this.targetOf(t);
    const k = keys(target);
    this.target = target;
    const fault = this.journal.optedOut(k.peer) ? 'peer-stopped' : this.journal.uncertain(k.peer) ? 'send-unknown' : this.journal.read(k.read)?.fault;
    if (fault) { this.pause(fault); throw new BridgeError(fault); }
    const since = this.journal.beginDrain(k.read, now);
    const r: Run = { grant, target, peer: k.peer, route: k.read, abort: new AbortController(), phase: 'connecting',
      since, replyAfter: now, reader: new Xiaohe(t.mcp), writer: new Xiaohe(t.mcp),
      identity: '', cursor: null, synced: false, processing: false, version: 0, queue: [], context: [], contextAt: 0, clockAt: now };
    clearTimeout(this.draftTimer); this.draft = undefined;
    this.run = r; this.reason = undefined;
    if (grant.kind === 'active') r.expiry = setTimeout(() => this.hold(r, 'expired'), grant.deadline - now);
    r.guardTimer = setInterval(() => {
      try {
        r.clockAt = this.valid(r);
        if (r.context.length && r.clockAt - r.contextAt >= 180_000) r.context = [];
      }
      catch (e) { this.hold(r, code(e)); }
    }, 1000);
    this.publish();
    return r;
  }

  private valid(r: Run) {
    if (this.run !== r || r.abort.signal.aborted) throw new BridgeError('stopped');
    const now = Date.now();
    if (r.grant.kind === 'active' && (now >= r.grant.deadline || dayStart(now) !== r.grant.day)) throw new BridgeError('expired');
    if (now < r.clockAt - 1000 || now - r.clockAt > 3500) throw new BridgeError('clock-changed');
    return now;
  }

  private async connect(r: Run) {
    await this.bind(r);
    await this.catchUp(r);
    this.valid(r);
    r.synced = true;
    r.poll = this.watch(r);
    if (r.grant.kind === 'active') {
      this.show(r, 'scheduled');
      r.timer = setTimeout(() => this.launch(r), Math.max(0, r.grant.at - Date.now()));
    } else { this.show(r, 'listening'); this.debounce(r); }
  }

  private async bind(r: Run) {
    const remote = await r.reader.identify(r.target.account, r.abort.signal, !(r.grant.kind === 'auto' && r.grant.dry));
    this.valid(r);
    const identity = remoteIdentity(remote);
    const stored = this.journal.read(r.route);
    if ((stored && stored.identity !== identity) || (r.identity && r.identity !== identity)) throw new BridgeError('wechat-changed');
    r.identity = identity;
    r.cursor = stored?.cursor ?? null;
    r.scope = { ...remote.binding, conversation_id: r.target.contact };
  }

  private async catchUp(r: Run) {
    const began = performance.now();
    for (let i = 0; i < 160 && performance.now() - began < 11_000; i++) {
      this.valid(r);
      const page = await r.reader.page(r.scope!, r.cursor, false, r.abort.signal);
      await this.accept(r, page);
      if (!page.more) return;
    }
    throw new BridgeError('backlog-limit');
  }

  private async watch(r: Run) {
    let more = false;
    let draining = 0;
    while (this.run === r) {
      try {
        this.valid(r);
        const start = performance.now();
        const page = await r.reader.page(r.scope!, r.cursor, !more, r.abort.signal);
        await this.accept(r, page);
        if (this.run !== r) return;
        more = page.more;
        draining = more ? draining + 1 : 0;
        if (draining >= 160) throw new BridgeError('backlog-limit');
        r.synced = !more;
        if (!more) this.debounce(r);
        if (!more && !page.events.length && performance.now() - start < 150) await delay(550, undefined, { signal: r.abort.signal });
      } catch (e) {
        const why = code(e);
        if (this.run !== r) return;
        if (why !== 'mcp-offline' || r.grant.kind === 'active') { this.hold(r, why); return; }
        try { await this.reconnect(r); more = false; draining = 0; }
        catch (failure) { this.hold(r, code(failure)); return; }
      }
    }
  }

  private async reconnect(r: Run) {
    r.synced = false; r.version++; r.queue = []; r.context = [];
    r.generation?.abort();
    clearTimeout(r.timer); r.timer = undefined;
    this.show(r, 'retrying', 'mcp-offline');
    await r.reader.close();
    for (const ms of [350, 900, 2200, 4500]) {
      await delay(ms, undefined, { signal: r.abort.signal });
      r.replyAfter = this.valid(r);
      r.reader = new Xiaohe(r.target.mcp);
      try {
        await this.bind(r);
        await this.catchUp(r);
        this.valid(r);
        r.synced = true;
        this.show(r, 'listening');
        this.debounce(r);
        return;
      } catch (e) { await r.reader.close(); if (code(e) !== 'mcp-offline') throw e; }
    }
    throw new BridgeError('mcp-offline');
  }

  private async accept(r: Run, page: Page) {
    const now = this.valid(r);
    if (!page.events.length && page.cursor === r.cursor && this.journal.read(r.route)) return;
    r.processing = true;
    try {
      const seen = new Set<string>();
      const fresh = page.events.flatMap(raw => {
        const m = message(raw, r.scope!, r.since, now);
        if (!m || seen.has(m.key) || seen.has(m.refKey) || this.journal.known(r.route, m.key) || this.journal.known(r.route, m.refKey)) return [];
        seen.add(m.key); seen.add(m.refKey);
        return [m];
      });
      const stop = () => {
        this.journal.advance(r.route, r.identity, page.cursor, seen, now, r.peer);
        this.hold(r, 'peer-stopped');
      };
      if (fresh.some(m => m.text && classifyText(m.text) === 'stop')) { stop(); return; }
      const turn: Incoming[] = [];
      let manual = false, takeover = false, anchors = 0;
      for (const m of fresh) {
        if (m.self) {
          const pending = this.waiting;
          if (!this.journal.own(r.peer, r.identity, m.request, m.ref) && pending?.run === r) await pending.done;
          this.valid(r);
          if (!this.journal.own(r.peer, r.identity, m.request, m.ref)) takeover = true;
          continue;
        }
        if (!m.text) {
          if (++anchors > 4) throw new BridgeError('manual-review');
          try { m.text = await r.reader.anchor(r.scope!, m.ref, r.abort.signal); }
          catch (e) {
            // An unavailable body may have contained a stop request. Do not
            // silently skip it and reply to other messages on the same page.
            if (code(e) === 'no-anchor') { manual = true; continue; }
            throw e;
          }
          this.valid(r);
        }
        const rule = classifyText(m.text);
        if (rule === 'stop') { stop(); return; }
        if (m.created <= r.replyAfter || m.observed <= r.replyAfter || now - Math.min(m.created, m.observed) > MAX_AGE || r.grant.kind !== 'auto') continue;
        if (rule === 'manual') manual = true;
        else turn.push(m);
      }
      this.journal.advance(r.route, r.identity, page.cursor, seen, now);
      r.cursor = page.cursor;
      if (takeover || manual) { this.hold(r, takeover ? 'manual-takeover' : 'manual-review'); return; }
      if (turn.length) {
        r.version++;
        r.queue.push(...turn);
        if (r.queue.length > 8) this.hold(r, 'busy-chat');
        else r.generation?.abort();
      }
    } finally { r.processing = false; }
  }

  private debounce(r: Run) {
    if (this.run !== r || !r.synced || r.processing || r.work || !r.queue.length || r.grant.kind !== 'auto') return;
    clearTimeout(r.timer);
    const oldest = r.queue[0]!.seen;
    const latest = r.queue.at(-1)!.seen;
    r.timer = setTimeout(() => this.launch(r), Math.max(0, Math.min(oldest + 1350, latest + 620) - Date.now()));
  }

  private launch(r: Run) {
    if (this.run !== r || r.work) return;
    r.timer = undefined;
    r.work = this.respond(r).catch(e => {
      const why = code(e);
      if (why === 'turn-obsolete' && r.grant.kind === 'auto') {
        if (r.phase !== 'retrying') this.show(r, 'listening');
      }
      else if (why !== 'stopped') this.hold(r, why);
    }).finally(() => { r.work = undefined; this.debounce(r); });
  }

  private async respond(r: Run) {
    const start = this.valid(r);
    if (!r.synced || r.processing) {
      if (r.grant.kind === 'active') throw new BridgeError('send-fence');
      return;
    }
    const version = r.version;
    if (r.grant.kind === 'active') {
      const text = r.grant.text;
      await this.transmit(r, text, `wmb-${sha(`${r.peer}:${r.grant.request}`)}`, version);
      if (this.run === r) this.pause('one-shot-complete');
      return;
    }
    // Keep unhandled lines until a draft/skip is final or the send actually starts.
    // A newer line invalidates the decision, not the queued conversation.
    r.queue = r.queue.filter(m => start - Math.min(m.created, m.observed) <= MAX_AGE);
    const turn = r.queue.slice();
    if (!turn.length) return;
    if (turn.length > 4) throw new BridgeError('busy-chat');
    const texts = turn.map(m => m.text!);
    const modelAt = performance.now();
    const sample = texts.some(t => classifyText(t) === 'identity');
    this.show(r, 'generating');
    const isObsolete = () => !r.synced || r.processing || version !== r.version;
    let decision: Decision = { action: 'identity' };
    if (!sample) {
      const generation = r.generation = new AbortController();
      try {
        decision = await r.grant.model!.generate(texts, start - r.contextAt < 180_000 ? r.context : [],
          AbortSignal.any([r.abort.signal, generation.signal]));
      } catch (e) {
        this.valid(r);
        throw isObsolete() ? new BridgeError('turn-obsolete') : e;
      } finally { r.generation = undefined; }
    }
    this.valid(r);
    if (decision.action === 'stop') { this.journal.optOut(r.peer); this.hold(r, 'peer-stopped'); return; }
    if (isObsolete()) throw new BridgeError('turn-obsolete');
    if (decision.action === 'manual') throw new BridgeError('manual-review');
    const oldestAt = Math.min(...turn.map(m => Math.min(m.created, m.observed)));
    const checkAge = () => { if (Date.now() - oldestAt > MAX_AGE) throw new BridgeError('turn-obsolete'); };
    checkAge();
    const text = sendable(decision);
    if (!text || r.grant.dry) r.queue = [];
    if (!text) { this.show(r, 'listening', 'model-skip'); return; }
    if (r.grant.dry) {
      this.draft = { text, until: Date.now() + 45_000 };
      clearTimeout(this.draftTimer);
      this.draftTimer = setTimeout(() => { this.draft = undefined; this.publish(); }, 45_000);
      this.show(r, 'listening', 'draft-ready');
      this.publish();
    } else {
      const id = `wmb-${sha(`${r.peer}:${turn.map(m => m.refKey).sort().join(':')}`)}`;
      const gen = Math.round(performance.now() - modelAt);
      const first = turn[0]!;
      const sent = await this.transmit(r, text, id, version, checkAge);
      if (sent) this.journal.addTiming(r.peer, Date.now(), { ingest: Math.max(0, first.seen - first.observed),
        batch: Math.max(0, start - first.seen), model: gen, rpc: sent.rpc, total: Math.max(0, Date.now() - first.seen) });
      this.show(r, 'listening');
    }
    if (this.run === r) {
      r.context = [...r.context, ...texts.map(t => ({ from: 'peer' as const, text: t })), { from: 'auto' as const, text }].slice(-4);
      r.contextAt = Date.now();
    }
  }

  private async transmit(r: Run, text: string, attempt: string, version: number, checkAge = () => {}) {
    this.valid(r);
    const signal = r.abort.signal;
    const writer = r.writer;
    const scope = r.scope!;
    this.show(r, 'checking');
    const remote = await writer.identify(r.target.account, signal);
    this.valid(r);
    if (remoteIdentity(remote) !== r.identity) throw new BridgeError('wechat-changed');
    const cursor = r.cursor;
    const fence = await writer.page(scope, cursor, false, signal);
    this.valid(r);
    const check = () => {
      const now = this.valid(r);
      const newerPage = fence.more || fence.events.length > 0 || fence.cursor !== cursor;
      // If the writer saw a newer page before the reader, wait for the reader's next
      // pass instead of repeatedly generating for the same pending messages.
      if (newerPage && r.cursor === cursor) r.synced = false;
      if (!r.synced || r.processing || version !== r.version || newerPage || r.cursor !== cursor) {
        throw new BridgeError(r.grant.kind === 'active' ? 'send-fence' : 'turn-obsolete');
      }
      checkAge();
      return now;
    };
    check();
    if (this.waiting) throw new BridgeError('busy');
    let release!: () => void;
    const done = new Promise<void>(r => { release = r; });
    this.waiting = { run: r, done };
    let reserved = false, onWire = false, started = 0;
    try {
      const result = await writer.send(scope, text, attempt, () => {
        const now = check();
        this.journal.reserve(attempt, r.peer, r.route, r.identity, r.grant.kind, now);
        reserved = true;
        check();
        if (r.grant.kind === 'auto') r.queue = [];
        onWire = true; started = performance.now();
        queueMicrotask(() => this.show(r, 'sending'));
      });
      this.journal.complete(attempt, result);
      if (result.status === 'unknown') throw new BridgeError('send-unknown');
      if (result.status === 'rejected' || result.delivery === 'failed') throw new BridgeError('send-rejected');
      return { rpc: Math.round(performance.now() - started) };
    } catch (e) {
      const why = code(e);
      if (!reserved) throw e;
      if (!onWire || ['wechat-permission', 'wechat-changed', 'send-rejected'].includes(why)) {
        this.journal.complete(attempt, { status: 'rejected', delivery: 'failed' });
        throw e;
      }
      if (this.journal.get(attempt)?.status === 'trying') this.journal.complete(attempt, unknownReceipt);
      if (!this.run && this.reason !== 'peer-stopped') this.reason = 'send-unknown';
      throw new BridgeError('send-unknown');
    } finally {
      this.waiting = undefined;
      release();
      if (this.run !== r) void writer.close();
      this.publish();
    }
  }

  private hold(r: Run, why: string) {
    if (this.run !== r) return;
    try { if (READ_FAILURE.has(why)) this.journal.holdRead(r.route, r.identity, why); }
    finally { this.pause(why); }
  }

  async close() {
    if (this.closed) return;
    const r = this.run ?? this.waiting?.run;
    this.closed = true;
    this.lookup?.abort();
    this.pause();
    await this.waiting?.done;
    await Promise.allSettled([r?.poll, r?.work]);
    this.journal.close();
  }
}
