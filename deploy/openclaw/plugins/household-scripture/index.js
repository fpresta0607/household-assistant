// The Bible for every household, in the gateway itself: the `scripture` tool reads verses,
// searches them by meaning, lists a verse's cross references and original-language words,
// and keeps the household's sermons and study plans. It replaces the SIQsermon skill, which
// reached SIQsermon's backend and its Qdrant over SIQsermon's network: nothing here needs
// an account, another service or a network but OpenRouter, for the meaning of a question.
//
// The verses come from the database scripts/scripture-build.py writes (bible.js), mounted
// read-only; the archive lives in the gateway's state (archive.js). A tool rather than a
// skill, so the model sees it on every turn instead of having to read a catalog entry it
// may skip, and so it runs in the gateway and needs no shell.

import { readFileSync } from "node:fs";
import path from "node:path";

import { openArchive, KINDS } from "./archive.js";
import { Bible, passageCard } from "./bible.js";
import { BIBLE_VERSIONS, ScriptureError, bookName, parseReference, referenceOf, verseId } from "./books.js";

export const PLUGIN_ID = "household-scripture";
export const TOOL = "scripture";
export const DEFAULT_BIBLE_FILE = "/opt/household-scripture/bible.sqlite";
const OPENROUTER_EMBEDDINGS = "https://openrouter.ai/api/v1/embeddings";
const EMBED_TIMEOUT_MS = 20_000;
const SEARCH_RESULTS = 6;
const MAX_SEARCH_RESULTS = 12;
const ACTIONS = ["ref", "search", "study", "sermons", "plans", "save"];

// The plugin's config, the same schema the manifest declares.
const CONFIG_SCHEMA = JSON.parse(readFileSync(new URL("./openclaw.plugin.json", import.meta.url), "utf8")).configSchema;

export function parseConfig(raw) {
  const value = raw ?? {};
  if (typeof value !== "object" || Array.isArray(value)) return { error: "expected a config object" };
  const unknown = Object.keys(value).filter((key) => !(key in CONFIG_SCHEMA.properties));
  if (unknown.length > 0) return { error: `unknown config keys: ${unknown.join(", ")}` };
  if (value.bibleFile !== undefined && (typeof value.bibleFile !== "string" || !path.isAbsolute(value.bibleFile))) {
    return { error: "bibleFile must be an absolute path" };
  }
  if (value.edition !== undefined && !(value.edition in BIBLE_VERSIONS)) {
    return { error: `edition must be one of ${Object.keys(BIBLE_VERSIONS).join(", ")}` };
  }
  return { value: { bibleFile: value.bibleFile ?? DEFAULT_BIBLE_FILE, edition: value.edition ?? null } };
}

const configSchema = {
  safeParse(value) {
    const parsed = parseConfig(value);
    if (parsed.error) return { success: false, error: { issues: [{ path: [], message: parsed.error }] } };
    return { success: true, data: value };
  },
  jsonSchema: CONFIG_SCHEMA,
};

const answer = (text) => ({ content: [{ type: "text", text }] });
const failure = (text) => ({ content: [{ type: "text", text }], isError: true });

const DESCRIPTION =
  "The Bible: use it for every question that touches a verse, a passage, a doctrine, a sermon or a study plan, before answering, " +
  "even for John 3:16: never quote scripture from memory. " +
  "`ref` reads a reference you know (`reference`: 'John 3:16', 'Psalms 23:1-6', at most 40 verses); with `card: true` it returns a " +
  "steward-card block for the Steward app, to paste unchanged before your own words. " +
  "`search` finds verses by meaning for a topic, a question or half-remembered wording (`query`), with cross references and the " +
  "original-language words; never use it to look up a reference. `study` gives one verse's cross references and Hebrew or Greek words. " +
  "`sermons` and `plans` list the household's kept sermons and study plans, or read one by `id`; `save` keeps one (`kind`, `title`, " +
  "`text`, optional `detail`) only when someone asks to keep it. Quote book, chapter and verse exactly as the tool prints them; " +
  "if it finds nothing, say so.";

const PARAMETERS = {
  type: "object",
  additionalProperties: false,
  required: ["action"],
  properties: {
    action: { type: "string", enum: ACTIONS },
    reference: { type: "string", maxLength: 80, description: "For ref and study: 'Book chapter:verse' or a short range." },
    card: { type: "boolean", description: "For ref in the Steward app: return a scripture card block." },
    translation: { type: "string", maxLength: 8, description: "For ref: a translation this Bible holds; its first when unset." },
    query: { type: "string", maxLength: 500, description: "For search: a topic, a question or remembered wording." },
    limit: { type: "integer", minimum: 1, maximum: MAX_SEARCH_RESULTS, description: `For search: how many verses, ${SEARCH_RESULTS} when unset.` },
    id: { type: "integer", minimum: 1, description: "For sermons and plans: the one to read." },
    kind: { type: "string", enum: KINDS, description: "For save: a sermon or a study plan." },
    title: { type: "string", maxLength: 200, description: "For save: its title." },
    detail: { type: "string", maxLength: 200, description: "For save: its passage, series or study method." },
    text: { type: "string", maxLength: 200_000, description: "For save: the whole sermon or plan." },
  },
};

export function createScripture(api, config, options = {}) {
  const env = options.env ?? process.env;
  const fetchFn = options.fetchFn ?? fetch;
  const log = api.logger;
  let bible = null;
  let archive = null;

  function openBible() {
    bible ??= new Bible(config.bibleFile);
    return bible;
  }

  function openHouseholdArchive() {
    if (!archive) {
      archive = openArchive(path.join(api.runtime.state.resolveStateDir(env), PLUGIN_ID));
    }
    const { kept, refused } = archive.importWaiting();
    if (kept > 0) log?.info?.(`${PLUGIN_ID}: kept ${kept} imported sermons and plans`);
    if (refused.length > 0) log?.warn?.(`${PLUGIN_ID}: refused ${refused.length} import files that are not sermons or plans`);
    return archive;
  }

  // The question's meaning vector from OpenRouter, with the model the verses were built with.
  async function embed(query, signal) {
    const key = env.OPENROUTER_API_KEY;
    if (!key) throw new Error("no OpenRouter key");
    const timeout = AbortSignal.timeout(EMBED_TIMEOUT_MS);
    const response = await fetchFn(OPENROUTER_EMBEDDINGS, {
      method: "POST",
      headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
      body: JSON.stringify({ model: bible.embeddingModel, input: query }),
      signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
    });
    if (!response.ok) throw new Error(`OpenRouter answered ${response.status}`);
    const body = await response.json();
    const vector = body?.data?.[0]?.embedding;
    if (!Array.isArray(vector) || vector.length === 0) throw new Error("OpenRouter returned no vector");
    return vector;
  }

  function verseBlock(id, score, translation) {
    const text = bible.text(id, translation);
    const lines = [`${referenceOf(id).label} (${translation})${score === null ? "" : ` score ${score.toFixed(3)}`}`, `  ${text}`];
    const xrefs = bible.crossReferences(id);
    if (xrefs.length > 0) lines.push(`  cross-refs: ${xrefs.map((xref) => xref.label).join("; ")}`);
    const words = bible.words(id);
    if (words.length > 0) {
      lines.push(
        "  word study: " +
          words.map((word) => `${word.translit || word.lemma || word.strongs} (${word.strongs}) "${(word.gloss || "").slice(0, 60)}"`).join("; "),
      );
    }
    return lines.join("\n");
  }

  async function ref(params) {
    const reference = parseReference(params.reference);
    const translation = openBible().translationFor(params.translation);
    const passage = bible.passage(reference, translation);
    const book = bookName(reference.book);
    if (passage.found.length === 0) {
      const range = reference.last !== reference.first ? `-${reference.last}` : "";
      return failure(`This Bible holds nothing at ${book} ${reference.chapter}:${reference.first}${range}. Check the reference.`);
    }
    if (params.card === true) {
      const card = passageCard(reference, passage, config.edition);
      return answer("```steward-card\n" + JSON.stringify(card) + "\n```");
    }
    const lines = passage.found.map((verse) => `${book} ${reference.chapter}:${verse.n} (${translation})\n  ${verse.text}`);
    if (passage.missing.length > 0) {
      lines.push(`\nNot in this Bible: verse(s) ${passage.missing.join(", ")} of ${book} ${reference.chapter}.`);
    }
    return answer(lines.join("\n"));
  }

  async function search(params, signal) {
    const query = String(params.query ?? "").trim();
    if (!query) return failure("Give a topic, a question or the wording you remember as `query`.");
    const limit = Number.isInteger(params.limit) ? Math.min(Math.max(params.limit, 1), MAX_SEARCH_RESULTS) : SEARCH_RESULTS;
    openBible();
    let found = null;
    let note = "";
    if (bible.hasMeaning) {
      try {
        found = bible.byMeaning(await embed(query, signal), limit);
      } catch (error) {
        log?.warn?.(`${PLUGIN_ID}: a search fell back to words: ${error?.message ?? error}`);
        note = "Searched by words, not meaning: the meaning of the question could not be read just now.\n\n";
      }
    } else {
      note = "Searched by words, not meaning: this Bible's meaning vectors are not built yet.\n\n";
    }
    found ??= bible.byWords(query, limit);
    if (found.length === 0) return answer(`${note}This Bible found no verses for: ${query}`);
    const lowScores = found.every((hit) => hit.score !== null && hit.score < 0.3);
    const blocks = found.map((hit) => verseBlock(hit.id, hit.score, bible.primary));
    const caution = lowScores ? "\n\nEvery score is low: nothing here is close, so say so rather than stretching one to fit." : "";
    return answer(`${note}${blocks.join("\n\n")}${caution}`);
  }

  async function study(params) {
    const reference = parseReference(params.reference);
    if (reference.first !== reference.last) return failure("`study` takes one verse: 'Book chapter:verse'.");
    openBible();
    const id = verseId(reference.book, reference.chapter, reference.first);
    if (bible.text(id) === null) return failure(`This Bible holds nothing at ${referenceOf(id).label}. Check the reference.`);
    return answer(verseBlock(id, null, bible.primary));
  }

  function listOrRead(kind, params) {
    const kept = openHouseholdArchive();
    const noun = kind === "sermon" ? "sermons" : "study plans";
    if (params.id !== undefined) {
      const item = kept.read(kind, params.id);
      if (!item) return failure(`There is no kept ${kind} ${params.id}. List them with ${kind === "sermon" ? "sermons" : "plans"}.`);
      const header = [`${item.id}  ${item.created_at.slice(0, 10)}  ${item.title}`, item.detail ? `(${item.detail})` : null].filter(Boolean).join("\n");
      return answer(`${header}\n\n${item.body}`);
    }
    const items = kept.list(kind);
    if (items.length === 0) return answer(`The household has no kept ${noun} yet.`);
    return answer(items.map((item) => `${String(item.id).padStart(4)}  ${item.created_at.slice(0, 10)}  ${item.title}${item.detail ? `  (${item.detail})` : ""}`).join("\n"));
  }

  function save(params) {
    if (!KINDS.includes(params.kind)) return failure(`\`kind\` is one of ${KINDS.join(", ")}.`);
    const id = openHouseholdArchive().keep({ kind: params.kind, title: params.title, detail: params.detail, body: params.text });
    return answer(`Kept as ${params.kind} ${id}. It is in ${params.kind === "sermon" ? "sermons" : "plans"} now.`);
  }

  function tool() {
    return {
      name: TOOL,
      label: "Scripture",
      description: DESCRIPTION,
      parameters: PARAMETERS,
      async execute(_id, params, signal) {
        try {
          switch (params?.action) {
            case "ref":
              return await ref(params);
            case "search":
              return await search(params, signal);
            case "study":
              return await study(params);
            case "sermons":
              return listOrRead("sermon", params);
            case "plans":
              return listOrRead("plan", params);
            case "save":
              return save(params);
            default:
              return failure(`\`action\` is one of ${ACTIONS.join(", ")}.`);
          }
        } catch (error) {
          if (error instanceof ScriptureError) return failure(error.message);
          log?.warn?.(`${PLUGIN_ID}: ${params?.action} failed: ${error?.message ?? error}`);
          return failure(`The scripture tool could not ${params?.action ?? "run"}: ${error?.message ?? error}`);
        }
      },
    };
  }

  return {
    tool,
    close() {
      bible?.close();
      archive?.close();
      bible = null;
      archive = null;
    },
  };
}

export default {
  id: PLUGIN_ID,
  name: "Household scripture",
  description: "The Bible in every household's gateway: verses, search by meaning, cross references, word studies, and the household's sermons.",
  configSchema,
  register(api) {
    const parsed = parseConfig(api.pluginConfig);
    if (parsed.error) {
      api.logger.error(`${PLUGIN_ID}: not started, ${parsed.error}`);
      return;
    }
    const scripture = createScripture(api, parsed.value);
    api.registerTool(() => scripture.tool(), { names: [TOOL] });
  },
};
