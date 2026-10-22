---
name: scripture
# Kept under the 220 characters the skill catalog renders before it truncates,
# and front-loaded: this line is the whole routing signal the model sees.
description: "Bible, scripture, sermons, daily devotionals and study plans: use SIQsermon, never memory, even for John 3:16 or a scheduled reading. In Steward, include a scripture card with Open in Bible."
metadata:
  {
    "openclaw":
      { "emoji": "📖", "requires": { "bins": ["python3"] } },
  }
---

# Scripture

SIQsermon holds all 31,105 verses with cross-references, original-language word studies, book dating and the household's own sermon archive.
It runs on this same box.

**Use it whenever a question touches the Bible, a verse, a passage, a doctrine, a sermon, or a study plan.**
Answer from it first, before answering from memory.

## Daily sermons and Steward delivery

Apply this workflow to both Corey and Denise, including scheduled daily sermons and devotionals, not only direct Bible questions.
Fetch the reading with this skill before writing the teaching; distinguish the returned Bible text from your interpretation.

When replying in Steward (`channel=household`), or when a scheduled job's explicit delivery destination is `household`, run:

```bash
python3 ~/.openclaw/workspace/skills/scripture/scripture.py ref "Luke 24:13-35" --card
```

Paste the returned `steward-card` block unchanged into the final message, after the greeting and before the teaching.
The block contains the passage and its Bible link; Steward renders **Open in Bible** from it.
Keep context, application and prayer in prose after the card. Do not repeat the whole passage as a Markdown quote, omit the block, or replace it with a `sermon` card.
The `sermon` card is only for an existing sermon read from the archive, not a newly written devotional.
For a reading longer than 40 verses, fetch consecutive ranges of at most 40 and include each returned card.

Use the same rule in an isolated scheduled run: inspect its actual delivery destination rather than assuming that no interactive chat means plain text.
Do not send cards to Telegram or other destinations. For those, use `ref` without `--card` and ordinary prose.
Do not change a job's destination or send an extra message yourself.
For the separate Today snapshot, follow the `household_today` tool's schema; this rule does not turn a no-delivery job into a chat message.

`--card` builds the link without another AI request. It opens the edition the household reads, set on the box, whatever translation the verses are in, and the card still names the translation of its text.
Where no edition is set, it links BSB, KJV and ASV text to their own edition and leaves other translations without a link rather than guessing one.
If a passage is incomplete or inconsistent, report the tool's error instead of inventing a card. Never claim the skill was used unless its command ran successfully.

## The rule that matters

**Never invent a reference.**
Quote book, chapter and verse exactly as the tool prints them.
If the tool does not return a verse, say so plainly and stop.
"I could not find that in the database" is a correct answer; a plausible-looking citation that came from memory is not, and neither is a real verse attached to the wrong reference.

Everything here is read-only.
Writing study notes and plans back into SIQsermon is a later phase, not something this skill can do, so do not promise it.

## Commands

```bash
S=~/.openclaw/workspace/skills/scripture/scripture.py

# A reference you already know. Also takes a short range.
python3 $S ref "John 3:16"
python3 $S ref "Psalms 23:1-6"

# A reading to include in a Steward reply or scheduled daily devotional.
python3 $S ref "Luke 24:13-35" --card

# A question, a theme, or half-remembered wording. Searches by meaning.
python3 $S search "what does the Bible say about forgiving someone repeatedly"
python3 $S search "for God so loved the world"

# The household's own preaching material.
python3 $S sermons            # list
python3 $S sermons 12         # read one
python3 $S plans              # study projects
python3 $S plans 15           # read one
```

## Which command

`ref` and `search` are not interchangeable.

- Asked for a **specific reference** ("what does John 3:16 say", "read me Psalm 23"), use `ref`.
  Searching for `"John 3:16"` returns verses about John the Baptist, because search matches meaning, not reference labels.
- Asked about a **topic, a question, or remembered wording**, use `search`.
  Looking up a reference cannot answer "what does the Bible say about anxiety".

If `ref` reports the reference does not exist, do not fall back to `search` and present whatever comes back as if it were the verse asked for.

## Reading the output

```
John 3:16 (BSB)
  For God so loved the world that He gave His one and only Son, ...
```

The translation is in brackets.
The database holds public-domain translations only, BSB first, so quote the text as printed rather than from memory of another translation.

`search` adds a relevance score, cross-references and a word study per verse.
A low score across every result means the database has nothing close; say so rather than stretching the best match to fit.

## When it cannot answer

The script exits non-zero and prints one line to stderr.
Relay that, do not work around it.

| message | what it means |
|---|---|
| `No SIQsermon account configured` | this gateway's env file has no `SIQSERMON_USERNAME` / `SIQSERMON_PASSWORD`; an administrator has to add them |
| `Cannot reach SIQsermon` or `Cannot reach the verse collection` | the gateway is not on the `deploy_default` docker network |
| `holds nothing at <ref>` | there is no such verse; the reference is wrong |
| `Cannot read SIQsermon's verse collection` | the `verses` collection is gone or renamed in Qdrant; the database is broken, so say that rather than anything about the reference |
| `is out of range` | the chapter or verse is above 999, which the verse ids cannot express; the reference is wrong |
| `not one of the 66 books` | the book name was not recognised |
| `returned 401` | the stored credential is no longer valid |

## How it reaches SIQsermon

`search`, `sermons` and `plans` go to `http://deploy-backend-1:8000`, signing in with the account in this gateway's env file.

`ref` is a single GET against the Qdrant collection `verses` on `http://deploy-qdrant-1:6333`, because SIQsermon's HTTP API has no lookup-by-reference read.
That couples this skill to two SIQsermon internals: the collection name `verses`, and the `BBCCCVVV` point-id scheme from `ingestion/books.verse_id` (book number × 1,000,000 + chapter × 1,000 + verse) together with its 1-66 book order, both mirrored in `scripture.py`.
When SIQsermon grows a verses-by-reference read, `ref` should switch to it and the mirrored table should go.
