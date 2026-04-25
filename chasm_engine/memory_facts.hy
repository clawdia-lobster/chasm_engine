"
Memory compatibility layer using SQLite FTS.
Replaces ChromaDB with structured facts + full-text search.
"

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])

(import time [time])
(import json)

(import chasm_engine [log])
(import chasm_engine.lib *)
(import chasm_engine.facts [add-fact search-facts query-facts recent-facts])


;; -----------------------------------------------------------------------------

(defclass MemoryError [Exception])

;; Compatibility layer: the old memory API backed by facts

(defn add [name metadata text]
  "Add a memory as a structured fact.
  
  Args:
    name: Source identifier (character name or 'narrator')
    metadata: Dict with optional keys (classification, place, coords, time, characters)
    text: The memory text to store
  "
  (let [classification (:classification metadata "memory")
        place (:place metadata None)
        coords (:coords metadata None)
        source-type (if (= name "narrator") "narrator" "character")]
    (add-fact name "remembers" text
              :source name
              :source-type source-type
              :location place
              :coords coords
              :fact-type classification
              :confidence 1.0)
    (log.debug f"memory.add: {name} -> {(cut text 0 50)}...")))


(defn query [name text [n 5] [where None]]
  "Search memories using FTS.
  
  Args:
    name: Source identifier (character name or 'narrator')
    text: Search query
    n: Max results
    where: Optional metadata filter (currently only 'classification' supported)
  
  Returns dict with 'documents' key containing list of matching texts.
  "
  (let [classification (when where (:classification where None))
        results (search-facts text :n n :source name)
        ;; Filter by classification if specified
        filtered (if classification
                    (lfor r results
                          :if (= (:fact-type r None) classification)
                          r)
                    results)
        ;; Extract just the text (object field contains the memory)
        documents (lfor r filtered (:object r))]
    {"documents" [documents]}))


(defn recent [name [n 5] [where None]]
  "Get recent memories for a source.
  
  Args:
    name: Source identifier
    n: Max results
    where: Optional metadata filter
  
  Returns dict with 'documents' key.
  "
  (let [classification (when where (:classification where None))
        results (query-facts :source name :limit (* n 2))
        ;; Filter by classification if specified
        filtered (if classification
                    (lfor r results
                          :if (= (:fact-type r None) classification)
                          r)
                    results)
        ;; Sort by timestamp descending, take n
        sorted-results (cut (sorted filtered :key (fn [r] (:timestamp r 0)) :reverse True) 0 n)
        documents (lfor r sorted-results (:object r))]
    {"documents" documents}))


;; Keep these for compatibility with old code that might call them directly

(defn peek [name]
  "Compatibility stub - returns empty dict."
  {})


(defn collection [name]
  "Compatibility stub - returns None."
  None)
