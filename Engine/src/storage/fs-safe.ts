import { randomUUID } from 'node:crypto';
import {
  closeSync, constants, fchmodSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readSync,
  realpathSync, renameSync, unlinkSync, writeFileSync, type Stats,
} from 'node:fs';
import { basename, dirname, isAbsolute, join, normalize, sep } from 'node:path';
import { BridgeError } from '../contracts/errors.ts';

const PRIVATE_DIR = 0o700;
const PRIVATE_FILE = 0o600;
const MODE_MASK = 0o7777;
const storageError = () => new BridgeError('storage-unavailable');
const missing = (error: unknown) => (error as NodeJS.ErrnoException | undefined)?.code === 'ENOENT';
const directoryPath = (path: string) => normalize(path).replace(/\/+$/, '') || sep;

function validateDir(path: string) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.uid !== process.getuid?.() || (stat.mode & MODE_MASK) !== PRIVATE_DIR) {
    throw storageError();
  }
}

export function assertPrivateFile(stat: Stats) {
  if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== process.getuid?.() || (stat.mode & MODE_MASK) !== PRIVATE_FILE) {
    throw storageError();
  }
}

// 由调用方指定已存在的父目录。拒绝替换现有非私有目录或链接。
export function ensurePrivateDir(path: string): void {
  try {
    if (!isAbsolute(path) || path.split(sep).includes('..')) throw storageError();
    try { mkdirSync(path, { mode: PRIVATE_DIR }); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error; }
    validateDir(directoryPath(path));
  } catch { throw storageError(); }
}

export function readPrivateFile(path: string, maxBytes = 64 * 1024): Buffer {
  try {
    if (!isAbsolute(path) || path.split(sep).includes('..') || !Number.isSafeInteger(maxBytes) || maxBytes < 0) {
      throw storageError();
    }
    const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const stat = fstatSync(fd);
      assertPrivateFile(stat);
      if (stat.size > maxBytes) throw storageError();
      // 多读一个字节，检测检查文件长度后发生的追加。
      const data = Buffer.alloc(stat.size + 1);
      let offset = 0;
      while (offset < data.length) {
        const read = readSync(fd, data, offset, data.length - offset, offset);
        if (read === 0) break;
        offset += read;
      }
      if (offset !== stat.size) throw storageError();
      return data.subarray(0, offset);
    } finally { closeSync(fd); }
  } catch { throw storageError(); }
}

export function atomicWritePrivateFile(path: string, data: string | Uint8Array): void {
  let temporary: string | undefined;
  try {
    if (!isAbsolute(path) || path.endsWith(sep) || path.split(sep).includes('..')) throw storageError();
    const dir = directoryPath(dirname(path));
    validateDir(dir);
    try { assertPrivateFile(lstatSync(path)); }
    catch (error) { if (!missing(error)) throw error; }
    const candidate = join(dir, `.${basename(path)}.${randomUUID()}.tmp`);
    const fd = openSync(candidate, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, PRIVATE_FILE);
    temporary = candidate;
    try {
      fchmodSync(fd, PRIVATE_FILE);
      writeFileSync(fd, data);
      fsyncSync(fd);
    } finally { closeSync(fd); }
    renameSync(candidate, path);
    temporary = undefined;
    const parent = openSync(dir, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    try { fsyncSync(parent); } finally { closeSync(parent); }
  } catch { throw storageError(); }
  finally {
    if (temporary) {
      try { unlinkSync(temporary); } catch { /* 保留写入错误 */ }
    }
  }
}

// root 是受信的容器目录。允许新建路径，但路径上已存在的节点不能是符号链接。
export function resolveContainedPath(root: string, relativePath: string): string {
  try {
    const parts = relativePath.split('/');
    if (!isAbsolute(root) || root.split(sep).includes('..') || isAbsolute(relativePath) ||
        /^[a-z]:/i.test(relativePath) || relativePath.includes('\\') ||
        parts.some(part => !part || part === '.' || part === '..' || part.includes('\0'))) {
      throw storageError();
    }
    const container = directoryPath(root);
    if (!lstatSync(container).isDirectory()) throw storageError();
    let current = realpathSync(container);
    for (const [index, part] of parts.entries()) {
      current = join(current, part);
      try {
        const stat = lstatSync(current);
        if (stat.isSymbolicLink() || (index < parts.length - 1 && !stat.isDirectory())) throw storageError();
      } catch (error) { if (!missing(error)) throw error; }
    }
    return current;
  } catch { throw storageError(); }
}
