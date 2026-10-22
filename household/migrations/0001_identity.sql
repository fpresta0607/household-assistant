CREATE TABLE person (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL
);

CREATE TABLE persona (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL
);

CREATE TABLE channel_identity (
    channel TEXT NOT NULL,
    channel_user_id TEXT NOT NULL,
    person_id TEXT NOT NULL REFERENCES person(id),
    enrolled_at TEXT NOT NULL,
    PRIMARY KEY (channel, channel_user_id)
);

CREATE TABLE route (
    id TEXT PRIMARY KEY,
    channel TEXT NOT NULL,
    channel_chat_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('direct', 'group')),
    persona_id TEXT REFERENCES persona(id),
    approved INTEGER NOT NULL DEFAULT 0 CHECK (approved IN (0, 1)),
    UNIQUE (channel, channel_chat_id)
);

CREATE TABLE route_member (
    route_id TEXT NOT NULL REFERENCES route(id),
    person_id TEXT NOT NULL REFERENCES person(id),
    PRIMARY KEY (route_id, person_id)
);

CREATE TABLE account (
    id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL REFERENCES person(id),
    provider TEXT NOT NULL CHECK (provider IN ('google', 'microsoft', 'apple')),
    address TEXT NOT NULL,
    mail_monitored INTEGER NOT NULL DEFAULT 0 CHECK (mail_monitored IN (0, 1)),
    mail_digest INTEGER NOT NULL DEFAULT 0 CHECK (mail_digest IN (0, 1)),
    mail_writable INTEGER NOT NULL DEFAULT 0 CHECK (mail_writable IN (0, 1)),
    mail_last_sync_at TEXT,
    UNIQUE (provider, address)
);

CREATE TABLE calendar (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES account(id),
    name TEXT NOT NULL,
    counts_toward_availability INTEGER NOT NULL DEFAULT 1
        CHECK (counts_toward_availability IN (0, 1)),
    writable INTEGER NOT NULL DEFAULT 0 CHECK (writable IN (0, 1)),
    last_sync_at TEXT
);

CREATE INDEX account_person ON account (person_id);

CREATE INDEX calendar_account ON calendar (account_id);
