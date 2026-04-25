"Test quest system"

(import sys)
(setv sys.argv ["server" "-c" "milliways.toml"])

(import chasm_engine.quest [init get-quest all-quests quest-context
                             eligible? start-quest active-quests
                             completed-quest-ids available-for])

(init)
(print f"Quests loaded: {(len (all-quests))}")

(let [q (get-quest "end-of-universe")]
  (print f"Quest: {(:name q)}")
  (print f"Stages: {(len (:stages q []))}")
  (for [s (:stages q [])]
    (print f"  - {(:id s)}: {(:condition s)}")))

(let [elig-main (eligible? "Arthur" "end-of-universe")
      elig-chain (eligible? "Arthur" "hitchhikers-guide")]
  (print f"Eligible end-of-universe: {elig-main}")
  (print f"Eligible hitchhikers-guide (needs prereq): {elig-chain}"))

(start-quest "Arthur" "end-of-universe")

(let [active (active-quests "Arthur")]
  (print f"Active quests: {(len active)}")
  (for [p active]
    (let [q (get-quest (:quest_id p))]
      (print f"  {(:name q)} stage {(:stage_index p)}"))))

(print "Quest context for narrator:")
(print (quest-context "Arthur"))
