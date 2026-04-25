"
Quest system for chasm-engine.

Quests are narrative scaffolding: goals with LLM-evaluated conditions.
Definitions live in world/quests/*.toml.
Progress is tracked per character in SQLite.

Design: docs/QUEST_SYSTEM.md
"

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])

(import glob)
(import json)
(import time [time])
(import pathlib [Path])

(import chasm_engine [log])
(import chasm_engine.lib [config extract-json-unwrap format-msgs])
(import chasm_engine.state [path world get-table character-key])
(import chasm_engine.chat [respond truncate system user])


;; * Tables
;; -----------------------------------------------------------------------------

(setv quest-defs   (get-table "quests"   :db "quests"))
(setv quest-prog   (get-table "progress" :db "quests"))


;; * TOML Loading
;; -----------------------------------------------------------------------------

(defn load-quest-file [fpath]
  "Parse a quest TOML file into a dict. Returns None on error."
  (import tomllib)
  (try
    (let [raw (tomllib.loads (.read_text (Path fpath)))
          q   (.get raw "quest" {})]
      ;; normalise stages: ensure optional defaults to False
      (setv (get q "stages")
            (lfor s (.get q "stages" [])
                  (| {"optional" False "hint" None} s)))
      (setv (get q "rewards")
            (| {"score" 0 "items" [] "unlocks" []} (.get q "rewards" {})))
      (setv (get q "prerequisites")
            (.get (.get q "prerequisites" {}) "requires" []))
      q)
    (except [e [Exception]]
      (log.error f"quest/load-quest-file: {fpath}" :exception e)
      None)))


(defn load-world-quests []
  "Load all quest TOML files from world/quests/ into quest-defs table."
  (let [quest-dir (Path f"{path}/quests")]
    (unless quest-dir.exists
      (quest-dir.mkdir :parents True :exist-ok True))
    (let [files (list (quest-dir.glob "*.toml"))
          loaded 0]
      (for [f files]
        (let [q (load-quest-file (str f))]
          (when (and q (:id q None))
            (setv (get quest-defs (:id q)) q)
            (setv loaded (+ loaded 1)))))
      (log.info f"Loaded {loaded} quests from {quest-dir}")
      loaded)))


(defn get-quest [quest-id]
  "Get a quest definition by id."
  (try
    (get quest-defs quest-id)
    (except [KeyError] None)))


(defn all-quests []
  "List all quest definitions."
  (list (.values quest-defs)))


;; * Progress Management
;; -----------------------------------------------------------------------------

(defn progress-key [char-name quest-id]
  (+ (character-key char-name) ":" quest-id))


(defn get-progress [char-name quest-id]
  "Get quest progress for a character."
  (try
    (get quest-prog (progress-key char-name quest-id))
    (except [KeyError] None)))


(defn set-progress [char-name quest-id #** kwargs]
  "Create or update progress for a character/quest pair."
  (let [key    (progress-key char-name quest-id)
        now    (time)
        existing (or (get-progress char-name quest-id)
                     {"character_name" char-name
                      "quest_id"       quest-id
                      "stage_index"    0
                      "stage_history"  []
                      "started_at"     now
                      "completed_at"   None
                      "failed_at"      None})]
    (setv (get quest-prog key) (| existing kwargs))
    (get quest-prog key)))


(defn active-quests [char-name]
  "Return list of in-progress quest dicts for a character."
  (lfor [k v] (.items quest-prog)
        :if (and (.startswith k (character-key char-name))
                 (is None (:completed_at v None))
                 (is None (:failed_at v None)))
        v))


(defn completed-quest-ids [char-name]
  "Return set of quest ids the character has completed."
  (set (lfor [k v] (.items quest-prog)
             :if (and (.startswith k (character-key char-name))
                      (:completed_at v None))
             (:quest_id v))))


;; * Prerequisite & Eligibility
;; -----------------------------------------------------------------------------

(defn prerequisites-met? [char-name quest]
  "True if the character has completed all prerequisites."
  (let [reqs (set (:prerequisites quest []))
        done (completed-quest-ids char-name)]
    (reqs.issubset done)))


(defn eligible? [char-name quest-id]
  "True if character can start this quest (not started, prereqs met)."
  (let [q (get-quest quest-id)]
    (and q
         (prerequisites-met? char-name q)
         (is None (get-progress char-name quest-id)))))


;; * Starting & Abandoning
;; -----------------------------------------------------------------------------

(defn start-quest [char-name quest-id]
  "Begin a quest for a character. Returns progress dict or None."
  (let [q (get-quest quest-id)]
    (unless q
      (log.warn f"quest/start-quest: unknown quest {quest-id}")
      (return None))
    (unless (eligible? char-name quest-id)
      (log.debug f"quest/start-quest: {char-name} not eligible for {quest-id}")
      (return None))
    (log.info f"{char-name} started quest '{(:name q quest-id)}'")
    (set-progress char-name quest-id)))


(defn abandon-quest [char-name quest-id [reason "abandoned"]]
  "Mark a quest as failed/abandoned."
  (let [p (get-progress char-name quest-id)]
    (when p
      (set-progress char-name quest-id :failed_at (time))
      (log.info f"{char-name} abandoned quest {quest-id}: {reason}"))))


;; * Condition Evaluation (LLM)
;; -----------------------------------------------------------------------------

(setv condition-template
  "You are evaluating whether a quest condition has been met in a text adventure.

Quest: {quest_name}
Current stage: {stage_description}
Condition to check: {condition}

Recent narrative:
{narrative}

Has the condition been met? Reply with exactly one word: YES or NO.")


(defn :async check-stage-condition [quest stage messages player-name]
  "Ask the narrator LLM whether the current stage condition is met.
  Returns True or False."
  (let [msgs (truncate (cut messages -8 None) :spare-length 500)
        narrative (format-msgs msgs)
        prompt (condition-template.format
                  :quest_name    (:name quest "quest")
                  :stage_description (:description stage "")
                  :condition     (:condition stage "")
                  :narrative     narrative)
        response (await (respond [(system "You evaluate quest conditions in a text adventure.")
                                  (user prompt)]
                                 :provider "narrator"))
        verdict (.strip (.upper response))]
    (log.debug f"quest condition '{(:condition stage)}': {verdict}")
    (or (= verdict "YES") (.startswith verdict "YES"))))


;; * Stage Advancement
;; -----------------------------------------------------------------------------

(defn :async try-advance [char-name messages]
  "Check all active quests for stage advancement. Returns list of events.
  
  Call this during engine develop cycle."
  (let [events []
        quests (active-quests char-name)]
    (for [prog quests]
      (let [q   (get-quest (:quest_id prog))
            idx (:stage_index prog 0)]
        (when (and q (< idx (len (:stages q []))))
          (let [stage (get (:stages q []) idx)
                met?  (await (check-stage-condition q stage messages char-name))]
            (when met?
              (let [completion {"stage_id"    (:id stage "")
                                "completed_at" (time)
                                "narrative"   f"Stage {(:id stage)} completed"}
                    history    (+ (:stage_history prog []) [completion])
                    next-idx   (+ idx 1)
                    finished?  (>= next-idx (len (:stages q [])))]
                (log.info f"{char-name}: quest '{(:name q)}' stage {(:id stage)} complete")
                (.append events {"type"     "stage_complete"
                                 "quest"    q
                                 "stage"    stage
                                 "finished" finished?})
                (if finished?
                    (do
                      (set-progress char-name (:quest_id prog)
                                    :stage_index next-idx
                                    :stage_history history
                                    :completed_at (time))
                      (grant-rewards char-name q)
                      (.append events {"type" "quest_complete" "quest" q}))
                    (set-progress char-name (:quest_id prog)
                                  :stage_index next-idx
                                  :stage_history history))))))))
    events))


;; * Rewards
;; -----------------------------------------------------------------------------

(defn grant-rewards [char-name quest]
  "Apply quest rewards to a character."
  (let [rewards (:rewards quest {})]
    ;; Score: update character score via state
    (let [score-delta (:score rewards 0)]
      (when (> score-delta 0)
        (import chasm_engine.state [get-character update-character])
        (let [char (get-character char-name)]
          (when char
            (update-character char :score (+ char.score score-delta))
            (log.info f"{char-name}: +{score-delta} score from quest '{(:name quest)}'")))))
    ;; Items: grant to character inventory (state items table)
    (for [item-name (:items rewards [])]
      (import chasm_engine.state [get-item set-item get-character])
      (let [char (get-character char-name)]
        (when char
          (import chasm_engine.types [Item])
          (let [new-item (Item :name item-name
                               :type "quest_reward"
                               :appearance f"A reward from completing '{(:name quest)}'"
                               :usage ""
                               :owner char-name
                               :coords None)]
            (set-item new-item)
            (log.info f"{char-name}: received item '{item-name}' from quest '{(:name quest)}'")))))
    ;; Unlocks: log them; player can discover via /quests
    (for [unlock-id (:unlocks rewards [])]
      (log.info f"Quest '{(:name quest)}' unlocked: {unlock-id}"))))


;; * Context for Narrator
;; -----------------------------------------------------------------------------

(defn quest-context [char-name]
  "Return a string summarising active quests for the narrator context."
  (let [active (active-quests char-name)]
    (if (not active)
        ""
        (let [lines ["Active quests:"]]
          (for [prog active]
            (let [q     (get-quest (:quest_id prog))
                  idx   (:stage_index prog 0)
                  stage (when (and q (< idx (len (:stages q []))))
                          (get (:stages q []) idx))]
              (when q
                (let [stage-desc (if stage (:description stage) "...")]
                  (.append lines f"  - {(:name q)}: {stage-desc}")))))
          (.join "\n" lines)))))


;; * Quest Chain Generation
;; -----------------------------------------------------------------------------

(defn :async generate-followup-quest [completed-quest narrative]
  "Generate a follow-up quest based on a completed quest and recent narrative."
  (let [prompt (+ "You are a quest designer for a text adventure game.\n"
                  "Generate a follow-up quest based on the completed quest and recent narrative.\n\n"
                  f"Completed quest: {(:name completed-quest)}\n"
                  f"Completed quest description: {(:description completed-quest)}\n\n"
                  f"Recent narrative:\n{narrative}\n\n"
                  "Generate a new quest that:\n"
                  "- Follows logically from the completed quest\n"
                  "- References events or characters from the narrative\n"
                  "- Has a clear goal and stages\n"
                  "- Is interesting and engaging\n\n"
                  "Reply with JSON only:\n"
                  "{\"id\": \"quest-id\", \"name\": \"Quest Name\", \"description\": \"...\", \"stages\": [{\"condition\": \"...\", \"description\": \"...\"}], \"rewards\": {\"score\": 10}}")]
    (try
      (let [response (await (respond [(system prompt)] :provider "backend"))
            result (extract-json-unwrap response)]
        (when (and result (:id result) (:name result))
          (log.info f"Generated follow-up quest: {(:name result)}")
          result))
      (except [Exception]
        None))))

(defn :async check-and-generate-followups [char-name narrative]
  "Check for recently completed quests and generate follow-ups."
  (let [completed (completed-quest-ids char-name)]
    (for [qid completed]
      (let [quest (get-quest qid)]
        (when quest
          (let [followup (await (generate-followup-quest quest narrative))]
            (when followup
              ;; Save the generated quest
              (setv (get quest-defs (:id followup)) followup)
              (log.info f"Saved follow-up quest: {(:id followup)}"))))))))


;; * Offering Quests (NPC integration)
;; -----------------------------------------------------------------------------

(defn quests-from [npc-name]
  "Return quest defs given by this NPC that haven't been started."
  (lfor q (all-quests)
        :if (= (:giver q None) npc-name)
        q))


(defn available-for [char-name]
  "Quest defs a character can start right now."
  (lfor q (all-quests)
        :if (eligible? char-name (:id q ""))
        q))


;; * Initialisation
;; -----------------------------------------------------------------------------

(defn init []
  "Load quest definitions from world directory."
  (load-world-quests))
