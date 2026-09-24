# Capability: cdp

Raw Chrome DevTools Protocol for development work. Prefer the higher-level APIs.

- `send(method, params, { target: { sessionId }, timeoutMs })` → the command result.
- `readEvents({ afterSequence, methods, limit, timeoutMs })` → `{ cursor, events, hasMore, truncated }`.
  Call it without `afterSequence` to get the current cursor, act, then read from that cursor.
  Keep paging with the returned cursor while `hasMore` is true; `truncated` means older
  events were dropped.

If you change page content or browser state through CDP and leave it that way, tell the user.
