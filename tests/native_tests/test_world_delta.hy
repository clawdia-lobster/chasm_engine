"""Tests for world_delta module - persistent world mutations."""

(import pytest)
(import asyncio)

(import chasm_engine.world_delta)


(defn test-parse-coords []
  "Test coordinate parsing."
  (let [coords (chasm_engine.world_delta.parse-coords "0,0")]
    (assert (= (:x coords) 0))
    (assert (= (:y coords) 0)))
  (let [coords (chasm_engine.world_delta.parse-coords "-3,5")]
    (assert (= (:x coords) -3))
    (assert (= (:y coords) 5)))
  ; Invalid formats return None
  (assert (is (chasm_engine.world_delta.parse-coords "invalid") None))
  (assert (is (chasm_engine.world_delta.parse-coords "0") None)))


(defn test-valid-attrs-for-type []
  "Test attribute validation for entity types."
  (let [place-attrs (chasm_engine.world_delta.valid-attrs-for-type "place")]
    (assert (in "name" place-attrs))
    (assert (in "state" place-attrs))
    (assert (in "properties" place-attrs)))
  (let [item-attrs (chasm_engine.world_delta.valid-attrs-for-type "item")]
    (assert (in "name" item-attrs))
    (assert (in "state" item-attrs)))
  (let [char-attrs (chasm_engine.world_delta.valid-attrs-for-type "character")]
    (assert (in "health" char-attrs))
    (assert (in "emotions" char-attrs)))
  ; Unknown type returns empty set
  (assert (= (chasm_engine.world_delta.valid-attrs-for-type "unknown") #{})))


(defn test-validate-empty-delta []
  "Test that empty delta is valid."
  (let [result (chasm_engine.world_delta.validate-delta {"updates" [] "creations" [] "deletions" [] "relations" []})]
    (assert (.get result "valid"))))


(defn test-validate-invalid-entity-type []
  "Test that invalid entity type is rejected."
  (let [result (chasm_engine.world_delta.validate-delta {"updates" [{"entity-type" "invalid" "entity-id" "test" "patch" {}}]})]
    (assert (not (.get result "valid")))
    (assert (> (len (.get result "errors")) 0))))


(defn test-validate-nonexistent-entity []
  "Test that update to nonexistent entity is rejected."
  (let [result (chasm_engine.world_delta.validate-delta {"updates" [{"entity-type" "item" "entity-id" "nonexistent-item" "patch" {"state" "broken"}}]})]
    (assert (not (.get result "valid")))))


(defn test-valid-entity-types []
  "Test that valid entity types are defined."
  (assert (in "place" chasm_engine.world_delta.VALID_ENTITY_TYPES))
  (assert (in "item" chasm_engine.world_delta.VALID_ENTITY_TYPES))
  (assert (in "character" chasm_engine.world_delta.VALID_ENTITY_TYPES)))
