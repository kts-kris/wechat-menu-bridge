import { z } from 'zod';
import { BridgeError } from '../../contracts.ts';

export { BridgeError };

export const ERROR_CODES = [
  'active-limit', 'backlog-limit', 'busy', 'busy-chat', 'clock-changed', 'cloud-not-approved',
  'cloud-profile', 'config-unreadable', 'draft-ready', 'duplicate-attempt', 'engine-exited',
  'engine-missing', 'engine-not-ready', 'engine-protocol', 'engine-timeout', 'event-gap',
  'expired', 'internal-error', 'invalid-command', 'invalid-configuration', 'invalid-endpoint',
  'invalid-expiry', 'invalid-frame', 'invalid-key', 'keychain-unavailable', 'manual-review',
  'manual-takeover', 'mcp-contract', 'mcp-offline', 'missing-key', 'model-auth', 'model-format',
  'model-limit', 'model-skip', 'model-timeout', 'model-unavailable', 'no-anchor', 'no-operation',
  'one-shot-complete', 'peer-stopped', 'plugin-circuit-open', 'plugin-limit', 'plugin-permission',
  'plugin-timeout', 'preview-local-only', 'profile-unreadable', 'send-fence', 'send-not-authorized',
  'send-rejected', 'send-unknown', 'settings-changed', 'stopped', 'storage-in-use',
  'storage-unavailable', 'system-sleep', 'turn-obsolete', 'user-paused', 'wechat-changed',
  'wechat-permission', 'wrong-anchor',
] as const;

export const errorCodeSchema = z.enum(ERROR_CODES);
export type ErrorCode = z.infer<typeof errorCodeSchema>;
export const isErrorCode = (value: unknown): value is ErrorCode => errorCodeSchema.safeParse(value).success;
export const errorCode = (error: unknown): ErrorCode =>
  error instanceof BridgeError && isErrorCode(error.code) ? error.code : 'internal-error';
