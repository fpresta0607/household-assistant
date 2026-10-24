// Household communication lives in Steward, the household's only channel. A post the model
// addresses to the family by one of its names goes to the app's family room, and one
// addressed to Telegram, which the household no longer uses, is refused with where to post.
export const FAMILY_POST_TOOLS = ["message"];
const POSTING_ACTIONS = new Set(["send", "broadcast"]);
const REFUSED = {
  block: true,
  blockReason: "Telegram is retired. Use message(action=send, channel=household, target=family) for The Fam, or the owner's household id for their private thread. Nothing was sent.",
};

const targetOf = (params) => [params.target, params.to, params.channelId].find((target) => typeof target === "string" && target.trim());
const namesTelegram = (target) => /^(?:telegram|tg):/i.test(String(target));
const namesAppFamily = (target) => typeof target === "string" && /^(?:household:)?(?:the fam|fam|family)$/i.test(target.trim());

export function householdRoutingGuidance(config) {
  const owner = config?.channels?.household?.owner?.id;
  if (!/^[a-z][a-z0-9-]{0,31}$/.test(owner ?? "")) return "";
  return `All household communication is in the Steward household app. Telegram is retired. ` +
    `The Fam means the app's shared family room, read by both people and both assistants. ` +
    `When asked to post a message to the family, use message with action=send, channel=household, target=family. ` +
    `Keep family logs and facts in household_note, not a private tracker. To coordinate with the other assistant, use household_note with action=hand; their seen status and answer appear there without a family-room message. ` +
    `An ordinary answer stays in the current app conversation; private messages to your own person use channel=household, target=${owner}. ` +
    `Do not use Telegram handles, Telegram conversation references or the old coordinate.py relay. ` +
    `Never copy private information to The Fam without the owner's request, and never claim delivery until the tool succeeds.`;
}

export function createFamilyPosts() {
  return {
    beforeToolCall(event) {
      if (event?.toolName !== "message") return undefined;
      const params = event.params ?? {};
      const channel = params.channel === undefined ? undefined : String(params.channel).trim().toLowerCase();
      const targets = params.action === "broadcast" ? params.targets : [targetOf(params)];
      if (channel === "telegram" || channel === "tg" || (Array.isArray(targets) && targets.some(namesTelegram))) return REFUSED;
      if (!POSTING_ACTIONS.has(params.action) || (channel !== undefined && channel !== "household")) return undefined;
      if (!Array.isArray(targets) || targets.length === 0 || !targets.every(namesAppFamily)) return undefined;
      if (params.accountId !== undefined && params.accountId !== "default") return REFUSED;
      const { to, channelId, threadId, replyTo, targets: named, ...rest } = params;
      return { params: { ...rest, channel: "household", target: "family",
        ...(params.action === "broadcast" ? { targets: ["family"] } : {}) } };
    },
  };
}
