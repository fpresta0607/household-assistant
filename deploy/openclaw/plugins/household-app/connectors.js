// The connectors a phone may switch on and off for its own assistant, in Settings.
//
// Each switches the narrowest settings that take it away from the assistant everywhere it
// answers, Telegram and the family room included: a skill's own
// `skills.entries.<name>.enabled`, or a tool in the gateway-wide `tools.deny`, which
// wins over every allow list, The Fam's and the family room's included. Neither needs a
// restart. A plugin is never switched off: that restarts the gateway, and PocketPiggies'
// guard puts its plugin back anyway, while it leaves `tools.deny` alone.
//
// Which gateway has which was read from both on 15 October, and Denise has had Gia's own
// Google account through gog since #93. A connector one of them does not have, or has
// without what it needs to run, is listed only for the other.
//
// Nothing that keeps the app or the family room working is here: not the household
// plugins, memory, Telegram, device pairing, PocketPiggies' key holder or a model
// provider. Switching one of those off from a phone would cut that phone off.

export const CATEGORIES = ["money", "faith", "calendar-and-mail", "notes", "web", "pictures-and-video", "everyday"];

export const CONNECTORS = [
  {
    id: "pocket-piggies",
    name: "PocketPiggies",
    category: "money",
    icon: "pocketpiggies",
    summary: "Budgets, balances and spending",
    tools: ["pocketpiggies_catalog", "pocketpiggies_read", "pocketpiggies_records"],
    capabilities: ["Reads your budgets, balances and spending", "Answers money questions in your own chat only"],
  },
  // The Bible, in the gateway itself (household-scripture): nothing to sign in to.
  { id: "scripture", name: "Scripture", category: "faith", icon: "symbol:book", summary: "The Bible, sermons and word studies",
    skills: ["scripture"], tools: ["scripture"],
    capabilities: ["Reads and searches the Bible", "Shows cross references and the Hebrew and Greek words", "Keeps the household's sermons and study plans"] },
  {
    id: "icloud",
    name: "iCloud",
    category: "calendar-and-mail",
    icon: "icloud",
    summary: "Calendars and reminders in iCloud",
    skills: ["apple-cal-anywhere", "icloud-caldav-connect"],
    signIn: "password",
    envSignIn: "APPLECAL_PASSWORD",
    capabilities: ["Reads your iCloud calendars", "Adds and changes events and reminders"],
  },
  { id: "gog", name: "Google", category: "calendar-and-mail", icon: "google", summary: "Gmail and Google Calendar", skills: ["gog"], signIn: "oauth",
    capabilities: ["Reads your Gmail", "Reads and adds events in Google Calendar"] },
  {
    id: "outlook-hack",
    name: "Outlook",
    category: "calendar-and-mail",
    icon: "symbol:envelope",
    summary: "Outlook mail and calendar",
    skills: ["outlook-hack"],
    assistants: ["corey"],
    capabilities: ["Reads your Outlook mail", "Reads and changes your Outlook calendar"],
  },
  {
    id: "himalaya",
    name: "Email",
    category: "calendar-and-mail",
    icon: "symbol:envelope",
    summary: "Reads and sends from your inbox",
    skills: ["himalaya"],
    assistants: ["denise"],
    signIn: "password",
    envSignIn: "YAHOO_APP_PASSWORD_GIA",
    capabilities: ["Reads your inbox", "Sends mail you ask it to send"],
  },
  { id: "notion", name: "Notion", category: "notes", icon: "notion", summary: "Pages and databases in Notion", skills: ["notion"],
    signInKind: "token", capabilities: ["Reads the Notion pages you share with it", "Adds and edits pages there when you ask"] },
  { id: "perplexity", name: "Perplexity", category: "web", icon: "perplexity", summary: "Searches the web", tools: ["web_search"],
    capabilities: ["Searches the web for current answers"] },
  {
    id: "web-readability",
    name: "Reading pages",
    category: "web",
    icon: "symbol:doc.text.magnifyingglass",
    summary: "Opens a link and reads the page",
    tools: ["web_fetch"],
    capabilities: ["Opens a link you send and reads the page"],
  },
  {
    id: "browser-automation",
    name: "Browser",
    category: "web",
    icon: "symbol:safari",
    summary: "Uses a browser for sites that need one",
    skills: ["browser-automation"],
    tools: ["browser"],
    capabilities: ["Uses a browser for sites that need one"],
  },
  {
    id: "image-generation",
    name: "Pictures",
    category: "pictures-and-video",
    icon: "symbol:photo",
    summary: "Makes a picture from a description",
    tools: ["picture"],
    capabilities: ["Makes a picture from a description"],
  },
  {
    id: "video-generation",
    name: "Videos",
    category: "pictures-and-video",
    icon: "symbol:film",
    summary: "Makes a short video from a description",
    tools: ["video"],
    capabilities: ["Makes a short video from a description"],
  },
  { id: "weather", name: "Weather", category: "everyday", icon: "symbol:cloud.sun", summary: "Forecasts and conditions", skills: ["weather"],
    capabilities: ["Gives forecasts and current conditions"] },
];

// The connectors one gateway has, by its assistant's id.
export function connectorsFor(assistantId) {
  return CONNECTORS.filter((connector) => !connector.assistants || connector.assistants.includes(assistantId));
}

const denied = (cfg) => (Array.isArray(cfg?.tools?.deny) ? cfg.tools.deny : []);

export function isConnectorOn(connector, cfg) {
  const skills = cfg?.skills?.entries ?? {};
  return (connector.skills ?? []).every((skill) => skills[skill]?.enabled !== false) &&
    !(connector.tools ?? []).some((tool) => denied(cfg).includes(tool));
}

// Switches one connector in a config draft about to be written.
export function switchConnector(draft, connector, isOn) {
  for (const skill of connector.skills ?? []) {
    draft.skills ??= {};
    draft.skills.entries ??= {};
    draft.skills.entries[skill] = { ...draft.skills.entries[skill], enabled: isOn };
  }
  if (!connector.tools) return;
  const kept = denied(draft).filter((tool) => !connector.tools.includes(tool));
  draft.tools ??= {};
  draft.tools.deny = isOn ? kept : [...kept, ...connector.tools];
}

// One connector as the phone shows it, from what connect.js reads back for it on this
// gateway. `signIn` keeps the values build 13 of the app decodes ("oauth", "password" or
// null) and `signInKind` is the full one, Notion's "token" among them. `state` is
// "connected" with at least one linked account or when the connector needs no sign-in,
// "unavailable" with a `reason` when this gateway cannot have it, and "available"
// otherwise. A linked account carries its name, email, linked time, status and plain
// abilities, and is the owner's own: never a token, a secret or an expiry.
export function connectorView(connector, cfg, { signInKind = null, linkedAccounts = [], oauth = null, reason = null } = {}) {
  const { id, name, category, icon, summary, capabilities } = connector;
  const isUnavailable = reason !== null;
  return {
    id,
    name,
    category,
    icon,
    summary,
    isOn: isConnectorOn(connector, cfg),
    signIn: isUnavailable ? null : connector.signIn ?? null,
    accounts: linkedAccounts.length,
    state: isUnavailable ? "unavailable" : linkedAccounts.length > 0 || signInKind === null ? "connected" : "available",
    reason,
    capabilities,
    signInKind: isUnavailable ? null : signInKind,
    linkedAccounts,
    oauth: isUnavailable ? null : oauth,
  };
}
