# Chasm Engine - Current State

**Last Updated:** 2026-04-26
**Branch:** nereus
**Tests:** 26 passing

## Architecture

```
┌─────────────────┐     WebSocket      ┌──────────────────┐
│   chasm/        │◄──────────────────►│  chasm_engine/   │
│   (client)      │    ws://host:8765  │   (server)       │
└─────────────────┘                    └──────────────────┘
        │                                       │
        │                                       │
   ┌────▼────┐                           ┌─────▼─────┐
   │ PTK TUI │                           │  SQLite   │
   │ client  │                           │  (facts,  │
   └─────────┘                           │  quests)  │
                                         └───────────┘
```

## Components

### chasm_engine/ (Server)

| Module | Purpose | Status |
|--------|---------|--------|
| `engine.hy` | Main game loop, command parsing | ✅ Working |
| `facts.hy` | SQLite fact storage with FTS5 | ✅ Working |
| `memory_facts.hy` | ChromaDB-compatible wrapper | ✅ Working |
| `quest.hy` | Quest system with LLM conditions | ✅ Working |
| `world_author.hy` | Dynamic content generation | ✅ Working |
| `character.hy` | NPC/player management | ✅ Working |
| `place.hy` | Location system | ✅ Working |
| `item.hy` | Inventory system | ✅ Working |
| `chat.hy` | LLM integration (OpenAI-compatible) | ✅ Working |

### chasm/ (Client)

| Module | Purpose | Status |
|--------|---------|--------|
| `ws_server.hy` | WebSocket server (JSON-RPC 2.0) | ✅ Working |
| `client.hy` | WebSocket client | ✅ Working |
| `ptk_repl.hy` | Prompt-toolkit REPL | ⚠️ Incomplete |
| `ptk_interface.hy` | PTK UI components | ⚠️ Incomplete |

## Protocol

**WebSocket JSON-RPC 2.0**

Methods:
- `spawn` — Create player character
- `parse` — Process player input
- `status` — Get server status
- `online` — List online players
- `motd` — Message of the day
- `quit` — Disconnect

Authentication: JWT tokens (1-hour expiry)

## Configuration

**Server:** `chasm_engine/server.toml`
```toml
ws_host = "0.0.0.0"
ws_port = 8765
world = "/path/to/world/data"
jwt_secret = "change-me-in-production"

[providers.backend]
api_base = "http://llm-server:port/v1"
model = "model-name"
```

**Client:** `chasm/client.toml`
```toml
name = "PlayerName"
passphrase = "secret"
websocket_url = "ws://localhost:8765"
```

## Recent Changes (nereus branch)

### Removed
- ZMQ server/wire protocol → WebSocket
- ChromaDB → SQLite facts
- `memory.hy` → `memory_facts.hy`
- Legacy Rich interface (`repl.hy`, `interface.hy`)
- `sentence-transformers` dependency

### Added
- WebSocket server/client
- Turn-level context cache (LLM prompt optimisation)
- JWT authentication
- Rate limiting

### Fixed
- Predicate naming: `?` → `is-` prefix (16 functions)
- SQL schema extracted to `sql/schema.sql`
- Missing paren in `engine.hy`
- Malformed import in `character.hy`

## Known Issues

1. **ptk_repl.hy incomplete** — TUI migration not finished
2. **No push access** — Commits ready but cannot push to GitHub
3. **Style warnings** — `hylint` reports minor issues (redundant `do`, use `inc`)

## Testing

```bash
# Run tests
cd chasm
.venv/bin/python -m pytest ../chasm_engine/tests/native_tests/ --assert=plain -v

# Lint Hy files
.venv/bin/python -c "
from beautifhy.lint import lint
from pathlib import Path
for f in Path('../chasm_engine/chasm_engine').glob('*.hy'):
    issues = lint(f.read_text())
    if issues: print(f'{f.name}: {len(issues)} issues')
"

# Integration test
cd chasm_engine
python test_ws.py
```

## Deployment

```bash
# Start server
cd chasm_engine
hy chasm/ws_server.hy

# Or with config
hy chasm/ws_server.hy -c path/to/server.toml
```

## Dependencies

**chasm_engine:**
- hyjinx, openai, anthropic
- sqlitedict, jaro-winkler
- tiktoken, tenacity, ecdsa, async-lru

**chasm:**
- hyjinx, rich
- websockets, PyJWT, ecdsa
