"""Tests for the memory_facts compatibility layer."""

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])

(import tempfile)
(import os)
(import pathlib [Path])
(import sqlite3)

(import chasm_engine.memory_facts *)
(import chasm_engine.facts [get-db init-schema])


;; Test fixtures
;; -----------------------------------------------------------------------------

(defn setup-test-db []
  "Create a temporary database for testing."
  (let [temp-dir (tempfile.mkdtemp)
        db-path (Path temp-dir "test_memory.sqlite")]
    (setv chasm_engine.facts._test_db_path (str db-path))
    temp-dir))

(defn teardown-test-db [temp-dir]
  "Clean up temporary database."
  (when (hasattr chasm_engine.facts "_test_db_path")
    (delattr chasm_engine.facts "_test_db_path"))
  (import shutil)
  (shutil.rmtree temp-dir :ignore-errors True))


(defmacro with-test-db [#* body]
  "Execute body with a temporary test database."
  `(let [temp-dir# (setup-test-db)
         original-get-db# chasm_engine.facts.get-db]
     (try
       (defn test-get-db []
         (let [conn# (sqlite3.connect chasm_engine.facts._test_db_path)]
           (setv conn#.row_factory sqlite3.Row)
           conn#))
       (setv chasm_engine.facts.get-db test-get-db)
       (chasm_engine.facts.init-schema)
       ~@body
       (finally
         (setv chasm_engine.facts.get-db original-get-db#)
         (teardown-test-db temp-dir#)))))


;; Tests
;; -----------------------------------------------------------------------------

(defn test-add-memory []
  "Test adding a memory via compatibility layer."
  (with-test-db
    (add "Arthur" {"classification" "significant" "place" "Earth"} "The Earth was destroyed")

    ;; Query it back
    (let [result (query "Arthur" "Earth destroyed" :n 5)]
      (assert (in "documents" result))
      (assert (> (len (:documents result)) 0))
      (assert (in "Earth was destroyed" (first (:documents result)))))))

(defn test-query-with-classification []
  "Test querying with classification filter."
  (with-test-db
    ;; Add memories with different classifications
    (add "Arthur" {"classification" "significant"} "Important event")
    (add "Arthur" {"classification" "trivial"} "Minor detail")

    ;; Query only significant
    (let [result (query "Arthur" "event" :n 5 :where {"classification" "significant"})]
      (assert (= (len (:documents result)) 1))
      (assert (in "Important" (first (:documents result)))))))

(defn test-recent-memories []
  "Test retrieving recent memories."
  (with-test-db
    ;; Add some memories
    (add "Arthur" {} "First memory")
    (add "Arthur" {} "Second memory")
    (add "Arthur" {} "Third memory")

    ;; Get recent
    (let [result (recent "Arthur" :n 2)]
      (assert (= (len (:documents result)) 2))
      ;; Should be most recent first
      (assert (in "Third" (first (:documents result)))))))

(defn test-recent-with-classification []
  "Test recent with classification filter."
  (with-test-db
    (add "Arthur" {"classification" "significant"} "Significant memory")
    (add "Arthur" {"classification" "trivial"} "Trivial memory")

    (let [result (recent "Arthur" :n 5 :where {"classification" "significant"})]
      (assert (= (len (:documents result)) 1))
      (assert (in "Significant" (first (:documents result)))))))

(defn test-compatibility-stubs []
  "Test compatibility stub functions."
  (assert (= (peek "Arthur") {}))
  (assert (is (collection "Arthur") None)))

(defn test-share-knowledge []
  "Test sharing knowledge between characters."
  (with-test-db
    ;; Arthur has some significant memories
    (add "Arthur" {"classification" "significant"} "Secret knowledge")
    (add "Arthur" {"classification" "significant"} "Another secret")
    (add "Arthur" {"classification" "trivial"} "Not important")

    ;; Share with Ford
    (let [shared (share-knowledge "Arthur" "Ford" :n 3)]
      (assert (= shared 2))

      ;; Ford should now have these as hearsay
      (let [ford-knowledge (query "Ford" "secret" :n 5)]
        (assert (> (len (:documents ford-knowledge)) 0))))))

(defn test-knowledge-about []
  "Test knowledge-about function."
  (with-test-db
    (add "Arthur" {"classification" "significant"} "The Vogon ships are yellow")
    (add "Arthur" {"classification" "significant"} "Vogons write bad poetry")

    (let [knowledge (knowledge-about "Arthur" "Vogon" :n 5)]
      (assert (in "Arthur knows:" knowledge))
      (assert (in "Vogon" knowledge)))))

(defn test-narrator-source []
  "Test that narrator source gets correct source-type."
  (with-test-db
    (add "narrator" {"classification" "world"} "The world is round")

    ;; Query should find it
    (let [result (query "narrator" "world" :n 5)]
      (assert (> (len (:documents result)) 0)))))
