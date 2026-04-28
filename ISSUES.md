# Chasm Engine Issues

## UX Improvements

1. **Server should send immediate message on connect** — Currently `handle-spawn` waits for `engine.spawn-player` to complete before responding. Need to send a "spawning, initializing world..." notification immediately.
   - **Status:** ✅ Fixed — Server now sends immediate notification before spawn.

2. **Client should show UI immediately** — The client waits for the spawn response. Need to decouple UI display from spawn completion.

3. **UI should show server/client status** — `chatthy` has status bar infrastructure but needs wiring.

## Bugs (2026-04-28)

4. **Return key does nothing in UI** — Typing `/help<RETURN>` stays on editing line, no action taken.
   - **Root cause:** `input-callback` variable was shadowed by local `setv` in ptk_repl.hy.
   - **Status:** ✅ Fixed — Now uses mutable dict container with `set-input-callback` function.

5. **Need more debug logging** — Especially for `place/new` generation timing. Seems to take much longer than expected.
   - **Root cause:** `extend-map` generates 9 places (3x3 grid), each requiring 3 sequential LLM calls = 27 LLM calls total.
   - **Status:** ✅ Fixed — Added timing logs and parallelized place generation with `asyncio.gather`.

6. **No accounts in world.sqlite after connect** — New accounts not being persisted.
   - **Root cause:** `update-account` only called if passphrase provided. No account created for passphrase-less players.
   - **Status:** ✅ Fixed — Always create account entry on spawn.

7. **No characters visible** — Including player's own character not appearing in database.
   - **Root cause:** `is-valid-key` was rejecting single-character names. Also, world path may be wrong.
   - **Status:** ✅ Fixed — Single-character names now allowed. Added better logging for validation failures.

8. **JWT key too short** — Warning: "The HMAC key is 23 bytes long, which is below the minimum recommended length of 32 bytes for SHA256."
   - **Root cause:** Default `jwt_secret = "change-me-in-production"` is 23 bytes.
   - **Status:** ✅ Fixed — Default now 32+ bytes.

9. **World path hardcoded in example config** — `server.toml` has `/home/node/...` path that only works on node machine.
   - **Status:** ✅ Fixed — Now uses relative path with comment. Added CONFIG.md with setup instructions.

10. **Passphrase not passed to spawn** — Client reads passphrase from config but never sends it.
    - **Status:** ✅ Fixed — Now passes passphrase from config to spawn function.

11. **Spawn increments turn count** — First spawn shouldn't count as a turn.
    - **Status:** ✅ Fixed — Added `increment-turn` parameter to payload, spawn passes False.

12. **Client hangs on input** — asyncio.run() cannot be called from running event loop.
    - **Root cause:** PTK callback is sync but called from async context.
    - **Status:** ✅ Fixed — Using queue pattern with background async processor.

13. **Session token not stored** — Client wasn't storing session_token from spawn.
    - **Root cause:** spawn response includes session_token but client didn't save it.
    - **Status:** ✅ Fixed — Client now stores token in _state and uses for subsequent requests.

14. **parse-stream-async wrong signature** — Function took wrong arguments.
    - **Root cause:** Function signature had player-name as first arg, but was called with input.
    - **Status:** ✅ Fixed — Function now takes input as first arg, uses stored session token.

15. **Client hangs during spawn** — UI not responsive during spawn.
    - **Root cause:** Spawn happened before app started, so UI couldn't update.
    - **Status:** ✅ Fixed — Spawn now runs as background task after app starts.

16. **Notifications not handled** — Server notifications were treated as responses.
    - **Root cause:** _call-async returned first message instead of waiting for response with matching id.
    - **Status:** ✅ Fixed — _call-async now loops until it gets response with matching id.
