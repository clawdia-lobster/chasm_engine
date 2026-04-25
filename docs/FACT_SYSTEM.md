# Fact System Design

Replace the fragile ChromaDB memory system with a structured, queryable fact store
embedded in the existing SQLite database.

---

## Motivation

### Current problems

| Problem | Root cause |
|---------|-----------|
| Regex extraction breaks on LLM variation | `remember` parses `[class] point` with `re.search` |
| "What does Alice know about Bob?" has no clean answer | Semantic search returns approximate matches, not provenance-scoped records |
| No way to invalidate stale facts | ChromaDB has no update/delete by field |
| Child threads cannot write memories | ChromaDB singleton: `which sadly means no concurrency` |
| ChromaDB is a heavy external dependency | Adds ~200 MB, runs its own HTTP telemetry, needs a local embedding model |

### Design goals

1. **Structured triples** — `(subject, predicate, object)` with metadata
2. **Provenance-scoped queries** — "what does character X know about Y?"
3. **Temporal validity** — expiration and invalidation as first-class operations
4. **Zero new dependencies** — `sqlite3` is already in `state.hy`
5. **Clean migration path** — `memory.hy` API preserved during transition

---

## Schema

All tables live in the existing `{world}/world.sqlite` file alongside characters,
places, and items. The `SqliteDict` tables use a separate sqlite connection so there
is no schema conflict; `facts` and `fact_witnesses` use direct `sqlite3` access.

```sql
-- Core fact store: subject-predicate-object triples
CREATE TABLE IF NOT EXISTS facts (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    subject      TEXT    NOT NULL,   -- entity the fact is about (character name, place name, item name)
    predicate    TEXT    NOT NULL,   -- relationship type ('knows', 'has', 'is-at', 'wants', ...)
    object       TEXT,               -- target of predicate; NULL for unary predicates
    location     TEXT,               -- place name where fact was established
    coords       TEXT,               -- JSON {"x": int, "y": int}
    timestamp    REAL    NOT NULL,   -- Unix time (float) when fact was established
    classification TEXT DEFAULT 'observation',  -- 'observation', 'significant', 'major', 'rumour'
    valid        INTEGER NOT NULL DEFAULT 1,    -- 0 = invalidated
    invalidated_reason TEXT,                    -- why it was invalidated
    expires_at   REAL                           -- Unix time; NULL = never expires
);

-- Per-character knowledge: which characters know which facts
-- A fact may be known by many characters (e.g. public events)
CREATE TABLE IF NOT EXISTS fact_witnesses (
    fact_id    INTEGER NOT NULL REFERENCES facts(id) ON DELETE CASCADE,
    character  TEXT    NOT NULL,  -- character-key of the knowing character, or 'narrator'
    learned_at REAL    NOT NULL,  -- when this character learned it
    PRIMARY KEY (fact_id, character)
);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_facts_subject       ON facts(subject);
CREATE INDEX IF NOT EXISTS idx_facts_predicate     ON facts(predicate);
CREATE INDEX IF NOT EXISTS idx_facts_location      ON facts(location);
CREATE INDEX IF NOT EXISTS idx_facts_valid         ON facts(valid);
CREATE INDEX IF NOT EXISTS idx_facts_timestamp     ON facts(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_witnesses_character ON fact_witnesses(character);
CREATE INDEX IF NOT EXISTS idx_witnesses_fact      ON fact_witnesses(fact_id);

-- Convenience view: only live facts
CREATE VIEW IF NOT EXISTS live_facts AS
    SELECT f.*, group_concat(w.character) AS witnesses
    FROM   facts f
    JOIN   fact_witnesses w ON w.fact_id = f.id
    WHERE  f.valid = 1
      AND  (f.expires_at IS NULL OR f.expires_at > unixepoch('now'))
    GROUP  BY f.id;
```

### Field semantics

| Field | Notes |
|-------|-------|
| `subject` | Normalised entity name. For characters use `character-key`; for places use `place.name`; for items use `item.name`. |
| `predicate` | Verb-phrase in kebab-style: `"knows"`, `"is-at"`, `"has"`, `"wants"`, `"saw"`, `"is-dead"`. |
| `object` | Optional second entity or free-text phrase. `NULL` for state facts like `(Alice, is-dead, NULL)`. |
| `location` | Where the fact was witnessed or established. Supports `WHERE location = ?` queries. |
| `classification` | Mirrors current ChromaDB metadata. `'observation'` is default; `'significant'` / `'major'` for important events. |
| `witnesses` | Separate table. The fact exists once; multiple characters can know it. |

---

## API — `chasm_engine/facts.hy`

```hy
"
Structured fact storage and retrieval.
Replaces chasm_engine.memory for all structured recall needs.
"

(require hyrule [-> ->> unless])

(import time [time])
(import json)
(import sqlite3)

(import chasm_engine [log])
(import chasm_engine.lib [config])


;; ---------------------------------------------------------------------------
;; Connection
;; ---------------------------------------------------------------------------

(setv _path (config "world"))

(defn _db []
  "Open a connection to the world database."
  (let [conn (sqlite3.connect f"{_path}/world.sqlite"
                              :check-same-thread False
                              :isolation-level None)]   ; autocommit
    (setv conn.row-factory sqlite3.Row)
    conn))

(defn _row->dict [row]
  "Convert a sqlite3.Row to a plain dict."
  (dict row))


;; ---------------------------------------------------------------------------
;; Schema initialisation
;; ---------------------------------------------------------------------------

(setv _SCHEMA "
CREATE TABLE IF NOT EXISTS facts (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    subject        TEXT    NOT NULL,
    predicate      TEXT    NOT NULL,
    object         TEXT,
    location       TEXT,
    coords         TEXT,
    timestamp      REAL    NOT NULL,
    classification TEXT    NOT NULL DEFAULT 'observation',
    valid          INTEGER NOT NULL DEFAULT 1,
    invalidated_reason TEXT,
    expires_at     REAL
);

CREATE TABLE IF NOT EXISTS fact_witnesses (
    fact_id    INTEGER NOT NULL REFERENCES facts(id) ON DELETE CASCADE,
    character  TEXT    NOT NULL,
    learned_at REAL    NOT NULL,
    PRIMARY KEY (fact_id, character)
);

CREATE INDEX IF NOT EXISTS idx_facts_subject       ON facts(subject);
CREATE INDEX IF NOT EXISTS idx_facts_predicate     ON facts(predicate);
CREATE INDEX IF NOT EXISTS idx_facts_location      ON facts(location);
CREATE INDEX IF NOT EXISTS idx_facts_valid         ON facts(valid);
CREATE INDEX IF NOT EXISTS idx_facts_timestamp     ON facts(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_witnesses_character ON fact_witnesses(character);
CREATE INDEX IF NOT EXISTS idx_witnesses_fact      ON fact_witnesses(fact_id);

CREATE VIEW IF NOT EXISTS live_facts AS
    SELECT f.*, group_concat(w.character) AS witnesses
    FROM   facts f
    JOIN   fact_witnesses w ON w.fact_id = f.id
    WHERE  f.valid = 1
      AND  (f.expires_at IS NULL OR f.expires_at > unixepoch('now'))
    GROUP  BY f.id;
")

(defn init-schema []
  "Initialise the facts schema. Safe to call repeatedly."
  (let [conn (_db)]
    (try
      (conn.executescript _SCHEMA)
      (log.info "facts: schema ready")
      (except [e Exception]
        (log.error f"facts: schema init failed: {e}"))
      (finally
        (conn.close)))))

;; Run on import
(init-schema)


;; ---------------------------------------------------------------------------
;; Write operations
;; ---------------------------------------------------------------------------

(defn add [subject predicate *
           [object None]
           [location None]
           [coords None]
           [classification "observation"]
           [character None]                ; who learns this fact (character-key or "narrator")
           [characters []]                 ; multiple witnesses
           [expires-after None]]           ; seconds until expiry, or None
  "Add a fact triple to the store.

  Returns the new fact id, or None on error.

  subject        — entity the fact is about
  predicate      — relationship type, kebab-style ('knows', 'is-at', 'has', ...)
  object         — optional target entity or description
  location       — place name where established
  coords         — Coords dict {\"x\" int \"y\" int}
  classification — 'observation' | 'significant' | 'major' | 'rumour'
  character      — single knowing character (character-key or 'narrator')
  characters     — list of knowing characters (merged with `character` if given)
  expires-after  — seconds until this fact expires; None = permanent
  "
  (let [conn (_db)
        now (time)
        expires (when expires-after (+ now expires-after))
        coords-json (when coords (json.dumps coords))
        all-witnesses (-> (list characters)
                          (+ (if character [character] []))
                          (set)
                          (list))]
    (try
      (let [cursor (.execute conn
                     "INSERT INTO facts
                        (subject, predicate, object, location, coords, timestamp,
                         classification, expires_at)
                      VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
                     #(subject predicate object location coords-json now
                       classification expires))
            fact-id cursor.lastrowid]
        (when all-witnesses
          (.executemany conn
            "INSERT OR IGNORE INTO fact_witnesses (fact_id, character, learned_at)
             VALUES (?, ?, ?)"
            (lfor c all-witnesses #(fact-id c now))))
        (log.debug f"facts: added #{fact-id} {subject!r} {predicate!r} {object!r}")
        fact-id)
      (except [e Exception]
        (log.error f"facts: add failed: {e}")
        None)
      (finally
        (conn.close)))))

(defn witness [fact-id character]
  "Record that `character` now knows fact `fact-id`.
  Idempotent; safe to call if the witness already exists.
  Returns True on success."
  (let [conn (_db)]
    (try
      (.execute conn
        "INSERT OR IGNORE INTO fact_witnesses (fact_id, character, learned_at)
         VALUES (?, ?, ?)"
        #(fact-id character (time)))
      True
      (except [e Exception]
        (log.error f"facts: witness failed for #{fact-id}: {e}")
        False)
      (finally
        (conn.close)))))

(defn invalidate [fact-id reason]
  "Mark fact `fact-id` as no longer valid.
  Returns True on success."
  (let [conn (_db)]
    (try
      (.execute conn
        "UPDATE facts SET valid = 0, invalidated_reason = ? WHERE id = ?"
        #(reason fact-id))
      (log.info f"facts: invalidated #{fact-id}: {reason}")
      True
      (except [e Exception]
        (log.error f"facts: invalidate #{fact-id} failed: {e}")
        False)
      (finally
        (conn.close)))))

(defn invalidate-about [subject * [predicate None] [character None] [reason "superseded"]]
  "Invalidate all live facts about `subject`, optionally filtered by predicate or witness.
  Use when a fact is known to be wrong or outdated.
  Returns count of rows updated."
  (let [conn (_db)
        conditions ["f.valid = 1" "f.subject = ?"]
        params [subject]]
    (when predicate
      (.append conditions "f.predicate = ?")
      (.append params predicate))
    (when character
      (.append conditions
        "EXISTS (SELECT 1 FROM fact_witnesses fw WHERE fw.fact_id = f.id AND fw.character = ?)")
      (.append params character))
    (let [where (.join " AND " conditions)
          sql f"UPDATE facts SET valid = 0, invalidated_reason = ?
                WHERE id IN (SELECT f.id FROM facts f WHERE {where})"
          _ (.insert params 0 reason)]  ; reason is first param in UPDATE SET
      (try
        (let [cursor (.execute conn sql (tuple params))]
          (log.info f"facts: invalidated {cursor.rowcount} facts about {subject!r}")
          cursor.rowcount)
        (except [e Exception]
          (log.error f"facts: invalidate-about failed: {e}")
          0)
        (finally
          (conn.close))))))

(defn expire-stale []
  "Soft-delete all facts past their expiry time. Call periodically.
  Returns count removed."
  (let [conn (_db)]
    (try
      (let [cursor (.execute conn
                     "UPDATE facts SET valid = 0, invalidated_reason = 'expired'
                      WHERE valid = 1
                        AND expires_at IS NOT NULL
                        AND expires_at < unixepoch('now')")]
        (when (> cursor.rowcount 0)
          (log.info f"facts: expired {cursor.rowcount} facts"))
        cursor.rowcount)
      (except [e Exception]
        (log.error f"facts: expire-stale failed: {e}")
        0)
      (finally
        (conn.close)))))


;; ---------------------------------------------------------------------------
;; Read operations
;; ---------------------------------------------------------------------------

(defn _fetch [sql params]
  "Execute `sql` with `params`, return list of dicts."
  (let [conn (_db)]
    (try
      (->> (.execute conn sql (tuple params))
           (.fetchall)
           (map _row->dict)
           (list))
      (except [e Exception]
        (log.error f"facts: query failed: {e}")
        [])
      (finally
        (conn.close)))))

(defn known-by [character *
                [subject None]
                [predicate None]
                [location None]
                [classification None]
                [limit 20]]
  "Return live facts known by `character` (character-key or 'narrator').

  subject        — filter by subject entity
  predicate      — filter by predicate type
  location       — filter by place where established
  classification — filter by classification tag
  limit          — maximum rows returned (most recent first)
  "
  (let [conditions ["fw.character = ?" "f.valid = 1"
                    "(f.expires_at IS NULL OR f.expires_at > unixepoch('now'))"]
        params [character]]
    (when subject
      (.append conditions "f.subject = ?")
      (.append params subject))
    (when predicate
      (.append conditions "f.predicate = ?")
      (.append params predicate))
    (when location
      (.append conditions "f.location = ?")
      (.append params location))
    (when classification
      (.append conditions "f.classification = ?")
      (.append params classification))
    (.append params limit)
    (let [where (.join " AND " conditions)]
      (_fetch f"SELECT f.*
               FROM   facts f
               JOIN   fact_witnesses fw ON fw.fact_id = f.id
               WHERE  {where}
               ORDER  BY f.timestamp DESC
               LIMIT  ?"
              params))))

(defn about [subject *
             [character None]
             [predicate None]
             [classification None]
             [limit 20]]
  "Return live facts about `subject`, optionally filtered by knowing character.

  character      — if given, only facts known by this character
  predicate      — filter by predicate type
  classification — filter by classification tag
  limit          — maximum rows returned
  "
  (let [conditions ["f.subject = ?" "f.valid = 1"
                    "(f.expires_at IS NULL OR f.expires_at > unixepoch('now'))"]
        params [subject]]
    (when character
      (.append conditions
        "EXISTS (SELECT 1 FROM fact_witnesses fw WHERE fw.fact_id = f.id AND fw.character = ?)")
      (.append params character))
    (when predicate
      (.append conditions "f.predicate = ?")
      (.append params predicate))
    (when classification
      (.append conditions "f.classification = ?")
      (.append params classification))
    (.append params limit)
    (let [where (.join " AND " conditions)]
      (_fetch f"SELECT f.*
               FROM   facts f
               WHERE  {where}
               ORDER  BY f.timestamp DESC
               LIMIT  ?"
              params))))

(defn at-location [location *
                   [character None]
                   [classification None]
                   [limit 20]]
  "Return live facts established at `location`.

  character      — if given, only facts known by this character
  classification — filter by classification tag
  "
  (let [conditions ["f.location = ?" "f.valid = 1"
                    "(f.expires_at IS NULL OR f.expires_at > unixepoch('now'))"]
        params [location]]
    (when character
      (.append conditions
        "EXISTS (SELECT 1 FROM fact_witnesses fw WHERE fw.fact_id = f.id AND fw.character = ?)")
      (.append params character))
    (when classification
      (.append conditions "f.classification = ?")
      (.append params classification))
    (.append params limit)
    (let [where (.join " AND " conditions)]
      (_fetch f"SELECT f.*
               FROM   facts f
               WHERE  {where}
               ORDER  BY f.timestamp DESC
               LIMIT  ?"
              params))))

(defn recent [character * [n 10] [classification None]]
  "Return the `n` most recent live facts known by `character`."
  (known-by character :classification classification :limit n))

(defn narrated [* [n 10] [classification "major"]]
  "Return recent narrator-level facts (world events, plot points)."
  (known-by "narrator" :n n :classification classification))


;; ---------------------------------------------------------------------------
;; Formatting helpers
;; ---------------------------------------------------------------------------

(defn fact->str [fact]
  "Render a fact dict as a short human-readable string."
  (let [s (get fact "subject")
        p (get fact "predicate")
        o (get fact "object")
        loc (get fact "location")]
    (if o
        (if loc f"{s} {p} {o} (at {loc})" f"{s} {p} {o}")
        (if loc f"{s} {p} (at {loc})" f"{s} {p}"))))

(defn facts->context [facts]
  "Format a list of fact dicts as a bulleted context block."
  (->> facts
       (map fact->str)
       (map (fn [s] f"- {s}"))
       (list)
       (.join "\n")))
```

---

## Integration with `character.hy`

### Replace `remember`

Current `remember` uses regex to parse `[classification] point` from a raw LLM string. Replace with structured storage after the LLM has already extracted structured data in `develop-json`.

```hy
;; In character.hy — replace remember

(defn remember [character subject predicate *
                [object None]
                [classification "observation"]
                [expires-after None]]
  "Store a fact learned by this character.

  subject        — what the fact is about (another character, item, place)
  predicate      — relationship ('knows', 'is-at', 'has', 'wants', ...)
  object         — optional description or target entity
  classification — 'observation' | 'significant' | 'major' | 'rumour'
  expires-after  — seconds until expiry (None = permanent)
  "
  (log.info f"{character.name} remembers: {subject} {predicate} {object}")
  (facts.add subject predicate
             :object object
             :location (place.name character.coords)
             :coords character.coords
             :classification classification
             :character (character-key character.name)
             :expires-after expires-after))
```

### Replace `recall`

```hy
;; In character.hy — replace recall

(defn recall [character * [about None] [location None] [n 6] [classification "significant"]]
  "What does this character know?

  about          — filter to facts about this subject
  location       — filter to facts learned at this location
  n              — number of facts to return
  classification — filter by classification tag
  "
  (facts/known-by (character-key character.name)
                  :subject about
                  :location location
                  :classification classification
                  :limit n))
```

### `develop-json` change

The LLM prompt already returns a `new_memory` field in its JSON. Change that field's format from the fragile `[classification] text` string to a small dict:

```json
{
  "new_memory": {
    "subject": "Bob",
    "predicate": "is-hiding",
    "object": "in the mill",
    "classification": "significant"
  }
}
```

Then in `develop-json`:

```hy
;; In character.hy, inside develop-json

(let [raw-memory (.pop clean-details "new_memory" None)]
  (when (isinstance raw-memory dict)
    (remember character
              (:subject raw-memory subject)   ; default to the character itself
              (:predicate raw-memory "observed")
              :object (:object raw-memory None)
              :classification (:classification raw-memory "observation"))))
```

---

## Integration with `plot.hy`

### Replace narrator memory writes

```hy
;; In plot.hy — replace memory.add calls in extract-point

(defn record-plot-point [subject predicate object *
                         [location None] [coords None]
                         [classification "major"]
                         [characters []]]
  "Record a world-level plot point known to the narrator and present characters."
  (facts.add subject predicate
             :object object
             :location location
             :coords coords
             :classification classification
             :character "narrator"
             :characters characters))

;; Replace narrator memory reads

(defn recent [[n 5] [classification "major"]]
  "Return `n` recent narrator facts."
  (->> (facts.narrated :n n :classification classification)
       (map facts.fact->str)
       (list)))

(defn recall-points [subject [n 6] [classification "major"]]
  "Recall narrator facts about `subject`."
  (->> (facts.about subject
                    :character "narrator"
                    :classification classification
                    :limit n)
       (map facts.fact->str)
       (list)))
```

### `extract-point` rewrite

Change the LLM prompt to return structured JSON instead of `[class] text`. Then:

```hy
(defn :async extract-point [messages player]
  "Scan recent conversation for plot points; store as structured facts."
  (let [msgs (truncate (cut messages -6 None) :spare-length 1000)
        narrative (format-msgs (msgs->dlg "narrative" player.name msgs))
        response (await (plot-point :world world :narrative narrative))
        point (extract-json response)
        chars-here (lfor c (append player (character.get-at player.coords)) c.name)]
    (when (and point (:subject point None) (:predicate point None))
      (log.info f"plot point: {point}")
      (record-plot-point (:subject point)
                         (:predicate point)
                         (:object point None)
                         :location (place.name player.coords)
                         :coords player.coords
                         :classification (:classification point "major")
                         :characters chars-here))))
```

The updated `plot-point` system prompt should request JSON like:

```
{"subject": "the king", "predicate": "is-dead", "object": null, "classification": "major"}
```

---

## Migration Plan

### Phase 0 — foundation (no behaviour change)

1. Add `chasm_engine/facts.hy` with schema and full API.
2. Call `facts.init-schema` at startup (idempotent).
3. No existing code changes yet.

### Phase 1 — dual write

Modify `character.remember` and `plot.extract-point` to write to **both** ChromaDB
and the new facts table. Read operations remain on ChromaDB.

```hy
;; Temporary shim in character.hy
(defn remember [character new-memory]
  "Dual-write during migration: both ChromaDB and facts table."
  ;; --- legacy path (unchanged) ---
  (let [mem-class (re.search r"\[(\w+)\]" new-memory)
        mem-point (re.search r"\][- ]*([\w ,.']+)" new-memory)]
    (when (and mem-class mem-point
               (not (in "[forgettable]" new-memory))
               (not (in "[classification]" new-memory)))
      (memory.add (character-key character.name)
                  {"character" character.name
                   "coords" (str character.coords)
                   "place" (place.name character.coords)
                   "time" f"{(time):015.2f}"
                   "classification" (.lower (first (.groups mem-class)))}
                  (first (.groups mem-point)))
      ;; --- new path ---
      (facts.add character.name "remembers"
                 :object (first (.groups mem-point))
                 :location (place.name character.coords)
                 :coords character.coords
                 :classification (.lower (first (.groups mem-class)))
                 :character (character-key character.name)))))
```

### Phase 2 — historical migration script

Run once to backfill all ChromaDB records into the facts table:

```hy
(defn migrate-chroma->facts []
  "One-shot migration of all ChromaDB collections into the facts table."
  (import chasm_engine.state [get-characters character-key])
  (import chasm_engine [memory])
  ;; Migrate character memories
  (for [char (get-characters)]
    (let [ckey (character-key char.name)
          data (memory.peek ckey)]
      (when data
        (for [#(doc meta) (zip (get data "documents") (get data "metadatas"))]
          (facts.add ckey "remembers"
                     :object doc
                     :location (get meta "place" None)
                     :classification (get meta "classification" "observation")
                     :character ckey)))))
  ;; Migrate narrator / plot memories
  (let [data (memory.peek "narrator")]
    (when data
      (for [#(doc meta) (zip (get data "documents") (get data "metadatas"))]
        (facts.add "world" "plot-point"
                   :object doc
                   :location (get meta "place" None)
                   :classification (get meta "classification" "major")
                   :character "narrator")))))
```

### Phase 3 — read cutover

Switch `recall` and `recall-points` to read from the facts table.
Keep ChromaDB writes for one release as a safety net.

### Phase 4 — ChromaDB removal

Remove `memory.hy`, the ChromaDB dependency from `pyproject.toml`, and the
on-disk `{world}/memory/` directory.

```
chroma           # remove from pyproject.toml
sentence-transformers  # remove if only used for embeddings
```

---

## Example Queries

```hy
;; What does Alice know about Bob?
(facts/known-by "alice" :subject "bob")

;; What does anyone know about the cursed amulet?
(facts/about "cursed amulet")

;; What major plot points are known to the narrator?
(facts/known-by "narrator" :classification "major")

;; What happened at the tavern, as far as Alice knows?
(facts/known-by "alice" :location "The Rusty Flagon")

;; Has anyone recorded Bob's whereabouts?
(facts/about "bob" :predicate "is-at")

;; Recent events for narrator context
(facts/narrated :n 5)

;; Invalidate stale location fact when character moves
(facts/invalidate-about "bob" :predicate "is-at" :reason "character moved")

;; All facts that will expire within 60 seconds (diagnostic)
(let [conn (facts/_db)
      soon (+ (time) 60)]
  (.fetchall (.execute conn
    "SELECT * FROM facts WHERE valid=1 AND expires_at IS NOT NULL AND expires_at < ?"
    #(soon))))
```

---

## Comparison: before and after

| Operation | ChromaDB (current) | Facts table (new) |
|-----------|-------------------|-------------------|
| Store character memory | `memory.add ckey meta text` | `facts.add subject pred :character ckey` |
| Recall what Alice knows about Bob | `memory.query "alice" "Bob" :where {"classification" "significant"}` → fuzzy | `(facts/known-by "alice" :subject "bob")` → exact |
| Recall recent plot points | `memory.recent "narrator" :where {"classification" "major"}` | `(facts/narrated :n 5)` |
| Invalidate stale fact | not possible | `(facts/invalidate-about subject :reason r)` |
| Concurrent writes from threads | broken (singleton) | safe (one connection per call) |
| Dependency footprint | chromadb + sentence-transformers (~200 MB) | stdlib `sqlite3` only |
| Query by location | metadata filter (approximate) | indexed `WHERE location = ?` |
| Multiple witnesses to same event | duplicated storage | `fact_witnesses` join table |

---

## Notes on LLM prompt changes

The two templates that will need updating are:

**`character develop-json`** — add `new_memory` as a structured field:

```
"new_memory": {
  "subject": "<entity the memory is about>",
  "predicate": "<relationship: knows | has | is-at | wants | ...>",
  "object": "<optional target or description>",
  "classification": "observation | significant | major | rumour"
}
```

**`plot point`** — change from `[classification] text` to JSON:

```
{"subject": "...", "predicate": "...", "object": "...", "classification": "major | minor | rumour"}
```

Both changes make extraction robust: `extract-json` already handles JSON parsing
and is used across the codebase. The regex path is eliminated entirely.
