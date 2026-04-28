"""Tests for world_author module pure functions."""

(import chasm_engine.world_author [summarise-narrative])


(defn test-summarise-narrative []
  "Test narrative summarization."
  (let [messages [{"role" "user" "content" "You enter the forest."}
                  {"role" "assistant" "content" "The trees tower above you."}
                  {"role" "user" "content" "I look around."}]
        summary (summarise-narrative messages)]
    (assert (in "forest" summary))
    (assert (in "trees" summary))))

(defn test-summarise-narrative-empty []
  "Test summarization with empty messages."
  (let [summary (summarise-narrative [])]
    (assert (= summary ""))))

(defn test-summarise-narrative-custom-n []
  "Test summarization with custom message count."
  (let [messages [{"role" "user" "content" "one"}
                  {"role" "assistant" "content" "two"}
                  {"role" "user" "content" "three"}
                  {"role" "assistant" "content" "four"}]
        summary (summarise-narrative messages 2)]
    (assert (in "three" summary))
    (assert (in "four" summary))
    (assert (not (in "one" summary)))))
