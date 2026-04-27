# Chasm Code Quality Plan

## Summary
8 issues identified, 6 resolved, 2 remaining.

---

## Completed ✅

### 1. Check engine FIXMEs
**Result:** 2 FIXMEs found, both already tracked in ISSUES.md.
- `engine.hy:617` - consume-item not written → ISSUES.md #8
- `place.hy:120` - place generation flaky → ISSUES.md #7

### 2. Tidy solved TODOs
**Result:** Removed obsolete streaming TODO (streaming is implemented).

### 3. Remove dead code
**Result:**
- Removed unused `summary-*` imports from engine.hy
- Removed `moderation.hy` (stubs, never used)
- Noted: `edit.hy` unused but may be useful for admin REPL

### 4. Extract world_author prompts
**Result:** Created `templates/world_author.toml` with 4 prompts.
**Remaining:** Wire up templates in `world_author.hy`.

### 5. Wire up intent.hy ✅
**Issue:** `intent.hy` existed with LLM-based intent classification but was not imported or used.
**Result:**
- Added intent import to engine.hy
- Created `parse-with-intent` function
- Modified parse to use hybrid approach:
  - Fast path for explicit `/commands`
  - Intent classification for natural language
- ROADMAP now matches code

### 6. Improve chat.truncate ✅
**Issue:** Current approach removes oldest messages with no intelligence.
**Result:**
- Added `truncate-smart` async function
- Keeps recent N messages verbatim (default 10)
- Summarizes older messages using `summary-msgs-paragraph` template
- Falls back to `truncate` for short message lists
- Preserves context better than brutal deletion

### 7. Refactor engine.develop
**Issue:** Does 5 things, not thread-safe, uses global queue.

**Plan:**
1. Extract `extract-plot-points()`
2. Extract `check-quest-progress()`
3. Extract `run-world-author()`
4. Extract `develop-characters-at()`
5. Extract `spawn-npcs-if-needed()`
6. Make thread-safe (remove global queue)

**Complexity:** High (architectural change)

---

## Deferred ⏸️

### 8. Clarify place/rooms structure
**Issue:** Grid → Place → Rooms (strings) hierarchy is confusing.

**Recommendation:** Document intended use case or simplify.
**Why deferred:** Architectural decision, needs user input on game design direction.

---

## Execution Order

1. **Wire up intent.hy** - Most impactful, resolves disconnect between docs and code
2. **Improve chat.truncate** - Quality of life improvement
3. **Refactor engine.develop** - Larger change, do after intent.hy is stable
