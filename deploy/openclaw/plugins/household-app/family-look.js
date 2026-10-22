// The family room's shared look, which either person may change from their phone: the
// colour of the ring round the room's face, and its appearance, Auto (each phone's own) or
// Custom (one chat background for both phones). Each change is one "look" entry in the
// family room, written as the person who made it, so the relay carries it like their
// messages and each phone shows it in the room as a line with its time, such as
// "Franco changed the group color". Changing the room's photo writes one too.
//
// An entry holds only what it changed, and the look is every entry folded in the order
// they were made, so two people changing different things at once both keep their
// change. Custom keeps the latest custom background whoever chose it, so Auto and back
// to Custom shows it again.

const CHANGES = new Set(["photo", "color", "appearance"]);
const APPEARANCES = new Set(["auto", "custom"]);
// The chat backgrounds a phone can draw for everyone: its own photo is not shared.
export const FAMILY_BACKGROUNDS = new Set(["rainbow", "dawn", "night"]);

const refuseWith = (refuse) => (message) => refuse(`bad look: ${message}`);

const isUnit = (value) => typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;

function cleanRing(raw, fail) {
  if (raw === null) return null;
  if (typeof raw !== "object" || Array.isArray(raw)) fail("a color is red, green and blue");
  const { red, green, blue } = raw;
  if (![red, green, blue].every(isUnit)) fail("a color is red, green and blue, each 0 to 1");
  return { red, green, blue };
}

// What one change says, cleaned. A phone changes the color or the appearance; the photo's
// line comes from setting the photo itself, so only the other gateway may hand one over.
export function cleanLookChange(raw, refuse, { mayBePhoto = false } = {}) {
  const fail = refuseWith(refuse);
  if (!raw || typeof raw !== "object") fail("no change");
  const { change } = raw;
  if (!CHANGES.has(change) || (change === "photo" && !mayBePhoto)) fail("unknown change");
  if (change === "photo") return { change };
  if (change === "color") {
    if (!("ring" in raw)) fail("a color change names its color, or null for the default");
    return { change, ring: cleanRing(raw.ring, fail) };
  }
  if (!APPEARANCES.has(raw.appearance)) fail("an appearance is auto or custom");
  if (raw.background === undefined || raw.background === null) return { change, appearance: raw.appearance };
  if (!FAMILY_BACKGROUNDS.has(raw.background)) fail("unknown background");
  return { change, appearance: raw.appearance, background: raw.background };
}

// The look every entry made, oldest first: each field as its newest change left it.
export function foldLook(entries) {
  const look = { ring: null, appearance: "auto", background: null };
  for (const entry of entries) {
    if (entry.change === "color") look.ring = entry.ring ?? null;
    if (entry.change === "appearance") {
      look.appearance = entry.appearance;
      if (entry.background) look.background = entry.background;
    }
  }
  return look;
}
