export const OWNER = "franco";

/**
 * A gateway whose owner keeps every tool while the family room and other senders cannot reach
 * finance: the app's channel is the owner's, its family room runs on a safe allowlist, and the
 * Telegram channel the household retired is switched off.
 */
export const FINANCE_SAFE_GATEWAY_CONFIG = {
  session: { dmScope: "per-channel-peer", groupScope: "per-group" },
  tools: { profile: "coding", alsoAllow: ["family_history", "pocketpiggies_catalog"] },
  channels: {
    defaults: { groupPolicy: "allowlist" },
    household: {
      enabled: true,
      owner: { id: OWNER, name: "Franco" },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
      familyTools: ["web_search", "web_fetch", "family_history", "picture", "video"],
    },
    telegram: { enabled: false, dmPolicy: "allowlist", allowFrom: ["7000000001"] },
  },
};
