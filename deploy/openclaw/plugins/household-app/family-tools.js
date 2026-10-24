// The tools a family-room turn may use.
//
// OpenClaw asks a channel's group adapter for a turn's tool policy only when the turn's
// session is a group's, so the owner's own thread is never restricted here. The family
// room is this channel's one group.
//
// A turn the owner started there, by a message one of their phones signed, is the owner's
// own and keeps every tool their thread has (the household's decision of 17 October: a
// question asked in the family room works exactly as it does one to one). It runs in its
// own session, the room's per-sender form (turn.js ownersFamilySession), so OpenClaw asks
// first about that session's group, `family:sender:<owner>`, and the answer there is a
// policy that restricts nothing. An empty deny list is a policy OpenClaw takes, so it stops
// there and never falls back to the room's own group.
//
// Every turn in the room's shared session, the owner's included, gets the family room's
// allowlist, `channels.household.familyTools`, which scripts/openclaw-household-app.py
// writes from the tools PocketPiggies and the household agree are safe in a group. So the
// other person, the other assistant's handover, a gateway client's chat.send (which names
// its own client id) and a run OpenClaw asks about with sender rules off
// (`senderPolicyMode: "never"`, a scheduled run) get the list, and what the owner's tools
// return in their own session is never in a turn anyone else starts.
//
// Without that list those turns get no tools at all. Returning nothing would leave them
// every tool, and so would an empty allow list, which OpenClaw 2026.9.4 reads as "allow
// everything not denied", so the closed policy denies "*". A wildcard, a glob, a tool
// group or a plugin's id would widen the list the same way, so only plain names count.

import { householdId, isNameable, ownersFamilyGroup } from "./turn.js";

const TOOL_NAME = /^[a-z][a-z0-9_]{0,63}$/;

export function familyToolPolicy({ cfg, groupId, senderId, senderPolicyMode }) {
  const owner = cfg?.channels?.household?.owner?.id;
  const isOwnersOwn = isNameable(owner) && senderPolicyMode !== "never" &&
    householdId(senderId) === owner && groupId === ownersFamilyGroup(owner);
  if (isOwnersOwn) return { deny: [] };
  const allowed = cfg?.channels?.household?.familyTools;
  const isPlainList = Array.isArray(allowed) && allowed.length > 0 &&
    allowed.every((name) => typeof name === "string" && TOOL_NAME.test(name));
  return isPlainList ? { allow: [...allowed] } : { deny: ["*"] };
}
