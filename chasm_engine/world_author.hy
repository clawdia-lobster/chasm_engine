"
World Author - LLM-driven dynamic world generation.

The World Author reviews narrative state and injects new content:
- New regions at map edges
- Connected quest chains  
- NPC backstories and relationships
- Plot hooks and mysteries

Design: docs/WORLD_AUTHOR.md (to be created)
"

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])

(import time [time])
(import random [choice random])

(import chasm_engine [log])
(import chasm_engine.lib [config extract-json-unwrap format-msgs jn])
(import chasm_engine.state [world world-name path get-place len-places
                            get-character get-characters
                            random-coords])
(import chasm_engine.types [Coords])
(import chasm_engine.chat [respond system user])
(import chasm_engine.place)
(import chasm_engine.character)
(import chasm_engine.quest)


;; * Author Prompts
;; -----------------------------------------------------------------------------

(setv author-prompt
  "You are the World Author for an interactive fiction game.
Your job is to review the current state of the world and decide what new content
to add to keep the world fresh, interesting, and coherent.

World setting: {world}
Current map size: {map_size} places
Active characters: {character_count}
Active quests: {quest_count}

Recent narrative summary:
{narrative_summary}

Decide what to add. Choose ONE of:
1. NEW_REGION - Add a new area at the map edge
2. NEW_QUEST - Create a quest based on recent events  
3. NEW_NPC - Add an interesting character
4. PLOT_HOOK - Inject a mystery or event
5. NOTHING - World is fine as-is

Reply in JSON:
{\"decision\": \"NEW_REGION\", \"reason\": \"brief explanation\", \"details\": {...}}")


(setv region-prompt
  "Create a new region for the world: {world}

This region should be at coordinates ({x}, {y}), adjacent to existing areas.
Existing nearby places: {nearby}

Generate a compelling new location that fits the world theme.

Reply in JSON:
{
  \"name\": \"Place Name\",
  \"appearance\": \"vivid description\",
  \"atmosphere\": \"mood and feeling\",
  \"terrain\": \"terrain type\",
  \"rooms\": [\"room1\", \"room2\"]
}")


(setv quest-prompt
  "Create a quest based on recent events in: {world}

Recent happenings:
{narrative_summary}

Active characters: {characters}

Design a quest that:
- Follows naturally from recent events
- Involves existing characters or places
- Has 2-4 stages with clear conditions
- Offers meaningful choices

Reply as a quest TOML structure (without the [quest] header):
{
  \"id\": \"kebab-case-id\",
  \"name\": \"Quest Name\",
  \"description\": \"brief summary\",
  \"giver\": \"NPC name or null\",
  \"stages\": [
    {\"id\": \"stage1\", \"description\": \"...\", \"condition\": \"...\", \"hint\": \"...\", \"optional\": false}
  ],
  \"rewards\": {\"score\": 50, \"items\": [], \"unlocks\": []}
}")


(setv npc-prompt
  "Create an NPC for: {world}

This character will appear at: {location}

Existing characters nearby: {nearby_chars}

Generate a character with:
- A distinct personality that fits the world
- A connection to existing places or people
- A secret or motivation
- Potential for quests or conflict

Reply in JSON:
{
  \"name\": \"Character Name\",
  \"appearance\": \"physical description\",
  \"gender\": \"M/F/N\",
  \"backstory\": \"brief history\",
  \"voice\": \"speech pattern\",
  \"traits\": [\"trait1\", \"trait2\"],
  \"occupation\": \"job or role\",
  \"motivation\": \"what they want\",
  \"secret\": \"something hidden\"
}")


;; * Review & Decision
;; -----------------------------------------------------------------------------

(defn :async review-world [narrative-summary]
  "Ask the World Author LLM what content to add. Returns decision dict."
  (let [prompt (author-prompt.format
                  :world world
                  :world_name world-name
                  :map_size (len-places)
                  :character_count (len (list (get-characters)))
                  :quest_count (len (quest.all-quests))
                  :narrative_summary (or narrative-summary "World just started."))
        response (await (respond [(system "You are the World Author.")
                                  (user prompt)]
                                 :provider "narrator"))
        decision (extract-json-unwrap response)]
    (let [dec (or (.get decision "decision") "NOTHING")
          reason (or (.get decision "reason") "")]
      (log.info f"World Author decision: {dec} - {reason}"))
    decision))


;; * Content Generation
;; -----------------------------------------------------------------------------

(defn :async generate-region [coords]
  "Create a new place at the given coordinates."
  (let [nearby-places (lfor c [(Coords (+ (:x coords) 1) (:y coords))
                               (Coords (- (:x coords) 1) (:y coords))
                               (Coords (:x coords) (+ (:y coords) 1))
                               (Coords (:x coords) (- (:y coords) 1))]
                        :if (get-place c)
                        (:name (get-place c) "unknown"))
        prompt (region-prompt.format
                 :world world
                 :x (:x coords)
                 :y (:y coords)
                 :nearby (or (.join ", " nearby-places) "wilderness"))
        response (await (respond [(system "You create vivid game locations.")
                                  (user prompt)]
                                 :provider "narrator"))
        region-data (extract-json-unwrap response)]
    (when region-data
      (log.info f"Generated region: {(or (.get region-data "name") "unknown")} at {coords}")
      region-data)))


(defn :async generate-quest [narrative-summary]
  "Create a new quest based on recent events."
  (let [chars (lfor c (get-characters) (:name c))
        prompt (quest-prompt.format
                 :world world
                 :narrative_summary narrative-summary
                 :characters (or (.join ", " chars) "no one yet"))
        response (await (respond [(system "You design compelling quests.")
                                  (user prompt)]
                                 :provider "narrator"))
        quest-data (extract-json-unwrap response)]
    (when quest-data
      (log.info f"Generated quest: {(or (.get quest-data "name") "unknown")}")
      quest-data)))


(defn :async generate-npc [coords]
  "Create a new character at the given location."
  (let [nearby-chars (lfor c (character.get-at coords) (:name c))
        place (get-place coords)
        place-name (if place (:name place) "unknown location")
        prompt (npc-prompt.format
                 :world world
                 :location place-name
                 :nearby_chars (or (.join ", " nearby-chars) "no one"))
        response (await (respond [(system "You create memorable characters.")
                                  (user prompt)]
                                 :provider "narrator"))
        npc-data (extract-json-unwrap response)]
    (when npc-data
      (log.info f"Generated NPC: {(or (.get npc-data "name") "unknown")}")
      npc-data)))


;; * Content Installation
;; -----------------------------------------------------------------------------

(defn install-region! [coords region-data]
  "Create a new place from generated data."
  (import chasm_engine.types [Place])
  (import chasm_engine.state [set-place])
  (let [place (Place :coords coords
                     :name (:name region-data "Unknown")
                     :rooms (:rooms region-data [])
                     :appearance (:appearance region-data "")
                     :atmosphere (:atmosphere region-data "")
                     :terrain (:terrain region-data ""))]
    (set-place place)
    (log.info f"Installed region: {(:name region-data)} at {coords}")
    place))


(defn install-quest! [quest-data]
  "Save a generated quest to the quest definitions."
  (let [quest-id (.get quest-data "id" (str (time)))]
    (setv (get quest.quest-defs quest-id) quest-data)
    (log.info f"Installed quest: {(or (.get quest-data "name") "unknown")} ({quest-id})")
    quest-id))


(defn install-npc! [coords npc-data]
  "Create a character from generated data at the given location."
  (import chasm_engine.types [Character])
  (import chasm_engine.state [set-character])
  (import chasm_engine.character [spawn])
  (let [char-data (| {"coords" coords
                      "npc" True
                      "score" 0}
                     npc-data)
        char (Character #** char-data)]
    (set-character char)
    (log.info f"Installed NPC: {(or (.get npc-data "name") "unknown")} at {coords}")
    char))


;; * Main Author Cycle
;; -----------------------------------------------------------------------------

(defn :async author-cycle [narrative-summary]
  "Run one cycle of the World Author. Called periodically from engine."
  (let [decision (await (review-world narrative-summary))]
    (match (:decision decision "NOTHING")
           "NEW_REGION" (let [edge-coords (find-map-edge)]
                         (when edge-coords
                           (let [region-data (await (generate-region edge-coords))]
                             (when region-data
                               (install-region! edge-coords region-data)))))
           "NEW_QUEST"  (let [quest-data (await (generate-quest narrative-summary))]
                         (when quest-data
                           (install-quest! quest-data)))
           "NEW_NPC"    (let [coords (random-coords)
                              npc-data (await (generate-npc coords))]
                         (when npc-data
                           (install-npc! coords npc-data)))
           "PLOT_HOOK"  (log.info "Plot hook injection not yet implemented")
           _            (log.debug "World Author: no action taken"))
    decision))


;; * Helpers
;; -----------------------------------------------------------------------------

(defn find-map-edge []
  "Find a coordinate at the edge of the existing map for expansion.
  Returns Coords or None."
  (import chasm_engine.state [get-places])
  (let [places (list (get-places))
        xs (lfor p places (:x p.coords))
        ys (lfor p places (:y p.coords))]
    (when (and xs ys)
      (let [min-x (min xs)
            max-x (max xs)
            min-y (min ys)
            max-y (max ys)
            ;; Pick a random edge
            edge (choice ["north" "south" "east" "west"])
            new-coords (match edge
                              "north" (Coords (choice xs) (+ max-y 1))
                              "south" (Coords (choice xs) (- min-y 1))
                              "east"  (Coords (+ max-x 1) (choice ys))
                              "west"  (Coords (- min-x 1) (choice ys))
                              _       None)]
        (when (and new-coords (not (get-place new-coords)))
          new-coords)))))


(defn summarise-narrative [messages [n 10]]
  "Extract a brief summary of recent narrative for the World Author.
  Returns a string."
  (let [recent (cut messages (- n) None)
        texts (lfor m recent (:content m ""))]
    (.join "\n" texts)))
