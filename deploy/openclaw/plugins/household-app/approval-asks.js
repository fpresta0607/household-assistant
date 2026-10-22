// Which steps of the assistant's run wait for the owner's yes: a change to a calendar or a
// reminder, in a turn the owner's phone started, in the owner's own thread or in the family
// room. The household chose this for the app, and approvals.js shows the request as a card
// in the owner's thread either way. Reading a calendar never asks.
//
// It asks only when the turn's requester is this channel and its session is the owner's
// thread or the owner's own session of the family room (turn.js ownersFamilySession), which
// only the owner's turns run in, so it asks whatever sender the hook is told. Everyone
// else's family-room turns run in the room's shared session with The Fam's tools, which
// change no calendar (family-tools.js). Telegram, a scheduled run and every other session
// get nothing from here, exactly as before.
//
// A reminder is a job of OpenClaw's scheduler. OpenClaw 2026.9.4 names that tool
// `automations`, and turns the model's `cron` into it before any hook sees the call. Adding,
// updating or removing a job asks, and so does a command running OpenClaw's own `cron` or
// `automations` CLI to do the same.
//
// A calendar changes through a command a calendar skill runs: gog's `calendar` commands for
// Google, and apple-cal-anywhere's applecal.py for iCloud. Their reads are listed below, and
// any other calendar command asks: the programs' full command lists live with them, and a
// tap too many costs less than a change nobody saw.
//
// The same reading says what a step changed once it has run, as data, for the reply's
// `did` list (did.js): an event added, moved, changed or deleted, with its title and when
// it is, or a reminder set, moved, changed or deleted.

const CHANNEL = "household";
// One yes, for this step only, or a no. OpenClaw denies a request nobody answered once the
// ten minutes it allows at most have passed.
const DECISIONS = ["allow-once", "deny"];
const TIMEOUT_MS = 10 * 60_000;
// What OpenClaw lets a plugin put in an approval's title and description.
const MAX_TITLE = 80;
const MAX_DESCRIPTION = 512;

const REMINDER_CHANGES = new Set(["add", "update", "remove"]);
// The scheduler CLI's words for the same changes, and the root options that take a value.
const REMINDER_COMMANDS = { add: "add", create: "add", edit: "update", enable: "update", disable: "update", remove: "remove", rm: "remove", delete: "remove" };
const OPENCLAW_VALUE_OPTIONS = ["--profile", "--log-level", "--container"];
const CALENDAR_READS = new Set(["list", "ls", "get", "show", "search", "events", "event", "calendars", "colors", "freebusy", "conflicts", "doctor", "help"]);
const ADDS = new Set(["create", "add", "new", "insert"]);
const MOVES = new Set(["update", "edit", "move", "patch"]);
const DELETES = new Set(["delete", "remove", "rm", "del", "cancel"]);
const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;
const HAS_ZONE = /(?:z|[+-]\d{2}:?\d{2})$/i;
const INTERVALS = [["day", 86_400_000], ["hour", 3_600_000], ["minute", 60_000], ["second", 1000]];

const isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value);
const text = (value) => (typeof value === "string" && value.trim() ? value.trim() : undefined);

// A time as a person says it, "Friday 16 October, 7 pm", in the gateway's own time zone
// unless one is given. A date alone, or an all-day event's, is the date. A time with no
// offset is UTC to the programs that read it so, and otherwise the time as written.
// Anything that is no time is shown as given.
function spokenTime(value, { timeZone, isAllDay = false, isNaiveUtc }) {
  const given = String(value).trim();
  const isDate = DATE_ONLY.test(given);
  const hasZone = HAS_ZONE.test(given);
  const moment = new Date(isDate ? `${given}T00:00:00Z` : hasZone ? given : `${given}Z`);
  if (Number.isNaN(moment.getTime())) return given || undefined;
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone: !isDate && (hasZone || isNaiveUtc) ? timeZone : "UTC",
      weekday: "long",
      day: "numeric",
      month: "long",
      hour: "numeric",
      minute: "2-digit",
      hour12: true,
    }).formatToParts(moment).map(({ type, value: part }) => [type, part]),
  );
  const day = `${parts.weekday} ${parts.day} ${parts.month}`;
  if (isDate || isAllDay) return day;
  return `${day}, ${parts.hour}${parts.minute === "00" ? "" : `:${parts.minute}`} ${parts.dayPeriod.toLowerCase()}`;
}

// A time with no offset, as the clock in `timeZone` shows it, as the moment it names.
function zonedMoment(given, timeZone) {
  const asIfUtc = new Date(`${given}Z`);
  if (Number.isNaN(asIfUtc.getTime())) return asIfUtc;
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "numeric",
      minute: "numeric",
      second: "numeric",
    }).formatToParts(asIfUtc).map(({ type, value: part }) => [type, Number(part)]),
  );
  const shown = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
  return new Date(2 * asIfUtc.getTime() - shown);
}

// When a change is for, as the did list keeps it: the day of an all-day event or of a date
// alone, or else the exact moment. A time with no offset is UTC to the programs that read it
// so, and otherwise the gateway's own clock, which is the time as written. Nothing for
// anything that is no time.
function momentOf(value, { timeZone, isAllDay = false, isNaiveUtc }) {
  const given = String(value).trim();
  const day = given.slice(0, 10);
  if (DATE_ONLY.test(given) || (isAllDay && DATE_ONLY.test(day))) return { day };
  const hasZone = HAS_ZONE.test(given);
  const moment = hasZone || isNaiveUtc ? new Date(hasZone ? given : `${given}Z`) : zonedMoment(given, timeZone);
  return Number.isNaN(moment.getTime()) ? {} : { at: moment.toISOString() };
}

function spokenSchedule(schedule, timeZone) {
  if (!isRecord(schedule)) return undefined;
  if (schedule.kind === "at" && text(schedule.at)) return spokenTime(schedule.at, { timeZone, isNaiveUtc: true });
  if (schedule.kind === "cron" && text(schedule.expr)) return `on the schedule ${text(schedule.expr)}`;
  if (schedule.kind !== "every" || !Number.isInteger(schedule.everyMs)) return undefined;
  const [unit, size] = INTERVALS.find(([, length]) => schedule.everyMs >= length && schedule.everyMs % length === 0) ?? [];
  if (!unit) return undefined;
  const count = schedule.everyMs / size;
  return count === 1 ? `every ${unit}` : `every ${count} ${unit}s`;
}

// The scheduler tool adding, updating or removing a job: when it is for, its name and what
// it says, or the job's id when the call names nothing else.
function reminderChange(params, timeZone) {
  if (!REMINDER_CHANGES.has(params?.action)) return null;
  const job = isRecord(params.job) ? params.job : {};
  const when = spokenSchedule(job.schedule, timeZone);
  const name = text(job.name);
  const says = text(job.payload?.text) ?? text(job.payload?.message);
  const jobId = text(params.jobId) ?? text(params.id);
  const titles = {
    add: when ? `Add a reminder, ${when}` : "Add a reminder",
    update: when && job.schedule.kind === "at" ? `Move a reminder to ${when}` : "Change a reminder",
    remove: "Delete a reminder",
  };
  const description = (name && says ? `${name}: ${says}` : name ?? says) ?? (jobId ? `Reminder ${jobId}` : "A reminder");
  const moment = job.schedule?.kind === "at" && text(job.schedule.at) ? momentOf(job.schedule.at, { timeZone, isNaiveUtc: true }) : {};
  const changes = { add: "added", update: moment.at || moment.day ? "moved" : "changed", remove: "deleted" };
  const title = says ?? name;
  return {
    title: titles[params.action],
    description,
    did: { kind: "reminder", change: changes[params.action], ...(title ? { title } : {}), ...moment },
  };
}

// A command's simple commands, each as its words, with quotes and escapes resolved the way
// a shell resolves them: enough to find a program and read its options, not a shell.
export function simpleCommands(command) {
  const commands = [[]];
  let word = null;
  let quote = null;
  const endWord = () => {
    if (word !== null) commands.at(-1).push(word);
    word = null;
  };
  for (let index = 0; index < command.length; index += 1) {
    const char = command[index];
    if (quote === "'") {
      if (char === "'") quote = null;
      else word += char;
    } else if (char === "\\" && index + 1 < command.length) {
      index += 1;
      word = (word ?? "") + command[index];
    } else if (quote === '"') {
      if (char === '"') quote = null;
      else word += char;
    } else if (char === "'" || char === '"') {
      quote = char;
      word ??= "";
    } else if (/[;&|\n]/.test(char)) {
      endWord();
      commands.push([]);
    } else if (/\s/.test(char)) {
      endWord();
    } else {
      word = (word ?? "") + char;
    }
  }
  endWord();
  return commands.filter((words) => words.length > 0);
}

// The value of the first of `names` among `words`, as `--name value` or `--name=value`.
export function option(words, names) {
  for (const [index, word] of words.entries()) {
    const [name, ...value] = word.split("=");
    if (names.includes(name)) return value.length > 0 ? value.join("=") : words[index + 1];
  }
  return undefined;
}

// A program's command and subcommand and their arguments: the words after its leading
// options, of which those in `valued` take a value, and before its first option after them.
export function commandWords(words, valued = []) {
  let index = 0;
  while (words[index]?.startsWith("-")) index += valued.includes(words[index]) ? 2 : 1;
  const found = [];
  for (; index < words.length && !words[index].startsWith("-"); index += 1) found.push(words[index]);
  return found;
}

// A calendar change in a few words. `verb` is what the program calls the change to an
// event, or nothing for any other change to the calendar.
function calendarChange({ verb, service, calendar, words, startOptions, isNaiveUtc, timeZone }) {
  const summary = text(option(words, ["--summary"]));
  const start = text(option(words, startOptions));
  const isAllDay = words.includes("--all-day");
  const when = start && spokenTime(start, { timeZone, isAllDay, isNaiveUtc });
  const what = summary ?? "an event";
  let title = summary ? `Change ${summary}` : "Change the calendar";
  let change = "changed";
  if (ADDS.has(verb)) {
    title = when ? `Add ${what}, ${when}` : `Add ${what}`;
    change = "added";
  } else if (MOVES.has(verb)) {
    title = when ? `Move ${what} to ${when}` : `Change ${what}`;
    if (when) change = "moved";
  } else if (DELETES.has(verb)) {
    title = `Delete ${what}`;
    change = "deleted";
  }
  const named = text(calendar);
  return {
    title,
    description: named ? `On the ${named} calendar in ${service}.` : `On a calendar in ${service}.`,
    did: {
      kind: "event",
      change,
      ...(summary ? { title: summary } : {}),
      ...(start && change !== "deleted" ? momentOf(start, { timeZone, isAllDay, isNaiveUtc }) : {}),
    },
  };
}

// gog [options] calendar <command> <calendar id> ...
function gogChange(words, timeZone) {
  const [group, verb, calendar] = commandWords(words, ["--account", "--client"]);
  if ((group !== "calendar" && group !== "cal") || !verb || CALENDAR_READS.has(verb)) return null;
  return calendarChange({ verb, service: "Google", calendar, words, startOptions: ["--from"], isNaiveUtc: false, timeZone });
}

// applecal.py --apple-id <account> <group> <command> ..., or a command of its own such as
// doctor. It reads a time with no offset as UTC.
function applecalChange(words, timeZone) {
  const [first, second] = commandWords(words, ["--apple-id"]);
  const command = second ?? first;
  if (!command || CALENDAR_READS.has(command)) return null;
  const verb = second && (first === "events" || first === "event") ? second : undefined;
  const calendar = option(words, ["--calendar"]);
  return calendarChange({ verb, service: "iCloud", calendar, words, startOptions: ["--start"], isNaiveUtc: true, timeZone });
}

// openclaw [options] cron|automations <command> [job id] ...
function openclawChange(words) {
  const [group, command, target] = commandWords(words, OPENCLAW_VALUE_OPTIONS);
  const change = group === "cron" || group === "automations" ? REMINDER_COMMANDS[command] : undefined;
  if (!change) return null;
  const titles = { add: "Add a reminder", update: "Change a reminder", remove: "Delete a reminder" };
  const changes = { add: "added", update: "changed", remove: "deleted" };
  const name = text(option(words, ["--name"]));
  const named = name ?? (change === "add" ? undefined : text(target));
  return {
    title: titles[change],
    description: named ? `Reminder ${named}` : "A new reminder",
    did: { kind: "reminder", change: changes[change], ...(name ? { title: name } : {}) },
  };
}

// The program a command's word runs, as its path, lower case, with forward slashes.
export function programPath(word) {
  return word.replaceAll("\\", "/").toLowerCase();
}

function programOf(word) {
  const path = programPath(word);
  const name = path.split("/").at(-1);
  if (name === "gog") return gogChange;
  if (name === "applecal.py") return applecalChange;
  return name === "openclaw" || name === "openclaw.mjs" || path.endsWith("dist/index.js") ? openclawChange : null;
}

// The first calendar or reminder change a shell command makes, of all it runs.
function commandChange(params, timeZone) {
  if (typeof params?.command !== "string") return null;
  for (const words of simpleCommands(params.command)) {
    const index = words.findIndex((word) => programOf(word));
    const change = index === -1 ? null : programOf(words[index])(words.slice(index + 1), timeZone);
    if (change) return change;
  }
  return null;
}

const CHANGES_BY_TOOL = { automations: reminderChange, exec: commandChange };

// The tools whose calls this hook reads, as OpenClaw names them to a hook's matcher.
export const ASKING_TOOLS = Object.keys(CHANGES_BY_TOOL);

// The calendar or reminder change a step makes, or null for a read or any other step: the
// approval card's title and description, and `did`, the change as data.
export function changeOf(toolName, params, timeZone) {
  return Object.hasOwn(CHANGES_BY_TOOL, toolName) ? CHANGES_BY_TOOL[toolName](params, timeZone) : null;
}

// The `before_tool_call` hook's answer: an approval for a change in the owner's own thread,
// and nothing otherwise. `ownerSession` is the thread's session while the channel runs, and
// `timeZone` is for tests: the gateway shows times in its own zone.
export function askBeforeChange(event, context, { ownerSession, ownersFamilySession, timeZone } = {}) {
  const isThisChannel = String(context?.requester?.channel ?? "").trim().toLowerCase() === CHANNEL;
  const isOwnersSession = [ownerSession, ownersFamilySession].some((session) => Boolean(session) && context?.sessionKey === session);
  const change = isThisChannel && isOwnersSession ? changeOf(event?.toolName, event.params, timeZone) : null;
  if (!change) return undefined;
  return {
    requireApproval: {
      title: change.title.slice(0, MAX_TITLE),
      description: change.description.slice(0, MAX_DESCRIPTION),
      allowedDecisions: [...DECISIONS],
      timeoutMs: TIMEOUT_MS,
    },
  };
}
