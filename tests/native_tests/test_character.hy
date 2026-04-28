"""Tests for character module pure functions."""

(import chasm_engine.character [is-valid-key])


(defn test-is-valid-key []
  "Test character key validation."
  ;; Valid keys
  (assert (is-valid-key "alice"))
  (assert (is-valid-key "Alice"))
  (assert (is-valid-key "user_123"))
  (assert (is-valid-key "test.name"))
  (assert (is-valid-key "a-b"))
  (assert (is-valid-key "a"))  ; Single char is valid
  (assert (is-valid-key "ab"))  ; Two chars is valid
  ;; Invalid keys
  (assert (not (is-valid-key "")))
  (assert (not (is-valid-key "-start")))
  (assert (not (is-valid-key "end-")))
  (assert (not (is-valid-key "no spaces")))
  (assert (not (is-valid-key "special!char"))))
