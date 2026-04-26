"""Tests for the facts module."""

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])

(import pytest)
(import tempfile)
(import os)
(import pathlib [Path])
(import sqlite3)

(import toolz [first second])

(import chasm_engine.facts *)


;; Tests
;; -----------------------------------------------------------------------------

(defn test-add-fact [facts_db]
  "Test adding a basic fact."
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
      (assert (= (:location fact) "Earth")))))

(defn test-query-facts [facts_db]
  "Test querying facts with filters."
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
    (assert (= (:subject (first ford-facts)) "Ford"))))

(defn test-invalidate-fact [facts_db]
  "Test invalidating a fact."
  (let [fact-id (add-fact "Arthur" "has" "towel" :source "Arthur")]
    ;; Invalidate it
    (assert (invalidate-fact fact-id "lost it"))
    ;; Query should exclude by default
    (let [valid-facts (query-facts :subject "Arthur" :only-valid True)]
      (assert (= (len valid-facts) 0)))
    ;; Query with only-valid False should include it
    (let [all-facts (query-facts :subject "Arthur" :only-valid False)]
      (assert (= (len all-facts) 1))
      (assert (= (:invalidated_reason (first all-facts)) "lost it")))))

(defn test-fact-tags [facts_db]
  "Test adding and retrieving tags."
  (let [fact-id (add-fact "Arthur" "has" "towel" :source "Arthur" :tags ["inventory" "important"])]
    ;; Get tags
    (let [tags (get-tags fact-id)]
      (assert (= (len tags) 2))
      (assert (in "inventory" tags))
      (assert (in "important" tags)))
    ;; Query by tag
    (let [tagged-facts (facts-with-tag "inventory")]
      (assert (= (len tagged-facts) 1)))))

(defn test-what-does-know [facts_db]
  "Test the what-does-know convenience function."
  ;; what-does-know queries by source (who knows) and subject (what they know about)
  (add-fact "Earth" "is" "doomed" :source "Arthur")
  (add-fact "Vogons" "have" "ships" :source "Arthur")
  
  (let [knowledge (what-does-know "Arthur" "Earth")]
    (assert (= (len knowledge) 1))
    (assert (= (:predicate (first knowledge)) "is"))))

(defn test-recent-facts [facts_db]
  "Test retrieving recent facts."
  ;; Add facts with slight delay
  (add-fact "Arthur" "first" "fact" :source "Arthur")
  (add-fact "Arthur" "second" "fact" :source "Arthur")
  (add-fact "Arthur" "third" "fact" :source "Arthur")
  
  (let [recent (recent-facts :n 2)]
    (assert (= (len recent) 2))
    ;; Should be in reverse chronological order
    (assert (= (:predicate (first recent)) "third"))))

(defn test-format-fact []
  "Test fact formatting functions."
  (let [fact {"subject" "Arthur" "predicate" "has" "object" "towel" "source" "narrator" "location" "Earth"}
        formatted (format-fact fact)]
    (assert (in "Arthur" formatted))
    (assert (in "has" formatted))
    (assert (in "towel" formatted))
    
    (let [narrative (format-fact-for-narrative fact)]
      (assert (in "Arthur" narrative))
      (assert (in "has" narrative)))))
