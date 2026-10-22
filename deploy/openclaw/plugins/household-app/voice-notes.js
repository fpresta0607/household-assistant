// A person's voice note, heard once on this gateway. Its words are kept with the message
// (store.js), so the phone shows them under the note, the assistant's turn reads them in
// place of the audio, and the family room's history has them, however many of those ask
// and across restarts. Two that ask while the note is being heard share the one hearing.
//
// OpenClaw cannot hear an app voice note for a turn itself: it reads attachments only from
// its own media folders, and the app keeps its media in this plugin's. So this is the one
// place an app voice note is ever transcribed.
//
// Only a person's note is asked about: an assistant's spoken reply carries its own words.
// Nothing heard here is relayed. Each gateway hears the family room's notes for itself,
// since words the other gateway wrote would be the other assistant's to put in a
// person's mouth, and the audio, which the person's phone signed, is not.
//
// A note that could not be heard, or held no words, keeps nothing, and is heard again
// only when something asks again.

// Whether `words`, as speech-to-text wrote them, say `name`. Speech-to-text writes a name
// as it sounds, so a spoken Corey comes back as Cory as often as Corey (OpenRouter's
// whisper-large-v3-turbo on 17 October), and also as Corie, Kori or Correy, and Denise as
// Denice. So a word counts when it is the name up to those spellings: a k for a leading c,
// a doubled consonant, an ending in -ey, -y, -ie, -i or -ee, and -ce for -se. Core, car
// and Dennis are not Corey or Denise. A name of more than one word counts only as typed,
// through OpenClaw's own rule.
export function isNameSpoken(words, name) {
  const key = (word) => word.toLowerCase()
    .replace(/^k/, "c")
    .replace(/([b-df-hj-np-tv-z])\1/g, "$1")
    .replace(/(?:ey|ie|ee|i|y)$/, "y")
    .replace(/ce$/, "se");
  const wanted = key(name);
  return (String(words).match(/\p{L}+/gu) ?? []).some((word) => key(word) === wanted);
}

// A turn started by a person's voice note. The family lives in voice notes, so a weigh-in or a
// grocery list said aloud is logged as it is, rows in the household note or items in the
// cart, and answered with one line: no re-reading, no transcription chore. Speech-to-text
// mishears a number or a name now and then, so the one unclear value is asked about, never
// guessed. It is an instruction only: no model call is added for it.
export const VOICE_NOTE_INSTRUCTION = [
  "This message is a voice note, and you have its words as speech-to-text wrote them.",
  "When it gives something the family keeps track of, such as a weigh-in, a reading, a dose or a list, log it at once, in one call: household_note add with rows, one row per item, or household_cart add with list for things to buy.",
  "If one value is unclear in the words, such as a number misheard or a name that is no one's, never guess it: give that row with unsure saying what you heard, log the rest, and ask about that one value alone in a short question.",
  "Then answer in one line that says what you logged, such as \"logged 7 kittens, Day 17\", plus that one question when there is one, and nothing else.",
].join(" ");

export function createHearing({ store, transcribe, assistantId, heard, log, now = Date.now }) {
  const hearing = new Map();

  async function hear(message, voice) {
    let words = "";
    try {
      words = String((await transcribe(message, voice)) ?? "").trim();
    } catch (error) {
      log.warn(`household-app: a voice note could not be heard: ${error?.message ?? error}`);
      return "";
    }
    if (!words) return "";
    const entry = store.setTranscript({ messageId: message.id, author: assistantId, words, at: now() });
    if (entry) heard(entry);
    return words;
  }

  return {
    // The words of `message`'s voice note: "" when it has none or none were heard, so a
    // note that cannot be heard leaves a turn its other words.
    async words(message) {
      const voice = message.media.find((item) => item.kind === "voice");
      if (!voice) return "";
      const kept = store.transcript(message.id);
      if (kept !== null) return kept;
      if (!hearing.has(message.id)) {
        hearing.set(message.id, hear(message, voice).finally(() => hearing.delete(message.id)));
      }
      return hearing.get(message.id);
    },
  };
}
