"
Functions that deal with characters.
"

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])

(require hyjinx.macros [prepend append])

(import time [time])

(import chasm_engine [log])

(require chasm_engine.instructions [deftemplate def-fill-template])

(import chasm_engine.lib *)
(import chasm_engine.constants [alphabet default-character banned-names])
(import chasm_engine.types [Coords Character Item is-at])
                            mutable-character-attributes
                            initial-character-attributes])
(import chasm_engine [place memory_facts])

(import chasm_engine.state [world
                            get-place
                            get-character set-character update-character character-key get-characters])


(defclass CharacterError [Exception])

(def-fill-template character json system)
(def-fill-template character lines system)
;(def-fill-template character develop-lines develop-system)
(def-fill-template character develop-json develop-system)
(def-fill-template character score score-system)
(def-fill-template character mentioned mentioned-system)


(defn is-valid-key [s]
  (re.match "^[a-zA-Z0-9][a-zA-Z0-9._-]*[a-zA-Z0-9]$" s))

(defn :async spawn [[name None] [coords (Coords 0 0)] [loaded {}] [retries 0]] ; -> Character
  "Spawn a character from card, db, or just generated."
  (try
    (let [; only allow to override some
          sanitised {"name" name
                     "appearance" (:appearance loaded None)
                     "gender" (:gender loaded None)
                     "backstory" (:backstory loaded None)
                     "voice" (:voice loaded None)
                     "traits" (:traits loaded None)
                     "likes" (:likes loaded None)
                     "dislikes" (:dislikes loaded None)
                     "occupation" (:occupation loaded None)
                     "motivation" (:motivation loaded None)}]
      (let [char (or (get-character name)
                     (await (gen-json coords name))
                     default-character)
            filtered (dfor [k v] (.items sanitised) :if v k v)
            character (Character #** (| (._asdict default-character)
                                        (._asdict char)
                                        filtered))]
        (log.info f"{char.name}")
        (when loaded (log.info f"loaded: {sanitised}"))
        (if (and character.name
                 (is-valid-key (character-key character.name))
                 (< retries 5))
            (do
              (log.info f"set character {name} -> {char.name}")
              ;(log.info (json.dumps (._asdict character))))
              (set-character character))
            (do
              ; else keep trying until it works
              (log.warn f"invalid spawn for character {character.name} at {coords}, retrying...")
              (await (spawn name coords loaded (inc retries)))))))
    (except [e [Exception]]
      (log.error f"spawn failed for {name} at {coords}.")
      (log.error e))))

(defn :async gen-lines [coords [name None]] ; -> Character or None
  "Make up some plausible character based on a name."
  (let [seed (choice alphabet)
        name-str (or name f"the character (invent one whose first name begins with '{seed}')")
        place (get-place coords)
        place-name (if place place.name "a typical place in this world")
        details (grep-attributes
                  (await (character-lines
                           :name name-str
                           :place place-name
                           :setting f"Story setting: {world}"))
                  initial-character-attributes)
        name (word-chars (or name (:name details "")))
        objective (word-chars (:objective details ""))
        name-dict (if name {"name" name} {})]
    (log.info name)
    (Character #** (| (._asdict default-character)
                      details
                      name-dict
                      {"coords" coords
                       "objective" objective}))))

(defn :async gen-json [coords [name None]] ; -> Character or None
  "Make up some plausible character based on a name."
  (let [seed (choice alphabet)
        name-str (or name f"the character's name (whose first name begins with {seed})")
        name-dict (if name {"name" name} {})
        place (get-place coords)
        place-name (if place place.name "a typical place in this world")
        details (extract-json-unwrap
                  (await (character-json
                           :name name-str
                           :place place-name
                           :setting f"Story setting: {world}")))]
    (when details
      (log.info f"'{(:name details None)}'")
      (Character #** (| (._asdict default-character)
                        details
                        name-dict
                        {"coords" coords})))))

(defn describe [character [long False]]
  "A string that briefly describes the character."
  (if character
      (let [attributes (._asdict character)]
        ; pop off the things we don't want to inject
        (.pop attributes "coords")
        (.pop attributes "destination")
        (if long
            (json.dumps
              (dfor #(k v) (.items attributes)
                    :if v
                    k v)
              :indent 4)
            f"{character.name} - {character.appearance}"))
      ""))

(defn describe-at [coords [long False] [exclude None]]
  "A string describing any characters at a location."
  (let [all-at (get-at coords :exclude exclude)]
    (if all-at
        (.join "\n" ["The following characters (and nobody else) are here with you:"
                     #* (map (fn [c] (describe c :long long)) all-at)])
        "")))
  
(defn list-at-str [coords [exclude None]]
  "Give the names (as prose) of who is here."
  (let [character-names-here (lfor c (get-at coords :exclude exclude) c.name)
        n (len character-names-here)]
    (cond (= n 0) ""
          (= n 1) f"{(first character-names-here)} is here."
          :else f"{(.join ", " (butlast character-names-here))} and {(last character-names-here)} are here.")))

(defn get-at [coords [exclude None]]
  "List of characters at a location, excluding player.
  This loops over all characters."
  (let [cs (get-characters)]
    (if cs
      (lfor character cs
            :if (and (is-at coords character.coords)
                     (not (= character.name exclude)))
            character)
      []))) 

(defn move [character coords]
  "Just set a location."
  (update-character character :coords coords)
  coords)

(defn :async check-score-increment [character messages]
  "Has the character done something worthwhile?"
  (let [setting f"Story setting: {world}"
        result (await
                 (character-score
                   messages
                   :name character.name
                   :objective character.objective))
        verdict (or (similar result "yes")
                    (in "yes" (.lower result)))]
    (log.info f"{verdict}")
    verdict))

(defn :async develop-json [character messages]
  "Develop a character's attributes based on the dialogue."
  (let [nearby-places (.join ", " (await (place.nearby character.coords :name True)))
        details (extract-json-unwrap
                  (await
                    (character-develop-json
                      messages
                      #** (._asdict character)
                      :world world
                      :place-name (place.name character.coords)
                      :nearby-places nearby-places)))
        ;; inserting invalid keys will fail
        clean-details (dfor [k v] (.items details)
                        :if (in k (._asdict default-character))
                        k v)]
    (try
      (let [objective (word-chars (.pop clean-details "objective" ""))
            new-score (if (await (check-score-increment character messages))
                        character.score
                        (inc character.score))]
        (log.info f"{character.name}")
        (.pop clean-details "name" None) ; leave the name alone
        (remember character (.pop clean-details "new_memory" ""))
        (update-character character
                          :score new-score
                          :objective objective
                          #** clean-details))
      (except [e [Exception]]
        ; generating to template sometimes fails 
        (log.error "Bad character" e)
        (log.error details)))))

(defn remember [character new-memory]
  "Commit memory to vector db."
  (log.info f"{character.name} {new-memory}")
  (let [mem-class (re.search r"\[(\w+)\]" new-memory)
        mem-point (re.search r"\][- ]*([\w ,.']+)" new-memory)]
    (when (and mem-class
               mem-point
               ; ignore failed memories
               (not (in "significant or poignant thing worth remembering from this dialogue" new-memory))
               (not (in "[forgettable]" new-memory))
               (not (in "[classification]" new-memory)))
      (memory_facts.add (character-key character.name)
                  {"character" character.name
                   "coords" (str character.coords)
                   "place" (place.name character.coords)
                   "time" f"{(time):015.2f}"
                   "classification" (.lower (first (.groups mem-class)))}
                  (first (.groups mem-point))))))

(defn recall [character text [n 6] [class "significant"]]
  "Recall memories of a character. Pass `class=None` for all memories."
  (first
    (:documents (memory_facts.query (character-key character.name)
                              :text text
                              :n n
                              :where (when class {"classification" class})))))

(defn :async get-new [messages player]
  "Are any new or existing characters mentioned in the messages?
  They will appear at the player's location."
  (let [place-name (place.name player.coords)
        disallowed (+ [player.name place-name] banned-names)
        char-list (await (character-mentioned
                           (cut messages -6 None)
                           :world world
                           :place-name place-name))
        filtered-char-list (->> char-list
                                 (debullet)
                                 (.split :sep "\n")
                                 (map capwords)
                                 (sieve)
                                 (filter (fn [x] (not (fuzzy-in x disallowed))))
                                 (filter (fn [x] (< (len (.split x)) 3))) ; exclude long rambling non-names
                                 (filter is-valid-key)
                                 (list))]
    (log.info f"{filtered-char-list}")
    (cut filtered-char-list 3)))


;; * NPC Backstory Generation
;; -----------------------------------------------------------------------------

(defn :async generate-backstory [char-name existing-chars place-name]
  "Generate a rich backstory for an NPC with connections to existing characters."
  (let [existing-names (.join ", " (lfor c existing-chars c.name))
        prompt (+ "You are a character designer for a text adventure game.\n"
                  "Generate a rich backstory for a new NPC.\n\n"
                  f"NPC name: {char-name}\n"
                  f"Location: {place-name}\n"
                  f"Existing characters nearby: {existing-names}\n\n"
                  "Create a backstory that:\n"
                  "- Explains why they are here\n"
                  "- Connects them to at least one existing character (if any)\n"
                  "- Gives them a secret or hidden motivation\n"
                  "- Fits the world theme\n\n"
                  "Reply with JSON only:\n"
                  "{\"backstory\": \"...\", \"secret\": \"...\", \"connections\": [{\"name\": \"...\", \"relationship\": \"...\"}], \"hidden_objective\": \"...\"}")]
    (try
      (let [response (await (respond [(system prompt)] :provider "backend"))
            result (extract-json-unwrap response)]
        (when result
          (log.info f"Generated backstory for {char-name}")
          result))
      (except [Exception]
        None))))

(defn :async enhance-with-backstory [char existing-chars]
  "Enhance a character with a generated backstory."
  (let [place (get-place char.coords)
        place-name (if place place.name "somewhere")
        backstory (await (generate-backstory char.name existing-chars place-name))]
    (when backstory
      ;; Update character with backstory info
      (let [enhanced-backstory (+ (or char.backstory "") " " (or (:backstory backstory) ""))
            enhanced-objective (or (:hidden_objective backstory) char.objective)]
        (update-character char
                          :backstory enhanced-backstory
                          :objective enhanced-objective)
        ;; Store connections as facts
        (when (:connections backstory)
          (for [conn (:connections backstory)]
            (let [other-name (:name conn)
                  relationship (:relationship conn)]
              (when (and other-name relationship)
                (import chasm_engine.facts [add-fact])
                (add-fact char.name "knows" other-name
                          :location place-name
                          :classification "significant")
                (add-fact char.name "relationship" relationship
                          :location place-name
                          :classification "significant")))))
        ;; Store secret as a fact
        (when (:secret backstory)
          (import chasm_engine.facts [add-fact])
          (add-fact char.name "has-secret" (:secret backstory)
                    :location place-name
                    :classification "major"))
        (get-character char.name)))))
