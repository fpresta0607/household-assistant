// What this gateway shows the other one: its outbox and the family room's attachments the
// outbox names, in household-app/share/ under the gateway's state. The other gateway's
// container mounts that one folder read-only and reads it directly (peer-link.js), so a
// family message crosses as soon as it is written, with no relay in between.
//
// Nothing else of this gateway's state is in the folder: the owner's own thread, its
// attachments, the stores and the settings stay where only this gateway reaches them. An
// attachment is a hard link to the media store's own file, so sharing it copies nothing,
// and it is linked before the outbox that names it is written, so the other side never
// reads an entry whose attachment is not there yet. One the outbox no longer names goes.

import { copyFile, link, mkdir, readdir, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";

import { isMediaId } from "./media.js";

export const SHARE = "share";
export const SHARED_OUTBOX = "outbox.json";
export const SHARED_MEDIA = "media";

// The attachments the outbox's family-room entries name, by their hash.
export function sharedMediaIds(entries) {
  const ids = new Set();
  for (const entry of Array.isArray(entries) ? entries : []) {
    for (const item of Array.isArray(entry?.media) ? entry.media : []) {
      if (isMediaId(item?.id)) ids.add(item.id);
    }
  }
  return ids;
}

async function shareOne(source, target) {
  try {
    await link(source, target);
  } catch (error) {
    if (error.code === "EEXIST" || error.code === "ENOENT") return;
    // A media store on another file system than the share, which the box never has.
    if (error.code === "EXDEV" || error.code === "EPERM") await copyFile(source, target);
    else throw error;
  }
}

// `mediaPath` is the media store's path for an id. Writes are queued, so an older outbox can
// never land after a newer one.
export function createShare({ directory, mediaPath }) {
  const folder = path.join(directory, SHARE);
  const mediaFolder = path.join(folder, SHARED_MEDIA);
  let writing = Promise.resolve();

  async function publish(text, entries) {
    const wanted = sharedMediaIds(entries);
    await mkdir(mediaFolder, { recursive: true, mode: 0o700 });
    for (const id of wanted) await shareOne(mediaPath(id), path.join(mediaFolder, id));
    const outbox = path.join(folder, SHARED_OUTBOX);
    const temporary = `${outbox}.${process.pid}.tmp`;
    await writeFile(temporary, text, { mode: 0o600 });
    await rename(temporary, outbox);
    for (const name of await readdir(mediaFolder)) {
      if (!wanted.has(name)) await rm(path.join(mediaFolder, name), { force: true });
    }
  }

  return {
    folder,
    // `text` is the outbox as written, `entries` the family-room entries it holds.
    write(text, entries) {
      const next = writing.then(() => publish(text, entries));
      writing = next.catch(() => undefined);
      return next;
    },
  };
}
