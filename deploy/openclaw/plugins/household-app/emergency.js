// The emergency card: the vet, poison control, the pediatrician, the insurance details and the
// neighbor's number, short enough to read out loud in a panic.
//
// Its entries are lines of the household note under one topic, "Emergency card", a line per
// contact with who it is as the line's item ("Vet") and the name and number as its words, so
// both assistants keep it current there the way they keep anything else the family shares:
// `household_note` add, correct and remove. `/emergency` answers with it at once, with no
// model; asked in words or by voice, the assistant reads the topic and says it.

export const EMERGENCY_TOPIC = "Emergency card";
// The order a panic reads it in, by item; anything else after them, as kept.
const ORDER = ["vet", "poison control", "pediatrician", "insurance", "neighbor"];
// Poison control is a public number, the same for every household in the United States, so
// the card has it before anyone writes it down.
const POISON_CONTROL = "1-800-222-1222";
export const EMERGENCY_GUIDANCE =
  `The family's emergency card is the household note's topic "${EMERGENCY_TOPIC}": one line per contact, its item who it is ` +
  "(Vet, Poison control, Pediatrician, Insurance, Neighbor) and its words the name and number. Keep it current there. " +
  "When someone asks for it, give it as those few short lines and nothing else, and when they asked by voice, also read it aloud with speak.";

const rank = (item) => {
  const found = ORDER.findIndex((name) => item.toLowerCase().startsWith(name));
  return found === -1 ? ORDER.length : found;
};

// The card as its lines, from the topic's rows, with poison control's public number when
// the family has not kept one of its own.
export function cardOf(log) {
  const rows = (log?.rows ?? []).filter((row) => typeof row.item === "string" && row.item.trim());
  const ordered = rows.toSorted((left, right) => rank(left.item) - rank(right.item));
  const lines = ordered.map((row) => `${row.item}: ${row.text}`);
  if (!rows.some((row) => rank(row.item) === ORDER.indexOf("poison control"))) {
    const at = ordered.findIndex((row) => rank(row.item) > ORDER.indexOf("poison control"));
    lines.splice(at === -1 ? lines.length : at, 0, `Poison control: ${POISON_CONTROL}`);
  }
  return [
    "Emergency: call 911 first.",
    ...lines,
    ...(rows.length === 0 ? [`Nothing else is on the card yet: ask your assistant to keep the vet, the pediatrician, insurance and a neighbor under "${EMERGENCY_TOPIC}".`] : []),
  ];
}
