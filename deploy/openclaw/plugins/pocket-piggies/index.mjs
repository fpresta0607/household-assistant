import { callKeyHolder } from "./client.mjs";
import { ConnectorError, TOOLS, errorResult, redact } from "./tools.mjs";

/**
 * The only tools a family group may use: none reads gateway files or reaches the key holder.
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
  "web_search", "web_fetch", "speak", "family_history", "picture", "video", "household_location",
  "household_cart", "household_home", "household_react", "household_note", "scripture",
];
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

function telegramId(value) {
  return typeof value === "string"
    ? /^(?:telegram:)?([1-9]\d*)$/.exec(value)?.[1]
    : undefined;
}

function householdId(value) {
  return typeof value === "string"
    ? /^(?:household:)?([a-z][a-z0-9-]{0,31})$/.exec(value)?.[1]
    : undefined;
}

function isSafeGroupAllowlist(allowed) {
  return Array.isArray(allowed) && allowed.length > 0 && allowed.every((name) => SAFE_GROUP_TOOLS.includes(name));
}

/**
 * The controls that keep the owner's finance out of everyone else's turns. The owner's
 * own chat keeps every tool, so these hold only if no one else can reach a full-tool
 * turn: private messages come from the owner alone, and every group the bot admits runs
 * with a tool allowlist that cannot read gateway files or reach the key holder. So does
 * the household app's family room wherever its channel is configured, switched off or
 * not, since switching it on is a hot reload.
 */
export function hasFinanceSafeGatewayPolicy(config, owner) {
  const telegram = config?.channels?.telegram;
  const allowFrom = telegram?.allowFrom;
  const groups = telegram?.groups ?? {};
  const household = config?.channels?.household;
  return (
    typeof owner === "string" && telegram?.dmPolicy === "allowlist" &&
    Array.isArray(allowFrom) && allowFrom.length === 1 && telegramId(String(allowFrom[0])) === owner &&
    ["allowlist", "disabled"].includes(telegram.groupPolicy) &&
    telegram.accounts === undefined && telegram.direct === undefined &&
    config.session?.dmScope === "per-channel-peer" && config.session?.groupScope === "per-group" &&
    config.session?.scope !== "global" &&
    (config.bindings ?? []).every((binding) => binding?.session?.groupScope !== "main") &&
    Object.values(groups).every((group) => (
      isSafeGroupAllowlist(group?.tools?.allow) &&
        Object.keys(group.tools).join() === "allow" &&
        group.toolsBySender === undefined && group.topics === undefined
    )) &&
    (household === undefined || isSafeGroupAllowlist(household?.familyTools))
  );
}

function ownsPrivateChat({ channel, sender, chat, sessionKey }, config) {
  const owner = config.ownerTelegramId;
  if (typeof owner !== "string" || !/^[1-9]\d*$/.test(owner)) return false;
  if (channel !== "telegram" || telegramId(sender) !== owner || chat !== owner) return false;
  // Shared main, group, cron, sub-agent and manual CLI sessions fail closed. The
  // installer uses per-channel-peer, which names no account in the session key.
  return sessionKey === `agent:main:telegram:direct:${owner}`;
}

/**
 * Every identity here is runtime metadata; no model argument can select an account.
 * A queued turn can omit the native chat, so then the trusted delivery destination
 * stands in for it, as for family_history; when both are present they must agree.
 */
export function authorizedPrivateTurn(context, config) {
  if (context.agentId !== "main" || context.agentAccountId !== "default" || context.oneShotCliRun === true) {
    return false;
  }
  const delivery = context.deliveryContext;
  if (delivery?.channel !== "telegram" || delivery.accountId !== "default" || delivery.threadId != null) {
    return false;
  }
  const destination = telegramId(delivery.to);
  const chat = context.nativeChannelId === undefined ? destination : telegramId(context.nativeChannelId);
  return chat === destination && ownsPrivateChat({
    channel: context.messageChannel,
    sender: context.requesterSenderId,
    chat,
    sessionKey: context.sessionKey,
  }, config);
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
 * household channel belongs to household-app alone. The config maps the household person
 * to the Telegram owner the key holder is pinned to.
 */
export function authorizedAppTurn(context, config) {
  const owner = householdId(config.ownerHouseholdPersonId);
  if (owner === undefined || owner !== config.ownerHouseholdPersonId || owner === "family" || GATEWAY_CLIENT_IDS.has(owner)) {
    return false;
  }
  if (context.agentId !== "main" || context.agentAccountId !== "default" || context.oneShotCliRun === true) {
    return false;
  }
  const delivery = context.deliveryContext;
  if (delivery?.channel !== "household" || delivery.accountId !== "default" || delivery.threadId != null) {
    return false;
  }
  if (context.messageChannel !== "household" || householdId(context.requesterSenderId) !== owner) return false;
  // A queued turn can omit the native chat; when both are present they must agree.
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

/** The Telegram owner whose finances this turn may read, or undefined when it may read none. */
function financeOwner(context, config) {
  if (authorizedPrivateTurn(context, config)) return telegramId(context.requesterSenderId);
  return authorizedAppTurn(context, config) ? config.ownerTelegramId : undefined;
}

export function authorizedPrivateCommand(context, config) {
  return (
    context.isAuthorizedSender === true &&
    context.messageThreadId === undefined &&
    telegramId(context.from) === config.ownerTelegramId &&
    ownsPrivateChat({
      channel: context.channel,
      sender: context.senderId,
      chat: telegramId(context.to),
      sessionKey: context.sessionKey,
    }, config)
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
  let hasWarned = false;
  const isCurrentConfig = () => {
    const isCurrent = (
      hasFinanceSafeGatewayPolicy(api.runtime?.config?.current?.() ?? api.config, initialConfig.ownerTelegramId) &&
      api.pluginConfig?.ownerTelegramId === initialConfig.ownerTelegramId &&
      api.pluginConfig?.accountLabel === initialConfig.accountLabel &&
      api.pluginConfig?.ownerHouseholdPersonId === initialConfig.ownerHouseholdPersonId
    );
    if (!isCurrent && !hasWarned) {
      hasWarned = true;
      api.logger?.warn?.(
        "pocket-piggies: finance is off: the gateway no longer keeps private messages owner-only " +
        "and groups, the app's family room included, on their tool allowlist; rerun " +
        "scripts/pocket-piggies-install.py, and scripts/openclaw-household-app.py apply for the room",
      );
    }
    if (isCurrent) hasWarned = false;
    return isCurrent;
  };
  const owner = initialConfig.ownerTelegramId;
  const link = async (name, args = {}) => {
    const value = answerOf(await invoke(name, args, { owner }));
    if (typeof value.text !== "string") {
      throw new ConnectorError("mcp_transport_error", "The PocketPiggies answer was invalid.");
    }
    if (name !== "link_start") return { text: value.text };
    if (typeof value.url !== "string" || !CONNECT_URL.test(value.url)) {
      throw new ConnectorError("mcp_transport_error", "The PocketPiggies connect link was invalid.");
    }
    return {
      text: value.text,
      channelData: { telegram: { buttons: [[{ text: "Connect PocketPiggies", url: value.url }]] } },
    };
  };
  const command = async (context, isCallback) => {
    try {
      if (!isCurrentConfig() || !authorizedPrivateCommand(context, api.pluginConfig ?? {})) {
        throw new ConnectorError("private_chat_required", "Use your own private Telegram chat for PocketPiggies.");
      }
      const argument = context.args?.trim() ?? "";
      if (isCallback) {
        if (argument === "pp_connect") return await link("link_start");
        if (argument.startsWith("pp_")) return await link("link_complete", { requestId: argument.slice(3) });
        return { text: "Use /pocketpiggies connect to connect your PocketPiggies account." };
      }
      if (["", "connect", "reconnect"].includes(argument)) return await link("link_start");
      if (argument === "status") return await link("link_status");
      if (argument === "disconnect") return await link("link_disconnect");
      return { text: "Use /pocketpiggies connect, status, reconnect or disconnect." };
    } catch (error) {
      return { text: JSON.parse(errorResult(error).content[0].text).message, isError: true };
    }
  };
  api.registerCommand({
    name: "pocketpiggies", description: "Connect or disconnect your PocketPiggies account",
    channels: ["telegram"], acceptsArgs: true, requireAuth: true,
    handler: (context) => command(context, false),
  });
  api.registerCommand({
    name: "start", description: "Finish connecting your PocketPiggies account",
    channels: ["telegram"], acceptsArgs: true, requireAuth: true,
    handler: (context) => command(context, true),
  });
  api.registerTool(
    (context) => {
      if (!isCurrentConfig() || financeOwner(context, api.pluginConfig ?? {}) === undefined) return null;
      return TOOLS.map((tool) => ({
        name: tool.name,
        label: "PocketPiggies",
        description: tool.description,
        parameters: tool.inputSchema,
        async execute(_id, args, signal) {
          try {
            // Recheck policy and owner configuration if either changed after discovery.
            const owner = isCurrentConfig() ? financeOwner(context, api.pluginConfig ?? {}) : undefined;
            if (owner === undefined) {
              throw new ConnectorError(
                "private_chat_required",
                "Use your own private chat for PocketPiggies financial data.",
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
