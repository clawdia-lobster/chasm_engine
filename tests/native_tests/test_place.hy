"""Tests for place module pure functions."""

(import chasm_engine.place [is-nearby rose])


(defn test-is-nearby []
  "Test coordinate proximity check."
  (assert (is-nearby {"x" 0 "y" 0} {"x" 1 "y" 0}))
  (assert (is-nearby {"x" 0 "y" 0} {"x" 0 "y" 1}))
  (assert (is-nearby {"x" 0 "y" 0} {"x" 1 "y" 1}))
  (assert (not (is-nearby {"x" 0 "y" 0} {"x" 2 "y" 0})))
  (assert (not (is-nearby {"x" 0 "y" 0} {"x" 0 "y" 2})))
  ;; Test custom distance
  (assert (is-nearby {"x" 0 "y" 0} {"x" 2 "y" 0} 2))
  (assert (not (is-nearby {"x" 0 "y" 0} {"x" 3 "y" 0} 2))))

(defn test-rose []
  "Test compass rose directions."
  (assert (= (rose 0 1) "north"))
  (assert (= (rose 0 -1) "south"))
  (assert (= (rose 1 0) "east"))
  (assert (= (rose -1 0) "west"))
  (assert (= (rose 1 1) "northeast"))
  (assert (= (rose -1 -1) "southwest"))
  (assert (is (rose 0 0) None)))
