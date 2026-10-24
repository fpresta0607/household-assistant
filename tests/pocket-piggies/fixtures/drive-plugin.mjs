// Drives the real OpenClaw plugin against a real key holder socket for
// tests/test_pocketpiggies_keyholder.py and prints what the owner and the model would get.
import { callKeyHolder } from "../../../deploy/openclaw/plugins/pocket-piggies/client.mjs";
import { register } from "../../../deploy/openclaw/plugins/pocket-piggies/index.mjs";
import { FINANCE_SAFE_GATEWAY_CONFIG, OWNER } from "./gateway.mjs";

const [socketPath] = process.argv.slice(2);
const registered = { commands: {}, tools: null };
register({
  pluginConfig: { ownerHouseholdPersonId: OWNER, accountLabel: "corey" },
  config: structuredClone(FINANCE_SAFE_GATEWAY_CONFIG),
  registerCommand: (command) => { registered.commands[command.name] = command; },
  registerTool: (factory) => { registered.tools = factory; },
}, { invoke: (name, args, options = {}) => callKeyHolder(name, args, { ...options, socketPath }) });

const ownThread = {
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "household",
  requesterSenderId: OWNER,
  nativeChannelId: OWNER,
  sessionKey: `agent:main:household:direct:${OWNER}`,
  deliveryContext: { channel: "household", accountId: "default", to: `household:${OWNER}` },
};
// The owner allowed access on PocketPiggies' page and came back to send `/pocketpiggies status`.
const completed = await registered.commands.pocketpiggies.handler({
  channel: "household", senderId: OWNER, from: `household:${OWNER}`, to: `household:${OWNER}`,
  isAuthorizedSender: true, sessionKey: `agent:main:household:direct:${OWNER}`, args: "status",
});
const tools = registered.tools(ownThread);
const byName = Object.fromEntries(tools.map((tool) => [tool.name, tool]));
await byName.pocketpiggies_catalog.execute("catalog", {});
const read = await byName.pocketpiggies_read.execute("read", { read: "account.safe_to_transfer" });
const records = await byName.pocketpiggies_records.execute("records", { table: "transactions", limit: 50 });
const synced = await byName.pocketpiggies_read.execute("synced", { read: "account.safe_to_transfer", sync: "now" });
const groupTools = registered.tools({
  ...ownThread,
  nativeChannelId: "family",
  sessionKey: "agent:main:household:group:family",
  deliveryContext: { channel: "household", accountId: "default", to: "household:family" },
});
process.stdout.write(JSON.stringify({
  completed, tools: tools.map((tool) => tool.name), groupTools, read, records, synced,
}));
