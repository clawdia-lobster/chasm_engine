"
The game engine. Handles interaction between Place, Item, Character, Event and narrative.
The engine logic is expected to handle many players.
"

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])
(import hyrule.collections [assoc])

(require hyjinx.macros [prepend append])

(import time [time])
(import asyncio)

(import chasm-engine [log])

(import chasm-engine.lib *)
(import chasm-engine [place item character plot quest world_author memory_facts intent world_delta])
(import chasm-engine.types [Coords])
(import chasm-engine.constants [character-density item-density compass-directions])
(import chasm-engine.state [world world-name
                            characters
                            accounts
                            len-items
                            get-place len-places
                            random-coords
                            get-character update-character delete-character len-characters
                            get-account update-account get-accounts
                            get-narrative set-narrative])

(import chasm-engine.chat [ChatError
                           respond
                           msg->dlg msgs->dlg
                           truncate standard-roles
                           token-length
                           msg user assistant system])

(require chasm-engine.instructions [deftemplate def-fill-template])


;; * Turn-level context cache with per-player locking
;; -----------------------------------------------------------------------------
;; The cache stores turn-level context (location, player state, memories) to avoid
;; recomputation. Per-player locks prevent race conditions when the same player
;; sends concurrent requests (e.g., rapid retries, multiple tabs).

(setv _context-cache {})
(setv _player-locks {})

(defn get-player-lock [player-name]
  "Get or create an asyncio.Lock for a specific player."
  (global _player-locks)
  (unless (in player-name _player-locks)
    (assoc _player-locks player-name (asyncio.Lock)))
  (.get _player-locks player-name))

(defn cleanup-player-lock [player-name]
  "Remove a player's lock (call on disconnect)."
  (global _player-locks)
  (.pop _player-locks player-name None))

(defn invalidate-context-cache [player-name]
  "Invalidate cached context for a player."
  (global _context-cache)
  (.pop _context-cache player-name None))

(defn get-cached-context [player-name key]
  "Get cached value for player."
  (let [player-cache (.get _context-cache player-name {})]
    (.get player-cache key)))

(defn set-cached-context [player-name key value]
  "Set cached value for player."
  (global _context-cache)
  (unless (in player-name _context-cache)
    (assoc _context-cache player-name {}))
  (assoc (.get _context-cache player-name) key value)
  value)


(defclass EngineError [RuntimeError])

(setv develop-queue (set))

(def-fill-template hint instruction system-prompt)
(deftemplate narrative)

(defn info [content]
  (msg "info" content))

(defn error [content]
  (msg "error" content))

;; Development functions (extracted from develop)
;; -----------------------------------------------------------------------------

(defn :async extract-plot-points [messages player]
  "Extract and record plot points from recent messages."
  (await (plot.extract-point messages player)))

(defn :async check-quest-progress [player-name messages]
  "Check and advance quest progress based on recent messages."
  (await (quest.try-advance player-name messages)))

(defn :async run-world-author [messages]
  "Run world author cycle to potentially add new content."
  (await (world_author.author-cycle (world_author.summarise-narrative messages))))

(defn :async develop-characters-at [coords messages]
  "Develop all characters at the given coordinates."
  (let [characters-here (character.get-at coords)]
    (for [c characters-here]
      (await (character.develop-json c messages)))))

(defn :async spawn-npcs-if-needed [player messages]
  "Spawn NPCs at player location if player is alone and narrative mentions new characters."
  (let [characters-here (character.get-at player.coords)]
    (when (= (len characters-here) 1)
      (for [c-name (await (character.get-new messages player))]
        (let [c (get-character c-name)]
          (if (and c c.npc)
            (character.move c player.coords)
            (await (character.spawn :name c-name :coords player.coords))))))))

(defn :async develop-player [player-name]
  "Develop a single player: plot, quests, world, characters, NPCs."
  (let [player (get-character player-name)
        messages (get-narrative player-name)
        recent-messages (cut messages -4 None)]
    (when (and player messages)
      (await (extract-plot-points recent-messages player))
      (await (check-quest-progress player-name recent-messages))
      (await (run-world-author recent-messages))
      (await (develop-characters-at player.coords recent-messages))
      (await (spawn-npcs-if-needed player recent-messages)))))

;; API functions
;; -----------------------------------------------------------------------------

;; Main engine loop
;; -----------------------------------------------------------------------------

(defn :async print-map [coords [compass False]]
  "Get your bearings."
  (if compass
      (let [cx (:x coords)
            cy (:y coords)
            accessible-places (await (place.accessible coords :min-places 4))]
        (jn
          (lfor dy [1 0 -1]
                (.join ""
                       (lfor dx [-1 0 1]
                         :setv nearby-place (place.get-offset-place coords dx dy)
                         (cond (in nearby-place accessible-places) "• "
                               (= 0 (+ (abs dx) (abs dy))) "+ "
                               :else "  "))))))
      (let [rooms (place.rooms coords :as-string False)]
        (if rooms
          (jnn
            [f"***{(place.name coords)}***"
             f"Rooms: {(.join ", " rooms)}"
             f"*{(await (place.nearby-str coords))}*"])
          (jnn
            [f"***{(place.name coords)}***"
             f"*{(await (place.nearby-str coords))}*"])))))

(defn :async payload [narrative result player-name [increment-turn True]]
  "What the client expects."
  (let [player (get-character player-name)
        account (get-account player-name)
        turns (if increment-turn
                (inc (if account (:turns account 0) 0))
                (if account (:turns account 0) 0))]
    (when increment-turn
      (update-account player-name :turns turns))
    (if (not player)
        {"error" f"Player not found: {player-name}"}
        {"narrative" narrative
         "result" result
         "player" {"name" player.name
                   "objective" player.objective
                   "score" player.score
                   "turns" turns
                   "health" player.health
                   "coords" player.coords
                   "compass" (await (print-map player.coords :compass True))
                   "inventory" (lfor i (item.inventory player) i.name)
                   "place" (place.name player.coords)}
         "world" world-name
         "coords" player.coords})))

(defn null [#* args #** kwargs] ; -> response
  "Server no-op."
  {"error" "No valid engine function specified."})

(defn status [#* args #** kwargs] ; -> response
  "Server status."
  (import chasm_engine.status [get-status])
  {"result" {"status" (get-status)}})

(defn motd [#* args #** kwargs] ; -> response
  "Server MOTD."
  {"result"
   (info
     (or (config "motd")
         (slurp (or (+ (os.path.dirname __file__) "/motd.md")
                    "chasm/motd.md"))))})

(defn :async spawn-player [player-name #* args #** kwargs] ; -> response
  "Start the game. Make sure there's a recent message. Return the whole visible state.
  New players spawn at (0,0), returning players resume at their saved location."
  (try
    (await (place.extend-map (Coords 0 0)))
    (let [; Check if player already exists (returning player)
          existing-char (get-character player-name)
          ; Use existing coords for returning players, (0,0) for new players
          coords (if existing-char existing-char.coords (Coords 0 0))
          player (await (character.spawn :name player-name :loaded kwargs :coords coords))]
      (if (not player)
          (error f"Failed to spawn player: {player-name}")
          (let [narrative (or (get-narrative player-name)
                              (set-narrative [(user f"****") (assistant (await (describe-place player)))] player-name))]
            (update-character player :npc False)
            (await (place.extend-map coords))
            (await (payload narrative (last narrative) player.name :increment-turn False)))))
    (except [err [Exception]]
      (log.error "spawn-player failed" :exception err)
      ;; Cleanup partial state
      (when (get-character player-name)
        (delete-character player-name))
      (error f"Engine error: {(repr err)}"))))

(defn help-str []
  "Return the help string."
  (slurp (or (+ (os.path.dirname __file__) "/help.md")
             "chasm/help.md")))

(defn quest-status [player-name]
  "Return a formatted string of quest status for a player."
  (let [active    (quest.active-quests player-name)
        done-ids  (quest.completed-quest-ids player-name)
        available (quest.available-for player-name)
        lines     []]
    (when active
      (.append lines "Active quests:")
      (for [p active]
        (let [quest-id (:quest_id p None)
              q      (when quest-id (quest.get-quest quest-id))
              idx    (:stage_index p 0)
              stages (if q (:stages q []) [])
              stage  (when (and q (< idx (len stages))) (get stages idx))]
          (when q
            (.append lines (+ "  " (:name q "Unknown")))
            (.append lines (if stage
                               (+ "    -> " (:description stage ""))
                               "    -> Complete!"))))))
    (when done-ids
      (.append lines "Completed:")
      (for [qid done-ids]
        (.append lines (+ "  [x] " qid))))
    (when available
      (.append lines "Available:")
      (for [q available]
        (.append lines (+ "  [?] " (:name q "?")))))
    (if lines
        (.join "
" lines)
        "You have no quests. Explore the world and speak to characters.")))

(defn online [[long False] [seconds 600]]
  "List of player-characters online since (600) seconds ago."
  ; Iterate accounts.items() so we get the name from the dict key,
  ; since older accounts may not store :name in the value dict.
  (let [chars-online (lfor [player-key a] (.items accounts)
                            :if (< (- (time) (float (:last-verified a Inf))) seconds)
                            (or (:name a None) player-key))]
    (if long
        (if chars-online
            (+ (.join ", " chars-online) ".")
            "Nobody online.")
        chars-online)))

(defn :async move-characters [messages]
  "Move characters to their targets."
  (for [c (map get-character characters)]
    (when c.npc ; don't randomly move a player, only NPCs
      ; don't test for accessibility
      (let [ps (await (place.nearby c.coords :place True :list-inaccessible True))
            pnames (lfor p ps p.name)
            pname (fuzzy-in c.destination pnames)]
        (when (and pname
                   (dice 16)
                   ; don't move them if they've been mentioned in the last move or two
                   (not (in c.name (str (cut messages -4 None)))))
          (let [p (first (lfor p ps :if (= p.name pname) p))]
            (log.info f"{c.name} -> {p.name}")
            (character.move c p.coords)))))))

(defn :async parse [player-name line #* args #** kwargs] ; -> response
  "Process the player's input and return the whole visible state.
  Uses per-player lock to prevent race conditions from concurrent requests."
  (log.info f"{player-name}: {line}")
  ;; Acquire per-player lock to prevent concurrent request race conditions
  (let [lock (get-player-lock player-name)]
    (async-with [lock]
      ;; Invalidate context cache at start of each turn
      (invalidate-context-cache player-name)
      (let [_player (or (get-character player-name) (await (character.spawn :name player-name :loaded kwargs)))
            player (update-character _player :npc False)
            narrative (get-narrative player-name)
            messages (truncate (standard-roles narrative)
                               :spare-length (+ (token-length world) (config "max_tokens"))) 
            user-msg (user line)
            result (try
                     (cond
                       ;; Fast path: explicit commands (starting with /)
                       (is-quit line) (do (update-character player :npc True) (msg "QUIT" "QUIT"))
                       (.startswith line "/help") (info (help-str))
                       (.startswith line "/hint") (info (await (hint messages player line)))
                       (.startswith line "/hist") (msg "history" "The story so far...")
                       (.startswith line "/map") (info (await (print-map player.coords)))
                       (.startswith line "/exits") (msg (await (print-map player.coords)))
                       (.startswith line "/online") (info (online :long True))
                       (.startswith line "/quests") (info (quest-status player.name))
                       (.startswith line "/take") (info (item.fuzzy-claim (parse-take line) player))
                       (.startswith line "/drop") (info (item.fuzzy-drop (parse-drop line) player))
                       (.startswith line "/give") (info (item.fuzzy-give player #* (parse-give line)))
                       (.startswith line "/l") (assistant (await (place.describe player :messages messages :length "short")))
                       (.startswith line "/go") (assistant (await (move (append user-msg messages) player)))
                       ;; Intent-based path for natural language
                       (is-command line) (let [u-msg (user (get line (slice 1 None)))]
                                           (assistant (await (narrate (append u-msg messages) player))))
                       ;; Natural language: use intent classification
                       line (await (parse-with-intent line player messages)))
                     (except [err [ChatError]]
                       (log.error "Empty reply" :exception err)
                       (info f"There was no reply."))
                     (except [err [Exception]]
                       (log.error "Engine error" :exception err)
                       (error f"Engine error: {(repr err)}")))]
        ; info, error do not extend narrative.
        (when (and result (= (:role result) "assistant"))
          (.extend narrative [user-msg result])
          (set-narrative (cut narrative -100 None) player-name) ; keep just last 100 messages
          (await (move-characters narrative)))
        (log.debug f"-> {result}")
        ; always return the most recent state
        (await (payload narrative result player-name))))))

(defn :async parse-stream [player-name line websocket send-notification #* args #** kwargs]
  "Process player input with streaming narrative. Yields chunks via callback.
  Returns final payload when complete.
  Uses per-player lock to prevent race conditions from concurrent requests."
  (log.info f"{player-name}: {line} (streaming)")
  ;; Acquire per-player lock to prevent concurrent request race conditions
  (let [lock (get-player-lock player-name)]
    (async-with [lock]
      (invalidate-context-cache player-name)
      (let [_player (or (get-character player-name) (await (character.spawn :name player-name :loaded kwargs)))
            player (update-character _player :npc False)
            narrative (get-narrative player-name)
            messages (truncate (standard-roles narrative)
                               :spare-length (+ (token-length world) (config "max_tokens")))
            user-msg (user line)
            ; Check if this is a narrative command (streaming applicable)
            is-narrative (and line
                             (not (is-quit line))
                             (not (parse-take line))
                             (not (parse-drop line))
                             (not (parse-give line))
                             (not (.startswith line "/"))
                             (not (is-look line))
                             (not (parse-go line)))]
        (if is-narrative
          ; Streaming path for narrative commands
          (do
            (let [full-text []]
              (async-for [chunk done (narrate-stream (append user-msg messages) player)]
                (if done
                  ; Final chunk - send complete notification
                  (await (send-notification "stream_complete" {"text" chunk}))
                  ; Intermediate chunk
                  (do
                    (.append full-text chunk)
                    (await (send-notification "stream_chunk" {"text" chunk})))))
              ; Update narrative with full text
              (let [result (assistant (.join "" full-text))]
                (.extend narrative [user-msg result])
                (set-narrative (cut narrative -100 None) player-name)
                (await (move-characters narrative))
                (await (payload narrative result player-name)))))
          ; Non-streaming path for other commands
          (await (parse player-name line #* args #** kwargs)))))))
      
;; World functions (background tasks)
;; -----------------------------------------------------------------------------

(defn :async init []
  "When first starting the engine, create a few places to go."
  (quest.init)
  (for [x (range -4 5)
        y (range -4 5)]
    (await (place.extend-map (Coords x y)))))

(defn :async extend-world [] ; -> place or None
  "Make sure the map covers all characters. Add items, new characters if necessary.
  This function does not use vdb memory so should be thread-safe."
  (for [n (.keys characters)]
    (let [c (get-character n)
          coords c.coords]
      (unless c.npc
        (await (place.extend-map coords))))))

(defn :async spawn-items [] ; -> item or None
  "Spawn items when needed at existing places."
  (let [coords (random-coords)]
    (when (> (* item-density (len-places))
             (len-items))
      (log.info f"New item at {coords}")
      (await (item.spawn coords)))))
  
(defn :async spawn-characters [] ; -> char or None
  "Spawn characters when needed at existing places."
  (let [coords (random-coords)]
    (unless (character.get-at coords)
      (when (> (* character-density (len-places))
               (len-characters))
        (log.info f"New character at {coords}")
        (await (character.spawn :name None :coords coords))))))
  
(defn :async develop [] ; -> char or None
  "Process the development queue: plot, quests, world, characters, NPCs.
  Note: Uses global develop-queue, not thread-safe."
  (when develop-queue
    (log.info f"queue: {develop-queue}")
    (let [player-name (.pop develop-queue)]
      (await (develop-player player-name)))))

(defn set-offline-players []
  "Set characters not accessed in last hour to NPC."
  ; TODO: maybe this is server logic, not engine?
  ; Iterate accounts.items() so we get the name from the dict key,
  ; since older accounts may not store :name in the value dict.
  (for [[player-key a] (.items accounts)]
    (let [dt (- (time) (:last-accessed a Inf))
          char (get-character (or (:name a None) player-key))]
      (when (and char (> (abs dt) 3600))
        (update-character char :npc True)))))

;; Parser functions
;; -----------------------------------------------------------------------------

(defn is-command [line]
  (.startswith line "/"))

(defn is-quit [line]
  (or (.startswith line "/q")
      (.startswith line "/exit")))

(defn is-look [line]
  (.startswith line "/l"))

(defn is-hist [line]
  (.startswith line "/hist"))

(defn parse-go [line] ; -> direction or None
  "Are you trying to go to a new direction?"
  (let [[_cmd _ dirn] (.partition line " ")
        cmd (.lower _cmd)]
    (cond (= cmd "/go") (re.sub "^to " "" (sstrip dirn))
          (= cmd "go") (re.sub "^to " "" (sstrip dirn))
          (and (is-command cmd) (in (rest cmd) compass-directions)) (rest (sstrip cmd)) ; '/sw' etc
          (in cmd compass-directions) (sstrip cmd)))) ; plain 'east' etc

(defn parse-take [line] ; -> obj or None
  "Are you trying to pick up an item?"
  (let [[_cmd _ obj] (.partition line " ")
        cmd (.lower _cmd)]
    (when (.startswith cmd "/take") (sstrip obj))))

(defn parse-drop [line] ; -> item or None
  "Are you trying to drop an item?"
  (let [[_cmd _ obj] (.partition line " ")
        cmd (.lower _cmd)]
    (when (.startswith cmd "/drop") (sstrip obj))))

(defn parse-give [line] ; -> [item character] or None
  "Are you trying to give an item?"
  (let [[cmd _ obj-recip] (.partition line " ")
        cmd (.lower cmd)
        [obj _ recipient] (.partition obj-recip " to ")]
    (when (.startswith cmd "/give") [(sstrip obj) (get-character (sstrip recipient))])))

(defn parse-talk [line] ; -> string or None
  "Are you trying to talk to another character?"
  (let [[_cmd _ char] (.partition line " ")
        cmd (.lower _cmd)]
    (when (.startswith cmd "/talk") (sstrip char))))

(defn :async parse-with-intent [line player messages]
  "Parse natural language using LLM intent classification.
  Returns result dict suitable for engine processing."
  (let [context {"location" (place.name player.coords)
                 "items-here" (item.describe-at player.coords)
                 "characters-here" (character.describe-at player.coords :exclude player.name)
                 "nearby" (await (place.nearby-str player.coords))}
        parsed (await (intent.parse-command line player context))
        action (:action parsed "say")]
    (match action
      "move" (let [dirn (:direction parsed)]
               (if dirn
                   (assistant (await (move (append (user line) messages) player)))
                   (info "Where do you want to go?")))
      "take" (let [obj (:item parsed)]
               (if obj
                   (info (item.fuzzy-claim obj player))
                   (info "What do you want to take?")))
      "drop" (let [obj (:item parsed)]
                (if obj
                    (info (item.fuzzy-drop obj player))
                    (info "What do you want to drop?")))
      "give" (let [obj (:item parsed)
                    recip (:recipient parsed)]
               (if (and obj recip)
                   (info (item.fuzzy-give player obj recip))
                   (info "Give what to whom?")))
      "look" (assistant (await (place.describe player :messages messages :length "short")))
      "help" (info (help-str))
      "quests" (info (quest-status player.name))
      "quit" (do (update-character player :npc True) (msg "QUIT" "QUIT"))
      ;; Default: narrate
      _ (assistant (await (narrate (append (user line) messages) player))))))

;; -----------------------------------------------------------------------------

(defn talk-status [dialogue character]
  "Show chat partner, place, tokens used."
  (status-line (.join " | "
                      [f"[italic blue]{world-name}[/italic blue]"
                       f"[italic cyan]Talking to {character.name}[/italic cyan]"
                       f"{(:x character.coords)} {(:y character.coords)}"
                       f"{(+ (token-length world) (token-length dialogue))} tkns"])))

;; functions -> msg or None (with output)
;; -----------------------------------------------------------------------------

(defn :async describe-place [char]
  "Short context-free description of a place and its occupants."
  ; don't include context so we force the narrative location to change.
  (let [description (await (place.describe char))
        chars-here (character.list-at-str char.coords :exclude char.name)]
    (jnn [description chars-here])))

(defn :async move [messages player] ; -> msg or None
  "Move the player. Describe. `dirn` may be a compass direction like 'n' or a place name like 'Small House'"
  (let [user-msg (last messages)
        line (:content user-msg)
        dirn (parse-go line)
        new-coords (await (place.go dirn player.coords))
        here (get-place player.coords)]
    (log.info f"{player.name} to {dirn} {player.coords} -> {new-coords}")
    (cond
      new-coords (do (character.move player new-coords)
                     ; and make sure to pass character with updated position to place.describe
                     (await (describe-place (get-character player.name))))
      (fuzzy-in dirn here.rooms) (await (narrate messages player)) ; going to a room
      :else (choice [f"You can't go to '{dirn}'."
                     f"Is '{dirn}' where you meant?"
                     f"I'm not sure '{dirn}' is a place that you can go to."
                     f"'{dirn}' doesn't seem to be a location you can go."
                     f"'{dirn}' isn't accessible from here. Try somewhere else."]))))

(defn location-context [character]
  "Fill in location context templates with current information."
  (let [cached (get-cached-context character.name "location")]
    (or cached
        (set-cached-context character.name "location"
          (plot.context "location"
            :items-here (item.describe-at character.coords)
            :characters (character.describe-at character.coords :long False))))))
  
(defn npc-context [character]
  "Fill in npc context templates with current information."
  (plot.context "npc"
    :player character.name
    :location (place.name character.coords)
    :objective character.objective
    :inventory (item.describe-inventory character)))
  
(defn :async player-context [player]
  "Fill in player context templates with current information. Cached per turn."
  (let [cached (get-cached-context player.name "player")]
    (or cached
        (let [quest-ctx (quest.quest-context player.name)
              result (plot.context "player"
                        :player player.name
                        :items-here (item.describe-at player.coords)
                        :location (place.name player.coords)
                        :locations (await (place.nearby-str player.coords))
                        :rooms (place.rooms player.coords)
                        :character-descriptions-here (character.describe-at player.coords :long True)
                        :objective player.objective
                        :inventory (item.describe-inventory player)
                        :quests (or quest-ctx ""))]
          (set-cached-context player.name "player" result)))))
  
(defn memories [player [n 6]]
  "Returns (as a string) top memories for all characters at the player's location. Cached per turn."
  (let [cached (get-cached-context player.name "memories")]
    (or cached
        (set-cached-context player.name "memories"
          (let [characters-here (character.get-at player.coords)
                character-names-here (lfor c characters-here c.name)
                plot-points (jn (plot.recall-points (plot.news)))
                place-name (place.name player.coords)]
            (jnn
              (lfor c (character.get-at player.coords)
                (let [s (jn [c.objective
                             plot-points
                             #* character-names-here
                             (plot.news)])
                      mem (bullet (character.recall c s :n n))
                      ; Include knowledge from facts system
                      knowledge (memory-facts.knowledge-about c.name place-name :n 3)]
                  (jnn [(if mem f"{c.name} recalls the memories:\n{mem}." "")
                        (if knowledge knowledge "")]))))))))
  
(defn :async hint [messages player line]
  "Offer a hint to aid the player's progress, in light of a question."
  (-> messages
    (truncate)
    (hint-instruction
      :context (jnn (await (player-context player))
                    (location-context player))
      :player player.name
      :question line
      :provider "narrator")
    (await)
    (trim-prose)))

(defn :async narrate [messages player]
  "Narrate the story, in the fictional universe.
  Also extracts and applies world state changes from the narrative."
  (let [here (. (get-place player.coords) name) ; a place
        ; Include what the narrator knows about the player for context-aware responses
        narrator-knowledge (memory-facts.knowledge-about "narrator" player.name :n 5)
        context (jnn [(jn (plot.recall-points (plot.news)))
                      (await (player-context player))
                      (memories player)
                      narrator-knowledge])
        narrative-prompt (narrative "system-prompt"
                           :player player.name
                           :context context
                           :here here)]
    (.add develop-queue player.name) ; add the player to the development queue
    (let [prose (-> (-> [(system narrative-prompt) #* messages]
                        (truncate))
                    (respond :provider "narrator")
                    (await)
                    (trim-prose)
                    (or ""))]
      ; Extract and apply world delta from narrative
      (try
        (let [delta (await (world_delta.extract-delta prose player))
              result (await (world_delta.process-delta delta prose))
              success (.get result "success")
              applied (.get result "applied")
              errors (.get result "errors")]
          (when (not success)
            (log.warn f"Delta validation failed: {errors}"))
          (when (> applied 0)
            (log.info f"Applied {applied} world changes")))
        (except [e Exception]
          (log.error f"Delta processing error: {e}")))
      prose)))

(defn :async narrate-stream [messages player]
  "Stream narrative chunks as they arrive.
  Yields (chunk, done) tuples where done=True on final chunk.
  Also extracts and applies world state changes from the narrative."
  (let [here (. (get-place player.coords) name)
        ; Include what the narrator knows about the player for context-aware responses
        narrator-knowledge (memory-facts.knowledge-about "narrator" player.name :n 5)
        context (jnn [(jn (plot.recall-points (plot.news)))
                      (await (player-context player))
                      (memories player)
                      narrator-knowledge])
        narrative-prompt (narrative "system-prompt"
                           :player player.name
                           :context context
                           :here here)]
    (.add develop-queue player.name)
    (let [stream (await (respond-stream
                         (-> [(system narrative-prompt) #* messages]
                             (truncate))
                         :provider "narrator"))
          content []]
      (async-for [chunk stream]
        (when (and chunk (first chunk.choices))
          (let [delta (. (first chunk.choices) delta)]
            (when delta.content
              (.append content delta.content)
              (yield #(delta.content False))))))
      ;; Final chunk with trimmed result
      (let [full-text (trim-prose (.join "" content))]
        ; Extract and apply world delta from narrative
        (try
          (let [delta (await (world_delta.extract-delta full-text player))
                result (await (world_delta.process-delta delta full-text))
                success (.get result "success")
                applied (.get result "applied")
                errors (.get result "errors")]
            (when (not success)
              (log.warn f"Delta validation failed: {errors}"))
            (when (> applied 0)
              (log.info f"Applied {applied} world changes")))
          (except [e Exception]
            (log.error f"Delta processing error: {e}")))
        (yield #(full-text True))))))

(defn consume-item [messages player item]
  "The character changes the narrative and the item based on the usage.
  Rewrite the item description based on its usage.")
  ; FIXME not written
  ; How is it being used?
  ; What happens to the item?

;; Main engine loop
;; -----------------------------------------------------------------------------

(defn spy [char-name]
  (-> (get-character char-name)
      (._asdict) 
      (json.dumps :indent 4)))
)