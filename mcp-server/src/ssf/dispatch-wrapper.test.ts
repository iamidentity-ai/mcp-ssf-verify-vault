// Tests for dispatchToolWithDenyTracking — the SSF orchestration layer that
// sits in front of dispatchTool. Increments the per-user deny counter on MFA
// errors, clears it on success, and at the threshold emits a CAEP
// session-revoke event before throwing a friendly threshold-reached error.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import * as antennaEmitter from './antenna-emitter.js';
import {
  __resetForTests,
  getDenyCount,
  recordDeny,
} from './deny-counter.js';
import { dispatchToolWithDenyTracking } from './dispatch-wrapper.js';

const VERIFY_USER = 'user123';
const EMAIL = 'c@x.com';

beforeEach(() => {
  __resetForTests();
});

afterEach(() => {
  vi.restoreAllMocks();
});

function makeMfaError(code: 'mfa_denied' | 'mfa_timeout' | 'mfa_no_factor', msg = 'mfa error'): Error {
  const e = new Error(msg) as Error & { code?: string };
  e.code = code;
  return e;
}

describe('dispatchToolWithDenyTracking', () => {
  it('passes through a successful dispatch and clears the deny counter', async () => {
    // Pre-seed two prior denies — they must be cleared on success.
    recordDeny(VERIFY_USER);
    recordDeny(VERIFY_USER);
    expect(getDenyCount(VERIFY_USER)).toBe(2);

    const emitSpy = vi
      .spyOn(antennaEmitter, 'emitSessionRevoked')
      .mockResolvedValue({ ok: true, status: 202 });

    const inner = vi.fn(async () => ({ ok: true, data: 'patient row' }));

    const result = await dispatchToolWithDenyTracking({
      toolName: 'read_patient_record',
      args: { id: 1 },
      bearer: 'bearer-xyz',
      verifyUserId: VERIFY_USER,
      email: EMAIL,
      inner,
    });

    expect(result).toEqual({ ok: true, data: 'patient row' });
    expect(getDenyCount(VERIFY_USER)).toBe(0);
    expect(emitSpy).not.toHaveBeenCalled();
  });

  it('on mfa_denied below threshold: increments counter, re-throws, does not emit', async () => {
    const emitSpy = vi
      .spyOn(antennaEmitter, 'emitSessionRevoked')
      .mockResolvedValue({ ok: true, status: 202 });

    const inner = vi.fn(async () => {
      throw makeMfaError('mfa_denied', 'user denied push');
    });

    await expect(
      dispatchToolWithDenyTracking({
        toolName: 'read_patient_record',
        args: {},
        bearer: 'bearer-xyz',
        verifyUserId: VERIFY_USER,
        email: EMAIL,
        inner,
      }),
    ).rejects.toMatchObject({ code: 'mfa_denied', message: 'user denied push' });

    expect(getDenyCount(VERIFY_USER)).toBe(1);
    expect(emitSpy).not.toHaveBeenCalled();
  });

  it('on mfa_denied AT threshold (3rd consecutive): emits session-revoke, clears counter, throws threshold error', async () => {
    recordDeny(VERIFY_USER);
    recordDeny(VERIFY_USER);

    const emitSpy = vi
      .spyOn(antennaEmitter, 'emitSessionRevoked')
      .mockResolvedValue({ ok: true, status: 202 });

    const inner = vi.fn(async () => {
      throw makeMfaError('mfa_denied');
    });

    await expect(
      dispatchToolWithDenyTracking({
        toolName: 'read_patient_record',
        args: {},
        bearer: 'bearer-xyz',
        verifyUserId: VERIFY_USER,
        email: EMAIL,
        inner,
      }),
    ).rejects.toMatchObject({ code: 'session_revoked_threshold_reached' });

    expect(emitSpy).toHaveBeenCalledOnce();
    const emitArg = emitSpy.mock.calls[0]![0];
    expect(emitArg).toMatchObject({ verifyUserId: VERIFY_USER, email: EMAIL });
    expect(emitArg.reason).toMatch(/3|threshold|denial/i);

    // Counter cleared so the next sign-in starts fresh.
    expect(getDenyCount(VERIFY_USER)).toBe(0);
  });

  it('mfa_timeout counts the same as mfa_denied — triggers at the threshold', async () => {
    recordDeny(VERIFY_USER);
    recordDeny(VERIFY_USER);

    const emitSpy = vi
      .spyOn(antennaEmitter, 'emitSessionRevoked')
      .mockResolvedValue({ ok: true, status: 202 });

    const inner = vi.fn(async () => {
      throw makeMfaError('mfa_timeout');
    });

    await expect(
      dispatchToolWithDenyTracking({
        toolName: 'read_patient_record',
        args: {},
        bearer: 'bearer-xyz',
        verifyUserId: VERIFY_USER,
        email: EMAIL,
        inner,
      }),
    ).rejects.toMatchObject({ code: 'session_revoked_threshold_reached' });

    expect(emitSpy).toHaveBeenCalledOnce();
  });

  it('mfa_no_factor also counts — triggers at the threshold', async () => {
    recordDeny(VERIFY_USER);
    recordDeny(VERIFY_USER);

    const emitSpy = vi
      .spyOn(antennaEmitter, 'emitSessionRevoked')
      .mockResolvedValue({ ok: true, status: 202 });

    const inner = vi.fn(async () => {
      throw makeMfaError('mfa_no_factor');
    });

    await expect(
      dispatchToolWithDenyTracking({
        toolName: 'read_patient_record',
        args: {},
        bearer: 'bearer-xyz',
        verifyUserId: VERIFY_USER,
        email: EMAIL,
        inner,
      }),
    ).rejects.toMatchObject({ code: 'session_revoked_threshold_reached' });

    expect(emitSpy).toHaveBeenCalledOnce();
  });

  it('non-MFA errors pass through without incrementing the counter or emitting', async () => {
    const emitSpy = vi
      .spyOn(antennaEmitter, 'emitSessionRevoked')
      .mockResolvedValue({ ok: true, status: 202 });

    const inner = vi.fn(async () => {
      const e = new Error('postgres down') as Error & { code?: string };
      e.code = 'ECONNREFUSED';
      throw e;
    });

    await expect(
      dispatchToolWithDenyTracking({
        toolName: 'read_patient_record',
        args: {},
        bearer: 'bearer-xyz',
        verifyUserId: VERIFY_USER,
        email: EMAIL,
        inner,
      }),
    ).rejects.toMatchObject({ code: 'ECONNREFUSED' });

    expect(getDenyCount(VERIFY_USER)).toBe(0);
    expect(emitSpy).not.toHaveBeenCalled();
  });

  it('threshold-reached error message is human-readable', async () => {
    recordDeny(VERIFY_USER);
    recordDeny(VERIFY_USER);

    vi.spyOn(antennaEmitter, 'emitSessionRevoked').mockResolvedValue({
      ok: true,
      status: 202,
    });

    const inner = vi.fn(async () => {
      throw makeMfaError('mfa_denied');
    });

    let caught: Error | undefined;
    try {
      await dispatchToolWithDenyTracking({
        toolName: 'read_patient_record',
        args: {},
        bearer: 'bearer-xyz',
        verifyUserId: VERIFY_USER,
        email: EMAIL,
        inner,
      });
    } catch (e) {
      caught = e as Error;
    }

    expect(caught).toBeDefined();
    expect(caught!.message).toMatch(/3 denials|threshold|revoked/i);
  });
});
