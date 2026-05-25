// Routing-only JWT decoder for the SSF dispatch wrapper.
//
// extractClaims() decodes the JWT payload segment and returns sub +
// preferred_username for routing purposes only. It does NOT:
//   - verify the signature
//   - check exp / nbf / iat
//   - validate iss / aud
//   - call IBM Verify's introspection endpoint
//
// All of that is the Token Exchange layer's job — by the time the SSF wrapper
// gets to record a denial or emit a session-revoke, the bearer has already
// been validated end-to-end by Verify during Token Exchange. This helper
// exists purely so the SSF layer can attribute events to a user.
//
// Opaque (non-JWT) tokens and malformed JWTs return { undefined, undefined }
// — the dispatch wrapper falls back to whatever verifyUserId / email the
// caller supplied directly.

export interface BearerClaims {
  /** Verify-internal user id (the JWT's `sub` claim). */
  verifyUserId: string | undefined;
  /** User's email / login (the JWT's `preferred_username` claim). */
  email: string | undefined;
}

export function extractClaims(bearer: string): BearerClaims {
  const parts = bearer.split('.');
  if (parts.length !== 3) {
    return { verifyUserId: undefined, email: undefined };
  }
  try {
    const payload = JSON.parse(
      Buffer.from(parts[1]!, 'base64url').toString('utf8'),
    );
    return {
      verifyUserId:
        typeof payload.sub === 'string' ? payload.sub : undefined,
      email:
        typeof payload.preferred_username === 'string'
          ? payload.preferred_username
          : undefined,
    };
  } catch {
    return { verifyUserId: undefined, email: undefined };
  }
}
