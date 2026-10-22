// The cards in an assistant's message, as the gateway reads them: each closed block marked
// `steward-card` whose body is one JSON object. The app draws them; see
// deploy/openclaw/skills/steward-cards/SKILL.md for the format the assistants write.

export const OPENING = "```steward-card";
export const CLOSING = "```";
const FENCE = /^(`{3,}|~{3,})/;

// Each closed steward-card block's body. One inside another fenced block is that block's
// text, and one that never closes is no card.
function blocks(text) {
  const lines = text.split("\n");
  const found = [];
  let fence = null;
  for (let index = 0; index < lines.length; index += 1) {
    const trimmed = lines[index].trim();
    if (fence) {
      const closing = FENCE.exec(trimmed);
      if (closing && closing[1][0] === fence[0] && closing[1].length >= fence.length && trimmed === closing[1]) fence = null;
      continue;
    }
    if (trimmed === OPENING) {
      const end = lines.findIndex((line, at) => at > index && line.trim() === CLOSING);
      if (end === -1) break;
      found.push(lines.slice(index + 1, end).join("\n"));
      index = end;
      continue;
    }
    const opening = FENCE.exec(trimmed);
    if (opening) fence = opening[1];
  }
  return found;
}

function parse(body) {
  try {
    const card = JSON.parse(body);
    return card && typeof card === "object" && !Array.isArray(card) ? card : null;
  } catch {
    return null;
  }
}

// Every card in the text that reads as one, in order.
export function cardsIn(text) {
  return blocks(text).map(parse).filter((card) => card !== null);
}
