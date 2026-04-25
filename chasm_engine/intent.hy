"
LLM-based intent classification for natural language commands.
Replaces regex-based parsing with flexible LLM interpretation.
"

(require hyrule.argmove [-> ->>])

(import chasm_engine [log])
(import chasm_engine.lib [config jn extract-json-unwrap])
(import chasm_engine.chat [respond user])
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
(def-fill-template intent classify)

(defn :async classify-intent [line player context]
  "Classify player input into an intent.
  Returns dict with 'intent' and optional 'target', 'recipient', 'item', etc."
  (let [prompt (+ "You are an intent classifier for a text adventure game.\n"
                  "Classify the player's action into one of these intents:\n\n"
                  "- MOVE: going somewhere (direction or place name)\n"
                  "- TAKE: picking up an item\n"
                  "- DROP: dropping an item\n"
                  "- GIVE: giving an item to someone\n"
                  "- TALK: talking to a character\n"
                  "- LOOK: examining something\n"
                  "- USE: using an item\n"
                  "- ATTACK: attacking something\n"
                  "- HELP: asking for help or a hint\n"
                  "- QUESTS: checking quest status\n"
                  "- QUIT: exiting the game\n"
                  "- SAY: saying something (default for dialogue)\n\n"
                  f"Player: {player.name}\n"
                  f"Location: {(:location context)}\n"
                  f"Items here: {(:items-here context)}\n"
                  f"Characters here: {(:characters-here context)}\n"
                  f"Nearby: {(:nearby context)}\n\n"
                  f"Player input: {line}\n\n"
                  "Reply with JSON only:\n"
                  "{\"intent\": \"INTENT_TYPE\", \"target\": \"optional target\", \"item\": \"optional item\", \"recipient\": \"optional recipient\", \"direction\": \"optional direction\"}")]
    (try
      (let [response (await (intent-classify [] :prompt prompt :provider "backend"))
            result (extract-json-unwrap response)]
        (or result {"intent" "SAY" "content" line}))
      (except [Exception]
        {"intent" "SAY" "content" line}))))

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
