import assert from "node:assert/strict";
import test from "node:test";

import { isAskedByName, isMentioned, mentionedIds, withAppMentions } from "../../deploy/openclaw/plugins/household-app/mentions.js";

const ROOM = [
  { id: "franco", name: "Franco" },
  { id: "gia", name: "Gia" },
  { id: "corey", name: "Corey" },
  { id: "denise", name: "Denise" },
];

for (const [text, isAsked] of [
  ["Denise - anything on your side that I'd miss because it's Gia's?", true],
  ["Here are the numbers.\nDenise, did you log them too?", true],
  ["**Denise** — anything to add?", true],
  ["Hey Denise: what time is church?", true],
  ["Anything else, Denise?", true],
  ["@Denise, anything else?", true],
  ["Did Denise log it?", false],
  ["Denise, Gia says we need milk.", false],
  ["Denise's list is done?", false],
  ["Denisea, are you there?", false],
  ["", false],
]) {
  test(`${JSON.stringify(text)} ${isAsked ? "asks" : "does not ask"} Denise by name`, () => {
    assert.equal(isAskedByName(text, "Denise"), isAsked);
  });
}

for (const [text, name, isExpected] of [
  ["@Corey can you check?", "Corey", true],
  ["can you check, @corey", "Corey", true],
  ["@COREY!", "Corey", true],
  ["(@Denise)", "Denise", true],
  ["Corey can you check?", "Corey", false],
  ["@Coreys list", "Corey", false],
  ["@Giant pumpkins", "Gia", false],
  ["mail franco@example.com", "example", false],
  ["mail franco@Gia", "Gia", false],
  ["", "Gia", false],
  // An assistant's Telegram bot, which the other assistant learned to write in The Fam.
  ["@Denise_the_woman_bot can you check?", "Denise", true],
  ["ask @corey_the_man_bot.", "Corey", true],
  ["@DeniseBot?", "Denise", true],
  ["@Denisebotany notes", "Denise", false],
]) {
  test(`"${text}" ${isExpected ? "mentions" : "does not mention"} ${name}`, () => {
    assert.equal(isMentioned(text, name), isExpected);
  });
}

test("a name with a dot or a bracket is matched as written, not as a pattern", () => {
  assert.equal(isMentioned("@J.R. are you there?", "J.R."), true);
  assert.equal(isMentioned("@JxR are you there?", "J.R."), false);
});

test("nothing is mentioned by a missing text or name", () => {
  assert.equal(isMentioned(undefined, "Gia"), false);
  assert.equal(isMentioned("@Gia", ""), false);
  assert.equal(isMentioned("@Gia", undefined), false);
});

test("the room's participants a message mentions come back in the room's order", () => {
  assert.deepEqual(mentionedIds("@Denise and @Franco, ask @corey", ROOM), ["franco", "corey", "denise"]);
  assert.deepEqual(mentionedIds("no one here", ROOM), []);
});

// What an assistant writes in the app (19 October): Corey wrote "@Denise_the_woman_bot" in the
// family room, which no one there is called, where a person's @ writes "@Denise".
for (const [written, shown] of [
  ["That one is Gia's. @Denise_the_woman_bot is she free?", "That one is Gia's. @Denise is she free?"],
  ["@corey_the_man_bot, over to you", "@Corey, over to you"],
  ["@Denise_the_woman_bot's list and @Corey_the_man_bot", "@Denise's list and @Corey"],
  ["@DeniseBot", "@Denise"],
  ["@Denise is already the app's mention", "@Denise is already the app's mention"],
  ["@Denise_the_woman_botany is not a bot", "@Denise_the_woman_botany is not a bot"],
  ["mail franco@Denise_the_woman_bot.example", "mail franco@Denise_the_woman_bot.example"],
  ["@Gia_bot is not an assistant", "@Gia_bot is not an assistant"],
]) {
  test(`an assistant's "${written}" reads "${shown}" in the app`, () => {
    assert.equal(withAppMentions(written, ["Corey", "Denise"]), shown);
  });
}

test("an assistant's Telegram bot still mentions it in the app", () => {
  assert.deepEqual(mentionedIds("@Denise_the_woman_bot is Gia free Saturday?", ROOM), ["denise"]);
});

test("a name with a dot is rewritten as written, not as a pattern", () => {
  assert.equal(withAppMentions("@J.R._bot and @JxR_bot", ["J.R."]), "@J.R. and @JxR_bot");
});
