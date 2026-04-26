"""Tests for the quest module."""

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])

(import pytest)
(import tempfile)
(import os)
(import pathlib [Path])

(import toolz [first second])

(import chasm_engine.quest *)
(import chasm_engine.state [path])


;; Tests
;; -----------------------------------------------------------------------------

(defn test-get-quest [sample_quests]
  "Test retrieving quest definitions."
  (let [q (get-quest "test-quest")]
    (assert (isinstance q dict))
    (assert (= (:id q) "test-quest"))
    (assert (= (:name q) "Test Quest"))
    (assert (= (len (:stages q)) 2))))

(defn test-get-quest-missing [sample_quests]
  "Test retrieving non-existent quest."
  (let [q (get-quest "nonexistent")]
    (assert (is q None))))

(defn test-all-quests [sample_quests]
  "Test listing all quests."
  (let [quests (all-quests)]
    (assert (= (len quests) 2))))

(defn test-eligible [sample_quests quest_defs_reset]
  "Test quest eligibility."
  ;; Arthur should be eligible for test-quest (no prereqs)
  (assert (eligible? "Arthur" "test-quest"))

  ;; Arthur should NOT be eligible for chain-quest (needs test-quest first)
  (assert (not (eligible? "Arthur" "chain-quest"))))

(defn test-start-quest [sample_quests quest_defs_reset]
  "Test starting a quest."
  (let [progress (start-quest "Arthur" "test-quest")]
    (assert (isinstance progress dict))
    (assert (= (:character_name progress) "Arthur"))
    (assert (= (:quest_id progress) "test-quest"))
    (assert (= (:stage_index progress) 0))
    (assert (isinstance (:started_at progress) float)))

  ;; Should not be eligible anymore (already started)
  (assert (not (eligible? "Arthur" "test-quest"))))

(defn test-active-quests [sample_quests quest_defs_reset]
  "Test retrieving active quests."
  ;; No active quests initially
  (assert (= (len (active-quests "Arthur")) 0))

  ;; Start a quest
  (start-quest "Arthur" "test-quest")

  ;; Should have one active quest
  (let [active (active-quests "Arthur")]
    (assert (= (len active) 1))
    (assert (= (:quest_id (first active)) "test-quest"))))

(defn test-completed-quest-ids [sample_quests quest_defs_reset]
  "Test tracking completed quests."
  ;; Manually mark quest as completed
  (set-progress "Arthur" "test-quest"
                :stage_index 2
                :completed_at 1234567890.0)

  (let [completed (completed-quest-ids "Arthur")]
    (assert (in "test-quest" completed))
    (assert (= (len completed) 1)))

  ;; Now should be eligible for chain-quest
  (assert (eligible? "Arthur" "chain-quest")))

(defn test-prerequisites-met [sample_quests quest_defs_reset]
  "Test prerequisite checking."
  (let [chain-q (get-quest "chain-quest")]
    ;; Prerequisites not met initially
    (assert (not (prerequisites-met? "Arthur" chain-q)))

    ;; Complete the prerequisite
    (set-progress "Arthur" "test-quest" :completed_at 1234567890.0)

    ;; Now prerequisites should be met
    (assert (prerequisites-met? "Arthur" chain-q))))

(defn test-abandon-quest [sample_quests quest_defs_reset]
  "Test abandoning a quest."
  (start-quest "Arthur" "test-quest")
  (assert (= (len (active-quests "Arthur")) 1))

  ;; Abandon it
  (abandon-quest "Arthur" "test-quest" "got bored")

  ;; Should no longer be active
  (assert (= (len (active-quests "Arthur")) 0))

  ;; Progress should show failed_at
  (let [progress (get-progress "Arthur" "test-quest")]
    (assert (isinstance (:failed_at progress) float))))

(defn test-quest-context [sample_quests quest_defs_reset]
  "Test generating quest context for narrator."
  ;; No active quests = empty context
  (assert (= (quest-context "Arthur") ""))

  ;; Start a quest
  (start-quest "Arthur" "test-quest")

  ;; Should have context
  (let [ctx (quest-context "Arthur")]
    (assert (in "Active quests:" ctx))
    (assert (in "Test Quest" ctx))
    (assert (in "Find the golden key" ctx))))

(defn test-available-for [sample_quests quest_defs_reset]
  "Test finding available quests for character."
  ;; Should have test-quest available
  (let [available (available-for "Arthur")]
    (assert (= (len available) 1))
    (assert (= (:id (first available)) "test-quest")))

  ;; Complete it
  (set-progress "Arthur" "test-quest" :completed_at 1234567890.0)

  ;; Now chain-quest should be available
  (let [available (available-for "Arthur")]
    (assert (= (len available) 1))
    (assert (= (:id (first available)) "chain-quest"))))
