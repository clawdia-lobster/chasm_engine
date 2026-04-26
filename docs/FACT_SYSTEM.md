# Fact System Design

Replace the fragile ChromaDB memory system with a structured, queryable fact store embedded in the existing SQLite database.

## Motivation

| Problem | Root cause |
|---------|-----------|
| Regex extraction breaks on LLM variation | `remember` parses `[class] point` with `re.search` |
| No clean provenance-scoped queries | Semantic search returns approximate matches |
| No invalidation mechanism | ChromaDB has no update/delete by field |
| No concurrent writes | ChromaDB singleton limitation |
| Heavy dependency | ~200 MB, HTTP telemetry, local embedding model |

## Design Goals

1. **Structured triples** — `(subject, predicate, object)` with metadata
2. **Provenance-scoped queries** — "what does character X know about Y?"
3. **Temporal validity** — expiration and invalidation as first-class operations
4. **Zero new dependencies** — `sqlite3` is already available
5. **Clean migration path** — `memory.hy` API preserved during transition

## Schema Overview

Core tables in `{world}/world.sqlite`:

- `facts` — subject-predicate-object triples with location, timestamp, classification, validity, expiry
- `fact_witnesses` — join table linking facts to knowing characters
- `live_facts` — view of valid, non-expired facts with aggregated witnesses

Key fields: `subject` (entity), `predicate` (kebab-style verb), `object` (optional target), `classification` (observation/significant/major/rumour), `valid` (soft-delete flag).

## API Surface (`chasm_engine/facts.hy`)

**Write operations:**
- `(add subject predicate ...)` — store a fact with witnesses
- `(witness fact-id character)` — record character knowledge
- `(invalidate fact-id reason)` — soft-delete a fact
- `(invalidate-about subject ...)` — bulk invalidation by subject/predicate/witness
- `(expire-stale)` — periodic cleanup of expired facts

**Read operations:**
- `(known-by character ...)` — facts known by a character, with filters
- `(about subject ...)` — facts about an entity
- `(at-location location ...)` — facts from a place
- `(recent character n)` — most recent facts
- `(narrated ...)` — narrator-level facts (world events)

**Formatting:**
- `(fact->str fact)` — human-readable rendering
- `(facts->context facts)` — bulleted context block

## Key Concepts

**Triple structure** — Facts use `(subject, predicate, object)` instead of free text. Predicates are kebab-case verbs: `knows`, `is-at`, `has`, `wants`, `saw`.

**Witness model** — Facts exist once; multiple characters can know them via `fact_witnesses`. This enables "what does Alice know that Bob doesn't?" queries.

**Soft deletion** — Facts are invalidated (marked `valid=0`) rather than deleted, preserving historical record with `invalidated_reason`.

**Expiry** — Facts can have `expires_at` for transient information (locations, temporary states). Expired facts are treated as invalid.

**Classification** — Mirrors existing ChromaDB metadata: `observation` (default), `significant`, `major`, `rumour`. Used for relevance filtering.

## Migration Path

1. **Phase 0** — Add `facts.hy`, initialize schema (no behaviour change)
2. **Phase 1** — Dual-write to ChromaDB and facts table
3. **Phase 2** — Backfill historical data
4. **Phase 3** — Switch reads to facts table
5. **Phase 4** — Remove ChromaDB dependency

## LLM Prompt Changes

`new_memory` field changes from `[classification] text` to structured JSON:

```json
{
  "subject": "Bob",
  "predicate": "is-hiding",
  "object": "in the mill",
  "classification": "significant"
}
```

This eliminates regex parsing and uses the existing `extract-json` infrastructure.
