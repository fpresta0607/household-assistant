// The owner's Gmail, as the order mail reader asks it, through the gog binary the gateway
// already holds for its owner, run without a shell and with --readonly, which refuses any
// change, so nothing is marked read: the ids of Amazon's order mail of the last week, and
// one message's original bytes.
//
// `run(file, args, signal)` resolves to { stdout } as a Buffer or a string.

const LOOK_BACK_DAYS = 7;
const MAX_MESSAGES = 50;
const QUERY = `from:amazon.com newer_than:${LOOK_BACK_DAYS}d ` +
  '(subject:ordered OR subject:shipped OR subject:"out for delivery" OR subject:delivered OR subject:"your amazon.com order")';
const MESSAGE_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;

export function gmailSource({ account, run }) {
  const base = ["--readonly", "--no-input", "--account", account, "gmail"];
  return {
    async list(signal) {
      const { stdout } = await run("gog", [...base, "messages", "search", QUERY, "--max", String(MAX_MESSAGES), "--json", "--results-only"], signal);
      const parsed = JSON.parse(String(stdout));
      const listed = Array.isArray(parsed) ? parsed : parsed?.messages;
      return (Array.isArray(listed) ? listed : [])
        .map((message) => message?.id)
        .filter((id) => typeof id === "string" && MESSAGE_ID.test(id));
    },
    async raw(id, signal) {
      if (typeof id !== "string" || !MESSAGE_ID.test(id)) throw new Error("not a message id");
      const { stdout } = await run("gog", [...base, "get", id, "--format", "raw", "--json", "--results-only"], signal);
      const parsed = JSON.parse(String(stdout));
      const raw = parsed?.raw ?? parsed?.message?.raw;
      if (typeof raw !== "string") throw new Error("gog gave no raw message");
      return Buffer.from(raw, "base64url");
    },
  };
}
