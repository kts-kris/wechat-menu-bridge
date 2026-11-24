import { IDENTITY, inspectDraft, inspectText, type DraftReviewRule, type TextReviewRule } from '../../policy.ts';
import type { Decision } from '../../model.ts';
import type { NormalizedEvent } from '../contracts/events.ts';
import { riskLevel, type ConversationPolicy, type RiskLevel } from '../contracts/settings.ts';

type Action = 'lock_peer' | 'pause_session' | 'cooldown_or_pause' | 'skip_turn' | 'identity' | 'allow';
type ReviewHit = { source: 'inbound'; rule: TextReviewRule } | { source: 'outbound'; rule: DraftReviewRule } |
  { source: 'model' | 'unparsed-media' | 'unavailable-body' };
export type PolicyDecision = {
  action: Action;
  reason?: 'peer-stopped' | 'manual-review' | 'manual-takeover' | 'busy-chat' | 'model-skip';
  text?: string;
  review?: ReviewHit;
};

const reviewLabels: Record<DraftReviewRule, string> = {
  credentials: '账号凭据或验证码', finance: '资金或借还', privacy: '个人隐私或敏感号码',
  legal: '合同或签字', health: '诊疗或用药', crisis: '人身安全', instructions: '提示词或指令',
  link: '链接或邮箱', commitment: '承诺或代为表态', schedule: '时间或见面约定', delegation: '委托或提醒',
  'sensitive-topic': '敏感话题', numbers: '数字或金额格式', 'scoped-no-reply': '请求不回复这个话题',
  length: '来信过长', 'input-format': '来信含控制字符', 'draft-format': '草稿为空、过长或含控制字符',
  'identity-claim': '草稿冒充本人', 'recipient-intent': '草稿含叫停或身份询问', 'personal-assertion': '未经核实的个人事实或表态',
};

export function reviewDescription(hit: ReviewHit) {
  switch (hit.source) {
    case 'inbound': return `入站规则：${reviewLabels[hit.rule]}`;
    case 'outbound': return `出站草稿规则：${reviewLabels[hit.rule]}`;
    case 'model': return '模型建议转人工';
    case 'unparsed-media': return '无法解析图片或语音';
    case 'unavailable-body': return '消息正文无法核对';
  }
}

export function manualReview(action: 'pause_session' | 'skip_turn', review: ReviewHit): PolicyDecision {
  return { action, reason: 'manual-review', review };
}

function ordinaryNumbers(text: string) {
  const normalized = text.normalize('NFKC');
  const sensitive = /(?:简讯|短信|动态码|验证|校验码|安全码|授权码|确认码|口令|OTP|PIN code|verification|one.time|双重认证|登录|login|code|手机|电话|联系号码|银行卡|卡号|身份证|证件|账号|账户|支付|收款|汇款|金额|借|欠|转给|转你|付给|收费|账单|买单|结账|报酬|押金|红包|工资|payment)/iu;
  // 保留原规则中数字与定时、借款归还、金额单位的组合。只消除独立数字串的泛化误判。
  return normalized.replace(/(?<!\d)\d{4,}(?!\d)/gu, (digits, at: number) => {
    const before = normalized.slice(Math.max(0, at - 24), at);
    const after = normalized.slice(at + digits.length, at + digits.length + 24);
    if (sensitive.test(normalized) || /^(?:(?:(?:00)?86)?1[3-9]\d{9}|\d{16,19})$/.test(digits) ||
      (digits.length === 17 && /^[xX]/.test(after)) || /还/u.test(after) ||
      /^\s*(?:[:：]|点|号|元|块|万)/u.test(after) || /\d[\s-]$/u.test(before) || /^[\s-]\d/u.test(after)) return digits;
    return '数'.repeat(digits.length);
  });
}

export class PolicyEngine {
  classify(text: string) {
    return this.inboundMatch(text, 'strict')?.action;
  }

  inboundMatch(text: string, level: RiskLevel) {
    if (level === 'recommended' || level === 'minimal') return inspectText(text, level);
    const original = inspectText(text, 'minimal');
    return original?.action === 'stop' ? original : inspectText(ordinaryNumbers(text));
  }

  inbound(event: NormalizedEvent, policy: ConversationPolicy, own: boolean, awaitingMedia = false): PolicyDecision {
    if (event.origin !== 'live' || event.kind === 'recall') return { action: 'skip_turn' };
    if (event.isSelf) return own || policy.riskProfile.takeoverAction === 'ignore'
      ? { action: 'skip_turn' } : { action: 'cooldown_or_pause', reason: 'manual-takeover' };
    const level = riskLevel(policy.riskProfile);
    const match = this.inboundMatch(event.text, level);
    if (match?.action === 'stop') return { action: 'lock_peer', reason: 'peer-stopped' };
    const referenced = event.scopeType !== 'group' || policy.groupTrigger === 'all' || event.mentions.mentionsSelf;
    if (!referenced) return { action: 'skip_turn' };
    if (match?.action === 'manual') {
      return manualReview(level === 'strict' ? 'pause_session' : 'skip_turn', { source: 'inbound', rule: match.rule });
    }
    if (match?.action === 'identity') return { action: 'identity', text: IDENTITY };
    if ((event.kind === 'voice' || event.kind === 'image') && event.media?.enrichmentStatus !== 'ok') {
      if (awaitingMedia) return { action: 'allow' };
      return manualReview(level === 'strict' ? 'pause_session' : policy.riskProfile.unparsedMediaAction, { source: 'unparsed-media' });
    }
    if (!event.text || !['text', 'image', 'voice'].includes(event.kind)) return { action: 'skip_turn' };
    return { action: 'allow' };
  }

  busy(policy: ConversationPolicy): PolicyDecision {
    return { action: riskLevel(policy.riskProfile) === 'strict' ? 'pause_session' : policy.riskProfile.busyChatAction,
      reason: 'busy-chat' };
  }

  outbound(decision: Decision, level: RiskLevel = 'strict'): PolicyDecision {
    const manualAction = level === 'strict' ? 'pause_session' : 'skip_turn';
    switch (decision.action) {
      case 'stop': return { action: 'lock_peer', reason: 'peer-stopped' };
      case 'manual': return manualReview(manualAction, { source: 'model' });
      case 'skip': return { action: 'skip_turn', reason: 'model-skip' };
      case 'identity': return { action: 'identity', text: IDENTITY };
      case 'reply': {
        const conservative = level === 'strict' || level === 'legacy';
        const rule = !decision.text.trim() || decision.text.length > 140 || /[\p{Cc}\p{Cf}]/u.test(decision.text)
          ? 'draft-format' : inspectDraft(conservative ? ordinaryNumbers(decision.text) : decision.text, conservative);
        return rule ? manualReview(manualAction, { source: 'outbound', rule }) : { action: 'allow', text: decision.text };
      }
    }
  }
}
