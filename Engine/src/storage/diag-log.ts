import { closeSync, constants, fstatSync, openSync, readSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { isErrorCode } from '../contracts/errors.ts';
import type { SessionTraceEntry } from '../contracts/ipc.ts';
import { assertPrivateFile, atomicWritePrivateFile } from './fs-safe.ts';

const MAX_BYTES = 256 * 1024;

export class DiagnosticLog {
  private readonly path: string;

  constructor(stateDir: string) { this.path = join(stateDir, 'engine.log'); }

  append({ at, conversationId, stage, level, summary, detail }: SessionTraceEntry) {
    // 摘要来自引擎内置事件。详情可能带有微信昵称，只允许标准错误码落盘。
    const line = Buffer.from(JSON.stringify({ at, session: conversationId.slice(-8), stage, level, summary,
      ...(isErrorCode(detail) && { code: detail }) }) + '\n');
    let fd: number | undefined;
    try {
      fd = openSync(this.path, constants.O_RDWR | constants.O_CREAT | constants.O_APPEND |
        constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
      const stat = fstatSync(fd);
      assertPrivateFile(stat);
      if (stat.size + line.length <= MAX_BYTES) {
        writeFileSync(fd, line);
        return;
      }
      const keep = Buffer.alloc(MAX_BYTES / 2);
      const offset = Math.max(0, stat.size - keep.length);
      const read = readSync(fd, keep, 0, keep.length, offset);
      const tail = keep.subarray(0, read);
      const firstComplete = offset ? tail.indexOf(10) : -1;
      const retained = offset && firstComplete < 0 ? Buffer.alloc(0) : tail.subarray(firstComplete + 1);
      atomicWritePrivateFile(this.path, Buffer.concat([retained, line]));
    } catch { /* 诊断日志故障不阻断会话 */ }
    finally { if (fd !== undefined) closeSync(fd); }
  }
}
