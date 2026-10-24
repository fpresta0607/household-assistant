// Speech in Steward is asked for, never sent: a person long-presses a message and chooses
// Speak, or starts a call, and speak.js makes both under its own day ceiling. No chat tool
// makes a voice note. This moved here from the household-speech plugin when Telegram, the
// one channel its voice notes went to, was retired.
//
// - OpenClaw's own `tts` tool is refused if a config ever hands it back to the model, and
//   so is household-speech's `speak`, should a config still name it.
// - `/tts` typed in a chat is answered with how to hear a message, so the built-in `/tts
//   on`, which would speak every reply with no ceiling, cannot be reached from a chat. It is
//   claimed in before_dispatch, which runs ahead of the built-in command.
// - Every turn is told to reply in text, since the model has been seen to plan a spoken
//   answer when someone asks for a voice note.

export const SPEECH_TOOLS = ["tts", "speak"];
export const HOW_TO_HEAR = "To hear a message in Steward, long-press it and choose Speak. For a conversation aloud, start a call.";
export const REPLY_IN_TEXT = `Reply in text in Steward chat. Do not call speak or tts or send generated voice notes. If asked to read a chat message aloud, explain: ${HOW_TO_HEAR}`;
// `/tts` at the start of a message, with a bot's name on it or not. OpenClaw takes a colon
// between a command and its words, so this does too.
const TTS_COMMAND = /^\/tts(?:@[^\s:]+)?(?::|\s|$)/i;

export function refuseSpeechTool(event) {
  return SPEECH_TOOLS.includes(event?.toolName) ? { block: true, blockReason: HOW_TO_HEAR } : undefined;
}

// Every `/tts` is claimed: one let through would be spoken by the built-in with no ceiling.
export function claimTtsCommand(event) {
  return TTS_COMMAND.test(String(event?.content ?? "").trim()) ? { handled: true, text: HOW_TO_HEAR } : undefined;
}
