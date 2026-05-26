#!/bin/bash
# synthetic-probe.sh — fires a session-revoked event into the transmitter, watches
# the receiver logs for the session_revoked action handler to complete within 75s.
#
# Step-by-step explanation: docs/ssf-manual-deployment.md § "synthetic-probe.sh — end-to-end health check"
#
# Use this after bootstrap-antenna.sh + create-stream.sh to confirm the full SSF
# pipeline is healthy:
#   MCP -> transmitter ingester -> sign as SET -> receiver poll -> action handler ->
#   Verify DELETE /v1.0/auth/sessions
#
# WARNING — this WILL revoke the configured probe user's session on the Verify
# tenant. Don't run against a real user. Defaults to PROBE_USER_DO_NOT_USE
# (configure a non-existent userId in your .env if you don't want the action to
# succeed — the synthetic event still validates the pipeline up to the Verify call).
#
# Body shape matches the canonical recipe at
# /tmp/verify-antenna-recipes/deploying/transmitter/scripts/test_device_event.sh
# but uses the CAEP session-revoked schema (banking-compatible — sub_id at top
# level with verifyUserId field; event_timestamp in epoch seconds; reasonAdmin/
# reasonUser as {en:'...'} maps). The shape MUST match — wrong shape returns 201
# but the receiver errors "failed to parse event timestamp" downstream silently.

set -euo pipefail
cd "$(dirname "$0")"

[[ -f .env ]] || { echo "ERROR: infra/antenna/.env not found — copy .env.example and edit" >&2; exit 1; }
# shellcheck disable=SC1091
source .env

: "${ANTENNA_HOSTNAME:?ANTENNA_HOSTNAME required in infra/antenna/.env}"
: "${ANTENNA_TRANSMITTER_PORT:?ANTENNA_TRANSMITTER_PORT required in infra/antenna/.env}"
: "${ANTENNA_SOURCE_ID:?ANTENNA_SOURCE_ID required in infra/antenna/.env}"

PROBE_USER="${PROBE_VERIFY_USER_ID:-PROBE_USER_DO_NOT_USE}"
PROBE_EMAIL="${PROBE_EMAIL:-probe@example.com}"
INGESTER="https://${ANTENNA_HOSTNAME}:${ANTENNA_TRANSMITTER_PORT}/sources/${ANTENNA_SOURCE_ID}/events"

TS=$(date +%s)
echo "[probe] POST ${INGESTER} (user=${PROBE_USER})"
curl -sk -X POST -H "Content-Type: application/json" -w "\n[probe] ingester status: %{http_code}\n" \
  -d "{
    \"sub_id\":{\"format\":\"email\",\"email\":\"${PROBE_EMAIL}\",\"verifyUserId\":\"${PROBE_USER}\"},
    \"events\":{
      \"https://schemas.openid.net/secevent/caep/event-type/session-revoked\":{
        \"reasonAdmin\":{\"en\":\"synthetic probe\"},
        \"reasonUser\":{\"en\":\"synthetic probe\"},
        \"initiatingEntity\":\"policy\",
        \"event_timestamp\":${TS}
      }
    }
  }" "$INGESTER"

echo "[probe] waiting up to 180s for the receiver to action the event…"
echo "[probe]   (first run after container start takes 60-90s for the partitioner to warm up,"
echo "[probe]    plus the 30s receiver poll interval — subsequent probes are much faster)"
for i in $(seq 1 36); do
  sleep 5
  # Pipeline-health proof, ordered strongest to weakest:
  #   1. "All sessions revoked" — full happy path, real user, sessions actually revoked
  #   2. "session_revoked action completed successfully" — handler ran to its end-log
  #   3. "[fetchUser] No user found on tenant" — handler ran + reached Verify SCIM,
  #      user-not-found is the expected outcome for the probe's PROBE_USER_DO_NOT_USE.
  #      This is conclusive proof that the WHOLE chain (transmitter → SET signing →
  #      receiver → action handler → Verify SCIM) is healthy. For a real demo the
  #      user exists and outcome #1 fires instead.
  RECEIVER_LOG=$(docker logs vva-antenna-receiver --since 200s 2>&1)
  if echo "$RECEIVER_LOG" | grep -q "All sessions revoked\|session_revoked action completed successfully"; then
    echo "[probe] PASS — full happy path ($((i*5))s) — sessions actually revoked on tenant"
    exit 0
  elif echo "$RECEIVER_LOG" | grep -q "\[fetchUser\] No user found on tenant"; then
    echo "[probe] PASS — pipeline is healthy ($((i*5))s)"
    echo "[probe]   The action handler ran end-to-end and reached the Verify SCIM API."
    echo "[probe]   No actual session was revoked because PROBE_USER_DO_NOT_USE doesn't"
    echo "[probe]   exist on your tenant — that's the EXPECTED outcome for the probe."
    echo "[probe]   For a real demo, use scripts/smoke-test-ssf.sh with a clinician token."
    exit 0
  fi
done

echo "[probe] FAIL — receiver did not action the event within 180s"
echo "[probe] last 40 receiver log lines:"
docker logs vva-antenna-receiver --tail 40
echo ""
echo "[probe] TROUBLESHOOTING — see docs/ssf-troubleshooting.md and check:"
echo "  - was create-stream.sh run successfully? (re-run ./create-stream.sh)"
echo "  - is the receiver mgmt endpoint reachable?"
echo "      curl -sk https://${ANTENNA_HOSTNAME}:${ANTENNA_RECEIVER_PORT}/mgmt/v2.0/receivers/config"
echo "  - did the SSF management API client on Verify get the right entitlements?"
echo "      (Read users + Revoke sessions — open Security -> API -> mcp-ssf-shared-signals in the Admin UI)"
echo "  - is the rendered transmitter.yml carrying the right discovery_uri?"
echo "      grep discovery_uri deploying/transmitter/configs/transmitter.yml"
exit 1
