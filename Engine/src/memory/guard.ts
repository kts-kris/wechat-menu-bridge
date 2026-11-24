import { randomUUID } from 'node:crypto';
import { BridgeError } from '../contracts/errors.ts';
import {
  MAX_ENTRY_CHARS, MAX_MEMORY_BYTES, charCount, expired, localDate,
  type MemoryEntry, type MemoryTarget, type PatchOperation, type RevisionSource, type Visibility,
} from './types.ts';

// 保守处理格式化数字、全角字符及中英文隐私用词；此处只降级，不尝试猜测或复原隐私。
const SENSITIVE = [
  /(?<!\d)1[\s.()-]*[3-9](?:[\s.()-]*\d){9}(?!\d)/u,
  /(?<!\d)\d(?:[\s.()-]*\d){12,18}(?:[\s-]*[xX])?(?!\d)/u,
  /手机号|联系电话|身份证(?:号|号码)|银行卡(?:号|号码)?|信用卡号|卡号|密码|验证码|校验码|口令|密钥|password|passcode|\bpin\s*[:=]|\botp\b|verification code|credit card|social security/i,
  /住址|地址\s*[:：是]|家庭地址|门牌(?:号)?|住在|入户|(?:省|市|区|县|镇|乡|街道|小区|大道|路|街|巷).{0,24}[\d零〇一二三四五六七八九十百]+\s*(?:号(?:楼|院)?|栋|幢|单元|室)|\d+\s*(?:号楼|栋|幢|单元|室)|\b\d+\s+.{1,35}\b(?:street|road|avenue|drive|lane|st\.|rd\.)/i,
  /[¥$€£]\s*\d|\d[\d,.]*\s*(?:[万亿千百]\s*)?(?:元|块(?:钱)?|人民币|美元|欧元|港币|CNY\b|RMB\b|USD\b|EUR\b)|[一二两三四五六七八九十][零一二两三四五六七八九十百千万亿]+\s*(?:元|块钱|人民币|美元|欧元)|(?:金额|转账|汇款|余额|存款|工资|薪资|报价|账单|价格|花费|花了|预算|红包|人民币|CNY\b|RMB\b|USD\b|EUR\b)\D{0,8}\d/i,
  /健康|病历|病例|病情|病史|慢性病|生病|患病|诊断|确诊|就诊|住院|手术|处方|体检|医疗|医保|医院|门诊|医生|药物|服药|血压|血糖|控糖|糖尿病|抑郁|癌症|化疗|妊娠|怀孕|过敏|medical|diagnos(?:is|ed)|hospital|prescription/i,
];
const invisible = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u;
const unsafeEntry = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]|<!--|-->/u;
const unsafeDocument = /[^\P{Cc}\t\r\n]|[\p{Cf}\p{Zl}\p{Zp}]/u;
const normalized = (value: string) => value.normalize('NFKC').replace(/\p{Cf}/gu, '').trim().replace(/\s+/gu, ' ').toLowerCase();

export function containsSensitiveMemory(text: string) {
  const value = normalized(text);
  return SENSITIVE.some(rule => rule.test(value));
}

export class MemoryGuard {
  allowsCloud(content: string) { return !unsafeEntry.test(content) && !containsSensitiveMemory(content); }

  assertDocument(text: string) {
    if (Buffer.byteLength(text) > MAX_MEMORY_BYTES || unsafeDocument.test(text.replace(/^\uFEFF/, ''))) {
      throw new BridgeError('invalid-configuration');
    }
  }

  assertEntry(content: string) {
    if (!content.trim() || charCount(content) > MAX_ENTRY_CHARS || unsafeEntry.test(content)) {
      throw new BridgeError('invalid-configuration');
    }
  }

  // 手写段落允许换行和缩进，但不允许注入不可见控制字符。
  assertHandwritten(content: string) {
    if (charCount(content) > MAX_ENTRY_CHARS || invisible.test(content.replace(/\r?\n|\t/g, ''))) {
      throw new BridgeError('invalid-configuration');
    }
  }

  visibility(content: string, suggested: Visibility): Visibility {
    return this.allowsCloud(content) ? suggested : 'local-only';
  }

  applyPatch(entries: readonly MemoryEntry[], operations: readonly PatchOperation[], options: {
    target: MemoryTarget; source: RevisionSource; now: number; archiveExpired?: boolean;
  }): MemoryEntry[] {
    const today = localDate(options.now);
    const result = new Map(entries.map(entry => [entry.id, entry]));
    const archives = new Set(operations.filter(op => op.op === 'archive').map(op => op.entryId));
    for (const entry of entries) {
      if (!entry.locked && (archives.has(entry.id) || (options.archiveExpired && expired(entry, today)))) result.delete(entry.id);
    }
    const duplicateOf = (content: string, except?: string) => [...result.values()].find(entry =>
      entry.id !== except && normalized(entry.content) === normalized(content));
    // 先更新原 ID，再处理新增，避免「先 add 再 update 同一事实」造成不必要的 ID 变化。
    const changes = [...operations.filter(op => op.op === 'update'), ...operations.filter(op => op.op === 'add')];
    for (const operation of changes) {
      if (operation.op === 'update') {
        const entry = result.get(operation.entryId);
        if (!entry || entry.locked || !entry.managed) continue;
        this.assertEntry(operation.content);
        const duplicate = duplicateOf(operation.content, entry.id);
        if (duplicate) {
          // 不用较公开的副本替代已有私有条目，也不丢掉原有事实。
          if (entry.visibility === 'cloud-safe' || duplicate.visibility === 'local-only') result.delete(entry.id);
          continue;
        }
        const visibility = this.visibility(operation.content, entry.visibility === 'local-only' ? 'local-only' : operation.suggestedVisibility);
        if (entry.content !== operation.content || entry.visibility !== visibility) {
          result.set(entry.id, { ...entry, content: operation.content, visibility, updated: today, source: options.source });
        }
      } else {
        this.assertEntry(operation.content);
        if (duplicateOf(operation.content)) continue;
        const id = `${options.target.kind === 'persona' ? 'p' : 'm'}_${randomUUID().replace(/-/g, '').slice(0, 28)}`;
        result.set(id, {
          id, section: operation.section, content: operation.content, managed: true, locked: false,
          source: options.source, updated: today, visibility: this.visibility(operation.content, operation.suggestedVisibility),
          ...(operation.ttlDays === undefined ? {} : { expires: localDate(options.now, operation.ttlDays) }),
        });
      }
    }
    return [...result.values()];
  }
}
