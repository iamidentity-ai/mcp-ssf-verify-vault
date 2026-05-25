#!/bin/bash
# bootstrap-antenna.sh — one-command setup of the IBM Antenna SSF pipeline.
#
# Step-by-step explanation: docs/ssf-manual-deployment.md § "bootstrap-antenna.sh — the orchestrator"
#
# Sequence:
#   0. .env check (copy from .env.example if missing; require customer edit)
#   1. generate-certs.sh        — self-signed TLS + JWT-signer certs (idempotent)
#   2. configure-antenna.sh     — fetch SSF creds from Vault + template configs
#   3. docker compose up -d     — start transmitter + receiver
#   4. wait 30s                  — let both bind ports + initialize
#   5. create-stream.sh         — register the receiver as a subscriber (idempotent)
#   6. synthetic-probe.sh       — end-to-end SSF health check
#
# Prereqs:
#   - infra/docker-compose.yml services postgres + vault are running
#   - infra/verify/bootstrap-verify.ts has run AND written SSF_CLIENT_ID +
#     SSF_CLIENT_SECRET to Vault KV (paths in infra/antenna/.env)
#
# This script is idempotent — safe to re-run after a partial failure.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANTENNA_DIR="${REPO_ROOT}/infra/antenna"

cd "${ANTENNA_DIR}"

# 0. .env check
if [[ ! -f .env ]]; then
  echo "[bootstrap-antenna] infra/antenna/.env not found — copying from .env.example"
  cp .env.example .env
  echo ""
  echo "Edit infra/antenna/.env (specifically VERIFY_TENANT_HOSTNAME) then re-run this script."
  exit 1
fi

# shellcheck disable=SC1091
source .env
: "${VERIFY_TENANT_HOSTNAME:?VERIFY_TENANT_HOSTNAME required in infra/antenna/.env}"

echo "==> [1/6] Generating TLS + JWT-signer certs (idempotent)"
./generate-certs.sh

echo "==> [2/6] Templating configs from Vault"
./configure-antenna.sh --no-restart

echo "==> [3/6] Starting antenna containers"
(cd "${REPO_ROOT}/infra" && docker compose up -d antenna-transmitter antenna-receiver)

echo "==> [4/6] Waiting 30s for transmitter + receiver to bind ports + initialize"
sleep 30

echo "==> [5/6] Registering stream (idempotent)"
./create-stream.sh

echo "==> [6/6] Running synthetic probe"
./synthetic-probe.sh
