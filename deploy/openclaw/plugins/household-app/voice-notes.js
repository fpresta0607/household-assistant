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
