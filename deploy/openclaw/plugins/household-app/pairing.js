// One-tap pairing for the app. Whoever runs the box asks the gateway for a setup link
// (household-app.pair), a paired phone asks for one for a new iPhone on Account, and the
// owner may send /app in their own thread. Each is one setup code: OpenClaw's own
// single-use bootstrap token, which the gateway
// forgets after ten minutes, with this gateway's address for phones and who the code is
// for. The app connects with it as a mobile node, OpenClaw pairs the phone by itself and
// hands it a chat-only operator token, never admin, and from then on that phone's key
// speaks for the person in the family room (see room.js).
//
// Nothing here talks to OpenClaw: index.js hands in its bootstrap issuer and its device
// list, so this stays testable without a gateway.

import { isPhoneKey } from "./signature.js";

// The client id the app connects with, which OpenClaw's setup-code pairing approves.
export const APP_CLIENT = "openclaw-ios";

// A phone reaches its gateway only over wss, through the box's tailnet route.
export function isPhoneUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "wss:" && url.hostname !== "" && url.username === "" && url.password === "";
  } catch {
    return false;
  }
}

export async function issueSetupCode({ url, person, assistant, issue, profile }) {
  const issued = await issue({ profile });
  const payload = {
    url,
    bootstrapToken: issued.token,
    expiresAtMs: issued.expiresAtMs,
    access: "limited",
    person,
    assistant,
  };
  return { code: Buffer.from(JSON.stringify(payload), "utf8").toString("base64url"), expiresAtMs: issued.expiresAtMs };
}

// Where the gateway serves the page a pairing link opens, on its own tailnet address.
export const PAIR_PATH = "/household-app/pair";

// A tap on the link opens this page in the phone's browser, which hands the code to the
// app. The code rides after the #, which a browser never sends, so the gateway serves
// the same page to everyone and never sees a code in a request.
export const PAIR_PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Steward AI</title>
<style>
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: 17px/1.45 -apple-system, system-ui, sans-serif; color: #13204A;
    background: radial-gradient(600px 400px at 0% 0%, rgba(110,170,255,.35), transparent 60%), radial-gradient(600px 400px at 100% 100%, rgba(255,190,120,.3), transparent 60%), #F7F5F0; }
  main { text-align: center; padding: 32px 24px; max-width: 360px; }
  a { display: block; margin: 24px 0 12px; padding: 16px; border-radius: 999px; background: #2346D8; color: #fff; text-decoration: none; font-weight: 600; }
  p { color: rgba(19,32,74,.7); margin: 6px 0; }
</style>
</head>
<body>
<main>
  <h1>Steward AI</h1>
  <p id="say">Opening Steward AI to pair this iPhone.</p>
  <a id="open" href="#">Open Steward AI</a>
  <p>No app yet? Install Steward AI first, then tap the link again.</p>
</main>
<script>
  const code = location.hash.slice(1);
  const open = document.getElementById("open");
  if (/^[A-Za-z0-9_-]{20,2000}$/.test(code)) {
    const target = "steward://pair?code=" + encodeURIComponent(code);
    open.href = target;
    history.replaceState(null, "", location.pathname);
    location.replace(target);
  } else {
    document.getElementById("say").textContent = "This link has no code in it. Ask whoever runs your household's server for a new one.";
    open.remove();
  }
</script>
</body>
</html>
`;

// The page's address on this gateway, with the code after the #.
export function pairLink(phoneUrl, code) {
  const url = new URL(phoneUrl);
  return `https://${url.host}${PAIR_PATH}#${code}`;
}

// The link first, which opens the app already paired as the person who asked, then the
// code alone in a code span, which copies with one tap, for pasting by hand.
export function setupReply({ code, link }) {
  return [
    "Tap to set up Steward AI on this iPhone:",
    link,
    "",
    "Or copy this code and tap Paste in Steward AI:",
    `\`${code}\``,
    "",
    "Both work once and stop working in 10 minutes. Send /app again for a new one.",
  ].join("\n");
}

// The owner, in a channel that knows them, or a gateway client allowed to pair devices.
export function mayIssueSetupCode(ctx) {
  if (ctx?.senderIsOwner === true) return true;
  const scopes = Array.isArray(ctx?.gatewayClientScopes) ? ctx.gatewayClientScopes : [];
  return scopes.includes("operator.admin") || scopes.includes("operator.pairing");
}

// The app's phones in OpenClaw's device list. A phone paired by setup code is a node
// that also holds the operator role, one pinned before is an operator.
export function appPhonesFrom(devices) {
  const rows = Array.isArray(devices?.paired) ? devices.paired : [];
  return rows
    .filter((row) => row?.clientId === APP_CLIENT)
    .filter((row) => row.role === "operator" || (Array.isArray(row.roles) && row.roles.includes("operator")))
    .filter((row) => isPhoneKey(row.publicKey));
}

// Their keys, each once.
export function phoneKeysFrom(devices) {
  return [...new Set(appPhonesFrom(devices).map((row) => row.publicKey))];
}
