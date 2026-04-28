# Chasm Engine Issues

## UX Improvements

1. **Server should send immediate message on connect** — Currently `handle-spawn` waits for `engine.spawn-player` to complete before responding. Need to send a "spawning, initializing world..." notification immediately.

2. **Client should show UI immediately** — The client waits for the spawn response. Need to decouple UI display from spawn completion.

3. **UI should show server/client status** — `chatthy` has status bar infrastructure but needs wiring.

## Bugs (2026-04-28)

4. **Return key does nothing in UI** — Typing `/help<RETURN>` stays on editing line, no action taken.
   - **Root cause:** chatthy requires TAB to toggle command mode. `/help` is sent as chat input, not command.
   - **Fix:** Either document TAB requirement, or auto-detect `/` prefix as command.

5. **Need more debug logging** — Especially for `place/new` generation timing. Seems to take much longer than expected.
   - **Root cause:** `extend-map` generates 9 places (3x3 grid), each requiring 3 sequential LLM calls = 27 LLM calls total.
   - **Fix:** Add timing logs, consider parallel generation.

6. **No accounts in world.sqlite after connect** — New accounts not being persisted.
   - **Root cause:** `update-account` only called if passphrase provided. No account created for passphrase-less players.
   - **Fix:** Always create account entry on spawn.

7. **No characters visible** — Including player's own character not appearing in database.
   - **Root cause:** `is-valid-key` rejects names that don't match `^[a-zA-Z0-9][a-zA-Z0-9._-]*[a-zA-Z0-9]$`. Also, world path may be wrong.
   - **Fix:** Check world path config, relax validation or add better error messages.

8. **JWT key too short** — Warning: "The HMAC key is 23 bytes long, which is below the minimum recommended length of 32 bytes for SHA256."
   - **Root cause:** Default `jwt_secret = "change-me-in-production"` is 23 bytes.
   - **Fix:** Generate longer default or require config.

9. **World path hardcoded in example config** — `server.toml` has `/home/node/...` path that only works on node machine.
   - **Fix:** Use relative path or document requirement to edit config.
