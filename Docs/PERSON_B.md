# PERSON_B.md — Data Layer & Trust Engine

**Owner:** B
**Branch prefix:** `b/` · pairing branches `ab/`
**Primary folder:** `lib/data/`
**Reviews my PRs:** A (always, for anything in `data/`)
**I review:** A's `mesh/` PRs

Read `CLAUDE.md` and `CLAIM_SCHEMA.md` first. This is my task list and progress log — tick boxes as I go, keep the log at the bottom current.

---

## 1. What I own

The Claim — what it is, how it's identified, how it's stored, and how much we believe it.

- The `Claim` model and SQLite persistence
- **The two claim-ID functions** — the most important code in the repo
- Trust state machine: UNCONFIRMED → CORROBORATED → GROUND_CONFIRMED
- Corroboration rules including the anti-echo rule
- Type-specific decay
- Logical clocks and mesh time gossip
- Resource counter semantics — add-only, computed availability
- CBOR serialization of the payload
- Storage budget and eviction

**What I don't own:** getting bytes between phones (A's) or how anything looks (C's). My layer must be **fully testable with no radio and no widget tree.** If a test needs a Flutter widget or a BLE connection, I've built it wrong.

---

## 2. Why my week 1 is pure logic, deliberately

Everything I build in week 1 runs on one device with fake data. No networking, no UI. That's the point — this is where correctness is subtle and testable, and it's far easier to get right in isolation than while also debugging BLE.

By end of week 1, unit tests should prove the trust engine behaves correctly *before* it has to survive being carried across a mesh.

---

# WEEK 1 — PHASE 1: DATA LAYER

### Day 1 — Schema and storage
- [x] SQLite set up (`sqflite` or `drift` — pick one, note why)
- [x] `claims`, `corroborations`, `seen_messages` tables exactly per `CLAIM_SCHEMA.md` §10
- [x] All enums as **real Dart enums**, never strings or bare ints in code
- [x] `Claim` model with CBOR encode/decode for `payload`
- [x] Assert: `display_lifetime_ms` is **NULL** for `sos`/`sosProxy` — not a large number
- [x] Assert: `ResolutionMethod.autoExpired` is impossible for SOS types

### Day 2 — The two ID paths *(the critical day)*
- [x] `sosClaimId(deviceId, sequence)` — unique, never merges
- [x] `mergeableClaimId(type, geohashBucket)` — merging is the goal
- [x] **Two separate functions in two separate places.** Not one function with a type branch.
- [x] A comment on each pointing to `CLAIM_SCHEMA.md` §2, explaining *why* they're separate
- [x] Per-device monotonic sequence counter that never resets
- [x] 7-char geohash bucketing (~150m)
- [x] **No timestamp anywhere in either formula**

**Write this test before anything else:**
```
Two SOS claims, same geohash bucket, same minute, different origin devices
  → two distinct IDs
  → two separate records
  → resolving one leaves the other untouched and ACTIVE
```
The single most important test in the repo — the bug that would have made the system lose people.

### Day 3 — Trust state machine
- [x] UNCONFIRMED → CORROBORATED → GROUND_CONFIRMED; no skipping, no reversal from groundConfirmed
- [x] Only `independentGeneration` and `explicitAttestation` raise trust
- [x] **Relaying raises nothing** — not represented in `CorroborationKind` at all
- [x] Anti-echo rule via `firstSeenVia`
- [x] `dispatchPriority` moves independently — a volunteer seeing a claim raises priority, **never** trust
- [x] Weighting by `hopDistance` and `signalStrength`, not raw device count
- [x] Newcomer discount: a device unseen before the claim existed carries little weight
- [x] Per-device contribution cap

### Day 4 — Decay and logical clocks
- [x] `displayLifetimeFor(type)` returns **`null`** for SOS types
- [x] Hazard: long window. Resource: shortest. Values TBD — named constants, flagged.
- [x] `LogicalClock` — per-device counter, increments on every send
- [x] Ordering between devices uses logical clocks, **never** `DateTime`
- [x] Mesh time gossip → display-only estimate
- [x] Nothing that could affect an SOS ever reads a wall clock

### Day 5 — Multi-device simulation harness
- [x] Simulate N fake "devices" writing claims into one store
- [x] Two devices independently generating a matching hazard → merges, count rises
- [x] Two devices raising SOS in the same bucket → **stays two claims**
- [x] A device corroborating something it first saw via mesh → **rejected**
- [x] Twenty devices each claiming the last resource → availability floors at 0, **never negative**
- [x] SOS with zero corroborations after a long simulated period → **still ACTIVE, still visible**

**This harness is my dress rehearsal for Phase 2.** Every bug caught here is one A and I don't chase across two physical phones next week.

**Exit criteria:** unit tests prove merge, corroboration, decay, and resource counting behave correctly, with no networking in the picture.

**Sync — what I bring:** the actual CBOR-encoded size of a typical claim of each type. Budget is ≤400 bytes. If A's measured payload capacity comes in lower, we shrink the schema (shorter text caps, tighter geo precision) or A builds fragmentation — a three-person decision.

---

# WEEK 2 — PHASE 2: TRANSPORT ↔ DATA (paired with A)

Branch prefix `ab/`. C works solo swapping mocks for my Phase 1 store — they aren't blocked on us.

### Day 1 — Serialization contract
- [ ] Freeze the CBOR encoding of each `ClaimPayload` type with A
- [ ] Measure real encoded size per type; compare against A's measured max write
- [ ] If over budget: shrink free-text caps or geo precision **before** anyone considers fragmentation
- [ ] Round-trip test: `Claim` → CBOR → bytes → CBOR → `Claim`, field-for-field identical
- [ ] Confirm enums serialize as **ints**, not names

### Day 2 — Signing the immutable core
- [ ] Define the canonical byte ordering for the signed payload — must be deterministic across devices
- [ ] Sign only: `id`, `type`, `originDeviceId`, `logicalClock`, `payload`, `createdAtLogical`
- [ ] **Exclude** `corroborations`, `claimTrust`, `dispatchPriority`, `hopLimit` — mutable or per-hop
- [ ] Verify a claim signed on device 1 validates on device 2
- [ ] Re-serializing a received claim produces a byte-identical signed core (this is what makes verification stable)

Deterministic ordering matters more than it looks: if two devices encode the same map in different key order, signatures fail for no visible reason.

### Day 3 — Ingest from the mesh
- [ ] `ingestClaim()` — accept a verified claim from A's layer and store it
- [ ] A claim already in the store → merge per type rules, don't duplicate
- [ ] Corroboration arriving separately → attach to the right claim, recompute trust
- [ ] `firstSeenVia` set correctly on ingest — this is what the anti-echo rule reads
- [ ] Ingest is idempotent: the same claim twice leaves the store unchanged

### Day 4 — Two-phone verification, then three-way integration
- [ ] Claim from phone 1 lands in phone 2's store with trust computed correctly
- [ ] **Relaying between two real phones does not move trust** — verify on hardware, not just in the harness
- [ ] Corroboration from a genuinely distinct second device *does* move it
- [ ] Join C: two SOS in one geohash bucket render as two pins
- [ ] Confirm C reads availability from my layer rather than caching it

### Day 5 — Query layer for the UI
- [ ] `watchActiveClaims()` — reactive stream C can bind to
- [ ] Filter by layer: emergency (`sos`, `sosProxy`, `hazardReport`) vs `resource`
- [ ] Sort helper for the volunteer queue: `dispatchPriority` then trust
- [ ] `availableFor(resourceClaim)` computing `max(0, pledged - claimed)` — **never a stored field**
- [ ] Relative-time helper from logical clocks, for C's "about 2 hours ago"

**Exit criteria:** claims cross the wire and land in the store with correct trust, and C's UI reads live from it.

---

# WEEK 3 — PHASE 3: REPORT FLOW

I take Report — geohash merging and confirmation counts, closest to what I've already built. A takes Rescue, C takes Contribute. Back to `b/` branches.

### Day 1 — Hazard report creation and merging
- [ ] Report creation end to end with all `HazardType` values
- [ ] Two reports, same type, same bucket, different devices → **one claim, count 2**
- [ ] Same type, **different** bucket → two separate claims
- [ ] **Different** type, same bucket → two separate claims (a flood and a road block at one junction are different facts)
- [ ] `confirmationCount` increments only on genuine independent generation

### Day 2 — The anti-echo rule under real conditions
- [ ] Device C receives A's report via relay, then files "the same" report → **does not count**
- [ ] Device C independently generates before ever seeing A's → **counts**
- [ ] Explicit attestation ("I can see this too") → counts, and is distinguishable in the record
- [ ] One device attesting twice → counted once (`PRIMARY KEY (claim_id, device_id)`)
- [ ] Test on real hardware with A, not only in the harness

**Why this matters:** without it, ten people "confirm" a rumour they all read on the same relayed message. That's one witness and nine repeaters.

### Day 3 — Report decay and lifecycle
- [ ] Hazard reports decay after their window; SOS types remain exempt
- [ ] A report with rising confirmations refreshes its window — an actively-reconfirmed hazard shouldn't expire
- [ ] Volunteer ground-confirms a report → `groundConfirmed`, decay stops
- [ ] Volunteer marks a hazard cleared (road reopened) → `resolved`, propagates
- [ ] Confirm `autoExpired` never appears on a SOS-type claim

### Day 4 — Corroboration weighting in practice
- [ ] Weighting genuinely uses `hopDistance` and `signalStrength`, not just device count
- [ ] Newcomer discount fires for a device unseen before the claim existed
- [ ] Contribution cap holds — one device can't push a claim to CORROBORATED alone
- [ ] Volunteer attestation weighted higher than a general user's, but still **attestation, not ground confirmation**
- [ ] Write the Sybil test: one device presenting five identities does **not** reach CORROBORATED

### Day 5 — Adversarial test suite
Formalise the cases from `CLAUDE.md` §6.2 as permanent tests:
- [ ] Two SOS, same bucket, same minute → two claims *(the critical one)*
- [ ] Replayed QR without fresh nonce → rejected
- [ ] Mesh-relayed corroboration → rejected
- [ ] Multi-identity corroboration → capped
- [ ] Twenty offline devices claiming one resource → floors at 0
- [ ] Storage pressure with active SOS → SOS retained
- [ ] Wire these into CI so they can't quietly regress

**Exit criteria:** hazard reports merge correctly, echo chambers can't inflate confidence, and the adversarial suite runs green in CI.

---

# WEEK 4 — PHASE 4: IDENTITY, CRDT, TIME

Phase 4 splits three ways across one feature. **My share: keypairs, secure storage, and node trust.** A does vouch/revocation transport; C does the volunteer UI.

### Day 1 — Keypair generation and secure storage
- [ ] Ed25519 keypair generated on first launch (libsodium via `cryptography` or similar)
- [ ] Private key in hardware-backed storage (Keystore/Keychain)
- [ ] Public key is the device identity — `originDeviceId` derives from it
- [ ] **Document honestly:** Android deletes Keystore keys on uninstall, so identity does not survive reinstall. Recovery is via vouching, not a server.
- [ ] Optional encrypted identity backup file — flag its theft risk if we build it

### Day 2 — Volunteer credentials and node trust
- [ ] Campaign credential = organiser's signature over the volunteer's public key
- [ ] `NodeTrust` state: `campaignVerified` / `vouchedProvisional` / `unverified`
- [ ] Phone number stored as a **display label only**, never a credential — deriving a credential from a 10-digit number with known prefixes would be trivially brute-forceable
- [ ] Verify a credential fully offline against the organiser's public key
- [ ] Provisional nodes: can respond to SOS and ground-confirm, **cannot pledge resources, cannot vouch**

### Day 3 — Vouching state, promotion, revocation
- [ ] Apply A's incoming vouch messages to local node trust
- [ ] **Two vouches from independent campaign-verified volunteers → promote to full trust**
- [ ] One vouch → stays provisional with limited powers
- [ ] Vouch cap of 5 enforced on receipt, read from inside the signed vouch
- [ ] Revocation overrides the vouch; most recent valid one wins by logical clock
- [ ] A revoked node's past corroborations are re-weighted, not silently deleted

### Day 4 — CRDT resource ledger
- [ ] Pick the CRDT library. **Semantics are already settled — add-only counters. Don't reopen that as part of picking a library.**
- [ ] `pledgedCount` and `claimedReports` as separate grow-only counters
- [ ] Merge two divergent replicas → both totals converge, availability floors at 0
- [ ] Twenty-device partition merge → **never negative** (the −19 case)
- [ ] Replica disagreement surfaces as a **range** for C ("2–6 packets")
- [ ] Volunteer-only reset of the authoritative count

### Day 5 — Time gossip
- [ ] Consume A's `kind: 6` readings; maintain a mesh-median estimate
- [ ] Weight volunteer clocks higher
- [ ] Estimate feeds `createdAtLogical` display values only — never identity, ordering, or SOS decay
- [ ] Tolerance window for matching hazard reports across drifted clocks, sized from A's measured drift
- [ ] Test: two devices 5 minutes apart still merge matching hazard reports correctly

**Exit criteria:** identity works fully offline, vouching promotes and revokes correctly, resource counters converge without going negative, and clock drift no longer breaks merging.

---

# WEEK 5 — HARDENING & CORRECTNESS

### Day 1 — Storage eviction
- [ ] 200 MB claim-store cap with eviction ordering: archived+resolved → oldest resolved → oldest low-priority resource pins
- [ ] **Active SOS is never evicted at any storage pressure** — test this explicitly by filling the store
- [ ] Warn the user before storage becomes critical
- [ ] Archived claims purge only after their retention window
- [ ] With A: confirm map tiles are evicted before active SOS records

### Day 2 — Partition and convergence
- [ ] With A: split the mesh, generate claims on both sides, rejoin
- [ ] Hazard reports merge correctly post-rejoin, counts sum without double-counting
- [ ] SOS claims from both sides stay distinct
- [ ] A resolution issued during partition applies after rejoin
- [ ] Conflicting `dispatchPriority` updates resolve by logical clock

### Day 3 — Performance on low-end hardware
- [ ] Load the store with 5,000 claims — how slow is the map query?
- [ ] Index effectiveness on `(status, type)` and `geohash_bucket`
- [ ] Reactive stream doesn't re-query the world on every insert
- [ ] Ingest throughput: can I keep up with a burst of relayed claims?
- [ ] Profile on the **cheapest** device we have, not the best

### Day 4 — Full adversarial re-run
- [ ] Run the whole suite from Week 3 Day 5 against real multi-device data
- [ ] Add: malformed CBOR payload → rejected, no crash
- [ ] Add: claim with valid signature but nonsense location → handled
- [ ] Add: sequence number replay from one device → detected
- [ ] Add: a `groundConfirmed` claim can't be downgraded by later contradicting corroborations

### Day 5 — Documentation and invariant audit
- [ ] Walk `CLAIM_SCHEMA.md` §12 line by line against the actual code — **every invariant, confirmed in the implementation, not assumed**
- [ ] Update the schema doc with anything decided during weeks 2–5
- [ ] Confirm every invariant-enforcing branch carries a comment explaining why
- [ ] Log any deviations found and fix or record them
- [ ] Close or re-scope my open questions below

**Exit criteria:** the data layer survives partitions, storage pressure, adversarial input, and low-end hardware — with the invariant audit signed off.

---

# BEYOND WEEK 5 — BACKLOG

- [ ] Delta sync — send only what a peer is missing rather than re-flooding
- [ ] Smarter geohash merging near bucket boundaries (two reports 10m apart, different buckets)
- [ ] Claim compaction — collapse a long corroboration list once past a confidence ceiling
- [ ] Encrypted identity backup/restore, if the team accepts the theft risk
- [ ] Historical archive export for post-disaster reporting (manual, offline — **not** a sync path)
- [ ] Tunable trust thresholds per deployment region

---

## Invariants I'm personally responsible for

Every one was a real bug in v1. Not stylistic.

- **SOS IDs are unique and never merge.** Two code paths, not one function with a branch. If someone refactors them together during a cleanup, the bug comes straight back.
- **Relaying is never corroboration.** v1 said "generated *or relayed*," which meant a fabricated SOS hit CORROBORATED — labelled "genuine evidence" — after a single hop.
- **The anti-echo rule holds.** Ten people confirming a rumour they all read on one screen is one witness and nine repeaters.
- **SOS never decays.** `displayLifetime` is `null` — not a large number. A person trapped alone is UNCONFIRMED *because* nobody is nearby to corroborate; blanket decay deletes the call for help from the person in most danger.
- **`available` is computed, never stored.** Storing it is how a counter goes negative when twenty offline devices merge.
- **Trust and priority stay separate.** A volunteer touching a claim knows no more than anyone else at that moment.
- **No wall clock in identity, ordering, or any decay decision affecting an SOS.**

---

## My PR checklist

Beyond the standard checks in `CLAUDE.md` §4.5:

- [ ] SOS unique-ID path and mergeable-ID path tested **separately** — confirmed not a shared code path
- [ ] Relaying does **not** upgrade `claimTrust`
- [ ] Anti-echo rule holds
- [ ] SOS/SOS_PROXY exempt from decay; `displayLifetime` is `null`
- [ ] `claimTrust` and `dispatchPriority` written independently
- [ ] Resource counters add-only; availability computed at read time
- [ ] All `data/` logic testable with no widget tree and no radio
- [ ] Reviewer named: **A**, per `CLAUDE.md` §3.3

---

## Progress log

| Date | Week/Day | Branch | What landed | Blocked on / notes |
|---|---|---|---|---|
| Day 1 | Wk1 D1 | `b/claim-schema` | SQLite setup + models | Selected `sqflite` over `drift` to execute raw schema precisely |
| Day 2 | Wk1 D2 | `b/claim-schema` | ID paths + critical test | `dart_geohash` for bucketing, `shared_preferences` for counter |
| Day 3 | Wk1 D3 | `b/claim-schema` | Trust engine + tests | Implemented rule set based on §3, tests passing |
| Day 4 | Wk1 D4 | `b/claim-schema` | Decay & logic clocks | `LogicalClock` Comparable + `MeshTimeGossip` stub |
| Day 5 | Wk1 D5 | `b/claim-schema` | Simulation harness | Proved merge, anti-echo, and resource flooring logic |

### Open questions I'm carrying

- [x] `sqflite` vs `drift` — decide Wk1 D1, note reason: Selected `sqflite` over `drift` to execute raw schema precisely
- [ ] CRDT library choice — Wk4 D4. **Semantics settled; don't reopen them.**
- [ ] `displayLifetime` defaults for hazard and resource — named constants until real data
- [ ] Clock-drift tolerance width — depends on A's Wk4 D4 measurement
- [ ] Retention window before archived claims purge — Wk5 D1
- [ ] Do we build encrypted identity backup, accepting the theft risk? — team call

### Encoded claim sizes (fill before the Wk1 sync, revise Wk2 D1)

| Claim type | CBOR size | Largest field | Under budget? |
|---|---|---|---|
| SOS | 38 | location | Yes |
| SOS_PROXY | 70 | reporterDeviceId | Yes |
| HAZARD_REPORT | 58 | location | Yes |
| RESOURCE | 68 | location | Yes |
| **Budget** | **≤ 400 bytes** | | |

### Invariant audit (Wk5 D5)

| Invariant | Verified in code | Notes |
|---|---|---|
| SOS IDs unique, never merge | ☐ | |
| Two separate ID functions | ☐ | |
| No timestamp in any claim ID | ☐ | |
| Relay never counts as corroboration | ☐ | |
| Anti-echo rule enforced | ☐ | |
| `displayLifetime` null for SOS | ☐ | |
| `autoExpired` impossible for SOS | ☐ | |
| Counters add-only, availability computed | ☐ | |
| Claims signed, never encrypted | ☐ | |
| Trust and priority separate | ☐ | |
| No server/sync/connectivity reference | ☐ | |
