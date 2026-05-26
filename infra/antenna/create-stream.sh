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

# Pre-flight: from inside the RECEIVER container, can it actually reach the
# transmitter at the docker-internal hostname? If not, the v2 stream-create
# POST will fail with the cryptic IBM error code CSICO0007E (HTTP 500) and
# the only way to figure out it was a DNS problem is to dig through receiver
# logs. Surface it here, in human-readable form, BEFORE the customer hits
# that error.
PREFLIGHT_URL="https://${ANTENNA_TRANSMITTER_INTERNAL_HOSTNAME:-antenna-transmitter}:${ANTENNA_TRANSMITTER_PORT}/.well-known/ssf-configuration"
echo "[create-stream] preflight: receiver -> ${PREFLIGHT_URL}"
PREFLIGHT_STATUS=$(docker exec vva-antenna-receiver curl -sk -o /dev/null -w "%{http_code}" \
  --max-time 5 "$PREFLIGHT_URL" 2>&1)
if [[ "$PREFLIGHT_STATUS" != "200" ]]; then
  cat >&2 <<EOF
ERROR: receiver cannot reach the transmitter's SSF discovery URL.
  URL tried:       ${PREFLIGHT_URL}
  curl exit/status: ${PREFLIGHT_STATUS}

This is a docker-network / hostname problem (NOT an IBM Verify problem).
The receiver container fetches that URL from INSIDE its own network namespace,
so it must resolve to the transmitter container. Most likely cause:

  - transmitter.base_url in deploying/transmitter/configs/transmitter.yml
    uses 'localhost' (= the receiver's own container) instead of the
    docker-internal hostname 'antenna-transmitter'.

Diagnostic commands:

  docker exec vva-antenna-receiver getent hosts antenna-transmitter
  # Should resolve to the transmitter's container IP. If not, the docker
  # network is broken — re-run: docker compose up -d antenna-transmitter

  docker exec vva-antenna-receiver curl -vk ${PREFLIGHT_URL} 2>&1 | head -25
  # Look for 'dial tcp ... connect: connection refused' (transmitter not up)
  # or 'no such host' (docker DNS broken).

  grep -E 'base_url|issuer' deploying/transmitter/configs/transmitter.yml
  # Both should show 'antenna-transmitter' (or your override). 'localhost'
  # there is the cookbook's known-bad value — re-run ./configure-antenna.sh
  # after fixing infra/antenna/.env (see docs/ssf-troubleshooting.md
  # § "Receiver cannot reach transmitter").
EOF
  exit 1
fi
echo "[create-stream] preflight OK — receiver can reach transmitter discovery"

# The script (running on the HOST) talks to the receiver via host-side localhost:9043.
RECEIVER_MGMT="https://${ANTENNA_HOSTNAME}:${ANTENNA_RECEIVER_PORT}/mgmt/v2.0/receivers/config"

# CRITICAL: the metadataUrl gets stored in the receiver and fetched by the receiver
# AT POLL TIME from INSIDE its container. "localhost" inside a container means the
# container itself, not the host — so the host-facing hostname is wrong here.
# Use the docker-internal hostname of the transmitter container (matches the
# `hostname:` field in infra/docker-compose.yml). Customer can override via the
# ANTENNA_TRANSMITTER_INTERNAL_HOSTNAME env var if they deploy on a non-default
# network or change container names.
TRANSMITTER_INTERNAL_HOST="${ANTENNA_TRANSMITTER_INTERNAL_HOSTNAME:-antenna-transmitter}"
TRANSMITTER_METADATA="https://${TRANSMITTER_INTERNAL_HOST}:${ANTENNA_TRANSMITTER_PORT}/.well-known/ssf-configuration"

# Idempotency check — GET existing streams; if one matches our transmitter,
# exit 0. The v2 mgmt GET returns the current receiver config (list of
# subscribed transmitters); a substring match on the docker-internal hostname
# is the right key to look for (that's what we just stored).
if existing=$(curl -sk "$RECEIVER_MGMT" 2>/dev/null); then
  if echo "$existing" | grep -q "${TRANSMITTER_INTERNAL_HOST}:${ANTENNA_TRANSMITTER_PORT}"; then
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
  echo "" >&2
  echo "[create-stream] ERROR — non-2xx response from ${RECEIVER_MGMT}" >&2

  # If the receiver responded HTTP 500 + CSICO0007E, the root cause is almost
  # always in its own logs as a "dial tcp ... connect: connection refused"
  # or "no such host" line. Extract that and surface it — saves customers
  # from chasing CSICO0007E in the IBM error catalog (it's a generic
  # "unexpected condition" code and won't tell them what failed).
  if echo "$RESPONSE" | grep -q "CSICO0007E"; then
    DIAG=$(docker logs vva-antenna-receiver --since 30s 2>&1 \
      | grep -oE '(Post|Get) "https?://[^"]*"[^"]*(connection refused|no such host|timeout|network is unreachable)' \
      | tail -1)
    if [[ -n "$DIAG" ]]; then
      echo "" >&2
      echo "Receiver-log diagnostic (this is the ACTUAL failure — CSICO0007E is generic):" >&2
      echo "  ${DIAG}" >&2
      echo "" >&2
      echo "This is a docker-network / DNS problem (NOT an IBM Verify problem)." >&2
      echo "The hostname in that URL must resolve + accept connections FROM" >&2
      echo "the receiver container's network namespace." >&2
      echo "" >&2
      echo "Check transmitter.base_url + .issuer in deploying/transmitter/configs/transmitter.yml" >&2
      echo "— they should use 'antenna-transmitter' (docker-internal), NOT 'localhost'." >&2
      echo "If they're wrong: edit infra/antenna/.env then re-run ./configure-antenna.sh." >&2
      echo "" >&2
      echo "Full receiver log: docker logs vva-antenna-receiver --tail 40" >&2
      echo "Cookbook: docs/ssf-troubleshooting.md § \"Receiver cannot reach transmitter\"" >&2
    fi
  fi
  exit 1
fi
echo "[create-stream] success"
