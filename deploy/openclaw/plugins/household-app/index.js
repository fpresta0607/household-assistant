// The household app as an OpenClaw channel, `household`: the family room the two people
// and both assistants share, and each person's own thread with their assistant, in
// place of Telegram.
//
// A turn in the app is a channel turn like a Telegram one: it carries who sent it and the
// family room's recent messages as history. The owner's own turns, their thread and a
// family-room turn they started, have every tool their thread has; anyone else's
// family-room turn has The Fam's allowlist, or none without one (family-tools.js), and
// each family-room turn is told whose it is and who else reads the room. In the family room the
// assistant answers only when a message names it or replies to it, the way the
// household's Telegram group works, and a voice note is heard first to find out, once,
// its words then shown under it and handed to the turn (voice-notes.js).
// Replies, and anything the assistant sends there on its own (a reminder, a spoken
// reply), land in the room and on the phone.
//
// The phone talks to this through the gateway methods below, over the connection it
// already pairs with. The other gateway's half of the family room arrives through the
// host relay, which writes it into this plugin's inbox; see relay-in.mjs. The rules for
// who may say what live in room.js, checklist ticks on the assistants' cards in cards.js,
// where the owner is, while they share it, in location.js and the assistant's tool for it
// in location-tool.js, the house's thermostat and music in home-tool.js, the household note both
// assistants write and every app turn starts with in notes.js, a step that waits for the owner's yes in approvals.js and which
// steps wait in approval-asks.js, what a run changed, for the chips under its answer, in
// did.js, a call with the assistant folded into one entry once it ends in call-log.js, and
// nothing here logs what anybody said or where anybody is.
//
// Settings, the phone's own assistant's name, voice, model, connectors and manner, are in
// settings.js, with spend.js, speak.js and models.js behind the Settings pages, and the
// owner's iPhones on Account in phones.js. The assistant's day at a glance above the pins
// on Chats is in today.js, and the one line for the day older phones show there in brief.js.

import { AsyncLocalStorage } from "node:async_hooks";
import { execFile } from "node:child_process";
import { readFileSync, watch } from "node:fs";
import { mkdir, readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { promisify } from "node:util";
import path from "node:path";

import { resolveApprovalOverGateway } from "openclaw/plugin-sdk/approval-gateway-runtime";
import {
  CHANNEL_APPROVAL_NATIVE_RUNTIME_CONTEXT_CAPABILITY,
  createChannelApprovalNativeRuntimeAdapter,
} from "openclaw/plugin-sdk/approval-handler-runtime";
import {
  buildChannelOutboundSessionRoute,
  createChatChannelPlugin,
  defineChannelPluginEntry,
} from "openclaw/plugin-sdk/channel-core";
import {
  buildMentionRegexes,
  formatLocationText,
  implicitMentionKindWhen,
  matchesMentionWithExplicit,
  resolveChannelInboundRouteEnvelope,
  resolveInboundMentionDecision,
  toInboundMediaFacts,
} from "openclaw/plugin-sdk/channel-inbound";
import {
  createMessageReceiptFromOutboundResults,
  defineChannelMessageAdapter,
  waitUntilAbort,
} from "openclaw/plugin-sdk/channel-outbound";
import { buildJsonChannelConfigSchema } from "openclaw/plugin-sdk/core";
import {
  PAIRING_SETUP_BOOTSTRAP_PROFILE,
  issueDeviceBootstrapToken,
  listDevicePairing,
} from "openclaw/plugin-sdk/device-bootstrap";
import { registerChannelRuntimeContext } from "openclaw/plugin-sdk/channel-runtime-context";
import { channelReadyPatch, channelStoppedPatch } from "openclaw/plugin-sdk/gateway-runtime";
import { getAgentScopedMediaLocalRoots } from "openclaw/plugin-sdk/media-local-roots";
import { formatAudioTranscriptForAgent } from "openclaw/plugin-sdk/media-understanding-runtime";
import { loadOutboundMediaFromUrl } from "openclaw/plugin-sdk/outbound-media";
import { createFixedWindowRateLimiter, readJsonWebhookBodyOrReject } from "openclaw/plugin-sdk/webhook-ingress";

import { APPLE_PATH, createAppleKeys, createAppleSignIn, createNonces } from "./apple-signin.js";
import { ASKING_TOOLS, askBeforeChange } from "./approval-asks.js";
import { familyAutomations } from "./automations.js";
import { approvalNativeRuntime, createApprovals, ownerApprovalCapability } from "./approvals.js";
import { BRIEF_TOOL, createBrief, createBriefTool } from "./brief.js";
import { TODAY_TOOL, createToday, createTodayTool } from "./today.js";
import { CALL_TURN_INSTRUCTION, callSetupLine } from "./call-log.js";
import { DASHBOARD_TOOL, createCardTick, createCartOrdered, refuseDashboardInApp } from "./cards.js";
import { CART_TOOL, createCart } from "./cart.js";
import { createCartTool } from "./cart-tool.js";
import { createDid } from "./did.js";
import { FAMILY_POST_TOOLS, createFamilyPosts, householdRoutingGuidance } from "./family-posts.js";
import { gmailSource } from "./gmail-source.js";
import { createOrderMail } from "./order-mail.js";
import { createConnect } from "./connect.js";
import { CONNECTORS, connectorsFor } from "./connectors.js";
import { familyToolPolicy } from "./family-tools.js";
import { createGoogleConnector, listGogAccounts, removeGogAccount } from "./google-connect.js";
import { createHandovers } from "./handovers.js";
import { createImageUnderstanding, imageSource, isImageAttachment } from "./image-understanding.js";
import { callHome } from "./home-client.js";
import { HOME_TOOL, createHomeTool } from "./home-tool.js";
import { createLocation } from "./location.js";
import { LOCATION_TOOL, createLocationTool } from "./location-tool.js";
import { MAX_MEDIA_BYTES, createMediaStore } from "./media.js";
import { isMentioned } from "./mentions.js";
import { MICROSOFT_ENV, createMicrosoftConnector } from "./microsoft-connect.js";
import { createModelCatalog } from "./models.js";
import { createNoteTool } from "./note-tool.js";
import { NOTE_TOOL, createNotes } from "./notes.js";
import { createNotionConnector } from "./notion-connect.js";
import {
  PAIR_PAGE,
  PAIR_PATH,
  isPhoneUrl,
  issueSetupCode,
  mayIssueSetupCode,
  pairLink,
  phoneKeysFrom,
  setupReply,
} from "./pairing.js";
import { phoneMetricsLine } from "./phone-metrics.js";
import { createPhones, removeThroughOpenClaw } from "./phones.js";
import { createHttp2Transport, createPush } from "./push.js";
import { REACT_TOOL, createReactTool } from "./react-tool.js";
import { createRoom } from "./room.js";
import { assistantPage, createSettings, nameOf } from "./settings.js";
import { openSettingsStore } from "./settings-store.js";
import { isTextSignedBy } from "./signature.js";
import { createSpeak } from "./speak.js";
import { createSpend, mediaSpentSince } from "./spend.js";
import { openRoomStore } from "./store.js";
import { ownersFamilySession } from "./turn.js";
import { createVideoSummaries, videoSource } from "./video-summary.js";
import { createHearing, isNameSpoken } from "./voice-notes.js";

export const PLUGIN_ID = "household-app";
export const CHANNEL = "household";
const ACCOUNT = "default";
const AGENT = "main";
const FAMILY = "family";
// The two assistants' direct line: a handoff from the other one starts a turn in this
// group's session, with The Fam's tools (family-tools.js), and is posted nowhere.
const PAIR = "pair";
// A handoff starts a turn only while it is this fresh; an older one, from before a restart,
// is marked seen and waits in the note.
const HANDOFF_WITHIN_MS = 10 * 60_000;
const ROOM_HISTORY = 20;
const MAX_INBOX_FILE = 64 * 1024 * 1024;
const INBOX_SCAN_MS = 2000;
// How often the owner's Amazon order mail is read, and how soon after the channel starts.
const ORDER_MAIL_MS = 30 * 60_000;
const ORDER_MAIL_FIRST_MS = 2 * 60_000;
// How often calls past their thirty days are dropped while the channel runs.
const OLD_CALLS_MS = 6 * 3_600_000;
// How often this assistant's family reminders are checked for one that came due.
const REMINDERS_MS = 30_000;
const execFileAsync = promisify(execFile);
// One mail binary's run: no shell, a minute at most, the bytes as they came, and stopped
// with the channel.
const runMail = (file, args, signal) =>
  execFileAsync(file, args, { timeout: 60_000, maxBuffer: 25 * 1024 * 1024, encoding: "buffer", signal });
const MAX_MEDIA_CHUNK = 512 * 1024;
const TYPING_KEEPALIVE_MS = 4000;
const APPLE_BODY_BYTES = 16 * 1024;
const APPLE_BODY_MS = 10_000;

// The channel's config, `channels.household`, the same schema the manifest declares.
const CHANNEL_SCHEMA = JSON.parse(
  readFileSync(new URL("./openclaw.plugin.json", import.meta.url), "utf8"),
).channelConfigs.household.schema;

const PERSON = /^[a-z][a-z0-9-]{0,31}$/;

export function resolveAccount(cfg) {
  const config = cfg?.channels?.household ?? {};
  const configured = Boolean(
    PERSON.test(config.owner?.id ?? "") &&
      PERSON.test(config.assistant?.id ?? "") &&
      PERSON.test(config.peer?.person?.id ?? "") &&
      PERSON.test(config.peer?.assistant?.id ?? ""),
  );
  return { accountId: ACCOUNT, enabled: config.enabled !== false, configured, config };
}

// What a send to "household:<target>" means: the family room, or the owner's own thread.
export function normalizeTarget(raw) {
  const target = String(raw ?? "").trim().replace(/^household:/i, "").toLowerCase();
  return target === FAMILY || PERSON.test(target) ? target : undefined;
}

// Everything one running account holds, set while the channel runs and cleared when it stops.
let live = null;
// The gateway's event emitter, which exists only while this plugin's service runs.
let events = null;
let runtime = null;
// Apple's signing keys, and a ceiling on sign-ins. Every phone reaches the gateway
// through the box's one tailnet route, so the ceiling is for the gateway as a whole.
const appleKeys = createAppleKeys();
const appleLimiter = createFixedWindowRateLimiter({ windowMs: 60_000, maxRequests: 30, maxTrackedKeys: 1 });
// OpenClaw's session workflow, from the full registration: where a checklist tick waits
// for the assistant's next turn.
let workflow = null;
let logger = null;
// The scheduler, once OpenClaw has reconciled it, and the one mirror of this assistant's
// family automations into the household note running at a time (automations.js).
let scheduler = null;
let mirroring = Promise.resolve();

function mirrorAutomations() {
  mirroring = mirroring.then(async () => {
    const running = live;
    const current = scheduler;
    if (!running || !current || current.signal?.aborted) return;
    const jobs = await current.cron.list({ includeDisabled: true });
    const counts = running.notes.mirror(familyAutomations(jobs, { config: runtime.config.current() }), { forWho: running.owner.id });
    if (counts.added + counts.corrected + counts.removed > 0) logger?.info?.(`${PLUGIN_ID}: family automations mirrored: ${JSON.stringify(counts)}`);
  }).catch(() => logger?.warn?.(`${PLUGIN_ID}: the family automations could not be mirrored`));
  return mirroring;
}
// OpenRouter's public model lists, read at most once an hour.
const catalog = createModelCatalog();
// The runs of turns the other assistant's @mention started, and their tool calls.
const handovers = createHandovers();
// What each app turn's runs changed, for its reply's did list.
const did = createDid();
// The sign-ins the box's env file gave this gateway, read once as the process starts and
// before any sign-in from a phone goes into the environment (connect.js).
const BOX_ENV = Object.fromEntries(
  [...CONNECTORS.flatMap((connector) => [connector.envSignIn, connector.envUsername]).filter(Boolean), ...MICROSOFT_ENV]
    .map((name) => [name, process.env[name]]),
);
// The plugin's own settings and spend, opened on first use and kept until the plugin's
// service stops. They serve Telegram's turns as well as the app's, channel or not.
let own = null;

function ownSettings() {
  if (own) return own;
  const config = () => runtime.config.current();
  const directory = path.join(runtime.state.resolveStateDir(process.env), PLUGIN_ID);
  const store = openSettingsStore(path.join(directory, "settings.sqlite"));
  const household = () => config()?.channels?.household;
  // Connector sign-ins from the owner's phone: see connect.js and google-connect.js.
  const connect = createConnect({
    connectors: () => connectorsFor(household()?.assistant?.id),
    store,
    phoneKeys: () => live.room.refreshPhoneKeys(),
    google: () => createGoogleConnector({
      directory: path.join(directory, "connectors"),
      clientId: household()?.googleClientId,
      keyringPassword: process.env.GOG_KEYRING_PASSWORD,
    }),
    microsoft: () => createMicrosoftConnector({
      directory: path.join(directory, "connectors"),
      clientId: BOX_ENV.MS_GRAPH_CLIENT_ID,
      tenantId: BOX_ENV.MS_GRAPH_TENANT_ID,
      keyringPassword: process.env.GOG_KEYRING_PASSWORD,
    }),
    notion: () => createNotionConnector({
      directory: path.join(directory, "connectors"),
      keyringPassword: process.env.GOG_KEYRING_PASSWORD,
      clientId: process.env.NOTION_OAUTH_CLIENT_ID,
      clientSecret: process.env.NOTION_OAUTH_CLIENT_SECRET,
      redirectUri: process.env.NOTION_OAUTH_REDIRECT_URI,
    }),
    secretsDirectory: directory,
    keyringPassword: process.env.GOG_KEYRING_PASSWORD,
    gogAccounts: () => listGogAccounts(),
    removeGogAccount: (email) => removeGogAccount(email),
    boxEnv: BOX_ENV,
    env: process.env,
  });
  const brief = createBrief({ store, changed: (written) => emit("brief", { brief: written }) });
  own = {
    store,
    connect,
    settings: createSettings({
      config,
      mutateConfig: (write) => runtime.config.mutateConfigFile({ afterWrite: { mode: "auto" }, mutate: write }),
      store,
      phoneKeys: () => live.room.refreshPhoneKeys(),
      catalog,
      changed: () => sharePage(),
      readBack: (connector) => connect.readBack(connector),
    }),
    spend: createSpend({
      store,
      catalog,
      apiKey: () => process.env.OPENROUTER_API_KEY,
      speechModel: () => config()?.tts?.providers?.openrouter?.model ?? "",
      assistantName: () => nameOf(config()),
      mediaSpent: async (firstDay) => (await mediaSpentSince(path.join(runtime.state.resolveStateDir(process.env), "household-pictures", "ledger.json"), firstDay)) + (live?.videos.spentSince(firstDay) ?? 0) + (live?.images.spentSince(firstDay) ?? 0),
      reportFile: path.join(directory, "spend.json"),
    }),
    // Written from Telegram and a scheduled run as well as the app, channel or not.
    brief,
    today: createToday({ store, brief, changed: (today) => emit("today", { today }) }),
  };
  return own;
}

// This assistant's page, relayed to the other gateway when its voice or model has a name
// to show there. A rename restarts the channel, which shares it again as it starts.
function sharePage() {
  void (async () => {
    const page = assistantPage(runtime.config.current(), await catalog.models());
    if (page.voiceName && page.modelName) live?.room.publishProfile(page);
  })().catch((error) => logger?.warn?.(`${PLUGIN_ID}: this assistant's page was not shared: ${error?.message ?? error}`));
}

const phoneOf = (client) => client?.connect?.device?.id;

function emit(name, payload) {
  try {
    events?.emit(name, payload, { scope: "operator.read" });
  } catch {
    // An emitter revoked mid-stop has nobody left to tell.
  }
}

function conversationFor(target, owner) {
  if (target === FAMILY) return FAMILY;
  if (target === owner) return "direct";
  return null;
}

async function writeAtomically(file, text) {
  await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${process.pid}.tmp`;
  await writeFile(temporary, text, { mode: 0o600 });
  await rename(temporary, file);
}

const KIND_OF_FACT = { voice: "audio", photo: "image", video: "video", file: "document" };

// A message's words, with a shared map's place after them the way OpenClaw writes any
// channel's shared location. A live map's later moves are the phones' to show, not the
// assistant's to hear.
function withPlace(message) {
  if (!message.location) return message.text;
  const { latitudeE6, longitudeE6, accuracy, until } = message.location;
  const isLive = until !== null;
  const place = formatLocationText({
    latitude: latitudeE6 / 1_000_000,
    longitude: longitudeE6 / 1_000_000,
    accuracy,
    source: isLive ? "live" : "pin",
    isLive,
  });
  return [message.text.trim(), place].filter(Boolean).join("\n");
}

// A reply's media, read the way OpenClaw reads it for any channel: local files only
// under the agent's own media roots, remote ones through its guarded fetch.
async function loadReplyFiles(cfg, payload) {
  const urls = [payload.mediaUrl, ...(payload.mediaUrls ?? [])].filter((url) => typeof url === "string" && url);
  const files = [];
  for (const url of [...new Set(urls)]) {
    const loaded = await loadOutboundMediaFromUrl(url, {
      maxBytes: MAX_MEDIA_BYTES,
      mediaLocalRoots: getAgentScopedMediaLocalRoots(cfg, AGENT),
    });
    const mime = String(loaded.contentType ?? "application/octet-stream").split(";")[0].trim();
    files.push({
      bytes: loaded.buffer,
      mime,
      kind: payload.audioAsVoice && mime.startsWith("audio/") ? "voice" : undefined,
      name: loaded.fileName,
    });
  }
  return files;
}

function startRoom(ctx) {
  const { config } = ctx.account;
  const cfg = () => runtime?.config?.current?.() ?? ctx.cfg;
  const stateDir = runtime.state.resolveStateDir(process.env);
  const directory = path.join(stateDir, PLUGIN_ID);
  const log = ctx.log ?? { info() {}, warn() {}, error() {} };
  const store = openRoomStore(path.join(directory, "room.sqlite"));
  const media = createMediaStore(directory);
  const videos = createVideoSummaries({ directory, media, log });
  const images = createImageUnderstanding({ directory, media, config: cfg, log });
  const owner = { id: config.owner.id, name: config.owner.name ?? config.owner.id, keys: config.owner.deviceKeys ?? [] };
  const peerPerson = { id: config.peer.person.id, name: config.peer.person.name ?? config.peer.person.id, keys: config.peer.person.deviceKeys ?? [] };
  const assistant = { id: config.assistant.id, name: config.assistant.name ?? config.assistant.id, emoji: config.assistant.emoji };
  const peerAssistant = { id: config.peer.assistant.id, name: config.peer.assistant.name ?? config.peer.assistant.id };
  const configuredPeerAssistantName = peerAssistant.name;

  const routeFor = (conversation) =>
    resolveChannelInboundRouteEnvelope({
      cfg: cfg(),
      channel: CHANNEL,
      accountId: ACCOUNT,
      peer: conversation === FAMILY || conversation === PAIR ? { kind: "group", id: conversation } : { kind: "direct", id: owner.id },
    }).route;

  const apns = process.env.HOUSEHOLD_APNS_KEY_ID && process.env.HOUSEHOLD_APNS_TEAM_ID && process.env.HOUSEHOLD_APNS_PRIVATE_KEY
    ? createPush({
        keyId: process.env.HOUSEHOLD_APNS_KEY_ID,
        teamId: process.env.HOUSEHOLD_APNS_TEAM_ID,
        privateKey: process.env.HOUSEHOLD_APNS_PRIVATE_KEY.replaceAll("\\n", "\n"),
        topic: config.push?.topic ?? "com.siqstack.stewardai",
        transport: createHttp2Transport(),
      })
    : null;
  if (!apns) log.info(`${PLUGIN_ID}: no Apple push key in the environment, so phones are not notified`);
  const push = apns ?? { notify: async () => [] };

  // A voice note's file is named by its hash alone, so its mime is what tells the speech
  // model how to read it.
  const transcribe = async (message, voice) => (await runtime.mediaUnderstanding.transcribeAudioFile({
    filePath: media.path(voice.id),
    cfg: cfg(),
    mime: voice.mime,
    scopeContext: {
      sessionKey: routeFor(message.conversation).sessionKey,
      channel: CHANNEL,
      chatType: message.conversation === FAMILY ? "group" : "direct",
    },
  }))?.text;

  // Whether a family-room message is for this assistant: it names it, by name or emoji
  // as OpenClaw derives them from the agent's identity, or it replies to one of its
  // messages. A voice note is heard first unless its typed words already name it, and a
  // spoken name counts as a typed one does, in any spelling speech-to-text gives it.
  async function isAddressed(message, { isReplyToAssistant }) {
    const mentionRegexes = buildMentionRegexes(cfg(), AGENT, { provider: CHANNEL, conversationId: FAMILY });
    const isSpokenTo = (words) => matchesMentionWithExplicit({ text: words, mentionRegexes }) ||
      [assistant.name, cfg()?.agents?.entries?.main?.identity?.name]
        .some((name) => typeof name === "string" && name && isNameSpoken(words, name));
    const wasMentioned = matchesMentionWithExplicit({ text: message.text, mentionRegexes }) ||
      isSpokenTo(await hearing.words(message));
    const decision = resolveInboundMentionDecision({
      facts: {
        canDetectMention: true,
        wasMentioned,
        hasAnyMention: false,
        implicitMentionKinds: implicitMentionKindWhen("reply_to_bot", isReplyToAssistant),
      },
      policy: { isGroup: true, requireMention: true, allowTextCommands: false, hasControlCommand: false, commandAuthorized: false },
    });
    return !decision.shouldSkip;
  }

  // Whether a family message asks the other assistant too: its @mention, its name typed, or
  // its name heard in a voice note, the way this gateway hears its own (isAddressed).
  async function isPeerAddressed(message) {
    const name = configuredPeerAssistantName;
    if (isMentioned(message.text, name) || isNameSpoken(message.text, name)) return true;
    const heard = await hearing.words(message);
    return Boolean(heard) && isNameSpoken(heard, name);
  }

  // The family room's recent messages before this one, as OpenClaw's group history.
  function historyBefore(message) {
    const names = Object.fromEntries(room.participants().map((who) => [who.id, who.name]));
    return store
      .history(FAMILY, { before: message.rev, limit: ROOM_HISTORY })
      .messages.map((earlier) => {
        const heard = store.transcript(earlier.id);
        return {
          sender: earlier.author === assistant.id ? `${names[earlier.author]} (you)` : names[earlier.author] ?? earlier.author,
          body: withPlace(earlier).trim() ||
            earlier.media.map((item) => (item.kind === "voice" && heard !== null
              ? `(voice note) ${heard}`
              : `<media:${KIND_OF_FACT[item.kind] ?? "document"}>`)).join(" "),
          timestamp: earlier.at,
          messageId: earlier.id,
        };
      });
  }

  // What a family-room turn is told of whose it is: the owner's own, with everything their
  // thread has, before the rest of the family; or anyone else's, without the owner's
  // private things, which that turn's tools cannot reach either (family-tools.js).
  // The other assistant's name is the configured one, never the name its gateway relays.
  //
  // A question both assistants were asked gets one answer, for both of them (room.js claims).
  function familyTurnInstruction(author, claim) {
    const privateThings = `${owner.name}'s private things, such as money, mail, calendar details and private notes`;
    const forBoth = claim === "claimed"
      ? ` They asked ${configuredPeerAssistantName} too, who leaves it to you: give the one answer for both of you, from the household note and what you know, and do not say you will check with ${configuredPeerAssistantName}.`
      : claim === "tookOver"
        ? ` They asked ${configuredPeerAssistantName} first, who has not answered, so give the one answer for both of you, from the household note and what you know.`
        : "";
    if (author.id === owner.id) {
      return `${owner.name}, your own person, wrote this in the family room, which ${peerPerson.name} and ${configuredPeerAssistantName} read too. ` +
        `Answer ${owner.name} as you would in their own thread, with the same tools and memory, and share ${privateThings} only as far as their question asks.${forBoth}`;
    }
    return `${author.name} wrote this in the family room. Answer them for the family; ${privateThings} are not theirs to hear from you.${forBoth}`;
  }

  // A turn names its message's author as the sender, which OpenClaw hands to tools as the
  // trusted `requesterSenderId`. In the owner's own thread, and the family room, that author
  // is a person only because one of that person's phones signed the message (room.js), so
  // PocketPiggies takes the owner as that sender in either as proof the owner asked. A turn the other assistant's
  // @mention handed over names that assistant, as a bot, and its replies carry the mark
  // that keeps them from handing anything back. A turn said on a voice call asks, for that
  // turn alone, for an answer made to be heard (call-log.js).
  //
  // The owner's own family-room turn runs in the owner's own session of the room
  // (turn.js ownersFamilySession), which no other sender's turn reads, so what their tools
  // return stays out of everyone else's turns. Everyone else's runs in the room's own.
  //
  // A voice note reaches the turn as its words, the way OpenClaw's own channels hand over
  // a note they heard first, and is marked heard so OpenClaw never transcribes it again.
  //
  // Photos and image files are read by the selected Vision model after admission.
  // Only its reading reaches the chat model, preventing native vision from bypassing
  // the selection. Videos use their bounded digest; ordinary documents stay unchanged.
  async function runTurn({ conversation, message, author, handedOver = false, isCall = false, claim }) {
    const channelRuntime = ctx.channelRuntime ?? runtime.channel;
    const isGroup = conversation === FAMILY;
    const isOwner = author.id === owner.id;
    const roomRoute = routeFor(conversation);
    const route = isGroup && isOwner ? { ...roomRoute, sessionKey: ownersFamilySession(owner.id) } : roomRoute;
    const target = `${CHANNEL}:${isGroup ? FAMILY : owner.id}`;
    // Taken up: the person's phone shows their message as Read, as the assistant starts
    // typing, before a voice note is heard.
    room.assistantRead({ conversation, messageId: message.id });
    room.setTyping({ conversation, active: true });
    const changes = did.turn();
    try {
      // The other assistant's spoken reply carries its own words.
      const words = author.isAssistant ? "" : await hearing.words(message);
      const voice = message.media.find((item) => item.kind === "voice");
      const video = author.isAssistant ? "" : await videos.describe(videoSource(message, store));
      const image = author.isAssistant ? "" : await images.describe(imageSource(message, store), [message.text, words].filter(Boolean).join("\n"));
      const body = [withPlace(message).trim(), words ? formatAudioTranscriptForAgent(words) : "", video, image].filter(Boolean).join("\n");
      const ctxPayload = await channelRuntime.inbound.buildContext({
        channel: CHANNEL,
        accountId: ACCOUNT,
        messageId: message.id,
        messageIdFull: message.id,
        timestamp: message.at,
        from: `${CHANNEL}:${author.id}`,
        sender: { id: author.id, name: author.name, ...(author.isAssistant ? { isBot: true } : {}) },
        conversation: isGroup
          ? { kind: "group", id: FAMILY, label: "The Fam" }
          : { kind: "direct", id: owner.id, label: owner.name },
        route: {
          agentId: route.agentId,
          dmScope: route.dmScope,
          accountId: ACCOUNT,
          routeSessionKey: route.sessionKey,
          dispatchSessionKey: route.sessionKey,
        },
        reply: { to: target, originatingTo: target, ...(message.replyTo ? { replyToId: message.replyTo } : {}) },
        message: {
          inboundEventKind: "user_request",
          body,
          rawBody: body,
          bodyForAgent: body,
          commandBody: message.text,
          ...(isGroup ? { inboundHistory: historyBefore(message) } : {}),
        },
        ...(isCall ? { supplemental: { groupSystemPrompt: CALL_TURN_INSTRUCTION } } : {}),
        ...(isGroup ? { supplemental: { groupSystemPrompt: familyTurnInstruction(author, claim) } } : {}),
        media: toInboundMediaFacts(message.media.filter((item) => item.kind !== "video" && !isImageAttachment(item)).map((item) => ({
          path: media.path(item.id),
          contentType: item.mime,
          kind: KIND_OF_FACT[item.kind],
          fileName: item.name,
          durationMs: item.durationMs,
          width: item.width,
          height: item.height,
          messageId: message.id,
          ...(item === voice && words ? { transcribed: true } : {}),
        }))),
        access: {
          commands: { authorized: isOwner },
          ...(isGroup ? { mentions: { canDetectMention: true, wasMentioned: true, requireMention: true, effectiveWasMentioned: true } } : {}),
        },
        ...(isOwner ? {} : { extra: { CommandInterpretationSuppressed: true } }),
      });

      // The turn names each run OpenClaw starts for it, so what its runs change goes on its
      // reply (did.js), and a handed-over turn's tools' posts are marked as its own
      // (handovers.js).
      const dispatchTurn = (nameHandedOverRun) => channelRuntime.inbound.dispatch({
        cfg: cfg(),
        channel: CHANNEL,
        accountId: ACCOUNT,
        route: { agentId: route.agentId, dmScope: route.dmScope, sessionKey: route.sessionKey },
        ctxPayload,
        messageId: message.id,
        replyOptions: {
          disableBlockStreaming: true,
          sourceReplyDeliveryMode: "automatic",
          onAgentRunStart: (runId) => {
            changes.name(runId);
            nameHandedOverRun?.(runId);
          },
        },
        replyPipeline: {
          typing: {
            start: async () => room.setTyping({ conversation, active: true }),
            stop: async () => room.setTyping({ conversation, active: false }),
            onStartError: () => {},
            keepaliveIntervalMs: TYPING_KEEPALIVE_MS,
          },
        },
        delivery: {
          deliver: async (payload, info) => {
            if (info.kind !== "final") return;
            if (payload.isReasoning || payload.isCommentary || payload.isStatusNotice || payload.isCompactionNotice) return;
            const files = await loadReplyFiles(cfg(), payload);
            const entry = await room.reply({ conversation, text: payload.text ?? "", files, handedOver, did: changes.take() });
            return entry
              ? {
                  messageIds: [entry.id],
                  receipt: createMessageReceiptFromOutboundResults({ results: [{ channel: CHANNEL, messageId: entry.id }], kind: files.length ? "media" : "text" }),
                }
              : { visibleReplySent: false };
          },
          onError: (error) => log.warn(`${PLUGIN_ID}: a reply in the ${conversation} conversation was not kept: ${error?.message ?? error}`),
        },
      });
      const result = handedOver ? await handovers.during(dispatchTurn) : await dispatchTurn();
      if (result?.admission?.kind !== "dispatch") {
        log.info(`${PLUGIN_ID}: a ${conversation} turn was not started: ${result?.admission?.kind ?? "unknown"}`);
      }
    } finally {
      changes.end();
      room.setTyping({ conversation, active: false });
    }
  }

  // What a handoff's turn is told: who handed it over, who reads the answer, and that a
  // person's own things are not the other assistant's to hear.
  function handoffInstruction() {
    const people = `${owner.name} and ${peerPerson.name}`;
    return `${configuredPeerAssistantName} handed you this through your direct line, which ${people} can read in the app. ` +
      `Your reply is kept as your answer to it, and ${configuredPeerAssistantName} reads it in their next turn; nothing here is posted in the family room. ` +
      `Answer from what the family shares, such as the household note. ${owner.name}'s private things, such as money, mail, calendar details and private notes, are not ${configuredPeerAssistantName}'s to hear. ` +
      `When it needs ${owner.name}, say so in a line: it stays in the household note as yours to do, and you mark it done there in a chat with ${owner.name}.`;
  }

  // One turn for the other assistant's handoff, in the direct line's own session, sent by
  // that assistant as a bot. Its final reply becomes the handoff's answer (notes.js reply):
  // nothing reaches the room or a phone, and a tool's post finds no conversation called the
  // direct line (targetConversation). The turn has no household tool (turn.js), so it cannot
  // hand anything back.
  async function runHandoff(line) {
    const channelRuntime = ctx.channelRuntime ?? runtime.channel;
    const route = routeFor(PAIR);
    const target = `${CHANNEL}:${PAIR}`;
    const body = [line.text, line.due ? `(due ${line.due})` : ""].filter(Boolean).join(" ");
    const ctxPayload = await channelRuntime.inbound.buildContext({
      channel: CHANNEL,
      accountId: ACCOUNT,
      messageId: line.id,
      messageIdFull: line.id,
      timestamp: line.at,
      from: `${CHANNEL}:${peerAssistant.id}`,
      sender: { id: peerAssistant.id, name: configuredPeerAssistantName, isBot: true },
      conversation: { kind: "group", id: PAIR, label: `${assistant.name} and ${configuredPeerAssistantName}` },
      route: {
        agentId: route.agentId,
        dmScope: route.dmScope,
        accountId: ACCOUNT,
        routeSessionKey: route.sessionKey,
        dispatchSessionKey: route.sessionKey,
      },
      reply: { to: target, originatingTo: target },
      message: { inboundEventKind: "user_request", body, rawBody: body, bodyForAgent: body, commandBody: body },
      supplemental: { groupSystemPrompt: handoffInstruction() },
      access: {
        commands: { authorized: false },
        mentions: { canDetectMention: true, wasMentioned: true, requireMention: true, effectiveWasMentioned: true },
      },
      extra: { CommandInterpretationSuppressed: true },
    });
    const result = await channelRuntime.inbound.dispatch({
      cfg: cfg(),
      channel: CHANNEL,
      accountId: ACCOUNT,
      route: { agentId: route.agentId, dmScope: route.dmScope, sessionKey: route.sessionKey },
      ctxPayload,
      messageId: line.id,
      replyOptions: { disableBlockStreaming: true, sourceReplyDeliveryMode: "automatic" },
      delivery: {
        deliver: async (payload, info) => {
          if (info.kind !== "final") return;
          if (payload.isReasoning || payload.isCommentary || payload.isStatusNotice || payload.isCompactionNotice) return;
          const answered = notes.reply(line.id, payload.text ?? "");
          return answered
            ? {
                messageIds: [line.id],
                receipt: createMessageReceiptFromOutboundResults({ results: [{ channel: CHANNEL, messageId: line.id }], kind: "text" }),
              }
            : { visibleReplySent: false };
        },
        onError: (error) => log.warn(`${PLUGIN_ID}: a handoff's answer was not kept: ${error?.message ?? error}`),
      },
    });
    if (result?.admission?.kind !== "dispatch") {
      log.info(`${PLUGIN_ID}: a handoff turn was not started: ${result?.admission?.kind ?? "unknown"}`);
    }
  }

  // The other assistant's handoffs that just arrived: each marked seen at once, which the
  // other side reads as acknowledged, and a fresh one answered in a turn of its own.
  function considerHandoffs(handed = []) {
    for (const { id, at } of handed) {
      if (!notes.seen(id)) continue;
      if (Date.now() - at >= HANDOFF_WITHIN_MS) continue;
      void runInChannel(() => runHandoff({ ...notes.line(id), at })).catch((error) => {
        log.warn(`${PLUGIN_ID}: a handoff turn failed to start: ${error?.message ?? error}`);
      });
    }
  }

  let writing = Promise.resolve();
  const sessionKeys = { family: routeFor(FAMILY).sessionKey, direct: routeFor("direct").sessionKey };
  // Taken here, while the channel starts, so a phone's turn runs as the channel's, and
  // an approval the owner answers reaches OpenClaw as this channel's.
  const runInChannel = AsyncLocalStorage.snapshot();
  // The bounds of questions stood down from, cleared when the channel stops, so a bound set
  // before a restart in the same process never checks the closed note: the started channel
  // resumes it from the note's file instead.
  const bounds = new Set();
  const schedule = (task, milliseconds) => {
    const timer = setTimeout(() => {
      bounds.delete(timer);
      task();
    }, milliseconds);
    timer.unref();
    bounds.add(timer);
  };
  const stopBounds = () => {
    for (const timer of bounds) clearTimeout(timer);
    bounds.clear();
  };
  const room = createRoom({
    identity: { owner, assistant, peer: { person: peerPerson, assistant: peerAssistant } },
    sessionKeys,
    schedule,
    ownersFamilySession: ownersFamilySession(owner.id),
    // When the two assistants' line last moved, for the family room's quiet marker.
    pairLastAt: () => notes.lastAt(),
    // Who answers a question both assistants were asked.
    isPeerAddressed,
    claims: {
      claim: (message, options) => notes.claim(message, options),
      took: (message) => notes.took(message),
      claimOf: (message) => notes.claimOf(message),
      standDown: (message, bound) => notes.standDown(message, bound),
      standingDown: () => notes.standingDown(),
      settled: (message) => notes.settled(message),
    },
    phoneKeys: async () => phoneKeysFrom(await listDevicePairing()),
    notificationChoices: (phone) => ownSettings().store.notifications(phone),
    // The agent's own name, which a rename from Settings or the box may leave apart from
    // the family room's until the channel restarts.
    assistantNames: () => [cfg()?.agents?.entries?.main?.identity?.name].filter((name) => typeof name === "string" && name),
    runInChannel,
    // Where a person's reaction to one of this assistant's messages waits for its next turn.
    enqueue: (injection) => workflow.enqueueNextTurnInjection(injection),
    store,
    media,
    emit,
    // One write at a time, so an older snapshot can never land after a newer one.
    writeOutbox: (outbox) => {
      const text = JSON.stringify({ persona: assistant.id, ...outbox, ...appleSignIn.outbox(), ...cart.outbox(), ...notes.outbox() });
      writing = writing
        .then(() => writeAtomically(path.join(directory, "outbox.json"), text))
        .catch((error) => log.warn(`${PLUGIN_ID}: the outbox could not be written: ${error?.message ?? error}`));
    },
    push,
    dispatch: runTurn,
    isAddressed,
    log,
  });
  const hearing = createHearing({ store, transcribe, assistantId: assistant.id, heard: (entry) => room.heard(entry), log });

  // What /app hands a phone: where to reach this gateway, and whose phone it becomes.
  const pairing = { url: isPhoneUrl(config.phoneUrl) ? config.phoneUrl : null, person: owner.id, assistant: assistant.name };
  const nonces = createNonces();
  const appleSignIn = createAppleSignIn({
    owner,
    peer: peerPerson,
    approver: config.approver,
    store,
    nonces,
    keys: appleKeys,
    issueCode: () => setupCode({ pairing }),
    approverKeys: async () => {
      if (config.approver === owner.id) return room.refreshPhoneKeys();
      return config.approver === peerPerson.id ? room.peerKeys() : [];
    },
    isSignedBy: isTextSignedBy,
    changed: () => room.publishOutbox(),
  });

  // The household cart both assistants add to. Its steps cross in the outbox, beside the
  // family room's entries, and the other gateway's come back through the inbox.
  const cart = createCart({
    file: path.join(directory, "cart.sqlite"),
    assistant,
    peerAssistant,
    people: [owner, peerPerson],
    changed: () => room.publishOutbox(),
  });

  // The household note both assistants write and every app turn starts with (notes.js). Its
  // steps cross in the outbox beside the cart's, and the other gateway's come back the same way.
  // Every step is also an event of the two assistants' line, which both people's phones show.
  const notes = createNotes({
    file: path.join(directory, "notes.sqlite"),
    assistant,
    peerAssistant: { id: peerAssistant.id, name: configuredPeerAssistantName },
    people: [owner, peerPerson],
    changed: () => {
      room.publishOutbox();
      emit(PAIR, { lastAt: notes.lastAt() });
    },
  });

  // The other gateway's half of the family room, as relay-in.mjs leaves it.
  const inbox = path.join(directory, "inbox");
  let draining = Promise.resolve();
  const drain = () => {
    draining = draining.then(async () => {
      let names;
      try {
        names = (await readdir(inbox)).filter((name) => name.endsWith(".json") && !name.startsWith(".")).sort();
      } catch {
        return;
      }
      for (const name of names) {
        const file = path.join(inbox, name);
        try {
          const { size } = await stat(file);
          if (size > MAX_INBOX_FILE) throw new Error("over its size bound");
          const { from, batch } = JSON.parse(await readFile(file, "utf8"));
          if (from !== peerAssistant.id) throw new Error("not from the other gateway");
          const { accepted, refused } = await room.acceptPeer(batch);
          if (refused) log.warn(`${PLUGIN_ID}: kept ${accepted} and refused ${refused} entries from the other gateway`);
          await appleSignIn.acceptPeer(batch);
          const steps = cart.acceptPeer(batch);
          if (steps.refused) log.warn(`${PLUGIN_ID}: refused ${steps.refused} cart steps from the other gateway`);
          const noted = notes.acceptPeer(batch);
          if (noted.refused) log.warn(`${PLUGIN_ID}: refused ${noted.refused} household note steps from the other gateway`);
          considerHandoffs(noted.handed);
        } catch (error) {
          log.warn(`${PLUGIN_ID}: an inbox file was refused: ${error?.message ?? error}`);
        } finally {
          await rm(file, { force: true });
        }
      }
    });
    return draining;
  };

  void room.refreshPhoneKeys().catch((error) => log.warn(`${PLUGIN_ID}: the paired phones could not be read: ${error?.message ?? error}`));

  const tick = createCardTick({
    store,
    ownerName: owner.name,
    assistantIds: [assistant.id, peerAssistant.id],
    sessionKeys,
    enqueue: (injection) => workflow.enqueueNextTurnInjection(injection),
  });

  // Whoever checked out tapping Ordered on the cart's card, answered at once with the cart
  // and the order, as this assistant's messages.
  const cartOrdered = createCartOrdered({
    store,
    cart,
    assistantIds: [assistant.id, peerAssistant.id],
    reply: (message) => room.reply(message),
  });

  // The owner's own Amazon order mail, read by the plugin on a timer from the owner's Gmail
  // when the channel names it, with no model (order-mail.js). Off when it does not.
  const orderMail = config.orderMail && createOrderMail({
    source: gmailSource({ account: config.orderMail.account, run: runMail }),
    owner: config.orderMail.account,
    cart,
    post: (message) => room.reply(message),
    seenFile: path.join(directory, "order-mail-seen.json"),
    log,
  });

  // Where the owner is, from the same phones that sign the owner's messages. Never in the
  // store or the outbox, so the relay carries none of it to the other gateway.
  const location = createLocation({ phoneKeys: () => room.refreshPhoneKeys() });

  // A step waiting for the owner's yes, shown in the owner's own thread. The answer goes
  // to OpenClaw as the owner's, through this channel, once the phone's signature is checked.
  const approvals = createApprovals({
    store,
    assistant,
    // The owner's own session of the family room asks too (approval-asks.js).
    sessionKeys: { ...sessionKeys, ownersFamily: ownersFamilySession(owner.id) },
    announce: (entry) => room.announce(entry),
    ownerKeys: () => room.refreshPhoneKeys(),
    isSignedBy: isTextSignedBy,
    resolve: ({ approvalId, approvalKind, decision }) =>
      runInChannel(() => resolveApprovalOverGateway({
        cfg: cfg(),
        approvalId,
        approvalKind,
        decision,
        channel: CHANNEL,
        accountId: ACCOUNT,
        senderId: owner.id,
      })),
  });

  return {
    room, media, store, inbox, drain, owner, peerPerson, pairing, nonces, appleSignIn, tick, location, approvals, cart, cartOrdered,
    notes, videos, images, stopBounds,
    orderMail,
    log,
    peerAssistantName: configuredPeerAssistantName,
    ownerSession: sessionKeys.direct,
    familySession: sessionKeys.family,
    ownersFamilySession: ownersFamilySession(owner.id),
    pairSession: routeFor(PAIR).sessionKey,
  };
}

const householdMessageAdapter = defineChannelMessageAdapter({
  id: CHANNEL,
  durableFinal: { capabilities: { text: true, media: true } },
  send: {
    text: async (ctx) => sendText(ctx),
    media: async (ctx) => sendMedia(ctx),
  },
});

function targetConversation(to) {
  const target = normalizeTarget(to);
  const conversation = live && target ? conversationFor(target, live.owner.id) : null;
  if (!conversation) throw new Error(`household cannot send to ${to}: it reaches the family room and its owner only`);
  return conversation;
}

// What the assistant posts on its own, a tool's post included, marked when a tool of a
// handed-over turn posts it. A reminder the job mirror copies here comes marked time
// sensitive (household-job-mirror), so its push gets through a Focus.
async function sendText({ to, text, isTimeSensitive }) {
  const conversation = targetConversation(to);
  const entry = await live.room.reply({
    conversation,
    text,
    handedOver: handovers.marks(conversation),
    isTimeSensitive: isTimeSensitive === true,
  });
  if (!entry) throw new Error("nothing to send");
  return {
    messageId: entry.id,
    receipt: createMessageReceiptFromOutboundResults({ results: [{ channel: CHANNEL, messageId: entry.id }], kind: "text" }),
  };
}

async function sendMedia({ to, text, mediaUrl, mediaAccess, mediaLocalRoots, mediaReadFile, audioAsVoice }) {
  const conversation = targetConversation(to);
  const loaded = await loadOutboundMediaFromUrl(mediaUrl, { maxBytes: MAX_MEDIA_BYTES, mediaAccess, mediaLocalRoots, mediaReadFile });
  const mime = String(loaded.contentType ?? "application/octet-stream").split(";")[0].trim();
  const entry = await live.room.reply({
    conversation,
    text: text ?? "",
    files: [{ bytes: loaded.buffer, mime, kind: audioAsVoice && mime.startsWith("audio/") ? "voice" : undefined, name: loaded.fileName }],
    handedOver: handovers.marks(conversation),
  });
  return {
    messageId: entry.id,
    receipt: createMessageReceiptFromOutboundResults({ results: [{ channel: CHANNEL, messageId: entry.id }], kind: "media" }),
  };
}

export const householdChannel = createChatChannelPlugin({
  base: {
    id: CHANNEL,
    meta: {
      id: CHANNEL,
      label: "Household app",
      selectionLabel: "Household app (Steward AI)",
      docsPath: "/channels/household",
      blurb: "The family's own app: the family room and each person's thread with their assistant.",
    },
    capabilities: { chatTypes: ["direct", "group"], media: true, reactions: true },
    reload: { configPrefixes: ["channels.household"] },
    configSchema: buildJsonChannelConfigSchema(CHANNEL_SCHEMA),
    config: {
      listAccountIds: (cfg) => (cfg?.channels?.household ? [ACCOUNT] : []),
      resolveAccount: (cfg) => resolveAccount(cfg),
      defaultAccountId: () => ACCOUNT,
      isConfigured: (account) => account.configured,
      isEnabled: (account) => account.enabled,
      resolveAllowFrom: ({ cfg }) => {
        const { config } = resolveAccount(cfg);
        return [config.owner?.id, config.peer?.person?.id].filter(Boolean);
      },
    },
    groups: { resolveToolPolicy: familyToolPolicy },
    approvalCapability: ownerApprovalCapability({
      ownerOf: (cfg) => {
        const account = resolveAccount(cfg);
        return account.configured ? account.config.owner.id : undefined;
      },
      nativeRuntime: createChannelApprovalNativeRuntimeAdapter(approvalNativeRuntime),
    }),
    messaging: {
      normalizeTarget,
      inferTargetChatType: ({ to }) => (normalizeTarget(to) === FAMILY ? "group" : "direct"),
      targetResolver: {
        looksLikeId: (raw) => normalizeTarget(raw) !== undefined,
        hint: "family, or the owner's id",
      },
      resolveOutboundSessionRoute: ({ cfg, agentId, accountId, target }) => {
        const to = normalizeTarget(target);
        if (!to) return null;
        const isGroup = to === FAMILY;
        return buildChannelOutboundSessionRoute({
          cfg,
          agentId,
          channel: CHANNEL,
          accountId,
          recipientSessionExact: true,
          peer: { kind: isGroup ? "group" : "direct", id: to },
          chatType: isGroup ? "group" : "direct",
          from: `${CHANNEL}:${accountId ?? ACCOUNT}`,
          to: `${CHANNEL}:${to}`,
        });
      },
    },
    gateway: {
      startAccount: async (ctx) => {
        if (!ctx.account.configured) {
          throw new Error("channels.household names no owner, assistant and other gateway yet");
        }
        ctx.setStatus({ accountId: ctx.accountId, running: true, lifecycle: "starting", configured: true, enabled: ctx.account.enabled });
        const started = startRoom(ctx);
        await mkdir(started.inbox, { recursive: true, mode: 0o700 });
        live = started;
        sharePage();
        void mirrorAutomations();
        // OpenClaw starts this channel's native approvals once it finds them here, and
        // forgets them when the channel stops.
        registerChannelRuntimeContext({
          channelRuntime: ctx.channelRuntime,
          channelId: CHANNEL,
          accountId: ctx.accountId,
          capability: CHANNEL_APPROVAL_NATIVE_RUNTIME_CONTEXT_CAPABILITY,
          context: { approvals: started.approvals },
          abortSignal: ctx.abortSignal,
        });
        const watcher = watch(started.inbox, () => void started.drain());
        const sweep = setInterval(() => void started.drain(), INBOX_SCAN_MS);
        // One read of the order mail at a time.
        let reading = null;
        const readMail = () => {
          reading ??= started.orderMail.poll({ signal: ctx.abortSignal })
            .catch((error) => ctx.log?.warn?.(`${PLUGIN_ID}: order mail stopped short (${error?.name ?? "error"})`))
            .finally(() => {
              reading = null;
            });
        };
        const firstMail = started.orderMail ? setTimeout(readMail, ORDER_MAIL_FIRST_MS) : null;
        const mailTimer = started.orderMail ? setInterval(readMail, ORDER_MAIL_MS) : null;
        // Calls past their thirty days, dropped now and every six hours. A store that cannot
        // drop them now keeps them until the next time, and the gateway runs on.
        const dropOldCalls = () => {
          try {
            started.room.dropOldCalls();
          } catch (error) {
            ctx.log?.warn?.(`${PLUGIN_ID}: old calls were not dropped: ${error?.message ?? error}`);
          }
        };
        dropOldCalls();
        const callsTimer = setInterval(dropOldCalls, OLD_CALLS_MS);
        callsTimer.unref();
        // This assistant's family reminders that came due (notes.js), each moved on before its
        // words are posted, so a slow post can never post it twice. A reminder from while the
        // gateway was down is moved on unposted. A reminder's post is marked like a handed-over
        // turn's, so its words, whoever they name, start no turn on the other side (room.js).
        const remind = () => {
          try {
            for (const due of started.notes.dueReminders()) {
              started.notes.fired(due.id);
              if (due.isLate) continue;
              void started.room.reply({ conversation: FAMILY, text: `Reminder: ${due.text}`, handedOver: true, isTimeSensitive: true })
                .catch((error) => ctx.log?.warn?.(`${PLUGIN_ID}: a family reminder was not posted: ${error?.message ?? error}`));
            }
          } catch (error) {
            ctx.log?.warn?.(`${PLUGIN_ID}: family reminders were not checked: ${error?.message ?? error}`);
          }
        };
        remind();
        // A question this assistant stood down from just before a restart is still checked once.
        try {
          started.room.resumeStandDowns();
        } catch (error) {
          ctx.log?.warn?.(`${PLUGIN_ID}: questions stood down from were not resumed: ${error?.message ?? error}`);
        }
        const remindersTimer = setInterval(remind, REMINDERS_MS);
        remindersTimer.unref();
        void started.drain();
        try {
          ctx.setStatus(channelReadyPatch({ accountId: ctx.accountId }));
          await waitUntilAbort(ctx.abortSignal);
        } finally {
          watcher.close();
          clearInterval(sweep);
          clearTimeout(firstMail);
          clearInterval(mailTimer);
          clearInterval(callsTimer);
          clearInterval(remindersTimer);
          started.stopBounds();
          await reading;
          await started.drain();
          if (live === started) live = null;
          started.location.forget();
          await started.videos.close();
          await started.images.close();
          started.store.close();
          started.cart.close();
          started.notes.close();
          ctx.setStatus(channelStoppedPatch({ accountId: ctx.accountId }));
        }
      },
    },
    message: householdMessageAdapter,
  },
  outbound: {
    base: { deliveryMode: "direct" },
    attachedResults: {
      channel: CHANNEL,
      sendText: async (ctx) => sendText(ctx),
      sendMedia: async (ctx) => sendMedia(ctx),
    },
  },
});

// The phone's calls. Each needs the channel running, and is handed the calling
// connection, whose device id OpenClaw checked when the phone connected. A request this
// plugin refused, or one over a ceiling, says why, in words that carry nothing anybody
// said; any other failure says only that it failed.
function method(handler) {
  return async ({ params, respond, client }) => {
    if (!live) {
      respond(false, undefined, { code: "UNAVAILABLE", message: "the household app channel is not running" });
      return;
    }
    try {
      respond(true, await handler(live, params ?? {}, client));
    } catch (error) {
      if (error?.code === "INVALID_REQUEST" || error?.code === "LIMIT") {
        respond(false, undefined, {
          code: error.code,
          message: error.message,
          ...(typeof error.detailCode === "string" ? { details: { detailCode: error.detailCode } } : {}),
        });
      } else {
        respond(false, undefined, { code: "UNAVAILABLE", message: "the household app could not do that" });
      }
    }
  };
}

// A setup code for the owner's phone, from OpenClaw's own single-use bootstrap tokens.
async function setupCode(running) {
  if (!running.pairing.url) {
    throw Object.assign(new Error("channels.household.phoneUrl is not set, so phones cannot be told where to connect"), { code: "INVALID_REQUEST" });
  }
  return issueSetupCode({ ...running.pairing, issue: issueDeviceBootstrapToken, profile: PAIRING_SETUP_BOOTSTRAP_PROFILE });
}

// The owner's iPhones on Account, from one of them: see phones.js.
function phonesOf(running) {
  return createPhones({
    devices: listDevicePairing,
    phoneKeys: () => running.room.refreshPhoneKeys(),
    store: ownSettings().store,
    removePairing: (device) => removeThroughOpenClaw(device).catch((error) => {
      logger?.warn?.(`${PLUGIN_ID}: OpenClaw did not remove the paired phone ${device}: ${error?.message ?? error}`);
      throw error;
    }),
    forgetPush: (device) => running.store.removeDevicesOf(device),
    issueCode: async () => {
      const { code, expiresAtMs } = await setupCode(running);
      logger?.info?.(`${PLUGIN_ID}: issued an app setup code to a paired phone`);
      return { setupCode: code, link: pairLink(running.pairing.url, code), expiresAtMs };
    },
    // The other gateway stops believing the removed phone once the outbox leaves it out.
    changed: async () => {
      await running.room.refreshPhoneKeys();
      running.room.publishOutbox();
      logger?.info?.(`${PLUGIN_ID}: a paired phone removed another of its person's phones`);
    },
  });
}

// A sign-in with Apple from a phone not paired yet, so it answers anyone who reaches
// the gateway on the tailnet: Apple's token is the proof, and apple-signin.js checks it.
async function appleRoute(req, res, handle, logger) {
  const answer = (status, body) => {
    res.statusCode = status;
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    res.setHeader("Cache-Control", "no-store");
    res.end(JSON.stringify(body));
    return true;
  };
  if (req.method !== "POST") return answer(405, { error: "POST only" });
  if (appleLimiter.isRateLimited("apple")) return answer(429, { error: "too many sign-ins, try again in a minute" });
  const body = await readJsonWebhookBodyOrReject({ req, res, maxBytes: APPLE_BODY_BYTES, timeoutMs: APPLE_BODY_MS, emptyObjectOnEmpty: true });
  if (!body.ok) return true;
  if (!live) return answer(503, { error: "the household app channel is not running" });
  try {
    return answer(200, await handle(live, body.value ?? {}));
  } catch (error) {
    if (error?.code === "INVALID_REQUEST") return answer(400, { error: error.message });
    logger.warn?.(`${PLUGIN_ID}: a sign-in with Apple failed: ${error?.message ?? error}`);
    return answer(503, { error: "the household app could not do that" });
  }
}

function registerFull(api) {
  const read = { scope: "operator.read" };
  const write = { scope: "operator.write" };
  workflow = api.session.workflow;
  logger = api.logger;
  api.registerCommand({
    name: "app",
    description: "Set up the Steward AI app on your phone.",
    acceptsArgs: false,
    requiredScopes: ["operator.pairing"],
    handler: async (ctx) => {
      if (!mayIssueSetupCode(ctx)) return { text: "Only the person this assistant belongs to can set up the app." };
      if (!live) return { text: "The app channel is not running on this gateway." };
      try {
        const { code } = await setupCode(live);
        api.logger.info?.(`${PLUGIN_ID}: issued an app setup code on ${ctx.channel}`);
        return { text: setupReply({ code, link: pairLink(live.pairing.url, code) }) };
      } catch (error) {
        api.logger.warn?.(`${PLUGIN_ID}: no app setup code: ${error?.message ?? error}`);
        return { text: "The app cannot be set up from this gateway yet." };
      }
    },
  });
  // The page a pairing link opens. It holds no code and needs no sign-in: the code rides
  // after the #, which no browser sends.
  api.registerHttpRoute({
    path: PAIR_PATH,
    auth: "plugin",
    match: "exact",
    handler: async (req, res) => {
      res.statusCode = req.method === "GET" || req.method === "HEAD" ? 200 : 405;
      res.setHeader("Content-Type", "text/html; charset=utf-8");
      res.setHeader("Cache-Control", "no-store");
      res.setHeader("Referrer-Policy", "no-referrer");
      res.setHeader(
        "Content-Security-Policy",
        "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      );
      res.end(res.statusCode === 200 && req.method === "GET" ? PAIR_PAGE : "");
      return true;
    },
  });
  for (const [route, handle] of [
    [`${APPLE_PATH}/nonce`, (running) => running.nonces.issue()],
    [`${APPLE_PATH}/pair`, (running, body) => running.appleSignIn.pair(body)],
    [`${APPLE_PATH}/status`, (running, body) => running.appleSignIn.status(body)],
  ]) {
    api.registerHttpRoute({
      path: route,
      auth: "plugin",
      match: "exact",
      handler: (req, res) => appleRoute(req, res, handle, api.logger),
    });
  }
  // The same code for whoever runs the box, through an admin gateway client.
  api.registerGatewayMethod(
    `${PLUGIN_ID}.pair`,
    method(async (running) => {
      const { code, expiresAtMs } = await setupCode(running);
      return { setupCode: code, expiresAtMs };
    }),
    { scope: "operator.admin" },
  );
  api.registerGatewayMethod(`${PLUGIN_ID}.sync`, method((running, params) => running.room.sync(params)), read);
  // The two assistants' line, for both people to watch: every step either took in the
  // household note, a page at a time (notes.js timeline). Not `.pair`, which is the setup
  // code's above: OpenClaw keeps a method's first registration.
  api.registerGatewayMethod(`${PLUGIN_ID}.line`, method((running, params) => running.notes.timeline({ before: params?.before, limit: params?.limit })), read);
  api.registerGatewayMethod(`${PLUGIN_ID}.history`, method((running, params) => running.room.history(params)), read);
  api.registerGatewayMethod(
    `${PLUGIN_ID}.send`,
    method((running, params) => running.room.receive(params)),
    write,
  );
  // A call with the assistant, ended: its turns, each sent as a message, folded into one
  // call entry, signed by the phone that made the call, and one line in the log for how the
  // call came up.
  api.registerGatewayMethod(
    `${PLUGIN_ID}.call.end`,
    method(async (running, params) => {
      const answer = await running.room.endCall(params);
      running.log.info(callSetupLine(params, answer.entry));
      return answer;
    }),
    write,
  );
  // What iOS measured of the app on the owner's phone over a day: one line in the log.
  api.registerGatewayMethod(
    `${PLUGIN_ID}.metrics.report`,
    method((running, params) => {
      running.log.info(phoneMetricsLine(params));
      return { ok: true };
    }),
    write,
  );
  api.registerGatewayMethod(`${PLUGIN_ID}.upload`, method((running, params) => running.media.putUpload(params)), write);
  api.registerGatewayMethod(
    `${PLUGIN_ID}.media`,
    method((running, params) => running.media.read(params.id, Number(params.offset) || 0, Math.min(Number(params.length) || MAX_MEDIA_CHUNK, MAX_MEDIA_CHUNK))),
    read,
  );
  api.registerGatewayMethod(`${PLUGIN_ID}.react`, method(async (running, params) => ({ entry: await running.room.react(params) })), write);
  api.registerGatewayMethod(`${PLUGIN_ID}.avatar.set`, method((running, params) => running.room.setAvatar(params)), write);
  api.registerGatewayMethod(`${PLUGIN_ID}.look.set`, method((running, params) => running.room.setLook(params)), write);
  api.registerGatewayMethod(`${PLUGIN_ID}.read`, method(async (running, params) => ({ entry: await running.room.read(params) })), write);
  api.registerGatewayMethod(`${PLUGIN_ID}.typing`, method((running, params) => {
    running.room.personTyping(params);
    return {};
  }), write);
  api.registerGatewayMethod(`${PLUGIN_ID}.card.tick`, method((running, params) => running.tick(params)), write);
  api.registerGatewayMethod(`${PLUGIN_ID}.cart.ordered`, method((running, params) => running.cartOrdered(params)), write);
  // The owner's phone answering an approval card, signed by that phone.
  api.registerGatewayMethod(`${PLUGIN_ID}.approval.answer`, method((running, params) => running.approvals.answer(params)), write);
  api.registerGatewayMethod(`${PLUGIN_ID}.location`, method((running, params) => running.location.report(params)), write);
  // A live map the owner shared in a conversation, moved or stopped by the phone that
  // shared it, and the owner's answer to a reminder by place that would watch them.
  api.registerGatewayMethod(`${PLUGIN_ID}.location.live`, method((running, params) => running.room.live(params)), write);
  api.registerGatewayMethod(`${PLUGIN_ID}.place.answer`, method((running, params) => running.room.answerPlace(params)), write);
  api.registerGatewayMethod(
    `${PLUGIN_ID}.push.register`,
    method((running, params, client) => {
      running.room.registerDevice({ ...params, phone: phoneOf(client) });
      return { ok: true };
    }),
    write,
  );
  // Settings: the phone's own assistant, read and changed, its model picker, the month's
  // spend, and a few words spoken in a voice.
  api.registerGatewayMethod(`${PLUGIN_ID}.settings`, method((running, params, client) => ownSettings().settings.view(phoneOf(client), params)), read);
  api.registerGatewayMethod(
    `${PLUGIN_ID}.settings.change`,
    method((running, params, client) => ownSettings().settings.change(params, phoneOf(client))),
    write,
  );
  // A connector's sign-in from the owner's phone, answered with the settings as they are
  // now, so the phone reads Connected from the gateway.
  for (const action of ["connect", "disconnect"]) {
    api.registerGatewayMethod(
      `${PLUGIN_ID}.connector.${action}`,
      method(async (running, params, client) => {
        await ownSettings().connect[action](params);
        return ownSettings().settings.view(phoneOf(client), params);
      }),
      write,
    );
  }
  // A picker's list: the text models, or with `kind` the image or the video models.
  const pickerLists = { text: () => catalog.models(), vision: () => catalog.visionModels(), image: () => catalog.imageModels(), video: () => catalog.videoModels() };
  api.registerGatewayMethod(`${PLUGIN_ID}.models`, method(async (running, params) => {
    const kind = params.kind ?? "text";
    if (!Object.hasOwn(pickerLists, kind)) throw Object.assign(new Error("kind is text, vision, image or video"), { code: "INVALID_REQUEST" });
    return { models: await pickerLists[kind]() };
  }), read);
  api.registerGatewayMethod(`${PLUGIN_ID}.spend`, method(() => ownSettings().spend.view()), read);
  // What the box's spend job adds the household's month up from (spend.js), for whoever
  // runs the box only: the key's own usage, which phones need not see or make it read.
  api.registerGatewayMethod(`${PLUGIN_ID}.spend.figures`, method(() => ownSettings().spend.figures()), { scope: "operator.admin" });
  // A voice's sample and Talk's sentences, kept with the conversations' media.
  api.registerGatewayMethod(
    `${PLUGIN_ID}.speak`,
    method((running, params) => createSpeak({
      store: ownSettings().store,
      media: running.media,
      tts: (request) => runtime.tts.textToSpeech(request),
      config: () => runtime.config.current(),
    })(params)),
    write,
  );
  // How the assistant is named and talks, in every turn of the main agent, Telegram's
  // included. A system-prompt addition, never a hook on what is sent, which would end
  // Telegram's streaming preview. Every app turn also starts with the household note
  // (notes.js): the family room's shared session, which the other assistant's handed-over
  // turns run in, and the direct line's, where its handoffs run, all of it, and the owner's
  // own thread and own session of the room, which
  // hold every tool, the lines this assistant wrote for its owner and a count of the rest.
  api.on("before_prompt_build", (event, context) => {
    const cfg = runtime.config.current();
    if ((context?.agentId !== undefined && context.agentId !== AGENT) || !resolveAccount(cfg).configured) return undefined;
    const sessionKey = context?.sessionKey;
    const isOwnersOwn = live !== null && (sessionKey === live.ownerSession || sessionKey === live.ownersFamilySession);
    const isAppTurn = isOwnersOwn || (live !== null && [live.familySession, live.pairSession].includes(sessionKey));
    const note = isAppTurn ? live.notes.prompt(event?.prompt, isOwnersOwn ? { fullFor: live.owner.id } : {}) : "";
    return { appendSystemContext: [ownSettings().settings.guidance(cfg), householdRoutingGuidance(cfg)].filter(Boolean).join("\n\n"), ...(note ? { prependContext: note } : {}) };
  });
  // This assistant's family automations, mirrored into the household note as OpenClaw
  // reconciles the scheduler and whenever a job changes, a run's finish included, since a
  // one-time job is gone once it ran.
  api.on("cron_reconciled", (event, context) => {
    const cron = event?.enabled === false ? undefined : context?.getCron?.();
    scheduler = cron ? { cron, signal: context.abortSignal } : null;
    return mirrorAutomations();
  });
  api.on("cron_changed", () => mirrorAutomations());
  // Which run each tool call is, so a tool's post during a handed-over turn is marked, and
  // what each call changed once it ended, for its turn's reply. They only watch: neither
  // ever blocks or changes a call.
  api.on("before_tool_call", (event, context) => {
    handovers.toolStarted(event?.runId ?? context?.runId, event?.toolCallId ?? context?.toolCallId);
  });
  api.on("after_tool_call", (event, context) => {
    const runId = event?.runId ?? context?.runId;
    handovers.toolEnded(runId, event?.toolCallId ?? context?.toolCallId);
    did.toolEnded(runId, event);
  });
  // A paired phone linking its person's Apple ID, and the approver's phone letting in a
  // phone that signed in with Apple and nobody linked.
  api.registerGatewayMethod(`${PLUGIN_ID}.apple.nonce`, method((running) => running.nonces.issue()), write);
  api.registerGatewayMethod(`${PLUGIN_ID}.apple.link`, method((running, params) => running.appleSignIn.link(params)), write);
  api.registerGatewayMethod(
    `${PLUGIN_ID}.apple.waiting`,
    method((running) => ({ waiting: running.appleSignIn.waiting() })),
    read,
  );
  api.registerGatewayMethod(`${PLUGIN_ID}.apple.approve`, method((running, params) => running.appleSignIn.approve(params)), write);
  // The owner's iPhones on Account: each one paired, removing another, and a setup code
  // for a new one, the last two signed by one of them.
  api.registerGatewayMethod(`${PLUGIN_ID}.phones`, method((running, params, client) => phonesOf(running).view(phoneOf(client))), read);
  api.registerGatewayMethod(
    `${PLUGIN_ID}.phones.remove`,
    method((running, params, client) => phonesOf(running).remove(params, phoneOf(client))),
    write,
  );
  api.registerGatewayMethod(`${PLUGIN_ID}.pair.code`, method((running, params) => phonesOf(running).pairCode(params)), write);
  // Where the owner is, for the assistant, in the turns the owner's choice in the app
  // covers. Before the channel runs there is no tool, and the tool reads the position as
  // it runs, so a share that ended or a channel that stopped answers nothing.
  api.registerTool(
    (context) => live && createLocationTool({
      context,
      owner: live.owner.id,
      ownerName: live.owner.name,
      people: [live.owner.id, live.peerPerson.id],
      current: () => live?.location.current() ?? null,
    }),
    { names: [LOCATION_TOOL], optional: true },
  );
  // A calendar or reminder change in the owner's own turns, their thread and a family-room
  // turn they started, waits for the owner's yes, which approvals.js asks for in their
  // thread. Nothing asks while the channel is not running.
  api.on("before_tool_call", (event, context) => askBeforeChange(event, context, {
    ownerSession: live?.ownerSession,
    ownersFamilySession: live?.ownersFamilySession,
  }), { matcher: ASKING_TOOLS });
  // A chart in the app is a card: a dashboard widget there would reach nobody.
  api.on("before_tool_call", (event, context) => refuseDashboardInApp(context), { matcher: [DASHBOARD_TOOL] });
  // Old family destinations resolve to the app once, with no Telegram copy.
  const familyPosts = createFamilyPosts({ config: () => runtime.config.current() });
  api.on("before_tool_call", (event, context) => familyPosts.beforeToolCall(event, context), { matcher: FAMILY_POST_TOOLS });
  // The household cart, in the owner's own thread and the family room.
  api.registerTool(
    (context) => live && createCartTool({ context, owner: live.owner.id, people: [live.owner, live.peerPerson], cart: live.cart }),
    { names: [CART_TOOL], optional: true },
  );
  // The household note, in the owner's own thread and the family room.
  api.registerTool(
    (context) => live && createNoteTool({
      context,
      owner: live.owner.id,
      people: [live.owner.id, live.peerPerson.id],
      notes: live.notes,
      peerAssistantName: live.peerAssistantName,
    }),
    { names: [NOTE_TOOL], optional: true },
  );
  // The thermostat, the music and the living room TV, through the home key holder on the
  // host, in the owner's own thread and the family room.
  api.registerTool(
    (context) => live && createHomeTool({ context, owner: live.owner.id, people: [live.owner.id, live.peerPerson.id], call: callHome }),
    { names: [HOME_TOOL], optional: true },
  );
  // A tapback from the assistant on a person's message, in the owner's own thread and the
  // family room, where it crosses to the other gateway like any reaction.
  api.registerTool(
    (context) => live && createReactTool({ context, owner: live.owner.id, people: [live.owner.id, live.peerPerson.id], room: live.room }),
    { names: [REACT_TOOL], optional: true },
  );
  // Today's brief: written by the assistant in its own turns, the morning's scheduled run
  // included, and read by the phone. The owner comes from the config, since a Telegram
  // turn or a scheduled run needs no running channel.
  api.registerTool(
    (context) => {
      const cfg = runtime.config.current();
      const account = resolveAccount(cfg);
      return account.configured
        ? createBriefTool({
            context,
            owner: account.config.owner.id,
            owners: cfg?.commands?.ownerAllowFrom,
            write: (text) => ownSettings().brief.write(text),
          })
        : null;
    },
    { names: [BRIEF_TOOL], optional: true },
  );
  api.registerGatewayMethod(`${PLUGIN_ID}.brief`, method(() => ({ brief: ownSettings().brief.today() })), read);
  // The Today card: written by the assistant in the same turns as the brief, the morning's
  // and the evening's scheduled runs included, which writes today's brief beside it.
  api.registerTool(
    (context) => {
      const cfg = runtime.config.current();
      const account = resolveAccount(cfg);
      return account.configured
        ? createTodayTool({
            context,
            owner: account.config.owner.id,
            owners: cfg?.commands?.ownerAllowFrom,
            write: (today) => ownSettings().today.write(today),
          })
        : null;
    },
    { names: [TODAY_TOOL], optional: true },
  );
  api.registerGatewayMethod(`${PLUGIN_ID}.today`, method(() => ({ today: ownSettings().today.latest() })), read);
  api.registerService({
    id: `${PLUGIN_ID}-events`,
    start(ctx) {
      events = ctx.gatewayEvents ?? null;
      // The sign-ins kept from phones, where each skill looks for them (connect.js).
      ownSettings().connect.exportEnv().catch((error) => api.logger.warn?.(`${PLUGIN_ID}: a kept sign-in could not be opened: ${error?.message ?? error}`));
    },
    stop() {
      events = null;
      own?.store.close();
      own = null;
    },
  });
}

export default defineChannelPluginEntry({
  id: PLUGIN_ID,
  name: "Household app",
  description: "The family's own app as a channel: the family room and each person's thread with their assistant.",
  plugin: householdChannel,
  setRuntime: (pluginRuntime) => {
    runtime = pluginRuntime;
  },
  registerFull,
});

