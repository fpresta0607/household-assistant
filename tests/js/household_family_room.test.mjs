// The gateway half of the family room, the household-family-room OpenClaw plugin.
//
// Run with `node --test tests/js`. tests/test_family_room_plugin.py runs it under
// pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { copyFile, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import plugin, {
  audioType,
  createFamilyRoom,
  parseConfig,
} from "../../deploy/openclaw/plugins/household-family-room/index.js";

const GROUP = "-5100000001";
const FAMILY_SESSION = `agent:main:telegram:group:${GROUP}`;
const HOUR = 3_600_000;
const START = Date.UTC(2026, 9, 6, 23, 0);

function fakeApi({ transcript = "Can somebody grab milk on the way home?", fail = false, agentId = "main" } = {}) {
  const calls = [];
  const looked = [];
  const scopeContexts = [];
  const warnings = [];
  return {
    calls,
    looked,
    scopeContexts,
    warnings,
    logger: { info() {}, warn: (message) => warnings.push(message), error() {} },
    runtime: {
      config: { current: () => ({}) },
      mediaUnderstanding: {
        async transcribeAudioFile(params) {
          calls.push(params);
          scopeContexts.push(["audio", params.scopeContext]);
          if (fail) throw new Error("OpenRouter audio transcription failed (402)");
          return { text: transcript };
        },
        async describeImageFile(params) {
          assert.equal(params.agentId, agentId);
          looked.push(["photo", params.filePath]);
          scopeContexts.push(["image", params.scopeContext]);
          if (fail) throw new Error("Image model failed (402)");
          return { text: "A receipt from the grocery store totalling $42." };
        },
        async describeVideoFile(params) {
          assert.equal(params.agentId, agentId);
          looked.push(["video", params.filePath]);
          scopeContexts.push(["video", params.scopeContext]);
          if (fail) throw new Error("Video model failed (402)");
          return { text: "A dog catches a red ball in a park." };
        },
      },
    },
  };
}

function groupMedia({ messageId, content, media }) {
  return {
    type: "message",
    action: "received",
    sessionKey: FAMILY_SESSION,
    context: {
      content,
      timestamp: START - 30_000,
      channelId: "telegram",
      conversationId: `telegram:${GROUP}`,
      messageId,
      media,
      metadata: { senderName: "Gia Marlowe", senderId: "7100000002" },
    },
  };
}

async function room(options = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "family-room-"));
  const clock = { now: START };
  const api = fakeApi(options);
  const value = parseConfig({ groupChatId: GROUP, ...(options.config ?? {}) }).value;
  const handlers = createFamilyRoom(api, value, { directory, now: () => clock.now });
  return { api, clock, directory, handlers };
}

function skippedVoiceNote({ session = FAMILY_SESSION, messageId = "302", content = "<media:audio>", media } = {}) {
  return {
    type: "message",
    action: "received",
    sessionKey: session,
    context: {
      from: `telegram:group:${GROUP}`,
      content,
      timestamp: START - 60_000,
      channelId: "telegram",
      conversationId: `telegram:${GROUP}`,
      messageId,
      media: media ?? [
        { path: "/state/media/inbound/note.ogg", contentType: "application/ogg", kind: "audio", messageId },
      ],
      metadata: { senderName: "Franco Marlowe", senderId: "7100000001" },
    },
  };
}

function respondInto(answers) {
  return (ok, payload, error) => answers.push({ ok, payload, error });
}

async function prompt(handlers, sessionKey = FAMILY_SESSION) {
  return handlers.beforePromptBuild({ prompt: "", messages: [] }, { sessionKey });
}

test("the config needs the group and nothing it does not know", () => {
  assert.deepEqual(parseConfig({ groupChatId: GROUP }).value, { groupChatId: GROUP });
  assert.match(parseConfig({}).error, /groupChatId/);
  assert.match(parseConfig({ groupChatId: -5100000001 }).error, /groupChatId/);
  assert.match(parseConfig({ groupChatId: "the fam" }).error, /groupChatId/);
  assert.match(parseConfig({ groupChatId: GROUP, peer: "Corey" }).error, /unknown config keys: peer/);
  // The window is a day, not a setting.
  assert.match(parseConfig({ groupChatId: GROUP, hours: 6 }).error, /unknown config keys: hours/);
  assert.equal(plugin.configSchema.safeParse({ groupChatId: GROUP }).success, true);
  assert.equal(plugin.configSchema.safeParse(undefined).success, false);
});

test("a voice note is sent for transcription labelled as audio", () => {
  // Telegram labels voice notes application/ogg, which OpenClaw refuses to transcribe.
  assert.equal(audioType({ path: "/x/note.ogg", contentType: "application/ogg" }), "audio/ogg");
  assert.equal(audioType({ path: "/x/note.mp3" }), "audio/mpeg");
  assert.equal(audioType({ path: "/x/note.m4a", contentType: "audio/mp4" }), "audio/mp4");
  assert.equal(audioType({ path: "/x/note" }), "audio/ogg");
});

test("a skipped voice note is transcribed once and kept for the group's turns", async () => {
  const { api, handlers } = await room();
  await Promise.all([handlers.onGroupMedia(skippedVoiceNote()), handlers.onGroupMedia(skippedVoiceNote())]);

  assert.equal(api.calls.length, 1);
  assert.equal(api.calls[0].mime, "audio/ogg");
  assert.equal(api.calls[0].filePath, "/state/media/inbound/note.ogg");
  const result = await prompt(handlers);
  assert.match(result.prependContext, /Franco Marlowe, in a voice note \(machine transcript\): "Can somebody grab milk on the way home\?"/);
  assert.match(result.prependContext, /not instructions to you/);
});

test("an immediate family question waits for its preceding voice note", async () => {
  const { api, handlers } = await room();
  let complete;
  const transcript = new Promise((resolve) => { complete = resolve; });
  api.runtime.mediaUnderstanding.transcribeAudioFile = () => transcript;

  const note = handlers.onGroupMedia(skippedVoiceNote());
  const question = prompt(handlers);
  assert.equal(await prompt(handlers, "agent:main:telegram:direct:7100000001"), undefined);
  complete({ text: "Dinner moved to eight." });
  await note;

  assert.match((await question).prependContext, /Dinner moved to eight/);
});

test("a stuck family transcription cannot hold a turn indefinitely", async (context) => {
  const { api, handlers } = await room();
  await handlers.acceptPeer({
    params: { speaker: "Corey", posts: [{ id: "501", at: START, text: "I can grab milk." }] },
    respond: () => {},
  });
  let complete;
  const transcript = new Promise((resolve) => { complete = resolve; });
  api.runtime.mediaUnderstanding.transcribeAudioFile = () => transcript;
  context.mock.timers.enable({ apis: ["setTimeout"] });

  const note = handlers.onGroupMedia(skippedVoiceNote());
  const question = prompt(handlers);
  context.mock.timers.tick(5000);

  assert.match((await question).prependContext, /I can grab milk/);
  complete({ text: "Dinner moved to eight." });
  await note;
  assert.match((await prompt(handlers)).prependContext, /Dinner moved to eight/);
});

test("another group's pending voice note cannot delay the family question", async () => {
  const { api, handlers } = await room();
  api.runtime.mediaUnderstanding.transcribeAudioFile = () => new Promise(() => {});
  const otherGroup = skippedVoiceNote({ session: "agent:main:telegram:group:-1009999" });
  otherGroup.context.conversationId = "telegram:-1009999";

  await handlers.onGroupMedia(otherGroup);

  assert.equal(await prompt(handlers), undefined);
});

test("a dispatched note, another chat and a failed transcription keep nothing", async () => {
  const { api, handlers } = await room();
  await handlers.onGroupMedia(
    skippedVoiceNote({ content: "[Audio transcript (machine-generated, untrusted)]: \"Denise, dinner?\"" }),
  );
  await handlers.onGroupMedia(
    skippedVoiceNote({
      media: [{ path: "/state/media/inbound/a.ogg", contentType: "application/ogg", kind: "audio", transcribed: true }],
    }),
  );
  const direct = skippedVoiceNote({ session: "agent:main:telegram:direct:7100000001" });
  direct.context.conversationId = "telegram:7100000001";
  await handlers.onGroupMedia(direct);
  const otherGroup = skippedVoiceNote({ session: "agent:main:telegram:group:-1009999" });
  otherGroup.context.conversationId = "telegram:-1009999";
  await handlers.onGroupMedia(otherGroup);
  assert.equal(api.calls.length, 0);
  assert.equal(await prompt(handlers), undefined);

  const failing = await room({ fail: true });
  await failing.handlers.onGroupMedia(skippedVoiceNote());
  assert.equal(await prompt(failing.handlers), undefined);
  assert.match(failing.api.warnings[0], /could not read a voice/);
});

test("only the assistant's own turns in the group go to the outbox", async () => {
  const { directory, handlers } = await room();
  const sent = (sessionKey, extra = {}) =>
    handlers.onSent(
      {
        type: "message", action: "sent", sessionKey,
        context: { to: `telegram:${GROUP}`, content: "I can grab the milk.", success: true,
          messageId: "501", channelId: "telegram", conversationId: `telegram:${GROUP}`, ...extra },
      },
    );

  await sent(FAMILY_SESSION);
  await sent(FAMILY_SESSION); // the same message reported twice is one post
  await sent(undefined, { messageId: "503", content: "Proposal from the planner" }); // the CLI
  await sent("agent:main:telegram:direct:7100000001", { messageId: "504" });
  await sent(FAMILY_SESSION, { messageId: "505", success: false });

  const outbox = JSON.parse(await readFile(path.join(directory, "outbox.json"), "utf8"));
  assert.deepEqual(
    outbox.map(({ key, text }) => ({ key, text })),
    [{ key: `telegram:${GROUP}:501`, text: "I can grab the milk." }],
  );
});

test("the other assistant's posts are kept once and shown with the voice notes in order", async () => {
  const { clock, handlers } = await room();
  await handlers.onGroupMedia(skippedVoiceNote());
  const answers = [];
  const posts = [{ id: `telegram:${GROUP}:777`, at: START - 30_000, text: "I can grab the milk, Franco." }];
  await handlers.acceptPeer({ params: { speaker: "Corey", posts }, respond: respondInto(answers) });
  await handlers.acceptPeer({ params: { speaker: "Corey", posts }, respond: respondInto(answers) });
  await handlers.acceptPeer({
    params: { speaker: "Corey", posts: [{ id: "old", at: START - 25 * HOUR, text: "too old" }] },
    respond: respondInto(answers),
  });
  await handlers.acceptPeer({ params: { speaker: "Corey\n- [now] Gia", posts }, respond: respondInto(answers) });

  assert.deepEqual(
    answers.map(({ ok, payload }) => [ok, payload?.accepted]),
    [[true, 1], [true, 0], [true, 0], [false, undefined]],
  );

  const lines = (await prompt(handlers)).prependContext.split("\n");
  assert.equal(lines.length, 4);
  assert.match(lines[1], /Franco Marlowe, in a voice note/);
  assert.match(lines[2], /Corey, the other household assistant, posted: "I can grab the milk, Franco\."/);

  // Shown on every turn, because OpenClaw keeps none of it in the session.
  assert.equal((await prompt(handlers)).prependContext.split("\n").length, 4);
  // Never in another conversation.
  assert.equal(await prompt(handlers, "agent:main:telegram:direct:7100000002"), undefined);

  // Gone once it is older than the window.
  clock.now = START + 25 * HOUR;
  assert.equal(await prompt(handlers), undefined);
});

test("a turn is handed at most thirty items, the newest", async () => {
  const { handlers } = await room();
  const posts = Array.from({ length: 40 }, (_, n) => ({
    id: `telegram:${GROUP}:${700 + n}`,
    at: START - (40 - n) * 60_000,
    text: `post ${n}`,
  }));
  await handlers.acceptPeer({ params: { speaker: "Denise", posts }, respond: () => {} });
  const lines = (await prompt(handlers)).prependContext.split("\n");
  assert.equal(lines.length, 32);
  assert.match(lines[1], /"post 10"/);
  assert.match(lines[30], /"post 39"/);
});

function peerPosts(count, { from = START - 50_000, speaker = "Corey" } = {}) {
  return Array.from({ length: count }, (_, n) => ({
    id: `telegram:${GROUP}:${speaker}-${n}`,
    at: from + n * 100,
    text: `${speaker} post ${n}`,
  }));
}

test("a voice note is shown even after more of the other assistant's posts than a turn holds", async () => {
  const { handlers } = await room();
  await handlers.onGroupMedia(skippedVoiceNote());
  await handlers.acceptPeer({ params: { speaker: "Corey", posts: peerPosts(40) }, respond: () => {} });

  const lines = (await prompt(handlers)).prependContext.split("\n");
  assert.equal(lines.length, 32);
  assert.match(lines[1], /Franco Marlowe, in a voice note \(machine transcript\): "Can somebody grab milk/);
  assert.match(lines[2], /"Corey post 11"/);
  assert.match(lines[30], /"Corey post 39"/);
});

test("a voice note is kept even after more of the other assistant's posts than are kept", async () => {
  const { directory, handlers } = await room();
  await handlers.onGroupMedia(skippedVoiceNote());
  const posts = peerPosts(150);
  for (let start = 0; start < posts.length; start += 50) {
    await handlers.acceptPeer({
      params: { speaker: "Corey", posts: posts.slice(start, start + 50) },
      respond: () => {},
    });
  }

  const kept = JSON.parse(await readFile(path.join(directory, "room.json"), "utf8"));
  assert.equal(kept.length, 120);
  assert.equal(kept.filter((record) => record.kind === "voice").length, 1);
  assert.match((await prompt(handlers)).prependContext, /Franco Marlowe, in a voice note/);
});

const MEDIA_DIRECTORY = await mkdtemp(path.join(tmpdir(), "family-room-media-"));
const PHOTO = { path: path.join(MEDIA_DIRECTORY, "receipt.jpg"), contentType: "image/jpeg", kind: "image" };
const SECOND_PHOTO = { ...PHOTO, path: path.join(MEDIA_DIRECTORY, "second.jpg") };
const VIDEO = { path: path.join(MEDIA_DIRECTORY, "clip.mp4"), contentType: "video/mp4", kind: "video" };
const SECOND_VIDEO = { ...VIDEO, path: path.join(MEDIA_DIRECTORY, "second.mp4") };
await Promise.all([
  writeFile(PHOTO.path, "abc"),
  writeFile(SECOND_PHOTO.path, "hello"),
  writeFile(VIDEO.path, "test"),
  writeFile(SECOND_VIDEO.path, ""),
]);

test("a photo or video in the group is described once and shown with its caption", async () => {
  const { api, handlers } = await room();
  const photo = groupMedia({ messageId: "410", content: "Look what I found", media: [PHOTO] });
  await Promise.all([handlers.onGroupMedia(photo), handlers.onGroupMedia(photo)]);
  await handlers.onGroupMedia(groupMedia({ messageId: "411", content: "<media:video>", media: [VIDEO] }));

  assert.deepEqual(api.looked, [["photo", PHOTO.path], ["video", VIDEO.path]]);
  const lines = (await prompt(handlers)).prependContext.split("\n");
  assert.equal(lines.length, 4);
  assert.match(
    lines[1],
    /Gia Marlowe sent a photo, captioned "Look what I found" \(machine description\): "A receipt from the grocery store totalling \$42\."/,
  );
  assert.match(lines[2], /Gia Marlowe sent a video \(machine description\): "A dog catches a red ball in a park\."/);
});

for (const agentId of ["corey", "denise"]) {
  test(`photos and videos use the ${agentId} agent from the hook session`, async () => {
    const { api, handlers } = await room({ agentId });
    const event = groupMedia({ messageId: "415", content: `${agentId}, what is this?`, media: [PHOTO, VIDEO] });
    event.sessionKey = `agent:${agentId}:telegram:group:${GROUP}:topic:7`;

    await handlers.onGroupMedia(event);

    assert.deepEqual(api.looked.toSorted(), [["photo", PHOTO.path], ["video", VIDEO.path]]);
    assert.equal((await prompt(handlers, event.sessionKey)).prependContext.split("\n").length, 4);
  });
}

test("audio, photo and video requests carry the hook's family group scope", async () => {
  const { api, handlers } = await room({ agentId: "denise" });
  const event = skippedVoiceNote({
    session: `agent:denise:telegram:group:${GROUP}:topic:7`,
    media: [{ path: "/state/media/inbound/note.ogg", kind: "audio" }, PHOTO, VIDEO],
  });

  await handlers.onGroupMedia(event);

  const expectedScope = {
    sessionKey: `agent:denise:telegram:group:${GROUP}:topic:7`,
    channel: "telegram",
    chatType: "group",
  };
  assert.deepEqual(api.scopeContexts.toSorted(), [
    ["audio", expectedScope],
    ["image", expectedScope],
    ["video", expectedScope],
  ]);
  assert.equal(api.calls.length, 1);
  assert.equal(api.looked.length, 2);
});

test("a hook without an agent identity does not request descriptions", async () => {
  const { api, handlers } = await room();
  const event = groupMedia({ messageId: "416", content: "<media:image>", media: [PHOTO, VIDEO] });
  delete event.sessionKey;

  await handlers.onGroupMedia(event);

  assert.deepEqual(api.looked, []);
  assert.equal(await prompt(handlers), undefined);
});

for (const representation of ["kind", "contentType"]) {
  test(`media identified only by ${representation} are described`, async () => {
    const { api, handlers } = await room();
    const attachments = [PHOTO, VIDEO].map((file) => ({ path: file.path, [representation]: file[representation] }));

    await handlers.onGroupMedia(groupMedia({ messageId: "417", content: "<media:image>", media: attachments }));

    assert.deepEqual(api.looked.toSorted(), [["photo", PHOTO.path], ["video", VIDEO.path]]);
    assert.equal((await prompt(handlers)).prependContext.split("\n").length, 4);
  });
}

for (const content of ["<media:image> (4 attachments)", "Denise, look at this album"]) {
  test(`every photo and video in an album is kept once: ${content}`, async () => {
    const { api, directory, handlers } = await room();
    const attachments = [
      { ...PHOTO, messageId: "420" },
      { ...SECOND_PHOTO, messageId: "421" },
      { ...VIDEO, messageId: "422" },
      { ...SECOND_VIDEO, messageId: "423" },
    ];
    const album = groupMedia({ messageId: "420", content, media: attachments });

    await Promise.all([handlers.onGroupMedia(album), handlers.onGroupMedia(album)]);
    await handlers.onGroupMedia(groupMedia({ messageId: "421", content, media: [attachments[1]] }));

    assert.deepEqual(api.looked.toSorted(), attachments.map((file) => [file.kind === "image" ? "photo" : "video", file.path]).sort());
    const records = JSON.parse(await readFile(path.join(directory, "room.json"), "utf8"));
    assert.deepEqual(records.map(({ key }) => key), [
      "photo:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
      "photo:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      "video:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
      "video:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    ]);
    assert.equal((await prompt(handlers)).prependContext.split("\n").length, 6);
  });
}

test("different photos without message IDs keep distinct bounded content keys", async () => {
  const { api, directory, handlers } = await room();
  const attachments = [PHOTO, SECOND_PHOTO];
  const album = groupMedia({ messageId: "424", content: "<media:image>", media: attachments });

  await Promise.all([handlers.onGroupMedia(album), handlers.onGroupMedia(album)]);

  assert.deepEqual(api.looked.toSorted(), [["photo", PHOTO.path], ["photo", SECOND_PHOTO.path]].sort());
  const records = JSON.parse(await readFile(path.join(directory, "room.json"), "utf8"));
  assert.equal(records.length, 2);
  assert.ok(records.every(({ key }) => key.length <= 200));
  assert.equal((await prompt(handlers)).prependContext.split("\n").length, 4);
});

for (const attachment of [PHOTO, VIDEO]) {
  test(`a reply quoting retained ${attachment.kind} bytes adds no description or record`, async () => {
    const { api, directory, handlers } = await room();
    const original = groupMedia({ messageId: "410", content: "Look what I found", media: [{ ...attachment, messageId: "410" }] });
    await handlers.onGroupMedia(original);
    const kept = JSON.parse(await readFile(path.join(directory, "room.json"), "utf8"));
    const copiedPath = path.join(directory, "quoted-copy");
    await copyFile(attachment.path, copiedPath);
    const reply = groupMedia({ messageId: "430", content: "Denise, what do you think?", media: [{ ...attachment, path: copiedPath }] });
    reply.context.metadata.senderName = "Franco Marlowe";
    reply.context.timestamp = START;

    await handlers.onGroupMedia(reply);

    assert.equal(api.looked.length, 1);
    assert.deepEqual(JSON.parse(await readFile(path.join(directory, "room.json"), "utf8")), kept);
    assert.equal(kept.length, 1);
    assert.equal(kept[0].speaker, "Gia Marlowe");
    assert.equal(kept[0].caption, "Look what I found");
    assert.equal(kept[0].at, START - 30_000);
    assert.doesNotMatch((await prompt(handlers)).prependContext, /Franco Marlowe|what do you think/);
  });
}

test("concurrent copies of the same video share one in-flight description", { timeout: 5000 }, async () => {
  const { api, directory, handlers } = await room();
  const copiedPath = path.join(directory, "video-copy.mp4");
  await copyFile(VIDEO.path, copiedPath);
  let complete;
  let start;
  const description = new Promise((resolve) => { complete = resolve; });
  const started = new Promise((resolve) => { start = resolve; });
  const describeVideo = api.runtime.mediaUnderstanding.describeVideoFile;
  api.runtime.mediaUnderstanding.describeVideoFile = async (params) => {
    const result = await describeVideo(params);
    start();
    await description;
    return result;
  };
  const first = handlers.onGroupMedia(groupMedia({ messageId: "431", content: "<media:video>", media: [{ ...VIDEO, messageId: "431" }] }));
  const second = handlers.onGroupMedia(groupMedia({ messageId: "432", content: "Denise, watch this", media: [{ ...VIDEO, path: copiedPath }] }));
  await started;

  await (api.looked[0][1] === VIDEO.path ? second : first);
  assert.equal(api.looked.length, 1);
  complete();
  await Promise.all([first, second]);

  assert.equal(api.looked.length, 1);
  assert.equal(JSON.parse(await readFile(path.join(directory, "room.json"), "utf8")).length, 1);
});

for (const attachment of [PHOTO, VIDEO]) {
  test(`an unreadable ${attachment.kind} file is skipped before description without losing siblings`, async () => {
    const { api, directory, handlers } = await room();
    const sibling = attachment === PHOTO ? VIDEO : PHOTO;
    const missing = { ...attachment, path: path.join(directory, "missing-media") };

    await handlers.onGroupMedia(groupMedia({ messageId: "433", content: "<media:image>", media: [missing, sibling] }));

    assert.deepEqual(api.looked, [[sibling === PHOTO ? "photo" : "video", sibling.path]]);
    assert.match(api.warnings[0], /could not read a photo|could not read a video/);
    assert.equal(JSON.parse(await readFile(path.join(directory, "room.json"), "utf8")).length, 1);
  });
}

for (const hasExpiredOriginal of [false, true]) {
  test(`quoted media without a retained record is credited to the reply: expired=${hasExpiredOriginal}`, async () => {
    const { api, clock, directory, handlers } = await room();
    if (hasExpiredOriginal) {
      await handlers.onGroupMedia(groupMedia({ messageId: "434", content: "<media:image>", media: [PHOTO] }));
      clock.now = START + 25 * HOUR;
    }
    const copiedPath = path.join(directory, "unretained-quote.jpg");
    await copyFile(PHOTO.path, copiedPath);
    const reply = groupMedia({ messageId: "435", content: "Denise, what is this?", media: [{ ...PHOTO, path: copiedPath }] });
    reply.context.metadata.senderName = "Franco Marlowe";
    reply.context.timestamp = clock.now;

    await handlers.onGroupMedia(reply);

    assert.equal(api.looked.length, hasExpiredOriginal ? 2 : 1);
    const kept = JSON.parse(await readFile(path.join(directory, "room.json"), "utf8"));
    assert.equal(kept.length, 1);
    assert.equal(kept[0].speaker, "Franco Marlowe");
    assert.equal(kept[0].caption, "Denise, what is this?");
    assert.equal(kept[0].at, clock.now);
  });
}

for (const content of ["<media:audio>", "Denise, can you hear this?"]) {
  test(`voice eligibility does not hide photos and videos: ${content}`, async () => {
    const { api, handlers } = await room();
    const event = skippedVoiceNote({ content, media: [
      { path: "/state/media/inbound/note.ogg", kind: "audio", messageId: "425" },
      { ...PHOTO, messageId: "426" },
      { ...VIDEO, messageId: "427" },
    ] });

    await handlers.onGroupMedia(event);

    assert.equal(api.calls.length, content === "<media:audio>" ? 1 : 0);
    assert.deepEqual(api.looked.toSorted(), [["photo", PHOTO.path], ["video", VIDEO.path]]);
    assert.match((await prompt(handlers)).prependContext, /sent a photo/);
    assert.match((await prompt(handlers)).prependContext, /sent a video/);
  });
}

test("an unreadable album attachment does not discard its siblings", async () => {
  const { api, handlers } = await room();
  api.runtime.mediaUnderstanding.describeImageFile = async () => { throw new Error("Unreadable photo"); };

  await handlers.onGroupMedia(groupMedia({ messageId: "428", content: "<media:image>", media: [PHOTO, VIDEO] }));

  assert.deepEqual(api.looked, [["video", VIDEO.path]]);
  assert.match(api.warnings[0], /could not read a photo/);
  assert.match((await prompt(handlers)).prependContext, /sent a video/);
});

test("a family question waits for every pending album attachment", { timeout: 5000 }, async () => {
  const { api, handlers } = await room();
  let completePhoto;
  let completeVideo;
  let startPhoto;
  let startVideo;
  const photoStarted = new Promise((resolve) => { startPhoto = resolve; });
  const videoStarted = new Promise((resolve) => { startVideo = resolve; });
  api.runtime.mediaUnderstanding.describeImageFile = () => new Promise((resolve) => { completePhoto = resolve; startPhoto(); });
  api.runtime.mediaUnderstanding.describeVideoFile = () => new Promise((resolve) => { completeVideo = resolve; startVideo(); });
  const album = handlers.onGroupMedia(groupMedia({ messageId: "429", content: "<media:image>", media: [PHOTO, VIDEO] }));
  const question = prompt(handlers);
  let hasAnswered = false;
  question.then(() => { hasAnswered = true; });
  await Promise.all([photoStarted, videoStarted]);

  completePhoto({ text: "A grocery receipt." });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(hasAnswered, false);
  completeVideo({ text: "A dog playing." });
  await album;

  assert.match((await question).prependContext, /A grocery receipt/);
  assert.match((await question).prependContext, /A dog playing/);
});

test("media in another chat, or ones that cannot be read, keep nothing", async () => {
  const { api, handlers } = await room();
  const direct = groupMedia({ messageId: "412", content: "<media:image>", media: [PHOTO] });
  direct.sessionKey = "agent:main:telegram:direct:7100000002";
  direct.context.conversationId = "telegram:7100000002";
  await handlers.onGroupMedia(direct);
  assert.deepEqual(api.looked, []);

  for (const attachment of [PHOTO, VIDEO]) {
    const failing = await room({ fail: true });
    await failing.handlers.onGroupMedia(groupMedia({ messageId: "413", content: "<media:image>", media: [attachment] }));
    assert.equal(await prompt(failing.handlers), undefined);
    assert.match(failing.api.warnings[0], /could not read a photo|could not read a video/);
  }
});

test("a photo is never crowded out by more of the other assistant's posts than a turn holds", async () => {
  const { handlers } = await room();
  await handlers.onGroupMedia(groupMedia({ messageId: "414", content: "<media:image>", media: [PHOTO] }));
  const newer = peerPosts(40, { from: START - 20_000 });
  await handlers.acceptPeer({ params: { speaker: "Corey", posts: newer }, respond: () => {} });

  const lines = (await prompt(handlers)).prependContext.split("\n");
  assert.equal(lines.length, 32);
  assert.match(lines[1], /Gia Marlowe sent a photo/);
  assert.match(lines[2], /"Corey post 11"/);
});

test("simultaneous writes are not lost and a damaged file starts over", async () => {
  const { directory, handlers } = await room();
  await Promise.all(
    Array.from({ length: 12 }, (_, n) =>
      handlers.acceptPeer({
        params: { speaker: "Corey", posts: [{ id: `p${n}`, at: START - n * 1000, text: `post ${n}` }] },
        respond: () => {},
      }),
    ),
  );
  assert.equal((await prompt(handlers)).prependContext.split("\n").length, 14);

  await writeFile(path.join(directory, "room.json"), "{not json");
  assert.equal(await prompt(handlers), undefined);
  await handlers.acceptPeer({
    params: { speaker: "Corey", posts: [{ id: "again", at: START, text: "after the damage" }] },
    respond: () => {},
  });
  assert.match((await prompt(handlers)).prependContext, /after the damage/);
});

test("finalized streamed and progress replies are recorded through the internal sent hook", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "family-room-sent-"));
  const hooks = new Map();
  const api = {
    ...fakeApi(),
    pluginConfig: { groupChatId: GROUP },
    registerHook: (name, handler) => hooks.set(name, handler),
    on() {},
    registerTool() {},
    registerGatewayMethod() {},
  };
  api.runtime.state = { resolveStateDir: () => directory };
  plugin.register(api);
  for (const [messageId, content] of [["501", "Finalized streamed reply"], ["502", "Progress-mode final reply"]]) {
    await hooks.get("message:sent")({
      type: "message", action: "sent", sessionKey: FAMILY_SESSION,
      context: { channelId: "telegram", conversationId: GROUP, to: GROUP, messageId, content, success: true },
    });
  }
  const outbox = JSON.parse(await readFile(path.join(directory, "household-family-room", "outbox.json"), "utf8"));
  assert.deepEqual(outbox.map(({ key, text }) => ({ key, text })), [
    { key: `telegram:${GROUP}:501`, text: "Finalized streamed reply" },
    { key: `telegram:${GROUP}:502`, text: "Progress-mode final reply" },
  ]);
});

test("registration wires each hook and the one gateway method", () => {
  const registered = { hooks: [], on: [], methods: [] };
  const api = {
    ...fakeApi(),
    pluginConfig: { groupChatId: GROUP },
    registerHook: (events, _handler, options) => registered.hooks.push([events, options.name]),
    on: (name) => registered.on.push(name),
    registerTool() {},
    registerGatewayMethod: (name, _handler, options) => registered.methods.push([name, options.scope]),
  };
  api.runtime.state = { resolveStateDir: () => tmpdir() };
  plugin.register(api);
  assert.deepEqual(registered.hooks, [
    ["message:received", "household-family-room-group-media"],
    ["message:sent", "household-family-room-group-posts"],
  ]);
  assert.deepEqual(registered.on, ["before_prompt_build"]);
  assert.deepEqual(registered.methods, [["household-family-room.peer", "operator.write"]]);

  const errors = [];
  plugin.register({ ...api, pluginConfig: {}, logger: { ...api.logger, error: (m) => errors.push(m) } });
  assert.match(errors[0], /not started/);
});
