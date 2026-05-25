# MCP-SSF Verify Receiver Recipe

This recipe is the companion to [`../transmitter/`](../transmitter/) and configures
IBM Verify Antenna as a **receiver** that consumes session-revoked SETs and triggers
a tenant-wide session revocation on IBM Verify via the admin API.

## Overview

When the mcp-ssf-verify-vault MCP server's 3-MFA-deny anomaly fires, the
transmitter signs a CAEP `session-revoked` event and stages it for poll. The
receiver pulls the SET, decodes it, and dispatches to `session_revoked.js`. The
handler:

1. Mints a tenant-admin OAuth token (client_credentials on the SSF OIDC client)
2. Looks up the user by email (from `sub_id.email` in the SET payload)
3. Resets the user's password (auto-generated, email notification sent)
4. Calls `DELETE /v1.0/auth/sessions/{userId}` to terminate **every** active
   session that user has across **every** federated app on the tenant

Step 3 (password reset) is lifted verbatim from the canonical VIP recipe. For a
"revoke sessions but don't reset password" deployment, comment out the
`resetPassword(...)` call in `session_revoked.js.tpl`'s `main()` function and
re-run `configure-antenna.sh`.

## Prerequisites

- The companion [transmitter recipe](../transmitter/) deployed and running
- An **API client** on the IBM Verify tenant (created automatically by
  `infra/verify/bootstrap-verify.ts`) with these entitlements:
  - Read users and groups
  - Reset password of any user
  - Revoke all sessions for a user
- The SSF OIDC client's clientId + clientSecret stored in Vault at
  `secret/data/SSF_CLIENT_ID` + `secret/data/SSF_CLIENT_SECRET`

## Deployment

This recipe ships as the **default** receiver config of the cookbook — running
`./scripts/bootstrap-antenna.sh` from the cookbook root deploys it as-is:

1. `session_revoked.js.tpl` in this directory is rendered (tenant +
   clientId/secret substituted) to `deploying/receiver/configs/js/session_revoked.js`
2. `receiver.yml.tpl` (one level up at `deploying/receiver/configs/`) is templated
   and dropped at `/configs/receiver.yml`
3. The receiver container starts
4. `create-stream.sh` POSTs to `https://antenna-receiver:9043/mgmt/v2.0/receivers/config`,
   which subscribes the receiver to the transmitter

## Testing

End-to-end smoke (after stream is registered):
```bash
./scripts/synthetic-probe.sh
```
Probe fires a synthetic session-revoked SET into the transmitter ingester; within
~30-75 seconds you should see `[deleteSessions] status=204` in the receiver logs
(`docker logs -f antenna-receiver`).

## Internals

### `session_revoked.js.tpl`

Templated copy of [VIP recipe `session_revoked.js`](https://github.com/ibm-verify/verify-antenna-recipes/blob/main/recipes/vip/verify-receiver/configs/js/session_revoked.js).
The only deltas are templating placeholders for the three tenant constants and
the comment block at the top.

## Reference

- Canonical VIP receiver recipe: [verify-antenna-recipes VIP verify-receiver](https://github.com/ibm-verify/verify-antenna-recipes/tree/main/recipes/vip/verify-receiver)
- v26.03 schema (action_rules): `/tmp/verify-antenna-recipes/config/ibm-verify-antenna-config-ref.md` §9.5
- IBM Verify admin API: [DELETE /v1.0/auth/sessions/{id}](https://docs.verify.ibm.com/verify/reference/deleteuseraccess)
