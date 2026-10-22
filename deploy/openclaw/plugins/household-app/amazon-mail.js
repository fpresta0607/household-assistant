// What an Amazon order email to the owner says, read by the plugin itself so that no email
// text ever reaches an assistant: the order number, how far the order has come, when the
// email was sent, the day it is expected, and the Amazon product ids of what was ordered.
//
// An email is believed only when all of these hold:
// - Gmail's own authentication result, the topmost Authentication-Results header and
//   stamped by mx.google.com, says DKIM passed for amazon.com. A header lower down, or one
//   another server wrote, could have been written by anyone.
// - It has one From, To, Subject and Date each. DKIM signs the bottom-most copy of a
//   header, so a second copy added on top could say anything.
// - Its From is an amazon.com address, and its To, which Amazon signed, is the owner's own
//   address, so someone else's genuine Amazon email sent on to the owner does not count.
// Every other email, and anything this cannot read, is null.
//
// Amazon changes its mail, so this reads only what has held for years: the subject's first
// words, an order number in the 3-7-7 form, "Arriving" before a day, and /dp/ links, also
// inside Amazon's redirect links. Only the part before Amazon's recommendations is read for
// products and the day, since those links are not what was ordered.

const AUTH_SERVER = "mx.google.com";
const STATUS_BY_SUBJECT = [
  [/^Ordered:/i, "ordered"],
  [/^Shipped:/i, "shipped"],
  [/^Out for delivery:/i, "out_for_delivery"],
  [/^Delivered:/i, "delivered"],
  [/^Your Amazon\.com order .*has (?:been )?shipped/i, "shipped"],
  [/^Your Amazon\.com order of /i, "ordered"],
];
const SINGLE_HEADERS = ["from", "to", "subject", "date"];
const ORDER_NUMBER = /\b(\d{3}-\d{7}-\d{7})\b/;
const SLASH = "(?:/|%2F|%2f)";
const PRODUCT_LINK = new RegExp(
  `${SLASH}(?:dp|gp${SLASH}product|gp${SLASH}aw${SLASH}d)${SLASH}([A-Z0-9]{10})(?=${SLASH}|[?&"'<>)#.\\s]|%3F|%3f|$)`,
  "g",
);
// Where Amazon's own suggestions begin, after the items of the order.
const RECOMMENDATIONS = /recommended for you|recommendations for you|customers who (?:bought|viewed)|related to items you|inspired by your|frequently bought|you might (?:also )?like|top picks for you|based on your/i;
const MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];
const MONTH_WORD = `(${MONTHS.join("|")}|jan|feb|mar|apr|jun|jul|aug|sept?|oct|nov|dec)\\.?`;
const ARRIVING = new RegExp(
  `Arriving:?\\s+(?:(today|tomorrow)|(?:(?:mon|tues|wednes|thurs|fri|satur|sun)day|mon|tue|wed|thu|fri|sat|sun),?\\s+${MONTH_WORD}\\s+(\\d{1,2})\\b|${MONTH_WORD}\\s+(\\d{1,2})\\b)`,
  "i",
);
const MAIL_DATE = /^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s+(?:([+-])(\d{2})(\d{2})|(GMT|UTC?|Z))\b/;
const SHORT_MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const DAY_MS = 86_400_000;
// One part's text, which is far more than any order email holds.
const MAX_PART_CHARACTERS = 2_000_000;

const pad = (value) => String(value).padStart(2, "0");

function decodeBytes(bytes, charset = "utf-8") {
  try {
    return new TextDecoder(charset.toLowerCase(), { fatal: false }).decode(bytes);
  } catch {
    return new TextDecoder("utf-8").decode(bytes);
  }
}

// RFC 2047 words in a header, such as =?UTF-8?Q?=E2=80=9CBounty?=.
function decodeHeader(value) {
  return value
    .replace(/(=\?[^?]+\?[QqBb]\?[^?]*\?=)\s+(?==\?)/g, "$1")
    .replace(/=\?([^?]+)\?([QqBb])\?([^?]*)\?=/g, (_, charset, encoding, text) => {
      const bytes = encoding.toUpperCase() === "B"
        ? Buffer.from(text, "base64")
        : Buffer.from(text.replace(/_/g, " ").replace(/=([0-9A-Fa-f]{2})/g, (_m, hex) => String.fromCharCode(parseInt(hex, 16))), "latin1");
      return decodeBytes(bytes, charset);
    });
}

// Header lines in order, unfolded, as [lower-case name, value] pairs, and the body after.
// A part that starts with its blank line has no headers.
function split(raw) {
  const blank = /^\r?\n/.exec(raw);
  const found = blank ? null : /\r?\n\r?\n/.exec(raw);
  const head = blank ? "" : found ? raw.slice(0, found.index) : raw;
  const body = blank ? raw.slice(blank[0].length) : found ? raw.slice(found.index + found[0].length) : "";
  const headers = [];
  for (const line of head.split(/\r?\n/)) {
    if (/^[ \t]/.test(line) && headers.length) headers.at(-1)[1] += ` ${line.trim()}`;
    else {
      const colon = line.indexOf(":");
      if (colon > 0) headers.push([line.slice(0, colon).trim().toLowerCase(), line.slice(colon + 1).trim()]);
    }
  }
  return { headers, body };
}

const headersOf = (headers, name) => headers.filter(([key]) => key === name).map(([, value]) => value);
const headerOf = (headers, name) => headersOf(headers, name)[0];

function parameter(value, name) {
  const found = new RegExp(`(?:^|;)\\s*${name}\\s*=\\s*(?:"([^"]*)"|([^;\\s]+))`, "i").exec(value ?? "");
  return found ? found[1] ?? found[2] : undefined;
}

const escaped = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// The parts between a multipart's boundary lines, each a line of its own.
function partsOf(body, boundary) {
  const line = new RegExp(`(?:^|\\r?\\n)--${escaped(boundary)}(--)?[ \\t]*(?=\\r?\\n|$)`, "g");
  const parts = [];
  let start = null;
  for (const found of body.matchAll(line)) {
    if (start !== null) parts.push(body.slice(start, found.index));
    if (found[1]) return parts;
    start = found.index + found[0].length;
  }
  return parts;
}

// The decoded text of every text/plain and text/html part, in order, walking multiparts.
function texts(raw, depth = 0) {
  const { headers, body } = split(raw);
  const type = (headerOf(headers, "content-type") ?? "text/plain").toLowerCase();
  if (type.startsWith("multipart/")) {
    const boundary = parameter(headerOf(headers, "content-type"), "boundary");
    if (!boundary || depth > 8) return [];
    return partsOf(body, boundary).flatMap((part) => texts(part.replace(/^\r?\n/, ""), depth + 1));
  }
  const kind = type.startsWith("text/html") ? "html" : type.startsWith("text/plain") ? "text" : null;
  if (!kind) return [];
  const encoding = (headerOf(headers, "content-transfer-encoding") ?? "").toLowerCase();
  const bytes = encoding === "base64"
    ? Buffer.from(body.replace(/\s+/g, ""), "base64")
    : encoding === "quoted-printable"
      ? Buffer.from(body.replace(/=\r?\n/g, "").replace(/=([0-9A-Fa-f]{2})/g, (_m, hex) => String.fromCharCode(parseInt(hex, 16))), "latin1")
      : Buffer.from(body, "latin1");
  const text = decodeBytes(bytes, parameter(type, "charset") ?? "utf-8").slice(0, MAX_PART_CHARACTERS);
  return [{ kind, text }];
}

// Markup's words, in one pass, so no input can make it slow.
function wordsOf(html) {
  let out = "";
  let isInTag = false;
  for (const character of html) {
    if (character === "<") isInTag = true;
    else if (character === ">" && isInTag) {
      isInTag = false;
      out += " ";
    } else if (!isInTag) out += character;
  }
  return out.replace(/&nbsp;/g, " ").replace(/&amp;/g, "&");
}

function isSignedByAmazon(headers) {
  const result = headerOf(headers, "authentication-results");
  if (!result) return false;
  const [server, ...methods] = result.split(";");
  return server.trim().toLowerCase() === AUTH_SERVER && methods.some((method) => /^\s*dkim=pass\b/i.test(method) &&
    /(?:^|\s)header\.(?:i=@|d=)amazon\.com(?:\s|$)/i.test(method));
}

const addressesIn = (value) => [...value.matchAll(/<([^<>\s]+)>/g)].map((found) => found[1])
  .concat(value.includes("<") ? [] : value.split(",").map((part) => part.trim()))
  .map((address) => address.toLowerCase())
  .filter((address) => /^[^@\s]+@[^@\s]+$/.test(address));

// Gmail's own reading of an address: dots and anything after a plus in its name do not count.
function mailbox(address) {
  const [name, domain] = address.toLowerCase().split("@");
  return domain === "gmail.com" || domain === "googlemail.com"
    ? `${name.split("+")[0].replaceAll(".", "")}@gmail.com`
    : `${name}@${domain}`;
}

// The email's Date as an ISO time with its own offset, and its local calendar day.
function sentAt(headers) {
  const found = MAIL_DATE.exec(headerOf(headers, "date") ?? "");
  const month = found ? SHORT_MONTHS.indexOf(found[2].toLowerCase()) : -1;
  if (!found || month === -1) return null;
  const [, day, , year, hours, minutes, seconds = "00", sign = "+", offsetHours = "00", offsetMinutes = "00"] = found;
  const at = `${year}-${pad(month + 1)}-${pad(day)}T${hours}:${minutes}:${seconds}${sign}${offsetHours}:${offsetMinutes}`;
  if (!Number.isFinite(Date.parse(at))) return null;
  return { at, local: Date.UTC(Number(year), month, Number(day)) };
}

const asDay = (utc) => new Date(utc).toISOString().slice(0, 10);

function monthIndex(word) {
  const short = word.toLowerCase().replace(/\.$/, "").slice(0, 3);
  return SHORT_MONTHS.indexOf(short);
}

function expectedDay(words, sent) {
  const found = ARRIVING.exec(words);
  if (!found) return undefined;
  if (found[1]) return asDay(sent.local + (found[1].toLowerCase() === "tomorrow" ? DAY_MS : 0));
  const month = monthIndex(found[2] ?? found[4]);
  const date = Number(found[3] ?? found[5]);
  const year = new Date(sent.local).getUTCFullYear();
  let day = Date.UTC(year, month, date);
  if (month === -1 || new Date(day).getUTCDate() !== date) return undefined;
  if (day < sent.local - 60 * DAY_MS) day = Date.UTC(year + 1, month, date);
  return asDay(day);
}

const beforeRecommendations = (text) => {
  const found = RECOMMENDATIONS.exec(text);
  return found ? text.slice(0, found.index) : text;
};

// `to` is the owner's own address, the only one whose Amazon mail counts.
export function readAmazonEmail(raw, { to }) {
  if ((typeof raw !== "string" && !Buffer.isBuffer(raw)) || typeof to !== "string") return null;
  const message = Buffer.isBuffer(raw) ? raw.toString("latin1") : Buffer.from(raw, "utf8").toString("latin1");
  const { headers } = split(message);
  if (!isSignedByAmazon(headers)) return null;
  if (SINGLE_HEADERS.some((name) => headersOf(headers, name).length !== 1)) return null;
  const from = addressesIn(headerOf(headers, "from"));
  if (from.length !== 1 || !/^[^@\s]+@amazon\.com$/.test(from[0])) return null;
  if (!addressesIn(headerOf(headers, "to")).some((address) => mailbox(address) === mailbox(to))) return null;
  const subject = decodeHeader(decodeBytes(Buffer.from(headerOf(headers, "subject"), "latin1"))).trim();
  const status = STATUS_BY_SUBJECT.find(([pattern]) => pattern.test(subject))?.[1];
  const sent = sentAt(headers);
  if (!status || !sent) return null;
  const parts = texts(message).map((part) => ({ ...part, text: part.text.replaceAll("%252F", "%2F").replaceAll("%252f", "%2F") }));
  const plain = parts.map((part) => (part.kind === "html" ? wordsOf(part.text) : part.text)).join("\n").replace(/[ \t]+/g, " ");
  const order = ORDER_NUMBER.exec(`${subject}\n${plain}`)?.[1];
  if (!order) return null;
  const asins = [];
  for (const part of [...parts.filter((part) => part.kind === "text"), ...parts.filter((part) => part.kind === "html")]) {
    for (const found of beforeRecommendations(part.text).matchAll(PRODUCT_LINK)) if (!asins.includes(found[1])) asins.push(found[1]);
  }
  const arriving = expectedDay(beforeRecommendations(plain), sent);
  return { order, status, at: sent.at, ...(arriving ? { arriving } : {}), asins };
}
