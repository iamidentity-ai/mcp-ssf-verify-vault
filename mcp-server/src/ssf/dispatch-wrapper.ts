// SSF orchestration layer that wraps the existing tool dispatcher.
//
// Behavior:
//   1. Call inner(toolName, args, bearer) — the actual MCP tool dispatch.
//   2. On success: clearDeny(verifyUserId) (any prior denies were transient
//      / accidental — fresh slate) and return the result unchanged.
//   3. On MFA error (mfa_denied / mfa_timeout / mfa_no_factor): recordDeny.
//      - Below threshold: re-throw the original error so the caller still sees
//        the specific MFA outcome code.
//      - At threshold: emit a CAEP session-revoke event to Antenna, clear the
//        counter, throw a friendly threshold-reached error so the HTTP handler
//        can map it to 401 + the "your session has been revoked" message.
//   4. Non-MFA errors: re-throw untouched (don't increment, don't emit).
//
// We import * as antennaEmitter so vitest's spyOn() works against the
// emitSessionRevoked member at test time — calling a destructured binding
// would bypass the spy.

import * as antennaEmitter from './antenna-emitter.js';
import { clearDeny, recordDeny } from './deny-counter.js';

const MFA_DENIAL_CODES = new Set([
  'mfa_denied',
  'mfa_timeout',
  'mfa_no_factor',
]);

export interface DispatchInput {
  toolName: string;
  args: Record<string, unknown>;
  bearer: string;
  verifyUserId: string;
  email?: string;
  /** The inner dispatcher (typically the existing dispatchTool). */
  inner: (
    toolName: string,
    args: Record<string, unknown>,
    bearer: string,
  ) => Promise<unknown>;
}

export async function dispatchToolWithDenyTracking(
  input: DispatchInput,
): Promise<unknown> {
  try {
    const result = await input.inner(input.toolName, input.args, input.bearer);
    clearDeny(input.verifyUserId);
    return result;
  } catch (err) {
    const e = err as Error & { code?: string };
    if (!MFA_DENIAL_CODES.has(e.code ?? '')) {
      throw err;
    }

    const { count, thresholdReached, threshold } = recordDeny(input.verifyUserId);
    console.log(
      `[ssf] mfa denial #${count}/${threshold} user=${input.verifyUserId} tool=${input.toolName} code=${e.code}`,
    );

    if (thresholdReached) {
      const reason = `${threshold} consecutive MFA denials on VIP read attempts — session revoked by SSF`;
      const emit = await antennaEmitter.emitSessionRevoked({
        verifyUserId: input.verifyUserId,
        email: input.email,
        reason,
      });
      if (!emit.ok) {
        console.warn(
          `[ssf] CAEP emit FAILED status=${emit.status} body=${emit.body?.slice(0, 200)}`,
        );
      } else {
        console.log(
          `[ssf] CAEP session-revoked emitted for user=${input.verifyUserId}`,
        );
      }

      clearDeny(input.verifyUserId);
      const thresholdErr = new Error(
        `${threshold} denials reached. Your session has been revoked across all apps federated to this IBM Verify tenant. Please sign in again.`,
      );
      (thresholdErr as Error & { code?: string }).code =
        'session_revoked_threshold_reached';
      throw thresholdErr;
    }

    // Below threshold — re-throw the original MFA error verbatim.
    throw err;
  }
}
