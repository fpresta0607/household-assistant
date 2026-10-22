// The files the app's conversations carry: photos, voice notes, videos and documents,
// each kept once under the hex SHA-256 of its bytes.
//
// A phone uploads in chunks, because the gateway's WebSocket takes one JSON frame at a
// time and a video does not fit in one. Chunks arrive in order; one that was already
// taken, because the phone retried after a dropped answer, changes nothing. When the
// last byte is in, the file is hashed and moved under its hash, so the same photo sent
// twice is one file and a message names its attachment by what it is.
//
// A reply's attachment, a voice note the assistant spoke or an image it made, is kept by
// its hash too, so a phone reads every file the same way.

import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, open, readdir, rename, rm, stat } from "node:fs/promises";
import path from "node:path";

export const MAX_MEDIA_BYTES = 50 * 1024 * 1024;
const MEDIA_ID = /^[0-9a-f]{64}$/;
const UPLOAD_ID = /^[A-Za-z0-9-]{8,64}$/;
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;
const STALE_UPLOAD_MS = 24 * 3_600_000;

// A request the phone or the relay got wrong, said in words that carry no content.
function invalid(message) {
  return Object.assign(new Error(message), { code: "INVALID_REQUEST" });
}

export function isMediaId(value) {
  return typeof value === "string" && MEDIA_ID.test(value);
}

// A PNG's, JPEG's or WebP's width and height from its own header, or null, so a photo the
// assistant sends is drawn in its own shape rather than cut to the phone's 4:3 default.
export function photoSize(bytes) {
  let size = null;
  if (bytes.length >= 24 && bytes.readUInt32BE(0) === 0x89504e47) {
    size = { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  } else if (bytes.length >= 30 && bytes.toString("ascii", 0, 4) === "RIFF" && bytes.toString("ascii", 8, 12) === "WEBP") {
    const chunk = bytes.toString("ascii", 12, 16);
    if (chunk === "VP8X") size = { width: 1 + bytes.readUIntLE(24, 3), height: 1 + bytes.readUIntLE(27, 3) };
    if (chunk === "VP8 ") size = { width: bytes.readUInt16LE(26) & 0x3fff, height: bytes.readUInt16LE(28) & 0x3fff };
    if (chunk === "VP8L") {
      const bits = bytes.readUInt32LE(21);
      size = { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
    }
  } else if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    // A JPEG's size is in its first start-of-frame segment, after any others.
    for (let offset = 2; offset + 9 <= bytes.length && bytes[offset] === 0xff;) {
      const marker = bytes[offset + 1];
      if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
        size = { width: bytes.readUInt16BE(offset + 7), height: bytes.readUInt16BE(offset + 5) };
        break;
      }
      offset += 2 + bytes.readUInt16BE(offset + 2);
    }
  }
  const isSize = (value) => Number.isSafeInteger(value) && value > 0 && value <= 65535;
  return size && isSize(size.width) && isSize(size.height) ? size : null;
}

async function hashFile(file) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}

async function sizeOf(file) {
  try {
    return (await stat(file)).size;
  } catch (error) {
    if (error.code === "ENOENT") return 0;
    throw error;
  }
}

export function createMediaStore(directory, { maxBytes = MAX_MEDIA_BYTES, now = Date.now } = {}) {
  const mediaDirectory = path.join(directory, "media");
  const uploadDirectory = path.join(directory, "uploads");
  // One chunk at a time per upload, so two retries racing cannot both append.
  const queues = new Map();

  const mediaPath = (id) => path.join(mediaDirectory, id);

  async function keep(temporary, expected) {
    const id = await hashFile(temporary);
    if (expected !== undefined && id !== expected) {
      await rm(temporary, { force: true });
      throw invalid("media does not match its hash");
    }
    await mkdir(mediaDirectory, { recursive: true, mode: 0o700 });
    await rename(temporary, mediaPath(id));
    return id;
  }

  async function clearStaleUploads() {
    let names;
    try {
      names = await readdir(uploadDirectory);
    } catch {
      return;
    }
    await Promise.all(names.map(async (name) => {
      const file = path.join(uploadDirectory, name);
      const { mtimeMs } = await stat(file).catch(() => ({ mtimeMs: now() }));
      if (now() - mtimeMs > STALE_UPLOAD_MS) await rm(file, { force: true });
    }));
  }

  async function append({ uploadId, offset, total, data }) {
    const file = path.join(uploadDirectory, uploadId);
    const received = await sizeOf(file);
    const bytes = Buffer.from(data, "base64");
    if (offset + bytes.length <= received) return { complete: false, received };
    if (offset !== received) throw invalid(`expected the chunk at offset ${received}, got ${offset}`);
    if (offset + bytes.length > total) throw invalid("chunk runs past the upload's total");
    if (offset === 0) await clearStaleUploads();
    await mkdir(uploadDirectory, { recursive: true, mode: 0o700 });
    const handle = await open(file, "a", 0o600);
    try {
      await handle.write(bytes);
    } finally {
      await handle.close();
    }
    const end = offset + bytes.length;
    if (end < total) return { complete: false, received: end };
    const id = await keep(file);
    return { complete: true, received: end, id, bytes: total };
  }

  return {
    path: mediaPath,

    async putUpload(chunk) {
      const { uploadId, offset, total, data } = chunk ?? {};
      if (typeof uploadId !== "string" || !UPLOAD_ID.test(uploadId)) throw invalid("bad upload id");
      if (!Number.isSafeInteger(total) || total <= 0) throw invalid("bad upload total");
      if (total > maxBytes) throw invalid(`upload too large: over ${maxBytes} bytes`);
      if (!Number.isSafeInteger(offset) || offset < 0) throw invalid("bad upload offset");
      if (typeof data !== "string" || !BASE64.test(data)) throw invalid("chunk is not base64");
      const previous = queues.get(uploadId) ?? Promise.resolve();
      const next = previous.then(() => append({ uploadId, offset, total, data }));
      queues.set(uploadId, next.catch(() => undefined));
      try {
        return await next;
      } finally {
        if (queues.get(uploadId) === next) queues.delete(uploadId);
      }
    },

    // Bytes from the other gateway, which named them by their hash.
    async putBytes(bytes, expected) {
      if (bytes.length > maxBytes) throw invalid(`media too large: over ${maxBytes} bytes`);
      await mkdir(uploadDirectory, { recursive: true, mode: 0o700 });
      const temporary = path.join(uploadDirectory, `in-${randomUUID()}`);
      const handle = await open(temporary, "wx", 0o600);
      try {
        await handle.write(bytes);
      } finally {
        await handle.close();
      }
      const id = await keep(temporary, expected);
      return { id, bytes: bytes.length };
    },

    async read(id, offset, length) {
      if (!isMediaId(id)) throw invalid("bad media id");
      let handle;
      try {
        handle = await open(mediaPath(id), "r");
      } catch (error) {
        if (error.code === "ENOENT") throw invalid("no such media");
        throw error;
      }
      try {
        const { size } = await handle.stat();
        const start = Math.max(0, Math.min(offset, size));
        const buffer = Buffer.alloc(Math.max(0, Math.min(length, size - start)));
        await handle.read(buffer, 0, buffer.length, start);
        return { data: buffer.toString("base64"), offset: start, total: size };
      } finally {
        await handle.close();
      }
    },

    // How many bytes are kept under `id`, 0 when none are.
    async size(id) {
      return isMediaId(id) ? sizeOf(mediaPath(id)) : 0;
    },
  };
}
