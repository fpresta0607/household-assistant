// What iOS measured of the app on the owner's iPhone over about a day, as MetricKit hands
// it to the app once a day: how much of its scrolling hitched and how long it hung, so one
// build can be compared with the next on his own phone (CFO decision 1007134).
//
// Numbers only: never anything anybody said, never a message or a name. Nothing is kept.
// Each report becomes one line in this gateway's log, read with
// `docker logs openclaw-gateway | grep "iPhone metrics"`.

import { RoomError } from "./room-error.js";

// A version or build number as the app's Info.plist has it: "1.0", "14", "1.0 (14)".
const VERSION = /^[0-9A-Za-z.() +-]{1,32}$/;
// A day is what MetricKit reports; a month is far past anything real.
const LONGEST_WINDOW_MS = 31 * 24 * 60 * 60 * 1000;
const MOST_HANGS = 100_000;

function refuse(message) {
  throw new RoomError("INVALID_REQUEST", message);
}

function isCount(value, most) {
  return Number.isSafeInteger(value) && value >= 0 && value <= most;
}

function isAmount(value, most) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= most;
}

// The log line for one report, or a refusal that says which part was wrong.
export function phoneMetricsLine(params) {
  const { from, to, appVersion, build, scrollHitchMsPerSecond, hangCount, hangSeconds } = params ?? {};
  if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to) || to < from || to - from > LONGEST_WINDOW_MS) {
    refuse("bad metrics window");
  }
  if (typeof appVersion !== "string" || !VERSION.test(appVersion) || typeof build !== "string" || !VERSION.test(build)) {
    refuse("bad app version");
  }
  // Ten seconds of hitching in every second is impossible; a thousand milliseconds is all.
  if (scrollHitchMsPerSecond !== null && scrollHitchMsPerSecond !== undefined && !isAmount(scrollHitchMsPerSecond, 1000)) {
    refuse("bad scroll hitch ratio");
  }
  if (!isCount(hangCount, MOST_HANGS) || !isAmount(hangSeconds, LONGEST_WINDOW_MS / 1000)) {
    refuse("bad hang figures");
  }
  const window = `${new Date(from).toISOString()} to ${new Date(to).toISOString()}`;
  const scrolling = typeof scrollHitchMsPerSecond === "number"
    ? `scroll hitches ${scrollHitchMsPerSecond.toFixed(1)} ms/s`
    : "no scrolling measured";
  return `household-app: iPhone metrics, build ${build} (${appVersion}), ${window}: ${scrolling}, ${hangCount} hangs, ${hangSeconds.toFixed(1)} s hanging`;
}
