"""Tests for the memory_facts compatibility layer."""

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])

(import pytest)
(import tempfile)
(import os)
(import pathlib [Path])
(import sqlite3)

(import toolz [first second])

(import chasm_engine.memory_facts *)
(import chasm_engine.facts [get-db init-schema])


;; Tests
;; -----------------------------------------------------------------------------

(defn test-add-memory [facts_db]
  "Test adding a memory via compatibility layer."
  (add "Arthur" {"classification" "significant" "place" "Earth"} "The Earth was destroyed")

  ;; Query it back
  (let [result (query "Arthur" "Earth destroyed" :n 5)]
    (assert (in "documents" result))
    (assert (> (len (:documents result)) 0))
    (assert (in "Earth was destroyed" (first (:documents result))))))

(defn test-query-with-classification [facts_db]
  "Test querying with classification filter."
  ;; Add memories with different classifications
  (add "Arthur" {"classification" "significant"} "Important event")
  (add "Arthur" {"classification" "trivial"} "Minor detail")

  ;; Query only significant
  (let [result (query "Arthur" "event" :n 5 :where {"classification" "significant"})]
    (assert (= (len (:documents result)) 1))
    (assert (in "Important" (first (:documents result))))))

(defn test-recent-memories [facts_db]
  "Test retrieving recent memories."
  ;; Add some memories
  (add "Arthur" {} "First memory")
  (add "Arthur" {} "Second memory")
  (add "Arthur" {} "Third memory")

  ;; Get recent
  (let [result (recent "Arthur" :n 2)]
    (assert (= (len (:documents result)) 2))
    ;; Should be most recent first
    (assert (in "Third" (first (:documents result))))))

(defn test-recent-with-classification [facts_db]
  "Test recent with classification filter."
  (add "Arthur" {"classification" "significant"} "Significant memory")
  (add "Arthur" {"classification" "trivial"} "Trivial memory")

  (let [result (recent "Arthur" :n 5 :where {"classification" "significant"})]
    (assert (= (len (:documents result)) 1))
    (assert (in "Significant" (first (:documents result))))))

(defn test-compatibility-stubs []
  "Test compatibility stub functions."
  (assert (= (peek "Arthur") {}))
  (assert (is (collection "Arthur") None)))

(defn test-share-knowledge [facts_db]
  "Test sharing knowledge between characters."
  ;; Arthur has some significant memories
  (add "Arthur" {"classification" "significant"} "Secret knowledge")
  (add "Arthur" {"classification" "significant"} "Another secret")
  (add "Arthur" {"classification" "trivial"} "Not important")

  ;; Share with Ford
  (let [shared (share-knowledge "Arthur" "Ford" :n 3)]
    (assert (= shared 2))

    ;; Ford should now have these as hearsay
    (let [ford-knowledge (query "Ford" "secret" :n 5)]
      (assert (> (len (:documents ford-knowledge)) 0)))))

(defn test-knowledge-about [facts_db]
  "Test knowledge-about function."
  (add "Arthur" {"classification" "significant"} "The Vogon ships are yellow")
  (add "Arthur" {"classification" "significant"} "Vogons write bad poetry")

  (let [knowledge (knowledge-about "Arthur" "Vogon" :n 5)]
    (assert (in "Arthur knows:" knowledge))
    (assert (in "Vogon" knowledge))))

(defn test-narrator-source [facts_db]
  "Test that narrator source gets correct source-type."
  (add "narrator" {"classification" "world"} "The world is round")

  ;; Query should find it
  (let [result (query "narrator" "world" :n 5)]
    (assert (> (len (:documents result)) 0))))
