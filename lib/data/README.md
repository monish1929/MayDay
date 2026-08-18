# data/ — Claim model, SQLite, trust engine

**Owner:** B · **Branch prefix:** `b/` · **Required reviewer:** A specifically (CLAUDE.md §3.3)
**Task list:** `Docs/PERSON_B.md` · **Contract:** `Docs/CLAIM_SCHEMA.md` (no single owner — both others review)

Claim persistence, the **two separate claim-ID paths** (§2.1), the `claim_trust`
state machine, the anti-echo rule, type-specific decay (SOS never decays, §2.3),
logical clocks.

Everything here must be testable with no Flutter widget tree and no real radio (§5.2).
