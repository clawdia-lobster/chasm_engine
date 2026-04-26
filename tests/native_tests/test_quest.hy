"""Tests for the quest module."""

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])

(import tempfile)
(import os)
(import pathlib [Path])

(import chasm_engine.quest *)
(import chasm_engine.state [path])


;; Test fixtures
;; -----------------------------------------------------------------------------

(defn setup-test-quests []
  "Set up test quest definitions."
  ;; Create mock quest definitions
  (setv test-quests
    {"test-quest"
     {"id" "test-quest"
      "name" "Test Quest"
      "description" "A quest for testing"
      "stages" [{"id" "stage1" "condition" "find the key" "description" "Find the golden key" "optional" False}
                {"id" "stage2" "condition" "open the door" "description" "Open the mysterious door" "optional" False}]
      "prerequisites" []
      "rewards" {"score" 10 "items" ["potion"] "unlocks" []}}

     "chain-quest"
     {"id" "chain-quest"
      "name" "Chain Quest"
      "description" "Requires test-quest first"
      "stages" [{"id" "stage1" "condition" "talk to wizard" "description" "Talk to the wizard"}]
      "prerequisites" ["test-quest"]
      "rewards" {"score" 20}}})

  ;; Populate quest-defs table
  (for [[qid q] (.items test-quests)]
    (setv (get quest-defs qid) q)))


(defn reset-quest-progress []
  "Clear all quest progress."
  (.clear quest-prog))


;; Tests
;; -----------------------------------------------------------------------------

(defn test-get-quest []
  "Test retrieving quest definitions."
  (setup-test-quests)
  (let [q (get-quest "test-quest")]
    (assert (is q dict))
    (assert (= (:id q) "test-quest"))
    (assert (= (:name q) "Test Quest"))
    (assert (= (len (:stages q)) 2))))

(defn test-get-quest-missing []
  "Test retrieving non-existent quest."
  (setup-test-quests)
  (let [q (get-quest "nonexistent")]
    (assert (is q None))))

(defn test-all-quests []
  "Test listing all quests."
  (setup-test-quests)
  (let [quests (all-quests)]
    (assert (= (len quests) 2))))

(defn test-eligible []
  "Test quest eligibility."
  (setup-test-quests)
  (reset-quest-progress)

  ;; Arthur should be eligible for test-quest (no prereqs)
  (assert (eligible? "Arthur" "test-quest"))

  ;; Arthur should NOT be eligible for chain-quest (needs test-quest first)
  (assert (not (eligible? "Arthur" "chain-quest"))))

(defn test-start-quest []
  "Test starting a quest."
  (setup-test-quests)
  (reset-quest-progress)

  (let [progress (start-quest "Arthur" "test-quest")]
    (assert (is progress dict))
    (assert (= (:character_name progress) "Arthur"))
    (assert (= (:quest_id progress) "test-quest"))
    (assert (= (:stage_index progress) 0))
    (assert (is (:started_at progress) float)))

  ;; Should not be eligible anymore (already started)
  (assert (not (eligible? "Arthur" "test-quest"))))

(defn test-active-quests []
  "Test retrieving active quests."
  (setup-test-quests)
  (reset-quest-progress)

  ;; No active quests initially
  (assert (= (len (active-quests "Arthur")) 0))

  ;; Start a quest
  (start-quest "Arthur" "test-quest")

  ;; Should have one active quest
  (let [active (active-quests "Arthur")]
    (assert (= (len active) 1))
    (assert (= (:quest_id (first active)) "test-quest"))))

(defn test-completed-quest-ids []
  "Test tracking completed quests."
  (setup-test-quests)
  (reset-quest-progress)

  ;; Manually mark quest as completed
  (set-progress "Arthur" "test-quest"
                :stage_index 2
                :completed_at 1234567890.0)

  (let [completed (completed-quest-ids "Arthur")]
    (assert (in "test-quest" completed))
    (assert (= (len completed) 1)))

  ;; Now should be eligible for chain-quest
  (assert (eligible? "Arthur" "chain-quest")))

(defn test-prerequisites-met []
  "Test prerequisite checking."
  (setup-test-quests)
  (reset-quest-progress)

  (let [chain-q (get-quest "chain-quest")]
    ;; Prerequisites not met initially
    (assert (not (prerequisites-met? "Arthur" chain-q)))

    ;; Complete the prerequisite
    (set-progress "Arthur" "test-quest" :completed_at 1234567890.0)

    ;; Now prerequisites should be met
    (assert (prerequisites-met? "Arthur" chain-q))))

(defn test-abandon-quest []
  "Test abandoning a quest."
  (setup-test-quests)
  (reset-quest-progress)

  (start-quest "Arthur" "test-quest")
  (assert (= (len (active-quests "Arthur")) 1))

  ;; Abandon it
  (abandon-quest "Arthur" "test-quest" "got bored")

  ;; Should no longer be active
  (assert (= (len (active-quests "Arthur")) 0))

  ;; Progress should show failed_at
  (let [progress (get-progress "Arthur" "test-quest")]
    (assert (is (:failed_at progress) float))))

(defn test-quest-context []
  "Test generating quest context for narrator."
  (setup-test-quests)
  (reset-quest-progress)

  ;; No active quests = empty context
  (assert (= (quest-context "Arthur") ""))

  ;; Start a quest
  (start-quest "Arthur" "test-quest")

  ;; Should have context
  (let [ctx (quest-context "Arthur")]
    (assert (in "Active quests:" ctx))
    (assert (in "Test Quest" ctx))
    (assert (in "Find the golden key" ctx))))

(defn test-available-for []
  "Test finding available quests for character."
  (setup-test-quests)
  (reset-quest-progress)

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
