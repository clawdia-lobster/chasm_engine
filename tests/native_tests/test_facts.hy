"""Tests for the facts module."""

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])

(import tempfile)
(import os)
(import pathlib [Path])
(import sqlite3)

(import chasm_engine.facts *)


;; Test fixtures
;; -----------------------------------------------------------------------------

(defn setup-test-db []
  "Create a temporary database for testing."
  (let [temp-dir (tempfile.mkdtemp)
        db-path (Path temp-dir "test_facts.sqlite")]
    ;; Monkey-patch the get-db function to use test db
    (setv chasm_engine.facts._test_db_path (str db-path))
    temp-dir))

(defn teardown-test-db [temp-dir]
  "Clean up temporary database."
  (when (hasattr chasm_engine.facts "_test_db_path")
    (delattr chasm_engine.facts "_test_db_path"))
  ;; Remove temp directory
  (import shutil)
  (shutil.rmtree temp-dir :ignore-errors True))


;; Monkey-patch get-db for testing
(defmacro with-test-db [#* body]
  "Execute body with a temporary test database."
  `(let [temp-dir# (setup-test-db)
         original-get-db# chasm_engine.facts.get-db]
     (try
       ;; Replace get-db to use test path
       (defn test-get-db []
         (let [conn# (sqlite3.connect chasm_engine.facts._test_db_path)]
           (setv conn#.row_factory sqlite3.Row)
           conn#))
       (setv chasm_engine.facts.get-db test-get-db)
       ;; Re-initialise schema
       (chasm_engine.facts.init-schema)
       ~@body
       (finally
         (setv chasm_engine.facts.get-db original-get-db#)
         (teardown-test-db temp-dir#)))))


;; Tests
;; -----------------------------------------------------------------------------

(defn test-add-fact []
  "Test adding a basic fact."
  (with-test-db
    (let [fact-id (add-fact "Arthur" "has" "towel"
                           :source "Arthur"
                           :source-type "character"
                           :location "Earth")]
      (assert (isinstance fact-id int))
      (assert (> fact-id 0))
      ;; Retrieve and verify
      (let [fact (get-fact fact-id)]
        (assert (= (:subject fact) "Arthur"))
        (assert (= (:predicate fact) "has"))
        (assert (= (:object fact) "towel"))
        (assert (= (:source fact) "Arthur"))
        (assert (= (:location fact) "Earth"))))))

(defn test-query-facts []
  "Test querying facts with filters."
  (with-test-db
    ;; Add some facts
    (add-fact "Arthur" "has" "towel" :source "Arthur")
    (add-fact "Arthur" "is" "hungry" :source "Arthur")
    (add-fact "Ford" "has" "guide" :source "Ford")
    
    ;; Query by subject
    (let [arthur-facts (query-facts :subject "Arthur")]
      (assert (= (len arthur-facts) 2)))
    
    ;; Query by predicate
    (let [has-facts (query-facts :predicate "has")]
      (assert (= (len has-facts) 2)))
    
    ;; Query by source
    (let [ford-facts (query-facts :source "Ford")]
      (assert (= (len ford-facts) 1))
      (assert (= (:subject (first ford-facts)) "Ford")))))

(defn test-invalidate-fact []
  "Test invalidating a fact."
  (with-test-db
    (let [fact-id (add-fact "Arthur" "has" "towel" :source "Arthur")]
      ;; Invalidate it
      (assert (invalidate-fact fact-id "lost it"))
      ;; Query should exclude by default
      (let [valid-facts (query-facts :subject "Arthur" :only-valid True)]
        (assert (= (len valid-facts) 0)))
      ;; Query with only-valid False should include it
      (let [all-facts (query-facts :subject "Arthur" :only-valid False)]
        (assert (= (len all-facts) 1))
        (assert (= (:invalidated_reason (first all-facts)) "lost it"))))))

(defn test-fact-tags []
  "Test adding and retrieving tags."
  (with-test-db
    (let [fact-id (add-fact "Arthur" "has" "towel" :source "Arthur" :tags ["inventory" "important"])]
      ;; Get tags
      (let [tags (get-tags fact-id)]
        (assert (= (len tags) 2))
        (assert (in "inventory" tags))
        (assert (in "important" tags)))
      ;; Query by tag
      (let [tagged-facts (facts-with-tag "inventory")]
        (assert (= (len tagged-facts) 1))))))

(defn test-what-does-know []
  "Test the what-does-know convenience function."
  (with-test-db
    (add-fact "Arthur" "knows" "Earth is doomed" :source "Arthur" :subject "Earth")
    (add-fact "Arthur" "saw" "Vogon ships" :source "Arthur" :subject "Vogons")
    
    (let [knowledge (what-does-know "Arthur" "Earth")]
      (assert (= (len knowledge) 1))
      (assert (= (:predicate (first knowledge)) "knows")))))

(defn test-recent-facts []
  "Test retrieving recent facts."
  (with-test-db
    ;; Add facts with slight delay
    (add-fact "Arthur" "first" "fact" :source "Arthur")
    (add-fact "Arthur" "second" "fact" :source "Arthur")
    (add-fact "Arthur" "third" "fact" :source "Arthur")
    
    (let [recent (recent-facts :n 2)]
      (assert (= (len recent) 2))
      ;; Should be in reverse chronological order
      (assert (= (:predicate (first recent)) "third")))))

(defn test-format-fact []
  "Test fact formatting functions."
  (let [fact {"subject" "Arthur" "predicate" "has" "object" "towel" "source" "narrator"}
        formatted (format-fact fact)]
    (assert (in "Arthur" formatted))
    (assert (in "has" formatted))
    (assert (in "towel" formatted))
    
    (let [narrative (format-fact-for-narrative fact)]
      (assert (in "Arthur" narrative))
      (assert (in "has" narrative)))))
