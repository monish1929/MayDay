# PERSON_B.md — Data Layer & Trust Engine

**Owner:** B
**Branch prefix:** `b/`
**Primary folder:** `lib/data/`
**Reviews my PRs:** A (always, for anything in `data/`)
**I review:** A's `mesh/` PRs

Read `CLAUDE.md` and `CLAIM_SCHEMA.md` first. This file is my task list and progress log — update the checkboxes as I go, and fill in the log at the bottom.

---

## 1. What I own

The Claim — what it is, how it's identified, how it's stored, and how much we believe it.

- The `Claim` model and SQLite persistence (`CLAIM_SCHEMA.md` §1, §10)
- **The two claim-ID functions** (§2) — the most important code in the repo
- Trust state machine: UNCONFIRMED → CORROBORATED → GROUND_CONFIRMED (§3)
- Corroboration rules, including the anti-echo rule (§3.2)
- Type-specific decay (§7)
- Logical clocks and mesh time gossip (§4)
- Resource counter semantics — add-only, computed availability (§8.1)
- CBOR serialization of the payload

**What I don't own:** getting bytes between phones (A's), or how anything looks (C's). My layer must be fully testable with **no radio and no widget tree.**

---

## 2. Why my week 1 is pure logic, deliberately

Everything I build in week 1 runs on one device with fake data. No networking, no UI. That's the point — this is the part of the system where correctness is subtle and testable, and it's much easier to get right in isolation than while also debugging BLE.

By end of week 1 I should be able to prove, with unit tests, that the trust engine behaves correctly *before* it has to survive being carried across a mesh.

---

## 3. Week 1 — Phase 1: Data layer

### Day 1 — Schema and storage

- [ ] SQLite set up (`sqflite` or `drift` — pick one, note why in the log)
- [ ] `claims`, `corroborations`, `seen_messages` tables exactly per `CLAIM_SCHEMA.md` §10
- [ ] All enums as **real Dart enums** (§11), never strings or bare ints in code
- [ ] `Claim` model class with CBOR encode/decode for `payload`
- [ ] Assert: `display_lifetime_ms` is **NULL** for `sos`/`sosProxy` (§10.1) — not a large number
- [ ] Assert: `ResolutionMethod.autoExpired` is impossible for SOS types

### Day 2 — The two ID paths *(the critical day)*

- [ ] `sosClaimId(deviceId, sequence)` — unique, never merges
- [ ] `mergeableClaimId(type, geohashBucket)` — merging is the goal
- [ ] **Two separate functions in two separate places.** Not one function with a type branch.
- [ ] A comment on each pointing to `CLAIM_SCHEMA.md` §2, explaining *why* they're separate
- [ ] Per-device monotonic sequence counter that never resets
- [ ] Geohash bucketing at 7 chars (~150m)
- [ ] **No timestamp anywhere in either formula** (§2.4)

**Write this test before anything else:**

```
Two SOS claims, same geohash bucket, same minute, different origin devices
  → two distinct IDs
  → two separate records
  → resolving one leaves the other untouched and ACTIVE
```

This is the single most important test in the repo. It's the bug that would have made the system lose people — two families on one street collapsing into one claim, one rescue clearing both.

### Day 3 — Trust state machine

- [ ] UNCONFIRMED → CORROBORATED → GROUND_CONFIRMED, no stage skipping, no going back from GROUND_CONFIRMED
- [ ] Only two things raise trust: `independentGeneration` and `explicitAttestation` (§3.1)
- [ ] **Relaying raises nothing.** Not represented in `CorroborationKind` at all.
- [ ] Anti-echo rule via `firstSeenVia` (§3.2)
- [ ] `dispatchPriority` moves independently — a volunteer seeing a claim raises priority, **never** trust (§3.4)
- [ ] Weighting by `hopDistance` and `signalStrength`, not raw device count
- [ ] Newcomer discount: a device unseen before the claim existed carries little weight
- [ ] Per-device contribution cap

### Day 4 — Decay and logical clocks

- [ ] `displayLifetimeFor(type)` returns **`null`** for SOS types (§7)
- [ ] Hazard: long window. Resource: shortest. Values TBD — leave as named constants, flag them.
- [ ] `LogicalClock` — per-device counter, increments on every send
- [ ] Ordering between devices uses logical clocks, **never** `DateTime`
- [ ] Mesh time gossip → `createdAtLogical` estimate, display only
- [ ] Nothing that could affect an SOS ever reads a wall clock

### Day 5 — Multi-device simulation harness

- [ ] Simulate N fake "devices" writing claims into one store
- [ ] Two devices independently generating a matching hazard → merges, count rises
- [ ] Two devices raising SOS in the same bucket → **stays two claims**
- [ ] A device corroborating something it first saw via mesh → **rejected**
- [ ] Twenty devices each claiming the last resource, then merging → availability floors at 0, **never negative**
- [ ] SOS with zero corroborations after a long simulated period → **still ACTIVE, still visible**

**This harness is my dress rehearsal for Phase 2.** Every bug I catch here is a bug A and I don't have to chase across two physical phones next week.

### Exit criteria

Unit tests prove merge, corroboration, decay, and resource counting all behave correctly, with no networking anywhere in the picture.

---

## 4. The week 1 sync — what I bring

A will ask: **does the measured BLE payload capacity fit what my claims need to serialize?**

I need a real number ready — the actual CBOR-encoded size of a typical claim of each type. `CLAIM_SCHEMA.md` §9.2 targets ≤400 bytes. If A's measurement comes in lower, we either shrink the schema (shorter free-text caps, tighter geo precision) or A builds fragmentation. That's a three-person decision, not something either of us settles alone.

- [ ] Measure encoded size of each claim type before the sync
- [ ] Note which fields are the biggest contributors, in case we need to trim

---

## 5. Week 2 — Phase 2, pairing with A

Branch prefix `ab/`. We stop working solo.

- [ ] Claim → CBOR → over the wire → decode → verify signature → into my store
- [ ] Signature covers the immutable core only (`CLAIM_SCHEMA.md` §5) — not `corroborations`, `claimTrust`, `dispatchPriority`, `hopLimit`
- [ ] Receive pipeline order respected: de-dup → verify → decrement → store → relay (§9.3)
- [ ] Corroboration arriving from a genuinely second physical device upgrades trust correctly
- [ ] Relaying a claim between two phones does **not** move trust — verify this on real hardware, not just in the harness

**Why pair rather than split:** A can't see my assumptions about the schema, I can't see A's about the wire. This seam is where the relay-as-corroboration and clock-drift bugs would hide. Two people at one keyboard for three days beats debugging corrupted trust state later.

---

## 6. Later phases

**Phase 3** — I take one of the three flows, likely **Report** (geohash merging, confirmation counts) — closest to what I've already built.

**Phase 4+**
- [ ] CRDT for the resource ledger — **semantics are already settled** (add-only counters, §8.1). Only the library choice is open. Don't let "pick a CRDT library" become a redesign.
- [ ] Storage eviction policy (§10.2) — with active SOS never evicted
- [ ] Time gossip refinement, volunteer clocks weighted higher

---

## 7. Invariants I'm personally responsible for

Every one of these was a real bug in v1 of the design. They are not stylistic.

- **SOS IDs are unique and never merge** (§2). Two code paths, not one function with a branch. If someone refactors them together during a cleanup, the bug comes straight back.
- **Relaying is never corroboration** (§3.1). v1 said "generated *or relayed*," which meant a fabricated SOS hit CORROBORATED — labelled "genuine evidence" — after a single hop.
- **Anti-echo rule holds** (§3.2). Ten people confirming a rumour they all read on the same screen is one witness and nine repeaters.
- **SOS never decays** (§7). `displayLifetime` is `null` — not a large number. A person trapped alone is UNCONFIRMED *because* nobody is nearby to corroborate; blanket decay deletes the call for help from the person in most danger.
- **`available` is computed, never stored** (§8.1). Storing it is how a counter goes negative when twenty offline devices merge.
- **Trust and priority stay separate fields** (§3.4). A volunteer touching a claim knows no more than anyone else at that moment.
- **No wall clock in identity, ordering, or any decay decision affecting an SOS** (§4).

---

## 8. My PR checklist

Beyond the standard checks in `CLAUDE.md` §4.5:

- [ ] SOS unique-ID path and mergeable-ID path tested **separately** — confirmed they are not a shared code path
- [ ] Relaying does **not** upgrade `claimTrust`
- [ ] Anti-echo rule holds: a device can't corroborate what it first saw via mesh
- [ ] SOS/SOS_PROXY exempt from decay; `displayLifetime` is `null`
- [ ] `claimTrust` and `dispatchPriority` written independently
- [ ] Resource counters add-only; availability computed at read time
- [ ] All `data/` logic testable with no widget tree and no radio
- [ ] Reviewer named: **A**, per `CLAUDE.md` §3.3

---

## 9. Progress log

Update after each work session. Short entries — this is for the team sync.

| Date | Branch | What landed | Blocked on / notes |
|---|---|---|---|
| | | | |
| | | | |
| | | | |

### Open questions I'm carrying

- [ ] `sqflite` vs `drift` — decide day 1, note reason:
- [ ] CRDT library choice. Semantics settled; library is not. **Don't reopen the semantics.**
- [ ] `displayLifetime` defaults for hazard and resource — TBD, leave as named constants
- [ ] Clock-drift tolerance width — depends on A's and real-hardware drift data

### Encoded claim sizes (fill in before the week 1 sync)

| Claim type | CBOR size (bytes) | Largest field |
|---|---|---|
| SOS | | |
| SOS_PROXY | | |
| HAZARD_REPORT | | |
| RESOURCE | | |
| **Budget** | **≤ 400** | per `CLAIM_SCHEMA.md` §9.2 |
