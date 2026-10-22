// Amazon's order emails, from deploy/openclaw/plugins/household-app: what the plugin reads
// out of one, and when it believes it at all.
//
// Every email here is synthetic, written for these tests in the shape Amazon's order mail
// takes. None was copied from anyone's mailbox.
//
// Run with `node --test tests/js/household_app_amazon_mail.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { test } from "node:test";

import { readAmazonEmail } from "../../deploy/openclaw/plugins/household-app/amazon-mail.js";

const OWNER = "gia.example@gmail.com";
const GMAIL_AUTH = "mx.google.com; dkim=pass header.i=@amazon.com header.s=rjv7xxwhd header.b=AbCdEf12; spf=pass (google.com: domain of 20261015101022abc@bounces.amazon.com designates 54.240.1.1 as permitted sender) smtp.mailfrom=20261015101022abc@bounces.amazon.com; dmarc=pass (p=QUARANTINE) header.from=amazon.com";

const ORDER = "113-1234567-8904417";
const TOWELS = "B07XYZ1234";
const SOAP = "B08ABC5678";
const SUGGESTED = "B0SUGGEST1";

const redirect = (asin) =>
  `https://www.amazon.com/gp/r.html?C=ABC&K=DEF&M=urn:rtn:msg:2026&R=XYZ&T=C&U=https%3A%2F%2Fwww.amazon.com%2Fdp%2F${asin}%2Fref%3Dpe_123_456&H=ABCDEF&ref_=pe_123`;

const quotedPrintable = (text) =>
  Buffer.from(text, "utf8").toString("latin1").replace(/[^\x20-\x7e\n]|=/g, (c) =>
    `=${c.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0")}`);

function email({
  subject,
  from = '"Amazon.com" <shipment-tracking@amazon.com>',
  to = OWNER,
  date = "Wed, 15 Oct 2026 06:10:22 -0400",
  auth = [GMAIL_AUTH],
  extra = [],
  text = "",
  html = "",
}) {
  const boundary = "----=_Part_123_456.789";
  const headers = [
    ...extra,
    ...auth.map((value) => `Authentication-Results: ${value}`),
    "Received: from a1-2.smtp-out.amazonses.com (a1-2.smtp-out.amazonses.com. [54.240.1.2])",
    `Date: ${date}`,
    `From: ${from}`,
    `To: ${to}`,
    `Subject: ${subject}`,
    "MIME-Version: 1.0",
    `Content-Type: multipart/alternative; \r\n\tboundary="${boundary}"`,
  ];
  const parts = [
    `--${boundary}`,
    'Content-Type: text/plain; charset="UTF-8"',
    "Content-Transfer-Encoding: quoted-printable",
    "",
    quotedPrintable(text),
    `--${boundary}`,
    "Content-Type: text/html; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    Buffer.from(html, "utf8").toString("base64").replace(/.{76}/g, "$&\r\n"),
    `--${boundary}--`,
    "",
  ];
  return [...headers, "", ...parts].join("\r\n");
}

const read = (raw, to = OWNER) => readAmazonEmail(raw, { to });
const plain = (subject, text, overrides = {}) => email({ subject, text, ...overrides });

const ORDERED = email({
  subject: "Ordered: =?UTF-8?Q?=E2=80=9CBounty_Paper_Towels=E2=80=A6=E2=80=9D?= and 1 more item",
  text: `Thanks for your order.\nArriving Thursday, October 16\nOrder # ${ORDER}\nView or edit order`,
  html: `<html><body><p>Arriving <b>Thursday, October 16</b></p><p>Order # ${ORDER}</p>` +
    `<a href="${redirect(TOWELS)}"><img src="https://m.media-amazon.com/images/I/x.jpg"></a>` +
    `<a href="${redirect(SOAP)}">Dish soap</a><a href="${redirect(TOWELS)}">again</a>` +
    `<h2>Recommended for you</h2><a href="${redirect(SUGGESTED)}">Something else</a></body></html>`,
});

// MARK: - What it reads

test("an Ordered email gives its order, status, time, expected day and the products ordered", () => {
  assert.deepEqual(read(ORDERED), {
    order: ORDER,
    status: "ordered",
    at: "2026-10-15T06:10:22-04:00",
    arriving: "2026-10-16",
    asins: [TOWELS, SOAP],
  });
});

for (const [subject, status] of [
  ["Shipped: “Bounty Paper Towels…”", "shipped"],
  ["Out for delivery: “Bounty Paper Towels…”", "out_for_delivery"],
  ["Delivered: “Bounty Paper Towels…” and 1 more item", "delivered"],
  ["Delivered: 3 Drugstore Items", "delivered"],
  ["Your Amazon.com order #113-1234567-8904417 has shipped", "shipped"],
  ["Your Amazon.com order of “Bounty Paper Towels…”.", "ordered"],
]) {
  test(`"${subject}" reads as ${status}`, () => {
    const found = read(plain(subject, `Order # ${ORDER}`));
    assert.equal(found?.status, status);
    assert.equal(found?.order, ORDER);
  });
}

test("a subject sent as raw UTF-8 reads as one sent in encoded words", () => {
  assert.equal(read(plain("Delivered: “Bounty…”", `Order # ${ORDER}`))?.status, "delivered");
});

test("the owner's Gmail address counts however Gmail spells it", () => {
  for (const to of ["Gia <gia.example@gmail.com>", "giaexample@gmail.com", "gia.example+amazon@googlemail.com", "GIA.EXAMPLE@GMAIL.COM"]) {
    assert.equal(read(plain("Shipped: x", `Order # ${ORDER}`, { to }))?.status, "shipped", to);
  }
});

test("arriving tomorrow and today are days counted from the email's own date", () => {
  const date = "Fri, 31 Oct 2026 22:15:00 -0400";
  assert.equal(read(plain("Shipped: x", `Arriving tomorrow\nOrder # ${ORDER}`, { date }))?.arriving, "2026-11-01");
  assert.equal(read(plain("Shipped: x", `Arriving today\nOrder # ${ORDER}`, { date }))?.arriving, "2026-10-31");
});

test("a short day and month read as the long ones", () => {
  assert.equal(read(plain("Shipped: x", `Arriving Thu, Oct 16\nOrder # ${ORDER}`))?.arriving, "2026-10-16");
  assert.equal(read(plain("Shipped: x", `Arriving Oct. 16\nOrder # ${ORDER}`))?.arriving, "2026-10-16");
});

test("an expected day early in January, in a December email, is next year's", () => {
  const found = read(plain("Shipped: x", `Arriving Monday, January 4\nOrder # ${ORDER}`, { date: "Tue, 29 Dec 2026 09:00:00 -0500" }));
  assert.equal(found?.arriving, "2027-01-04");
});

test("an email with no expected day has none, and a day among the suggestions is not it", () => {
  assert.equal("arriving" in read(plain("Delivered: x", `Your package was delivered.\nOrder # ${ORDER}`)), false);
  assert.equal("arriving" in read(plain("Delivered: x", `Order # ${ORDER}\nRecommended for you\nArriving tomorrow with Prime`)), false);
});

test("a time in UTC keeps its offset, written as numbers or as GMT", () => {
  assert.equal(read(plain("Shipped: x", `Order # ${ORDER}`, { date: "Wed, 15 Oct 2026 10:10:22 +0000" }))?.at, "2026-10-15T10:10:22+00:00");
  assert.equal(read(plain("Shipped: x", `Order # ${ORDER}`, { date: "Wed, 15 Oct 2026 10:10:22 GMT" }))?.at, "2026-10-15T10:10:22+00:00");
});

test("product ids come from plain, angle-bracketed and redirect links, each once, and none from the suggestions", () => {
  const found = read(email({
    subject: "Shipped: x",
    text: `Order # ${ORDER}\n<https://www.amazon.com/gp/product/${SOAP}>\nCustomers who bought this also bought https://www.amazon.com/dp/${SUGGESTED}`,
    html: `<a href="https://www.amazon.com/dp/${TOWELS}?th=1">a</a><a href="${redirect(SOAP)}">b</a>` +
      `<a href="https://www.amazon.com/gp/r.html?U=https%253A%252F%252Fwww.amazon.com%252Fdp%252FB0DOUBLE01%252F">c</a>` +
      `<p>Inspired by your shopping</p><a href="https://www.amazon.com/dp/${SUGGESTED}">d</a>`,
  }));
  assert.deepEqual(found?.asins, [SOAP, TOWELS, "B0DOUBLE01"]);
});

test("a part that starts with its blank line, and a boundary that begins another, are read right", () => {
  const raw = [
    `Authentication-Results: ${GMAIL_AUTH}`,
    "Date: Wed, 15 Oct 2026 06:10:22 -0400",
    'From: "Amazon.com" <shipment-tracking@amazon.com>',
    `To: ${OWNER}`,
    "Subject: Shipped: x",
    'Content-Type: multipart/mixed; boundary="abc"',
    "",
    "--abc",
    'Content-Type: multipart/alternative; boundary="abc_1"',
    "",
    "--abc_1",
    "",
    `Order # ${ORDER} https://www.amazon.com/dp/${TOWELS}`,
    "--abc_1--",
    "--abc--",
    "",
  ].join("\r\n");
  const found = read(raw);
  assert.equal(found?.order, ORDER);
  assert.deepEqual(found?.asins, [TOWELS]);
});

test("a huge body of markup is read in good time", () => {
  const started = Date.now();
  assert.equal(read(plain("Shipped: x", `Order # ${ORDER}`, { html: "<".repeat(3_000_000) }))?.order, ORDER);
  assert.ok(Date.now() - started < 3000);
});

// MARK: - When it is not believed

for (const [why, overrides] of [
  ["DKIM failed", { auth: [GMAIL_AUTH.replace("dkim=pass", "dkim=fail")] }],
  ["the signature is another domain's", { auth: [GMAIL_AUTH.replace("header.i=@amazon.com", "header.i=@amazon.com.evil.example")] }],
  ["there is no authentication header", { auth: [] }],
  ["only a header below Gmail's says pass", { auth: [GMAIL_AUTH.replace("dkim=pass", "dkim=none"), GMAIL_AUTH] }],
  ["the result is another server's", { auth: [GMAIL_AUTH.replace("mx.google.com", "mx.evil.example")] }],
  ["a second Subject sits above the signed one", { extra: ["Subject: Delivered: everything"] }],
  ["a second From sits above the signed one", { extra: ['From: "Amazon.com" <auto-confirm@amazon.com>'] }],
  ["a second Date sits above the signed one", { extra: ["Date: Thu, 16 Oct 2026 06:10:22 -0400"] }],
  ["it was sent to someone else", { to: "someone.else@example.com" }],
  ["it is from another domain", { from: '"Amazon.com" <shipment-tracking@amazon.com.evil.example>' }],
  ["its name says amazon.com and its address does not", { from: '"orders@amazon.com" <orders@evil.example>' }],
  ["it is from a look-alike address", { from: "Amazon <orders@amazon-orders.example>" }],
  ["the subject is a promotion", { subject: "Deals picked for you" }],
  ["there is no order number", { text: "Arriving Thursday" }],
  ["the date is missing", { date: "" }],
]) {
  test(`an email is not read when ${why}`, () => {
    assert.equal(read(email({ subject: "Shipped: x", text: `Order # ${ORDER}`, ...overrides })), null);
  });
}

test("something that is not an email at all, or a reader with no owner, reads nothing", () => {
  for (const raw of ["", "not an email", Buffer.from([0xff, 0xfe, 0x00]), undefined]) assert.equal(read(raw), null);
  assert.equal(readAmazonEmail(ORDERED, {}), null);
});
