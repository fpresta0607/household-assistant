// OpenClaw's approvals in the app. When a step of the assistant's run waits for a yes,
// the way a command or a plugin's tool can be made to, OpenClaw hands the request to every
// channel that presents approvals natively. This one shows it as a card in the owner's own
// thread, never in the family room, and says there how it ended.
//
// Only the owner's phone can answer it, the way only that phone can start the owner's
// turn: the answer is signed with the phone's own key, over the approval it answers and
// the decision. A token with write scope, or an assistant talked into calling this, holds
// no phone's key, so it can never say yes for the owner. OpenClaw then checks the owner
// again through the channel's `authorizeActorAction`, and the first answer from any
// surface wins.
//
// Only approvals from a turn in this channel come here.
//
// A draft the owner sends with one tap (send-tool.js) is such an approval too. OpenClaw keeps
// only a few lines of a request's words, so its card carries the whole draft, found by the
// tool call it is for: where it goes, every word, or every item and the total.

import { createHash } from "node:crypto";

import { RoomError } from "./room.js";

export const APPROVAL_SIGNATURE_VERSION = "household-app/approval/v1";
const CHANNEL = "household";
const DIRECT = "direct";
// Approve is one yes, for this step only. A yes for always would change what the
// assistant may do from then on, which is the box's to set, not a tap's.
const DECISIONS = ["allow-once", "deny"];
const STATES = new Set(["approved", "denied", "expired"]);
// What OpenClaw lets a plugin put in an approval's title and description.
const MAX_TITLE = 80;
const MAX_DETAIL = 512;
const LINE_FREE = /^[^\r\n]+$/;

const refuse = (message) => {
  throw new RoomError("INVALID_REQUEST", message);
};

// The exact text the owner's phone signs to answer one approval. Null when a field could
// not be put on one line.
export function approvalText({ approvalId, decision }) {
  const fields = [approvalId, decision];
  if (!fields.every((field) => typeof field === "string" && LINE_FREE.test(field))) return null;
  return [APPROVAL_SIGNATURE_VERSION, ...fields].join("\n");
}

function bounded(text, limit) {
  const trimmed = typeof text === "string" ? text.trim() : "";
  return trimmed ? trimmed.slice(0, limit) : undefined;
}

// What the card shows, from the view OpenClaw builds of a pending approval: what is asked,
// in a line and a few more, and which of Approve and Deny the request allows.
export function approvalCard(view) {
  const offered = new Set((view.actions ?? []).map((action) => action.decision));
  const isCommand = view.approvalKind === "exec";
  const detail = bounded(isCommand ? view.commandPreview ?? view.commandText : view.description, MAX_DETAIL);
  return {
    title: isCommand ? "Run a command" : bounded(view.title, MAX_TITLE) ?? "Needs your OK",
    ...(detail ? { detail } : {}),
    decisions: DECISIONS.filter((decision) => offered.has(decision)),
  };
}

// The card's message id, the same every time OpenClaw hands over the same approval, as it
// does again for one still waiting when the gateway restarts.
function messageIdFor(approvalId) {
  return `ap-${createHash("sha256").update(approvalId).digest("hex").slice(0, 40)}`;
}

function stateOf(decision) {
  if (decision === "allow-once" || decision === "allow-always") return "approved";
  return decision === "deny" ? "denied" : "expired";
}

// `announce` tells the phones about an entry, and pushes a message to them. `ownerKeys`
// answers with the keys of the owner's phones, `resolve` hands an answer to OpenClaw, and
// `draftFor` answers a send's whole draft by its tool call, or null.
export function createApprovals({ store, assistant, sessionKeys, now = Date.now, announce, ownerKeys, isSignedBy, resolve, draftFor = () => null }) {
  const sessions = new Set(Object.values(sessionKeys));

  return {
    // Whether OpenClaw's request came from a turn in this channel: by the turn's channel,
    // or for a turn that names none, such as a reminder's, by its session.
    isOurs(request) {
      const source = String(request?.request?.turnSourceChannel ?? "").trim().toLowerCase();
      return source ? source === CHANNEL : sessions.has(request?.request?.sessionKey);
    },

    async present({ approvalId, approvalKind, card, toolCallId }) {
      const { title, decisions } = card;
      const draft = typeof toolCallId === "string" ? draftFor(toolCallId) : null;
      const detail = draft ? draft.text : card.detail;
      const send = draft && {
        kind: draft.kind,
        ...(draft.to ? { to: draft.to, subject: draft.subject } : {}),
        ...(draft.total ? { total: draft.total, items: draft.items } : {}),
      };
      const { added, entry } = store.addMessage({
        id: messageIdFor(approvalId),
        conversation: DIRECT,
        author: assistant.id,
        at: now(),
        text: detail ? `Needs your OK: ${title}\n${detail}` : `Needs your OK: ${title}`,
        media: [],
        replyTo: null,
        origin: "local",
        approval: { id: approvalId, kind: approvalKind, title, ...(detail ? { detail } : {}), ...(send ? { send } : {}), decisions },
      });
      if (added) await announce(entry);
      return { messageId: entry.id };
    },

    // How the approval ended, once: OpenClaw says so whichever surface answered.
    async settle({ messageId }, state) {
      if (!STATES.has(state)) return;
      const entry = store.setApprovalState({ messageId, state, at: now() });
      if (entry) await announce(entry);
    },

    // The owner's phone answering one card.
    async answer({ messageId, decision, signature } = {}) {
      if (typeof messageId !== "string") refuse("bad approval");
      const message = store.message(messageId);
      if (!message?.approval || message.conversation !== DIRECT || message.author !== assistant.id) refuse("no such approval");
      const { approval } = message;
      if (!approval.decisions.includes(decision)) refuse("that answer is not offered");
      if (!isSignedBy(approvalText({ approvalId: approval.id, decision }), signature, await ownerKeys())) {
        refuse("answers must carry the signature of one of the owner's phones");
      }
      if (store.approvalState(messageId)) refuse("that approval is no longer waiting");
      await resolve({ approvalId: approval.id, approvalKind: approval.kind, decision });
      return { answered: true };
    },
  };
}

// The channel's half of OpenClaw's native approvals, which OpenClaw drives: whether a
// request is this channel's, the card, delivering it to the owner's thread, and how it
// ended. Every hook reaches the running channel through the context it registers when it
// starts, so a stopped channel handles nothing.
export const approvalNativeRuntime = {
  eventKinds: ["exec", "plugin"],
  availability: {
    isConfigured: ({ context }) => Boolean(context?.approvals),
    shouldHandle: ({ context, request }) => context?.approvals?.isOurs(request) === true,
  },
  presentation: {
    buildPendingPayload: ({ view }) => approvalCard(view),
    buildResolvedResult: ({ resolved }) => ({
      kind: "update",
      payload: { state: resolved?.terminalStatus === "cancelled" ? "expired" : stateOf(resolved?.decision) },
    }),
    buildExpiredResult: () => ({ kind: "update", payload: { state: "expired" } }),
  },
  transport: {
    prepareTarget: ({ plannedTarget }) => ({ dedupeKey: plannedTarget.target.to, target: plannedTarget.target }),
    deliverPending: ({ context, request, approvalKind, pendingPayload }) =>
      context.approvals.present({ approvalId: request.id, approvalKind, card: pendingPayload, toolCallId: request.request?.toolCallId }),
    updateEntry: ({ context, entry, payload }) => context.approvals.settle(entry, payload.state),
  },
};

// The approval capability the channel declares: OpenClaw lets only the owner answer, and
// delivers every approval this channel handles to the owner's own thread. `ownerOf` reads
// the owner's id from the gateway's config, and `nativeRuntime` is the runtime above as
// OpenClaw's adapter wraps it.
export function ownerApprovalCapability({ ownerOf, nativeRuntime }) {
  const ownerThread = ({ cfg }) => {
    const owner = ownerOf(cfg);
    return owner ? [{ to: `${CHANNEL}:${owner}`, accountId: "default" }] : [];
  };
  return {
    authorizeActorAction: ({ cfg, senderId }) => {
      const owner = ownerOf(cfg);
      return owner && senderId === owner
        ? { authorized: true }
        : { authorized: false, reason: "Only the person this assistant belongs to can answer its approvals." };
    },
    native: {
      describeDeliveryCapabilities: (params) => ({
        enabled: ownerThread(params).length > 0,
        preferredSurface: "approver-dm",
        supportsOriginSurface: false,
        supportsApproverDmSurface: true,
        notifyOriginWhenDmOnly: false,
      }),
      resolveApproverDmTargets: ownerThread,
    },
    nativeRuntime,
  };
}
