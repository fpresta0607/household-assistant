CREATE TABLE memory (
    id TEXT PRIMARY KEY,
    scope TEXT NOT NULL
        CHECK (scope IN ('franco_private', 'gia_private', 'household_shared')),
    subject TEXT NOT NULL,
    body TEXT NOT NULL,
    author_person_id TEXT NOT NULL REFERENCES person(id),
    created_at TEXT NOT NULL
);

CREATE INDEX memory_scope ON memory (scope);

CREATE TABLE task (
    id TEXT PRIMARY KEY,
    scope TEXT NOT NULL
        CHECK (scope IN ('franco_private', 'gia_private', 'household_shared')),
    title TEXT NOT NULL,
    done INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0, 1)),
    author_person_id TEXT NOT NULL REFERENCES person(id),
    created_at TEXT NOT NULL
);

CREATE INDEX task_scope ON task (scope);

CREATE TABLE reminder (
    id TEXT PRIMARY KEY,
    scope TEXT NOT NULL
        CHECK (scope IN ('franco_private', 'gia_private', 'household_shared')),
    text TEXT NOT NULL,
    due_at TEXT NOT NULL,
    delivered_at TEXT,
    author_person_id TEXT NOT NULL REFERENCES person(id),
    created_at TEXT NOT NULL
);

CREATE INDEX reminder_scope_due ON reminder (scope, due_at);

CREATE TABLE household_list (
    id TEXT PRIMARY KEY,
    scope TEXT NOT NULL
        CHECK (scope IN ('franco_private', 'gia_private', 'household_shared')),
    name TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE (scope, name)
);

CREATE TABLE list_item (
    id TEXT PRIMARY KEY,
    list_id TEXT NOT NULL REFERENCES household_list(id),
    text TEXT NOT NULL,
    added_by_person_id TEXT NOT NULL REFERENCES person(id),
    created_at TEXT NOT NULL,
    removed_at TEXT
);

CREATE INDEX list_item_list ON list_item (list_id);

CREATE TABLE approval (
    id TEXT PRIMARY KEY,
    action_version TEXT NOT NULL,
    tool TEXT NOT NULL,
    actor_person_id TEXT NOT NULL REFERENCES person(id),
    route_id TEXT NOT NULL REFERENCES route(id),
    resource TEXT NOT NULL,
    destination TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('pending', 'granted', 'consumed')),
    requested_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    granted_at TEXT,
    granted_by_person_id TEXT REFERENCES person(id),
    consumed_at TEXT
);

CREATE INDEX approval_actor ON approval (actor_person_id);
