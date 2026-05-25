// Emits CAEP session-revoked events to the SSF Antenna container.
//
// The Antenna container's session_revoked.js action handler then calls
// IBM Verify's DELETE /v1.0/auth/sessions/{verifyUserId} — terminating the
// user's sessions across every app federated to the tenant (the SSF demo's
// headline behavior).
//
// Antenna's expected payload shape — this MUST match exactly. Wrong shape
// returns 201 from the ingester (silent success!) but the transmitter then
// errors "failed to parse event timestamp" or similar and the action handler
// never fires. The fields that bit production hardest:
//   - event_timestamp is SECONDS, not milliseconds
//   - reasonAdmin / reasonUser are { en: "..." } maps, not bare strings
//   - sub_id.verifyUserId at the TOP LEVEL (not nested under "subject")
//
// References:
//   - CLAUDE.md § "SSF pipeline correction" — canonical payload shape
//   - CLAUDE.md § "SSF/CAEP pipeline invariants" — ANTENNA_SOURCE_ID is the
//     ingester's only configured source_id; any other value 404s
//
// TLS NOTE: Antenna serves self-signed HTTPS on localhost:9044. The MCP
// process must run with NODE_TLS_REJECT_UNAUTHORIZED=0 in its env, OR the
// caller has to supply a fetch with a permissive https.Agent. The cookbook's
// docker-compose / systemd unit sets the env var.
//
// TEST HOOK: globalThis.fetch is not mocked because vitest parallel runs make
// global stubs flaky. Instead __setFetchForTests() injects a fake fetch — the
// default uses the runtime's fetch.

export const SESSION_REVOKED_URI =
  'https://schemas.openid.net/secevent/caep/event-type/session-revoked';

// Default: the cookbook's docker-compose runs Antenna at localhost:9044 with
// source_id=mcp configured in transmitter.yml + .env (ANTENNA_SOURCE_ID=mcp).
// Override via ANTENNA_SOURCE_URL for a different host/port/source.
const DEFAULT_SOURCE_URL =
  process.env.ANTENNA_SOURCE_URL ?? 'https://localhost:9044/sources/mcp/events';

type FetchFn = typeof fetch;
let _fetch: FetchFn | undefined;

/**
 * Inject a fake fetch for tests. Pass `undefined` to reset to the runtime
 * default (fetch global).
 */
export function __setFetchForTests(f: FetchFn | undefined): void {
  _fetch = f;
}

function getFetch(): FetchFn {
  return _fetch ?? fetch;
}

export interface EmitInput {
  /** Verify-internal user id, e.g. "643002NOIP". REQUIRED. */
  verifyUserId: string;
  /** Optional user email. Drives sub_id.format=email when present. */
  email?: string;
  /** Human-readable reason. Surfaces in reasonAdmin/reasonUser. */
  reason: string;
}

export interface EmitResult {
  ok: boolean;
  status: number;
  body?: string;
}

export async function emitSessionRevoked(input: EmitInput): Promise<EmitResult> {
  const payload = {
    sub_id: {
      format: input.email ? ('email' as const) : ('opaque' as const),
      verifyUserId: input.verifyUserId,
      ...(input.email ? { email: input.email } : {}),
    },
    events: {
      [SESSION_REVOKED_URI]: {
        // Seconds-since-epoch. Antenna parses this as a Unix timestamp and
        // rejects anything that looks like milliseconds (> ~2e9).
        event_timestamp: Math.floor(Date.now() / 1000),
        initiatingEntity: 'policy' as const,
        reasonAdmin: { en: input.reason },
        reasonUser: { en: input.reason },
      },
    },
  };

  try {
    const res = await getFetch()(DEFAULT_SOURCE_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      console.warn(
        `[antenna-emitter] non-2xx from Antenna: ${res.status} ${text.slice(0, 200)}`,
      );
      return { ok: false, status: res.status, body: text };
    }
    console.log(
      `[antenna-emitter] session-revoked emitted for user=${input.verifyUserId} status=${res.status}`,
    );
    return { ok: true, status: res.status };
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    console.warn(`[antenna-emitter] fetch failed: ${msg}`);
    return { ok: false, status: 0, body: msg };
  }
}
