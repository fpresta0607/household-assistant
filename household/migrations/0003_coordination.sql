-- The relay's three tables, and the two the planner will write.
--
-- taste_signal and research_budget arrive here with nothing in this change reading
-- or writing them: the planner that does follows as its own change. They ship whole
-- rather than in a later migration because splitting one schema across two of them
-- is a hazard, and two empty tables are not. A comment below that describes what the
-- planner does with a column is describing household/planner.py, which has landed
-- since.

CREATE TABLE coordination_flag (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    changed_at TEXT NOT NULL,
    changed_by_person_id TEXT NOT NULL REFERENCES person(id)
);

CREATE TABLE coordination_turn (
    id TEXT PRIMARY KEY,
    -- Not nullable, and there is no kind column beside it. A person addressing an
    -- assistant in the group is the only thing that opens a turn: the planner posts a
    -- proposal and opens nothing, because its research reads the open web.
    opened_by_person_id TEXT NOT NULL REFERENCES person(id),
    source_seq INTEGER NOT NULL,
    opened_at TEXT NOT NULL,
    closed_at TEXT,
    closed_reason TEXT CHECK (closed_reason IN ('stop', 'superseded', 'cap', 'stale'))
);

CREATE INDEX coordination_turn_open ON coordination_turn (closed_at);

CREATE TABLE coordination_message (
    id TEXT PRIMARY KEY,
    turn_id TEXT NOT NULL REFERENCES coordination_turn(id),
    speaker_persona_id TEXT NOT NULL REFERENCES persona(id),
    peer_persona_id TEXT NOT NULL REFERENCES persona(id),
    text TEXT NOT NULL,
    posted_at TEXT NOT NULL,
    group_message_ref TEXT NOT NULL,
    delivered_at TEXT
);

CREATE INDEX coordination_message_turn ON coordination_message (turn_id, speaker_persona_id);

-- How far the relay has consumed each gateway's own record of the group. One row
-- per persona because each gateway keeps its own transcript and Telegram never
-- shows one bot what the other posted.
CREATE TABLE coordination_cursor (
    persona_id TEXT PRIMARY KEY REFERENCES persona(id),
    last_seq INTEGER NOT NULL
);

-- One human message reaches both gateways and is recorded twice, under a different
-- idempotency key each time. This is the relay's own identity for it, so a stop is
-- acted on once and a turn is opened once.
CREATE TABLE coordination_seen (
    key TEXT PRIMARY KEY
);

CREATE TABLE taste_signal (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('enjoyed', 'attended', 'declined')),
    subject TEXT NOT NULL,
    detail TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL CHECK (source IN ('group', 'shared_calendar')),
    person_id TEXT REFERENCES person(id),
    observed_at TEXT NOT NULL,
    -- What the signal was read off: a calendar event uid, a group message key, or
    -- the signal's own id. The relay and the planner both run again and again over
    -- the same calendar, so one event must not become one signal per run. Two
    -- separate Sundays at church are two events and therefore two signals.
    ref TEXT NOT NULL,
    UNIQUE (kind, subject, source, ref)
);

CREATE INDEX taste_signal_subject ON taste_signal (subject);

-- One row per research turn taken, so counting the rows for a day is the budget and
-- the row itself is the cache. Keyed by the window too: candidates found for one
-- evening are not an answer for a different one, and a planner that has spent the
-- day's turn waits rather than proposing last night's places for next Friday.
CREATE TABLE research_budget (
    day TEXT NOT NULL,
    window_start TEXT NOT NULL,
    result_json TEXT,
    PRIMARY KEY (day, window_start)
);
