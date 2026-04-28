"""Tests for the intent classification module.

Note: classify-intent makes LLM calls, so we test parse-command
which has deterministic fallback behavior and the match logic.
"""

(import pytest)
(import asyncio)

(import chasm_engine.intent [classify-intent parse-command])


(defn test-parse-command-fallback-say []
  "Test that parse-command falls back to SAY for unclassified input."
  ;; When classify-intent fails or returns SAY, we get a say action
  (let [result (asyncio.run (parse-command "hello there" {} {}))]
    (assert (= (:action result) "say"))
    (assert (= (:content result) "hello there"))))

(defn test-parse-command-empty-input []
  "Test handling of empty input."
  (let [result (asyncio.run (parse-command "" {} {}))]
    (assert (= (:action result) "say"))
    (assert (= (:content result) ""))))

(defn test-classify-intent-fallback []
  "Test classify-intent fallback when LLM fails."
  ;; classify-intent catches exceptions and returns SAY
  (let [result (asyncio.run (classify-intent "test" {} {}))]
    (assert (= (:intent result) "SAY"))
    (assert (= (:content result) "test"))))
