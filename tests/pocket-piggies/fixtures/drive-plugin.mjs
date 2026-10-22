// Drives the real OpenClaw plugin against a real key holder socket for
// tests/test_pocketpiggies_keyholder.py and prints what the owner and the model would get.
import { callKeyHolder } from "../../../deploy/openclaw/plugins/pocket-piggies/client.mjs";
import { register } from "../../../deploy/openclaw/plugins/pocket-piggies/index.mjs";
import { FAMILY_GROUP, FINANCE_SAFE_GATEWAY_CONFIG } from "./gateway.mjs";

const [socketPath, requestId] = process.argv.slice(2);
const owner = "7000000001";
const config = structuredClone(FINANCE_SAFE_GATEWAY_CONFIG);
config.channels.telegram.allowFrom = [owner];
const registered = { commands: {}, tools: null };
register({
  pluginConfig: { ownerTelegramId: owner, accountLabel: "corey" },
  config,
  registerCommand: (command) => { registered.commands[command.name] = command; },
  registerTool: (factory) => { registered.tools = factory; },
}, { invoke: (name, args, options = {}) => callKeyHolder(name, args, { ...options, socketPath }) });

const privateTurn = {
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "telegram",
  requesterSenderId: owner,
  nativeChannelId: `telegram:${owner}`,
  sessionKey: `agent:main:telegram:direct:${owner}`,
  deliveryContext: { channel: "telegram", accountId: "default", to: `telegram:${owner}` },
};
const completed = await registered.commands.start.handler({
  channel: "telegram", senderId: owner, from: `telegram:${owner}`, to: `telegram:${owner}`,
  isAuthorizedSender: true, sessionKey: `agent:main:telegram:direct:${owner}`, args: `pp_${requestId}`,
});
const tools = registered.tools(privateTurn);
const byName = Object.fromEntries(tools.map((tool) => [tool.name, tool]));
await byName.pocketpiggies_catalog.execute("catalog", {});
const read = await byName.pocketpiggies_read.execute("read", { read: "account.safe_to_transfer" });
const records = await byName.pocketpiggies_records.execute("records", { table: "transactions", limit: 50 });
const synced = await byName.pocketpiggies_read.execute("synced", { read: "account.safe_to_transfer", sync: "now" });
const groupTools = registered.tools({
  ...privateTurn,
  nativeChannelId: `telegram:${FAMILY_GROUP}`,
  sessionKey: `agent:main:telegram:group:${FAMILY_GROUP}`,
});
process.stdout.write(JSON.stringify({
  completed, tools: tools.map((tool) => tool.name), groupTools, read, records, synced,
}));
