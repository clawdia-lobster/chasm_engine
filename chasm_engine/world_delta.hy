"""
World Delta System - Persistent world mutations with validation.

The narrator generates prose + structured delta as co-products.
The engine validates and applies changes, acting as the physics
that constrains the narrator's storytelling.
"""

(require hyrule.argmove [-> ->>])
(require hyrule.control [unless])

(import copy [deepcopy])
(import time [time])

(import chasm_engine [log])
(import chasm_engine.lib *)
(import chasm_engine.types [Coords])
(import chasm_engine.state [get-place set-place get-item set-item
                            get-character update-character
                            places items characters])
(require chasm_engine.instructions [deftemplate])


;; * Delta Schema
;; -----------------------------------------------------------------------------

;; A delta represents proposed world changes from the narrator:
;; {
;;   :updates [{:entity-type "place" :entity-id "0,0" :patch {...}}]
;;   :creations [{:entity-type "item" :entity-id "torch" :attrs {...}}]
;;   :deletions [{:entity-type "item" :entity-id "consumed-item"}]
;;   :relations [{:op "add" :type "contains" :from "0,0" :to "item"}]
;; }

(setv VALID-ENTITY-TYPES #{"place" "item" "character"})
(setv VALID-PLACE-ATTRS #{"name" "rooms" "appearance" "atmosphere" 
                          "terrain" "short_description" "state" "properties"})
(setv VALID-ITEM-ATTRS #{"name" "type" "appearance" "usage" "owner" 
                         "coords" "state" "properties"})
(setv VALID-CHAR-ATTRS #{"appearance" "health" "emotions" "objective"
                         "destination" "coords" "score" "properties"})


;; * Validation
;; -----------------------------------------------------------------------------

(defn entity-exists? [entity-type entity-id]
  "Check if an entity exists in the current world state."
  (match entity-type
    "place" (bool (get-place (parse-coords entity-id)))
    "item" (bool (get-item entity-id))
    "character" (bool (get-character entity-id))
    _ False))


(defn parse-coords [entity-id]
  "Parse 'x,y' string to Coords dict."
  (try
    (let [parts (.split entity-id ",")]
      (when (= (len parts) 2)
        (Coords (int (get parts 0)) (int (get parts 1)))))
    (except [Exception] None)))


(defn valid-attrs-for-type [entity-type]
  "Get valid attribute names for an entity type."
  (match entity-type
    "place" VALID-PLACE-ATTRS
    "item" VALID-ITEM-ATTRS
    "character" VALID-CHAR-ATTRS
    _ #{}))


(defn validate-update [change errors]
  "Validate a single update operation."
  (let [entity-type (:entity-type change)
        entity-id (:entity-id change)
        patch (:patch change {})]
    ;; Check entity type
    (unless (in entity-type VALID-ENTITY-TYPES)
      (.append errors f"Invalid entity type: {entity-type}"))
    ;; Check entity exists
    (unless (entity-exists? entity-type entity-id)
      (.append errors f"Entity does not exist: {entity-type}/{entity-id}"))
    ;; Check patch keys
    (let [valid-attrs (valid-attrs-for-type entity-type)
          invalid-keys (lfor k (.keys patch) :if (not (in k valid-attrs)) k)]
      (when invalid-keys
        (.append errors f"Invalid attributes for {entity-type}: {invalid-keys}")))))


(defn validate-creation [change errors]
  "Validate a single creation operation."
  (let [entity-type (:entity-type change)
        entity-id (:entity-id change)
        attrs (:attrs change {})]
    ;; Check entity type
    (unless (in entity-type VALID-ENTITY-TYPES)
      (.append errors f"Invalid entity type: {entity-type}"))
    ;; Check doesn't already exist
    (when (entity-exists? entity-type entity-id)
      (.append errors f"Entity already exists: {entity-type}/{entity-id}"))
    ;; Check required attributes
    (match entity-type
      "place" (unless (:coords attrs)
                (.append errors "Place creation requires coords"))
      "item" (unless (or (:coords attrs) (:owner attrs))
               (.append errors "Item creation requires coords or owner"))
      "character" (unless (:coords attrs)
                    (.append errors "Character creation requires coords")))))


(defn validate-deletion [change errors]
  "Validate a single deletion operation."
  (let [entity-type (:entity-type change)
        entity-id (:entity-id change)]
    ;; Check entity type
    (unless (in entity-type VALID-ENTITY-TYPES)
      (.append errors f"Invalid entity type: {entity-type}"))
    ;; Check entity exists
    (unless (entity-exists? entity-type entity-id)
      (.append errors f"Entity does not exist: {entity-type}/{entity-id}"))))


(defn validate-delta [delta]
  "Validate a complete delta. Returns {\"valid\" bool \"errors\" [...]}."
  (let [errors []]
    ;; Validate updates
    (for [change (:updates delta [])]
      (validate-update change errors))
    ;; Validate creations
    (for [change (:creations delta [])]
      (validate-creation change errors))
    ;; Validate deletions
    (for [change (:deletions delta [])]
      (validate-deletion change errors))
    ;; Relations validation (both entities must exist after creations)
    ;; For now, skip relations validation - implement when needed
    {"valid" (not errors) "errors" errors}))


;; * Application
;; -----------------------------------------------------------------------------

(defn apply-place-update [entity-id patch]
  "Apply a patch to a place."
  (let [coords (parse-coords entity-id)
        place (get-place coords)]
    (when place
      (let [new-place (| (._asdict place) patch)]
        (set-place new-place)
        (log.info f"Updated place {entity-id}: {patch}")))))


(defn apply-item-update [entity-id patch]
  "Apply a patch to an item."
  (let [item (get-item entity-id)]
    (when item
      (let [new-item (| (._asdict item) patch)]
        (set-item new-item)
        (log.info f"Updated item {entity-id}: {patch}")))))


(defn apply-character-update [entity-id patch]
  "Apply a patch to a character."
  (let [char (get-character entity-id)]
    (when char
      (update-character char #** patch)
      (log.info f"Updated character {entity-id}: {patch}"))))


(defn apply-update [change]
  "Apply a single update operation."
  (let [entity-type (:entity-type change)
        entity-id (:entity-id change)
        patch (:patch change {})]
    (match entity-type
      "place" (apply-place-update entity-id patch)
      "item" (apply-item-update entity-id patch)
      "character" (apply-character-update entity-id patch)
      _ (log.warn f"Unknown entity type for update: {entity-type}"))))


(defn :async apply-creation [change]
  "Apply a single creation operation."
  (let [entity-type (:entity-type change)
        entity-id (:entity-id change)
        attrs (:attrs change {})]
    (match entity-type
      "place" (let [coords (or (parse-coords entity-id) (:coords attrs))]
                (when coords
                  (import chasm_engine.place [new])
                  (await (new coords))))
      "item" (let [coords (:coords attrs)
                   owner (:owner attrs)]
               (when (or coords owner)
                 (import chasm_engine.item [spawn])
                 (await (spawn coords :name entity-id))))
      "character" (let [coords (:coords attrs)]
                    (when coords
                      (import chasm_engine.character [spawn])
                      (await (spawn :name entity-id :coords coords))))
      _ (log.warn f"Unknown entity type for creation: {entity-type}"))))


(defn apply-deletion [change]
  "Apply a single deletion operation."
  (let [entity-type (:entity-type change)
        entity-id (:entity-id change)]
    (match entity-type
      "place" (let [coords (parse-coords entity-id)]
                (when coords
                  (import chasm_engine.state [delete-place])
                  (delete-place coords)
                  (log.info f"Deleted place {entity-id}")))
      "item" (do
               (import chasm_engine.state [delete-item])
               (delete-item entity-id)
               (log.info f"Deleted item {entity-id}"))
      "character" (do
                    (import chasm_engine.state [delete-character])
                    (delete-character entity-id)
                    (log.info f"Deleted character {entity-id}"))
      _ (log.warn f"Unknown entity type for deletion: {entity-type}"))))


(defn :async apply-delta [delta]
  "Apply a validated delta to the world state.
  Returns {\"applied\" int \"failed\" int \"errors\" [...]}."
  (let [applied 0
        failed 0
        errors []]
    ;; Apply updates
    (for [change (:updates delta [])]
      (try
        (apply-update change)
        (setv applied (inc applied))
        (except [e Exception]
          (setv failed (inc failed))
          (.append errors f"Update failed: {e}"))))
    ;; Apply creations
    (for [change (:creations delta [])]
      (try
        (await (apply-creation change))
        (setv applied (inc applied))
        (except [e Exception]
          (setv failed (inc failed))
          (.append errors f"Creation failed: {e}"))))
    ;; Apply deletions
    (for [change (:deletions delta [])]
      (try
        (apply-deletion change)
        (setv applied (inc applied))
        (except [e Exception]
          (setv failed (inc failed))
          (.append errors f"Deletion failed: {e}"))))
    {"applied" applied "failed" failed "errors" errors}))


;; * Delta Extraction from Narrative
;; -----------------------------------------------------------------------------

(deftemplate world_delta)

(defn :async extract-delta [narrative player]
  "Extract world changes from narrative text.
  Returns delta dict or empty delta on failure."
  (import chasm_engine [item character place])
  (try
    (let [response (await (world-delta
                            :narrative narrative
                            :player player.name
                            :location (get-place player.coords)
                            :items (lfor i (item.get-at player.coords) i.name)
                            :characters (lfor c (character.get-at player.coords) c.name)))
          delta (extract-json-unwrap response)]
      (or delta {"updates" [] "creations" [] "deletions" [] "relations" []}))
    (except [e Exception]
      (log.error f"Failed to extract delta: {e}")
      {"updates" [] "creations" [] "deletions" [] "relations" []})))


;; * Timeline (Event Sourcing)
;; -----------------------------------------------------------------------------

(defclass WorldTimeline []
  "Event-sourced world state with snapshots and reversibility."
  
  (defn __init__ [self]
    (setv self.diffs []        ;; [{:delta ... :narrative ... :turn ... :timestamp ...}]
          self.snapshot-every 50
          self.snapshots {}))  ;; turn-id -> full state
  
  (defn record [self delta narrative]
    "Record a delta application in the timeline."
    (let [turn (len self.diffs)]
      (.append self.diffs
               {:delta delta
                :narrative narrative
                :turn turn
                :timestamp (time)})
      ;; Create snapshot periodically
      (when (= 0 (% (inc turn) self.snapshot-every))
        ;; Snapshot would capture full world state
        ;; For now, just log
        (log.debug f"Timeline snapshot at turn {turn}"))))
  
  (defn get-history [self [n 10]]
    "Get recent history entries."
    (cut self.diffs (- n) None))
  
  (defn get-turn [self turn-id]
    "Get a specific turn from history."
    (when (and (>= turn-id 0) (< turn-id (len self.diffs)))
      (get self.diffs turn-id))))


;; Global timeline instance
(setv timeline (WorldTimeline))


;; * Convenience Functions
;; -----------------------------------------------------------------------------

(defn :async process-delta [delta narrative]
  "Validate and apply a delta, recording in timeline.
  Returns {\"success\" bool \"applied\" int \"errors\" [...]}."
  (let [validation (validate-delta delta)]
    (if (.get validation "valid")
        (let [result (await (apply-delta delta))
              applied (.get result "applied")
              errors (.get result "errors")]
          ;; Only record in timeline if something was actually applied
          (when (> applied 0)
            (timeline.record delta narrative))
          {"success" True 
           "applied" applied
           "errors" errors})
        {"success" False
         "applied" 0
         "errors" (.get validation "errors")})))
