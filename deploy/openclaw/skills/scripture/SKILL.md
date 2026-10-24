---
name: scripture
# Kept under the 220 characters the skill catalog renders before it truncates,
# and front-loaded: this line is the whole routing signal the model sees.
description: "Bible, scripture, sermons, daily devotionals and study plans: use the scripture tool, never memory, even for John 3:16 or a scheduled reading. In Steward, include a scripture card with Open in Bible."
metadata:
  {
    "openclaw":
      { "emoji": "📖" },
  }
---

# Scripture

The `scripture` tool holds all 31,000-odd verses of the Berean Standard Bible, with OpenBible's cross references, the Hebrew and Greek words of every verse with their Strong's numbers, and the household's own sermons and study plans.
It runs in this gateway: nothing to sign in to, and nothing else has to be up.

**Use it whenever a question touches the Bible, a verse, a passage, a doctrine, a sermon, or a study plan.**
Answer from it first, before answering from memory.

## Daily sermons and Steward delivery

Apply this workflow to both assistants, including scheduled daily sermons and devotionals, not only direct Bible questions.
Fetch the reading with the tool before writing the teaching; distinguish the returned Bible text from your interpretation.

When replying in Steward (`channel=household`), or when a scheduled job's explicit delivery destination is `household`, call:

```
scripture { "action": "ref", "reference": "Luke 24:13-35", "card": true }
```

Paste the returned `steward-card` block unchanged into the final message, after the greeting and before the teaching.
The block contains the passage and its Bible link; Steward renders **Open in Bible** from it.
Keep context, application and prayer in prose after the card. Do not repeat the whole passage as a Markdown quote, omit the block, or replace it with a `sermon` card.
The `sermon` card is only for an existing sermon read from the archive, not a newly written devotional.
For a reading longer than 40 verses, fetch consecutive ranges of at most 40 and include each returned card.

Use the same rule in an isolated scheduled run: inspect its actual delivery destination rather than assuming that no interactive chat means plain text.
Do not send cards to other destinations. For those, call `ref` without `card` and write ordinary prose.
Do not change a job's destination or send an extra message yourself.
For the separate Today snapshot, follow the `household_today` tool's schema; this rule does not turn a no-delivery job into a chat message.

The card's link opens the edition the household reads, whatever translation the verses are in, and the card still names the translation of its text.
If a passage is incomplete or inconsistent, report the tool's error instead of inventing a card. Never claim the tool was used unless it answered.

## The rule that matters

**Never invent a reference.**
Quote book, chapter and verse exactly as the tool prints them.
If the tool does not return a verse, say so plainly and stop.
"This Bible holds nothing at that reference" is a correct answer; a plausible-looking citation that came from memory is not, and neither is a real verse attached to the wrong reference.

## Actions

| action | for | example |
|---|---|---|
| `ref` | a reference you already know, or a short range | `{"action": "ref", "reference": "Psalms 23:1-6"}` |
| `ref` with `card` | a reading in a Steward reply or a scheduled devotional | `{"action": "ref", "reference": "Luke 24:13-35", "card": true}` |
| `search` | a question, a theme, or half-remembered wording, by meaning | `{"action": "search", "query": "forgiving someone again and again"}` |
| `study` | one verse's cross references and its Hebrew or Greek words | `{"action": "study", "reference": "John 3:16"}` |
| `sermons` | the household's kept sermons, or one by `id` | `{"action": "sermons", "id": 12}` |
| `plans` | the household's study plans, or one by `id` | `{"action": "plans"}` |
| `save` | keep a sermon or plan someone asked to keep | `{"action": "save", "kind": "sermon", "title": "...", "text": "..."}` |

`ref` and `search` are not interchangeable.

- Asked for a **specific reference** ("what does John 3:16 say", "read me Psalm 23"), use `ref`.
  Searching for `"John 3:16"` returns verses about something else, because search matches meaning, not reference labels.
- Asked about a **topic, a question, or remembered wording**, use `search`.
  Looking up a reference cannot answer "what does the Bible say about anxiety".

If `ref` reports the reference does not exist, do not fall back to `search` and present whatever comes back as if it were the verse asked for.

## Reading the answers

```
John 3:16 (BSB) score 0.813
  For God so loved the world that He gave His one and only Son, ...
  cross-refs: Romans 5:8; 1 John 4:9; ...
  word study: agapaō (G0025) "to love"; kosmos (G2889) "world"; ...
```

The translation is in brackets: quote the text as printed rather than from memory of another translation.
A low score across every result means nothing is close; say so rather than stretching the best match to fit.
When the tool says it searched by words, not meaning, the results are keyword matches: check each one fits before using it.

## When it cannot answer

The tool says why in one line. Relay that; do not work around it.

| message | what it means |
|---|---|
| `The Bible is not installed on this gateway` | an administrator has to run `scripts/scripture-build.py` |
| `holds nothing at` | there is no such verse; the reference is wrong |
| `is out of range` or `not one of the 66 books` | the reference is wrong |
| `more than 40 verses` | fetch the reading as consecutive ranges |

Sources: the Berean Standard Bible (public domain); cross references from OpenBible.info (CC BY); Hebrew and Greek words from STEPBible.org, Tyndale House, Cambridge (CC BY 4.0).
