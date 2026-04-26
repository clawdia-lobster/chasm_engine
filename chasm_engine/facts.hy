"""
Structured fact storage using SQLite with pugsql.
Replaces the fragile ChromaDB-based memory system.
"""

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])

(import json)
(import time [time])
(import sqlite3 [OperationalError connect Row])
(import pathlib [Path])

(import pugsql)

(import chasm_engine [log])
(import chasm_engine.lib [config])
(import chasm_engine.state [path])


;; * PugSQL Setup
;; -----------------------------------------------------------------------------

;; Get the SQL file path - use absolute path based on module location
(import os)
(import importlib.util)
(setv _facts-queries None)
(setv _sql-path None)

(defn get-sql-path []
  "Get the SQL file path lazily."
  (global _sql-path)
  (when (is _sql-path None)
    ;; Try multiple approaches to find the module location
    (import sys [modules])
    (import importlib.util)
    (setv module-file None)
    
    ;; Approach 1: Use __file__ from module
    (setv this-module (.get modules "chasm_engine.facts"))
    (when this-module
      (setv module-file (getattr this-module "__file__" None)))
    
    ;; Approach 2: Use find_spec
    (when (is module-file None)
      (setv spec (importlib.util.find-spec "chasm_engine.facts"))
      (when spec
        (setv module-file spec.origin)))
    
    ;; Approach 3: Use chasm_engine package location
    (when (is module-file None)
      (setv engine-spec (importlib.util.find-spec "chasm_engine"))
      (when engine-spec
        (setv engine-path (getattr (Path engine-spec.origin) "parent"))
        (setv module-file (str (.joinpath engine-path "facts.hy")))))
    
    ;; Final fallback: assume relative to cwd
    (when (is module-file None)
      (setv module-file (str (Path (os.getcwd) "chasm_engine" "facts.hy"))))
    
    (setv sql-dir (getattr (Path module-file) "parent"))
    (setv _sql-path (str (.joinpath sql-dir "sql" "facts.sql"))))
  _sql-path)

(defn get-facts-queries []
  "Get or initialise the pugsql queries module."
  (global _facts-queries)
  (when (is _facts-queries None)
    (setv _facts-queries (.module pugsql (get-sql-path))))
  _facts-queries)


;; * Database Connection
;; -----------------------------------------------------------------------------

(defn get-db-path []
  "Get the path to the facts database."
  f"{path}/facts.sqlite")


(defn get-db []
  "Get a connection to the facts database."
  (let [db-path (get-db-path)
        conn (connect db-path)]
    ;; Return rows as dict-like objects
    (setv conn.row_factory Row)
    conn))


(defn init-connection []
  "Initialise the pugsql connection."
  (.connect (get-facts-queries) (get-db-path)))


;; * Schema Initialisation
;; -----------------------------------------------------------------------------

(defn init-schema []
  "Initialise the facts schema. Called on module load."
  (try
    ;; Initialise pugsql connection
    (init-connection)
    
    ;; Create tables and indexes
    (let [fq (get-facts-queries)]
      (fq.create_table_facts)
      (fq.create_index_facts_subject)
      (fq.create_index_facts_source)
      (fq.create_index_facts_location)
      (fq.create_index_facts_timestamp)
      (fq.create_index_facts_source-subject)
      (fq.create_index_facts_subject-predicate)
      (fq.create_table_fact_tags)
      (fq.create_index_fact_tags_tag)
      (fq.create_table_fact_provenance)
      (fq.create_fts_table)
      (fq.create_trigger_facts_ai)
      (fq.create_trigger_facts_ad)
      (fq.create_trigger_facts_au)
      (fq.create_view_valid_facts)
      (fq.create_view_character_knowledge)
      (fq.create_view_world_facts))
    
    (log.info "Facts schema initialised")
    (except [e Exception]
      (log.error f"Failed to initialise facts schema: {e}"))))


;; * Helpers
;; -----------------------------------------------------------------------------

(defn row->dict [row]
  "Convert a sqlite row to a dict."
  (when row
    (let [keys (row.keys)]
      (dict (zip keys row)))))


(defn rows->dicts [rows]
  "Convert sqlite rows to a list of dicts."
  (lfor row rows (row->dict row)))


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
  "Add a new fact. Returns fact ID or None on failure."
  (let [now (time)
        expires (when expires-after (+ now expires-after))
        coords-json (when coords (json.dumps coords))]
    (try
      ;; Insert the fact
      (let [fq (get-facts-queries)
            result (fq.insert_fact
                     :subject subject
                     :predicate predicate
                     :object object
                     :location location
                     :coords coords-json
                     :timestamp now
                     :source source
                     :source_type source-type
                     :fact_type fact-type
                     :confidence confidence
                     :expires_at expires)
            fact-id (:id (first result))]
        ;; Add tags
        (when tags
          (for [tag tags]
            (fq.insert_fact-tag :fact_id fact-id :tag tag)))
        ;; Add provenance
        (when origin-data
          (fq.insert_fact-provenance
            :fact_id fact-id
            :origin_type origin-type
            :origin_id origin-id
            :origin_data origin-data))
        fact-id)
      (except [e Exception]
        (log.error f"Failed to add fact: {e}")
        None))))


(defn get-fact [fact-id]
  "Retrieve a single fact by ID. Returns dict or None."
  (try
    (let [fq (get-facts-queries)
          result (fq.get_fact_by_id :id fact-id)]
      (row->dict (first result)))
    (except [e Exception]
      (log.error f"Failed to get fact: {e}")
      None)))


(defn invalidate-fact [fact-id reason]
  "Mark a fact as invalidated. Returns True on success."
  (try
    (let [fq (get-facts-queries)]
      (fq.invalidate_fact_by_id
        :invalidated_at (time)
        :invalidated_reason reason
        :id fact-id))
    True
    (except [e Exception]
      (log.error f"Failed to invalidate fact: {e}")
      False)))


(defn invalidate-by-query [subject predicate object source]
  "Invalidate all facts matching the given criteria."
  (try
    (let [fq (get-facts-queries)]
      (fq.invalidate_facts_by_query
        :invalidated_at (time)
        :subject subject
        :predicate predicate
        :object object
        :source source))
    (except [e Exception]
      (log.error f"Failed to invalidate facts: {e}")
      0)))


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
  "Query facts with flexible filtering. Returns list of dicts."
  (try
    (let [fq (get-facts-queries)
          results (fq.query_facts
                    :subject subject
                    :predicate predicate
                    :object object
                    :source source
                    :location location
                    :fact_type fact-type
                    :source_type source-type
                    :only_valid (if only-valid 1 0)
                    :limit limit
                    :offset offset)]
      (rows->dicts results))
    (except [e Exception]
      (log.error f"Failed to query facts: {e}")
      [])))


(defn what-does-know [character-name about-subject]
  "Convenience: what does X know about Y?"
  (query-facts :source character-name :subject about-subject))


(defn facts-at-location [location-name]
  "Convenience: facts about a location."
  (query-facts :location location-name))


(defn recent-facts [[n 10]]
  "Get the most recent facts."
  (try
    (let [fq (get-facts-queries)
          results (fq.get_recent_facts :n n)]
      (rows->dicts results))
    (except [e Exception]
      (log.error f"Failed to get recent facts: {e}")
      [])))


(defn search-facts [query [n 20] [source None]]
  "Full-text search across facts. Returns list of dicts."
  (try
    (let [fq (get-facts-queries)
          results (fq.search_facts_fts
                    :query query
                    :source source
                    :n n)]
      (rows->dicts results))
    (except [e Exception]
      (log.error f"Failed to search facts: {e}")
      [])))


;; * Convenience Functions
;;;; -----------------------------------------------------------------------------

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
  (try
    (let [fq (get-facts-queries)]
      (fq.insert_fact-tag :fact_id fact-id :tag tag))
    True
    (except [e Exception]
      (log.error f"Failed to add tag: {e}")
      False)))


(defn get-tags [fact-id]
  "Get all tags for a fact."
  (try
    (let [fq (get-facts-queries)
          results (fq.get_tags_for_fact :fact_id fact-id)]
      (lfor row results (:tag row)))
    (except [e Exception]
      (log.error f"Failed to get tags: {e}")
      [])))


(defn facts-with-tag [tag]
  "Get all facts with a specific tag."
  (try
    (let [fq (get-facts-queries)
          results (fq.get_facts_with_tag :tag tag)]
      (rows->dicts results))
    (except [e Exception]
      (log.error f"Failed to get facts with tag: {e}")
      [])))


;; * Initialisation
;; -----------------------------------------------------------------------------

;; Initialise schema on module load
(init-schema)
