// Tapbacks, as Messages has them: the five reactions a long press offers in the app, a
// heart, a thumbs up, a laugh, two exclamation marks and a question mark. They are also the
// only reactions an assistant gives (react-tool.js), so its reactions read as a person's.
//
// A person's reaction to one of this assistant's messages is told to the assistant as one
// quiet line on its next turn in that conversation, through OpenClaw's next-turn injection,
// the way a checklist tick is (cards.js). It never starts a turn or a reply: the line waits
// for whatever turn comes next there.

// ❤️ 👍 😂 ‼️ ❓, each spelled as the emoji keyboard sends it.
export const TAPBACKS = ["❤️", "\u{1F44D}", "\u{1F602}", "‼️", "❓"];

// How much of the message the line quotes, in characters, so the assistant knows which one.
const QUOTED_CHARACTERS = 60;
const MEDIA_NAMES = { voice: "voice note", photo: "photo", video: "video", file: "file" };

// The start of a message as a person would quote it: its words without any fenced block,
// such as a card's JSON, on one line, and cut at a word when it runs on.
function firstWords(text) {
  const words = String(text ?? "").replace(/```[\s\S]*?(?:```|$)/g, " ").replace(/\s+/g, " ").trim();
  const characters = [...words];
  if (characters.length <= QUOTED_CHARACTERS) return words;
  const cut = characters.slice(0, QUOTED_CHARACTERS).join("");
  const space = cut.lastIndexOf(" ");
  return `${space > 0 ? cut.slice(0, space) : cut}…`;
}

// What the assistant is told when `name` reacts with `emoji` to its `message`, or takes
// `previous` back when `emoji` is null: what happened on one line, and on the next that it
// asks for nothing.
export function reactionNote({ name, emoji, previous, message }) {
  const quoted = firstWords(message.text);
  const what = quoted ? `your message: "${quoted}"` : `your ${MEDIA_NAMES[message.media?.[0]?.kind] ?? "message"}`;
  const said = emoji ? `${name} reacted ${emoji} to ${what}` : `${name} took back their ${previous} on ${what}`;
  return `${said}\nIt is a reaction in the app, not a message, so it needs no answer.`;
}
