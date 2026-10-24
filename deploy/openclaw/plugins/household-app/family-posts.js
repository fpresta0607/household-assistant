// Household communication lives in Steward. Translate known legacy family targets at
// the tool boundary; never mirror or send a second copy to Telegram.
import { createHash } from "node:crypto";

export const FAMILY_POST_TOOLS = ["conversations_send", "message"];
const POSTING_ACTIONS = new Set(["send", "broadcast"]);
const GROUP_CHAT = /^-[1-9]\d*$/;

function conversationRef(channel, target) {
  const identity = JSON.stringify([channel, "default", "group", target, "", ""]);
  return `conv_${createHash("sha256").update(identity).digest("hex").slice(0, 32)}`;
}
export const familyConversationRef = (group) => conversationRef("telegram", group);
export const appFamilyConversationRef = () => conversationRef("household", "family");

export function familyGroupOf(config) {
  // Retain the old id for migration even after the Telegram plugin is disabled.
  const group = config?.plugins?.entries?.["household-family-room"]?.config?.groupChatId;
  return typeof group === "string" && GROUP_CHAT.test(group) ? group : undefined;
}
const targetOf = (params) => [params.target, params.to, params.channelId].find((target) => typeof target === "string" && target.trim());
const channelOf = (params, context) => params.channel !== undefined
  ? String(params.channel).trim().toLowerCase()
  : /^agent:[^:]+:telegram:/.test(String(context?.sessionKey ?? "")) ? "telegram" : undefined;
const namesGroup = (target, group) => typeof target === "string" && group &&
  target.trim().replace(/^(?:telegram|tg):/i, "").replace(/^group:/i, "") === group;
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

export function createFamilyPosts({ config }) {
  return {
    async beforeToolCall(event, context) {
      const params = event?.params ?? {};
      const group = familyGroupOf(config());
      const block = { block: true, blockReason: "Telegram is retired. Use message(action=send, channel=household, target=family) for The Fam, or the owner's household id for their private thread. Nothing was sent." };
      if (event?.toolName === "conversations_send") {
        if (!group || params.conversationRef?.trim().toLowerCase() !== familyConversationRef(group)) return undefined;
        if (context?.requester?.senderIsOwner === false) return block;
        return { params: { ...params, conversationRef: appFamilyConversationRef() } };
      }
      if (event?.toolName !== "message") return undefined;
      const channel = channelOf(params, context);
      const target = targetOf(params);
      const targets = params.action === "broadcast" ? params.targets : [target];
      const isTelegram = channel === "telegram" || channel === "tg" ||
        (Array.isArray(targets) && targets.some((value) => /^(?:telegram|tg):/i.test(String(value))));
      if (!POSTING_ACTIONS.has(params.action)) return isTelegram ? block : undefined;
      const canNameFamily = isTelegram || !channel || channel === "household";
      const allFamily = canNameFamily && Array.isArray(targets) && targets.length > 0 &&
        targets.every((value) => namesGroup(value, group) || namesAppFamily(value));
      if (!allFamily) return isTelegram ? block : undefined;
      const isLegacyFamily = isTelegram || targets.some((value) => namesGroup(value, group));
      if (context?.requester?.senderIsOwner === false && isLegacyFamily) return block;
      if (params.accountId !== undefined && params.accountId !== "default") return block;
      const { to, channelId, threadId, replyTo, targets: oldTargets, ...rest } = params;
      return { params: { ...rest, channel: "household", target: "family",
        ...(params.action === "broadcast" ? { targets: ["family"] } : {}) } };
    },
  };
}
