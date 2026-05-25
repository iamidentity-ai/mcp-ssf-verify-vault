// Tests for bearer-claims — a routing-only JWT decoder.
//
// extractClaims() does NOT validate signature, exp, iss, aud, etc. The
// surrounding Token Exchange call validates the bearer at IBM Verify. This
// helper only peeks at sub / preferred_username so the SSF wrapper knows
// which user to attribute denials and revocation events to.

import { describe, expect, it } from 'vitest';

import { extractClaims } from './bearer-claims.js';

function b64url(s: string): string {
  return Buffer.from(s).toString('base64url');
}

function makeJwt(payload: Record<string, unknown>): string {
  const header = b64url(JSON.stringify({ alg: 'none', typ: 'JWT' }));
  const body = b64url(JSON.stringify(payload));
  // Signature is the literal string "sig" — we don't validate it.
  return `${header}.${body}.sig`;
}

describe('extractClaims', () => {
  it('decodes verifyUserId from sub and email from preferred_username', () => {
    const jwt = makeJwt({ sub: '643002NOIP', preferred_username: 'c@x.com' });
    expect(extractClaims(jwt)).toEqual({
      verifyUserId: '643002NOIP',
      email: 'c@x.com',
    });
  });

  it('returns undefined for both fields on an opaque token (not 3 segments)', () => {
    expect(extractClaims('opaque-string-no-dots')).toEqual({
      verifyUserId: undefined,
      email: undefined,
    });
  });

  it('returns undefined for both fields on a malformed JWT (5 segments)', () => {
    expect(extractClaims('a.b.c.d.e')).toEqual({
      verifyUserId: undefined,
      email: undefined,
    });
  });
});
