// Where the owner is, as the owner's phone last said, for the assistant's
// household_location tool (location-tool.js).
//
// The phone says it only while its person shares, and only to this gateway: when they
// have moved a fair way or arrived somewhere, never as a stream, and "off" when they stop
// or pause. Each report carries the phone's signature, like a message, so an assistant
// talked into it, or a client holding a write-scoped token, cannot plant a position.
//
// Only the latest is kept, in memory: never in room.sqlite, whose family room the host
// relay carries to the other gateway and the box's backups copy, and never in a log. It is
// forgotten when the phone says off, when the share's time is up, and when the channel
// stops or the gateway restarts; the phone says again when it next moves or opens.

import { RoomError } from "./room.js";
import { isTextSignedBy } from "./signature.js";

export const LOCATION_VERSION = "household-app/location/v1";
const AUDIENCES = new Set(["assistant", "family"]);
// How far a report's signing time may be from the gateway's clock, as for a message.
const SIGNED_WITHIN_MS = 5 * 60_000;
// The longest a share may run before it ends by itself, other than one with no end: until
// the end of the day, which is 25 hours long on the day the clocks go back.
const LONGEST_SHARE_MS = 26 * 3_600_000;
// A position older than this says nothing about where somebody is now.
const OLDEST_POSITION_MS = 24 * 3_600_000;
const WIDEST_ACCURACY_M = 100_000;
const MICRODEGREES = 1_000_000;

const refuse = (message) => {
  throw new RoomError("INVALID_REQUEST", message);
};

// The exact text the phone signs: one line per field, and integers only, so the phone and
// this gateway write every number alike. A stop leaves the end and the position empty.
export function locationText({ at, sharing, until, position }) {
  return [
    LOCATION_VERSION,
    at,
    sharing,
    until ?? "",
    position?.at ?? "",
    position?.latitudeE6 ?? "",
    position?.longitudeE6 ?? "",
    position?.accuracy ?? "",
  ].join("\n");
}

const isWhole = (value, lowest, highest) => Number.isSafeInteger(value) && value >= lowest && value <= highest;

function cleanPosition(position, now) {
  if (!position || typeof position !== "object") refuse("a share needs a position");
  const { latitudeE6, longitudeE6, accuracy, at } = position;
  if (!isWhole(latitudeE6, -90 * MICRODEGREES, 90 * MICRODEGREES)) refuse("bad latitude");
  if (!isWhole(longitudeE6, -180 * MICRODEGREES, 180 * MICRODEGREES)) refuse("bad longitude");
  if (!isWhole(accuracy, 1, WIDEST_ACCURACY_M)) refuse("bad accuracy");
  if (!isWhole(at, now - OLDEST_POSITION_MS, now + SIGNED_WITHIN_MS)) refuse("position time out of range");
  return { latitudeE6, longitudeE6, accuracy, at };
}

// The fields a phone may send, checked and nothing else kept.
function cleanReport(params, now) {
  const { at, sharing, until, position } = params ?? {};
  if (!isWhole(at, now - SIGNED_WITHIN_MS, now + SIGNED_WITHIN_MS)) refuse("report time out of range");
  if (sharing === "off") {
    if (until != null || position != null) refuse("a stop carries no position");
    return { at, sharing, until: null, position: null };
  }
  if (!AUDIENCES.has(sharing)) refuse("unknown audience");
  if (until != null && !isWhole(until, Math.max(at, now) + 1, at + LONGEST_SHARE_MS)) refuse("bad end of sharing");
  return { at, sharing, until: until ?? null, position: cleanPosition(position, now) };
}

// `phoneKeys` answers with the keys of the owner's paired phones, as for a message.
export function createLocation({ phoneKeys, now = Date.now, setTimer = setTimeout, clearTimer = clearTimeout }) {
  let latest = null;
  // When the newest report was signed, so neither an older one nor the same one again can
  // undo it: a share played back after a stop would otherwise bring the position back.
  let newestAt = 0;
  let forgetting = null;

  function forget() {
    latest = null;
    if (forgetting !== null) clearTimer(forgetting);
    forgetting = null;
  }

  return {
    forget,

    // The owner's phone sharing where it is, or saying it stopped.
    async report(params) {
      const report = cleanReport(params, now());
      if (!isTextSignedBy(locationText(report), params.signature, await phoneKeys())) {
        refuse("a location must carry the signature of one of the owner's phones");
      }
      if (report.at <= newestAt) refuse("the gateway already has a newer location report");
      newestAt = report.at;
      forget();
      if (report.sharing !== "off") {
        const { latitudeE6, longitudeE6, accuracy, at } = report.position;
        latest = {
          latitude: latitudeE6 / MICRODEGREES,
          longitude: longitudeE6 / MICRODEGREES,
          accuracy,
          at,
          audience: report.sharing,
          until: report.until,
        };
        if (report.until !== null) {
          forgetting = setTimer(forget, report.until - now());
          forgetting?.unref?.();
        }
      }
      return { sharing: report.sharing, until: report.until };
    },

    // The latest position while its share lasts, or null.
    current() {
      if (latest?.until != null && latest.until <= now()) forget();
      return latest;
    },
  };
}
