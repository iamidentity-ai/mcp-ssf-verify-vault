## Addon: Cross-App Cascade

The v1 cookbook's 3-deny demo only exercises one OIDC application — the healthcare agent. A reasonable question from a security reviewer: *"What about the other apps the user is signed into? Does this revocation cascade?"* The answer is yes, automatically, by virtue of how IBM Verify's session-revocation API works. This addon explains what's already happening and sketches how to demonstrate the cascade visually with a second app.

## What "tenant-wide" already means in v1

The action handler at `infra/antenna/recipes/mcp-ssf/verify-receiver/configs/js/session_revoked.js.tpl` calls IBM Verify's `DELETE /v1.0/auth/sessions/{userId}` — not `DELETE /v1.0/auth/sessions/{userId}/apps/{appId}`. The endpoint revokes *every* session the user has on the tenant, across every OIDC application federated to it. That property is the cookbook's headline differentiator and it requires no per-app configuration.

The cookbook only *demonstrates* tenant-wide revocation with one app because the cookbook only stands up one app. The *behavior* is already cross-app, and you can prove it without changing a single line of the cookbook's code.

## To visually demonstrate the cascade

Register a second OIDC application on the same IBM Verify tenant. The cookbook does not provide one — you are demonstrating that you don't need to. In the Verify Admin Console:

1. Navigate to **Applications** > **Add application** > **Web Application** > **OpenID Connect**.
2. Set the application name to something like `Second App for Cascade Demo`.
3. Add a redirect URI for a tool that can complete an OIDC flow without writing code — `https://oidcdebugger.com/debug` works for ad-hoc testing.
4. Set `Grant types` to include `Authorization code` and check `Require PKCE`.
5. Save. Capture the `clientId` from the app's properties tab.

Sign in to both apps in parallel browser tabs (the cookbook's healthcare app in one tab, the second app's OIDC flow in another). Then in a third terminal, run the 3-deny demo from [SSF Demo Walkthrough](../ssf-demo-walkthrough.md). On the third denial, the cookbook app shows the threshold message and stops responding. Within ~30 to 75 seconds, refresh the second app's tab. The second app makes a fresh `/oauth2/userinfo` call (or whatever its session-validity check is), gets a 401, and either clears its session locally or redirects to the IDP login page.

You've watched the tenant-wide property fire end-to-end across two unrelated apps that knew nothing about each other.

## Detection pattern for any second app

Any relying party that wants to surface a revoked session promptly needs a periodic or per-request validity check. The simplest pattern is a server-side check on each navigation that calls IBM Verify's `userinfo` endpoint with the user's access token:

```typescript
// SvelteKit example — +layout.server.ts
import { redirect } from '@sveltejs/kit';

export async function load({ cookies, fetch }) {
  const accessToken = cookies.get('access_token');
  if (!accessToken) throw redirect(302, '/signin');

  const res = await fetch(`https://${VERIFY_TENANT}/oauth2/userinfo`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (res.status === 401) {
    cookies.delete('access_token', { path: '/' });
    throw redirect(302, '/signin');
  }
  return { user: await res.json() };
}
```

The same pattern in any framework that has a server-side route loader. The relying party makes no commitment to SSF; it just notices that its access token has been killed at the IDP and acts accordingly. Cache the result for ~30 seconds if userinfo round-trips are a load concern.

A more advanced pattern subscribes the relying party as its own SSF receiver to the same Antenna transmitter — that way the relying party finds out *immediately* rather than on the next navigation. That's an iteration on what the cookbook already builds; the wiring is identical to chapter 14, just with the relying party's session-clearing logic in place of Verify's session-revocation logic in the action handler. We don't ship a working example here because the point of the v1 cookbook is that you don't need to do this work — the IDP-side revocation cascades automatically, and a 30-second userinfo check is enough for most relying parties.
