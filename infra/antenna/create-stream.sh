#!/bin/bash
# create-stream.sh — registers the receiver as an SSF subscriber to the transmitter.
#
# Step-by-step explanation: docs/ssf-manual-deployment.md § "create-stream.sh — v2 receiver-side stream registration"
#
# v26.03 stream-create lives ON THE RECEIVER at POST :9043/mgmt/v2.0/receivers/config
# (the v25.05 :9043/mgmt/v1.0/receivers/config on the TRANSMITTER is gone — see
# /tmp/v26.03-notes.md §D13 for the version-by-version table).
#
# Body shape per /tmp/v26.03-notes.md §D14 — camelCase top-level fields,
# nested authorizationScheme + ssfStream, NO additional_properties.poll_interval_in_seconds
# (the v25.05 "stream silently dead" trap is structurally fixed in v26.03 because
# receiver-side mgmt owns the stream config).
#
# Idempotent: GETs the existing config first; if a stream already points at our
# transmitter, returns 0 without re-POSTing. Safe to re-run from bootstrap.
#
# Security: the receiver mgmt endpoint ships UNAUTHENTICATED in the v26.03
# recipes. We bind 9043 to 127.0.0.1 only in docker-compose.yml so localhost-only.
# DO NOT change that without putting an auth gate (mTLS / reverse-proxy) in front.

set -euo pipefail
cd "$(dirname "$0")"

[[ -f .env ]] || { echo "ERROR: infra/antenna/.env not found — copy .env.example and edit" >&2; exit 1; }
# shellcheck disable=SC1091
source .env

: "${ANTENNA_HOSTNAME:?ANTENNA_HOSTNAME required in infra/antenna/.env}"
: "${ANTENNA_RECEIVER_PORT:?ANTENNA_RECEIVER_PORT required in infra/antenna/.env}"
: "${ANTENNA_TRANSMITTER_PORT:?ANTENNA_TRANSMITTER_PORT required in infra/antenna/.env}"
: "${VERIFY_TENANT_HOSTNAME:?VERIFY_TENANT_HOSTNAME required in infra/antenna/.env}"

# SSF creds live in the rendered transmitter.yml. configure-antenna.sh must
# have run first; this is the single source of truth for what's currently
# wired up (matches what the transmitter is actually accepting at the bearer
# validation step).
TX_YAML=deploying/transmitter/configs/transmitter.yml
[[ -f "$TX_YAML" ]] || { echo "ERROR: $TX_YAML not found — run ./configure-antenna.sh first" >&2; exit 1; }

CID=$(python3 -c "import yaml,sys; d=yaml.safe_load(open('$TX_YAML')); print(d['authorization_schemes'][0]['client_id'])")
CSEC=$(python3 -c "import yaml,sys; d=yaml.safe_load(open('$TX_YAML')); print(d['authorization_schemes'][0]['client_secret'])")

if [[ -z "$CID" || -z "$CSEC" ]]; then
  echo "ERROR: failed to extract SSF creds from $TX_YAML" >&2
  echo "  Re-run ./configure-antenna.sh to re-template from Vault." >&2
  exit 1
fi

RECEIVER_MGMT="https://${ANTENNA_HOSTNAME}:${ANTENNA_RECEIVER_PORT}/mgmt/v2.0/receivers/config"
TRANSMITTER_METADATA="https://${ANTENNA_HOSTNAME}:${ANTENNA_TRANSMITTER_PORT}/.well-known/ssf-configuration"

# Idempotency check — GET existing streams; if one matches our transmitter,
# exit 0. The v2 mgmt GET returns the current receiver config (list of
# subscribed transmitters); a substring match on our transmitter port suffices.
if existing=$(curl -sk "$RECEIVER_MGMT" 2>/dev/null); then
  if echo "$existing" | grep -q "${ANTENNA_HOSTNAME}:${ANTENNA_TRANSMITTER_PORT}"; then
    echo "[create-stream] stream already exists for ${TRANSMITTER_METADATA} — skipping"
    exit 0
  fi
fi

echo "[create-stream] registering new stream against ${TRANSMITTER_METADATA}"
RESPONSE=$(curl -sk -w "\nHTTP %{http_code}" -X POST "$RECEIVER_MGMT" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"mcp-ssf-receiver\",
    \"metadataUrl\": \"${TRANSMITTER_METADATA}\",
    \"authorizationScheme\": {
      \"type\": \"urn:ietf:rfc:6749\",
      \"attributes\": {
        \"grantType\": \"client_credentials\",
        \"clientId\": \"${CID}\",
        \"clientSecret\": \"${CSEC}\",
        \"clientAuthenticationMethod\": \"client_secret_post\",
        \"discoveryURI\": \"https://${VERIFY_TENANT_HOSTNAME}/oauth2/.well-known/openid-configuration\"
      }
    },
    \"ssfStream\": {
      \"delivery\": { \"method\": \"urn:ietf:rfc:8936\" },
      \"events_requested\": [
        \"https://schemas.openid.net/secevent/caep/event-type/session-revoked\"
      ]
    }
  }")
echo "$RESPONSE"
# Last line is "HTTP <code>"; anything 2xx is success.
STATUS=$(echo "$RESPONSE" | tail -1 | awk '{print $2}')
if [[ "$STATUS" != 2* ]]; then
  echo "[create-stream] ERROR — non-2xx response from ${RECEIVER_MGMT}" >&2
  exit 1
fi
echo "[create-stream] success"
