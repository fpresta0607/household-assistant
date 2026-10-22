export const OWNER = "123456";
export const FAMILY_GROUP = "-1001";

/** A gateway whose owner keeps every tool while groups and other senders cannot reach finance. */
export const FINANCE_SAFE_GATEWAY_CONFIG = {
  session: { dmScope: "per-channel-peer", groupScope: "per-group" },
  tools: { profile: "coding", alsoAllow: ["speak", "family_history", "pocketpiggies_catalog"] },
  channels: {
    telegram: {
      dmPolicy: "allowlist",
      allowFrom: [OWNER],
      groupPolicy: "allowlist",
      groups: {
        [FAMILY_GROUP]: {
          requireMention: true,
          allowFrom: [OWNER, "654321"],
          tools: { allow: ["web_search", "web_fetch", "speak", "family_history", "picture", "video"] },
        },
      },
    },
  },
};
