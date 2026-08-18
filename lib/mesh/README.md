# mesh/ — BLE + Wi-Fi Direct transport

**Owner:** A · **Branch prefix:** `a/` · **Required reviewer:** B specifically (CLAUDE.md §3.3)
**Task list:** `Docs/PERSON_A.md`

Moves opaque signed bytes between phones. Envelope format, receive pipeline,
signature verification at each hop, `hop_limit` decrement, message-ID de-dup cache,
routing policy.

Does **not** interpret claim content — trust, decay and merging live in `data/`.
Relaying is never corroboration (§2.2). PRs here need two physical devices (§4.5).
