-- Facts schema for SQLite
-- Loaded by facts.hy at module import

-- Main facts table
CREATE TABLE IF NOT EXISTS facts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    subject TEXT NOT NULL,
    predicate TEXT NOT NULL,
    object TEXT,
    location TEXT,
    coords TEXT,
    timestamp REAL NOT NULL,
    source TEXT NOT NULL,
    source_type TEXT DEFAULT 'character',
    fact_type TEXT DEFAULT 'fact',
    confidence REAL DEFAULT 1.0,
    expires_at REAL,
    invalidated_at REAL,
    invalidated_reason TEXT,
    created_at REAL DEFAULT (strftime('%s', 'now'))
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_facts_subject ON facts(subject);
CREATE INDEX IF NOT EXISTS idx_facts_source ON facts(source);
CREATE INDEX IF NOT EXISTS idx_facts_location ON facts(location);
CREATE INDEX IF NOT EXISTS idx_facts_timestamp ON facts(timestamp);
CREATE INDEX IF NOT EXISTS idx_facts_source_subject ON facts(source, subject);
CREATE INDEX IF NOT EXISTS idx_facts_subject_predicate ON facts(subject, predicate);

-- Tags table
CREATE TABLE IF NOT EXISTS fact_tags (
    fact_id INTEGER REFERENCES facts(id) ON DELETE CASCADE,
    tag TEXT NOT NULL,
    PRIMARY KEY (fact_id, tag)
);
CREATE INDEX IF NOT EXISTS idx_fact_tags_tag ON fact_tags(tag);

-- Provenance table
CREATE TABLE IF NOT EXISTS fact_provenance (
    fact_id INTEGER REFERENCES facts(id) ON DELETE CASCADE,
    origin_type TEXT NOT NULL,
    origin_id TEXT,
    origin_data TEXT,
    PRIMARY KEY (fact_id)
);

-- FTS5 virtual table for full-text search
CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(
    subject, predicate, object, location,
    content='facts',
    content_rowid='id'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS facts_ai AFTER INSERT ON facts BEGIN
    INSERT INTO facts_fts(rowid, subject, predicate, object, location)
    VALUES (new.id, new.subject, new.predicate, new.object, new.location);
END;

CREATE TRIGGER IF NOT EXISTS facts_ad AFTER DELETE ON facts BEGIN
    INSERT INTO facts_fts(facts_fts, rowid, subject, predicate, object, location)
    VALUES ('delete', old.id, old.subject, old.predicate, old.object, old.location);
END;

CREATE TRIGGER IF NOT EXISTS facts_au AFTER UPDATE ON facts BEGIN
    INSERT INTO facts_fts(facts_fts, rowid, subject, predicate, object, location)
    VALUES ('delete', old.id, old.subject, old.predicate, old.object, old.location);
    INSERT INTO facts_fts(rowid, subject, predicate, object, location)
    VALUES (new.id, new.subject, new.predicate, new.object, new.location);
END;

-- Views
CREATE VIEW IF NOT EXISTS valid_facts AS
SELECT * FROM facts
WHERE invalidated_at IS NULL
    AND (expires_at IS NULL OR expires_at > strftime('%s', 'now'));

CREATE VIEW IF NOT EXISTS character_knowledge AS
SELECT * FROM valid_facts WHERE source_type = 'character';

CREATE VIEW IF NOT EXISTS world_facts AS
SELECT * FROM valid_facts WHERE source_type IN ('narrator', 'system');
