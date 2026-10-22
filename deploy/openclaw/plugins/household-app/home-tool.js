// household_home: the thermostat, the music and the living room TV, in the owner's own
// thread and the family room (turn.js), and nowhere else. A family-room turn also gets
// only The Fam's tool allowlist, so the tool reaches the room only once it is on that list.
//
// The house is reached only through the home key holder on the host (home-client.js),
// which holds the token and the TV's pairing and keeps the real limits: the thermostat
// within 62 to 80 degrees in its own mode and a yes each time, the volume never above 70%
// and a yes to raise it above 40%, and music only on the living room TV. This tool only
// names the actions.

import { HomeUnavailable } from "./home-client.js";
import { turnOf } from "./turn.js";

export const HOME_TOOL = "household_home";

// Only the fields the call gave, so the key holder sees no empty ones.
const given = (args, names) => Object.fromEntries(names.filter((name) => args[name] !== undefined).map((name) => [name, args[name]]));

// Each action, the key holder's tool, and the arguments it is given.
const ACTIONS = {
  status: ["home_status", [], () => ({})],
  thermostat: ["home_thermostat", ["low", "high", "target", "confirmed"], (args) => ({ ...given(args, ["low", "high", "target"]), confirmed: args.confirmed === true })],
  volume: ["home_volume", ["percent", "step", "confirmed"], (args) => ({ ...given(args, ["percent", "step"]), confirmed: args.confirmed === true })],
  music: ["home_music", ["control"], (args) => ({ action: args.control })],
  play: ["home_play", ["query", "kind", "link"], (args) => given(args, ["query", "kind", "link"])],
  open_spotify: ["home_open_spotify", [], () => ({})],
  youtube: ["home_youtube", ["link"], (args) => ({ link: args.link })],
  video: ["home_video", ["control", "seconds"], (args) => given(args, ["control", "seconds"])],
  tv: ["home_tv", ["power"], (args) => ({ power: args.power })],
};

function result(payload, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], ...(isError ? { isError } : {}) };
}

const failure = (code, message) => result({ code, message }, true);

// The key holder answers one text block of JSON; anything else is not passed on.
function answerOf(answer) {
  const blocks = Array.isArray(answer?.content) ? answer.content : [];
  const [block] = blocks;
  if (blocks.length !== 1 || block?.type !== "text" || typeof block.text !== "string") {
    return failure("mcp_transport_error", "The house's answer was not what was expected.");
  }
  return { content: [{ type: "text", text: block.text }], ...(answer.isError === true ? { isError: true } : {}) };
}

export function createHomeTool({ context, owner, people, call }) {
  if (turnOf(context, { owner, people }) === null) return null;
  return {
    name: HOME_TOOL,
    label: "Home",
    description:
      "The house's thermostat, and Spotify, volume and power on the living room TV. `status` reads the thermostat, " +
      "the music with what is playing and where and Spotify's `devices`, and the TV's power and volume. `thermostat` sets " +
      "what its `mode` holds, in whole °F from 62 to 80: one `target` on heat or cool, or `low` and `high` at least 5 " +
      "apart on heat_cool. `play` plays on the TV: pass what the person asked for as `query` (a song with " +
      "its artist when they named one) and its `kind`, track, album, artist or playlist, and Spotify's own search picks " +
      "it; pass `link` instead only for a full open.spotify.com link the person gave. To change the song, call `play` " +
      "again. `play` wakes the TV and opens Spotify by itself, so never turn the TV on first. `open_spotify` wakes the " +
      "TV and opens Spotify without playing anything. `music` is `control`: pause, resume, next or previous. " +
      "`youtube` opens YouTube on the TV and plays `link`, one video's youtube.com or youtu.be link: when the person " +
      "names or describes a video instead, find its link with a web search first, and never guess one. `video` is " +
      "`control` for what plays in YouTube: pause, resume, next, previous, or seek with `seconds`, negative to go back. `volume` " +
      "sets the TV's `percent`, 0 to 70, or `step` up or down by 10. `tv` turns the TV `power` on or off. A change that needs " +
      "a yes answers `needs_yes` with the question: ask the person exactly that, and call again with `confirmed: true` " +
      "only after they say yes to it. Never pass `confirmed` on your own. Report what the answer says the house did, " +
      "not what was asked. When an answer has a `message`, tell the person that reason in plain words.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: Object.keys(ACTIONS) },
        low: { type: "integer", minimum: 62, maximum: 75 },
        high: { type: "integer", minimum: 67, maximum: 80 },
        target: { type: "integer", minimum: 62, maximum: 80 },
        percent: { type: "integer", minimum: 0, maximum: 70 },
        step: { type: "string", enum: ["up", "down"] },
        control: { type: "string", enum: ["pause", "resume", "next", "previous", "seek"] },
        seconds: { type: "integer", minimum: -600, maximum: 600 },
        query: { type: "string", maxLength: 200, description: "What to play, as the person said it, such as a song and its artist." },
        kind: { type: "string", enum: ["track", "album", "artist", "playlist"] },
        link: { type: "string", maxLength: 300, description: "A full open.spotify.com link for play, or a YouTube video's link for youtube." },
        power: { type: "string", enum: ["on", "off"] },
        confirmed: { type: "boolean", description: "True only after the person said yes to this exact change." },
      },
    },
    async execute(_id, args, signal) {
      const action = typeof args?.action === "string" && Object.hasOwn(ACTIONS, args.action) ? ACTIONS[args.action] : null;
      if (!action || Object.keys(args).some((key) => key !== "action" && !action[1].includes(key))) {
        return failure("invalid_arguments", `Use one action of ${Object.keys(ACTIONS).join(", ")}, with only its own fields.`);
      }
      const [tool, , argumentsOf] = action;
      try {
        return answerOf(await call(tool, argumentsOf(args), { signal }));
      } catch (error) {
        if (error instanceof HomeUnavailable) return failure(error.code, error.message);
        throw error;
      }
    },
  };
}
