"
Structured fact storage using SQLite.
Replaces the fragile ChromaDB-based memory system.
"

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])

(import json)
(import time [time])
(import sqlite3 [OperationalError connect Row])
(import pathlib [Path])

(import chasm_engine [log])
(import chasm_engine.lib [config])
(import chasm_engine.state [path])


;; * Schema (loaded from SQL file)
;; -----------------------------------------------------------------------------

(defn get-schema-sql []
  "Load schema SQL from file as a single string."
  (let [module-dir (getattr (Path __file__) "parent")
        sql-path (.joinpath module-dir "sql" "schema.sql")]
    (.read_text sql-path)))

(setv schema-statements (get-schema-sql))


(defn init-schema []
  "Initialise the facts schema. Called on module load."
  (let [db (get-db)]
    (try
      ;; Use executescript for proper handling of triggers with embedded semicolons
      (.executescript db schema-statements)
      (.commit db)
      (log.info "Facts schema initialised")
      (except [e OperationalError]
        (log.error f"Failed to initialise facts schema: {e}"))
      (finally
        (.close db)))))


;; * Helpers
;; -----------------------------------------------------------------------------

(defn row->dict [row]
  "Convert a sqlite row to a dict."
  (let [keys (row.keys)]
    (dict (zip keys row))))


(defn time []
  "Current Unix timestamp."
  (import time [time])
  (time))


(defn get-db []
  "Get a connection to the facts database."
  (let [db-path f"{path}/facts.sqlite"
        conn (connect db-path)]
    ;; Return rows as dict-like objects
    (setv conn.row_factory Row)
    conn))


;; * Core CRUD
;; -----------------------------------------------------------------------------

(defn add-fact [subject predicate object
                [location None]
                [coords None]
                [source None]
                [source-type "character"]
                [fact-type "fact"]
                [confidence 1.0]
                [expires-after None]
                [tags []]
                [origin-type "observation"]
                [origin-id None]
                [origin-data None]]
  "Add a new fact. Returns fact ID or None on failure.

  Args:
    subject: Who/what the fact is about (e.g. 'Alice', 'the sword')
    predicate: Relationship (e.g. 'knows', 'has', 'is', 'saw', 'wants')
    object: Target of relationship (can be None for unary facts)
    location: Place name where fact was learned
    coords: Coords dict {'x': int, 'y': int}
    source: Who knows this (character name or 'narrator')
    source-type: 'character', 'narrator', or 'system'
    fact-type: 'fact', 'belief', 'rumour', 'observation'
    confidence: 0.0-1.0 certainty level
    expires-after: Seconds until expiration, or None
    tags: List of category tags
    origin-type: How this fact was derived
    origin-data: Raw text that generated this fact"
  (let [db (get-db)
        cursor (.cursor db)
        now (time)
        expires (when expires-after (+ now expires-after))
        coords-json (when coords (json.dumps coords))]
    (try
      (.execute cursor
        "INSERT INTO facts (subject, predicate, object, location, coords, timestamp, source, source_type, fact_type, confidence, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        #(subject predicate object location coords-json now source source-type fact-type confidence expires))
      (let [fact-id cursor.lastrowid]
        ;; Add tags
        (when tags
          (.executemany cursor
            "INSERT INTO fact_tags (fact_id, tag) VALUES (?, ?)"
            (lfor tag tags #(fact-id tag))))
        ;; Add provenance
        (when origin-data
          (.execute cursor
            "INSERT INTO fact_provenance (fact_id, origin_type, origin_id, origin_data) VALUES (?, ?, ?, ?)"
            #(fact-id origin-type origin-id origin-data)))
        (.commit db)
        fact-id)
      (except [e OperationalError]
        (log.error f"Failed to add fact: {e}")
        None)
      (finally
        (.close db)))))


(defn get-fact [fact-id]
  "Retrieve a single fact by ID. Returns dict or None."
  (let [db (get-db)
        cursor (.cursor db)]
    (try
      (.execute cursor "SELECT * FROM facts WHERE id = ?" #(fact-id))
      (let [row (.fetchone cursor)]
        (when row (row->dict row)))
      (finally
        (.close db)))))


(defn invalidate-fact [fact-id reason]
  "Mark a fact as invalidated. Returns True on success."
  (let [db (get-db)
        cursor (.cursor db)]
    (try
      (.execute cursor
        "UPDATE facts SET invalidated_at = ?, invalidated_reason = ? WHERE id = ?"
        #((time) reason fact-id))
      (.commit db)
      (> cursor.rowcount 0)
      (finally
        (.close db)))))


(defn invalidate-by-query [subject predicate object source]
  "Invalidate all facts matching the given criteria.
  Any None parameter is treated as wildcard.
  Returns count of invalidated facts."
  (let [conditions []
        params []]
    (when subject (do (.append conditions "subject = ?") (.append params subject)))
    (when predicate (do (.append conditions "predicate = ?") (.append params predicate)))
    (when object (do (.append conditions "object = ?") (.append params object)))
    (when source (do (.append conditions "source = ?") (.append params source)))
    (let [where-clause (if conditions (+ "WHERE " (.join " AND " conditions)) "")
          db (get-db)
          cursor (.cursor db)]
      (try
        (.execute cursor
          (+ "UPDATE facts SET invalidated_at = strftime('%s', 'now'), invalidated_reason = 'bulk_invalidation' " where-clause)
          params)
        (.commit db)
        (.rowcount cursor)
        (finally
          (.close db))))))


;; * Querying
;; -----------------------------------------------------------------------------

(defn query-facts [[subject None]
                   [predicate None]
                   [object None]
                   [source None]
                   [location None]
                   [fact-type None]
                   [source-type None]
                   [only-valid True]
                   [limit None]
                   [offset None]]
  "Query facts with flexible filtering. Returns list of dicts.

  Args:
    subject: Filter by subject (exact match)
    predicate: Filter by predicate (exact match)
    object: Filter by object (exact match)
    source: Filter by source (who knows this)
    location: Filter by location
    fact-type: Filter by fact type
    source-type: Filter by source type
    only-valid: Exclude invalidated/expired facts
    limit: Maximum results to return
    offset: Skip this many results"
  (let [conditions []
        params []]
    (when subject (do (.append conditions "subject = ?") (.append params subject)))
    (when predicate (do (.append conditions "predicate = ?") (.append params predicate)))
    (when object (do (.append conditions "object = ?") (.append params object)))
    (when source (do (.append conditions "source = ?") (.append params source)))
    (when location (do (.append conditions "location = ?") (.append params location)))
    (when fact-type (do (.append conditions "fact_type = ?") (.append params fact-type)))
    (when source-type (do (.append conditions "source_type = ?") (.append params source-type)))
    (when only-valid (do (.append conditions "invalidated_at IS NULL") 
                         (.append conditions "(expires_at IS NULL OR expires_at > strftime('%s', 'now'))")))
    
    (let [where-clause (if conditions (+ "WHERE " (.join " AND " conditions)) "")
          limit-clause (if limit (+ "LIMIT " (str limit)) "")
          offset-clause (if offset (+ "OFFSET " (str offset)) "")
          sql (+ "SELECT * FROM facts " where-clause " ORDER BY timestamp DESC " limit-clause " " offset-clause)
          db (get-db)
          cursor (.cursor db)]
      (try
        (.execute cursor sql params)
        (lfor row (.fetchall cursor) (row->dict row))
        (finally
          (.close db))))))


(defn what-does-know [character-name about-subject]
  "Convenience: what does X know about Y?"
  (query-facts :source character-name :subject about-subject))


(defn facts-at-location [location-name]
  "Convenience: facts about a location."
  (query-facts :location location-name))


(defn recent-facts [[n 10]]
  "Get the most recent facts."
  (query-facts :limit n))


(defn search-facts [query [n 20] [source None]]
  "Full-text search across facts. Returns list of dicts.

  Args:
    query: FTS5 search query (e.g. 'sword OR key')
    n: Maximum results to return
    source: Optional filter by source (character name)

  Example:
    (search-facts \"golden\")
    (search-facts \"tavern AND Alice\")
  "
  (let [db (get-db)
        cursor (.cursor db)
        source-filter (if source "AND source = ?" "")
        sql (+ "SELECT f.* FROM facts f "
               "JOIN facts_fts fts ON f.id = fts.rowid "
               "WHERE facts_fts MATCH ? "
               source-filter
               " AND f.invalidated_at IS NULL "
               "ORDER BY f.timestamp DESC LIMIT ?")
        params (if source [query source n] [query n])]
    (try
      (.execute cursor sql params)
      (lfor row (.fetchall cursor) (row->dict row))
      (except [OperationalError]
        [])
      (finally
        (.close db)))))


;; * Convenience Functions
;; -----------------------------------------------------------------------------

(defn format-fact [fact]
  "Format a fact for display."
  (let [subject (:subject fact)
        predicate (:predicate fact)
        object (:object fact)
        location (:location fact)
        source (:source fact)]
    (if object
      f"{source} knows: {subject} {predicate} {object}"
      f"{source} knows: {subject} {predicate}")))


(defn format-fact-for-narrative [fact]
  "Format a fact for narrative context."
  (let [subject (:subject fact)
        predicate (:predicate fact)
        object (:object fact)]
    (if object
      f"{subject} {predicate} {object}"
      f"{subject} {predicate}")))


;; * Tag Operations
;; -----------------------------------------------------------------------------

(defn add-tag [fact-id tag]
  "Add a tag to a fact."
  (let [db (get-db)
        cursor (.cursor db)]
    (try
      (.execute cursor
        "INSERT OR IGNORE INTO fact_tags (fact_id, tag) VALUES (?, ?)"
        #(fact-id tag))
      (.commit db)
      True
      (except [e OperationalError]
        (log.error f"Failed to add tag: {e}")
        False)
      (finally
        (.close db)))))


(defn get-tags [fact-id]
  "Get all tags for a fact."
  (let [db (get-db)
        cursor (.cursor db)]
    (try
      (.execute cursor
        "SELECT tag FROM fact_tags WHERE fact_id = ?"
        #(fact-id))
      (lfor row (.fetchall cursor) (get row 0))
      (finally
        (.close db)))))


(defn facts-with-tag [tag]
  "Get all facts with a specific tag."
  (let [db (get-db)
        cursor (.cursor db)]
    (try
      (.execute cursor
        "SELECT f.* FROM facts f JOIN fact_tags t ON f.id = t.fact_id WHERE t.tag = ?"
        #(tag))
      (lfor row (.fetchall cursor) (row->dict row))
      (finally
        (.close db)))))


;; * Initialisation
;; -----------------------------------------------------------------------------

;; Initialise schema on module load
(init-schema)
