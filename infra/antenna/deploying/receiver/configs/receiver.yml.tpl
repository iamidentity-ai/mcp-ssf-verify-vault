---
# IBM Verify Antenna v26.03 — Receiver configuration template (mcp-ssf-verify-vault cookbook)
#
# Templated tokens (replaced by infra/antenna/scripts/configure-antenna.sh at deploy time):
#   __ANTENNA_HOSTNAME__           — customer-facing hostname (TLS SAN, also embedded in base_url)
#
# Schema reference: /tmp/verify-antenna-recipes/config/ibm-verify-antenna-config-ref.md §9
# Canonical recipe: /tmp/verify-antenna-recipes/deploying/receiver/container-runtime/configs/receiver.yml
#
# v26.03 invariants:
#   - `version: 26.03` MUST be the first key
#   - `receiver.base_url` is REQUIRED
#   - `receiver.management.enabled: true` is the v2 stream-create gate (defaults off)
#   - `receiver.runtime.enabled: true` must be EXPLICITLY set (defaults off)
#   - `action_rules` live INSIDE `receiver.runtime.action_rules`
#     (the v25.05 top-level `processor:` block is GONE)
#
# Security note on the management port (9043):
#   The recipe-shipped stream-create scripts POST to /mgmt/v2.0/receivers/config
#   WITHOUT any Authorization header — the receiver mgmt endpoint is
#   unauthenticated in v26.03 by default. The receiver-side schema has no
#   auth-on-management knob; the inbound mgmt port is intentionally lockdown-at-
#   network-layer. Cookbook docker-compose binds 9043 to localhost only by
#   default; for production, front it with a reverse proxy that enforces
#   mTLS / a static API key / an OAuth gate, OR restrict access via
#   iptables / Security Groups.
version: 26.03

logging:
  level: info

receiver:
  server:
    ssl:
      key: "ks:server/key"
      certificate: "ks:server/cert"

  # Base URL the transmitter targets when pushing SETs back. In docker-compose
  # this is the internal hostname (antenna-receiver:9043). For non-compose
  # deployments edit configure-antenna.sh to reflect the receiver's reachable
  # address from the transmitter's POV.
  base_url: "https://__ANTENNA_HOSTNAME__:9043"

  # THE v2 stream-create gate. With this set to true, the receiver exposes
  # POST /mgmt/v2.0/receivers/config on its HTTPS port; create-stream.sh hits
  # that endpoint to subscribe to the transmitter.
  management:
    enabled: true

  runtime:
    enabled: true

    # MUST be <= the partition count of databases.ssf_2_action (storage.yml).
    worker_threads: 2

    # Periodically purge processed/errored events from ssf_2_action so SQLite
    # doesn't grow unbounded. 60s is the recipe default.
    cleaner_interval_in_secs: 60
    event_states_to_clean:
      - "actioned"
      - "errored"

    action_rules:
      # When a session-revoked SET arrives, run the cookbook action handler
      # (recipes/mcp-ssf/verify-receiver/configs/js/session_revoked.js.tpl
      # rendered to deploying/receiver/configs/js/session_revoked.js by
      # configure-antenna.sh). The handler calls IBM Verify's
      # DELETE /v1.0/auth/sessions/{userId} admin API to revoke every session
      # the named user has across every federated app on the tenant.
      - event_type: "https://schemas.openid.net/secevent/caep/event-type/session-revoked"
        type: javascript
        content: "@js/session_revoked.js"

# JS engine — used by action handlers. Matches the recipe defaults.
javascript:
  timeout: 10
  max_concurrent_jobs: 16
  max_ctx_pre_isolate: 50
