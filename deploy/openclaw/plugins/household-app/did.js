// What a run changed, kept on the reply it wrote as a short `did` list, which the app shows
// as chips under the answer: an event added, moved, changed or deleted, a reminder set,
// moved, changed or deleted, the household cart changed, an email drafted. Reads add nothing.
//
// It is read from the run's own tool calls, as OpenClaw's `after_tool_call` hook reports
// each one ended, and only a call that worked counts: a command that exited 0, a tool that
// answered without an error. A calendar or a reminder is read the way approval-asks.js reads
// it to ask, so a chip and a card say the same change.
//
// A turn names each run OpenClaw starts for it, as the handed-over turns in handovers.js do,
// so a change is the turn's whichever of its runs made it, and goes on the next reply the
// turn delivers. Nothing outlives the turn.
//
// The other assistant's list arrives on its family-room messages through the relay. An item
// this gateway cannot read, such as a kind a later version adds, is left out of it.

import { changeOf, commandWords, option, programPath, simpleCommands } from "./approval-asks.js";
import { CART_TOOL } from "./cart.js";

const MAX_DID = 8;
const MAX_TITLE = 80;
const CHANGES = {
  event: ["added", "moved", "changed", "deleted"],
  reminder: ["added", "moved", "changed", "deleted"],
  list: ["added", "changed", "deleted"],
  message: ["drafted"],
};
const CART_CHANGES = { add: "added", quantity: "changed", remove: "deleted" };
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const MOMENT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

const isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value);

// The household cart's add, quantity or remove. Only an add names the item.
function cartChange(params) {
  const change = CART_CHANGES[params?.action];
  if (!change) return null;
  return { kind: "list", change, ...(change === "added" ? { title: params.name } : {}) };
}

// gog [options] gmail drafts create --to <address> --subject <subject> ...
function draftChange(params) {
  if (typeof params?.command !== "string") return null;
  for (const words of simpleCommands(params.command)) {
    const index = words.findIndex((word) => programPath(word).split("/").at(-1) === "gog");
    if (index === -1) continue;
    const rest = words.slice(index + 1);
    const [group, drafts, verb] = commandWords(rest, ["--account", "--client"]);
    if (group === "gmail" && (drafts === "drafts" || drafts === "draft") && verb === "create") {
      return { kind: "message", change: "drafted", title: option(rest, ["--subject"]) };
    }
  }
  return null;
}

function changeMade(toolName, params, timeZone) {
  if (toolName === CART_TOOL) return cartChange(params);
  return changeOf(toolName, params, timeZone)?.did ?? (toolName === "exec" ? draftChange(params) : null);
}

function worked({ toolName, result, error }) {
  if (error || result?.isError === true) return false;
  return toolName !== "exec" || (result?.details?.status === "completed" && result.details.exitCode === 0);
}

// The item as a reply keeps it: its title one short line, and nothing else it carried.
function item({ kind, change, title, at, day }) {
  const line = typeof title === "string" ? title.replace(/\s+/g, " ").trim().slice(0, MAX_TITLE) : "";
  return { kind, change, ...(line ? { title: line } : {}), ...(at ? { at } : {}), ...(day ? { day } : {}) };
}

// `timeZone` is for tests: a time written with no offset is the gateway's own clock.
export function createDid({ timeZone } = {}) {
  // Each named run's list of changes, shared by the turn that named it.
  const runs = new Map();

  return {
    // One turn: `name` each run OpenClaw starts for it, `take` what its runs changed since
    // the last reply took it, and `end` it once it is over.
    turn() {
      const changes = [];
      const named = new Set();
      return {
        name(runId) {
          named.add(runId);
          runs.set(runId, changes);
        },
        take: () => changes.splice(0),
        end() {
          for (const runId of named) runs.delete(runId);
        },
      };
    },

    toolEnded(runId, event) {
      const changes = runs.get(runId);
      if (!changes || changes.length >= MAX_DID || !worked(event)) return;
      const change = changeMade(event.toolName, event.params, timeZone);
      if (change) changes.push(item(change));
    },
  };
}

function isReadable(value) {
  if (!isRecord(value) || !Object.hasOwn(CHANGES, value.kind) || !CHANGES[value.kind].includes(value.change)) return false;
  const { title, at, day } = value;
  if (title !== undefined && (typeof title !== "string" || !title.trim() || title.length > MAX_TITLE || /[\r\n]/.test(title))) {
    return false;
  }
  if (at !== undefined && (typeof at !== "string" || !MOMENT.test(at) || Number.isNaN(Date.parse(at)))) return false;
  if (day !== undefined && (typeof day !== "string" || !DAY.test(day))) return false;
  return at === undefined || day === undefined;
}

// The other gateway's list, as this one keeps it.
export function cleanDid(list) {
  return list.filter(isReadable).slice(0, MAX_DID).map(item);
}
