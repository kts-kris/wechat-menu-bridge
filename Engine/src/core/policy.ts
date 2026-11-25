import { IDENTITY, inspectDraft, inspectText, inspectTextAll, type DraftReviewRule, type TextReviewRule } from '../../policy.ts';
import type { Decision } from '../../model.ts';
import type { NormalizedEvent } from '../contracts/events.ts';
import type { PolicyEvaluateResult, PolicyEvaluateStep } from '../contracts/ipc.ts';
import {
  CUSTOMIZABLE_RULES, riskLevel,
  type ConversationPolicy, type CustomizableRuleId, type QuietHoursConfig, type RiskLevel,
} from '../contracts/settings.ts';

function clockMinutes(value: string): number {
  const [h, m] = value.split(':').map(Number);
  return (h ?? 0) * 60 + (m ?? 0);
}

/** 判定本机当前时间是否落在勿扰时间窗内；支持跨零点（如 23:00–08:00），起止相同时视为未命中。 */
export function isInQuietHours(config: QuietHoursConfig | undefined, nowMs: number): boolean {
  if (!config?.enabled) return false;
  const start = clockMinutes(config.start);
  const end = clockMinutes(config.end);
  if (start === end) return false;
  const d = new Date(nowMs);
  const current = d.getHours() * 60 + d.getMinutes();
  return start < end ? current >= start && current < end : current >= start || current < end;
}

/** NFKC + 大小写不敏感子串匹配，用于会话触发白名单、忽略黑名单与自定义必拦词。 */
export function matchesKeywordList(text: string, keywords: readonly string[]): boolean {
  if (!text || !keywords.length) return false;
  const haystack = text.normalize('NFKC').toLowerCase();
  for (const raw of keywords) {
    const needle = raw.trim().normalize('NFKC').toLowerCase();
    if (needle && haystack.includes(needle)) return true;
  }
  return false;
}

const CUSTOMIZABLE_RULE_SET = new Set<string>(CUSTOMIZABLE_RULES);
const HIGH_RISK_CUSTOMIZABLE = new Set<CustomizableRuleId>(['credentials', 'finance', 'privacy', 'legal', 'health']);

export type EffectiveRuleAction = 'allow' | 'skip_turn' | 'draft_only' | 'pause_session';

export function defaultRuleAction(level: RiskLevel, rule: CustomizableRuleId): 'allow' | 'skip_turn' | 'pause_session' {
  if (level === 'strict') return 'pause_session';
  if (level === 'legacy') return 'skip_turn';
  if (level === 'recommended') return HIGH_RISK_CUSTOMIZABLE.has(rule) ? 'skip_turn' : 'allow';
  return 'allow';
}

export function effectiveRuleAction(profile: ConversationPolicy['riskProfile'], rule: CustomizableRuleId): EffectiveRuleAction {
  const override = profile.ruleOverrides?.[rule];
  if (override && override !== 'inherit') return override;
  return defaultRuleAction(riskLevel(profile), rule);
}

const ACTION_SEVERITY: Record<EffectiveRuleAction, number> = {
  allow: 0,
  skip_turn: 1,
  draft_only: 2,
  pause_session: 3,
};

type Action = 'lock_peer' | 'pause_session' | 'cooldown_or_pause' | 'skip_turn' | 'draft_only' | 'identity' | 'allow';
type ReviewHit =
  | { source: 'inbound'; rule: TextReviewRule }
  | { source: 'outbound'; rule: DraftReviewRule }
  | { source: 'custom-keyword' }
  | { source: 'model' | 'unparsed-media' | 'unavailable-body' };
export type KeywordGate = 'ignored' | 'trigger-missed' | 'group-unmentioned';
export type PolicyDecision = {
  action: Action;
  reason?: 'peer-stopped' | 'manual-review' | 'manual-takeover' | 'busy-chat' | 'model-skip';
  text?: string;
  review?: ReviewHit;
  keywordGate?: KeywordGate;
};

const reviewLabels: Record<DraftReviewRule, string> = {
  credentials: '账号凭据或验证码', finance: '资金或借还', privacy: '个人隐私或敏感号码',
  legal: '合同或签字', health: '诊疗或用药', crisis: '人身安全', instructions: '提示词或指令',
  link: '链接或邮箱', commitment: '承诺或代为表态', schedule: '时间或见面约定', delegation: '委托或提醒',
  'sensitive-topic': '敏感话题', numbers: '数字或金额格式', 'scoped-no-reply': '请求不回复这个话题',
  length: '来信过长', 'input-format': '来信含控制字符', 'draft-format': '草稿为空、过长或含控制字符',
  'identity-claim': '草稿冒充本人', 'recipient-intent': '草稿含叫停或身份询问', 'personal-assertion': '未经核实的个人事实或表态',
};

const finalActionLabels: Record<PolicyEvaluateResult['finalAction'], string> = {
  allow: '放行进入模型回复',
  draft_only: '仅生成草稿（不自动发送）',
  skip_turn: '跳过本轮（保持监听）',
  pause_session: '暂停本会话（转人工处理）',
  lock_peer: '永久锁定退订（peer-stopped）',
  identity: '回复固定自动回复身份说明',
};

export function reviewDescription(hit: ReviewHit) {
  switch (hit.source) {
    case 'inbound': return `入站规则：${reviewLabels[hit.rule]}`;
    case 'outbound': return `出站草稿规则：${reviewLabels[hit.rule]}`;
    case 'custom-keyword': return '入站规则：自定义必拦词';
    case 'model': return '模型建议转人工';
    case 'unparsed-media': return '无法解析图片或语音';
    case 'unavailable-body': return '消息正文无法核对';
  }
}

export function manualReview(action: 'pause_session' | 'skip_turn' | 'draft_only', review: ReviewHit): PolicyDecision {
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

type RiskResolution =
  | { kind: 'stop' }
  | { kind: 'identity' }
  | { kind: 'manual'; action: 'skip_turn' | 'draft_only' | 'pause_session'; review: ReviewHit; matchedRule: string }
  | { kind: 'none' };

function evaluateKeywordGate(text: string, policy: ConversationPolicy, scopeType: ConversationPolicy['type'], mentionsSelf: boolean): KeywordGate | undefined {
  if (policy.ignoreKeywords.length > 0 && matchesKeywordList(text, policy.ignoreKeywords)) {
    return 'ignored';
  }
  const hasTriggers = policy.triggerKeywords.length > 0;
  const hitTrigger = hasTriggers && matchesKeywordList(text, policy.triggerKeywords);
  if (scopeType === 'group') {
    if (policy.groupTrigger === 'mention_only') {
      if (!mentionsSelf && !hitTrigger) return 'group-unmentioned';
    } else if (hasTriggers && !hitTrigger) {
      return 'trigger-missed';
    }
  } else if (hasTriggers && !hitTrigger) {
    return 'trigger-missed';
  }
  return undefined;
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

  resolveRisk(text: string, profile: ConversationPolicy['riskProfile']): RiskResolution {
    const level = riskLevel(profile);
    if (inspectTextAll(text, 'minimal').stop) return { kind: 'stop' };
    const explicitBlockingRules: TextReviewRule[] = CUSTOMIZABLE_RULES.filter(rule => {
      const override = profile.ruleOverrides?.[rule];
      return override !== undefined && override !== 'inherit' && override !== 'allow';
    });
    const sanitized = ordinaryNumbers(text);
    const inspection = level === 'recommended' || level === 'minimal'
      ? inspectTextAll(text, level, explicitBlockingRules, sanitized)
      : inspectTextAll(sanitized, 'strict');
    if (inspection.stop) return { kind: 'stop' };
    const defaultManual: 'pause_session' | 'skip_turn' = level === 'strict' ? 'pause_session' : 'skip_turn';
    if (inspection.scopedNoReply) {
      return { kind: 'manual', action: defaultManual, review: { source: 'inbound', rule: 'scoped-no-reply' }, matchedRule: 'scoped-no-reply' };
    }
    if (level !== 'strict' && inspection.asksIdentity) return { kind: 'identity' };

    let best: { action: 'skip_turn' | 'draft_only' | 'pause_session'; review: ReviewHit; matchedRule: string } | undefined;
    const consider = (action: 'skip_turn' | 'draft_only' | 'pause_session', review: ReviewHit, matchedRule: string) => {
      if (!best || ACTION_SEVERITY[action] > ACTION_SEVERITY[best.action]) {
        best = { action, review, matchedRule };
      }
    };

    for (const rule of inspection.rules) {
      if (CUSTOMIZABLE_RULE_SET.has(rule)) {
        const action = effectiveRuleAction(profile, rule as CustomizableRuleId);
        if (action !== 'allow') consider(action, { source: 'inbound', rule }, rule);
      } else {
        consider(defaultManual, { source: 'inbound', rule }, rule);
      }
    }

    if (profile.customBlockKeywords.length > 0 && matchesKeywordList(text, profile.customBlockKeywords)) {
      consider(profile.customBlockAction, { source: 'custom-keyword' }, 'custom-keyword');
    }

    if (best) return { kind: 'manual', ...best };
    if (inspection.asksIdentity) return { kind: 'identity' };
    return { kind: 'none' };
  }

  inbound(event: NormalizedEvent, policy: ConversationPolicy, own: boolean, awaitingMedia = false): PolicyDecision {
    if (event.origin !== 'live' || event.kind === 'recall') return { action: 'skip_turn' };
    if (event.isSelf) return own || policy.riskProfile.takeoverAction === 'ignore'
      ? { action: 'skip_turn' } : { action: 'cooldown_or_pause', reason: 'manual-takeover' };
    const level = riskLevel(policy.riskProfile);
    const risk = this.resolveRisk(event.text, policy.riskProfile);
    if (risk.kind === 'stop') return { action: 'lock_peer', reason: 'peer-stopped' };
    if (risk.kind === 'manual' && risk.matchedRule === 'crisis') {
      return manualReview(risk.action, risk.review);
    }
    const gate = evaluateKeywordGate(event.text, policy, event.scopeType, event.mentions.mentionsSelf);
    if (gate) return { action: 'skip_turn', keywordGate: gate };
    if (risk.kind === 'manual') return manualReview(risk.action, risk.review);
    if (risk.kind === 'identity') return { action: 'identity', text: IDENTITY };
    if ((event.kind === 'voice' || event.kind === 'image') && event.media?.enrichmentStatus !== 'ok') {
      if (awaitingMedia) return { action: 'allow' };
      return manualReview(level === 'strict' ? 'pause_session' : policy.riskProfile.unparsedMediaAction, { source: 'unparsed-media' });
    }
    if (!event.text || !['text', 'image', 'voice'].includes(event.kind)) return { action: 'skip_turn' };
    return { action: 'allow' };
  }

  /** 本地规则判定链模拟器：与运行期共享同一套判定逻辑，0 模型调用、0 发信、0 落盘。 */
  evaluate(input: {
    text: string;
    policy: ConversationPolicy;
    quietHours?: QuietHoursConfig;
    mentionsSelf?: boolean;
    inQuietHours?: boolean;
    nowMs?: number;
  }): PolicyEvaluateResult {
    const { text, policy, quietHours } = input;
    const mentionsSelf = input.mentionsSelf ?? false;
    const steps: PolicyEvaluateStep[] = [];
    const risk = this.resolveRisk(text, policy.riskProfile);

    // ① 安全铁律
    if (risk.kind === 'stop') {
      steps.push({ stage: 'iron_rule', title: '① 安全铁律', outcome: 'hit', detail: '命中对方叫停/退订表达，将永久锁定会话（peer-stopped）' });
      steps.push({ stage: 'quiet_hours', title: '② 勿扰时段', outcome: 'skip', detail: '已被前序安全铁律拦截' });
      steps.push({ stage: 'keywords', title: '③ 触发与忽略词', outcome: 'skip', detail: '已被前序安全铁律拦截' });
      steps.push({ stage: 'risk_rules', title: '④ 内置与自定义风控', outcome: 'skip', detail: '已被前序安全铁律拦截' });
      steps.push({ stage: 'verdict', title: '⑤ 最终判定', outcome: 'hit', detail: finalActionLabels.lock_peer });
      return { steps, finalAction: 'lock_peer', matchedRule: 'peer-stopped' };
    }
    if (risk.kind === 'manual' && risk.matchedRule === 'crisis') {
      steps.push({ stage: 'iron_rule', title: '① 安全铁律', outcome: 'hit', detail: `${reviewDescription(risk.review)}（不可放行）→ ${finalActionLabels[risk.action]}` });
      steps.push({ stage: 'quiet_hours', title: '② 勿扰时段', outcome: 'skip', detail: '已被前序安全铁律拦截' });
      steps.push({ stage: 'keywords', title: '③ 触发与忽略词', outcome: 'skip', detail: '已被前序安全铁律拦截' });
      steps.push({ stage: 'risk_rules', title: '④ 内置与自定义风控', outcome: 'skip', detail: '已被前序安全铁律拦截' });
      steps.push({ stage: 'verdict', title: '⑤ 最终判定', outcome: 'hit', detail: finalActionLabels[risk.action] });
      return { steps, finalAction: risk.action, matchedRule: 'crisis' };
    }
    steps.push({ stage: 'iron_rule', title: '① 安全铁律', outcome: 'pass', detail: '未命中退订锁或人身安全铁律（send-unknown / backfill 由运行期强制守护）' });

    // ② 勿扰时段
    const activeQuiet = input.inQuietHours ?? isInQuietHours(quietHours, input.nowMs ?? Date.now());
    let quietDraftOnly = false;
    if (policy.ignoreQuietHours) {
      steps.push({ stage: 'quiet_hours', title: '② 勿扰时段', outcome: 'pass', detail: '当前会话已开启「忽略全局勿扰时段」豁免' });
    } else if (activeQuiet) {
      const qAction = quietHours?.action ?? 'skip_turn';
      if (qAction === 'skip_turn') {
        steps.push({ stage: 'quiet_hours', title: '② 勿扰时段', outcome: 'hit', detail: '命中勿扰时段（跳过本轮，不调用模型）' });
        steps.push({ stage: 'keywords', title: '③ 触发与忽略词', outcome: 'skip', detail: '已被勿扰时段跳过' });
        steps.push({ stage: 'risk_rules', title: '④ 内置与自定义风控', outcome: 'skip', detail: '已被勿扰时段跳过' });
        steps.push({ stage: 'verdict', title: '⑤ 最终判定', outcome: 'hit', detail: finalActionLabels.skip_turn });
        return { steps, finalAction: 'skip_turn', matchedRule: 'quiet-hours' };
      }
      quietDraftOnly = true;
      steps.push({ stage: 'quiet_hours', title: '② 勿扰时段', outcome: 'hit', detail: '命中勿扰时段（降级为仅拟稿），继续校验关键词与风控规则' });
    } else {
      steps.push({ stage: 'quiet_hours', title: '② 勿扰时段', outcome: 'pass', detail: '当前不在勿扰时段' });
    }

    // ③ 触发与忽略词
    const gate = evaluateKeywordGate(text, policy, policy.type, mentionsSelf);
    if (gate) {
      const detail = gate === 'ignored'
        ? '命中忽略黑名单词，直接跳过本轮（不调用模型）'
        : gate === 'trigger-missed'
          ? '未命中会话触发白名单词，跳过本轮'
          : policy.triggerKeywords.length > 0
            ? '群聊仅被 @ 或命中触发词时触发，当前未命中，跳过本轮'
            : '群聊仅被 @ 时触发，当前未提及本人，跳过本轮';
      const matchedRule = gate === 'ignored' ? 'ignore-keyword' : gate;
      steps.push({ stage: 'keywords', title: '③ 触发与忽略词', outcome: 'hit', detail });
      steps.push({ stage: 'risk_rules', title: '④ 内置与自定义风控', outcome: 'skip', detail: '已被关键词门禁跳过' });
      steps.push({ stage: 'verdict', title: '⑤ 最终判定', outcome: 'hit', detail: finalActionLabels.skip_turn });
      return { steps, finalAction: 'skip_turn', matchedRule };
    }
    const kwPassDetail = policy.type === 'group' && policy.groupTrigger === 'mention_only'
      ? (mentionsSelf ? '群聊命中 @ 提及，通过触发门禁' : '群聊命中触发白名单词，通过触发门禁')
      : policy.triggerKeywords.length > 0
        ? '命中会话触发白名单词，且未命中忽略词'
        : '通过关键词门禁（未命中忽略词）';
    steps.push({ stage: 'keywords', title: '③ 触发与忽略词', outcome: 'pass', detail: kwPassDetail });

    // ④ 内置与自定义风控
    if (risk.kind === 'identity') {
      steps.push({ stage: 'risk_rules', title: '④ 内置与自定义风控', outcome: 'hit', detail: '命中身份询问（不可关闭），将返回固定自动回复说明' });
      steps.push({ stage: 'verdict', title: '⑤ 最终判定', outcome: 'hit', detail: finalActionLabels.identity });
      return { steps, finalAction: 'identity', matchedRule: 'identity' };
    }
    if (risk.kind === 'manual') {
      const finalAction: EffectiveRuleAction = ACTION_SEVERITY[risk.action] >= ACTION_SEVERITY[quietDraftOnly ? 'draft_only' : 'allow']
        ? risk.action : 'draft_only';
      steps.push({ stage: 'risk_rules', title: '④ 内置与自定义风控', outcome: 'hit', detail: `${reviewDescription(risk.review)} → ${finalActionLabels[risk.action]}` });
      steps.push({ stage: 'verdict', title: '⑤ 最终判定', outcome: 'hit', detail: finalActionLabels[finalAction] });
      return { steps, finalAction, matchedRule: risk.matchedRule };
    }
    if (!text.trim()) {
      steps.push({ stage: 'risk_rules', title: '④ 内置与自定义风控', outcome: 'hit', detail: '来信正文为空，跳过本轮' });
      steps.push({ stage: 'verdict', title: '⑤ 最终判定', outcome: 'hit', detail: finalActionLabels.skip_turn });
      return { steps, finalAction: 'skip_turn', matchedRule: 'empty-text' };
    }
    steps.push({ stage: 'risk_rules', title: '④ 内置与自定义风控', outcome: 'pass', detail: '未命中任何生效的内置风控类目或自定义必拦词' });

    // ⑤ 最终判定
    const finalAction: PolicyEvaluateResult['finalAction'] = quietDraftOnly ? 'draft_only' : 'allow';
    steps.push({ stage: 'verdict', title: '⑤ 最终判定', outcome: quietDraftOnly ? 'hit' : 'pass', detail: finalActionLabels[finalAction] });
    return { steps, finalAction, ...(quietDraftOnly && { matchedRule: 'quiet-hours' }) };
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
