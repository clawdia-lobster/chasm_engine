"""
LLM-based intent classification for natural language commands.
Replaces regex-based parsing with flexible LLM interpretation.
"""

(require hyrule.argmove [-> ->>])

(import chasm_engine [log])
(import chasm_engine.lib [config jn extract-json-unwrap])
(import chasm_engine.chat [respond user system])
(require chasm_engine.instructions [def-fill-template])

;; Intent types
;; -----------------------------------------------------------------------------
;; MOVE: go to a direction or place
;; TAKE: pick up an item
;; DROP: drop an item
;; GIVE: give an item to someone
;; TALK: talk to a character
;; LOOK: examine something
;; USE: use an item
;; ATTACK: attack something
;; HELP: ask for help/hint
;; QUESTS: check quest status
;; QUIT: exit the game
;; SAY: say something (default for dialogue)

;; Define the intent classification function using the template system
;; This creates intent-classify function that uses the 'classify' template
;; with 'system' as the system prompt
(def-fill-template intent classify system)

(defn :async classify-intent [line player context]
  "Classify player input into an intent.
  Returns dict with 'intent' and optional 'target', 'recipient', 'item', etc."
  (try
    (let [response (await (intent-classify
                            []
                            :player player.name
                            :location (:location context)
                            :items (:items-here context)
                            :characters (:characters-here context)
                            :nearby (:nearby context)
                            :input line
                            :provider "backend"))
          result (extract-json-unwrap response)]
      (or result {"intent" "SAY" "content" line}))
    (except [Exception]
      {"intent" "SAY" "content" line})))

(defn :async parse-command [line player context]
  "Parse a natural language command into structured action.
  Returns dict suitable for engine processing."
  (let [classification (await (classify-intent line player context))
        intent (:intent classification "SAY")]
    (match intent
      "MOVE" {"action" "move"
              "direction" (or (:direction classification) (:target classification))}
      "TAKE" {"action" "take"
              "item" (:item classification)}
      "DROP" {"action" "drop"
              "item" (:item classification)}
      "GIVE" {"action" "give"
              "item" (:item classification)
              "recipient" (:recipient classification)}
      "TALK" {"action" "talk"
              "target" (:target classification)}
      "LOOK" {"action" "look"
              "target" (:target classification)}
      "USE" {"action" "use"
             "item" (:item classification)
             "target" (:target classification)}
      "ATTACK" {"action" "attack"
                "target" (:target classification)}
      "HELP" {"action" "help"}
      "QUESTS" {"action" "quests"}
      "QUIT" {"action" "quit"}
      "SAY" {"action" "say"
             "content" (or (:content classification) line)}
      _ {"action" "say"
         "content" line})))
