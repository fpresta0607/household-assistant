import { callKeyHolder } from "./client.mjs";
import { ConnectorError, TOOLS, errorResult, redact } from "./tools.mjs";

/**
 * The only tools the family room may use: none reads gateway files or reaches the key holder.
 * family_history reads only the family room's own messages.
 * household_location is read-only and answers in a group only while that person shares
 * their location with the family from the app. household_cart reaches only the household's
 * shared shopping cart, in the app's family room, and records no orders there.
 * household_home reaches only the thermostat, the music and the living room TV, through
 * the home key holder, and answers only in the app. household_react only puts a tapback on
 * a person's message in the app's family room. household_note reaches only the household note
 * both assistants keep, which both people read, and answers only in the app. picture and
 * video only make a picture or a short video through OpenRouter and send it to the chat they
 * were asked in.
 */
export const SAFE_GROUP_TOOLS = [
  "web_search", "web_fetch", "family_history", "picture", "video", "household_location",
  "household_cart", "household_home", "household_react", "household_note", "scripture",
];
// The household app's channel, the household's only one, and the keys beside the channels
// in `channels` that configure them all rather than being one.
const CHANNEL = "household";
const CHANNEL_SETTINGS = new Set(["defaults", "modelByChannel"]);
const CONNECT_URL = /^https:\/\/pocketpiggies\.app\/assistant\/connect\?request=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/**
 * The ids OpenClaw 2026.9.4 lets a gateway client connect as (GATEWAY_CLIENT_IDS). chat.send
 * names its sender by that id, so a household person called one of these could be spoken
 * for by any client with write scope, and is refused as the app's owner.
 */
const GATEWAY_CLIENT_IDS = new Set([
  "webchat-ui", "openclaw-control-ui", "openclaw-browser-copilot", "openclaw-tui", "webchat", "cli",
  "gateway-client", "openclaw-macos", "openclaw-linux", "openclaw-ios", "openclaw-watchos",
  "openclaw-android", "node-host", "openclaw-worker", "test", "fingerprint", "openclaw-probe",
]);

function householdId(value) {
  return typeof value === "string"
    ? /^(?:household:)?([a-z][a-z0-9-]{0,31})$/.exec(value)?.[1]
    : undefined;
}

function isSafeGroupAllowlist(allowed) {
  return Array.isArray(allowed) && allowed.length > 0 && allowed.every((name) => SAFE_GROUP_TOOLS.includes(name));
}

/**
 * The owner whose finances this gateway may read, as the household app names them, or
 * undefined. A gateway client's id is refused: chat.send names its sender by that id, so a
 * household person called one of these could be spoken for by any client with write scope.
 */
function ownerOf(config) {
  const owner = config?.ownerHouseholdPersonId;
  return householdId(owner) === owner && owner !== "family" && !GATEWAY_CLIENT_IDS.has(owner) ? owner : undefined;
}

/**
 * The controls that keep the owner's finance out of everyone else's turns. The owner's
 * own turns keep every tool, so these hold only if no one else can reach a full-tool
 * turn: the app's channel is the owner's, everyone else's family-room turns run with a
 * tool allowlist that cannot read gateway files or reach the key holder, wherever the
 * channel is configured, switched off or not, and every other chat channel is switched
 * off, since it would admit senders this policy never reviewed. Switching any of them on
 * is a hot reload, so this is checked again before every call.
 */
export function hasFinanceSafeGatewayPolicy(config, owner) {
  const channels = config?.channels ?? {};
  const household = channels[CHANNEL];
  return (
    typeof owner === "string" && householdId(owner) === owner &&
    config.session?.dmScope === "per-channel-peer" && config.session?.groupScope === "per-group" &&
    config.session?.scope !== "global" &&
    (config.bindings ?? []).every((binding) => binding?.session?.groupScope !== "main") &&
    Object.entries(channels).every(([id, channel]) => id === CHANNEL || CHANNEL_SETTINGS.has(id) || channel?.enabled === false) &&
    (household === undefined || (household?.owner?.id === owner && isSafeGroupAllowlist(household?.familyTools)))
  );
}

/**
 * The owner's own turn in the Steward AI app: their own thread, or their own session of the
 * family room, `agent:main:household:group:family:sender:<owner>`, where household-app runs a
 * family-room turn whose message is theirs (the household's decision of 17 October: a
 * question the owner asks in the family room works exactly as it does in their thread, and
 * the owner's finance answers there only when the owner asked). The room's shared session,
 * where everyone else's turns run, gets none. household-app starts a turn in either only for a
 * message one of that person's paired phones signed, and names its author as the sender,
 * which OpenClaw carries to tools as `requesterSenderId`. No other path can name the owner
 * as that sender: a gateway client's chat.send names its own client id, the agent method
 * names one only to resume a turn the gateway already admitted, automations name none, the
 * other person's and the other assistant's family-room turns name themselves, and the
 * household channel belongs to household-app alone. Every identity here is runtime
 * metadata; no model argument can select an account. A queued turn can omit the native
 * chat; when both are present they must agree.
 */
export function authorizedAppTurn(context, config) {
  const owner = ownerOf(config);
  if (owner === undefined) return false;
  if (context.agentId !== "main" || context.agentAccountId !== "default" || context.oneShotCliRun === true) {
    return false;
  }
  const delivery = context.deliveryContext;
  if (delivery?.channel !== CHANNEL || delivery.accountId !== "default" || delivery.threadId != null) {
    return false;
  }
  if (context.messageChannel !== CHANNEL || householdId(context.requesterSenderId) !== owner) return false;
  const to = householdId(delivery.to);
  const chat = context.nativeChannelId === undefined ? to : householdId(context.nativeChannelId);
  if (chat !== to) return false;
  // The owner's family-room turns run in the owner's own session of the room, which no
  // other sender's turn reads, so the figures stay out of everyone else's turns there.
  return (
    (to === owner && context.sessionKey === `agent:main:household:direct:${owner}`) ||
    (to === "family" && context.sessionKey === `agent:main:household:group:family:sender:${owner}`)
  );
}

/**
 * `/pocketpiggies` in the owner's own thread, and nowhere else: a connect link posted in the
 * family room would be everyone's to tap. household-app lets only the owner's signed
 * messages run a command, which OpenClaw passes on as `isAuthorizedSender`.
 */
export function authorizedAppCommand(context, config) {
  const owner = ownerOf(config);
  return (
    owner !== undefined && context.channel === CHANNEL && context.isAuthorizedSender === true &&
    context.messageThreadId === undefined &&
    householdId(context.senderId) === owner && householdId(context.from) === owner &&
    householdId(context.to) === owner &&
    context.sessionKey === `agent:main:household:direct:${owner}`
  );
}

/** The key holder's tool result as one JSON value, or the refusal it carries. */
function answerOf(result) {
  const text = result?.content?.[0]?.type === "text" ? result.content[0].text : undefined;
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    throw new ConnectorError("mcp_transport_error", "The PocketPiggies answer was invalid.");
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new ConnectorError("mcp_transport_error", "The PocketPiggies answer was invalid.");
  }
  if (result.isError) {
    throw new ConnectorError(
      typeof value.code === "string" ? value.code : "connector_error",
      typeof value.message === "string" ? value.message : "PocketPiggies could not complete this.",
    );
  }
  return value;
}

export function register(api, { invoke = callKeyHolder } = {}) {
  const initialConfig = { ...api.pluginConfig };
  const owner = ownerOf(initialConfig);
  let hasWarned = false;
  const isCurrentConfig = () => {
    const isCurrent = (
      owner !== undefined &&
      hasFinanceSafeGatewayPolicy(api.runtime?.config?.current?.() ?? api.config, owner) &&
      api.pluginConfig?.ownerHouseholdPersonId === owner &&
      api.pluginConfig?.accountLabel === initialConfig.accountLabel
    );
    if (!isCurrent && !hasWarned) {
      hasWarned = true;
      api.logger?.warn?.(
        "pocket-piggies: finance is off: the gateway no longer keeps every other chat channel off " +
        "and the app's family room on its tool allowlist; rerun scripts/pocket-piggies-install.py, " +
        "and scripts/openclaw-household-app.py apply for the room",
      );
    }
    if (isCurrent) hasWarned = false;
    return isCurrent;
  };
  const link = async (name, args = {}) => {
    const value = answerOf(await invoke(name, args, { owner }));
    if (typeof value.text !== "string") {
      throw new ConnectorError("mcp_transport_error", "The PocketPiggies answer was invalid.");
    }
    if (name !== "link_start") return { text: value.text };
    if (typeof value.url !== "string" || !CONNECT_URL.test(value.url)) {
      throw new ConnectorError("mcp_transport_error", "The PocketPiggies connect link was invalid.");
    }
    return { text: `${value.text}\n\n${value.url}` };
  };
  api.registerCommand({
    name: "pocketpiggies", description: "Connect or disconnect your PocketPiggies account",
    channels: [CHANNEL], acceptsArgs: true, requireAuth: true,
    handler: async (context) => {
      try {
        if (!isCurrentConfig() || !authorizedAppCommand(context, api.pluginConfig ?? {})) {
          throw new ConnectorError("private_chat_required", "Send /pocketpiggies in your own thread with your assistant.");
        }
        const argument = context.args?.trim() ?? "";
        if (["", "connect", "reconnect"].includes(argument)) return await link("link_start");
        if (argument === "status") return await link("link_status");
        if (argument === "disconnect") return await link("link_disconnect");
        return { text: "Use /pocketpiggies connect, status, reconnect or disconnect." };
      } catch (error) {
        return { text: JSON.parse(errorResult(error).content[0].text).message, isError: true };
      }
    },
  });
  api.registerTool(
    (context) => {
      if (!isCurrentConfig() || !authorizedAppTurn(context, api.pluginConfig ?? {})) return null;
      return TOOLS.map((tool) => ({
        name: tool.name,
        label: "PocketPiggies",
        description: tool.description,
        parameters: tool.inputSchema,
        async execute(_id, args, signal) {
          try {
            // Recheck policy and owner configuration if either changed after discovery.
            if (!isCurrentConfig() || !authorizedAppTurn(context, api.pluginConfig ?? {})) {
              throw new ConnectorError(
                "private_chat_required",
                "Use your own thread for PocketPiggies financial data.",
              );
            }
            const result = await invoke(tool.name, args ?? {}, { signal, owner });
            const value = redact(answerOf(result));
            return { content: [{ type: "text", text: JSON.stringify(value) }], details: value };
          } catch (error) {
            return errorResult(error);
          }
        },
      }));
    },
    { names: TOOLS.map((tool) => tool.name), optional: true },
  );
}

export default { id: "pocket-piggies", name: "Pocket Piggies", register };
