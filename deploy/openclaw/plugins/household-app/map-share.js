// A map a person shares in a conversation, once or live for a while, as Messages does.
//
// It is a message whose `location` holds the place and, for a live one, when it ends.
// The phone signs it like any message, with the place inside the signed text as integers
// (signature.js), so the other gateway believes it only from that person's phone, and it
// is kept and relayed like any message. This is the person's own choice to show where they
// are to that conversation, apart from household-app.location, which only their own
// assistant hears.
//
// While a live map lasts, the phone moves it with updates, each signed on its own and
// kept as one entry per map, the newest only, which the relay carries like a reaction. An
// update with no position stops the share early. Nothing is taken once the share has
// ended or stopped, and nothing older than what is kept.

import { RoomError } from "./room-error.js";

export const LIVE_VERSION = "household-app/live/v1";
// How far an update's signing time may be from the gateway's clock, as for a message.
const SIGNED_WITHIN_MS = 5 * 60_000;
// The longest a live share runs: until the end of the day, 25 hours on the day the clocks
// go back.
const LONGEST_SHARE_MS = 26 * 3_600_000;
// A position measured this long before the map was shared says nothing of where its
// person was then.
const OLDEST_POSITION_MS = 3_600_000;
const WIDEST_ACCURACY_M = 100_000;
const MICRODEGREES = 1_000_000;
const ID = /^[A-Za-z0-9][A-Za-z0-9-]{7,79}$/;

const refuse = (message) => {
  throw new RoomError("INVALID_REQUEST", message);
};

const isWhole = (value, lowest, highest) => Number.isSafeInteger(value) && value >= lowest && value <= highest;

// A position in whole units, measured between `earliest` and `latest`.
function cleanPosition(position, earliest, latest) {
  if (!position || typeof position !== "object") refuse("a map needs a position");
  const { latitudeE6, longitudeE6, accuracy, at } = position;
  if (!isWhole(latitudeE6, -90 * MICRODEGREES, 90 * MICRODEGREES)) refuse("bad latitude");
  if (!isWhole(longitudeE6, -180 * MICRODEGREES, 180 * MICRODEGREES)) refuse("bad longitude");
  if (!isWhole(accuracy, 1, WIDEST_ACCURACY_M)) refuse("bad accuracy");
  if (!isWhole(at, earliest, latest)) refuse("position time out of range");
  return { latitudeE6, longitudeE6, accuracy, at };
}

// The place a message shares, checked and nothing else kept. `until` is null for a map
// shared once.
export function cleanSharedLocation(location, messageAt) {
  if (!location || typeof location !== "object") refuse("a map needs a position");
  const position = cleanPosition(location, messageAt - OLDEST_POSITION_MS, messageAt + SIGNED_WITHIN_MS);
  const { until } = location;
  if (until !== null && !isWhole(until, messageAt + 1, messageAt + LONGEST_SHARE_MS)) refuse("bad end of the share");
  return { ...position, until };
}

// The exact text the phone signs for an update. A stop leaves the position empty.
export function liveText({ messageId, at, position }) {
  return [
    LIVE_VERSION,
    messageId,
    at,
    position?.at ?? "",
    position?.latitudeE6 ?? "",
    position?.longitudeE6 ?? "",
    position?.accuracy ?? "",
  ].join("\n");
}

// An update's fields, checked against the map it moves and the update already kept.
// `now` is the gateway's clock for an update from its own owner's phone, and null for one
// the relay carried, which may arrive after the share's end and still count if it was
// signed before.
export function cleanLiveUpdate(params, { map, current, now }) {
  const { messageId, at, position } = params ?? {};
  if (typeof messageId !== "string" || !ID.test(messageId)) refuse("bad map id");
  if (!Number.isSafeInteger(at)) refuse("bad update time");
  if (now !== null && !isWhole(at, now - SIGNED_WITHIN_MS, now + SIGNED_WITHIN_MS)) refuse("update time out of range");
  if (!map?.location || map.location.until === null) refuse("no live map by that id");
  if (current && current.position === null) refuse("that share has stopped");
  if (at <= map.at || (current && at <= current.at)) refuse("the gateway already has a newer update");
  if (at > map.location.until || (now !== null && now >= map.location.until)) refuse("that share has ended");
  return {
    messageId,
    at,
    position: position === null ? null : cleanPosition(position, map.at - OLDEST_POSITION_MS, at + SIGNED_WITHIN_MS),
  };
}
