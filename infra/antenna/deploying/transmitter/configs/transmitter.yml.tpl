---
# IBM Verify Antenna v26.03 — Transmitter configuration template (mcp-ssf-verify-vault cookbook)
#
# Templated tokens (replaced by infra/antenna/scripts/configure-antenna.sh at deploy time):
#   __ANTENNA_HOSTNAME__           — customer-facing hostname (TLS SAN, also embedded in base_url + issuer)
#   __VERIFY_TENANT_HOSTNAME__     — IBM Verify tenant hostname (no scheme)
#   __SSF_CLIENT_ID__              — clientId of the "MCP-SSF Shared Signals" OIDC client on the tenant
#   __SSF_CLIENT_SECRET__          — its secret
#
# Schema reference: /tmp/verify-antenna-recipes/config/ibm-verify-antenna-config-ref.md
# Canonical recipe: /tmp/verify-antenna-recipes/deploying/transmitter/container-runtime/configs/transmitter.yml
#
# v26.03 invariants:
#   - `version: 26.03` MUST be the first key (missing -> "No configuration to merge.")
#   - `transmitter.base_url` and `transmitter.issuer` are both REQUIRED
#   - `transmitter.runtime.enabled: true` must be EXPLICITLY set (defaults off)
#   - `transmitter.runtime.jwks.signing_keystore` is REQUIRED when runtime is enabled
#   - `transmitter.ingester.enabled: true` must be EXPLICITLY set (defaults off)
#   - `transform_rules` live INSIDE each `transmitter.ingester.sources[].transform_rule`
#     (the v25.05 top-level `processor:` block is GONE)
version: 26.03

logging:
  level: info

transmitter:
  server:
    ssl:
      key: "ks:server/key"
      certificate: "ks:server/cert"

  # Base URL the receiver discovers via /.well-known/ssf-configuration. Must be a
  # hostname the receiver can reach (in docker-compose: antenna-transmitter:9044;
  # externally: __ANTENNA_HOSTNAME__:9044).
  base_url: "https://__ANTENNA_HOSTNAME__:9044"

  # Issuer claim on the signed SET tokens. Convention is the base hostname (no port).
  issuer: "https://__ANTENNA_HOSTNAME__"

  # ALL existing subjects auto-added to new streams (vs NONE = receiver must
  # explicitly add subjects via the subject management API). For the cookbook
  # demo we want every revoked session to flow, so ALL is correct.
  default_subjects: ALL

  # Event types the transmitter publishes. Both are CAEP-standard:
  #   verification    — receiver-initiated probe (used by stream-create handshake)
  #   session-revoked — emitted by the MCP server when the 3-deny anomaly fires
  event_types:
    - "https://schemas.openid.net/secevent/ssf/event-type/verification"
    - "https://schemas.openid.net/secevent/caep/event-type/session-revoked"

  runtime:
    enabled: true
    jwks:
      # MUST match a keystore name in storage.yml. The `default_signing_key`
      # value matches the LABEL of the key entry inside that keystore
      # (storage.yml: keystores[name=jwks_keys].key[label=jwtsigner]).
      signing_keystore: jwks_keys
      default_signing_key: jwtsigner
    sign_poll_set: true
    # Cookbook is single-tenant, low-throughput. Defaults from the recipe are
    # tuned for production; trimmed here.
    max_ssf_event_worker: 2
    max_set_push_worker: 2
    wait_ssf_event_timeout: 5s
    request_timeout: 20

  ingester:
    enabled: true
    # MUST be <= the partition count of databases.raw_2_ssf (storage.yml).
    worker_threads: 1

    sources:
      # Source id 'mcp' is referenced by the MCP server's ANTENNA_SOURCE_URL
      # (mcp-server/.env): https://__ANTENNA_HOSTNAME__:9044/sources/mcp/events
      # The transform is a pure pass-through — the MCP emits already-canonical
      # CAEP JSON (sub_id + events object), so the mapper just forwards.
      - id: mcp
        type: http_push
        transform_rule:
          type: javascript
          content: "@js/mcp_mapper.js"

# JS engine — used by both ingester transforms and (on the receiver) action
# handlers. Cookbook value matches the recipe.
javascript:
  timeout: 10
  max_concurrent_jobs: 16
  max_ctx_pre_isolate: 50

# OAuth bearer the transmitter accepts on INBOUND management calls (i.e. when
# the receiver POSTs /mgmt/v2.0/receivers/config on itself, which then turns
# around and calls the transmitter's stream-create endpoint with this bearer).
#
# The clientId/secret point at the "MCP-SSF Shared Signals" OIDC client created
# by infra/verify/bootstrap-verify.ts on the IBM Verify tenant. Its entitlements:
#   - Read users and groups
#   - Revoke all sessions for a user
#
# These same credentials are also used by session_revoked.js (the action handler)
# to mint a tenant admin token; consolidating to one OIDC client keeps Vault
# storage simple.
authorization_schemes:
  - spec_urn: "urn:ietf:rfc:6749"
    client_id: "__SSF_CLIENT_ID__"
    client_secret: "__SSF_CLIENT_SECRET__"
    client_authentication_method: "client_secret_post"
    discovery_uri: "https://__VERIFY_TENANT_HOSTNAME__/oauth2/.well-known/openid-configuration"
