# World Delta System Design

## Overview

The narrator generates **prose + structured delta as co-products**, enabling persistent world mutations while maintaining consistency. The engine validates and applies changes, acting as the "physics" that constrains the narrator's "storytelling."

## Architecture

```
Player Input
    ↓
Context Assembly (world state + history + player input)
    ↓
Narrator Generation (prose + delta)
    ↓
Validation
    ↓
[Valid] → Apply to Timeline → Return narrative
[Invalid] → Feedback to Narrator → Regenerate (or apply valid subset)
```

## Components

### 1. Delta Schema (`world_delta.hy`)

```hy
;; A delta represents proposed world changes from the narrator
{
  :updates [        ; Modify existing entities
    {:entity-type "place" :entity-id "0,0" 
     :patch {:short_description "The tavern has burned down." :state "ruins"}}]
  :creations [      ; Create new entities
    {:entity-type "item" :entity-id "ash-pile-01"
     :attrs {:name "pile of ash" :coords {:x 0 :y 0} :type "debris"}}]
  :deletions [      ; Remove entities
    {:entity-type "item" :entity-id "torch-01"}]
  :relations [      ; Add/remove relations between entities
    {:op "add" :type "contains" :from "0,0" :to "ash-pile-01"}]
}
```

### 2. Timeline (`world_delta.hy`)

Event-sourced world state with:
- Base state
- List of diffs (forward + inverse + narrative + metadata)
- Periodic snapshots for fast replay
- Undo capability

### 3. Validation (`world_delta.hy`)

Three-layer validation:
1. **Referential integrity**: Referenced entities must exist (except creations)
2. **Creation collision**: No duplicate entity IDs
3. **Attribute validity**: Patch keys must be valid for entity type

### 4. Entity Type Updates

Add flexible `state` and `properties` fields to Place and Item:

```hy
;; Place
(setv Place (namedtuple "Place" [... "state" "properties"]))
;; state: "normal", "ruins", "flooded", etc.
;; properties: {"burned": true, "looted": false, ...}

;; Item  
(setv Item (namedtuple "Item" [... "state" "properties"]))
;; state: "intact", "broken", "consumed", etc.
;; properties: {"charges": 3, "lit": true, ...}
```

### 5. Narrator Prompt Template

Create template instructing model to output JSON delta alongside prose:

```toml
[narrator.delta]
system = """You are a creative narrator. After generating narrative prose, 
output a JSON object describing any world changes you intend.

Valid entity types: place, item, character
For places, entity-id is "x,y" coordinates.
For items and characters, entity-id is the name.

Only include changes that are explicitly stated or strongly implied in your narrative.
If nothing changes, output {"updates": [], "creations": [], "deletions": [], "relations": []}
"""
```

### 6. Integration Points

- `engine/narrate` → parse delta from response, validate, apply
- `engine/narrate-stream` → accumulate delta from stream chunks
- `place/update-place` → add to state.hy
- `item/consume` → implement using delta mechanism

## Implementation Order

1. Create `world_delta.hy` with schema, validation, timeline
2. Update `types.hy` with state/properties fields
3. Update `state.hy` with `update-place`
4. Create narrator delta prompt template
5. Wire delta parsing into `engine.hy` narrate functions
6. Implement `consume-item` using delta mechanism
7. Add tests

## Entity ID Conventions

| Entity Type | ID Format | Example |
|-------------|-----------|---------|
| Place | "x,y" | "0,0", "-3,5" |
| Item | name (lowercase, hyphenated) | "torch-01", "healing-potion" |
| Character | name (as-is) | "Gandalf", "the innkeeper" |

## Consistency Constraints

The validator enforces:
- Places: coords must be valid, name required
- Items: name required, coords OR owner required
- Characters: name required, coords required
- Relations: both entities must exist

## Error Handling

1. **Invalid delta**: Log errors, return to narrator for regeneration (future: implement retry)
2. **Partial validity**: Apply valid changes, log invalid ones
3. **Hallucinated entities**: Reject with specific error message

## Future Enhancements

- Undo/redo commands for players
- Timeline queries ("what happened here?")
- Save/load with full history
- Narrative summaries from timeline
