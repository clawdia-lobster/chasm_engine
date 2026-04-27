"
Develop the plot / world events

- extract plot points from the messages
- summarise into
  * new important world facts
  * plot points
  * temporal story development
- global quests / mysteries (not character ones)
"

(require hyjinx.macros [prepend append])

(import time [time])
(import datetime [datetime timezone])
        
(import chasm_engine.lib *)
(import chasm_engine.types *)

(import chasm_engine [log])

(import chasm_engine [place character])
(import chasm_engine.facts [add-fact query-facts recent-facts])
(import chasm_engine.state [world])
(import chasm_engine.chat [truncate respond
                           system user
                           msgs->dlg])

(require chasm-engine.instructions [deftemplate def-fill-template])


(deftemplate context)
(def-fill-template plot point system)

(defn news []
 "Up-to-date info about the universe."
 (.join "\n"
        [f"It is {(.strftime (datetime.now timezone.utc) "%H:%M, %a %d %h")}."
         #* (recent-facts :fact-type "major" :limit 5)]))

(defn recent [[n 5] [where None]]
  "Return `n` recent memories filtered by `where` (e.g. `{\"classification\" \"major\"}"
  (let [results (query-facts :source "narrator" :limit (* n 2))
        ;; Filter by classification if specified
        filtered (if where
                    (lfor r results
                          :if (= (:fact-type r None) (:classification where None))
                          r)
                    results)
        ;; Sort by timestamp descending, take n
        sorted-results (cut (sorted filtered :key (fn [r] (:timestamp r 0)) :reverse True) 0 n)
        ;; Extract just the text (object field contains the memory)
        documents (lfor r sorted-results (:object r))]
    documents))

(defn recall-points [text [n 6] [class "major"]]
  "Recall the important plot points relating to `text`
  (the player, story thread, characters present, etc.)."
  (let [results (query-facts :source "narrator"
                             :text text
                             :limit n)
        ;; Filter by classification if specified
        filtered (if class
                    (lfor r results
                          :if (= (:fact-type r None) class)
                          r)
                    results)
        ;; Extract just the text (object field contains the memory)
        documents (lfor r filtered (:object r))]
    documents))

(defn :async extract-point [messages player]
  "Scan the recent conversation for plot points and insert them into the record."
  (let [msgs (truncate (cut messages -6 None) :spare-length 1000)
        narrative (format-msgs (msgs->dlg "narrative" player.name msgs))
        response (await (plot-point
                          :world world
                          :narrative narrative))
        sanitised (.replace response "\n" " ")
        classification (re.search r"\[(\w+)\]" sanitised)
        point (re.search r"\][- ]*([\w ,.'-]+)" sanitised)]
    (when (and point classification)
      (log.info f"{(first (classification.groups))}")
      (log.info f"{(first (point.groups))}")
      (let [chars-here (lfor c (append player (character.get-at player.coords)) c.name)
            meta {"time" f"{(time):015.2f}"
                  "place" (place.name player.coords)
                  "coords" (str player.coords)
                  "characters" (.join ", " chars-here)
                  "classification" (.lower (first (classification.groups)))}
            points (point.groups)]
        (for [pt points]
          (add-fact "narrator" "plot-point" pt
                    :source "narrator"
                    :source-type "narrator"
                    :location (:place meta)
                    :coords (:coords meta)
                    :fact-type (:classification meta)
                    :confidence 1.0
                    :origin-type "plot-extraction"
                    :origin-data meta))))))

