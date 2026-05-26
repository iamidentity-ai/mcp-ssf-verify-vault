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

echo "[probe] waiting up to 75s for the receiver to action the event…"
for i in $(seq 1 15); do
  sleep 5
  # The action handler logs "session_revoked action completed successfully" on
  # the happy path (and "All sessions revoked" on the inner deleteSessions
  # log line). Either is a pass — match both.
  if docker logs vva-antenna-receiver --since 90s 2>&1 | grep -q "session_revoked action completed successfully\|All sessions revoked"; then
    echo "[probe] PASS — pipeline is healthy ($((i*5))s)"
    exit 0
  fi
done

echo "[probe] FAIL — receiver did not complete the action within 75s"
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
