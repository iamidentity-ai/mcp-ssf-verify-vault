## SSF Demo Walkthrough

This chapter drives the 3-denials → tenant-wide revocation flow end-to-end with a real phone. By the end you will have watched a clinician's IBM Verify session die across the entire tenant in response to nothing but three taps on the *Deny* button. Two terminal windows side-by-side, one phone, about three minutes.

## Setup

You need three things ready:

1. **A fresh clinician token.** Run `./scripts/get-clinician-token.sh` and capture the output into an environment variable. The token comes from the OIDC + PKCE flow the cookbook bootstrapped in chapter 5; the script does the dance for you and prints the access token on its last line.

```bash
TOKEN=$(./scripts/get-clinician-token.sh | tail -1)
echo "$TOKEN" | head -c 40 && echo "..."
```

2. **A VIP patient MRN.** The cookbook's seed data flags two patients as VIP: `MRN-99001` (Reed) and `MRN-99002` (Thornton). Either works; the walkthrough uses `MRN-99001`.

3. **Your phone with the IBM Verify mobile app**, signed in as the clinician test user. The push factor must be enrolled and the phone must be unlocked and ready to receive notifications.

Open a second terminal next to your first. The second terminal is for tailing the receiver logs while the demo runs. You'll switch between them several times.

[Screenshot placeholder: two terminal windows side-by-side, left showing the agent chat, right showing `docker logs -f vva-antenna-receiver`]

## Step 1: Read a VIP patient and APPROVE the push

Confirm the happy path works before we start denying. From your first terminal, send a request that exercises a VIP read:

```bash
curl -sk -X POST http://localhost:8080/invoke \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Look up patient MRN-99001"}'
```

Your phone rings within a few seconds. Tap **Approve**. The MCP server completes the `jwt_bearer` second leg of the token exchange, mints a fresh OBO with the RAR signed in, asks Vault for a 5-minute Postgres credential, runs the SELECT, and returns the chart. The agent streams the response back through the curl.

In your second terminal, run:

```bash
docker logs vva-antenna-receiver --since 60s
```

The output should be quiet — no `session_revoked` lines. Success on a VIP read does not emit any CAEP event. The deny counter, if any was accrued from earlier attempts, gets cleared. From the MCP server's perspective every successful tool call is also a reset.

## Step 2: Read a VIP patient and DENY the push, three times

Now the actual demo. Run the same `curl` again. The phone rings; this time tap **Deny**. The agent responds with a tool-error narration along the lines of "the MFA push was denied; the request did not complete." In the MCP server's log (`docker logs vva-mcp-server` or wherever your MCP server's stdout goes — for a local node process, the terminal where you ran `npm run dev`) you see:

```
[ssf] mfa denial #1/3 user=643002NOIP tool=get_patient_record code=mfa_denied
```

The counter is at 1. No CAEP event was fired. Check the receiver logs again — still quiet.

Send the request a second time. Tap **Deny** on the phone. The MCP server log adds:

```
[ssf] mfa denial #2/3 user=643002NOIP tool=get_patient_record code=mfa_denied
```

Counter at 2. Still no CAEP event. Still quiet on the receiver.

Send the request a third time. Tap **Deny** on the phone. Now the threshold trips:

```
[ssf] mfa denial #3/3 user=643002NOIP tool=get_patient_record code=mfa_denied
[ssf] CAEP session-revoked emitted for user=643002NOIP
```

The agent's response to this third call is the friendly threshold message: *"3 denials reached. Your session has been revoked across all apps federated to this IBM Verify tenant. Please sign in again."* The agent's loop stops there — it doesn't retry, doesn't pass the error back to the LLM, doesn't make any more tool calls.

Switch to your second terminal and wait. Within ~30 to 75 seconds, the receiver logs catch up:

```bash
docker logs vva-antenna-receiver --since 90s | grep -E "session_revoked|deleteSessions|completed"
```

Expected:

```
----- session_revoked action execution -----
[main] Processing session-revoked event
[main] Subject email: clinician@example.com
[getToken] Token acquired successfully
[fetchUser] Using verifyUserId from event: 643002NOIP
[deleteSessions] status=204
[deleteSessions] All sessions revoked for user 643002NOIP
[main] session_revoked action completed successfully
```

The latency between the agent's threshold message (which happens synchronously, the moment the third denial registers) and the `[deleteSessions] status=204` line (which happens asynchronously after the transmitter signs the SET and the receiver polls for it) is the new normal — Antenna's poll cycle is typically tuned to 30 seconds. Sometimes the action completes in 30 seconds, sometimes 75. If you're past 75 seconds without seeing the `completed successfully` line, your pipeline has a problem; jump to [SSF Troubleshooting](./ssf-troubleshooting.md).

## Step 3: Prove the session is dead on IBM Verify

The crucial demo beat. Without re-authenticating, hit IBM Verify's `userinfo` endpoint with the token you've been using all along:

```bash
curl -sk https://${VERIFY_TENANT_HOSTNAME}/oauth2/userinfo \
  -H "Authorization: Bearer $TOKEN"
```

Expected response:

```json
{"error":"invalid_token","error_description":"CSIAS0080E The OAuth token is not valid"}
```

The token is dead at IBM Verify. Not just at the cookbook's MCP server, not just inside Antenna — the IDP itself has revoked the session. Every other app on the tenant that was relying on that session is now subject to the same 401 on its next token introspection. If you signed in to the IBM Verify mobile app with the same user, refreshing the app will boot you back to the sign-in screen. If you'd opened a second OIDC app federated to the tenant in a parallel browser tab, refreshing that tab triggers a redirect to the IDP login page.

This is the load-bearing claim of the demo: tenant-wide revocation, in real time, from a 3-strikes signal published by one MCP server. Three CAEP fields, one POST to Antenna, one DELETE from Antenna to Verify. The relying parties did nothing — they didn't need to subscribe to anything, didn't need to know SSF existed.

## Step 4: Read the logs end-to-end

Now is a good moment to gather the receipts. The full trace lives in three places:

```bash
# The MCP server — origin of the CAEP emit
grep '\[ssf\]' /path/to/mcp-server.log
```

```
[ssf] mfa denial #1/3 user=643002NOIP tool=get_patient_record code=mfa_denied
[ssf] mfa denial #2/3 user=643002NOIP tool=get_patient_record code=mfa_denied
[ssf] mfa denial #3/3 user=643002NOIP tool=get_patient_record code=mfa_denied
[ssf] CAEP session-revoked emitted for user=643002NOIP
```

```bash
# The Antenna receiver — action handler execution
docker logs vva-antenna-receiver --since 5m | grep -E "session_revoked|deleteSessions|completed"
```

```
----- session_revoked action execution -----
[main] Processing session-revoked event
[fetchUser] Using verifyUserId from event: 643002NOIP
[deleteSessions] status=204
[deleteSessions] All sessions revoked for user 643002NOIP
[main] session_revoked action completed successfully
```

```bash
# Optional — your IBM Verify tenant's event log
# (Navigate to Reports > Events in the Admin Console, filter by user, look
#  for "Session revoked" entries timestamped in the last 5 minutes. Visibility
#  depends on your tenant's event log retention configuration.)
```

The MCP server log and the receiver log are joined by the `verifyUserId` field — that's the value the bearer's `sub` claim carried, which the wrapper decoded via `bearer-claims.ts` and passed to `emitSessionRevoked()`. A SIEM that ingests both logs has everything it needs to reconstruct the chain without a custom correlation id.

[Screenshot placeholder: IBM Verify Admin Console showing the user's recent event log with the "Session revoked" entry timestamped a few seconds after the third denial]

## Step 5: Sign in again

The cookbook keeps no persistent state for the deny counter — it's an in-memory `Map` in the MCP server process, keyed by `verifyUserId`. The threshold-reached branch clears the counter for that user before throwing the friendly error. So a fresh sign-in produces a fresh counter; the old denials don't follow you across sessions.

Get a fresh token:

```bash
TOKEN=$(./scripts/get-clinician-token.sh | tail -1)
```

Run the VIP read again. Phone rings. Tap **Approve**. The chart comes back. The old token stays dead forever — IBM Verify's revocation is final; you cannot un-revoke a session, only mint a new one. But this is a *new* token from a new sign-in, so the system has no opinion about the previous denial streak.

```bash
curl -sk -X POST http://localhost:8080/invoke \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Look up patient MRN-99001"}'
```

Expected response includes the patient's structured chart record, same as Step 1. The deny counter for this user (now signed in under a fresh subject) is back at 0.

## What you just did

Three taps on a phone triggered four things: an in-memory counter increment in the MCP server, a CAEP `session-revoked` event into a local Antenna container, a `DELETE /v1.0/auth/sessions/{userId}` call from Antenna to IBM Verify, and a tenant-wide session kill. The audit trail is in three logs joined by the `verifyUserId` field. The user-facing message arrives synchronously the moment the third denial registers; the Verify-side revocation completes asynchronously within a minute. The chain runs entirely on standards (RFC 8417 for SETs, RFC 8936 for SSF poll delivery, the CAEP profile for the event vocabulary, IBM Verify's documented admin API for the revocation call) — no proprietary correlation ids, no bespoke channels.

If anything in this walkthrough didn't behave as expected — wrong status codes, no log lines, silent timeouts — [SSF Troubleshooting](./ssf-troubleshooting.md) is the next chapter. The chapter after that, the cross-app cascade addon under `docs/addons/`, sketches how to visually demonstrate the tenant-wide property with a second OIDC app you register yourself.
