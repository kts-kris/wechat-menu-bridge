import { createHash } from 'node:crypto';
import { z } from 'zod';

export class BridgeError extends Error {
  constructor(readonly code: string) { super(code); }
}
export const object = (x: unknown): Record<string, unknown> | undefined =>
  x !== null && typeof x === 'object' && !Array.isArray(x) ? x as Record<string, unknown> : undefined;
export const id = (x: unknown): x is string => typeof x === 'string' && x.length > 0 && x.length <= 2048 && !/\p{Cc}/u.test(x);
export const sha = (x: string) => createHash('sha256').update(x).digest('hex');
export const directID = (x: unknown): x is string => typeof x === 'string' && /^wxid_[a-z0-9_]{1,128}$/i.test(x);
export function endpoint(raw: string, kind: 'mcp' | 'local' | 'cloud') {
  let u: URL;
  try { u = new URL(raw); } catch { throw new BridgeError('invalid-endpoint'); }
  const approvedPath = kind === 'mcp' ? u.pathname === '/mcp' : /\/chat\/completions$/.test(u.pathname);
  const local = u.protocol === 'http:' && u.hostname === '127.0.0.1' && !!u.port;
  const cloud = u.protocol === 'https:' && u.hostname !== 'localhost' && u.hostname !== '127.0.0.1' && !u.hostname.startsWith('[');
  if (u.href !== raw || u.username || u.password || u.hash || u.search || !approvedPath || (kind === 'cloud' ? !cloud : !local)) {
    throw new BridgeError('invalid-endpoint');
  }
  return u;
}
const ident = z.string().refine(id);
const address = z.string().min(1).max(512);
const safePath = z.string().refine(x => x === '' || (x.startsWith('/') && /\.(md|txt)$/i.test(x) && x.length <= 4096 && !/\p{Cc}/u.test(x)));
export const targetSchema = z.strictObject({
  mcp: address, account: ident, contact: z.string().refine(directID),
});
export const modelSchema = z.strictObject({
  mode: z.enum(['local', 'cloud']), url: address, name: z.string().trim().min(1).max(160),
  reasoningEffort: z.enum(['default', 'low', 'medium', 'high', 'max']).optional(),
  stylePath: safePath, memoryPath: safePath, cloudApproved: z.boolean(),
  apiKey: z.string().min(1).max(4096).regex(/^[\x21-\x7e]+$/).optional(),
});
export const armSchema = z.strictObject({
  target: targetSchema, model: modelSchema, consent: z.literal(true), dryRun: z.boolean(),
});
export const activeSchema = z.strictObject({
  target: targetSchema, consent: z.literal(true), text: z.string().trim().min(1).max(500).regex(/^[^\p{Cc}]+$/u),
  request: z.uuid(), at: z.number().int().optional(),
});
export type Target = z.infer<typeof targetSchema>;
export type ModelConfig = z.infer<typeof modelSchema>;
export type ArmConfig = z.infer<typeof armSchema>;
export type ActiveConfig = z.infer<typeof activeSchema>;

export function checked<T extends z.ZodType>(schema: T, value: unknown): z.infer<T> {
  const r = schema.safeParse(value);
  if (!r.success) throw new BridgeError('invalid-configuration');
  return r.data;
}

export function tomorrow(now: number) {
  const d = new Date(now);
  d.setHours(24, 0, 0, 0);
  return d.getTime();
}
export function dayStart(now: number) {
  const d = new Date(now);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}
