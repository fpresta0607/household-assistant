// household_location: where this gateway's owner is, read-only, for the assistant, in the
// turns the owner's own choice in the app covers and in no other (turn.js): the owner's
// own turns, their thread and a family-room turn they started, and anyone else's
// family-room turn only while the owner shares with the family. Anyone else's family-room
// turn also gets only The Fam's tool allowlist, so the tool reaches it only once the
// household puts it on that list.
//
// The position is the owner's alone, so in anyone else's family-room turn the tool says
// the same thing whether the owner shares only with the assistant or not at all.

import { FAMILY, isOwnersTurn, turnOf } from "./turn.js";

export const LOCATION_TOOL = "household_location";
const EARTH_RADIUS_KM = 6371.0088;

function result(payload, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], ...(isError ? { isError } : {}) };
}

const isDegrees = (value, limit) => typeof value === "number" && Number.isFinite(value) && Math.abs(value) <= limit;

function cleanArguments(args) {
  if (args === undefined || args === null) return {};
  if (typeof args !== "object" || Array.isArray(args) || Object.keys(args).some((key) => key !== "to")) return null;
  if (args.to === undefined) return {};
  const { to } = args;
  if (!to || typeof to !== "object" || Object.keys(to).some((key) => key !== "latitude" && key !== "longitude")) return null;
  return isDegrees(to.latitude, 90) && isDegrees(to.longitude, 180) ? { to } : null;
}

// The great-circle distance, to a tenth of a kilometre.
function distanceKm(from, to) {
  const radians = (degrees) => (degrees * Math.PI) / 180;
  const dLatitude = radians(to.latitude - from.latitude);
  const dLongitude = radians(to.longitude - from.longitude);
  const half = Math.sin(dLatitude / 2) ** 2 +
    Math.cos(radians(from.latitude)) * Math.cos(radians(to.latitude)) * Math.sin(dLongitude / 2) ** 2;
  return Math.round(2 * EARTH_RADIUS_KM * Math.asin(Math.sqrt(half)) * 10) / 10;
}

// The tool for this turn, or null. `current` reads the owner's latest position at the
// moment the tool runs, so a share that ended or a channel that stopped answers nothing.
export function createLocationTool({ context, owner, ownerName, people, current, now = Date.now }) {
  const turn = turnOf(context, { owner, people });
  if (turn === null) return null;
  const isFamilyOnly = !isOwnersTurn(turn);
  const notShared = isFamilyOnly
    ? `${ownerName} is not sharing a location with the family room.`
    : `${ownerName} is not sharing a location now. It is off until they turn it on in the Steward AI app, under Settings, Location.`;
  return {
    name: LOCATION_TOOL,
    label: "Location",
    description:
      `Where ${ownerName} is, from their iPhone, while they share it: the latest position, how exact it is and ` +
      "how long ago it was measured. The phone updates it only after moving a fair way or arriving somewhere, so " +
      "say how old it is. Use it only for what was asked in this turn, such as how far from home, when to leave or " +
      "what is nearby; pass `to` with a place's coordinates for the straight-line distance. Never write the " +
      "coordinates into memory, notes, files or reminders, never send them anywhere but this conversation, and to " +
      "search for places nearby name the town or street, not the coordinates. An accuracy over a kilometre is " +
      "approximate, set by them on the iPhone: speak of the area, not an address.",
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        to: {
          type: "object",
          additionalProperties: false,
          required: ["latitude", "longitude"],
          description: "A place to measure the straight-line distance to, such as home.",
          properties: {
            latitude: { type: "number", minimum: -90, maximum: 90 },
            longitude: { type: "number", minimum: -180, maximum: 180 },
          },
        },
      },
    },
    async execute(_id, args) {
      const cleaned = cleanArguments(args);
      if (cleaned === null) {
        return result({ code: "invalid_arguments", message: "Use only `to`, with a latitude and a longitude." }, true);
      }
      const here = current();
      if (!here || (isFamilyOnly && here.audience !== FAMILY)) return result({ shared: false, message: notShared });
      return result({
        shared: true,
        person: ownerName,
        latitude: here.latitude,
        longitude: here.longitude,
        accuracyMeters: here.accuracy,
        measuredAt: new Date(here.at).toISOString(),
        minutesAgo: Math.max(0, Math.round((now() - here.at) / 60_000)),
        sharedWith: here.audience,
        sharingUntil: here.until === null ? null : new Date(here.until).toISOString(),
        ...(cleaned.to ? { distanceKm: distanceKm(here, cleaned.to) } : {}),
      });
    },
  };
}
