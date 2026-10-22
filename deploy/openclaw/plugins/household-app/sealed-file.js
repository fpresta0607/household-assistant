// A sign-in kept on the gateway: one JSON file, its secret fields sealed with AES-256-GCM
// under a key from the gateway's keyring password, written whole and readable only by
// the gateway's own user.

import { createCipheriv, createDecipheriv, randomBytes, scryptSync } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";

export function createSealedFile(file, keyringPassword) {
  function key(salt) {
    if (!keyringPassword) throw new Error("the keyring password is not set on this gateway");
    return scryptSync(keyringPassword, salt, 32);
  }

  function seal(secret) {
    const salt = randomBytes(16);
    const iv = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", key(salt), iv);
    const sealed = Buffer.concat([cipher.update(secret, "utf8"), cipher.final()]);
    return [salt, iv, cipher.getAuthTag(), sealed].map((part) => part.toString("base64url")).join(".");
  }

  function open(sealedText) {
    try {
      const [salt, iv, tag, sealed] = String(sealedText).split(".").map((part) => Buffer.from(part, "base64url"));
      const decipher = createDecipheriv("aes-256-gcm", key(salt), iv);
      decipher.setAuthTag(tag);
      return Buffer.concat([decipher.update(sealed), decipher.final()]).toString("utf8");
    } catch {
      throw new Error("the kept sign-in cannot be opened with this keyring password");
    }
  }

  return {
    seal,
    open,
    async read() {
      try {
        return JSON.parse(await readFile(file, "utf8"));
      } catch (error) {
        if (error.code === "ENOENT") return null;
        throw error;
      }
    },
    async write(record) {
      await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
      const temporary = `${file}.${process.pid}.tmp`;
      await writeFile(temporary, JSON.stringify(record), { mode: 0o600 });
      await rename(temporary, file);
    },
    remove: () => rm(file, { force: true }),
  };
}
