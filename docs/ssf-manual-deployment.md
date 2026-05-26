## SSF Manual Deployment — What Every Script Does

The cookbook ships one-shot scripts to keep the happy path short — `scripts/bootstrap-antenna.sh` brings the entire SSF pipeline up in about a minute. That's enough for a working demo and for everyday operations. But every script in this chapter is also a black box: when something breaks, when a security review asks "what does that script actually do", or when you need to adapt the deployment to a hosted environment that isn't laptop docker-compose, you want to know the exact commands the bootstrap runs and why.

This chapter is the script-by-script deep dive. Each section starts with what the script produces, walks through the commands it runs (including the manual `openssl` / `curl` / `docker` equivalents a customer could copy-paste by hand), and ends with the pointer back to running the script. Read this if you want to *understand* the pipeline; read [SSF setup](./ssf-setup.md) (chapter 14) if you just want to *run* it.

A note on idempotency. Every one of the four antenna scripts plus the `bootstrap-antenna.sh` orchestrator is safe to re-run. Cert generation skips files that already exist; config templating re-fetches from Vault but errors out rather than overwriting good output with empty values (see [`feedback_cookbook_idempotent_bootstrap_safety`](./ssf-troubleshooting.md) for the rationale); stream registration GETs the existing config and skips re-POST if a matching stream is already there; the synthetic probe just emits one event and watches logs. A partial failure leaves the pipeline in a state you can debug, then re-run from the top.

## §1 `generate-certs.sh` — TLS + JWT signer certs

Lives at `infra/antenna/generate-certs.sh`. Produces five files:

```
deploying/transmitter/configs/keys/
  server.key      — RSA-4096 private key for transmitter TLS
  server.pem      — self-signed X.509 cert with SANs: localhost, ${ANTENNA_HOSTNAME}, antenna-transmitter, 127.0.0.1
  jwtsigner.key   — RSA-4096 private key for signing Security Event Tokens (SETs)
  jwtsigner.pem   — self-signed cert wrapping the JWT signer public key (CN=antenna-jwt-signer)

deploying/receiver/configs/keys/
  server.key      — receiver TLS keypair (used by /mgmt/v2.0/receivers/config endpoint)
  server.pem      — SANs: localhost, ${ANTENNA_HOSTNAME}, antenna-receiver, 127.0.0.1
  jwtsigner.key   — receiver-side JWT signer (unused today; provisioned for future receiver-side SET signing)
  jwtsigner.pem
  ca-bundle.pem   — concatenation of (1) the transmitter's leaf cert and (2) system CAs
```

The two `server.*` cert pairs cover TLS at each container's listening port. The `jwtsigner.*` keypair on the transmitter is what signs the Security Event Tokens (SETs) the receiver picks up over the poll stream — a SET is a JWT carrying the CAEP event payload, and `jwtsigner.key` is the private key used to sign each one. The transmitter exposes the public half at its `/.well-known/ssf-configuration` JWKS endpoint so the receiver (or any downstream subscriber) can validate signatures.

The receiver's `ca-bundle.pem` is the most subtle of the five files. When the receiver subscribes to the transmitter at `https://antenna-transmitter:9044/.well-known/ssf-configuration`, the receiver's Go TLS stack has to *trust* the transmitter's self-signed cert. The bundle concatenates the transmitter's leaf cert onto the operator's system CA bundle (sourced from one of `/etc/ssl/cert.pem`, `/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`, `/usr/local/etc/openssl/cert.pem` — first match wins, macOS and common Linux distros covered). The receiver container's env sets `SSL_CERT_FILE=/configs/keys/ca-bundle.pem` so Go's `crypto/x509` picks it up automatically. Without the bundle, the receiver's SSF poll loop fails with `tls: certificate signed by unknown authority`.

File modes: `chmod 600` on every `.key` (operator-readable only); `chmod 644` on every `.pem` (the certs are public material). The script enforces this on the files it generates; if you run the `openssl` commands by hand, do the same `chmod` afterward.

**Manual equivalent.** The script is mostly two `openssl req -x509` invocations per role. For one cert pair by hand:

```bash
# Transmitter server cert + key (TLS for :9044)
openssl req \
  -x509 -newkey rsa:4096 -nodes -days 365 \
  -keyout deploying/transmitter/configs/keys/server.key \
  -out   deploying/transmitter/configs/keys/server.pem \
  -subj "/CN=antenna-transmitter" \
  -addext "subjectAltName=DNS:localhost,DNS:${ANTENNA_HOSTNAME},DNS:antenna-transmitter,IP:127.0.0.1"
chmod 600 deploying/transmitter/configs/keys/server.key
chmod 644 deploying/transmitter/configs/keys/server.pem

# Transmitter SET-signing keypair (signs the JWTs the receiver picks up)
openssl req \
  -x509 -newkey rsa:4096 -nodes -days 365 \
  -keyout deploying/transmitter/configs/keys/jwtsigner.key \
  -out   deploying/transmitter/configs/keys/jwtsigner.pem \
  -subj "/CN=antenna-jwt-signer"
chmod 600 deploying/transmitter/configs/keys/jwtsigner.key
chmod 644 deploying/transmitter/configs/keys/jwtsigner.pem
```

Repeat the `server` block for the receiver with `CN=antenna-receiver` and writing into `deploying/receiver/configs/keys/`. Repeat the `jwtsigner` block for the receiver too (unused today, kept symmetric for future receiver-side signing).

Build the receiver's `ca-bundle.pem` last:

```bash
cat deploying/transmitter/configs/keys/server.pem /etc/ssl/cert.pem \
  > deploying/receiver/configs/keys/ca-bundle.pem
chmod 644 deploying/receiver/configs/keys/ca-bundle.pem
```

(Substitute the correct system-CA path for your OS.)

If you'd rather just run the script: `./infra/antenna/generate-certs.sh`.

## §2 `configure-antenna.sh` — read Vault, template configs

Lives at `infra/antenna/configure-antenna.sh`. Two responsibilities: pull the SSF management API client's `clientId` + `clientSecret` from HashiCorp Vault (where you put them by hand in chapter 14 step 1), then substitute them (plus two hostname values) into four template files.

```
inputs (Vault KV reads):
  secret/data/SSF_CLIENT_ID     → field: SSF_CLIENT_ID
  secret/data/SSF_CLIENT_SECRET → field: SSF_CLIENT_SECRET
  (paths overridable via VAULT_SSF_CLIENT_ID_PATH / VAULT_SSF_CLIENT_SECRET_PATH in .env)

outputs (rendered configs):
  deploying/transmitter/configs/transmitter.yml      ← from transmitter.yml.tpl
  deploying/receiver/configs/receiver.yml            ← from receiver.yml.tpl
  deploying/receiver/configs/js/session_revoked.js   ← from recipes/.../session_revoked.js.tpl
  deploying/transmitter/configs/js/mcp_mapper.js     ← cp from recipes/.../mcp_mapper.js
```

The four placeholders the script substitutes via `sed`: `__SSF_CLIENT_ID__`, `__SSF_CLIENT_SECRET__`, `__ANTENNA_HOSTNAME__`, `__VERIFY_TENANT_HOSTNAME__`. The first two come from Vault; the last two come from `infra/antenna/.env`.

The `mcp_mapper.js` file is a straight `cp` rather than a symlink because docker bind-mounts don't dereference symlinks consistently across platforms — on Linux, a bind-mounted symlink resolves inside the container's view of the host filesystem (which is wrong); on macOS Docker Desktop's gRPC-FUSE, it sometimes works and sometimes doesn't. A copy avoids the entire class of bug. The recipes tree (`recipes/mcp-ssf/transmitter/configs/js/mcp_mapper.js`) is the canonical source you edit; the `deploying/` tree is what containers actually mount.

The `--no-restart` flag exists for one specific reason: `bootstrap-antenna.sh` calls `configure-antenna.sh --no-restart` because the orchestrator brings up the containers itself in a known order (step 3 in §5 below). A standalone re-run of `configure-antenna.sh` (no flag) restarts both containers so the new config takes effect immediately. Both are idempotent.

The idempotency-safety guard is worth calling out because it caught a real bug. If the customer has not yet run the two `vault kv put` commands from chapter 14 step 1 (creating the API client in the Admin UI and landing its credentials in Vault), the KV lookups for `SSF_CLIENT_ID` and `SSF_CLIENT_SECRET` return empty strings. An earlier version of the script let the `sed` substitutions write the empty values into the rendered configs, which then silently failed at runtime (the receiver mints a token at poll time and gets `invalid_client` from Verify). The current script `exit 1`s with a loud error rather than overwriting good values with empty ones. See `feedback_cookbook_idempotent_bootstrap_safety.md` for the wider rule — never let an idempotent bootstrap clobber known-good state with empty values from an upstream that hasn't run yet.

**Manual equivalent.** Read the Vault KV values and template the configs by hand:

```bash
# Source the .env so VAULT_ADDR, VAULT_TOKEN, ANTENNA_HOSTNAME, etc. are set
cd infra/antenna
set -a; source .env; set +a

# Fetch the SSF management API client's clientId + clientSecret from Vault
CID=$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/secret/data/SSF_CLIENT_ID" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data']['SSF_CLIENT_ID'])")
CSEC=$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/secret/data/SSF_CLIENT_SECRET" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data']['SSF_CLIENT_SECRET'])")

# Guard — if either is empty, bootstrap-verify.ts hasn't run successfully
[[ -z "$CID" || -z "$CSEC" ]] && { echo "Empty Vault creds — run bootstrap-verify.ts first" >&2; exit 1; }

# Render the four config files
for pair in \
  "deploying/transmitter/configs/transmitter.yml.tpl:deploying/transmitter/configs/transmitter.yml" \
  "deploying/receiver/configs/receiver.yml.tpl:deploying/receiver/configs/receiver.yml" \
  "recipes/mcp-ssf/verify-receiver/configs/js/session_revoked.js.tpl:deploying/receiver/configs/js/session_revoked.js"; do
  tpl="${pair%:*}"; out="${pair#*:}"
  sed -e "s|__SSF_CLIENT_ID__|${CID}|g" \
      -e "s|__SSF_CLIENT_SECRET__|${CSEC}|g" \
      -e "s|__ANTENNA_HOSTNAME__|${ANTENNA_HOSTNAME}|g" \
      -e "s|__VERIFY_TENANT_HOSTNAME__|${VERIFY_TENANT_HOSTNAME}|g" \
      "$tpl" > "$out"
done

# Copy the mcp_mapper.js (not a symlink — docker bind-mount caveat above)
cp recipes/mcp-ssf/transmitter/configs/js/mcp_mapper.js \
   deploying/transmitter/configs/js/mcp_mapper.js

# Restart the containers so the new configs take effect (skip if bootstrapping)
(cd .. && docker compose restart antenna-transmitter antenna-receiver)
```

If you'd rather just run the script: `./infra/antenna/configure-antenna.sh` (or `./configure-antenna.sh --no-restart` when chained from `bootstrap-antenna.sh`).

## §3 `create-stream.sh` — v2 receiver-side stream registration

Lives at `infra/antenna/create-stream.sh`. Registers the receiver as a subscriber to the transmitter by POSTing a stream config to the v26.03 v2 management endpoint on the receiver. This is one of the headline v26.03 changes — in v25.05 the same registration happened against `POST :9043/mgmt/v1.0/receivers/config` on the *transmitter*; in v26.03 it lives at `POST :9043/mgmt/v2.0/receivers/config` on the *receiver*. Hitting the v25.05 path on a v26.03 deployment returns 404 with no body.

The script does three things:

1. Reads `client_id` + `client_secret` out of the rendered `deploying/transmitter/configs/transmitter.yml` (these were written by `configure-antenna.sh`; the script greps the YAML rather than re-fetching from Vault so the registration uses the *exact* credentials the transmitter is now validating bearers against).
2. GETs `https://localhost:9043/mgmt/v2.0/receivers/config` for idempotency — if any existing stream's `metadataUrl` substring-matches our transmitter's host:port, the script exits 0. Re-running on a healthy pipeline is a no-op.
3. POSTs the new stream config. On HTTP 2xx, prints `[create-stream] success`. On any other status, dumps the response and exits 1.

The POST body is the full v26.03 v2 stream config. Every field has meaning:

```json
{
  "name": "mcp-ssf-receiver",
  "metadataUrl": "https://localhost:9044/.well-known/ssf-configuration",
  "authorizationScheme": {
    "type": "urn:ietf:rfc:6749",
    "attributes": {
      "grantType": "client_credentials",
      "clientId": "<from Vault via transmitter.yml>",
      "clientSecret": "<from Vault via transmitter.yml>",
      "clientAuthenticationMethod": "client_secret_post",
      "discoveryURI": "https://<VERIFY_TENANT>/oauth2/.well-known/openid-configuration"
    }
  },
  "ssfStream": {
    "delivery": { "method": "urn:ietf:rfc:8936" },
    "events_requested": [
      "https://schemas.openid.net/secevent/caep/event-type/session-revoked"
    ]
  }
}
```

Field by field:

- `name` — a human-readable label for the stream. Operator-chosen; the receiver uses it in log lines.
- `metadataUrl` — where the receiver fetches the transmitter's SSF metadata (algorithms, JWKS URL, delivery endpoint). The receiver polls this URL on startup and again when its stream config is updated.
- `authorizationScheme.type` — `urn:ietf:rfc:6749` is the SSF spec's reference to "use OAuth 2.0". The receiver mints a token via the SSF management API client's `client_credentials` grant and presents it as a `Bearer` header to the transmitter on every poll request.
- `authorizationScheme.attributes.grantType` — `client_credentials`. The receiver authenticates as a service principal, not as a user.
- `authorizationScheme.attributes.clientId` / `clientSecret` — the `mcp-ssf-shared-signals` API client's credentials, landed in Vault by the customer's `vault kv put` commands from chapter 14 step 1.
- `authorizationScheme.attributes.clientAuthenticationMethod` — `client_secret_post` sends the credentials in the POST body (rather than as a Basic auth header). Either method works; the cookbook picks `post` to match what `bootstrap-verify.ts` enables on the Verify app.
- `authorizationScheme.attributes.discoveryURI` — the OIDC discovery document for the Verify tenant. The receiver uses it to find the tenant's `/oauth2/token` endpoint.
- `ssfStream.delivery.method` — `urn:ietf:rfc:8936` is "SSF poll-based SET delivery". The receiver polls the transmitter every few seconds asking "give me any SETs you've signed since I last polled". The alternative `urn:ietf:rfc:8935` is push-based (transmitter POSTs to the receiver) — this cookbook uses poll because the receiver is bound to `127.0.0.1` and unreachable from the transmitter's network namespace.
- `ssfStream.events_requested` — an explicit allowlist of CAEP event types the receiver wants. We subscribe only to `session-revoked` because that's the only event the MCP server emits and the only one `session_revoked.js` knows how to action.

**A small but worth-noting deletion from v25.05.** The old v1 stream-create body had `additional_properties.poll_interval_in_seconds` as a required field. v26.03 removed it from the body entirely — poll interval is managed by the receiver internally, configured in `receiver.yml`. This is the structural fix for the "stream silently dead" failure mode that bit production v25.05 customers when the binary upgraded and started requiring the poll interval but their persisted streams predated the requirement. See [SSF troubleshooting](./ssf-troubleshooting.md) and `memory/project_ssf_stream_silently_dead.md` for the full history.

**Manual equivalent.** Register the stream by hand:

```bash
cd infra/antenna
source .env

# Re-extract the creds from the rendered transmitter.yml (single source of truth
# for what's wired up — matches what the transmitter currently accepts).
CID=$(python3 -c "import yaml; print(yaml.safe_load(open('deploying/transmitter/configs/transmitter.yml'))['authorization_schemes'][0]['client_id'])")
CSEC=$(python3 -c "import yaml; print(yaml.safe_load(open('deploying/transmitter/configs/transmitter.yml'))['authorization_schemes'][0]['client_secret'])")

# Idempotency check — skip if stream already registered against our transmitter.
if curl -sk "https://${ANTENNA_HOSTNAME}:${ANTENNA_RECEIVER_PORT}/mgmt/v2.0/receivers/config" \
     | grep -q "${ANTENNA_HOSTNAME}:${ANTENNA_TRANSMITTER_PORT}"; then
  echo "stream already exists — skipping"
  exit 0
fi

curl -sk -X POST "https://${ANTENNA_HOSTNAME}:${ANTENNA_RECEIVER_PORT}/mgmt/v2.0/receivers/config" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"mcp-ssf-receiver\",
    \"metadataUrl\": \"https://${ANTENNA_HOSTNAME}:${ANTENNA_TRANSMITTER_PORT}/.well-known/ssf-configuration\",
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
  }"
```

Expected response: HTTP 201 with a JSON body containing the new stream's `id`, `name`, and full echoed config. Any 4xx or 5xx is a real failure — jump to [SSF troubleshooting](./ssf-troubleshooting.md).

If you'd rather just run the script: `./infra/antenna/create-stream.sh`.

## §4 `synthetic-probe.sh` — end-to-end health check

Lives at `infra/antenna/synthetic-probe.sh`. The gold-standard test that the SSF pipeline is healthy. Fires one CAEP `session-revoked` event at the transmitter's ingester and polls the receiver's docker logs for the action handler to complete within 75 seconds. Pass = the pipeline works end-to-end; fail = something between the ingester and the Verify admin API is broken.

The script POSTs the following payload. The shape is non-negotiable — any deviation makes Antenna return HTTP 201 from the ingester (the JSON parses) but the downstream signer or delivery silently fails, and the action handler never fires:

```json
{
  "sub_id": {
    "format": "email",
    "email": "probe@example.com",
    "verifyUserId": "PROBE_USER_DO_NOT_USE"
  },
  "events": {
    "https://schemas.openid.net/secevent/caep/event-type/session-revoked": {
      "reasonAdmin":     { "en": "synthetic probe" },
      "reasonUser":      { "en": "synthetic probe" },
      "initiatingEntity": "policy",
      "event_timestamp": 1748208000
    }
  }
}
```

Three fields have the canonical SSF traps. Get any one of them wrong and the pipeline silently breaks:

- **`event_timestamp` is epoch seconds.** Not milliseconds. The first time you write Antenna code in JavaScript you reach for `Date.now()`, get milliseconds (1748208000000), the transmitter persists the event, the receiver picks it up, and `session_revoked.js` errors with `"failed to parse event timestamp"` because the value is in the year 57386. Always `Math.floor(Date.now() / 1000)`.
- **`reasonAdmin` and `reasonUser` are language-keyed dicts.** The `{ "en": "..." }` shape exists because the CAEP spec lets the same event carry a reason translated into multiple languages. A flat string (`"reason": "synthetic probe"`) is rejected — the entire event fails schema validation downstream of the ingester.
- **`initiatingEntity` is camelCase.** Not `initiator_entity` and not `initiating_entity`. The CAEP profile picked camelCase for the fields originating in the event payload itself; only the SET wrapper fields (`jti`, `iat`, `aud`) use snake_case.

The 75-second timeout is a budget for: the transmitter to sign the event as a SET (~1s), the receiver to poll the transmitter (default ~30s cycle), the receiver to run `session_revoked.js` against the SET (~1s), the action handler to fetch an OAuth token from Verify (~1s), and the actual `DELETE /v1.0/auth/sessions/<userId>` call to Verify to complete (~5-30s in the wild). 75 seconds covers the worst-case end-to-end with margin. If you tightened it to 30s, you'd see false failures whenever Verify's session-revoke API was under load.

The grep pattern is permissive: `session_revoked action completed successfully\|All sessions revoked`. The first phrase comes from the action handler's top-level logger; the second comes from the inner `deleteSessions()` helper. Either one is proof the chain worked.

The probe revokes a real session if `PROBE_VERIFY_USER_ID` in `.env` points at a real user. The default `PROBE_USER_DO_NOT_USE` is a sentinel — the Verify side returns 404 (user not found), but the upstream pipeline (ingester → signer → receiver poll → action handler → Verify call) still exercises end-to-end. To run the probe against a real user, set `PROBE_VERIFY_USER_ID` in `infra/antenna/.env` to that user's Verify internal id. **They will be signed out everywhere.**

**Manual equivalent.** Fire the event by hand and watch the receiver logs:

```bash
cd infra/antenna
source .env

INGESTER="https://${ANTENNA_HOSTNAME}:${ANTENNA_TRANSMITTER_PORT}/sources/${ANTENNA_SOURCE_ID}/events"
TS=$(date +%s)

curl -sk -X POST "$INGESTER" \
  -H "Content-Type: application/json" \
  -w "\n[probe] ingester status: %{http_code}\n" \
  -d "{
    \"sub_id\":{\"format\":\"email\",\"email\":\"probe@example.com\",\"verifyUserId\":\"PROBE_USER_DO_NOT_USE\"},
    \"events\":{
      \"https://schemas.openid.net/secevent/caep/event-type/session-revoked\":{
        \"reasonAdmin\":{\"en\":\"synthetic probe\"},
        \"reasonUser\":{\"en\":\"synthetic probe\"},
        \"initiatingEntity\":\"policy\",
        \"event_timestamp\":${TS}
      }
    }
  }"

# Watch the receiver logs for up to 75s for the action handler to complete.
docker logs -f --since 90s vva-antenna-receiver \
  | grep --line-buffered "session_revoked action completed successfully\|All sessions revoked"
```

The first command's expected output is `[probe] ingester status: 201`. The second command will print the matching log line within ~30-45 seconds on a healthy pipeline; Ctrl-C when you see it (or wrap the whole thing in a `timeout 75` and exit-status check).

If you'd rather just run the script: `./infra/antenna/synthetic-probe.sh`.

## §5 `bootstrap-antenna.sh` — the orchestrator

Lives at `scripts/bootstrap-antenna.sh`. Six steps in a fixed order; each is idempotent, so a partial failure leaves a debuggable state and a re-run picks up cleanly.

```
0.  .env check          — copy from .env.example if missing; error if customer hasn't edited it
1.  generate-certs.sh   — TLS + JWT-signer keypairs (§1)
2.  configure-antenna.sh --no-restart — fetch Vault creds, template configs (§2)
3.  docker compose up -d antenna-transmitter antenna-receiver
4.  sleep 30            — give both containers time to bind ports + initialize SQLite
5.  create-stream.sh    — register the receiver as a subscriber (§3)
6.  synthetic-probe.sh  — end-to-end smoke (§4)
```

The order matters. Step 1 has to run before step 2 because `configure-antenna.sh` substitutes paths into the rendered configs that reference the cert files generated in step 1. Step 2 has to run before step 3 because the containers won't start without valid configs at `/configs`. Step 4's 30-second sleep exists because the receiver's startup includes a one-shot SSF metadata fetch from the transmitter, which fails (and the receiver dies) if the transmitter isn't ready yet — `docker compose up -d` returns the moment containers are *running*, not when they're *healthy*. Step 5 has to run after step 4 because the receiver's mgmt endpoint isn't reachable until it's fully initialized. Step 6 has to run after step 5 because there's no stream to deliver the event over until the registration is in place.

Step 2 uses `--no-restart` because the containers don't exist yet on the first run (so a restart would error) and on re-runs the orchestrator restarts them itself in step 3 (via `docker compose up -d`, which is no-op-and-recreate if the config files changed). Inside a single bootstrap there's no point bouncing containers twice.

What to do if step N fails:

- Step 1 (certs) — only fails if the operator lacks write permission on `deploying/{transmitter,receiver}/configs/keys/` or `openssl` isn't installed. Both are operator-side issues, not code issues.
- Step 2 (configure) — fails loudly if Vault returns empty creds (re-run the two `vault kv put` commands from chapter 14 step 1 to land the API client's credentials in Vault) or if `infra/antenna/.env` is missing (copy from `.env.example`).
- Step 3 (compose up) — fails if the cookbook's `infra/docker-compose.yml` services postgres + vault aren't already running, or if ports 9043/9044 are bound by another process (`lsof -iTCP -sTCP:LISTEN -P -n | grep '9043\|9044'`).
- Step 4 (sleep) — won't fail directly, but if containers are crashing during this window the next steps will. Check `docker logs vva-antenna-transmitter vva-antenna-receiver` in another terminal during the sleep.
- Step 5 (create-stream) — fails with a non-2xx response if the receiver isn't healthy yet (extend the step 4 sleep), if the receiver mgmt endpoint isn't bound (check port mapping in compose), or if the embedded SSF clientId/secret is wrong (re-run `configure-antenna.sh` to refresh from Vault).
- Step 6 (probe) — covered exhaustively in [SSF troubleshooting](./ssf-troubleshooting.md). Every common failure mode keys off the probe's output.

If you'd rather just run the script: `./scripts/bootstrap-antenna.sh`.

## §6 Troubleshooting the manual flow

The failure modes covered in [SSF troubleshooting](./ssf-troubleshooting.md) (chapter 16) apply identically to the manual flow — running the commands by hand doesn't change *what* breaks, only *what's running under your fingers* when it breaks. The two probes that are most useful when working through the manual flow:

- After running the per-script `openssl` / `curl` / `sed` commands, run `./infra/antenna/synthetic-probe.sh` to confirm the resulting pipeline is end-to-end healthy. It's the same one-minute check you'd run after the orchestrator.
- After any change to a rendered config file under `deploying/`, restart the affected container (`docker compose restart antenna-transmitter` or `... antenna-receiver`) — the v26.03 images do not hot-reload `/configs` changes.

Beyond those, the failure modes table in chapter 16 is the canonical reference. The script-based path and the manual path produce identical artifacts; anything that breaks the script-based path will break the manual path in exactly the same way.

## What you just did

You read every command the SSF bootstrap runs and the rationale for each. You can stand up the pipeline by hand without ever invoking the orchestrator, audit the scripts against the commands documented here, or adapt the deployment to a hosted environment that runs the same commands but stores Vault elsewhere, packages the containers under a different orchestrator, or routes the transmitter through a real public DNS name. The script-based path stays the recommended happy path; this chapter is your reference for when "the script did it" stops being a good enough answer.

## What's next

If you have not yet stood up the pipeline, jump back to [SSF setup](./ssf-setup.md) (chapter 14) for the script-driven path. If the pipeline is up and you want to see it work end-to-end with a real phone, [SSF demo walkthrough](./ssf-demo-walkthrough.md) (chapter 15) is the 3-deny scenario. If something is broken, [SSF troubleshooting](./ssf-troubleshooting.md) (chapter 16) is the failure-mode table.
