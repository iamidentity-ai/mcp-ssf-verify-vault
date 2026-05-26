// IBM Verify Antenna v26.03 — Transmitter ingester transform for source_id=mcp.
//
// The mcp-ssf-verify-vault MCP server (mcp-server/src/ssf-emit.ts) emits
// already-canonical CAEP JSON when its 3-deny anomaly fires:
//
//   {
//     "sub_id": { "format": "email", "email": "...", "verifyUserId": "..." },
//     "events": {
//       "https://schemas.openid.net/secevent/caep/event-type/session-revoked": {
//         "event_timestamp": <epoch_seconds>,
//         "initiatingEntity": "policy",
//         "reasonAdmin": { "en": "..." },
//         "reasonUser":  { "en": "..." }
//       }
//     }
//   }
//
// So this transform is a PURE PASS-THROUGH: parse the raw event and push it onto
// outputData.ssfEvents unchanged. The transmitter's ssf_2_set worker then signs
// it as a JWT SET and queues it for receiver poll.
//
// The `eventStr` global is the body of the POST to /sources/mcp/events. The
// `outputData` variable MUST be declared at module scope by this script (the
// v26.03 JS engine does NOT inject it as a global); the runtime reads it back
// after main() returns. The v25.05 engine DID inject `outputData` as a global —
// scripts ported from v25.05 that omit the `let outputData = {};` declaration
// fail at runtime with "ReferenceError: outputData is not defined".
//
// Reference (canonical v26.03 pattern, including the let outputData line):
//   /tmp/verify-antenna-recipes/recipes/vip/transmitter/configs/js/vip_event_mapper.js

importClass(logger);

let outputData = {};

function main() {
    var rawEvent = JSON.parse(eventStr);

    logger.debug("[mcp_mapper] passing through event for sub_id=" + JSON.stringify(rawEvent.sub_id));

    outputData["ssfEvents"] = [];
    outputData["ssfEvents"].push(rawEvent);
}

main();
