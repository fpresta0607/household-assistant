// The family room's photos, voice notes, videos and files, from
// deploy/openclaw/plugins/household-app.
//
// Run with `node --test tests/js/household_app_media.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { mkdtemp, readFile, readdir, stat, utimes } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { createMediaStore, photoSize } from "../../deploy/openclaw/plugins/household-app/media.js";

async function media(options = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-media-"));
  return { directory, store: createMediaStore(directory, options) };
}

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

test("an upload in chunks becomes one file named by its hash", async () => {
  const { store } = await media();
  const bytes = randomBytes(5000);
  const first = await store.putUpload({ uploadId: "u-12345678", offset: 0, total: 5000, data: bytes.subarray(0, 3000).toString("base64") });
  assert.deepEqual(first, { complete: false, received: 3000 });
  const done = await store.putUpload({ uploadId: "u-12345678", offset: 3000, total: 5000, data: bytes.subarray(3000).toString("base64") });
  assert.deepEqual(done, { complete: true, received: 5000, id: sha256(bytes), bytes: 5000 });
  assert.deepEqual(await readFile(store.path(sha256(bytes))), bytes);
});

test("a chunk sent again after it was taken changes nothing", async () => {
  const { store } = await media();
  const bytes = randomBytes(4000);
  const chunk = { uploadId: "u-12345678", offset: 0, total: 4000, data: bytes.subarray(0, 2000).toString("base64") };
  await store.putUpload(chunk);
  assert.deepEqual(await store.putUpload(chunk), { complete: false, received: 2000 });
  const done = await store.putUpload({ uploadId: "u-12345678", offset: 2000, total: 4000, data: bytes.subarray(2000).toString("base64") });
  assert.equal(done.id, sha256(bytes));
});

for (const [name, chunk, message] of [
  ["a gap", { offset: 10 }, /offset/],
  ["an upload id with a path in it", { uploadId: "../room.sqlite" }, /upload id/],
  ["a total over the ceiling", { total: 2049 }, /too large/],
  ["a chunk past the total", { total: 100, data: Buffer.alloc(101).toString("base64") }, /past/],
  ["a chunk that is not base64", { data: "not base64!" }, /base64/],
]) {
  test(`${name} is refused`, async () => {
    const { store } = await media({ maxBytes: 2048 });
    await assert.rejects(
      store.putUpload({ uploadId: "u-12345678", offset: 0, total: 1000, data: Buffer.alloc(10).toString("base64"), ...chunk }),
      message,
    );
  });
}

test("the same bytes uploaded twice are one file", async () => {
  const { directory, store } = await media();
  const bytes = randomBytes(100);
  await store.putUpload({ uploadId: "u-aaaaaaaa", offset: 0, total: 100, data: bytes.toString("base64") });
  await store.putUpload({ uploadId: "u-bbbbbbbb", offset: 0, total: 100, data: bytes.toString("base64") });
  assert.deepEqual(await readdir(path.join(directory, "media")), [sha256(bytes)]);
});

test("an upload left unfinished for a day is cleared by the next one", async () => {
  const { directory, store } = await media();
  await store.putUpload({ uploadId: "u-old00000", offset: 0, total: 100, data: Buffer.alloc(10).toString("base64") });
  const old = path.join(directory, "uploads", "u-old00000");
  const dayAgo = new Date(Date.now() - 25 * 3_600_000);
  await utimes(old, dayAgo, dayAgo);
  await store.putUpload({ uploadId: "u-new00000", offset: 0, total: 100, data: Buffer.alloc(10).toString("base64") });
  await assert.rejects(stat(old), { code: "ENOENT" });
});

test("reading a file back is paged", async () => {
  const { store } = await media();
  const bytes = randomBytes(1000);
  const { id } = await store.putBytes(bytes);
  const first = await store.read(id, 0, 600);
  assert.equal(first.total, 1000);
  assert.deepEqual(Buffer.from(first.data, "base64"), bytes.subarray(0, 600));
  const second = await store.read(id, 600, 600);
  assert.deepEqual(Buffer.from(second.data, "base64"), bytes.subarray(600));
});

test("only a full hash names a file that can be read", async () => {
  const { store } = await media();
  await assert.rejects(store.read("../room.sqlite", 0, 10), /media id/);
  await assert.rejects(store.read("a".repeat(64), 0, 10), /no such media/);
});

test("bytes handed over keep their hash and refuse a wrong one", async () => {
  const { store } = await media();
  const bytes = randomBytes(64);
  assert.equal((await store.putBytes(bytes, sha256(bytes))).id, sha256(bytes));
  await assert.rejects(store.putBytes(bytes, "b".repeat(64)), /hash/);
});

test("bytes over the ceiling are refused", async () => {
  const { store } = await media({ maxBytes: 100 });
  await assert.rejects(store.putBytes(randomBytes(101)), /too large/);
});

// The first bytes of each kind of picture, with the size where its header keeps it.
function png(width, height) {
  const header = Buffer.alloc(24);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(header, 0);
  header.write("IHDR", 12, "ascii");
  header.writeUInt32BE(width, 16);
  header.writeUInt32BE(height, 20);
  return header;
}

function jpeg(width, height) {
  const app0 = Buffer.from([0xff, 0xe0, 0x00, 0x10, ...Buffer.alloc(14)]);
  const frame = Buffer.from([0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 0xff, width >> 8, width & 0xff, 0x03]);
  return Buffer.concat([Buffer.from([0xff, 0xd8]), app0, frame, Buffer.alloc(16)]);
}

function webp(chunk, body) {
  const header = Buffer.alloc(30);
  header.write("RIFF", 0, "ascii");
  header.write("WEBP", 8, "ascii");
  header.write(chunk, 12, "ascii");
  body(header);
  return header;
}

test("a picture's width and height come from its own header, PNG, JPEG or WebP", () => {
  assert.deepEqual(photoSize(png(1024, 1024)), { width: 1024, height: 1024 });
  assert.deepEqual(photoSize(png(1536, 1024)), { width: 1536, height: 1024 });
  assert.deepEqual(photoSize(jpeg(1200, 900)), { width: 1200, height: 900 });
  const extended = webp("VP8X", (bytes) => {
    bytes.writeUIntLE(1535, 24, 3);
    bytes.writeUIntLE(1023, 27, 3);
  });
  assert.deepEqual(photoSize(extended), { width: 1536, height: 1024 });
  const lossy = webp("VP8 ", (bytes) => {
    bytes.writeUInt16LE(800, 26);
    bytes.writeUInt16LE(600, 28);
  });
  assert.deepEqual(photoSize(lossy), { width: 800, height: 600 });
  const lossless = webp("VP8L", (bytes) => bytes.writeUInt32LE((640 - 1) | ((480 - 1) << 14), 21));
  assert.deepEqual(photoSize(lossless), { width: 640, height: 480 });
});

test("bytes with no size in them, or a size of nothing, are no size", () => {
  assert.equal(photoSize(Buffer.from("not a picture at all, just words")), null);
  assert.equal(photoSize(png(0, 1024)), null);
  assert.equal(photoSize(Buffer.from([0xff, 0xd8, 0xff, 0xe0])), null);
  assert.equal(photoSize(Buffer.alloc(0)), null);
});
