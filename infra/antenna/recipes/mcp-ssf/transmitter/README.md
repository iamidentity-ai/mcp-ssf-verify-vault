# MCP-SSF Transmitter Recipe

This recipe configures IBM Verify Antenna as a transmitter for **MCP-server-originated
session-revocation events**. When the mcp-ssf-verify-vault MCP server's 3-MFA-deny
anomaly counter trips for a user, it POSTs a CAEP `session-revoked` event to the
transmitter's ingester (`/sources/mcp/events`); this recipe transforms it
(pass-through) and signs it as a Security Event Token (SET) for the receiver to poll.

## Overview

The MCP server emits CAEP events at one point only — when a user has triggered the
agent's anomaly threshold (3 denied MFA pushes within 5 minutes). This recipe:

1. Receives the raw event from source `mcp`
2. Passes it through (no transformation needed — the MCP shapes it correctly already)
3. Signs it as a SET and stages it for receiver delivery

The companion receiver recipe (`../verify-receiver/`) registers the action handler
that revokes the user's sessions on IBM Verify.

## Prerequisites

- IBM Verify tenant: Sign up for a free trial at [ibm.biz/verify-trial](https://ibm.biz/verify-trial)
- Docker (or Podman) installed locally
- mcp-ssf-verify-vault scaffolded and `infra/.env` filled in

## Deployment

This recipe ships as the **default** transmitter config of the cookbook — running
`./scripts/bootstrap-antenna.sh` from the cookbook root deploys it as-is, no manual
file copies required.

1. Source `mcp_mapper.js` from this directory is copied to the running container's
   `/configs/js/` mount by the bootstrap script.
2. `transmitter.yml.tpl` (one level up at `deploying/transmitter/configs/`) is
   templated with your IBM Verify tenant + SSF management API client credentials
   (read from Vault) and dropped at `/configs/transmitter.yml`.
3. The container starts; the receiver subscribes via `create-stream.sh`.

## Internals

### `mcp_mapper.js` — pure pass-through

The MCP server emits events in canonical CAEP shape already (see
`mcp-server/src/ssf-emit.ts`). The mapper just parses + forwards.

## Testing

End-to-end smoke test: `./scripts/synthetic-probe.sh` — fires a synthetic
session-revoked event against the transmitter ingester and waits up to 75s for the
receiver action handler to log `[deleteSessions] status=204`.

## Customisation

To add new source IDs (e.g. for events from a sibling app), append entries to
`transmitter.ingester.sources[]` in `transmitter.yml.tpl` and ship per-source
transform handlers in this directory.

## Reference

- Canonical pass-through pattern: [IBM verify-antenna-recipes VIP transmitter](https://github.com/ibm-verify/verify-antenna-recipes/tree/main/recipes/vip/transmitter)
- v26.03 schema: `/tmp/verify-antenna-recipes/config/ibm-verify-antenna-config-ref.md`
