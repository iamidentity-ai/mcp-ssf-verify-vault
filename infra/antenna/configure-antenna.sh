#!/bin/bash
# configure-antenna.sh — fetches SSF creds from Vault, templates the rendered configs.
#
# Step-by-step explanation: docs/ssf-manual-deployment.md § "configure-antenna.sh — read Vault, template configs"
#
# Reads from Vault KV (paths in infra/antenna/.env):
#   ${VAULT_SSF_CLIENT_ID_PATH}      field: SSF_CLIENT_ID
#   ${VAULT_SSF_CLIENT_SECRET_PATH}  field: SSF_CLIENT_SECRET
#
# Writes:
#   deploying/transmitter/configs/transmitter.yml    (from transmitter.yml.tpl)
#   deploying/receiver/configs/receiver.yml          (from receiver.yml.tpl)
#   deploying/receiver/configs/js/session_revoked.js (from recipes/.../session_revoked.js.tpl)
#   deploying/transmitter/configs/js/mcp_mapper.js   (copy from recipes/)
#
# By default restarts the containers afterward. Pass --no-restart to skip
# (used by bootstrap-antenna.sh, which restarts them itself in a known order).
#
# Idempotency: every run re-fetches from Vault + re-renders. If Vault returns
# an empty SSF clientId/secret (e.g. infra/verify/bootstrap-verify.ts hasn't
# been run yet) the script ERRORS — it never silently overwrites a good
# rendered config with empty placeholders.

set -euo pipefail
cd "$(dirname "$0")"

[[ -f .env ]] || { echo "ERROR: infra/antenna/.env not found — copy .env.example and edit" >&2; exit 1; }
# shellcheck disable=SC1091
source .env

: "${VAULT_ADDR:?VAULT_ADDR required in infra/antenna/.env}"
: "${VAULT_TOKEN:?VAULT_TOKEN required in infra/antenna/.env}"
: "${ANTENNA_HOSTNAME:?ANTENNA_HOSTNAME required in infra/antenna/.env}"
: "${VERIFY_TENANT_HOSTNAME:?VERIFY_TENANT_HOSTNAME required in infra/antenna/.env}"
: "${VAULT_SSF_CLIENT_ID_PATH:?VAULT_SSF_CLIENT_ID_PATH required in infra/antenna/.env}"
: "${VAULT_SSF_CLIENT_SECRET_PATH:?VAULT_SSF_CLIENT_SECRET_PATH required in infra/antenna/.env}"

# Docker-internal hostname of the transmitter container — used in the URLs the
# transmitter advertises in its /.well-known/ssf-configuration. Defaulted; only
# override if you renamed the container in docker-compose.yml.
ANTENNA_TRANSMITTER_INTERNAL_HOSTNAME="${ANTENNA_TRANSMITTER_INTERNAL_HOSTNAME:-antenna-transmitter}"

fetch_kv() {
  local path=$1 field=$2
  # Strip optional "secret/data/" or "secret/" prefix and re-add the v2 KV path.
  # Covers customers who set the var as `secret/data/X` (canonical) or `secret/X`.
  local clean_path=${path#secret/data/}
  clean_path=${clean_path#secret/}
  # Capture body + HTTP status separately. curl -sf swallows the body on
  # non-2xx, which used to give us empty stdin → python3 traceback. With
  # -s -w "%{http_code}" we get both; we tee status to a separate fd to keep
  # this single-command-friendly. Python parses defensively (empty stdin or
  # malformed JSON returns the empty string instead of crashing).
  local body http_code response
  response=$(curl -s -w "\n%{http_code}" -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/${clean_path}")
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [[ "$http_code" != "200" ]]; then
    # Common: 403 (wrong VAULT_TOKEN), 404 (path doesn't exist). Stay silent
    # here; the caller's empty-string check surfaces the user-facing error.
    return 0
  fi
  echo "$body" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('data', {}).get('data', {}).get('${field}', ''))
except (json.JSONDecodeError, KeyError, TypeError):
    print('')
"
}

CID=$(fetch_kv "${VAULT_SSF_CLIENT_ID_PATH}" SSF_CLIENT_ID || echo "")
CSEC=$(fetch_kv "${VAULT_SSF_CLIENT_SECRET_PATH}" SSF_CLIENT_SECRET || echo "")

# Guard pattern (from feedback_cookbook_idempotent_bootstrap_safety): never
# overwrite rendered configs with empty creds. If we did, the next run of
# create-stream.sh would POST a stream with clientId="" / clientSecret="" and
# the receiver would silently fail to mint a token at poll time.
if [[ -z "$CID" || -z "$CSEC" ]]; then
  echo "ERROR: Vault returned empty SSF creds at ${VAULT_SSF_CLIENT_ID_PATH} / ${VAULT_SSF_CLIENT_SECRET_PATH}" >&2
  echo "" >&2
  echo "Two most common causes:" >&2
  echo "  1. VAULT_TOKEN in infra/antenna/.env is wrong. The dev-mode default" >&2
  echo "     is 'vva-dev-root-token' (NOT 'root'). Verify:" >&2
  echo "       docker exec -e VAULT_TOKEN=vva-dev-root-token vva-vault \\\\" >&2
  echo "         vault kv get -field=SSF_CLIENT_ID secret/SSF_CLIENT_ID" >&2
  echo "" >&2
  echo "  2. You have not created the SSF management API client yet (chapter 14" >&2
  echo "     step 1). Verify Admin UI -> Security -> API -> Create API client" >&2
  echo "     named 'mcp-ssf-shared-signals' with five entitlements, then:" >&2
  echo "       docker exec -e VAULT_TOKEN=vva-dev-root-token vva-vault \\\\" >&2
  echo "         vault kv put secret/SSF_CLIENT_ID SSF_CLIENT_ID=<paste>" >&2
  echo "       docker exec -e VAULT_TOKEN=vva-dev-root-token vva-vault \\\\" >&2
  echo "         vault kv put secret/SSF_CLIENT_SECRET SSF_CLIENT_SECRET=<paste>" >&2
  echo "" >&2
  echo "See docs/ssf-setup.md chapter 14 for the full walkthrough." >&2
  exit 1
fi

render() {
  local tpl=$1 out=$2
  sed -e "s|__SSF_CLIENT_ID__|${CID}|g" \
      -e "s|__SSF_CLIENT_SECRET__|${CSEC}|g" \
      -e "s|__ANTENNA_HOSTNAME__|${ANTENNA_HOSTNAME}|g" \
      -e "s|__ANTENNA_TRANSMITTER_INTERNAL_HOSTNAME__|${ANTENNA_TRANSMITTER_INTERNAL_HOSTNAME}|g" \
      -e "s|__VERIFY_TENANT_HOSTNAME__|${VERIFY_TENANT_HOSTNAME}|g" \
      "$tpl" > "$out"
  echo "wrote $out"
}

render deploying/transmitter/configs/transmitter.yml.tpl deploying/transmitter/configs/transmitter.yml
render deploying/receiver/configs/receiver.yml.tpl       deploying/receiver/configs/receiver.yml
render recipes/mcp-ssf/verify-receiver/configs/js/session_revoked.js.tpl deploying/receiver/configs/js/session_revoked.js

# Copy (not symlink — docker bind-mounts don't handle symlinks consistently
# across platforms) the mcp_mapper into deploying/. The recipes/ tree is the
# canonical source; deploying/ is what the container actually mounts.
cp recipes/mcp-ssf/transmitter/configs/js/mcp_mapper.js deploying/transmitter/configs/js/mcp_mapper.js
echo "wrote deploying/transmitter/configs/js/mcp_mapper.js (from recipes/)"

if [[ "${1:-}" != "--no-restart" ]]; then
  echo "Restarting antenna containers…"
  (cd ../ && docker compose restart antenna-transmitter antenna-receiver)
fi
