import { lstatSync, readdirSync, unlinkSync, utimesSync } from 'node:fs';
import { join } from 'node:path';
import { sha } from '../../contracts.ts';
import type { ModelRouter } from '../llm/router.ts';
import { assertPrivateFile, atomicWritePrivateFile, ensurePrivateDir, readPrivateFile } from '../storage/fs-safe.ts';
import type { MediaBlock, Scope, XiaoheClient } from './client.ts';
import type { EventInput } from './ingest.ts';

const CACHE_BYTES = 128 * 1024 * 1024;
const CACHE_TTL = 24 * 60 * 60_000;
const MEDIA_BYTES = 8 * 1024 * 1024;
type MediaOptions = { visionPresetId?: string; sttPresetId?: string; allowDownload?: boolean;
  cloudApproved?: boolean; priority?: 'reply' | 'background' };
const supported = (block: MediaBlock) => block.type === 'image' ?
  /^image\/(?:jpeg|png|gif|webp)$/.test(block.mimeType) :
  /^audio\/(?:wav|x-wav|mpeg|ogg|mp4|webm|flac)$/.test(block.mimeType);
const valid = (block: MediaBlock) => supported(block) && block.data.length > 0 &&
  block.data.length <= Math.floor(MEDIA_BYTES / 3) * 4 && block.data.length % 4 === 0 &&
  !/[^A-Za-z0-9+/]/.test(block.data.replace(/={1,2}$/, ''));

export class MediaEnricher {
  private readonly directory: string;

  constructor(dir: string, private readonly models: Pick<ModelRouter, 'vision' | 'stt'>,
    private readonly subscribed: (conversationId: string) => boolean) {
    this.directory = join(dir, 'media-cache');
  }

  prune(now = Date.now()) {
    ensurePrivateDir(this.directory);
    const rows: { path: string; time: number; size: number }[] = [];
    for (const name of readdirSync(this.directory)) {
      const path = join(this.directory, name);
      try {
        const stat = lstatSync(path);
        if (!/^[a-f0-9]{64}$/.test(name)) {
          if (stat.isFile() && name.startsWith('.') && now - stat.mtimeMs >= 60_000) unlinkSync(path);
          continue;
        }
        assertPrivateFile(stat);
        rows.push({ path, time: stat.mtimeMs, size: stat.size });
      } catch { /* 单个异常条目不中止其余缓存清理 */ }
    }
    rows.sort((a, b) => b.time - a.time);
    let bytes = 0;
    for (const row of rows) {
      if (now - row.time >= CACHE_TTL || bytes + row.size > CACHE_BYTES) {
        try { unlinkSync(row.path); } catch { /* 忽略并发删除 */ }
      } else bytes += row.size;
    }
  }

  private cache(key: string, block: MediaBlock) {
    this.prune();
    const path = join(this.directory, sha(key));
    try { readPrivateFile(path, MEDIA_BYTES); }
    catch { atomicWritePrivateFile(path, Buffer.from(block.data, 'base64')); }
    const now = new Date();
    utimesSync(path, now, now);
    this.prune();
    return path;
  }

  async enrich(input: EventInput, scope: Scope, client: Pick<XiaoheClient, 'readMedia'>, options: MediaOptions = {}, signal?: AbortSignal): Promise<EventInput> {
    const { event, mediaRef } = input;
    if (!this.subscribed(event.conversationId) || scope.conversation_id !== event.conversationId ||
        scope.account_id !== event.accountId || (event.kind !== 'image' && event.kind !== 'voice')) return input;
    const image = event.kind === 'image';
    const preset = image ? options.visionPresetId : options.sttPresetId;
    if (!image && event.text.trim() && !/^\[(?:语音|voice)\]$/i.test(event.text.trim())) {
      return { ...input, event: { ...event, media: { enrichmentStatus: 'ok', transcript: event.text } } };
    }
    const degraded: EventInput = { ...input, event: { ...event, text: image ? '[图片]' : '[语音]', media: { enrichmentStatus: 'degraded' } } };
    if (!preset || !mediaRef) return degraded;
    const timer = AbortSignal.timeout(10_000);
    const bounded = signal ? AbortSignal.any([signal, timer]) : timer;
    try {
      bounded.throwIfAborted();
      const media = await client.readMedia(scope, mediaRef, { representation: 'preview',
        allowDownload: image && options.allowDownload === true, ...(image && { maxDimension: 1280, frameCount: 3 }) }, bounded);
      if (!this.subscribed(event.conversationId)) return input;
      const blocks = media.blocks.filter(block => block.type === (image ? 'image' : 'audio') && valid(block)).slice(0, image ? 3 : 1);
      const first = blocks[0];
      if (!first) return degraded;
      const path = this.cache(JSON.stringify([input.identity, scope.conversation_id, mediaRef]), first);
      const modelOptions = { signal: bounded, priority: options.priority, cloudApproved: options.cloudApproved };
      const text = (await (image ? this.models.vision(preset, blocks, modelOptions) :
        this.models.stt(preset, first, modelOptions))).trim().slice(0, 2000);
      if (!text || bounded.aborted) return degraded;
      return { ...input, event: { ...event, text, media: { mimeType: first.mimeType, localTempPath: path,
        enrichmentStatus: 'ok', ...(image ? { caption: text } : { transcript: text }) } } };
    } catch { return degraded; }
  }
}
