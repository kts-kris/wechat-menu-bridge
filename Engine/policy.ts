import { BridgeError, id, object, sha } from './contracts.ts';
import type { Scope } from './mcp.ts';
import type { Decision } from './model.ts';

export const MAX_AGE = 45_000;
export const IDENTITY = '这是他设置的自动回复，不是本人在打字。';
export type Incoming = { key: string; refKey: string; ref: string; text?: string; seen: number; created: number; observed: number };
export type Message = Incoming & { self: boolean; request?: string };

export function message(raw: unknown, scope: Scope, since: number, now: number): Message | undefined {
  const e = object(raw);
  if (!e || e.event_type !== 'message.saved' || e.conversation_id !== scope.conversation_id) return;
  if (e.account_id !== scope.account_id || e.instance_id !== scope.instance_id || e.login_generation !== scope.login_generation) {
    throw new BridgeError('wechat-changed');
  }
  if (typeof e.is_self !== 'boolean') throw new BridgeError('mcp-contract');
  if (!e.is_self && (e.sender_id !== scope.conversation_id || e.type !== 'text')) return;
  const created = typeof e.created_at === 'string' ? Date.parse(e.created_at) : NaN;
  const observed = typeof e.observed_at === 'string' ? Date.parse(e.observed_at) : NaN;
  if (!Number.isFinite(created) || !Number.isFinite(observed)) throw new BridgeError('mcp-contract');
  // A newly observed older message can still contain a stop; replies use a stricter cutoff below.
  if (created < Math.floor(since / 1000) * 1000 && observed < Math.floor(since / 1000) * 1000) return;
  if (created > now + 5000 || observed > now + 5000) throw new BridgeError('clock-changed');
  if (!id(e.event_id) || !id(e.message_ref)) throw new BridgeError('mcp-contract');
  if (!e.is_self && (e.recalled === true || e.is_recalled === true)) return;
  return { key: sha(`event:${e.event_id}`), refKey: sha(`ref:${e.message_ref}`), ref: e.message_ref, seen: now, created, observed,
    self: e.is_self, request: id(e.client_request_id) ? e.client_request_id : undefined,
    text: !e.is_self && typeof e.text === 'string' && e.text.trim() ? e.text.trim() : undefined };
}

const normalized = (s: string) => s.normalize('NFKC').replace(/\p{Cf}+/gu, '').toLowerCase();
const scopedNoReply = /(?:上次的|之前的|这个|这件|那个|刚才的).{0,8}(?:问题|话题|事情|消息).{0,6}(?:不用|不需要|别|不要).{0,6}(?:回复|回)/gu;
const stop = /(?:别|不要|不想.{0,8}(?:再|收)|不用|不需要|不接受|不允许|关掉|关闭|停止|暂停|取消).{0,6}(?:回复|回我|回了|回消息|发了|发我|发消息|发给我|联系|自动|机器人|代回|找我)|(?:别|不要).{0,8}(?:发|发给我).{0,6}(?:消息|信息)|(?:禁止|拒绝|不愿意|不愿|不想|不同意).{0,6}(?:机器|机器人|ai|自动).{0,6}(?:代聊|代回|回|聊|发|说话)|(?:^|[。！？!?\n])\s*(?:停一下|别回|别再回|别理我|停止|退订|停)\s*(?:$|[。！？!?\n])|\b(?:stop|unsubscribe|opt\s*out|(?:don['’]?t|do not|no more)\s+(?:text|reply|message|contact|auto))\b/iu;
const identity = /(?:你|这是|这谁|谁|本人|是).{0,12}(?:真人|本人|机器人|自动回复|自动回|代回|ai\b|人工智能)|(?:好像|是不是|是个).{0,6}(?:机器人|ai\b)|(?:是你|谁).{0,5}(?:在回|在打字|发的消息)|\b(?:are you (?:an? )?(?:ai|bot|real)|is this (?:an? )?(?:ai|bot|you|automated)|who (?:is this|are you))\b/iu;
// Deliberately conservative. These checks complement, not replace, model triage or human judgment.
const financial = /钱|(?:笔|还|付|收|借|欠|转|汇|退|贷|赔|账|尾|打|结)款|款项|房租|租金|欠.{0,4}(?:我|你|他|她)/u;
const borrowedReturn = /(?:借|[0-9零〇一二三四五六七八九十百千万两]+).{0,20}还(?=给|我|你|他|她|吗|么|嘛|了|不|[？?。！!\s]|$)/u;
const qianAsName = /(?:小|老|阿)钱(?=说|讲|觉得|认为)/gu;
const workYear = /(?<!\d)(?:19|20)\d{2}年(?=的(?:电影|影片|动画|电视剧|歌曲|小说|作品))/gu;
const delegatedTask = /(?:替我|帮我|帮忙|麻烦(?:你|您)?|劳烦(?:你|您)?|辛苦(?:你|您)?|请(?:你|您)).{0,16}(?:做|办|处理|完成|交|写|准备|发|转发|提交|安排|拿|买|给|联系|回复)/u;
const reminderRequest = /(?:记得|别忘(?:记|了)?|不要忘(?:记|了)?).{0,16}(?:接|送|办|做|带|买|付|拿|给|发|去|来|交|还|处理|完成)|(?:接|送|办|做|带|买|付|拿|给|发|去|来|交|还|处理|完成).{0,12}(?:别忘(?:记|了)?|不要忘(?:记|了)?)/u;
const timedRequest = /(?:明早|明晚|后天|下(?:周|星期|礼拜)).{0,16}(?:接我|送我|等我|帮我|替我|给我|来我|去|见|吃|开会)/u;
const credentials = /密码|验证码|口令|密钥|\b(?:password|passcode|secret|api\s*key|pin code)\b/iu;
const transaction = /银行卡|开户|转账|借钱|红包|发票|报销|\b(?:iban|transfer money)\b/iu;
const agreement = /合同|签字/iu;
const medicalRecord = /病历/iu;
const crisis = /威胁|自杀|好想死|不想活/iu;
const strictRules = [
  ['credentials', credentials],
  ['finance', transaction],
  ['legal', agreement],
  ['health', /病历|医生|医院|药物|怀孕/iu],
  ['crisis', crisis],
  ['privacy', /身份证|你在哪|在哪儿|发个定位|地址|住哪|住址|门牌|隐私|保密|发我电话|手机号|私人|\b(?:address|location)\b/iu],
  ['instructions', /提示词|系统指令|忽略.{0,12}(?:指令|规则)|扮演|越权|\bprompt\b/iu],
  ['link', /https?:|www\.|[\w.+-]+@[a-z0-9.-]+\.[a-z]{2,}/iu],
  ['commitment', /承诺|答应|保证|\bpromise\b/iu],
  ['schedule', /\d\s*[:：]\s*\d|\d\s*点|[一二三四五六七八九十两]点(?:半|钟|见|等|到|过|左右)|约(?:好|定|个|会|时间|一下)|碰(?:面|个头)|(?:明天|今晚|周[一二三四五六日天]|下午|中午|一会儿).{0,12}(?:见|去|来|吃|接|等|开会)|(?:一起|陪我|能不能|可以).{0,12}(?:去|来|吃|接|见|帮|借|买|等)|等你|见面|到我这|\bmeet me\b/iu],
  ['sensitive-topic', /分手|离婚|投诉|报警|开会|汇报|客户/iu],
  ['numbers', /\d{4,}|\d\s*(?:号|元|块|万)/u],
] as const;
const sensitiveNumber = /(?<!\d)(?:(?:(?:00)?86)?1[3-9]\d{9}|\d{17}x|\d{16,19})(?!\d)/u;
const verificationCode = /动态码|校验码|安全码|授权码|\b(?:otp|verification code|security code)\b/iu;
const directPrivacy = /身份证|住址|门牌号|发(?:给)?我.{0,8}(?:手机号|电话号码|定位)|(?:手机|电话|账号|帐户|账户|卡号|证件).{0,12}\d{4,}/u;
const directPayment = /转[给你我].{0,6}(?:钱|元|块)|转你\d|汇款|打款|收款|付款|还款|借款|贷款|汇钱|打钱|还钱|欠钱|(?:借|欠|还).{0,8}\d|\d\s*(?:元|块钱)/u;
const directMedical = /确诊|诊断|处方|开药|剂量|用药|药.{0,5}怎么(?:用|吃|服)/u;
const commitment = /(?:我(?:来|去|会|等|能|马上|一定|同意|愿意|已经|正在|就在|帮你|给你)|(?:就这么定|我答应|没问题.*(?:去|给|发|见|办)|我也(?:爱你|想你)|我刚(?:到|来|从)|不告诉别人|我就是本人|不是机器人|是我在回)|^(?:可以|行|成|收到|好的|好哒|好呀|没问题|一定|ok(?:ay)?)[。！!\s]*$)|\b(?:i(?:'ll| will| promise| agree| am at)|deal|i can do it|not a bot)\b/iu;
const datedCommitment = /(?:明天|今晚|下(?:个)?(?:礼拜|星期)|下周|过几天|等会儿).{0,8}(?:给你|还你|转你|付你|搞定|办好|完成)/u;
const unverifiedPersonal = /我.{0,8}(?:一定|会|保证).{0,8}(?:到|去|办|做|给|还|发|处理|完成|搞定)|还(?:给)?(?:你|他|她)|记(?:得了|住了|下了|着了|好了|着呢|住这事了)|说定了|刚下班|(?:正在|在).{0,6}回家/u;
const identityClaim = /(?:我|这)(?:就|真|确实|当然)?是(?:本人|真人)|(?:就是|是)我(?:本人)?在(?:回|打字)|(?:^|[。！？!?])\s*(?:是的?[,，\s]*)?(?:当然|肯定|确实)?(?:就是|是)?(?:本人|真人)(?:在(?:回|打字)|[啊呀哦哈呢]?(?:$|[。！？!?,，~～]))|不是(?:机器人|自动回复|ai\b)|\b(?:not (?:an? )?(?:bot|ai)|i(?:'m| am) (?:the real person|human|not automated))\b/iu;

export type TextReviewRule = typeof strictRules[number][0] | 'scoped-no-reply' | 'length' | 'delegation' | 'input-format';
export type DraftReviewRule = TextReviewRule | 'draft-format' | 'identity-claim' | 'recipient-intent' | 'personal-assertion';
type TextMatch = { action: 'stop' } | { action: 'identity' } | { action: 'manual'; rule: TextReviewRule };

function strictReview(text: string, s: string): TextReviewRule | undefined {
  if (text.length > 400) return 'length';
  if (financial.test(s.replace(qianAsName, '')) || borrowedReturn.test(s)) return 'finance';
  if (delegatedTask.test(s) || reminderRequest.test(s)) return 'delegation';
  if (timedRequest.test(s)) return 'schedule';
  const visible = s.replace(workYear, '');
  return strictRules.find(([, pattern]) => pattern.test(visible))?.[0] ??
    (/[\p{Cc}\p{Cf}]/u.test(text.replace(/\r?\n/g, '')) ? 'input-format' : undefined);
}

function highRiskReview(s: string): TextReviewRule | undefined {
  if (credentials.test(s) || verificationCode.test(s)) return 'credentials';
  if (transaction.test(s) || directPayment.test(s) || borrowedReturn.test(s)) return 'finance';
  if (directPrivacy.test(s) || sensitiveNumber.test(s)) return 'privacy';
  if (agreement.test(s)) return 'legal';
  if (medicalRecord.test(s) || directMedical.test(s)) return 'health';
  if (crisis.test(s)) return 'crisis';
}

export function inspectText(text: string, level: 'strict' | 'recommended' | 'minimal' = 'strict'): TextMatch | undefined {
  // Long messages still go to manual review, but their tail can contain a
  // stop request that must be persisted before applying the length limit.
  const s = normalized(text);
  const unscoped = s.replace(scopedNoReply, '');
  if (stop.test(unscoped)) return { action: 'stop' };
  // 对方只是不想回复某个话题时，保留会话级授权，但不要回复该话题。
  if (unscoped !== s) return { action: 'manual', rule: 'scoped-no-reply' };
  const asksIdentity = identity.test(s);
  if (level !== 'strict' && asksIdentity) return { action: 'identity' };
  const rule = level === 'strict' ? strictReview(text, s) : level === 'recommended' ? highRiskReview(s) : undefined;
  if (rule) return { action: 'manual', rule };
  if (asksIdentity) return { action: 'identity' };
}

export function classifyText(text: string) { return inspectText(text)?.action; }

function strictDraftReview(text: string): DraftReviewRule | undefined {
  const match = inspectText(text);
  if (match) return match.action === 'manual' ? match.rule : 'recipient-intent';
  const s = normalized(text);
  if (/\d{4,}/u.test(s)) return 'numbers';
  if (commitment.test(s) || datedCommitment.test(s)) return 'commitment';
  if (unverifiedPersonal.test(s)) return 'personal-assertion';
}

export function inspectDraft(text: string, conservative: boolean): DraftReviewRule | undefined {
  if (identityClaim.test(normalized(text))) return 'identity-claim';
  if (conservative) return strictDraftReview(text);
}

export function sendable(d: Decision) {
  if (d.action === 'identity') return IDENTITY;
  if (d.action === 'reply') {
    if (strictDraftReview(d.text)) throw new BridgeError('manual-review');
    return d.text;
  }
}
