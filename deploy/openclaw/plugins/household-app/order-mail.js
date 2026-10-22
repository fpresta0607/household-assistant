// The household cart's order mail: on a timer, the plugin reads the owner's own new Amazon
// emails itself (amazon-mail.js), records what they say against the cart, and tells the
// owner in their own thread. No model sees an email, and a crafted one cannot steer an
// assistant. When an order is delivered, the family room hears one line, with no detail.
//
// Each email is read once: its id is kept in `seenFile` as soon as its bytes came, whatever
// they said. One that did not come is asked for again next time, three times at most.
// Emails are taken oldest first, and a card is posted only when an order moves forward,
// never for a step it already passed. The very first read, with no `seenFile` yet, records
// the week of mail it finds without posting, so turning this on is not a flood of old news.
// Nothing an email said is logged.

import { readFile, rename, writeFile } from "node:fs/promises";

import { readAmazonEmail } from "./amazon-mail.js";

const KEEP_SEEN = 1000;
const TRIES = 3;
const LINES = {
  ordered: "Amazon confirmed your household order.",
  shipped: "Your household order shipped.",
  out_for_delivery: "Your household order is out for delivery.",
  delivered: "Your household order was delivered.",
};
const DELIVERED_TO_FAMILY = "The household order was delivered.";

const block = (card) => `\`\`\`steward-card\n${JSON.stringify(card)}\n\`\`\``;
const reason = (error) => error?.code ?? error?.name ?? "error";

export function createOrderMail({ source, owner, cart, post, seenFile, log }) {
  const failures = new Map();

  async function loadSeen() {
    try {
      const list = JSON.parse(await readFile(seenFile, "utf8"));
      return Array.isArray(list) ? list.filter((id) => typeof id === "string") : [];
    } catch (error) {
      if (error?.code === "ENOENT") return null;
      log.warn(`household-app: the order mail's list of read emails was unreadable, so it starts again (${reason(error)})`);
      return [];
    }
  }

  async function saveSeen(list) {
    const temporary = `${seenFile}.tmp`;
    await writeFile(temporary, JSON.stringify(list.slice(-KEEP_SEEN)), { mode: 0o600 });
    await rename(temporary, seenFile);
  }

  async function tell(message) {
    try {
      await post(message);
    } catch (error) {
      log.warn(`household-app: an order update could not be posted (${reason(error)})`);
    }
  }

  return {
    async poll({ signal } = {}) {
      let ids;
      try {
        ids = await source.list(signal);
      } catch (error) {
        log.warn(`household-app: order mail could not list the mailbox (${reason(error)})`);
        return { read: 0, recorded: 0 };
      }
      const loaded = await loadSeen();
      const isFirstRead = loaded === null;
      const seen = loaded ?? [];
      const known = new Set(seen);
      const fresh = [];
      for (const id of ids) {
        if (known.has(id) || signal?.aborted) continue;
        try {
          fresh.push({ id, found: readAmazonEmail(await source.raw(id, signal), { to: owner }) });
          failures.delete(id);
        } catch (error) {
          const tries = (failures.get(id) ?? 0) + 1;
          failures.set(id, tries);
          log.warn(`household-app: an order email could not be fetched (${reason(error)}), try ${tries} of ${TRIES}`);
          if (tries >= TRIES) fresh.push({ id, found: null });
        }
      }
      const sentAt = (email) => (email.found ? Date.parse(email.found.at) : 0);
      fresh.sort((a, b) => sentAt(a) - sentAt(b));
      let recorded = 0;
      for (const { id, found } of fresh) {
        const result = found ? cart.mailOrder(found) : null;
        seen.push(id);
        failures.delete(id);
        await saveSeen(seen);
        if (!result?.isAdvance) continue;
        recorded += 1;
        if (isFirstRead) continue;
        await tell({ conversation: "direct", text: `${LINES[found.status]}\n\n${block(result.card)}` });
        if (found.status === "delivered") await tell({ conversation: "family", text: DELIVERED_TO_FAMILY });
      }
      if (isFirstRead && !fresh.length) await saveSeen(seen);
      return { read: fresh.length, recorded };
    },
  };
}
