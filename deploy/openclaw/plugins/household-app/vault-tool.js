// household_vault: the document and deadline vault (vault.js) for the assistant, in the
// owner's own thread alone. A document is kept from a photo or a scan the owner sent there,
// which never leaves this gateway; a photo in the family room has already reached the other
// side, so it is never kept from there. Its day also goes into the household note as a
// "Renewals" line, unless the owner asks to keep it to themselves.

import { NoteError } from "./notes.js";
import { turnOf } from "./turn.js";
import { DATE_KINDS, KINDS, MAX_WHAT, VaultError, dateWords } from "./vault.js";

export const VAULT_TOOL = "household_vault";
export const RENEWALS = "Renewals";
const ACTIONS = {
  keep: ["messageId", "what", "kind", "date", "dateKind", "isPrivate"],
  view: ["document"],
  update: ["document", "messageId", "what", "date", "dateKind"],
  remove: ["document"],
};

function result(payload, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], ...(isError ? { isError } : {}) };
}

const failure = (code, message) => result({ code, message }, true);

// A picture of a document: a photo, or a scan the app sends as a PDF.
const isPicture = (item) => item.kind === "photo" || (item.kind === "file" && (item.mime?.startsWith("image/") || item.mime === "application/pdf"));

// The pictures of the owner's message `messageId` in their own thread, or of the message it
// answers there, as media ids; the store's own copy is read, never anything the model says.
function picturesOf(store, messageId, owner) {
  const message = typeof messageId === "string" ? store.message(messageId) : null;
  const fromOwner = (each) => each?.conversation === "direct" && each.author === owner;
  if (!fromOwner(message)) return null;
  const found = message.media.filter(isPicture);
  if (found.length > 0) return found.map((item) => item.id);
  const parent = message.replyTo ? store.message(message.replyTo) : null;
  return fromOwner(parent) && parent.media.some(isPicture) ? parent.media.filter(isPicture).map((item) => item.id) : null;
}

export function createVaultTool({ context, owner, ownerName, people, vault, notes, store }) {
  if (turnOf(context, { owner, people })?.kind !== "direct") return null;
  const noteText = (shown) => `${ownerName}'s ${shown.what} ${shown.expires ? "expires" : "renews"} ${dateWords(shown.expires ?? shown.renews)}`;
  const due = (shown) => shown.expires ?? shown.renews;
  return {
    name: VAULT_TOOL,
    label: "Document vault",
    description:
      `${ownerName}'s document and deadline vault. When ${ownerName} sends a photo or a scan of a passport, an insurance policy, a car registration, ` +
      "a warranty, a subscription or a license, read from it the day it expires or renews and keep it with `keep`: the message's id (`message_id` " +
      "in the conversation info), what it is in a few words, such as \"passport\" or \"car insurance\", its `kind`, and the day as `date` with `dateKind`. " +
      "Never guess a date you cannot read: ask. The picture stays here on this side, and nobody else sees it. " +
      `The day also goes in the household note under "${RENEWALS}" for both sides, naming only the document and its day, unless ${ownerName} asks to keep it ` +
      "to themselves: then `isPrivate`. Never repeat a document's numbers, such as a passport or policy number, anywhere but here. " +
      `${ownerName} is told thirty days before the day, by the household, with no turn of yours. When the answer has \`tell\`, the day is closer than that: say so in your reply. ` +
      "`update` takes a renewed document's new day, or a new photo of it, `view` lists what is kept, and `remove` takes one out.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: Object.keys(ACTIONS) },
        messageId: { type: "string", maxLength: 80, description: `The id of ${ownerName}'s message with the photo or scan.` },
        what: { type: "string", minLength: 1, maxLength: MAX_WHAT, description: "What the document is, in a few words." },
        kind: { type: "string", enum: KINDS },
        date: { type: "string", pattern: "^\\d{4}-\\d{2}-\\d{2}$", description: "The day it expires or renews, YYYY-MM-DD, as the document shows it." },
        dateKind: { type: "string", enum: DATE_KINDS },
        isPrivate: { type: "boolean", description: `Only when ${ownerName} asks: the day stays out of the household note.` },
        document: { type: "string", description: "A kept document's id, such as dv-1a2b3c4d, from the vault." },
      },
    },
    async execute(_id, args) {
      const allowed = typeof args?.action === "string" && Object.hasOwn(ACTIONS, args.action) ? ACTIONS[args.action] : null;
      if (!allowed || Object.keys(args).some((key) => key !== "action" && !allowed.includes(key))) {
        return failure("invalid_arguments", `Use one action of ${Object.keys(ACTIONS).join(", ")}, with only its own fields.`);
      }
      const pictures = args.messageId === undefined ? undefined : picturesOf(store, args.messageId, owner);
      if (pictures === null) {
        return failure("no_picture", `That is not a message of ${ownerName}'s in this thread with a photo or a scan.`);
      }
      try {
        if (args.action === "view") return result(vault.view(args.document));
        if (args.action === "keep") {
          if (pictures === undefined) return failure("no_picture", "Give the id of the message with the photo or scan.");
          const kept = vault.keep({ what: args.what, kind: args.kind, date: args.date, dateKind: args.dateKind ?? "expires", pictures });
          if (args.isPrivate === true) return result(vault.view(kept.document));
          try {
            const added = notes.add({ topic: RENEWALS, text: noteText(kept), due: due(kept), forWho: owner });
            vault.setLine(kept.document, added.lines.at(-1).id);
          } catch (error) {
            // The document is kept either way; only its note line is missing.
            if (!(error instanceof NoteError)) throw error;
            return result({ ...vault.view(kept.document), notInNote: error.message });
          }
          return result(vault.view(kept.document));
        }
        if (args.action === "update") {
          const updated = vault.update(args.document, { what: args.what, date: args.date, dateKind: args.dateKind, pictures });
          const line = vault.line(updated.document);
          if (line !== null) {
            try {
              notes.correct(line, { text: noteText(updated), due: due(updated), forWho: owner });
            } catch (error) {
              // A note line someone removed comes back with the document's new day.
              if (!(error instanceof NoteError)) throw error;
              const added = notes.add({ topic: RENEWALS, text: noteText(updated), due: due(updated), forWho: owner });
              vault.setLine(updated.document, added.lines.at(-1).id);
            }
          }
          return result(vault.view(updated.document));
        }
        const removed = vault.remove(args.document);
        if (removed.line !== null) {
          try {
            notes.remove(removed.line);
          } catch (error) {
            if (!(error instanceof NoteError)) throw error;
          }
        }
        return result({ removed: removed.what });
      } catch (error) {
        if (error instanceof VaultError || error instanceof NoteError) return failure(error.code, error.message);
        throw error;
      }
    },
  };
}
