// In-memory per-user MFA denial counter for the "3 denials = session revoke"
// SSF demo flow.
//
// Cookbook design choice (brainstorm decision 3): NO time window. The counter
// resets only on:
//   - explicit clearDeny() — fires on any successful tool dispatch
//   - an emitted session-revoke at the threshold (counter cleared inside the
//     wrapper before throwing)
//
// The healthcare reference (claude-managed-agents/healthcare/mcp-server/src/
// deny-counter.ts) uses a 5-minute rolling window. The cookbook deliberately
// drops that: simpler semantics for a teaching/reference scenario, and one
// fewer "but what if the window expires mid-flow?" edge case to explain.
//
// Single-process, non-persistent — fine for the cookbook scenario where the
// MCP server runs as one process. If you ever scale horizontally, swap this
// for a shared store (Redis, Postgres advisory locks, etc.) — but understand
// you're now coordinating SSF state across processes.

const THRESHOLD = 3;

// Module-level singleton — one map per process.
const counts = new Map<string, number>();

export interface DenyResult {
  count: number;
  thresholdReached: boolean;
  threshold: number;
}

/**
 * Record a denial for the given user. Returns the new count and whether the
 * threshold has been reached. The threshold is INCLUSIVE: count === 3 triggers.
 */
export function recordDeny(verifyUserId: string): DenyResult {
  const next = (counts.get(verifyUserId) ?? 0) + 1;
  counts.set(verifyUserId, next);
  return { count: next, thresholdReached: next >= THRESHOLD, threshold: THRESHOLD };
}

/**
 * Clear the counter for a user. Called after:
 *   - A successful tool dispatch (legitimate user — fresh slate).
 *   - A threshold-triggered session revoke (next sign-in starts fresh).
 */
export function clearDeny(verifyUserId: string): void {
  counts.delete(verifyUserId);
}

/** Read-only count inspector for diagnostics. */
export function getDenyCount(verifyUserId: string): number {
  return counts.get(verifyUserId) ?? 0;
}

/** Test-only helper — wipes all state. */
export function __resetForTests(): void {
  counts.clear();
}
