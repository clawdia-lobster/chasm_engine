"""Tests for chat module pure functions."""

(import pytest)

(import chasm_engine.chat [msg system user assistant token-length standard-roles flip-roles])
(import chasm_engine.chat :as chat)


(defn test-msg []
  "Test message creation."
  (let [m (msg "user" "hello")]
    (assert (= (:role m) "user"))
    (assert (= (:content m) "hello"))))

(defn test-msg-strips-whitespace []
  "Test that msg strips whitespace from content."
  (let [m (msg "user" "  hello world  ")]
    (assert (= (:content m) "hello world"))))

(defn test-system-user-assistant []
  "Test convenience message constructors."
  (let [s (system "system prompt")
        u (user "user input")
        a (assistant "assistant reply")]
    (assert (= (:role s) "system"))
    (assert (= (:role u) "user"))
    (assert (= (:role a) "assistant"))))

(defn test-token-length []
  "Test token counting."
  ;; Empty string has 0 tokens
  (assert (= (token-length "") 0))
  ;; Longer text has more tokens
  (assert (> (token-length "hello world") (token-length "hello"))))

(defn test-standard-roles []
  "Test filtering messages by standard roles."
  (let [messages [{"role" "user" "content" "hi"}
                  {"role" "assistant" "content" "hello"}
                  {"role" "system" "content" "prompt"}
                  {"role" "unknown" "content" "weird"}]
        filtered (standard-roles messages)]
    (assert (= (len filtered) 3))
    (assert (not (in {"role" "unknown" "content" "weird"} filtered)))))

(defn test-msg-to-dlg []
  "Test converting message to dialogue format."
  (let [user-msg {"role" "user" "content" "hello"}
        asst-msg {"role" "assistant" "content" "hi there"}
        sys-msg {"role" "system" "content" "prompt"}]
    (assert (= (chat.msg->dlg "Alice" "Bob" user-msg) {"role" "Alice" "content" "hello"}))
    (assert (= (chat.msg->dlg "Alice" "Bob" asst-msg) {"role" "Bob" "content" "hi there"}))
    (assert (is (chat.msg->dlg "Alice" "Bob" sys-msg) None))))

(defn test-msgs-to-dlg []
  "Test converting messages to dialogue format."
  (let [messages [{"role" "user" "content" "hi"}
                  {"role" "assistant" "content" "hello"}
                  {"role" "system" "content" "prompt"}]
        dlg (chat.msgs->dlg "Alice" "Bob" messages)]
    (assert (= (len dlg) 2))
    (assert (= (:role (get dlg 0)) "Alice"))
    (assert (= (:role (get dlg 1)) "Bob"))))

(defn test-dlg-to-msg []
  "Test converting dialogue to message format."
  (let [alice-msg {"role" "Alice" "content" "hello"}
        bob-msg {"role" "Bob" "content" "hi there"}
        other-msg {"role" "Charlie" "content" "hey"}]
    (assert (= (chat.dlg->msg "Alice" "Bob" alice-msg) {"role" "user" "content" "hello"}))
    (assert (= (chat.dlg->msg "Alice" "Bob" bob-msg) {"role" "assistant" "content" "hi there"}))
    (assert (= (:role (chat.dlg->msg "Alice" "Bob" other-msg)) "system"))))

(defn test-flip-roles []
  "Test flipping user/assistant roles."
  (let [messages [{"role" "user" "content" "hi"}
                  {"role" "assistant" "content" "hello"}]
        flipped (flip-roles messages)]
    (assert (= (:role (get flipped 0)) "assistant"))
    (assert (= (:role (get flipped 1)) "user"))))
