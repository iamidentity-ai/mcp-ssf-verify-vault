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
// `outputData` global is the return channel back to the antenna runtime.
//
// Reference (canonical pass-through pattern): /tmp/verify-antenna-recipes/recipes/vip/transmitter/configs/js/vip_event_mapper.js
//   (the VIP mapper transforms; ours doesn't need to because the MCP already shapes events correctly)

importClass(logger);

function main() {
    var rawEvent = JSON.parse(eventStr);

    logger.debug("[mcp_mapper] passing through event for sub_id=" + JSON.stringify(rawEvent.sub_id));

    outputData["ssfEvents"] = [];
    outputData["ssfEvents"].push(rawEvent);
}

main();
