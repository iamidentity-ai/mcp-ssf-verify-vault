## SSF Setup

This chapter stands up the SSF pipeline on top of the base cookbook stack. By the end you will have two new containers running (`vva-antenna-transmitter` and `vva-antenna-receiver`), one OIDC application provisioned in your IBM Verify tenant, one stream registered between transmitter and receiver, and one synthetic probe confirming an event posted at the ingester ends with a `204 No Content` from IBM Verify's session-revocation API.

## Prerequisites

You have already worked through chapters 1–10 of the base cookbook: PostgreSQL and Vault are running under docker-compose, the `infra/verify/bootstrap-verify.ts` script has provisioned the cookbook's OIDC apps on your IBM Verify tenant, and the smoke test from chapter 10 returns a real patient row. If any of that is uncertain, run `./scripts/smoke-test.sh` first and resolve failures before continuing.

Two new prerequisites for SSF:

1. **A phone with the IBM Verify mobile app**, signed in as the clinician test user. The push factor must be enrolled — the demo in chapter 15 will fire a push and expect you to tap *Deny* three times.
2. **A clinician test user whose `verifyUserId` you don't mind losing the session of repeatedly.** Each demo run revokes that user's tenant-wide sessions; you will sign them back in fresh each time.

## Step 1: Provision the SSF management app in IBM Verify

The script `infra/verify/bootstrap-verify.ts` (which you ran in chapter 5) was extended in this cookbook to create one additional OIDC application on your Verify tenant. The app is named **MCP-SSF Shared Signals**, uses the `client_credentials` grant, and gets five entitlements scoped to session and grant administration:

```
readUsersAndGroups
revokeUserSession
revokeAllUserSessions
readOidcOAuthGrants
readOidcOAuthConsents
```

The script writes the resulting `clientId` and `clientSecret` to Vault KV at `secret/data/SSF_CLIENT_ID` and `secret/data/SSF_CLIENT_SECRET`. The `configure-antenna.sh` script reads them back from Vault at deploy time; they never sit on disk in plaintext. If you ran the base cookbook bootstrap before SSF was added, re-run it now:

```bash
cd infra/verify
npm run bootstrap
```

The bootstrap is idempotent — if the SSF app already exists, the script logs `[ssf] reusing existing app <id>` and skips creation. You can confirm in the Verify Admin Console: navigate to **Applications**, look for `MCP-SSF Shared Signals`. The entitlements appear under the app's **Entitlements** tab.

[Screenshot placeholder: Verify Admin Console showing the MCP-SSF Shared Signals app's Entitlements tab with the five granted entitlements]

## Step 2: Configure the antenna .env

The antenna scripts read configuration from `infra/antenna/.env`. Copy the example and set the one customer-specific value:

```bash
cp infra/antenna/.env.example infra/antenna/.env
$EDITOR infra/antenna/.env
```

The only variable that varies per customer is `VERIFY_TENANT_HOSTNAME` — set it to your tenant's hostname (no scheme, no trailing slash). For example:

```env
VERIFY_TENANT_HOSTNAME=myco-consulting.tryverify.ibm.com
```

The defaults for `ANTENNA_HOSTNAME=localhost`, `ANTENNA_TRANSMITTER_PORT=9044`, `ANTENNA_RECEIVER_PORT=9043`, `ANTENNA_SOURCE_ID=mcp`, `VAULT_ADDR=http://localhost:8200`, and `VAULT_TOKEN=root` all work for the cookbook's docker-compose setup. The Vault token is the dev-mode root token from `infra/docker-compose.yml`; in production replace it with a properly scoped token via SPIFFE or AppRole.

## Step 3: One-command bootstrap

The single command that brings up the SSF pipeline is:

```bash
./scripts/bootstrap-antenna.sh
```

The script runs six steps in sequence. Each step is idempotent, so a re-run after a partial failure picks up where you left off:

1. **Generate certs.** Self-signed TLS leaf + JWT-signer keypair for both transmitter and receiver. Existing certs are left in place; only missing files are created.
2. **Template configs from Vault.** Reads the SSF clientId and secret from Vault KV, substitutes them into `transmitter.yml.tpl`, `receiver.yml.tpl`, and `session_revoked.js.tpl`. The script errors loudly if Vault returns empty values rather than silently writing empty placeholders.
3. **Start the containers.** `docker compose up -d antenna-transmitter antenna-receiver` brings up the two new services on the shared `mcpssf` docker network.
4. **Wait 30 seconds.** Both containers need to bind their ports and initialize their SQLite databases. The receiver depends on the transmitter being reachable.
5. **Register the stream.** Posts a stream config to the receiver's v26.03 v2 management endpoint at `https://localhost:9043/mgmt/v2.0/receivers/config`. The script checks for an existing stream pointing at our transmitter and skips re-registration if one is present.
6. **Run the synthetic probe.** Fires a `session-revoked` event for the probe user `PROBE_USER_DO_NOT_USE` and watches the receiver logs for `session_revoked action completed successfully` within 75 seconds.

Expected output from a healthy run:

```
==> [1/6] Generating TLS + JWT-signer certs (idempotent)
[certs] using existing server.{key,pem}
[certs] using existing jwtsigner.{key,pem}
==> [2/6] Templating configs from Vault
wrote deploying/transmitter/configs/transmitter.yml
wrote deploying/receiver/configs/receiver.yml
wrote deploying/receiver/configs/js/session_revoked.js
wrote deploying/transmitter/configs/js/mcp_mapper.js (from recipes/)
==> [3/6] Starting antenna containers
[+] Running 2/2
 ✔ Container vva-antenna-transmitter  Started
 ✔ Container vva-antenna-receiver     Started
==> [4/6] Waiting 30s for transmitter + receiver to bind ports + initialize
==> [5/6] Registering stream (idempotent)
[create-stream] registering new stream against https://localhost:9044/.well-known/ssf-configuration
{"id":"e3a1...","name":"mcp-ssf-receiver","metadataUrl":"..."}
HTTP 201
[create-stream] success
==> [6/6] Running synthetic probe
[probe] POST https://localhost:9044/sources/mcp/events (user=PROBE_USER_DO_NOT_USE)
[probe] ingester status: 201
[probe] waiting up to 75s for the receiver to action the event…
[probe] PASS — pipeline is healthy (40s)
```

If the synthetic probe fails, jump to [SSF Troubleshooting](./ssf-troubleshooting.md) — the chapter is organized as a table of failure modes keyed by the symptom you see.

## Step 4: Verify the stream is registered

After bootstrap, the receiver's v2 management endpoint returns the current stream config. Localhost-only by design (the receiver port 9043 is bound to `127.0.0.1` in `infra/docker-compose.yml`):

```bash
curl -sk https://localhost:9043/mgmt/v2.0/receivers/config | python3 -m json.tool
```

Expected output (abbreviated):

```json
{
  "streams": [
    {
      "id": "e3a14b...",
      "name": "mcp-ssf-receiver",
      "metadataUrl": "https://localhost:9044/.well-known/ssf-configuration",
      "authorizationScheme": {
        "type": "urn:ietf:rfc:6749",
        "attributes": {
          "grantType": "client_credentials",
          "clientAuthenticationMethod": "client_secret_post"
        }
      },
      "ssfStream": {
        "delivery": { "method": "urn:ietf:rfc:8936" },
        "events_requested": [
          "https://schemas.openid.net/secevent/caep/event-type/session-revoked"
        ]
      }
    }
  ]
}
```

The `delivery.method` is `urn:ietf:rfc:8936` (SSF poll-based SET delivery). The receiver polls the transmitter every few seconds; no inbound traffic from the outside world is required. The receiver mgmt port is intentionally **not** authenticated in the v26.03 recipes — that's why we bind it to localhost. Don't expose 9043 publicly without putting a real auth gate (mTLS or a reverse proxy enforcing OAuth) in front.

## Step 5: End-to-end synthetic probe

The probe is also runnable on its own:

```bash
./infra/antenna/synthetic-probe.sh
```

It fires one CAEP `session-revoked` event for the user configured via `PROBE_VERIFY_USER_ID` in `infra/antenna/.env` (default `PROBE_USER_DO_NOT_USE`), then tails the receiver logs for `session_revoked action completed successfully` for up to 75 seconds. The 75-second budget accounts for the receiver's poll cycle (typically ~30 seconds), Antenna's batch processing, the OAuth token fetch inside `session_revoked.js`, and the round trip to Verify's session-revocation API.

A successful run prints:

```
[probe] POST https://localhost:9044/sources/mcp/events (user=PROBE_USER_DO_NOT_USE)
[probe] ingester status: 201
[probe] waiting up to 75s for the receiver to action the event…
[probe] PASS — pipeline is healthy (40s)
```

A failed run dumps the last 40 receiver log lines and points at the troubleshooting chapter. Make a habit of running the probe before any demo — it takes one minute and catches the failure modes (stale stream, missing entitlement, expired cert) that otherwise reveal themselves only when a live audience is watching.

## What's running now

Two new containers are visible in `docker ps`:

```
CONTAINER ID   IMAGE                                                       PORTS
abc123def456   icr.io/ibm-verify/ibm-verify-antenna-transmitter:26.03.0   0.0.0.0:9044->9044/tcp
def789abc012   icr.io/ibm-verify/ibm-verify-antenna-receiver:26.03.0      127.0.0.1:9043->9043/tcp
```

Both share the `mcpssf` docker network with the existing `vva-postgres` and `vva-vault` services — that's how the receiver reaches the transmitter by container hostname (`https://antenna-transmitter:9044/.well-known/ssf-configuration`). The transmitter binds to all interfaces because the MCP server, which runs on the host (not in a container), POSTs events to `https://localhost:9044/sources/mcp/events`. The receiver binds only to `127.0.0.1` for the security reason explained above.

The MCP server's `.env` now reads `ANTENNA_SOURCE_URL=https://localhost:9044/sources/mcp/events` and `NODE_TLS_REJECT_UNAUTHORIZED=0`. The first variable tells the SSF dispatcher where to send CAEP events; the second is required because Antenna's TLS cert is self-signed and Node's `fetch` rejects untrusted certs by default. The TLS bypass applies to all outbound fetches from the MCP server process — that's only safe because the MCP server makes outbound calls to (a) IBM Verify (production CA, so the bypass doesn't matter) and (b) the localhost Antenna (the entire point of the bypass). Don't carry the setting into any process that talks to real third-party HTTPS endpoints whose certs you can't control.

## What's next

Move on to [SSF Demo Walkthrough](./ssf-demo-walkthrough.md) to drive the 3-deny flow end-to-end with a real phone. If anything in this chapter failed, [SSF Troubleshooting](./ssf-troubleshooting.md) covers the common failure modes. For a line-by-line explanation of what each of the four antenna scripts does — useful if you want to understand the bootstrap rather than just run it — see [SSF Manual Deployment](./ssf-manual-deployment.md).
