// IBM Verify Antenna v26.03 — session-revoked action handler (mcp-ssf-verify-vault cookbook)
//
// Lifted verbatim from the canonical VIP recipe:
//   /tmp/verify-antenna-recipes/recipes/vip/verify-receiver/configs/js/session_revoked.js
// (also published at https://github.com/ibm-verify/verify-antenna-recipes/tree/main/recipes/vip)
//
// Only changes vs the VIP recipe:
//   - TENANT, CLIENT_ID, CLIENT_SECRET are templated tokens replaced by
//     infra/antenna/scripts/configure-antenna.sh at deploy time (the .tpl
//     suffix on this file signals that — the rendered .js file with concrete
//     values lands at deploying/receiver/configs/js/session_revoked.js)
//   - This comment block
//
// Triggered by: receiver.yml's action_rule for event_type=session-revoked.
// Fires when the mcp-ssf-verify-vault MCP server emits a session-revoked SET
// after the 3-MFA-deny anomaly counter trips. The handler:
//   1. Mints a tenant-admin OAuth token via client_credentials on the SSF OIDC client
//   2. Looks up the user by email (from sub_id.email in the SET payload)
//   3. Resets the user's password (auto-generated, notification email sent)
//   4. Deletes ALL active sessions for that user via DELETE /v1.0/auth/sessions/{id}
//
// Step 3 (password reset) is part of the VIP-recipe template. For an SSF-only
// "revoke sessions but don't reset password" deployment, comment out the
// resetPassword(...) call in main(). See README.md in this directory.

importClass(logger);
importClass(http);

// General
let debugLog = logger.info;

// Verify tenant variables — replaced at render time by configure-antenna.sh
const TENANT        = "__VERIFY_TENANT_HOSTNAME__"
const CLIENT_ID     = "__SSF_CLIENT_ID__"
const CLIENT_SECRET = "__SSF_CLIENT_SECRET__"
const THEME_ID      = "default";

// Extract the SET
const SETPayload = JSON.parse(eventStr).claimsJson;

// Debug logs to trace whatever is received
debugLog("----- session_revoked action execution -----");
debugLog("EventStr: " + eventStr);

function getToken() {
    let opt = {
        "headers": {
            "content-type": "application/x-www-form-urlencoded"
        }
    };

    let payload = `client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&grant_type=client_credentials`;
    result = http.post(opt, `https://${TENANT}/oauth2/token`, payload);

    let tokenResponse = JSON.parse(result.body);
    if (tokenResponse.error && tokenResponse.error != "") {
        logger.error(`Failed to get a token with error: ${tokenResponse.error_description}`);
        return null;
    }

    return tokenResponse.access_token;
}

function fetchUser(token) {
    let encodedUsername = encodeURIComponent(SETPayload.sub_id.email);
    let url = `https://${TENANT}/v2.0/Users?count=1&filter=(userName%20eq%20%22${encodedUsername}%22)&attributes=id`;
    debugLog(`[fetchUser] url: ${url}`);

    opts = {
        "headers": {
            "Authorization": `Bearer ${token}`,
            "Accept": "application/scim+json"
        }
    };

    result = http.get(opts, url);
    debugLog(`[fetchUser] URL response: ${JSON.stringify(result)}`);
    if (result.statusCode != 200) {
        logger.info(`[fetchUser] Failed to find user with username ${SETPayload.sub_id.email}; error=${result.body.detail}`);
        return null;
    }

    let userResponse = JSON.parse(result.body);
    let userId = userResponse.Resources[0].id;
    debugLog(`[fetchUser] userId=${userId}`)
    return userId;
}

function resetPassword(userId, token) {
    let url = `https://${TENANT}/v2.0/Users/${userId}/passwordResetter?themeId=${THEME_ID}`;
    opts = {
        "headers": {
            "Authorization": `Bearer ${token}`,
            "content-type": "application/scim+json"
        }
    };

    payload = {
        "operations": [
            {
                "op": "replace",
                "value": {
                    "password":"auto-generate",
                    "urn:ietf:params:scim:schemas:extension:ibm:2.0:Notification": {
                        "notifyManager":false,
                        "notifyPassword":true,
                        "notifyType":"EMAIL"
                    }
                }
            }
        ],
        "schemas": [
            "urn:ietf:params:scim:api:messages:2.0:PatchOp"
        ]
    };

    result = http.patch(opts, url, payload);
    debugLog(`[resetPassword] status=${result.statusCode}, body=${result.body}`)
}

function deleteSessions(userId, token) {
    let url = `https://${TENANT}/v1.0/auth/sessions/${userId}`;
    opts = {
        "headers": {
            "Authorization": `Bearer ${token}`
        }
    };

    result = http.delete(opts, url);
    debugLog(`[deleteSessions] status=${result.statusCode}, body=${result.body}`)
}

function main() {
    // Get a valid token to call APIs on Verify
    let token = getToken();
    if (!token) {
        return;
    }

    // fetch the user
    let userId = fetchUser(token);
    if (!userId) {
        return;
    }

    // reset password
    resetPassword(userId, token);

    // delete sessions
    deleteSessions(userId, token);
}

main();
