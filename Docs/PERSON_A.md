# PERSON_A.md — Mesh & Transport

**Owner:** A
**Branch prefix:** `a/` · pairing branches `ab/`
**Primary folder:** `lib/mesh/`
**Reviews my PRs:** B (always, for anything in `mesh/`)
**I review:** B's `data/` PRs

Read `CLAUDE.md` and `CLAIM_SCHEMA.md` first. This is my task list and progress log — tick boxes as I go, keep the log at the bottom current.

---

## 1. What I own

Getting bytes from one phone to another with no internet, no router, no cell tower. Everything below the data layer.

- BLE advertising, scanning, connection, GATT read/write
- Wi-Fi Direct, **if** Phase 0 shows it's needed
- The envelope format and receive pipeline (`CLAIM_SCHEMA.md` §9)
- Signature verification at each hop
- Hop-limit decrement and the message de-dup cache
- Routing policy — full flood vs selective relay
- Volunteer beaconing and time-gossip transport
- Duty-cycled scanning and the battery budget

**What I don't own:** what a Claim *means*. I move opaque signed bytes. Trust logic, decay, merging, claim IDs are all B's. If I find myself writing `if (claimType == ...)` outside of routing policy, I've drifted into B's territory — stop and talk to them.

---

## 2. Why I go first

The whole project rests on one unproven assumption: **phones can find each other and pass messages over BLE reliably enough to matter.** That's not a software design question — it's "does the hardware and OS cooperate," and no architecture fixes bad radio range.

If BLE mesh is painful on our devices, everyone needs to know in week 1, not week 4 after a trust engine and a map have been built on top of it. My Phase 0 output is the input to everyone else's risk assessment.

---

# WEEK 1 — PHASE 0: BLE MESH SPIKE

> ⚠️ **The real Week 1 progress is not in this copy.** It lives on `a/ble-mesh-spike`, which has never been merged to `main` — Days 1–2 ticked, 3a marked `[~]` (passed, detail not yet backfilled), Day 4 partially measured, the measurements table filled in, and five progress-log entries. This file was branched from `main`, so Week 1 below is still the blank template and is **wrong**.
>
> Reconcile before either branch merges, or git will conflict across this whole section. Week 2 below is current and accurate.

**Throwaway code.** A separate scratch project, not the real app. The deliverable is *knowledge*. Resist making it nice.

### Day 1–2 — Two phones talking
- [ ] Scratch Flutter project; `flutter_blue_plus` or `flutter_reactive_ble` (pick one, note why)
- [ ] Android BLE permissions (`BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, location on older APIs)
- [ ] Phone 1 advertises a custom service UUID
- [ ] Phone 2 scans and discovers it
- [ ] Connect, write a hardcoded string over a GATT characteristic
- [ ] Phone 2 displays it on receipt
- [ ] **Both directions** — each phone can send and receive

**Expect trouble here:** the Android 12+ BLE permission model is genuinely fiddly and plugin docs lag behind. Budget time; it isn't a sign anything's wrong.

### Day 3 — Three phones, the actual mesh question
- [ ] Phones A and C deliberately **out of range** of each other (verify they can't see each other directly first)
- [ ] Phone B in between, in range of both
- [ ] Message from A arrives at C via B
- [ ] Move B out of the picture — confirm delivery **stops**. This proves genuine relay.

**Single most important test of the week.** If multi-hop doesn't work, the architecture needs rethinking and everyone must know immediately.

### Day 4 — Measurements
Rough is fine; absent is not.
- [ ] Range indoors through walls (m)
- [ ] Range outdoors line of sight (m)
- [ ] Discovery time — best and worst of ~10 tries
- [ ] Battery: 1hr continuous scanning (%, note device model)
- [ ] Battery: 1hr duty-cycled 10s on / 50s off — what we'll actually ship
- [ ] Max payload that reliably writes in one go

### Day 5 — Write-up and the size question
- [ ] `docs/PHASE0_MESH_FINDINGS.md`, one page
- [ ] Recommendation: **is Wi-Fi Direct needed for MVP, or is BLE alone enough?**
- [ ] **Take the max payload number to B before the sync.** The schema assumes ≤400 bytes fits in one write. If mine is lower, the schema changes — three-person conversation.

**Exit criteria:** I can answer with evidence — does multi-hop work, what's the real range and discovery time, what does scanning cost, how many bytes fit.

**Sync question that's mine to raise:** does measured payload capacity match what B's claims need to serialize? If not, we shrink the schema or build fragmentation. Fragmentation is a real feature with real failure modes (partial delivery, reassembly timeouts), not something to slip in quietly.

---

# WEEK 2 — PHASE 2: TRANSPORT ↔ DATA (paired with B)

Branch prefix `ab/`. C works in parallel swapping mocks for B's store — they don't need us.

**Why pair rather than split:** this seam is where the subtle bugs live. I can't see B's assumptions about the schema; B can't see mine about the wire. Three days at one keyboard beats debugging corrupted trust state later.

### Day 1 — Envelope and serialization ✅
- [x] `Envelope` class exactly per `CLAIM_SCHEMA.md` §9.1 — `lib/mesh/envelope.dart`
- [x] CBOR encode/decode round-trip against B's `Claim` model — byte-identical for all 7 `kind` values
- [x] `msgId` generated fresh per **transmission**, not per claim — a claim is re-sent many times
- [x] Measure real encoded size per claim type against the 400-byte budget — **SOS 222B, SOS_PROXY 252B, HAZARD_REPORT 227B, RESOURCE 232B** (after `originPubKey` was added on Day 2; 188–218B before)
- [x] With B: if any type is over budget, shrink fields or plan fragmentation. **Don't decide alone.** — nothing over budget, no fragmentation needed

Also: `fromCbor()`/`decode()` return a typed `EnvelopeDecodeResult` and **never throw**. A stranger's malformed packet is expected input on this transport, not a bug — an uncaught exception on the receive path is a crash an attacker can trigger at will.

### Day 2 — Signature verification at the hop ✅
- [x] Ed25519 verify on receipt using the originator's public key
- [x] Confirm signature covers `(v || kind || body)` and **excludes `hopLimit` and `msgId`** — proven by a test that survives three simulated relay hops and still verifies
- [x] Tampered body → rejected
- [x] Missing signature → rejected (zeroed *and* absent both fail; there is deliberately no "unsigned but acceptable" branch)
- [x] Malformed CBOR → rejected without crashing
- [x] Rejected messages are **not relayed and not stored**

**Found a real hole in §9.1 doing this.** The envelope defined `originSig` but carried no public key, and `originDeviceId` is a *truncated hash* of the key — not reversible. A relay three hops out has never met the originator and there is no server to ask, so the claims that travelled furthest were exactly the unverifiable ones. Fixed by carrying `originPubKey` (32 bytes) on the wire; every message is now self-verifying with no prior contact. **This changed §9.1 — a wire-format change, not just a type fix.**

`EnvelopeSigner.matchesDeviceId()` closes the follow-on gap: a valid signature doesn't stop a device putting a *neighbour's* `originDeviceId` in the body, which for SOS would mint ids in that neighbour's id space (§2). **Not yet wired into the pipeline** — it needs the decoded body, which is B's side of the boundary. Agree with B where that check lives before Day 4.

### Day 3 — Receive pipeline in the correct order ✅
Order is not arbitrary (`CLAIM_SCHEMA.md` §9.3):
- [x] 1. De-dup — `msgId` in seen cache → drop silently, don't relay
- [x] 2. Verify — invalid → drop, don't relay, **don't store**
- [x] 3. Decrement `hopLimit` — at zero, store locally but don't relay
- [~] 4. Store via B's layer, then relay per routing policy — pipeline calls an `EnvelopeSink` interface; **real wiring waits on B's `ingestClaim()`**, still open on their list. Routing policy is Day 5.
- [x] `seen_messages` cache with eviction — it can't grow forever
- [x] Same message twice → stored once, relayed once

Verification lands **before** storage so a malformed claim can't enter the store, and **before** relay so an honest device can't propagate a tampered one.

Two decisions here that are load-bearing, both tested directly:

- **Relay preserves `msgId`.** A fresh id per hop would make a flooded message arriving via five neighbours look like five distinct messages — each stored and re-relayed. That is a broadcast storm, i.e. the Wk5 D1 open question, caused by us rather than by density. §9.1's "random per transmission" means per *origination*, not per hop.
- **A rejected envelope is not recorded as seen.** Otherwise anyone could flood garbage `msgId`s, evict ids for real messages still in flight, and make the device re-accept and re-relay them.

`hopLimit` hitting zero **still stores** — §1.1, a hop limit bounds how far a message travels, not whether the device holding it keeps a copy.

### Day 4 — Two-phone end-to-end, then three-way integration
**Not started — needs two physical devices.** Everything above is software and testable on the host; this is the first Phase 2 item that genuinely cannot be. Emulator never counts for mesh code (§4.5). Real BLE transport still has to be wired to the pipeline, reusing Phase 0's proven GATT setup and its hardware lessons: never `Advertisement(name:)` on Android, explicit timeout on every native call, per-peer connection lock, `origin_device_id` from the keypair rather than the BLE address.

- [ ] Claim created on phone 1 arrives in phone 2's store, intact and verified
- [ ] Corroboration from a genuinely second physical device upgrades trust correctly
- [ ] **Relaying between two phones does NOT move trust** — verify on real hardware, not just B's harness
- [ ] Join C: a claim raised on phone 1 renders on phone 2's map
- [ ] Two SOS in the same geohash bucket → **two pins**, not one

### Day 5 — Routing policy v1
- [ ] Full flood for `sos`, `sosProxy`, `hazardReport` — every device relays
- [ ] Selective relay for `resource` — a stale resource pin is an inconvenience, not a life risk
- [ ] `hopLimit` defaults per type, using Phase 0 range data
- [ ] Relay queue with volunteer-first send ordering when several neighbours are available
- [ ] Basic backpressure — what happens when the send queue outpaces the radio

**Exit criteria:** two real phones exchanging signed claims, trust moving only for the right reasons, C's UI rendering claims that originated elsewhere.

---

# WEEK 3 — PHASE 3: RESCUE FLOW

I take Rescue — deepest grip on SOS propagation after Phase 2, and it's where never-merge and never-decay matter most. B takes Report, C takes Contribute. Back to `a/` branches.

### Day 1 — SOS creation and the three sub-types
- [ ] Individual SOS end to end: create → sign → flood → appears on other devices
- [ ] Group SOS carrying a `HeadcountBucket`
- [ ] **Proxy SOS** — for someone whose phone is dead; carries `reporterDeviceId` and a reporter-marked location
- [ ] Verify with B that each generates a **unique** ID via `sosClaimId()`, never the merge hash
- [ ] Two SOS raised in the same bucket seconds apart → two distinct claims on every device

### Day 2 — Flood behaviour under stress
- [ ] Three-phone flood: SOS from one edge reaches the far edge
- [ ] Measure end-to-end latency across 2 and 3 hops
- [ ] Rapid repeat SOS from one device → de-dup holds, no broadcast storm
- [ ] A device joining the mesh *after* an SOS was raised still receives it (late-join delivery)
- [ ] SOS survives a relay node dropping out mid-propagation

**Late-join matters more than it sounds:** a volunteer arriving an hour later must still see the active SOS. This is the practical reason SOS never decays.

### Day 3 — QR resolution, transport side
- [ ] `kind: 2` resolution envelope defined and propagating
- [ ] Carries `sosId`, `nonce`, requester signature, volunteer counter-signature
- [ ] Verify **both** signatures at the hop before applying
- [ ] Resolution floods back through the mesh like the original SOS
- [ ] A resolution for an **unknown** `sosId` is stored and applied when the claim later arrives

That last one is easy to miss: a resolution can outrun the original SOS to a distant device. Dropping it leaves the claim active forever on that phone.

### Day 4 — Replay and adversarial resolution
- [ ] Replayed QR payload with a stale nonce → **rejected**
- [ ] Resolution signed by a non-volunteer key → rejected
- [ ] Tampered `sosId` → signature check fails
- [ ] Manual resolution propagates but is tagged lower confidence
- [ ] Confirm with B: manual resolve **archives** rather than clears

### Day 5 — Volunteer dispatch signalling
- [ ] `dispatchPriority` transitions propagate: `seenByVolunteer`, `enRoute`
- [ ] Confirm these move **priority only, never trust** — a volunteer seeing a claim knows no more than any other device
- [ ] A claim can be `enRoute` while still `unconfirmed` — verify that state is reachable and renders for C
- [ ] Two volunteers both marking `enRoute` → last-write-wins by logical clock, both recorded

**Exit criteria:** an SOS can be raised, flood three hops, be marked en route by a volunteer, resolved by signed QR, and cleared everywhere — with replay attempts rejected.

---

# WEEK 4 — PHASE 4: IDENTITY, ROUTING, BEACONING

Phase 4 splits three ways across one feature. **My share: vouch and revocation as message kinds, plus volunteer beaconing.** B does keypairs and secure storage; C does the volunteer UI.

### Day 1 — Vouch messages
- [ ] `kind: 3` vouch envelope — voucher public key, vouchee public key, voucher signature
- [ ] Vouch propagates and is independently verifiable by any device, no server
- [ ] Vouch cap (5 per verified volunteer) carried **inside the signed vouch** so any device can check it
- [ ] A vouch signed by a `vouchedProvisional` node → **rejected.** Provisional nodes cannot vouch — this stops unbounded trust minting from one compromise.

### Day 2 — Revocation
- [ ] `kind: 4` revocation envelope
- [ ] Propagates like any other claim and overrides the vouch
- [ ] Most recent valid revocation wins, ordered by logical clock
- [ ] Revocation signed by someone other than the original voucher → rejected
- [ ] A revoked node's later messages stop being volunteer-weighted

### Day 3 — Volunteer beaconing
This replaces "directional relay," which cannot work — **BLE has no directional information, and in a full flood there's nothing left to prefer.**
- [ ] `kind: 5` beacon — signed "volunteer here" with a hop count
- [ ] Volunteer nodes broadcast periodically; interval tuned against battery
- [ ] Receiving devices build a gradient: "a volunteer is ~3 hops away via this neighbour"
- [ ] Gradient entries expire — volunteers move, and a stale gradient is worse than none
- [ ] Send ordering uses the gradient: volunteer-ward neighbours first
- [ ] Beacons rate-limited so they don't crowd out real traffic

### Day 4 — Time gossip transport
- [ ] `kind: 6` — devices exchange clock readings on meeting
- [ ] Hand readings to B's layer, which computes the median (volunteers weighted higher)
- [ ] Gossip **piggybacks on existing connections** rather than opening new ones — a battery decision, not a nicety
- [ ] Measure real clock drift between our test devices over 24h; note it (feeds an open question)

### Day 5 — Duty cycling and the battery budget
- [ ] Duty-cycled scanning (start 10s on / 50s off, tune from there)
- [ ] Low-power mode: drop `resource` traffic, keep SOS relay alive
- [ ] Measure against the **72-hour target** (mid-range phone, 50% start charge)
- [ ] Confirm SOS relay latency is still acceptable at the chosen duty cycle — **this is the real trade-off**
- [ ] Record actual numbers in `PHASE0_MESH_FINDINGS.md`

**Exit criteria:** volunteers can be vouched in and revoked fully offline; the mesh routes toward volunteers via beacon gradient; duty cycling has real numbers against the 72-hour target.

---

# WEEK 5 — HARDENING & FIELD TESTING

### Day 1 — Multi-device scale test
- [ ] Borrow as many phones as possible (target 6–8) into one mesh
- [ ] **Does flood routing cause broadcast storms at density?** (a listed open question — this is the week to answer it)
- [ ] Measure delivery rate and latency as device count rises
- [ ] Tune de-dup cache size and relay backoff against what you observe

### Day 2 — Partition and rejoin
- [ ] Physically split the mesh into two groups; raise claims in each
- [ ] Rejoin — do both sides converge?
- [ ] A resolution raised during partition applies correctly after rejoin
- [ ] With B: resource counters converge sanely and never go negative

### Day 3 — Failure modes
- [ ] Bluetooth toggled off mid-relay → graceful recovery, no crash
- [ ] App backgrounded → does relay survive? **Android background BLE limits are real — document what actually happens rather than what should**
- [ ] Phone reboots → mesh rejoins without user action
- [ ] Storage full → with B, confirm active SOS is never what gets evicted
- [ ] Very low battery → low-power mode engages, SOS still relays

### Day 4 — Outdoor field test
- [ ] Real distances outdoors, not corridors — walk the range out until delivery fails
- [ ] Multi-hop across a genuine physical gap (across a field, between buildings)
- [ ] Volunteer gradient behaviour when a volunteer physically moves
- [ ] Update range and `hopLimit` numbers with real-world figures

### Day 5 — Documentation and handoff
- [ ] Finalise `PHASE0_MESH_FINDINGS.md` with all measured numbers
- [ ] Write down every Android-specific gotcha hit along the way — **this is the knowledge that evaporates**
- [ ] Close or re-scope my open questions below
- [ ] Answer for the team: **do we need fixed relay points?** My battery and range data is the deciding evidence

**Exit criteria:** the mesh has been tested at realistic device counts, outdoors, across partitions and failures, with documented numbers rather than assumptions.

---

# BEYOND WEEK 5 — BACKLOG

Not scheduled. Pull from here when the above is solid.

- [ ] Wi-Fi Direct for higher-bandwidth transfers, **if** Phase 0 said we need it
- [ ] Single-tile map transfer over mesh — narrow fallback only: explicit request, Wi-Fi Direct only, above a battery threshold, **never on a volunteer node during active response**
- [ ] Fixed relay point mode (generator-powered node at a relief camp), if the team says yes
- [ ] Adaptive duty cycling — scan harder when claims are active nearby, back off when quiet
- [ ] Message fragmentation, **only** if a payload genuinely can't be shrunk under budget
- [ ] Protocol version negotiation for mixed-version devices in one mesh

---

## Invariants I'm personally responsible for

Others may not catch these in review.

- **Claims are signed, never encrypted** (`CLAUDE.md` §2.5). Every relay must read content to corroborate and render pins. If I'm tempted to encrypt a payload, the answer is no — read the reasoning before arguing for it.
- **Verify before store, verify before relay.** A malformed claim must never enter the store; a tampered one must never be propagated by an honest device.
- **The signature excludes `hopLimit` and `msgId`.** They change per hop; signing them breaks verification after the first forward.
- **`hopLimit` is not TTL.** A hop count, unrelated to `displayLifetime`. Never share a variable, config key, or name between them.
- **Relaying never touches trust.** My layer hands claims to B's; it never sets `claimTrust` itself.
- **No server, endpoint, or sync path.** A retry-until-connected loop means something's wrong — there's nothing to connect to.
- **No directional relay.** BLE has no direction. Beacon gradient plus send ordering is the working replacement.

---

## My PR checklist

Beyond the standard checks in `CLAUDE.md` §4.5:

- [ ] Tested on **at least two physical devices.** Emulator never counts for mesh code.
- [ ] Signature verified at hop; unsigned/malformed dropped and not relayed
- [ ] `hopLimit` decrements; de-dup cache prevents re-broadcast
- [ ] Battery impact noted in the PR description if scan behaviour changed
- [ ] Reviewer named: **B**, per `CLAUDE.md` §3.3
- [ ] No new reference to a server, endpoint, or connectivity path

---

## Progress log

> **This table is missing Week 1.** The Phase 0 entries live on `a/ble-mesh-spike`, which has never been merged to `main` — so this copy, branched from `main`, still shows the blank template for Week 1. Reconcile the two before either merges; see the note under Week 1.

| Date | Week/Day | Branch | What landed | Blocked on / notes |
|---|---|---|---|---|
| 2026-08-21 | Wk2 D1 | `ab/transport-data-wiring` | `Envelope` + CBOR round-trip per §9.1. Byte-identical round-trip for all 7 `kind` values; typed `EnvelopeDecodeResult` so malformed input never throws; `signingPayload()` excludes `hopLimit`/`msgId`. Real sizes measured for all 4 claim types. | Nothing. Sizes well under the 400B budget. |
| 2026-08-21 | Wk2 D1 | `ab/transport-data-wiring` | Reviewed B's Phase 1 data layer across five rounds. Found a `Uint8Buffer`/sqflite bug that would have made **every** `insertClaim()` throw, `origin_sequence` being aliased to the Lamport clock, a `signalStrength` sentinel that promoted the weakest signal to the strongest weight, and signatures held in a Dart `String`. All fixed on `ab/`. | B's branch tip was pushed post-merge; cherry-picked onto `ab/`, which is now source of truth. |
| 2026-08-21 | Wk2 D2 | `ab/transport-data-wiring` | Ed25519 sign/verify in `lib/identity/`, package `cryptography ^2.7.0`. `EnvelopeSigner.sign`/`.verify`; verify never throws. **Found and fixed a hole in §9.1**: no public key on the wire meant a relay could not verify a claim from a device it had never met. Added `originPubKey`. | `identity/` opened ahead of its Phase 4 assignment — B and C both need to be aware, per that folder's own reviewer rule. |
| 2026-08-21 | Wk2 D3 | `ab/transport-data-wiring` | Receive pipeline in exact §9.3 order + persisted `SeenMessageCache` with eviction. Relay preserves `msgId`; rejected envelopes are not recorded as seen. 96/96 tests green, `flutter analyze` clean. | Store step goes through an `EnvelopeSink` interface — **real wiring waits on B's `ingestClaim()`**. |

### Open questions I'm carrying

- [ ] `hopLimit` default per message type — **TBD pending Phase 0 range data.** Don't let anyone pick a number before that lands. **A provisional `10` is now in `ClaimFactory.provisionalHopLimit`** — named, not inlined, so the real value is a one-line change. Still a placeholder, not a decision.
- [ ] `SeenMessageCache.maxEntries` — provisional `2000`. Depends on real traffic rates nobody has measured. Deliberately generous: evicting too eagerly re-admits messages still in flight, which costs duplicate relays, not lost data.
- [ ] Where does `matchesDeviceId()` get called? It needs the decoded `originDeviceId` from `body`, which is B's side of the boundary — so it belongs in the sink, not the pipeline. **Settle with B before Day 4.**
- [ ] Who owns `identity/`? Opened early in Phase 2 because Day 2 needed signing. Officially Phase 4, unassigned. Secure key storage is explicitly *not* built — `loadOrCreateProvisional()` writes the seed to `SharedPreferences` in plaintext.
- [ ] Is Wi-Fi Direct needed for MVP at all? — Phase 0, Wk1 D5
- [ ] Broadcast storms at relief-camp density? — Wk5 D1
- [ ] Real clock-drift rate over 72h+ — first number Wk4 D4
- [ ] Do we need fixed relay points? — Wk5 D5, my data decides
- [ ] Android background BLE limits — how much relay survives backgrounding? Wk5 D3
- [ ] `flutter_blue_plus` vs `flutter_reactive_ble` — decide Wk1 D1, note reason:

### Measurements (fill Wk1 D4–5, revise Wk5)

| Measurement | Wk1 | Wk5 revised | Device / conditions |
|---|---|---|---|
| Range, indoors through walls | | | |
| Range, outdoors line of sight | | | |
| Discovery time (best / worst of 10) | | | |
| Battery, 1hr continuous scan | | | |
| Battery, 1hr duty-cycled 10s/50s | | | |
| Max single-write payload | | | *(measured on `a/ble-mesh-spike`: 512B, MTU 517)* |
| **Encoded envelope size, per claim type** | SOS 222B · SOS_PROXY 252B · HAZARD 227B · RESOURCE 232B | | Wk2 D2, after `originPubKey` added. Target ≤400B, ceiling 512B (§9.2) — comfortable headroom |
| Delivery latency, 2 hops | | | |
| Delivery latency, 3 hops | | | |
| Max devices tested in one mesh | | | |
| Clock drift over 24h | | | |
| **Multi-hop relay works?** | | | |
| **Wi-Fi Direct needed for MVP?** | | | |
| **72-hour target achievable?** | | | |
