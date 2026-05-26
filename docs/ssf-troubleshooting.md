## SSF Troubleshooting

The SSF pipeline has four moving parts (MCP server, transmitter, receiver, IBM Verify) and three wire formats (CAEP event into the ingester, SET over the poll stream, the Verify admin REST call from the action handler). When something goes wrong the symptom usually shows up several layers downstream of the cause. This chapter is a flat table of failure modes keyed by what you actually see, plus one note about a v25.05 failure mode that is structurally unlikely in v26.03 but still worth checking.

## The synthetic probe is your gold-standard test

Before debugging anything else, run the synthetic probe:

```bash
./infra/antenna/synthetic-probe.sh
```

If the probe prints `[probe] PASS — pipeline is healthy`, the SSF chain is end-to-end functional. Any failure you are diagnosing is then either in your test scenario (e.g. the test user isn't enrolled with a push factor, the bearer isn't a JWT) or in something you changed since the probe last passed. Re-run the probe after every config or code change; it's a one-minute check that catches the cliff edges.

If the probe fails, the table below covers the most common causes.

## Top failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `fetch failed` from the MCP server when emitting | Antenna's self-signed TLS cert rejected by Node's `fetch` | Set `NODE_TLS_REJECT_UNAUTHORIZED=0` in `mcp-server/.env` and restart the MCP server. The cookbook's `.env.example` already includes this line. |
| `404 source not found` on `POST /sources/mcp/events` | `source_id` in `transmitter.yml` doesn't match the URL path | Confirm `infra/antenna/deploying/transmitter/configs/transmitter.yml` has `transmitter.ingester.sources[0].id: mcp` and the MCP server's `ANTENNA_SOURCE_URL` ends in `/sources/mcp/events`. Both default to `mcp`; one was probably renamed without the other. |
| Antenna ingester returns 201 but the action handler never fires | Stream is not registered, or was registered against the wrong transmitter | Run `curl -sk https://localhost:9043/mgmt/v2.0/receivers/config` and confirm at least one stream exists with `metadataUrl` pointing at your transmitter (`https://localhost:9044/.well-known/ssf-configuration`). If empty or pointing at the wrong host, re-run `./infra/antenna/create-stream.sh`. |
| Antenna ingester returns 201, transmitter persists the event but never signs it | CAEP payload shape wrong — typically `event_timestamp` in ms or `initiatingEntity` misspelled | Confirm with `docker logs vva-antenna-transmitter --tail 100` — look for `"failed to parse event timestamp"` or schema-validation errors. Fix the payload to match the canonical shape in `mcp-server/src/ssf/antenna-emitter.ts`. The two camelCase fields (`initiatingEntity`, `reasonAdmin`) and the seconds-not-ms timestamp are the most common errors. |
| Receiver logs `[deleteSessions] status=403` | SSF management API client on IBM Verify is missing entitlements | Open the `mcp-ssf-shared-signals` API client in the Verify Admin UI under **Security** -> **API** and verify the five entitlements are still attached: *Read users and groups*, *Revoke a session for a user*, *Revoke all sessions for a user*, *Read OIDC and OAuth application grants*, *Read OIDC and OAuth consents*. Re-add any missing ones and save. The bootstrap script does NOT manage this credential — it was created manually in chapter 14 and the script never touches it. |
| Receiver logs `[deleteSessions] status=404` | The `verifyUserId` doesn't exist on the tenant, or the SCIM email fallback found no match | Confirm the bearer is JWT-format (not opaque) — the cookbook's UI app's `accessTokenType` must be `jwt` for `bearer-claims.ts` to decode `sub` and `preferred_username`. Decode the bearer with `python3 -c "import base64, json, sys; print(json.dumps(json.loads(base64.urlsafe_b64decode(sys.argv[1].split('.')[1] + '==')), indent=2))" "$TOKEN"` and check the `sub` field is a real user. |
| Containers can't see each other (receiver can't reach transmitter on hostname `antenna-transmitter`) | Missing or misnamed docker network | Confirm `infra/docker-compose.yml` declares the `mcpssf` network at the top level AND attaches both `antenna-transmitter` and `antenna-receiver` to it. `docker network inspect mcpssf` should list both containers. |
| Receiver logs `tls: certificate signed by unknown authority` | Missing or stale `ca-bundle.pem` on the receiver | Re-run `./infra/antenna/generate-certs.sh`. The script regenerates `deploying/receiver/configs/keys/ca-bundle.pem` containing the transmitter's leaf cert, which the receiver trusts when it polls `https://antenna-transmitter:9044`. |
| `401 Unauthorized` on stream registration | Stale or wrong SSF client credentials in the rendered `transmitter.yml` | Re-run `./infra/antenna/configure-antenna.sh` (re-fetches from Vault, re-templates). Confirm the rendered file has real values: `grep -E 'client_id\|client_secret' infra/antenna/deploying/transmitter/configs/transmitter.yml` — values must NOT contain `__SSF_` placeholders. |
| 3-deny demo doesn't trigger the threshold | MCP server `.env` is missing `ANTENNA_SOURCE_URL` or `NODE_TLS_REJECT_UNAUTHORIZED=0` | `grep -E 'ANTENNA_SOURCE_URL\|NODE_TLS_REJECT_UNAUTHORIZED' mcp-server/.env`. Add the missing lines, restart the MCP server. The wrapper increments the counter regardless of whether the emit succeeds, but the threshold-reached branch emits to Antenna — without these env vars, the emit silently fails and the demo's downstream effect (the Verify-side revocation) never happens. |
| Antenna container fails to start with `"No configuration to merge"` | A YAML file under the mounted configs dir is missing the `version: 26.03` first key | Every `.yml` file in `infra/antenna/deploying/{transmitter,receiver}/configs/` must start with `version: 26.03`. Add the line to any file that's missing it. |
| Antenna container fails to start with `"ERROR reading directory /configs"` | Wrong mount path | `infra/docker-compose.yml` must mount the configs at `/configs` (not `/var/antenna/config`, which is what the IBM `verify-antenna-recipes` repo's docker-compose uses — that recipe has a verified bug). |

## MCP tool calls fail with `role "v-healthcare-records-..." does not exist` (Postgres code 28000)

The verify-rar plugin successfully minted a credential — the username + password came back — but Postgres can't authenticate as that user. **Almost always the MCP server's `POSTGRES_PORT` is wrong** and it's connecting to a DIFFERENT Postgres than `vva-postgres` (the one the plugin actually created the role in).

The cookbook's `infra/docker-compose.yml` maps the Postgres container's internal `5432` to the host's `15432` (so it doesn't collide with a system Postgres on the standard port). Two perspectives matter:

- **Vault container** reaches Postgres at `postgres:5432` (docker-network hostname, container-internal port). This is what `verify-rar/config/db`'s `connection_url` uses; the plugin's CREATE ROLE goes here.
- **MCP server** (running on the host) reaches Postgres at `localhost:15432`. This is what `mcp-server/.env`'s `POSTGRES_HOST` + `POSTGRES_PORT` must be.

If `mcp-server/.env` says `POSTGRES_PORT=5432`, the MCP server is talking to whatever else is on host:5432 (system Postgres, another container, nothing) — NOT vva-postgres. The plugin's roles aren't there, so authentication fails.

**Fix**:

```bash
sed -i '' 's/^POSTGRES_PORT=5432/POSTGRES_PORT=15432/' mcp-server/.env
# Restart the MCP server (Ctrl-C + npm run dev)
```

**Diagnostic that uniquely identifies this**: the v-* role DOES exist in vva-postgres immediately after a mint:

```bash
# 1. Mint a probe credential via the plugin
docker exec -e VAULT_TOKEN=vva-dev-root-token vva-vault sh -c 'cat > /tmp/c.json <<EOF
{"claims":{"sub":"t","jti":"t","authorization_details":[{"type":"urn:smt:agent:healthcare","operationDetails":{"action":"patient_read","patient_mrn":"A0001"}}]}}
EOF
vault write -format=json verify-rar/creds/healthcare-records @/tmp/c.json' \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['data']['username'])"
# Output: v-healthcare-records-<hex>

# 2. Confirm THAT role IS in vva-postgres on port 15432 (host-mapped):
PGPASSWORD=any psql "postgresql://v-healthcare-records-<hex>@localhost:15432/healthcare?sslmode=disable" \
  -c "SELECT current_user;"
# This will fail-on-password but the error tells you the role exists.

# 3. Confirm the SAME role is NOT on host port 5432 (the "wrong Postgres"):
PGPASSWORD=any psql "postgresql://v-healthcare-records-<hex>@localhost:5432/healthcare?sslmode=disable" \
  -c "SELECT current_user;"
# Output: FATAL: role "v-healthcare-records-<hex>" does not exist
# That's the exact error the smoke test sees — confirms wrong-port theory.
```

## Receiver cannot reach transmitter

This is the single most common failure mode and the script tries hard to surface it for you. The smoking gun looks like this:

```
[create-stream] ERROR — non-2xx response from https://localhost:9043/mgmt/v2.0/receivers/config

Receiver-log diagnostic (this is the ACTUAL failure — CSICO0007E is generic):
  Post "https://localhost:9044/streams" ... connection refused
  (or)
  Get "https://antenna-transmitter:9044/.well-known/ssf-configuration" ... no such host
```

The receiver responded HTTP 500 with `CSICO0007E`. That code is IBM Verify's generic "unexpected condition" — useless on its own. The actual failure is in the receiver-container logs and is **a docker network / hostname problem, not an IBM Verify problem**.

`create-stream.sh` runs a **preflight check** before POSTing: it execs into the receiver container and curls the transmitter's discovery URL. If the preflight fails, the script exits with a detailed diagnostic before sending anything to Verify. If you see the post-failure diagnostic above, the preflight passed but a deeper inter-container fetch failed (the receiver fetches multiple URLs during stream-create — the discovery URL first, then the `/streams` endpoint advertised in the discovery doc).

**Two specific causes that explain ~all instances of this error:**

1. **`transmitter.base_url` or `transmitter.issuer` is wrong** in `infra/antenna/deploying/transmitter/configs/transmitter.yml`. Both must be the **docker-internal** hostname `https://antenna-transmitter:9044` (or `https://antenna-transmitter` for `issuer`). If they're `localhost`, the receiver fetches the discovery doc, then tries to POST to `https://localhost:9044/streams`, and "localhost" inside the receiver container is the receiver itself — connection refused. This is the cookbook's known-bad value; the templates default to the docker-internal hostname, but if anyone edited the yml by hand or set `ANTENNA_HOSTNAME=localhost` in a way that bled into the templated config, it can drift.
2. **Docker network is broken** — the `mcpssf` network doesn't include both antenna containers, or one of them isn't joined. `docker network inspect infra_mcpssf` should show `vva-antenna-transmitter` and `vva-antenna-receiver` in its `Containers` map. If not: `docker compose up -d antenna-transmitter antenna-receiver` re-attaches them.

**Diagnostic commands**:

```bash
# Does the receiver container resolve the transmitter hostname?
docker exec vva-antenna-receiver getent hosts antenna-transmitter

# Can it reach the discovery URL from inside its network namespace?
docker exec vva-antenna-receiver curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
  https://antenna-transmitter:9044/.well-known/ssf-configuration

# What URLs does the transmitter actually advertise?
curl -sk https://localhost:9044/.well-known/ssf-configuration | python3 -m json.tool
# Look at jwks_uri, configuration_endpoint, status_endpoint.
# They MUST contain 'antenna-transmitter', NOT 'localhost'.

# What does the receiver-side rendered config say?
grep -E 'base_url|issuer' deploying/transmitter/configs/transmitter.yml
```

**Fix**: edit `infra/antenna/.env` and confirm `ANTENNA_TRANSMITTER_INTERNAL_HOSTNAME=antenna-transmitter` is set, then re-template and restart:

```bash
cd infra/antenna
./configure-antenna.sh   # re-templates yml + restarts containers
./create-stream.sh       # retries the registration with the preflight check
```

## The v26.03 "stream silently dead" mode (probably-doesn't-apply, but worth knowing)

In the IBM Antenna v25.05 line there was a canonical failure mode named "stream silently dead." A stream registered against an old binary would persist across a binary upgrade, the new binary required fields the old stream lacked (notably `additional_properties.poll_interval_in_seconds`), and the result was an apparently-healthy stream — visible in `GET /streams`, no errors at startup — that nonetheless never delivered events. The transmitter would persist events as "unsigned" indefinitely; the action handler would never fire. Operators trying to diagnose this saw nothing in logs to suggest the stream was the problem.

The v26.03 stream-create body shape (per `infra/antenna/create-stream.sh`) does not include `additional_properties.poll_interval_in_seconds` at all. The receiver-side v2 management endpoint owns the stream lifecycle and is documented to handle config defaults internally. So this failure mode is structurally unlikely in v26.03 — but if you are upgrading from v25.05, or if symptoms recur for any other reason, the diagnostic is:

```bash
curl -sk https://localhost:9043/mgmt/v2.0/receivers/config | python3 -m json.tool
```

Compare the output across stream entries. If any stream is missing fields that the others have, or shows last-update timestamps far older than the others, that's a candidate. Recovery is `./infra/antenna/create-stream.sh` (creates a new stream alongside any existing ones) followed by deleting the dead stream via the receiver's mgmt DELETE endpoint (the v26.03 path was not yet fully documented at the time of this cookbook's writing — confirm with a `curl -X OPTIONS` probe against your receiver if you need to delete a stream). The v25.05 endpoint was `DELETE /streams?stream_id=...`; the v26.03 equivalent is likely under `/mgmt/v2.0/receivers/config/<id>` but should be confirmed empirically before relying on it.

## Antenna container won't start

Two startup failure modes worth singling out because their error messages are terse:

**`"No configuration to merge"`** — a YAML file under the mounted configs dir is missing its `version: 26.03` first key. Every config file requires it; the binary refuses to load any file without it and refuses to start if none of the files in the directory are valid. Add `version: 26.03` to the top of every `.yml` file under `infra/antenna/deploying/{transmitter,receiver}/configs/`.

**`"ERROR reading directory /configs"`** — the container can't find the configs directory. The mount in `infra/docker-compose.yml` must use `/configs` as the target path; the v26.03 binary unconditionally reads from `/configs`. The IBM `verify-antenna-recipes` repo's docker-compose uses `/var/antenna/config` (a verified bug at the time this cookbook was written) — if you copy-pasted from there, change the path back to `/configs`.

## What's next

If the synthetic probe still won't pass after working through this chapter, the most useful next step is a verbose tail of both Antenna containers while you fire the probe:

```bash
docker logs -f vva-antenna-transmitter &
docker logs -f vva-antenna-receiver &
./infra/antenna/synthetic-probe.sh
```

The transmitter's log shows what happens to the event between the ingester and the SET signer; the receiver's log shows what happens between the poll and the action handler. The handoff between the two is the most opaque part of the pipeline and the place where misconfigurations express themselves as "nothing happens" rather than as visible errors. With both logs open, the gap is usually obvious within the first minute.

For everything else, the [SSF Architecture](./ssf-architecture.md) chapter has the end-to-end sequence diagram — sometimes naming the layer that's quiet narrows the search faster than any single error message.
