// What a mention is in the family room, by the household's decision 1006757: an @ and a
// participant's display name, as the room lists them, inside the text the phone signs.
// So a mention needs no field of its own and changes nothing that is signed, and Corey
// and Denise write one the same way when they hand a request to each other. One matcher
// serves everything that asks: a phone's "mentions only" notifications here, and which
// assistant a family message is for.
//
// Case does not matter, and the name must end where the mention does, so "@Gia" mentions
// Gia and "@Giant" does not. An @ inside a word, as in an email address, is no mention.
//
// An assistant's Telegram bot counts as its name: a bot's username is letters, digits and
// underscores ending in "bot", so "@Denise_the_woman_bot" mentions Denise. Each assistant
// learned to write the other's bot in The Fam, and on 19 October Corey wrote it in the app's
// family room, where nobody is called that, so an assistant's words there say "@Denise",
// the mention a person's @ writes (withAppMentions). The app draws either the same way.

const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// The @ and `name`, or the name's Telegram bot, ending where the mention does.
const mentionOf = (name, flags) => new RegExp(`(?<![\\p{L}\\p{N}])@${escape(name)}(?:\\w*bot)?(?![\\p{L}\\p{N}])`, flags);

// True when `text` mentions someone called `name`.
export function isMentioned(text, name) {
  if (typeof text !== "string" || typeof name !== "string" || !name) return false;
  return mentionOf(name, "iu").test(text);
}

// True when `text` puts a question to someone called `name` by name, without an @: the name
// opens the question or closes it, as in "Denise - anything on your side?" or "Anything
// else, Denise?". On 22 October Corey asked Denise that way twice in the family room and she
// never answered, since only an @mention handed her a turn. A name inside a question is talk
// about someone ("did Denise log it?"), and a sentence that asks nothing hands over nothing.
// Emphasis marks around the name, as Markdown writes them, do not count.
export function isAskedByName(text, name) {
  if (typeof text !== "string" || typeof name !== "string" || !name) return false;
  const called = `@?${escape(name)}(?:\\w*bot)?`;
  const opens = new RegExp(`^(?:(?:hey|and|so|ok|okay|oh|also)[,\\s]+)?${called}\\s*[,:;\\-\\u2013\\u2014]`, "iu");
  const closes = new RegExp(`[,\\s]${called}\\s*\\?+$`, "iu");
  return text
    .replace(/[*_~`]/g, "")
    .split(/(?<=[.!?])\s+|\n+/u)
    .map((sentence) => sentence.trim())
    .some((sentence) => sentence.endsWith("?") && (opens.test(sentence) || closes.test(sentence)));
}

// The ids of the participants `text` mentions, in the order the room lists them.
export function mentionedIds(text, participants) {
  return participants.filter((who) => isMentioned(text, who.name)).map((who) => who.id);
}

// An assistant's words for the app, each mention of one of `names`'s Telegram bots written
// as the app's mention of that name.
export function withAppMentions(text, names) {
  return names.reduce(
    (words, name) => words.replace(new RegExp(`(?<![\\p{L}\\p{N}])@${escape(name)}\\w*bot(?![\\p{L}\\p{N}_])`, "giu"), `@${name}`),
    text,
  );
}
