// Gift and wishlist memory, from deploy/openclaw/plugins/household-app/wishes.js: a wish said
// in passing is kept with who and when, where it belongs, and handed to the right parent three
// weeks before that person's birthday or Christmas, and a gift for one parent never reaches
// that parent: not in the household note, not on the assistants' line, and not on that
// parent's own gateway once the other side has it.
//
// Run with `node --test tests/js/household_app_wishes.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";

import { createWishTool } from "../../deploy/openclaw/plugins/household-app/wish-tool.js";
import { createWishes } from "../../deploy/openclaw/plugins/household-app/wishes.js";
import { runningChannel, until } from "./fixtures/household-app-channel.mjs";

const FRANCO = { id: "franco", name: "Franco" };
const GIA = { id: "gia", name: "Gia" };
const COREY = { id: "corey", name: "Corey" };
const DENISE = { id: "denise", name: "Denise" };
// Thursday 22 October 2026, noon in Chicago: three weeks before 12 November.
const NOW = Date.UTC(2026, 9, 22, 17, 0);
const ROOT = mkdtempSync(path.join(os.tmpdir(), "household-wishes-"));
const opened = [];
after(() => {
  for (const each of opened) each.close();
  rmSync(ROOT, { recursive: true, force: true });
});

let counter = 0;
const newId = () => `00000000-0000-4000-8000-${String(++counter).padStart(12, "0")}`;

function gateways() {
  let clock = NOW - 20 * 86_400_000;
  const open = (assistant, peerAssistant, owner, peerPerson) => {
    const wishes = createWishes({
      file: path.join(mkdtempSync(path.join(ROOT, "gateway-")), "wishes.sqlite"),
      assistant,
      peerAssistant,
      owner,
      peerPerson,
      now: () => clock,
      newId,
      timeZone: "America/Chicago",
    });
    opened.push(wishes);
    return wishes;
  };
  return {
    corey: open(COREY, DENISE, FRANCO, GIA),
    denise: open(DENISE, COREY, GIA, FRANCO),
    relay: (from, to) => to.acceptPeer({ wishes: from.outbox().wishes }),
    at: (moment) => {
      clock = moment;
    },
  };
}

const said = (wishes) => JSON.stringify(wishes.outbox()) + JSON.stringify(wishes.view());

test("Gia's own wish goes to Franco's side alone, and leaves hers once his side has it", () => {
  // Arrange
  const { corey, denise, relay } = gateways();

  // Act: Gia tells Denise, in passing, what she would love.
  const kept = denise.wish({ who: "Gia", words: "a green fountain pen" });
  const beforeDelivery = said(denise);
  relay(denise, corey);
  relay(corey, denise);

  // Assert
  assert.deepEqual(kept, { kept: "for Franco's side only" });
  assert.deepEqual(denise.view(), [], "nothing about Gia is kept on her own side");
  assert.match(beforeDelivery, /fountain pen/, "until it is delivered, the step waits in her side's outbox");
  assert.doesNotMatch(said(denise), /fountain pen/, "once Corey's side has it, its words leave Gia's side");
  assert.deepEqual(corey.view().map((wish) => [wish.who, wish.wants]), [["Gia", "a green fountain pen"]]);
});

test("a wish of the other parent stays on this side, for this gateway's own person, and never crosses", () => {
  // Arrange
  const { corey, denise, relay } = gateways();

  // Act: Franco tells Corey what Gia would love.
  const kept = corey.wish({ who: "gia", words: "a pasta maker" });
  relay(corey, denise);

  // Assert
  assert.deepEqual(kept, { kept: "for Franco only" });
  assert.deepEqual(corey.outbox().wishes, []);
  assert.doesNotMatch(said(denise), /pasta maker/);
  assert.deepEqual(corey.view().map((wish) => wish.wants), ["a pasta maker"]);
});

test("anyone else's wish, a child's, is kept on both sides for both parents", () => {
  const { corey, denise, relay } = gateways();
  assert.deepEqual(corey.wish({ who: "Luca", words: "a red scooter" }), { kept: "for Franco and Gia" });
  relay(corey, denise);
  assert.deepEqual(corey.view().map((wish) => wish.wants), ["a red scooter"]);
  assert.deepEqual(denise.view().map((wish) => wish.wants), ["a red scooter"]);
});

test("three weeks before Gia's birthday, Franco's side gets every wish for her, once a year, and Gia's side gets none", () => {
  // Arrange: Gia's birthday kept by Denise crosses to Corey; two wishes for Gia end up on Corey.
  const { corey, denise, relay, at } = gateways();
  denise.birthday({ who: "Gia", date: "1990-11-12" });
  denise.wish({ who: "Gia", words: "a green fountain pen" });
  relay(denise, corey);
  relay(corey, denise);
  corey.wish({ who: "Gia", words: "a pasta maker" });

  // Act
  at(NOW - 86_400_000);
  const dayEarly = corey.due();
  at(NOW);
  const due = corey.due();
  const again = corey.due();

  // Assert
  assert.deepEqual(dayEarly, []);
  assert.equal(due.length, 1);
  assert.match(due[0], /^Gia's birthday is in 21 days, Thu, Nov 12\. Things Gia said they wanted:\n/);
  assert.match(due[0], /\n- a pasta maker \(said [A-Z][a-z]{2}, [A-Z][a-z]{2} \d+\)/);
  assert.match(due[0], /\n- a green fountain pen \(said /);
  assert.deepEqual(again, [], "once for that birthday");
  assert.deepEqual(denise.due(), [], "nothing for Gia ever reaches her own side");
});

test("Christmas hands a child's wishes to both parents three weeks out", () => {
  const { corey, denise, relay, at } = gateways();
  corey.wish({ who: "Luca", words: "a red scooter" });
  relay(corey, denise);
  at(Date.UTC(2026, 11, 4, 18, 0));
  assert.match(corey.due()[0], /^Christmas is in 21 days, Fri, Dec 25\. Things Luca said they wanted:\n- a red scooter/);
  assert.match(denise.due()[0], /^Christmas is in 21 days/);
});

for (const [why, step] of [
  ["a wish from someone who is not the other assistant", { kind: "wish", author: "franco" }],
  ["a wish with no words", { kind: "wish", words: "" }],
  ["a birthday that is no day", { kind: "birthday", who: "Gia", day: "13-40" }],
  ["a kind it does not know", { kind: "gift" }],
]) {
  test(`the other side's step with ${why} is refused`, () => {
    const { corey } = gateways();
    const base = { id: "ws-00000000-0000-4000-8000-000000000777", at: NOW - 30 * 86_400_000, author: "denise", kind: "wish", wish: "wk-1", who: "Gia", words: "a scarf", saidAt: NOW };
    assert.deepEqual(corey.acceptPeer({ wishes: [{ ...base, ...step }] }), { accepted: 0, refused: 1 });
    assert.deepEqual(corey.view(), []);
  });
}

test("the tool is offered only in the owner's own turns, keeps a wish quietly, and refuses what is not one", async () => {
  // Arrange
  const { corey } = gateways();
  const context = (sessionKey, sender, to) => ({
    agentId: "main",
    agentAccountId: "default",
    messageChannel: "household",
    deliveryContext: { channel: "household", accountId: "default", to },
    requesterSenderId: sender,
    sessionKey,
  });
  const offer = (each) => createWishTool({ context: each, owner: "franco", ownerName: "Franco", peerName: "Gia", people: ["franco", "gia"], wishes: corey });
  const tool = offer(context("agent:main:household:direct:franco", "franco", "household:franco"));
  const run = async (args) => JSON.parse((await tool.execute("call-1", args)).content[0].text);

  // Act and Assert
  assert.equal(offer(context("agent:main:household:group:family", "gia", "household:family")), null, "the room's shared session");
  assert.match(tool.description, /never say you kept it or for whom/);
  assert.deepEqual(await run({ action: "wish", who: "Gia", what: "a pasta maker" }), { kept: "for Franco only" });
  assert.equal((await run({ action: "wish", who: "Gia" })).code, "invalid_wish");
  assert.equal((await run({ action: "birthday", who: "Gia", date: "Nov 12" })).code, "invalid_wish");
  assert.equal((await run({ action: "view", who: "Gia" })).code, "invalid_arguments");
  assert.deepEqual((await run({ action: "view" })).wishes.map((wish) => wish.wants), ["a pasta maker"]);
});

// Through Denise's plugin: Gia's wish for herself, said in her own thread, never reaches a page
// her phone reads or a turn of hers, and leaves her side once Corey's says it has it.
test("through the plugin, Gia's wish for herself reaches only the outbox, and leaves it once the other side has it", async () => {
  // Arrange
  const channel = await runningChannel({
    channels: {
      household: {
        owner: { id: "gia", name: "Gia" },
        assistant: { id: "denise", name: "Denise" },
        peer: { person: { id: "franco", name: "Franco" }, assistant: { id: "corey", name: "Corey" } },
      },
    },
  });
  const GIAS_THREAD = {
    agentId: "main",
    agentAccountId: "default",
    messageChannel: "household",
    deliveryContext: { channel: "household", accountId: "default", to: "household:gia" },
    requesterSenderId: "gia",
    sessionKey: "agent:main:household:direct:gia",
  };
  const outbox = path.join(channel.stateDir, "household-app", "outbox.json");
  try {
    const tool = channel.tools.find(({ options }) => options.names.includes("household_wish")).factory(GIAS_THREAD);

    // Act
    await tool.execute("call-1", { action: "wish", who: "Gia", what: "a green fountain pen" });
    await until("the wish in the outbox", async () => (await readFile(outbox, "utf8").catch(() => "")).includes("fountain pen"), { attempts: 2000 });
    const [step] = JSON.parse(await readFile(outbox, "utf8")).wishes;
    const turn = await channel.promptBuild({ prompt: "What should I get myself?" }, GIAS_THREAD);
    const page = JSON.stringify((await channel.call("household-app.sync", { since: 0 })).payload);
    const line = JSON.stringify((await channel.call("household-app.line", {})).payload);
    await writeFile(
      path.join(channel.stateDir, "household-app", "inbox", "0001-from-corey.json"),
      JSON.stringify({ from: "corey", batch: { entries: [], wishes: [{ id: "ws-00000000-0000-4000-8000-000000000901", at: Date.now(), author: "corey", kind: "seen", step: step.id }] } }),
    );
    await until("the wish gone from the outbox", async () => {
      const text = await readFile(outbox, "utf8").catch(() => null);
      return text !== null && !text.includes("fountain pen");
    }, { attempts: 2000 });

    // Assert
    assert.equal(step.who, "Gia");
    assert.doesNotMatch(JSON.stringify(turn), /fountain pen/);
    assert.doesNotMatch(page, /fountain pen/);
    assert.doesNotMatch(line, /fountain pen/);
    assert.deepEqual(JSON.parse((await tool.execute("call-2", { action: "view" })).content[0].text), { wishes: [] });
  } finally {
    await channel.stop();
  }
});
