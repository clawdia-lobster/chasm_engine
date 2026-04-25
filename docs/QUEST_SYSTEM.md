# Quest System Design for Chasm Engine

## Overview

Chasm currently lacks structured goals, puzzles, and victory conditions. Characters have an `objective` field but no mechanics for tracking progress toward goals. This document proposes a quest framework that:

1. Defines quests with stages, conditions, and rewards
2. Tracks per-character progress
3. Uses natural language conditions evaluated by the narrator LLM
4. Integrates seamlessly with the existing narrator context system
5. Supports both authored quests and emergent objectives

## Design Philosophy

**Natural language over state machines.** Traditional IF engines use explicit state checks (has-item?, visited?, flag-set?). Chasm's generative nature demands a different approach: conditions expressed in natural language, evaluated by the narrator LLM against the current narrative context. This is more flexible and aligns with the engine's design.

**Quests as narrative scaffolding.** Quests guide the story without constraining it. A quest stage like "Convince the blacksmith to help" doesn't specify *how*—the player might bribe, persuade, or threaten. The LLM evaluates whether the condition is met based on narrative events.

**Per-character isolation.** Each character tracks their own quest progress. NPCs can have quests; players can have multiple concurrent quests.

**Emergent objectives.** The existing `objective` field becomes the "active quest" pointer. Characters develop new objectives as quests complete or become stale.

---

## Data Structures

### Core Types (Hy namedtuples)

```hy
;; A quest definition (immutable template)
(setv Quest (namedtuple "Quest"
              ["id"           ; string, unique identifier e.g. "blacksmith-favor"
               "name"         ; string, display name "The Blacksmith's Favor"
               "description"  ; string, brief summary for player
               "giver"        ; string or None, character name who offers quest
               "location"     ; Coords or None, where quest originates
               "stages"       ; list of QuestStage, in order
               "prerequisites" ; list of quest ids that must be completed first
               "rewards"]))   ; QuestReward

;; A single stage within a quest
(setv QuestStage (namedtuple "QuestStage"
                   ["id"          ; string, e.g. "approach", "convince", "reward"
                    "description" ; string, what the player sees
                    "condition"   ; string, natural language condition for completion
                    "hint"        ; string or None, optional hint text
                    "optional"])) ; bool, if True can skip this stage

;; Rewards granted on quest completion
(setv QuestReward (namedtuple "QuestReward"
                    ["score"      ; int, points added to character.score
                     "items"      ; list of item names to grant
                     "reputation" ; dict mapping faction -> delta
                     "unlocks"])) ; list of quest ids that become available

;; Per-character progress through a quest
(setv QuestProgress (namedtuple "QuestProgress"
                      ["character_name" ; string
                       "quest_id"       ; string
                       "stage_index"    ; int, current stage (0-indexed)
                       "stage_history"  ; list of StageCompletion records
                       "started_at"     ; float, timestamp
                       "completed_at"   ; float or None
                       "failed_at"]))   ; float or None

;; Record of how a stage was completed
(setv StageCompletion (namedtuple "StageCompletion"
                        ["stage_id"     ; string
                         "completed_at" ; float, timestamp
                         "narrative"])) ; string, brief description of how it happened
```

### Mutable Character Attributes Update

Add to `mutable-character-attributes` in `types.hy`:

```hy
(setv mutable-character-attributes
      ["appearance"
       "health"
       "emotions"
       "objective"
       "destination"
       "active_quests"])    ; list of quest ids currently in progress
```

---

## State Storage

### SQLite Tables

Using the existing `SqliteDict` pattern from `state.hy`:

```hy
;; Quest definitions (world-level, shared across all characters)
(setv quests (get-table "quests"))  ; key: quest_id, value: Quest dict

;; Per-character quest progress
(setv quest-progress (get-table "quest_progress"))  
;; key: f"{character_name}:{quest_id}", value: QuestProgress dict
```

### Schema Details

**quests table:**
- Key: quest_id (string)
- Value: Quest namedtuple serialized as dict

**quest_progress table:**
- Key: composite "{character_name}:{quest_id}"
- Value: QuestProgress namedtuple serialized as dict

This allows:
- O(1) quest definition lookup
- O(1) progress lookup per character per quest
- Easy enumeration of all quests or all progress for a character

---

## Quest Definition Format

Quests are defined in TOML files under `worlds/{world}/quests/`. This allows world authors to create quest content without writing code.

### Example: `worlds/New York/quests/blacksmith_favor.toml`

```toml
[quest]
id = "blacksmith-favor"
name = "The Blacksmith's Favor"
description = "The village blacksmith needs help with a delicate matter."
giver = "Marcus the Blacksmith"
# location = { x = 3, y = -2 }  # optional, where quest originates

[quest.prerequisites]
# quests that must be completed first
requires = ["village-introduction"]

[quest.rewards]
score = 50
items = ["iron-key"]
unlocks = ["the-cellar-mystery"]

[[quest.stages]]
id = "approach"
description = "Speak with Marcus at the smithy."
condition = "Marcus has explained his problem to the player"
hint = "Marcus can be found at the smithy during the day."

[[quest.stages]]
id = "investigate"
description = "Find out what happened to Marcus's daughter."
condition = "The player has discovered where Marcus's daughter went"
hint = "Ask around the village. The innkeeper might know something."
optional = true

[[quest.stages]]
id = "convince"
description = "Convince Marcus to trust you with the full story."
condition = "Marcus trusts the player and has revealed the complete situation"
# No hint - player must figure this out

[[quest.stages]]
id = "resolve"
description = "Help Marcus resolve the situation with his daughter."
condition = "Marcus's daughter has returned or the situation is otherwise resolved"
```

### Example: Multi-Path Quest

```toml
[quest]
id = "merchant-caravan"
name = "The Merchant's Dilemma"
description = "A traveling merchant needs an escort through dangerous territory."

[[quest.stages]]
id = "accept"
description = "Agree to escort the merchant."
condition = "The player has agreed to escort the merchant"

[[quest.stages]]
id = "prepare"
description = "Prepare for the journey."
condition = "The player has made preparations for travel"
hint = "You might need supplies, weapons, or companions."
optional = true

[[quest.stages]]
id = "journey"
description = "Escort the merchant safely to the destination."
condition = "The merchant has arrived at their destination safely"

[[quest.stages]]
id = "confrontation"
description = "Deal with the bandits on the road."
condition = "The bandit threat has been neutralized"
optional = true  # can avoid bandits entirely

[[quest.stages]]
id = "complete"
description = "Receive payment from the merchant."
condition = "The merchant has paid the player"
```

---

## API Functions

### Quest Management (`quest.hy`)

```hy
(defn load-quests [world-path]
  "Load all quest TOML files from {world-path}/quests/ into the quests table.")

(defn get-quest [quest-id]
  "Return Quest namedtuple or None.")

(defn list-quests []
  "Return all available quests.")

(defn available-quests [character]
  "Return quests the character can start (prerequisites met, not already active).")

(defn :async start-quest [character quest-id]
  "Begin a quest for a character. Returns QuestProgress or raises QuestError.")

(defn abandon-quest [character quest-id]
  "Remove a quest from character's active quests without completion.")
```

### Progress Tracking

```hy
(defn get-progress [character quest-id]
  "Return QuestProgress or None if not started.")

(defn get-all-progress [character]
  "Return all QuestProgress records for a character.")

(defn current-stage [character quest-id]
  "Return the current QuestStage or None if quest not active.")

(defn :async advance-stage [character quest-id narrative]
  "Advance to next stage. Called when LLM confirms condition met.")

(defn :async complete-quest [character quest-id]
  "Mark quest complete, grant rewards, update character state.")

(defn :async fail-quest [character quest-id reason]
  "Mark quest failed. Some quests may be retryable.")
```

### Condition Evaluation

```hy
(defn :async check-stage-condition [character quest-id messages]
  "Ask the LLM if the current stage condition is met.
   Returns {:met bool :evidence string}.")
```

This is the core innovation: instead of checking game state directly, we ask the narrator LLM to evaluate whether the condition has been satisfied based on the narrative context.

---

## LLM Condition Evaluation

### Template: `quest.toml`

```toml
condition-system = '''You are evaluating whether a quest stage has been completed in an interactive fiction game.
Base your judgment only on the narrative events that have actually occurred.

Quest: {quest_name}
Current Stage: {stage_description}
Completion Condition: {condition}

Recent narrative context:
{narrative_summary}

Has the completion condition been met? Consider:
1. Direct actions by the player
2. Consequences of those actions
3. Events initiated by NPCs
4. Changes in the game world

Be strict: the condition should be clearly satisfied by events in the narrative.
If uncertain, err on the side of "not yet complete".'''

condition-check = '''Based on the narrative above, has the following condition been met?

Condition: {condition}

Reply in this exact format:
MET: [yes/no]
EVIDENCE: [brief quote or summary of what happened that satisfies the condition]
CONFIDENCE: [high/medium/low]

If the condition is partially met but not fully, answer "no".
If the condition requires something that hasn't happened yet, answer "no".'''
```

### Evaluation Function

```hy
(defn :async check-stage-condition [character quest-id messages]
  "Evaluate whether the current stage condition is met."
  (let [progress (get-progress character quest-id)
        quest (get-quest quest-id)
        stage (get quest.stages progress.stage-index)
        narrative-summary (summarize-recent messages :max-tokens 500)
        result (await (quest-condition-check
                        :quest-name quest.name
                        :stage-description stage.description
                        :condition stage.condition
                        :narrative-summary narrative-summary))]
    (parse-condition-result result)))

(defn parse-condition-result [text]
  "Parse LLM response into structured result."
  (let [met (in "MET: yes" (.lower text))
        evidence-match (re.search r"EVIDENCE:\s*(.+?)(?:\n|CONFIDENCE)" text)
        confidence-match (re.search r"CONFIDENCE:\s*(\w+)" text)]
    {"met" met
     "evidence" (if evidence-match (.group evidence-match 1) "")
     "confidence" (if confidence-match (.group confidence-match 1) "low")}))
```

### When to Check Conditions

Conditions are checked at specific points in the game loop:

1. **After each player action** - The `develop` function in `engine.hy` already processes recent messages. Add quest condition checks here.

2. **Explicitly via command** - `/quest status` shows current quest progress.

3. **Periodically for NPCs** - Background task checks NPC quest progress.

```hy
;; In engine.hy, extend develop function
(defn :async develop []
  "Move the plot and characters along."
  (when develop-queue
    (let [player-name (.pop develop-queue)
          player (get-character player-name)
          messages (get-narrative player-name)
          recent-messages (cut messages -4 None)]
      ; ... existing plot extraction ...
      
      ; NEW: Check quest conditions
      (for [quest-id player.active-quests]
        (let [result (await (check-stage-condition player quest-id recent-messages))]
          (when (:met result)
            (await (advance-stage player quest-id (:evidence result)))
            ; If quest complete, grant rewards
            (when (quest-complete? player quest-id)
              (await (complete-quest player quest-id)))))))))
```

---

## Narrator Integration

### Context Template Extension

Add quest context to the narrator's system prompt. Extend `context.toml`:

```toml
# In context.toml, add:

quest = '''
ACTIVE QUEST: {quest_name}
STAGE: {stage_description}
OBJECTIVE: {condition}

{hint_text}
'''

quests-active = '''
The player is pursuing the following quests:

{active_quests_context}
'''
```

### Player Context Update

Modify `player-context` in `engine.hy`:

```hy
(defn :async player-context [player]
  "Fill in player context templates with current information."
  (let [active-quests (get-all-progress player)
        quest-contexts (lfor qp active-quests
                          :if (not qp.completed_at)
                          (quest-context (get-quest qp.quest-id) qp))]
    (plot.context "player"
      :player player.name
      :items-here (item.describe-at player.coords)
      :location (place.name player.coords)
      :locations (await (place.nearby-str player.coords))
      :rooms (place.rooms player.coords)
      :character-descriptions-here (character.describe-at player.coords :long True)
      :objective player.objective
      :inventory (item.describe-inventory player)
      :active-quests (jnn quest-contexts))))
```

### Quest Context Function

```hy
(defn quest-context [quest progress]
  "Generate context string for an active quest."
  (let [stage (get quest.stages progress.stage-index)
        hint-text (if stage.hint f"Hint: {stage.hint}" "")]
    (plot.context "quest"
      :quest-name quest.name
      :stage-description stage.description
      :condition stage.condition
      :hint-text hint-text)))
```

This ensures the narrator always knows what the player is trying to accomplish, allowing it to:
- Guide the narrative toward quest-relevant events
- Recognize when quest conditions are met
- Provide appropriate hints through NPC dialogue
- Maintain consistency with quest objectives

---

## Reward System

### Granting Rewards

```hy
(defn :async grant-rewards [character reward]
  "Apply quest rewards to a character."
  ; Score
  (when reward.score
    (update-character character :score (+ character.score reward.score)))
  
  ; Items
  (for [item-name reward.items]
    (await (item.spawn-named item-name character.coords))
    (await (item.fuzzy-claim item-name character)))
  
  ; Unlocked quests
  ; (tracked via prerequisites system, no action needed)
  
  ; Reputation (future: faction system)
  ; (for [faction delta] (.items reward.reputation)
  ;   (update-reputation character faction delta))
  
  (log.info f"Granted rewards to {character.name}: {reward}"))
```

### Score Integration

The existing `increment-score?` function in `character.hy` checks if the character did something worthwhile. Quest completion should be a significant score event:

```hy
(defn :async complete-quest [character quest-id]
  "Mark quest complete and grant rewards."
  (let [quest (get-quest quest-id)
        progress (get-progress character quest-id)
        completed-progress (QuestProgress #** (| (._asdict progress)
                                                  {"completed_at" (time)}))]
    ; Update progress
    (set-progress completed-progress)
    
    ; Remove from active quests
    (update-character character 
                      :active-quests (lfor q character.active-quests 
                                           :if (!= q quest-id) q)
                      :objective nil)  ; or set to next suggested quest
    
    ; Grant rewards
    (await (grant-rewards character quest.rewards))
    
    ; Record in memory
    (memory.add "narrator"
                :metadata {"classification" "major"
                           "quest" quest-id
                           "type" "quest-complete"}
                :text f"{character.name} completed the quest '{quest.name}'")))
```

---

## Quest Discovery and Activation

### Starting Quests

Quests can be started through several mechanisms:

1. **NPC dialogue** - The narrator can trigger quest starts when appropriate
2. **Location discovery** - Entering a location with an available quest
3. **Item interaction** - Finding an item that starts a quest
4. **Explicit command** - `/quest start <quest-id>`

```hy
(defn :async offer-quest [character quest-id]
  "Check if a quest should be offered to a character."
  (let [quest (get-quest quest-id)]
    (and quest
         (not (in quest-id character.active-quests))
         (prerequisites-met? character quest)
         (not (quest-completed? character quest-id)))))

(defn prerequisites-met? [character quest]
  "Check if all prerequisite quests are completed."
  (all (lfor pre-quest-id quest.prerequisites
             (quest-completed? character pre-quest-id))))

(defn :async start-quest [character quest-id]
  "Begin a quest for a character."
  (let [quest (get-quest quest-id)]
    (unless (offer-quest character quest-id)
      (raise (QuestError f"Cannot start quest {quest-id}")))
    
    (let [progress (QuestProgress
                     :character_name character.name
                     :quest_id quest-id
                     :stage_index 0
                     :stage_history []
                     :started_at (time)
                     :completed_at None
                     :failed_at None)]
      (set-progress progress)
      (update-character character
                        :active_quests (+ character.active_quests [quest-id])
                        :objective quest.description)
      (log.info f"{character.name} started quest '{quest.name}'")
      progress)))
```

### Quest Giver Integration

When a character talks to an NPC who offers quests:

```hy
;; In the narrator context, include available quests from NPCs present
(defn npc-quest-context [character]
  "Find quests offered by NPCs at the character's location."
  (let [npcs-here (character.get-at character.coords)
        available (lfor npc npcs-here
                        :if (= npc.name (get-quest-giver npc.name))
                        :setv q (get-quest-by-giver npc.name)
                        :if (offer-quest character q.id)
                        q)]
    (if available
        f"The following quests may be available: {(.join ', ' (lfor q available q.name))"
        "")))
```

---

## CLI Commands

Add quest-related commands to the parser in `engine.hy`:

```hy
(defn quest-status [player]
  "Show active and completed quests."
  (let [active (get-all-progress player)
        active-strs (lfor qp active
                          :if (not qp.completed_at)
                          (let [q (get-quest qp.quest-id)
                                stage (get q.stages qp.stage-index)]
                            f"• {q.name}: {stage.description}"))
        completed (lfor qp active
                        :if qp.completed_at
                        (let [q (get-quest qp.quest-id)]
                          f"• {q.name} (completed)"))]
    (jnn ["Active Quests:"
          #* active-strs
          ""
          "Completed:"
          #* completed])))

;; In parse function, add:
(.startswith line "/quest") (info (quest-status player))
```

---

## Example Quests

### Tutorial Quest: "First Steps"

```toml
[quest]
id = "first-steps"
name = "First Steps"
description = "Learn the basics of navigating this world."

[quest.rewards]
score = 10

[[quest.stages]]
id = "look"
description = "Look around your current location."
condition = "The player has examined their surroundings"
hint = "Type '/look' to see what's around you."

[[quest.stages]]
id = "move"
description = "Travel to an adjacent location."
condition = "The player has moved to a new location"
hint = "Type '/go north' or use a compass direction."

[[quest.stages]]
id = "interact"
description = "Interact with something or someone."
condition = "The player has interacted with an item or character"
hint = "Try picking up an item or talking to someone."
```

### Mystery Quest: "The Missing Heirloom"

```toml
[quest]
id = "missing-heirloom"
name = "The Missing Heirloom"
description = "Lady Ashworth's family heirloom has vanished. She suspects foul play."
giver = "Lady Ashworth"

[quest.prerequisites]
requires = ["manor-introduction"]

[quest.rewards]
score = 100
items = ["ashworth-signet-ring"]
unlocks = ["the-family-secret"]

[[quest.stages]]
id = "accept"
description = "Accept Lady Ashworth's request to investigate."
condition = "The player has agreed to find the missing heirloom"

[[quest.stages]]
id = "investigate-scene"
description = "Examine the scene of the crime."
condition = "The player has thoroughly examined the room where the heirloom was kept"

[[quest.stages]]
id = "interview-suspects"
description = "Interview the household staff."
condition = "The player has questioned at least two members of the household"
optional = true

[[quest.stages]]
id = "discover-culprit"
description = "Identify who took the heirloom."
condition = "The player has determined who stole the heirloom"

[[quest.stages]]
id = "confront"
description = "Confront the thief or report to Lady Ashworth."
condition = "The player has confronted the thief or informed Lady Ashworth of the culprit"

[[quest.stages]]
id = "resolve"
description = "Recover the heirloom."
condition = "The heirloom has been returned to Lady Ashworth"
```

### Branching Quest: "The Faction Choice"

```toml
[quest]
id = "faction-choice"
name = "A House Divided"
description = "Two factions vie for control. Your choice will shape the region's future."

[quest.rewards]
score = 200
unlocks = ["merchants-path", "rebels-path"]  # Both unlock, but only one is completable

[[quest.stages]]
id = "learn"
description = "Learn about the conflict between the Merchants' Guild and the Rebels."
condition = "The player understands the basic positions of both factions"

[[quest.stages]]
id = "observe"
description = "Witness an incident between the factions."
condition = "The player has observed a confrontation between faction members"

[[quest.stages]]
id = "choose"
description = "Choose a side in the conflict."
condition = "The player has declared allegiance to one faction"

[[quest.stages]]
id = "prove-worth"
description = "Complete a task for your chosen faction."
condition = "The player has proven their loyalty to their chosen faction"

[[quest.stages]]
id = "decisive-action"
description = "Take decisive action that determines the conflict's outcome."
condition = "The player has taken action that resolves the faction conflict"
```

---

## Implementation Plan

### Phase 1: Core Infrastructure
1. Add quest types to `types.hy`
2. Create `quest.hy` module with basic functions
3. Add SQLite tables for quests and progress
4. Implement quest loading from TOML

### Phase 2: Condition Evaluation
1. Create `quest.toml` template
2. Implement `check-stage-condition`
3. Integrate with `develop` function in `engine.hy`

### Phase 3: Narrator Integration
1. Extend context templates
2. Update `player-context` function
3. Add quest context to narrator system prompt

### Phase 4: Rewards and Completion
1. Implement `grant-rewards`
2. Add score integration
3. Create memory entries for quest events

### Phase 5: Discovery and Activation
1. Implement quest offering logic
2. Add NPC quest giver integration
3. Create `/quest` CLI commands

### Phase 6: Polish
1. Add quest abandonment
2. Handle quest failure cases
3. Create tutorial quests
4. Write world-specific quest content

---

## Future Extensions

### Dynamic Quests
Quests generated by the LLM based on narrative events. The system could detect when a character makes a promise or commitment and automatically create a quest.

### Quest Chains
Quests that branch into multiple follow-up quests based on player choices. The `unlocks` field already supports this.

### Timed Quests
Quests with time limits (in-game or real-time). Add `deadline` field to Quest and check in `develop`.

### Reputation System
Track character reputation with factions. Quests modify reputation, which affects NPC behavior.

### Quest Items
Items that are only obtainable through quests, with special properties tracked in the item system.

---

## Appendix: Full Type Definitions

```hy
;; types.hy additions

(setv Quest (namedtuple "Quest"
              ["id"           ; str - unique identifier
               "name"         ; str - display name
               "description"  ; str - brief summary
               "giver"        ; str or None - NPC who offers quest
               "location"     ; dict or None - {"x" int "y" int}
               "stages"       ; list of dicts - [{"id" "description" "condition" "hint" "optional"}]
               "prerequisites" ; list of str - quest ids
               "rewards"]))   ; dict - {"score" int "items" [str] "unlocks" [str]}

(setv QuestProgress (namedtuple "QuestProgress"
                      ["character_name" ; str
                       "quest_id"       ; str
                       "stage_index"    ; int
                       "stage_history"  ; list of dicts
                       "started_at"     ; float
                       "completed_at"   ; float or None
                       "failed_at"]))   ; float or None

;; For serialization, stages and rewards are stored as dicts/lists
;; and reconstructed into namedtuples when accessed
```

---

## Appendix: Migration from Objective Field

The existing `objective` field on Character becomes the "primary active quest" description. When a quest is started, `objective` is set to the quest description. When completed, it's cleared or set to the next suggested quest.

This maintains backward compatibility while adding structured quest tracking.

```hy
;; In start-quest
(update-character character
                  :active_quests (+ character.active_quests [quest-id])
                  :objective quest.description)

;; In complete-quest
(let [next-quest (first (available-quests character))]
  (update-character character
                    :objective (if next-quest next-quest.description None)))
```
