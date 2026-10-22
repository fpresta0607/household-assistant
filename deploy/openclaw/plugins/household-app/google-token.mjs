// A fresh Google access token for this gateway's in-app Google sign-in, for gog.
//
// The household app's Connect Google keeps the refresh token here, sealed, under the
// household's iOS client, which has no secret, and gog refuses a client without one. So
// gog's wrapper (deploy/openclaw/bin/gog) runs this, inside the gateway as its own user,
// and hands gog the token as GOG_ACCESS_TOKEN for one run:
//
//   node /opt/household-plugins/household-app/google-token.mjs
//
// It prints the token and nothing else. With no in-app sign-in it prints nothing and
// exits 3, so the wrapper runs gog as installed. Any other failure exits 1 with a reason
// that names no account and no token.

import { readFile } from "node:fs/promises";
import path from "node:path";

import { createGoogleConnector } from "./google-connect.js";

const NOT_CONNECTED = 3;

async function main() {
  const state = process.env.OPENCLAW_STATE_DIR ?? path.join(process.env.HOME ?? "/home/node", ".openclaw");
  const configPath = process.env.OPENCLAW_CONFIG_PATH ?? path.join(state, "openclaw.json");
  const google = createGoogleConnector({
    directory: path.join(state, "household-app", "connectors"),
    clientId: JSON.parse(await readFile(configPath, "utf8"))?.channels?.household?.googleClientId,
    keyringPassword: process.env.GOG_KEYRING_PASSWORD,
  });
  if (!(await google.status()).connected) {
    process.stderr.write("household-app google-token: no Google sign-in from the app on this gateway\n");
    process.exit(NOT_CONNECTED);
  }
  process.stdout.write(await google.accessToken());
}

main().catch((error) => {
  process.stderr.write(`household-app google-token: ${error.message}\n`);
  process.exit(1);
});
