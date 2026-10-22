import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { createMediaStore } from '../../deploy/openclaw/plugins/household-app/media.js';
import { videoDurationMs } from '../../deploy/openclaw/plugins/household-app/video-duration.js';
import { createVideoSummaries, videoSource, VIDEO_MODEL, MAX_DAILY_VIDEOS } from '../../deploy/openclaw/plugins/household-app/video-summary.js';
import { signedText } from '../../deploy/openclaw/plugins/household-app/signature.js';
import { runningChannel, until } from './fixtures/household-app-channel.mjs';

const box = (type, body) => {
  const header = Buffer.alloc(8); header.writeUInt32BE(body.length + 8); header.write(type, 4);
  return Buffer.concat([header, body]);
};
function clip(seconds = 63, { version = 0, trackSeconds = seconds, label = '' } = {}) {
  const timing = (duration) => {
    const header = Buffer.alloc(version ? 32 : 20); header[0] = version;
    header.writeUInt32BE(1000, version ? 20 : 12);
    if (version) header.writeBigUInt64BE(BigInt(duration * 1000), 24);
    else header.writeUInt32BE(duration * 1000, 16);
    return header;
  };
  return Buffer.concat([box('ftyp', Buffer.from('isom0000')), box('moov', Buffer.concat([
    box('mvhd', timing(seconds)), box('trak', box('mdia', box('mdhd', timing(trackSeconds)))),
  ])), box('mdat', Buffer.from(label || 'video data'))]);
}
const answer = (text = 'A kitten runs across the room at 00:12; laughter is audible.') => ({
  ok: true, json: async () => ({ choices: [{ message: { content: text } }], usage: { cost: 0.0007 } }),
});
const message = (item, overrides = {}) => ({ conversation: 'family', id: 'video-000001', media: [item], ...overrides });
async function fixture(t, request = async () => answer(), now) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'steward-video-'));
  const media = createMediaStore(directory);
  const make = () => createVideoSummaries({ directory, media, log: { warn() {} }, apiKey: () => 'test-only', request, ...(now ? { now } : {}) });
  const summaries = make();
  t.after(async () => { await summaries.close(); await rm(directory, { recursive: true, force: true }); });
  const keep = async (bytes = clip()) => ({ ...(await media.putBytes(bytes)), kind: 'video', mime: 'video/mp4', durationMs: 1000 });
  return { directory, media, summaries, keep, make };
}

test('reads real container timing in both versions, including the longest track, and refuses malformed/fragmented inputs', () => {
  assert.equal(videoDurationMs(clip()), 63_000);
  assert.equal(videoDurationMs(clip(63, { version: 1 })), 63_000);
  assert.equal(videoDurationMs(clip(1, { trackSeconds: 181 })), 181_000);
  for (const bad of [Buffer.alloc(0), clip().subarray(0, 36), box('moov', Buffer.alloc(0)), Buffer.concat([clip(), box('moof', Buffer.alloc(0))])]) {
    assert.throws(() => videoDurationMs(bad));
  }
});

test('a simultaneous and later request reuse one bounded digest, including after reopening the cache', async (t) => {
  const requests = [];
  const f = await fixture(t, async (url, init) => { requests.push({ url, body: JSON.parse(init.body) }); return answer(); });
  const item = await f.keep();
  const [one, two] = await Promise.all([f.summaries.describe(message(item)), f.summaries.describe(message(item))]);
  assert.equal(one, two);
  assert.equal(requests.length, 1);
  assert.match(one, /kitten/);
  assert.match(one, /63 seconds/);
  const body = requests[0].body;
  assert.equal(body.model, VIDEO_MODEL);
  assert.equal(body.max_tokens, 500);
  assert.deepEqual(body.reasoning, { enabled: false });
  assert.deepEqual(body.provider.max_price, { prompt: 0.1, completion: 0.4 });
  assert.equal(body.provider.allow_fallbacks, false);
  assert.equal(body.tools, undefined);
  assert.equal(body.messages.length, 2);
  assert.match(body.messages[1].content[0].video_url.url, /^data:video\/mp4;base64,/);
  await f.summaries.close();
  const reopened = f.make();
  try { assert.equal(await reopened.describe(message(item)), one); } finally { await reopened.close(); }
  assert.equal(requests.length, 1);
  const ledger = f.make();
  try { assert.equal(ledger.spentSince("2000-01-01"), 0.0007); } finally { await ledger.close(); }
});

test('long, malformed and unsupported clips never call a provider; claimed duration cannot bypass the cap', async (t) => {
  let calls = 0;
  const f = await fixture(t, async () => { calls++; return answer(); });
  const long = await f.keep(clip(1, { trackSeconds: 121 }));
  assert.match(await f.summaries.describe(message(long)), /limited to two minutes/);
  assert.match(await f.summaries.describe(message(await f.keep(Buffer.from('not a movie')))), /not analyzed/);
  assert.match(await f.summaries.describe(message({ ...(await f.keep()), mime: 'video/webm' })), /MP4 and MOV/);
  assert.equal(calls, 0);
});

test('failures cool down across restarts and never trigger model retries', async (t) => {
  let calls = 0;
  const f = await fixture(t, async () => { calls++; return { ok: false, status: 429 }; });
  const item = await f.keep();
  assert.match(await f.summaries.describe(message(item)), /not analyzed/);
  await f.summaries.close();
  const reopened = f.make();
  try { assert.match(await reopened.describe(message(item)), /not analyzed/); } finally { await reopened.close(); }
  assert.equal(calls, 1);
});

test('one clip per turn and a durable rolling daily cap bound repeated spending', async (t) => {
  let calls = 0;
  const f = await fixture(t, async () => { calls++; return answer(); });
  const first = await f.keep();
  const second = await f.keep(clip(4, { label: 'second' }));
  assert.match(await f.summaries.describe(message(first, { media: [first, second] })), /Only the first/);
  assert.equal(calls, 1);
  for (let i = 1; i <= MAX_DAILY_VIDEOS; i++) {
    const result = await f.summaries.describe(message(await f.keep(clip(4, { label: String(i) }))));
    if (i === MAX_DAILY_VIDEOS) assert.match(result, /limit for the last 24 hours has been reached/);
  }
  assert.equal(calls, MAX_DAILY_VIDEOS);
  assert.match(await f.summaries.describe(message(first)), /kitten/, 'cached clips remain available after the cap');
});

test('replies only resolve videos in the same conversation', () => {
  const parent = message({ kind: 'video' });
  const reply = message(null, { media: [], replyTo: parent.id });
  assert.equal(videoSource(reply, { message: () => parent }), parent);
  assert.equal(videoSource({ ...reply, conversation: 'direct' }, { message: () => parent }), null);
  assert.equal(videoSource({ ...reply, replyTo: null }, { message: () => parent }), null);
});

const { publicKey, privateKey } = generateKeyPairSync('ed25519');
const cfg = {
  agents: { entries: { main: { identity: { name: 'Corey' } } } },
  channels: { household: {
    owner: { id: 'franco', name: 'Franco', deviceKeys: [publicKey.export({ format: 'der', type: 'spki' }).subarray(12).toString('base64url')] },
    assistant: { id: 'corey', name: 'Corey' },
    peer: { person: { id: 'gia', name: 'Gia' }, assistant: { id: 'denise', name: 'Denise' } },
  } },
};
const signed = (entry) => ({ ...entry, signature: sign(null, Buffer.from(signedText(entry)), privateKey).toString('base64url') });
const sdk = {
  buildMentionRegexes: '() => [/corey/i]',
  matchesMentionWithExplicit: '({ text, mentionRegexes }) => mentionRegexes.some((r) => r.test(text))',
  implicitMentionKindWhen: '(kind, when) => when ? [kind] : []',
  resolveInboundMentionDecision: '({ facts }) => ({ shouldSkip: !facts.wasMentioned && !facts.implicitMentionKinds.length })',
};

test('Fam upload does no AI work; an explicit reply summarizes the saved clip once and never forwards video bytes to the agent', async () => {
  const previousKey = process.env.OPENROUTER_API_KEY;
  process.env.OPENROUTER_API_KEY = 'test-only';
  const channel = await runningChannel(cfg, { sdk });
  const previousFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => { calls++; return answer(); };
  try {
    const media = createMediaStore(path.join(channel.stateDir, 'household-app'));
    const item = { ...(await media.putBytes(clip())), kind: 'video', mime: 'video/mp4', durationMs: 63_000 };
    const shared = message(item, { at: Date.now(), replyTo: null, text: 'Okra is crazy' });
    assert.equal((await channel.send(signed(shared))).ok, true);
    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.equal(calls, 0);
    assert.equal(channel.contexts.length, 0);
    await assert.rejects(stat(path.join(channel.stateDir, 'household-app', 'video-summaries.sqlite')));
    const reply = { ...shared, id: 'reply-000001', replyTo: shared.id, media: [], text: '@Corey what is happening in this video?' };
    assert.equal((await channel.send(signed(reply))).ok, true);
    await until('video context', () => channel.contexts.length === 1);
    assert.match(channel.contexts[0].message.bodyForAgent, /kitten/);
    assert.deepEqual(channel.contexts[0].media, []);
    const direct = { ...shared, id: 'direct-00001', conversation: 'direct', text: 'Describe this' };
    assert.equal((await channel.send(signed(direct))).ok, true);
    await until('direct context', () => channel.contexts.length === 2);
    assert.deepEqual(channel.contexts[1].media, []);
    assert.match(channel.contexts[1].message.bodyForAgent, /kitten/);
    assert.equal(calls, 2, 'each conversation owns its cache');
  } finally {
    await channel.stop();
    globalThis.fetch = previousFetch;
    if (previousKey === undefined) delete process.env.OPENROUTER_API_KEY;
    else process.env.OPENROUTER_API_KEY = previousKey;
  }
});
