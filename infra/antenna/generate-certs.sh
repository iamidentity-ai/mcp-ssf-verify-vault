#!/bin/bash
# Generate self-signed TLS certs + JWT signing keys for the v26.03 split-image Antenna
# deployment. Produces independent cert pairs for the transmitter and receiver
# containers so each role is deployable on its own host.
#
# Step-by-step explanation: docs/ssf-manual-deployment.md § "generate-certs.sh — TLS + JWT signer certs"
#
# Idempotent — if all expected files already exist, the script is a no-op.
# Re-run after `rm -rf deploying/{transmitter,receiver}/configs/keys/` to rotate.
#
# References:
#  - v25.05 single-container generate-certs.sh (adapted for split deployment):
#      /Users/robert/repos/ibm-verify-login/antenna/generate-certs.sh
#  - v26.03 canonical recipe key references (server.pem / jwtsigner.pem):
#      /tmp/verify-antenna-recipes/deploying/{transmitter,receiver}/container-runtime/configs/storage.yml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source .env for ANTENNA_HOSTNAME (the customer-facing SAN). Fall back to localhost
# if .env doesn't exist yet (first-time generation before the customer edits .env).
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "$SCRIPT_DIR/.env"; set +a
fi
ANTENNA_HOSTNAME="${ANTENNA_HOSTNAME:-localhost}"

DAYS=365
RSA_BITS=4096

TX_KEYS_DIR="$SCRIPT_DIR/deploying/transmitter/configs/keys"
RX_KEYS_DIR="$SCRIPT_DIR/deploying/receiver/configs/keys"

mkdir -p "$TX_KEYS_DIR" "$RX_KEYS_DIR"

# ─────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────

generated=()

# gen_server_cert <out_key> <out_pem> <CN> <docker-internal-hostname>
#   Generates an RSA TLS keypair with SANs covering localhost, 127.0.0.1,
#   the customer-facing ANTENNA_HOSTNAME, and the docker-internal hostname.
gen_server_cert() {
  local out_key="$1" out_pem="$2" cn="$3" docker_host="$4"

  if [[ -f "$out_key" && -f "$out_pem" ]]; then
    return 0
  fi

  openssl req \
    -x509 -newkey "rsa:${RSA_BITS}" -nodes -days "$DAYS" \
    -keyout "$out_key" -out "$out_pem" \
    -subj "/CN=${cn}" \
    -addext "subjectAltName=DNS:localhost,DNS:${ANTENNA_HOSTNAME},DNS:${docker_host},IP:127.0.0.1" \
    >/dev/null 2>&1

  chmod 600 "$out_key"
  chmod 644 "$out_pem"
  generated+=("$out_key" "$out_pem")
}

# gen_signing_key <out_key> <out_pem> <CN>
#   Generates an RSA keypair for signing SETs (transmitter) — no SANs needed.
gen_signing_key() {
  local out_key="$1" out_pem="$2" cn="$3"

  if [[ -f "$out_key" && -f "$out_pem" ]]; then
    return 0
  fi

  openssl req \
    -x509 -newkey "rsa:${RSA_BITS}" -nodes -days "$DAYS" \
    -keyout "$out_key" -out "$out_pem" \
    -subj "/CN=${cn}" \
    >/dev/null 2>&1

  chmod 600 "$out_key"
  chmod 644 "$out_pem"
  generated+=("$out_key" "$out_pem")
}

# ─────────────────────────────────────────────────────────────────
# Transmitter — server.{key,pem} + jwtsigner.{key,pem}
# ─────────────────────────────────────────────────────────────────

gen_server_cert \
  "$TX_KEYS_DIR/server.key" \
  "$TX_KEYS_DIR/server.pem" \
  "antenna-transmitter" \
  "antenna-transmitter"

gen_signing_key \
  "$TX_KEYS_DIR/jwtsigner.key" \
  "$TX_KEYS_DIR/jwtsigner.pem" \
  "antenna-jwt-signer"

# ─────────────────────────────────────────────────────────────────
# Receiver — server.{key,pem} + jwtsigner.{key,pem} (jwtsigner is unused
# by the receiver today; generated proactively so future receiver-side
# SET signing — e.g. for second-hop transmission — works without re-running
# this script).
# ─────────────────────────────────────────────────────────────────

gen_server_cert \
  "$RX_KEYS_DIR/server.key" \
  "$RX_KEYS_DIR/server.pem" \
  "antenna-receiver" \
  "antenna-receiver"

gen_signing_key \
  "$RX_KEYS_DIR/jwtsigner.key" \
  "$RX_KEYS_DIR/jwtsigner.pem" \
  "antenna-jwt-signer"

# ─────────────────────────────────────────────────────────────────
# Receiver ca-bundle.pem
#
# The receiver subscribes to the transmitter's SSF metadata at
# https://antenna-transmitter:9044/.well-known/ssf-configuration. Because the
# transmitter uses a self-signed cert, the receiver needs to trust it explicitly
# (otherwise the SSL handshake fails when it polls). We concatenate the
# transmitter's leaf cert onto the system CA bundle so the receiver trusts
# BOTH the transmitter AND any public CA (e.g. the IBM Verify tenant's TLS).
#
# Set SSL_CERT_FILE=/configs/keys/ca-bundle.pem in the receiver container env
# (handled by docker-compose.yml, Task 1.8) so Go's crypto/x509 picks it up.
# ─────────────────────────────────────────────────────────────────

CA_BUNDLE="$RX_KEYS_DIR/ca-bundle.pem"

# Detect system CAs (best-effort; this script runs on the operator's laptop so
# we expect macOS or Linux). Both produce a PEM-formatted concatenation.
detect_system_cas() {
  local candidate
  for candidate in \
    /etc/ssl/cert.pem \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/pki/tls/certs/ca-bundle.crt \
    /usr/local/etc/openssl/cert.pem; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

if [[ ! -f "$CA_BUNDLE" ]]; then
  {
    echo "# IBM Verify Antenna receiver CA bundle — generated by generate-certs.sh"
    echo "# Contains: (1) transmitter leaf cert (self-signed), (2) system CAs."
    echo "# Mount: /configs/keys/ca-bundle.pem in the antenna-receiver container."
    echo "# Wire: SSL_CERT_FILE=/configs/keys/ca-bundle.pem in the receiver env."
    echo
    echo "# ───── transmitter leaf (self-signed, trusts antenna-transmitter:9044) ─────"
    cat "$TX_KEYS_DIR/server.pem"
    if sys_ca="$(detect_system_cas)"; then
      echo
      echo "# ───── system CAs (sourced from ${sys_ca}) ─────"
      cat "$sys_ca"
    else
      echo
      echo "# (No system CA bundle found at the common paths. Receiver will only"
      echo "#  trust the transmitter leaf. Edit this file to append public CAs"
      echo "#  if the action handler needs to call non-IBM-Verify HTTPS endpoints.)"
    fi
  } > "$CA_BUNDLE"
  chmod 644 "$CA_BUNDLE"
  generated+=("$CA_BUNDLE")
fi

# ─────────────────────────────────────────────────────────────────
# Report
# ─────────────────────────────────────────────────────────────────

if [[ ${#generated[@]} -eq 0 ]]; then
  echo "[generate-certs] All cert files already exist — nothing to do."
  echo "[generate-certs] To rotate: rm -rf deploying/{transmitter,receiver}/configs/keys && re-run."
else
  echo "[generate-certs] Generated ${#generated[@]} file(s) (SAN: ${ANTENNA_HOSTNAME}, RSA-${RSA_BITS}, ${DAYS}d):"
  for f in "${generated[@]}"; do
    echo "  $f"
  done
fi
