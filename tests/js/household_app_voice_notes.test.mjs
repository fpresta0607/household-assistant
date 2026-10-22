// A person's voice note in the app, heard once on each gateway: in the family room it is
// answered by the assistant it names, as a typed mention is, and in either conversation
// the turn reads its words in place of the audio, and the owner's phone shows them under
// the note. Driven through the plugin's own entry on both gateways, Corey's with Franco's
// phone and Denise's with the same note arriving over the relay, with OpenClaw's mention
// rule standing in for its own and a stand-in speech-to-text.

import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { mkdir, mkdtemp, readFile, rename, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { signedText } from "../../deploy/openclaw/plugins/household-app/signature.js";
import { openRoomStore } from "../../deploy/openclaw/plugins/household-app/store.js";
import { createHearing, isNameSpoken } from "../../deploy/openclaw/plugins/household-app/voice-notes.js";
import { runningChannel, until } from "./fixtures/household-app-channel.mjs";

const keyPair = () => {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return { privateKey, raw: publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url") };
};
const FRANCO = keyPair();
const GIA = keyPair();
const signedBy = (person, message) => ({
  ...message,
  signature: sign(null, Buffer.from(signedText(message), "utf8"), person.privateKey).toString("base64url"),
});

const gateway = ({ owner, ownerKey, assistant, peerPerson, peerKey, peerAssistant }) => ({
  agents: { entries: { main: { identity: { name: assistant.name } } } },
  channels: {
    household: {
      owner: { ...owner, deviceKeys: [ownerKey] },
      assistant,
      peer: { person: { ...peerPerson, deviceKeys: [peerKey] }, assistant: peerAssistant },
    },
  },
});
const GATEWAYS = {
  corey: gateway({
    owner: { id: "franco", name: "Franco" }, ownerKey: FRANCO.raw, assistant: { id: "corey", name: "Corey" },
    peerPerson: { id: "gia", name: "Gia" }, peerKey: GIA.raw, peerAssistant: { id: "denise", name: "Denise" },
  }),
  denise: gateway({
    owner: { id: "gia", name: "Gia" }, ownerKey: GIA.raw, assistant: { id: "denise", name: "Denise" },
    peerPerson: { id: "franco", name: "Franco" }, peerKey: FRANCO.raw, peerAssistant: { id: "corey", name: "Corey" },
  }),
};

// OpenClaw 2026.9.4's own rule: the agent's name as a whole word, case aside, in the typed
// words, or in the transcript when there are none (matchesMentionWithExplicit).
const MENTION_RULE = {
  buildMentionRegexes: `(cfg) => [new RegExp("(?<![\\\\p{L}\\\\p{N}])" + cfg.agents.entries.main.identity.name + "(?![\\\\p{L}\\\\p{N}])", "iu")]`,
  matchesMentionWithExplicit: `({ text, mentionRegexes, transcript }) => { const check = (text ?? "").toLowerCase() || (transcript ?? "").toLowerCase(); return mentionRegexes.some((re) => re.test(check)); }`,
  implicitMentionKindWhen: `(kind, when) => (when ? [kind] : [])`,
  resolveInboundMentionDecision: `({ facts }) => ({ shouldSkip: !facts.wasMentioned && facts.implicitMentionKinds.length === 0 })`,
  formatAudioTranscriptForAgent: `(transcript) => "[Audio transcript (machine-generated, untrusted)]: " + JSON.stringify(transcript)`,
};
const forAgent = (words) => `[Audio transcript (machine-generated, untrusted)]: ${JSON.stringify(words)}`;

let sequence = 0;
// A voice note's bytes, its attachment as the phone describes it, and its message.
function voiceNote(conversation, label) {
  const bytes = Buffer.from(`voice note ${++sequence}: ${label}`);
  const note = { id: createHash("sha256").update(bytes).digest("hex"), kind: "voice", mime: "audio/mp4", bytes: bytes.length, durationMs: 3200 };
  const message = { conversation, id: `v-${String(sequence).padStart(8, "0")}`, at: Date.now(), replyTo: null, text: "", media: [note] };
  return { bytes, note, message };
}

// A channel whose speech-to-text says `said` for each media id, and lists every hearing.
async function channelHearing(gatewayName, said) {
  const heard = [];
  const channel = await runningChannel(GATEWAYS[gatewayName], {
    sdk: MENTION_RULE,
    async transcribeAudioFile({ filePath, mime, scopeContext }) {
      heard.push({ id: path.basename(filePath), mime, chatType: scopeContext.chatType });
      const words = said.get(path.basename(filePath));
      if (words instanceof Error) throw words;
      return { text: words };
    },
  });
  return { channel, heard };
}

async function keepMedia(channel, bytes, id) {
  await mkdir(path.join(channel.stateDir, "household-app", "media"), { recursive: true });
  await writeFile(path.join(channel.stateDir, "household-app", "media", id), bytes);
}

// What the host relay and relay-in.mjs leave for the other gateway: the attachment under
// its hash, then the batch in the plugin's inbox.
async function relay(channel, from, entries) {
  const inbox = path.join(channel.stateDir, "household-app", "inbox");
  await mkdir(inbox, { recursive: true });
  const temporary = path.join(inbox, ".batch.tmp");
  await writeFile(temporary, JSON.stringify({ from, batch: { entries } }));
  await rename(temporary, path.join(inbox, `${Date.now()}-${sequence}.json`));
}

const entriesOf = async (channel) => (await channel.call("household-app.sync", { since: 0 })).payload.entries;
const transcriptOf = async (channel, messageId) =>
  (await entriesOf(channel)).find((entry) => entry.kind === "transcript" && entry.messageId === messageId);
// A turn that is not started leaves nothing to wait for, so a note no assistant answers is
// judged once its words are kept and the rest of considering it, which awaits nothing
// more, has had its moment. One that is answered is judged when its turn starts.
const considered = async (channel, isAnswered) => {
  if (isAnswered) await until("the turn", () => channel.contexts.length > 0);
  else await new Promise((resolve) => setTimeout(resolve, 50));
};

const NOTES = [
  { said: "Corey, what's for dinner tonight?", answeredBy: ["corey"] },
  { said: "Denise, can you grab milk on the way home?", answeredBy: ["denise"] },
  // Franco asked both, so his own assistant gives the one answer and Denise stands down.
  { said: "Corey and Denise, are we free on Saturday?", answeredBy: ["corey"] },
  { said: "Running ten minutes late, start without me.", answeredBy: [] },
  // What OpenRouter's whisper-large-v3-turbo wrote for a spoken "Corey, what is the
  // weather like tomorrow morning?" on 17 October.
  { said: "Cory.  What is the weather like tomorrow morning?", answeredBy: ["corey"] },
  { said: "Denice, is the dentist at three?", answeredBy: ["denise"] },
];

for (const { said, answeredBy } of NOTES) {
  test(`Corey's gateway: Franco's family voice note "${said}" is answered by Corey only when it names him`, async () => {
    // Arrange
    const { bytes, note, message } = voiceNote("family", said);
    const { channel, heard } = await channelHearing("corey", new Map([[note.id, said]]));
    try {
      await keepMedia(channel, bytes, note.id);

      // Act
      const sent = await channel.send(signedBy(FRANCO, message));
      await until("the note's words", async () => (await transcriptOf(channel, message.id)) !== undefined);
      await considered(channel, answeredBy.includes("corey"));

      // Assert
      assert.equal(sent.ok, true);
      assert.deepEqual(heard, [{ id: note.id, mime: "audio/mp4", chatType: "group" }], "heard once, for the name and the turn alike");
      assert.equal(channel.contexts.length, answeredBy.includes("corey") ? 1 : 0);
      if (answeredBy.includes("corey")) {
        const [turn] = channel.contexts;
        assert.equal(turn.message.bodyForAgent, forAgent(said));
        assert.equal(turn.media[0].transcribed, true, "OpenClaw is told the note is heard, so it never hears it again");
        assert.equal(turn.sender.id, "franco");
        const isClaimed = /denise/i.test(said);
        assert.equal(/They asked Denise too, who leaves it to you/.test(turn.supplemental.groupSystemPrompt), isClaimed);
        if (isClaimed) {
          const outbox = path.join(channel.stateDir, "household-app", "outbox.json");
          await until("the claim in the outbox", async () => (await readFile(outbox, "utf8").catch(() => "")).includes('"claim"'));
          const { notes } = JSON.parse(await readFile(outbox, "utf8"));
          assert.deepEqual(notes.map((step) => [step.kind, step.message, step.for]), [["claim", message.id, "franco"]]);
        }
      }
    } finally {
      await channel.stop();
    }
  });

  test(`Denise's gateway: the same note over the relay, "${said}", is answered by Denise only when it names her`, async () => {
    // Arrange
    const { bytes, note, message } = voiceNote("family", said);
    const { channel, heard } = await channelHearing("denise", new Map([[note.id, said]]));
    try {
      await keepMedia(channel, bytes, note.id);

      // Act
      await relay(channel, "corey", [{ kind: "message", author: "franco", ...signedBy(FRANCO, message) }]);
      await until("the note's words", async () => (await transcriptOf(channel, message.id)) !== undefined);
      await considered(channel, answeredBy.includes("denise"));

      // Assert
      assert.equal(heard.length, 1);
      assert.equal(channel.contexts.length, answeredBy.includes("denise") ? 1 : 0);
      if (answeredBy.includes("denise")) {
        assert.equal(channel.contexts[0].message.bodyForAgent, forAgent(said));
        assert.equal(channel.contexts[0].sender.id, "franco");
      }
    } finally {
      await channel.stop();
    }
  });
}

test("a family voice note answers exactly as the same words typed would", async () => {
  // Arrange
  const said = "Corey, what's for dinner tonight?";
  const { bytes, note, message } = voiceNote("family", "spoken");
  const typed = { conversation: "family", id: "t-00000001", at: Date.now(), replyTo: null, text: said, media: [] };
  const { channel } = await channelHearing("corey", new Map([[note.id, said]]));
  try {
    await keepMedia(channel, bytes, note.id);

    // Act
    await channel.send(signedBy(FRANCO, typed));
    await until("the typed turn", () => channel.contexts.length === 1);
    await channel.send(signedBy(FRANCO, message));
    await until("the spoken turn", () => channel.contexts.length === 2);

    // Assert
    const [byText, byVoice] = channel.contexts;
    const shape = (turn) => ({ sender: turn.sender, conversation: turn.conversation, route: turn.route, reply: { to: turn.reply.to }, access: turn.access });
    assert.deepEqual(shape(byVoice), shape(byText));
    assert.equal(byText.message.bodyForAgent, said);
    assert.equal(byVoice.message.bodyForAgent, forAgent(said));
  } finally {
    await channel.stop();
  }
});

test("a voice note in the owner's own thread reaches the turn as its words, heard once, and the phone gets them", async () => {
  // Arrange
  const said = "Remind me to call the plumber at nine.";
  const { bytes, note, message } = voiceNote("direct", said);
  const { channel, heard } = await channelHearing("corey", new Map([[note.id, said]]));
  try {
    await keepMedia(channel, bytes, note.id);

    // Act
    await channel.send(signedBy(FRANCO, message));
    await until("the turn", () => channel.contexts.length === 1);

    // Assert
    assert.deepEqual(heard, [{ id: note.id, mime: "audio/mp4", chatType: "direct" }]);
    assert.equal(channel.contexts[0].message.bodyForAgent, forAgent(said));
    assert.equal(channel.contexts[0].media[0].transcribed, true);
    const transcript = await transcriptOf(channel, message.id);
    assert.deepEqual({ conversation: transcript.conversation, words: transcript.words }, { conversation: "direct", words: said });
  } finally {
    await channel.stop();
  }
});

test("a voice note's words come with the history page the phone reads, and stay this gateway's own", async () => {
  // Arrange
  const said = "Corey, are the kids' shoes in the car?";
  const { bytes, note, message } = voiceNote("family", said);
  const { channel } = await channelHearing("corey", new Map([[note.id, said]]));
  try {
    await keepMedia(channel, bytes, note.id);

    // Act
    await channel.send(signedBy(FRANCO, message));
    await until("the turn", () => channel.contexts.length === 1);
    const page = (await channel.call("household-app.history", { conversation: "family" })).payload;
    // The outbox is written a moment after each change, one write at a time.
    const outbox = async () => JSON.parse(await readFile(path.join(channel.stateDir, "household-app", "outbox.json"), "utf8").catch(() => '{"entries":[]}')).entries;
    await until("the note in the outbox", async () => (await outbox()).some((entry) => entry.id === message.id));

    // Assert
    assert.deepEqual(page.transcripts, { [message.id]: said });
    assert.equal((await outbox()).some((entry) => entry.kind === "transcript"), false, "the note crosses to the other gateway, its words never do");
  } finally {
    await channel.stop();
  }
});

test("a later turn's family history has an earlier voice note's words", async () => {
  // Arrange
  const said = "Dinner is at Nonna's on Sunday.";
  const { bytes, note, message } = voiceNote("family", said);
  const { channel } = await channelHearing("corey", new Map([[note.id, said]]));
  const asked = { conversation: "family", id: "t-00000002", at: Date.now() + 1, replyTo: null, text: "Corey, where is dinner Sunday?", media: [] };
  try {
    await keepMedia(channel, bytes, note.id);
    await channel.send(signedBy(FRANCO, message));
    await until("the note's words", async () => (await transcriptOf(channel, message.id)) !== undefined);

    // Act
    await channel.send(signedBy(FRANCO, asked));
    await until("the turn", () => channel.contexts.length === 1);

    // Assert
    const earlier = channel.contexts[0].message.inboundHistory.find((entry) => entry.messageId === message.id);
    assert.equal(earlier.body, `(voice note) ${said}`);
  } finally {
    await channel.stop();
  }
});

test("a voice note that cannot be heard still starts the owner's turn, with no words and nothing kept", async () => {
  // Arrange
  const { bytes, note, message } = voiceNote("direct", "unheard");
  const { channel, heard } = await channelHearing("corey", new Map([[note.id, new Error("speech-to-text is down")]]));
  try {
    await keepMedia(channel, bytes, note.id);

    // Act
    await channel.send(signedBy(FRANCO, message));
    await until("the turn", () => channel.contexts.length === 1);

    // Assert
    assert.equal(heard.length, 1);
    assert.equal(channel.contexts[0].message.bodyForAgent, "");
    assert.equal(channel.contexts[0].media[0].transcribed, undefined, "OpenClaw may still try the note itself");
    assert.equal(await transcriptOf(channel, message.id), undefined);
    assert.ok(channel.logs.some((line) => line === "household-app: a voice note could not be heard: speech-to-text is down"));
  } finally {
    await channel.stop();
  }
});

test("two that ask for a note's words while it is being heard share the one hearing", async () => {
  // Arrange
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-hearing-"));
  const store = openRoomStore(path.join(directory, "room.sqlite"));
  const { message } = voiceNote("family", "shared");
  store.addMessage({ ...message, author: "franco", origin: "local" });
  let finish;
  const transcribed = [];
  const hearing = createHearing({
    store,
    transcribe: (asked) => {
      transcribed.push(asked.id);
      return new Promise((resolve) => {
        finish = resolve;
      });
    },
    assistantId: "corey",
    heard: () => {},
    log: { warn() {} },
  });
  try {
    // Act
    const first = hearing.words(message);
    const second = hearing.words(message);
    await until("the hearing to start", () => finish !== undefined);
    finish("Pick up the dry cleaning.");
    const words = await Promise.all([first, second, hearing.words(message)]);

    // Assert
    assert.deepEqual(words, Array(3).fill("Pick up the dry cleaning."));
    assert.deepEqual(transcribed, [message.id]);
    assert.equal(store.transcript(message.id), "Pick up the dry cleaning.");
  } finally {
    store.close();
  }
});

test("a message with no voice note is never heard", async () => {
  // Arrange
  const hearing = createHearing({
    store: { transcript: () => assert.fail("no words to look up") },
    transcribe: () => assert.fail("nothing to hear"),
    assistantId: "corey",
    heard: () => {},
    log: { warn() {} },
  });

  // Act
  const words = await hearing.words({ id: "p-00000001", media: [{ id: "a".repeat(64), kind: "photo", mime: "image/jpeg" }] });

  // Assert
  assert.equal(words, "");
});

test("the other assistant's spoken reply that hands a request over is never heard: it carries its own words", async () => {
  // Arrange
  const { bytes, note, message } = voiceNote("family", "denise speaking");
  const handover = { ...message, text: "@Corey can you take this one?" };
  const { channel, heard } = await channelHearing("corey", new Map([[note.id, "@Corey can you take this one?"]]));
  try {
    await keepMedia(channel, bytes, note.id);

    // Act
    await relay(channel, "denise", [{ kind: "message", author: "denise", ...handover }]);
    await until("the handed-over turn", () => channel.contexts.length === 1);

    // Assert
    assert.deepEqual(heard, []);
    assert.equal(channel.contexts[0].message.bodyForAgent, "@Corey can you take this one?");
    assert.equal(channel.contexts[0].media[0].transcribed, undefined);
  } finally {
    await channel.stop();
  }
});

for (const [words, name, isSpoken] of [
  ["Cory.  What is the weather like tomorrow morning?", "Corey", true],
  ["Corey, what's for dinner?", "Corey", true],
  ["Corie, are you there?", "Corey", true],
  ["Hey Kori, quick one.", "Corey", true],
  ["Korey, the bins.", "Corey", true],
  ["Correy can you check?", "Corey", true],
  ["Is that on Corey's list?", "Corey", true],
  ["Denice, is the dentist at three?", "Denise", true],
  ["That's the core of it.", "Corey", false],
  ["Can you get the car?", "Corey", false],
  ["Carrie called earlier.", "Corey", false],
  ["He scored twice.", "Corey", false],
  ["Ask Dennis about it.", "Denise", false],
  ["Running ten minutes late.", "Denise", false],
  ["Mary, Jane, are you coming?", "Mary Jane", false],
]) {
  test(`"${words}" ${isSpoken ? "says" : "does not say"} ${name} as speech-to-text writes it`, () => {
    assert.equal(isNameSpoken(words, name), isSpoken);
  });
}
