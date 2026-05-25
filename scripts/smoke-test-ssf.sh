#!/usr/bin/env bash
# smoke-test-ssf.sh — end-to-end test of the 3-deny → tenant-wide-revoke path
#
# Step-by-step explanation: docs/ssf-demo-walkthrough.md
#
# What this proves:
#   1. The MCP server's deny-counter tracks per-user denials across tool calls
#   2. On the 3rd consecutive denial the MCP server returns 401
#      session_revoked_threshold_reached AND fires a CAEP event to Antenna
#   3. Antenna's session_revoked.js action handler completes (calls Verify
#      DELETE /v1.0/auth/sessions/{userId})
#   4. The token is dead on Verify's side (/oauth2/userinfo returns 401)
#
# Prerequisites:
#   1. All of Phases 0-6 of the cookbook are deployed:
#        ./scripts/bootstrap-all.sh
#        ./scripts/bootstrap-antenna.sh
#   2. A fresh clinician access token saved to /tmp/clinician.token (override
#      via TOKEN_FILE). Use scripts/get-clinician-token.sh to issue one and
#      save it: `bash scripts/get-clinician-token.sh > /tmp/clinician.token`
#      (or `eval "$(bash scripts/get-clinician-token.sh)"` then
#      `echo "$CLINICIAN_TOKEN" > /tmp/clinician.token`)
#   3. The clinician test user has a push factor enrolled in the IBM Verify
#      mobile app AND will physically DENY three push notifications during
#      this script's run
#
# USER PARTICIPATION REQUIRED: when prompted, deny each push on your phone.
# The script pauses briefly between attempts to give you time to tap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERIFY_OUTPUT="${REPO_ROOT}/infra/verify/verify-output.json"

# ── Inputs (override via env) ────────────────────────────────────────────────
TOKEN_FILE="${TOKEN_FILE:-/tmp/clinician.token}"
MCP_URL="${MCP_URL:-http://localhost:3012/tool}"
VIP_MRN="${VIP_MRN:-MRN-99001}"
INTER_CALL_SLEEP_SEC="${INTER_CALL_SLEEP_SEC:-3}"
REVOKE_TIMEOUT_SEC="${REVOKE_TIMEOUT_SEC:-75}"

# Tenant host — derived from verify-output.json if available
if [ -f "${VERIFY_OUTPUT}" ] && command -v jq >/dev/null 2>&1; then
  VERIFY_TENANT="${VERIFY_TENANT:-$(jq -r '.tenantHost // empty' "${VERIFY_OUTPUT}")}"
fi
VERIFY_TENANT="${VERIFY_TENANT:?VERIFY_TENANT or infra/verify/verify-output.json.tenantHost required}"

# ── Sanity ───────────────────────────────────────────────────────────────────
[[ -f "${TOKEN_FILE}" ]] || {
  echo "ERROR: ${TOKEN_FILE} not found." >&2
  echo "  Run: bash scripts/get-clinician-token.sh   then save the token to ${TOKEN_FILE}" >&2
  exit 1
}
TOKEN="$(tr -d '[:space:]' < "${TOKEN_FILE}")"
[[ -n "${TOKEN}" ]] || { echo "ERROR: ${TOKEN_FILE} is empty" >&2; exit 1; }

# ── Helpers ──────────────────────────────────────────────────────────────────
call_vip() {
  curl -sk -X POST "${MCP_URL}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"toolName\":\"get_patient_record\",\"args\":{\"mrn\":\"${VIP_MRN}\"}}" \
    -w "\nHTTP %{http_code}\n"
}

userinfo_status() {
  curl -sk -o /dev/null -w "%{http_code}" \
    "https://${VERIFY_TENANT}/oauth2/userinfo" \
    -H "Authorization: Bearer ${TOKEN}"
}

# ── Run ──────────────────────────────────────────────────────────────────────
echo "[1/4] confirming /oauth2/userinfo returns 200 with the fresh token"
STATUS="$(userinfo_status)"
if [[ "${STATUS}" != "200" ]]; then
  echo "FAIL: /oauth2/userinfo returned ${STATUS} — token is already dead or invalid" >&2
  exit 1
fi
echo "      OK — token is live"

echo
echo "[2/4] triggering VIP read 3 times — DENY EACH PUSH on your phone"
echo "      (script will sleep ${INTER_CALL_SLEEP_SEC}s between attempts so you can tap)"
for i in 1 2 3; do
  echo
  echo "      --- attempt ${i}/3 ---"
  call_vip
  if [[ ${i} -lt 3 ]]; then sleep "${INTER_CALL_SLEEP_SEC}"; fi
done

echo
echo "[3/4] waiting up to ${REVOKE_TIMEOUT_SEC}s for the Antenna pipeline to revoke"
echo "      (Antenna delivery: poll_interval + JS handler latency = 30-75s)"
START_TS=$(date +%s)
END_TS=$((START_TS + REVOKE_TIMEOUT_SEC))
while [[ $(date +%s) -lt ${END_TS} ]]; do
  sleep 5
  STATUS="$(userinfo_status)"
  ELAPSED=$(( $(date +%s) - START_TS ))
  echo "      [${ELAPSED}s] /oauth2/userinfo status=${STATUS}"
  if [[ "${STATUS}" == "401" ]]; then
    echo
    echo "[4/4] PASS — token is dead on Verify's side after ${ELAPSED}s"
    echo "      The SSF chain (MCP → Antenna → Verify) is healthy end-to-end."
    exit 0
  fi
done

echo
echo "[4/4] FAIL — token is still active ${REVOKE_TIMEOUT_SEC}s after 3rd denial"
echo "      Troubleshooting:"
echo "        docker logs vva-antenna-receiver --tail 40"
echo "        docker logs vva-antenna-transmitter --tail 40"
echo "      See docs/ssf-troubleshooting.md."
exit 1
