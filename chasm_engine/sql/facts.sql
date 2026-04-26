-- :name create_table_facts
-- :doc Create the main facts table
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

-- :name create_index_facts_subject
CREATE INDEX IF NOT EXISTS idx_facts_subject ON facts(subject);

-- :name create_index_facts_source
CREATE INDEX IF NOT EXISTS idx_facts_source ON facts(source);

-- :name create_index_facts_location
CREATE INDEX IF NOT EXISTS idx_facts_location ON facts(location);

-- :name create_index_facts_timestamp
CREATE INDEX IF NOT EXISTS idx_facts_timestamp ON facts(timestamp);

-- :name create_index_facts_source_subject
CREATE INDEX IF NOT EXISTS idx_facts_source_subject ON facts(source, subject);

-- :name create_index_facts_subject_predicate
CREATE INDEX IF NOT EXISTS idx_facts_subject_predicate ON facts(subject, predicate);

-- :name create_table_fact_tags
CREATE TABLE IF NOT EXISTS fact_tags (
    fact_id INTEGER REFERENCES facts(id) ON DELETE CASCADE,
    tag TEXT NOT NULL,
    PRIMARY KEY (fact_id, tag)
);

-- :name create_index_fact_tags_tag
CREATE INDEX IF NOT EXISTS idx_fact_tags_tag ON fact_tags(tag);

-- :name create_table_fact_provenance
CREATE TABLE IF NOT EXISTS fact_provenance (
    fact_id INTEGER REFERENCES facts(id) ON DELETE CASCADE,
    origin_type TEXT NOT NULL,
    origin_id TEXT,
    origin_data TEXT,
    PRIMARY KEY (fact_id)
);

-- :name create_fts_table
CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(
    subject, predicate, object, location,
    content='facts',
    content_rowid='id'
);

-- :name create_trigger_facts_ai
CREATE TRIGGER IF NOT EXISTS facts_ai AFTER INSERT ON facts BEGIN
    INSERT INTO facts_fts(rowid, subject, predicate, object, location)
    VALUES (new.id, new.subject, new.predicate, new.object, new.location);
END;

-- :name create_trigger_facts_ad
CREATE TRIGGER IF NOT EXISTS facts_ad AFTER DELETE ON facts BEGIN
    INSERT INTO facts_fts(facts_fts, rowid, subject, predicate, object, location)
    VALUES ('delete', old.id, old.subject, old.predicate, old.object, old.location);
END;

-- :name create_trigger_facts_au
CREATE TRIGGER IF NOT EXISTS facts_au AFTER UPDATE ON facts BEGIN
    INSERT INTO facts_fts(facts_fts, rowid, subject, predicate, object, location)
    VALUES ('delete', old.id, old.subject, old.predicate, old.object, old.location);
    INSERT INTO facts_fts(rowid, subject, predicate, object, location)
    VALUES (new.id, new.subject, new.predicate, new.object, new.location);
END;

-- :name create_view_valid_facts
CREATE VIEW IF NOT EXISTS valid_facts AS
SELECT * FROM facts
WHERE invalidated_at IS NULL
    AND (expires_at IS NULL OR expires_at > strftime('%s', 'now'));

-- :name create_view_character_knowledge
CREATE VIEW IF NOT EXISTS character_knowledge AS
SELECT * FROM valid_facts WHERE source_type = 'character';

-- :name create_view_world_facts
CREATE VIEW IF NOT EXISTS world_facts AS
SELECT * FROM valid_facts WHERE source_type IN ('narrator', 'system');

-- * Core CRUD operations
-- -----------------------------------------------------------------------------

-- :name insert_fact
-- :doc Insert a new fact and return its ID
INSERT INTO facts (subject, predicate, object, location, coords, timestamp, source, source_type, fact_type, confidence, expires_at)
VALUES (:subject, :predicate, :object, :location, :coords, :timestamp, :source, :source_type, :fact_type, :confidence, :expires_at)
RETURNING id;

-- :name get_fact_by_id
-- :doc Get a single fact by ID
SELECT * FROM facts WHERE id = :id;

-- :name invalidate_fact_by_id
-- :doc Mark a fact as invalidated
UPDATE facts SET invalidated_at = :invalidated_at, invalidated_reason = :invalidated_reason WHERE id = :id;

-- :name invalidate_facts_by_query
-- :doc Invalidate facts matching criteria
UPDATE facts SET invalidated_at = :invalidated_at, invalidated_reason = 'bulk_invalidation'
WHERE (:subject IS NULL OR subject = :subject)
    AND (:predicate IS NULL OR predicate = :predicate)
    AND (:object IS NULL OR object = :object)
    AND (:source IS NULL OR source = :source);

-- * Query operations
-- -----------------------------------------------------------------------------

-- :name query_facts
-- :doc Query facts with flexible filtering
SELECT * FROM facts
WHERE (:subject IS NULL OR subject = :subject)
    AND (:predicate IS NULL OR predicate = :predicate)
    AND (:object IS NULL OR object = :object)
    AND (:source IS NULL OR source = :source)
    AND (:location IS NULL OR location = :location)
    AND (:fact_type IS NULL OR fact_type = :fact_type)
    AND (:source_type IS NULL OR source_type = :source_type)
    AND (:only_valid = 0 OR invalidated_at IS NULL)
    AND (:only_valid = 0 OR expires_at IS NULL OR expires_at > strftime('%s', 'now'))
ORDER BY timestamp DESC
LIMIT COALESCE(:limit, 1000)
OFFSET COALESCE(:offset, 0);

-- :name search_facts_fts
-- :doc Full-text search across facts
SELECT f.* FROM facts f
JOIN facts_fts fts ON f.id = fts.rowid
WHERE facts_fts MATCH :query
    AND (:source IS NULL OR f.source = :source)
    AND f.invalidated_at IS NULL
ORDER BY f.timestamp DESC
LIMIT :n;

-- :name get_recent_facts
-- :doc Get the most recent facts
SELECT * FROM facts
WHERE invalidated_at IS NULL
    AND (expires_at IS NULL OR expires_at > strftime('%s', 'now'))
ORDER BY timestamp DESC
LIMIT :n;

-- * Tag operations
-- -----------------------------------------------------------------------------

-- :name insert_fact_tag
-- :doc Add a tag to a fact
INSERT OR IGNORE INTO fact_tags (fact_id, tag) VALUES (:fact_id, :tag);

-- :name get_tags_for_fact
-- :doc Get all tags for a fact
SELECT tag FROM fact_tags WHERE fact_id = :fact_id;

-- :name get_facts_with_tag
-- :doc Get all facts with a specific tag
SELECT f.* FROM facts f
JOIN fact_tags t ON f.id = t.fact_id
WHERE t.tag = :tag;

-- * Provenance operations
-- -----------------------------------------------------------------------------

-- :name insert_fact_provenance
-- :doc Add provenance information for a fact
INSERT INTO fact_provenance (fact_id, origin_type, origin_id, origin_data)
VALUES (:fact_id, :origin_type, :origin_id, :origin_data);
