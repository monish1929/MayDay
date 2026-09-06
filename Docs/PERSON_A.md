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

**Throwaway code.** A separate scratch project, not the real app — `spike/phase0_ble_mesh/`, not `lib/mesh/`. The deliverable is *knowledge*. Resist making it nice.

### Day 1–2 — Two phones talking
- [x] Scratch Flutter project — `spike/phase0_ble_mesh/`. Package: **`bluetooth_low_energy` ^6.2.1**, not `flutter_blue_plus`/`flutter_reactive_ble` — both are central-role only (scan+connect), neither can advertise, and a mesh node has to be peripheral **and** central at once. `flutter_ble_peripheral` advertises but exposes no GATT server. `bluetooth_low_energy` is the only Dart option that does both roles, including a GATT server with write callbacks. Trade-off: smaller user base. Fallback if it misbehaves: hand-written Android platform channel over `BluetoothGattServer`.
- [x] Android BLE permissions sorted — fixed a real bug where the spike unconditionally requested `locationWhenInUse` and treated any denial as fatal, when it's correctly unrequestable on API 31+ (manifest declares it `maxSdkVersion=30`, matching the `neverForLocation` flag on `BLUETOOTH_SCAN`). Verified clean on a real API 33 device.
- [x] Phone 1 advertises a custom service UUID — confirmed via `BluetoothGattServer addService()`/`onServiceAdded() status=0`
- [x] Phone 2 scans and discovers it — `FOUND` fired, 245ms on the one clean-methodology sample
- [x] Connect, write a hardcoded string over a GATT characteristic — `20B OK` write confirmed on real hardware
- [x] Phone 2 displays it on receipt — confirmed by direct observation
- [x] **Both directions** — A→B and B→A both confirmed. Bonus: de-dup cache verified working (A correctly dropped its own message after B relayed it back)

**Gotcha hit, as expected:** Android 12+ BLE permission model was genuinely fiddly; budgeted time for it, not a sign anything was wrong.

### Day 3 — Three phones, the actual mesh question
- [~] Phones A and C's direct write path deliberately cut (see below — **enforced in software, not by distance**)
- [~] Phone B in between, relaying, both discovering A and C
- [~] Message from A arrives at C via B, logged `hops=1`
- [~] Relay switched off (or B's block re-applied) — confirm delivery **stops**

**Redesigned after two failed attempts — see `PHASE0_MESH_FINDINGS.md` §12–§13 for why.** Distance-based separation doesn't work for this test: discovery range materially exceeds write range and both edges are fuzzy, and worse, if *both* the direct and relayed path exist, de-dup silently hides a working relay (A's direct `hops=0` copy usually wins the race against B's `hops=1` copy, so C logs `hops=0` and drops the relay as a dup — the relay worked and the log said it didn't). Fixed by adding a **tap-to-block** control to each peer chip: blocks writes to that node by label (not peripheral UUID, since BLE addresses rotate — §7) while leaving discovery alone, so the negative control is a fact you can point at instead of a distance you hope holds. `README.md` Day 3 is now split into **3a** (relay logic, desk test, software-blocked topology) and **3b** (relay across real distance, only after 3a passes).

**3a re-run since the redesign: passed.** Confirmed working with the tap-to-block topology. **Granular detail not yet backfilled** — exact hop logs, which direction(s) were run, and explicit confirmation of the negative control (relay OFF → no delivery) still need recording here before this entry is on par with the rest of this log. Until that's filled in, treat "passed" as A's word, not yet as documented evidence. 3b (real distance) has not been attempted.

### Day 4 — Measurements
Rough is fine; absent is not.
- [x] Range indoors through walls (m) — **no write-range boundary found within a home**, all test points inside <10m. RSSI -39 (near) to -94 (far corner, through wall+bathroom); writes incl. 512B probes mostly still succeeded at -94. The ~50 dB drop is wall attenuation, not distance. See `PHASE0_MESH_FINDINGS.md` §11.
- [~] Range outdoors line of sight (m) — three informal, uncontrolled data points, none walked or marked to a known distance: ~40m pre-TX-HIGH-patch (§10, discovery intermittent, writes failing at status 133); ~100m on the TX-HIGH build as a Day 3 byproduct (§12, discovery persisted badly, writes never succeeded); ~50m on the TX-HIGH build from a dedicated two-phone write-range session (§13, RSSI correlated cleanly with write success across the run). Consistent picture: discovery range meaningfully exceeds write range outdoors. **Still needs a real walked/marked-distance Day 4 re-run.**
- [~] Discovery time — best and worst of ~10 tries — 1 clean sample, 245ms (methodology: advertise on both phones first, confirm both show "advertising as X," *then* start scanning — an earlier 5.8s reading was human button-tapping lag, not radio latency, and was discarded). 9 more runs still needed for a real best/worst-of-10.
- [ ] Battery: 1hr continuous scanning (%, note device model) — not started. Prerequisites worked out: airplane mode on then Bluetooth back on manually (isolates BLE from cellular/WiFi), screen off, disable OEM battery-killing for the app, unplugged, no Battery Saver. `adb shell dumpsys battery` before/after for exact %.
- [ ] Battery: 1hr duty-cycled 10s on / 50s off — what we'll actually ship — not started; duty-cycling isn't implemented in the app yet, needs a `Timer.periodic`.
- [x] Max payload that reliably writes in one go — **512B confirmed, repeatedly, both directions, even at RSSI -91.** Negotiated ATT MTU 517 (~514B hard ceiling). `CLAIM_SCHEMA.md`'s ≤400B assumption holds with headroom — **no fragmentation needed.**

### Day 5 — Write-up and the size question
- [~] `PHASE0_MESH_FINDINGS.md` — in progress, not a "one page" any more: 13 sections, real bugs found and fixed documented with root cause (advertisement-name hang, GATT client exhaustion, TX-power ceiling, missing write-path timeout), two range findings, one inconclusive relay attempt with root cause, one write-range session. Lives in `spike/phase0_ble_mesh/`, not shared `Docs/` — throwaway A-owned working material.
- [ ] Recommendation: is Wi-Fi Direct needed for MVP, or is BLE alone enough? — not yet answered; 3a passing removes one blocker, but still needs 3b (relay at real distance) and a proper walked outdoor range figure.
- [x] **Took the max payload number to the team.** 512B confirmed >> the 400B schema assumption. No fragmentation needed at current schema budget — this is now evidence, not an assumption.

**Exit criteria:** I can answer with evidence — does multi-hop work, what's the real range and discovery time, what does scanning cost, how many bytes fit. **3 of 4 fully answered. Multi-hop is partially answered: 3a (relay logic) passed, but without detailed evidence recorded yet, and 3b (relay at real distance) hasn't been attempted.**

**Sync question that's mine to raise:** does measured payload capacity match what B's claims need to serialize? **Answered — yes, with headroom.** 512B measured vs 400B budgeted.

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

`EnvelopeSigner.matchesDeviceId()` closes the follow-on gap: a valid signature doesn't stop a device putting a *neighbour's* `originDeviceId` in the body, which for SOS would mint ids in that neighbour's id space (§2). **Now wired**, in `ClaimIngestion.ingest()` rather than the pipeline — it needs the decoded body, so it belongs on B's side of the seam. `MeshNode` additionally refuses to *relay* a claim rejected for `deviceIdMismatch` or `forgedClaimId`: forwarding a lie a signature cannot catch would make an honest device an amplifier for it.

### Day 3 — Receive pipeline in the correct order ✅
Order is not arbitrary (`CLAIM_SCHEMA.md` §9.3):
- [x] 1. De-dup — `msgId` in seen cache → drop silently, don't relay
- [x] 2. Verify — invalid → drop, don't relay, **don't store**
- [x] 3. Decrement `hopLimit` — at zero, store locally but don't relay
- [x] 4. Store via B's layer, then relay per routing policy — wired end to end in `MeshNode`: pipeline → `ClaimIngestion` → `RelayQueue`. Frame handling is serialised, because the store-then-relay sequence must not interleave across frames.
- [x] `seen_messages` cache with eviction — it can't grow forever
- [x] Same message twice → stored once, relayed once

Verification lands **before** storage so a malformed claim can't enter the store, and **before** relay so an honest device can't propagate a tampered one.

Two decisions here that are load-bearing, both tested directly:

- **Relay preserves `msgId`.** A fresh id per hop would make a flooded message arriving via five neighbours look like five distinct messages — each stored and re-relayed. That is a broadcast storm, i.e. the Wk5 D1 open question, caused by us rather than by density. §9.1's "random per transmission" means per *origination*, not per hop.
- **A rejected envelope is not recorded as seen.** Otherwise anyone could flood garbage `msgId`s, evict ids for real messages still in flight, and make the device re-accept and re-relay them.

`hopLimit` hitting zero **still stores** — §1.1, a hop limit bounds how far a message travels, not whether the device holding it keeps a copy.

### Day 4 — Two-phone end-to-end, then three-way integration
**Code ready, hardware run still outstanding — needs two physical devices.** Emulator never counts for mesh code (§4.5).

`BleMeshTransport` now exists in `lib/mesh/`, carrying Phase 0's proven GATT setup and all four hardware lessons: never `Advertisement(name:)` on Android, explicit timeout on every native call, per-peer connection lock, and BLE addresses treated as routing handles rather than identity. MTU is negotiated to 517 — the 23-byte default allows a 20-byte write, so every envelope would fail without it.

The wiring above the radio is proven against a fake transport (`test/mesh/mesh_node_test.dart`, 11 tests) including the §6.2 two-SOS-one-bucket case across the wire. **That proves the wiring, not the hardware.** Everything below is still unticked because none of it has seen a radio.

**Before the two-phone run, two things are needed that are not in this branch:**
1. Android BLE permissions in the app manifest (`BLUETOOTH_SCAN` with `neverForLocation`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, plus the `maxSdkVersion=30` legacy trio). The spike's manifest is the reference.
2. An app that runs at all — `lib/main.dart` and the `android/` host live on `origin/c/app-shell`, not here. Day 4's last two items need C's UI regardless.

- [x] Claim created on phone 1 arrives in phone 2's store, intact and verified — **PASSED.** Claim `3cb7b2c0…` originated on the Motorola (`a5f0f503…`, seq 1) and is present in the Xiaomi's `claims` table with identical id, origin device id and sequence, `badsig=0`. Verified by pulling both SQLite stores off the devices, not by reading the log.
- [ ] Corroboration from a genuinely second physical device upgrades trust correctly — **not attempted.** Needs an explicit-attestation path; nothing raises one yet.
- [x] **Relaying between two phones does NOT move trust** — **PASSED on hardware.** The Xiaomi received that claim, relayed it (`relayed=1`), and its stored copy is still `claim_trust=0` (unconfirmed). §2.2 holds across a real radio, not just in B's harness.
- [ ] Join C: a claim raised on phone 1 renders on phone 2's map — **blocked on C.** The map reads `mock_data.dart`; the mock→real swap is PERSON_C.md Wk2 D1, unstarted.
- [x] Two SOS in the same geohash bucket → **two records** — **PASSED, and this is the §6.2 case.** The Xiaomi raised two SOS at identical coordinates (one bucket) across two launches: ids `fe813f67…` (seq 1) and `1e80f07a…` (seq 2), completely distinct. With the Motorola's, that is **three distinct SOS records in one geohash bucket**. Under a shared id rule they would have collapsed into one and resolving one would have erased the others. The pin half of this item is C's.

**Also confirmed on device:** `display_lifetime_ms` is **NULL** on every SOS row (§2.3 — not a large number, actually null), and `hop_limit=8` on the wire, i.e. `RoutingPolicy`'s per-type value rather than `ClaimFactory.provisionalHopLimit=10`. That settles which of the two provisional hop limits actually governs propagation — the open question below is about the disagreement, not about behaviour.

**Three bugs found, all only findable on hardware** (see the fix commit): the plugin's managers were never authorized, so `addService`/`startAdvertising` silently never completed; every failure path returned in silence because `main.dart` discards the result; and `dart:developer`'s `log()` never reaches `adb logcat`. A fourth — a 5s timeout applied to a call that raises a permission dialog and waits on a human.

**RESOLVED: delivery is now bidirectional.** Root cause was not the radio. `RelayQueue.drain()` cleared the queue *before* attempting sends and ignored the result, so a failed write destroyed the envelope — every claim got exactly ONE delivery attempt in its life, and a phone whose GATT connect timed out once delivered nothing ever again. Undelivered envelopes are now re-queued; `critical` retries indefinitely (§1.1), droppable and standard are re-capped as on enqueue. Four new tests cover it.

Proof on hardware: both phones ended at `rx=2 dup=1 stored=1 relayed=1`, and the Xiaomi's claim `c760ad8be99b…` (seq 5) reached the Motorola's store **after 4 logged `send FAILED` timeouts**. Its earlier claims (seq 1–4, raised before the fix) never arrived and are gone — the same radio conditions, the only difference being whether a transient failure was allowed to destroy the message.

**Superseded, kept for the record: delivery was one-directional in the first run.** The Motorola never received the Xiaomi's claims (`rx=1 dup=1 stored=0` — the one envelope it saw was its own, relayed back, correctly dropped by de-dup). Probable cause found and fixed: `_peers` had no eviction, so rotated BLE addresses accumulated (`peers=2` with two phones in the room) and the relay queue drained onto dead handles. Re-test after the eviction fix.

### Day 5 — Routing policy v1
- [x] Full flood for `sos`, `sosProxy`, `hazardReport` — every device relays. `RoutingPolicy.decide()`; resolutions, vouches and revocations flood too.
- [x] Selective relay for `resource` — the one droppable claim type. Availability is add-only and self-corrects, so a shed resource claim costs a stale count, not a life.
- [~] `hopLimit` defaults per type — **PROVISIONAL, still an open question (CLAUDE.md §8).** Constants exist and the type *ordering* (SOS > hazard > resource) is a real decision, but the absolute numbers have nothing behind them: Phase 0 measured single-hop write range and never ran 3b, so nobody knows what one hop buys in the field. Needs a walked 3b run and a team call, not a routing-layer guess.
- [x] Relay queue with volunteer-first send ordering when several neighbours are available — `RelayQueue.drain()` sorts volunteers first. Every peer is currently a non-volunteer until beaconing lands in Week 4, which degrades this to insertion order rather than breaking it.
- [x] Basic backpressure — droppable traffic is capped and shed oldest-first; standard traffic has a generous cap. **SOS and resolutions have no cap and no eviction branch at all** (§1.1 — a queue cap is an eviction rule). Tested at `maxDroppable: 0, maxStandard: 0`: 50 SOS all survive.

**Exit criteria:** two real phones exchanging signed claims, trust moving only for the right reasons, C's UI rendering claims that originated elsewhere.

---

# WEEK 3 — PHASE 3: RESCUE FLOW

I take Rescue — deepest grip on SOS propagation after Phase 2, and it's where never-merge and never-decay matter most. B takes Report, C takes Contribute. Back to `a/` branches.

### Day 1 — SOS creation and the three sub-types
- [x] Individual SOS: create → sign → store → flood. `SosOrigination.raiseIndividual` (`lib/flows/rescue/sos_origination.dart`). **"Appears on other devices" is untested** — none of this has touched a radio.
- [x] Group SOS carrying a `HeadcountBucket` — `raiseGroup`. A bucket, not a count: "6–15" is what a frightened person on a roof can actually tell you, and a precise number would be a false precision that dispatch decisions then get made on.
- [x] **Proxy SOS** — `raiseProxy`, carrying `reporterDeviceId` and a reporter-marked location; note capped at 80 chars per §9.2 rather than refused, because an SOS that fails to send because somebody typed too much is not an acceptable failure mode.
- [x] Each generates a unique ID via `sosClaimId()`, never the merge hash — **checked in code on the outbound path**, not only the inbound one. The inbound check in `ClaimIngestion` guards this device against a stranger's forged id; the outbound one guards the whole mesh against a bug in our own factory. Different failures, same symptom, and the symptom is the worst one in the project.
- [ ] **Verify with B** that the outbound check belongs there, and that `identityRuleViolated` is the failure `data/` wants to see
- [ ] Two SOS raised in the same bucket seconds apart → two distinct claims on every device. `DebugSosTrigger.raiseSosSuite` raises all three sub-types at one location for exactly this — not yet run on hardware, and no unit test written.

**One origination path, not three.** The sub-types differ only by payload; the id rule, the signing, the rebuild-from-signed-bytes and the flood are shared. Three paths would have been three places for the SOS id rule to drift.

### Day 2 — Flood behaviour under stress
- [ ] Three-phone flood: SOS from one edge reaches the far edge
- [ ] Measure end-to-end latency across 2 and 3 hops
- [ ] Rapid repeat SOS from one device → de-dup holds, no broadcast storm
- [ ] A device joining the mesh *after* an SOS was raised still receives it (late-join delivery)
- [ ] SOS survives a relay node dropping out mid-propagation

**Late-join matters more than it sounds:** a volunteer arriving an hour later must still see the active SOS. This is the practical reason SOS never decays.

### Day 3 — QR resolution, transport side
- [x] `kind: 2` resolution envelope defined — `lib/mesh/messages/resolution_message.dart`
- [x] Carries `sosId`, `nonce`, requester signature, volunteer counter-signature. The counter-signature **is** the envelope's `originSig` and the volunteer's key **is** `originPubKey` — not repeated in the body, which would cost 96 bytes against the 400B budget for no extra proof.
- [x] Verify **both** signatures at the hop before applying — the envelope signature in the pipeline (§9.3 step 2), the requester's in `ResolutionIngestion`, which is the first point the bytes are decoded far enough to find it. One good signature and one forged one must not clear an SOS: the pair is the entire proof that two devices were physically in the same place.
- [x] Resolution floods back through the mesh like the original SOS — `resolutionHopLimit == sosHopLimit`, and `RelayPriority.critical`, so it is never shed under queue pressure
- [x] A resolution for an **unknown** `sosId` is parked and applied when the claim arrives — `PendingResolutionStore`, persisted, so a restart between the two arrivals does not lose it. Dropping it would leave that phone showing the rescue as active **forever**: SOS never decays, so nothing else would ever clear it.
- [x] QR payload build/parse, and the volunteer's counter-sign-apply-flood — `lib/flows/rescue/qr_resolution.dart`

**Replay rejection is Day 4 and is not built.** A fresh nonce is generated per *display*, which is what makes Day 4's test possible — but nothing yet refuses a stale one. Do not read the nonce field as replay protection.

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
- [x] `kind: 3` vouch envelope — `lib/mesh/messages/vouch_message.dart`. Voucher key and signature ride on the envelope (§9.1); the body carries the vouchee key, the index and the cap.
- [x] Vouch propagates and is independently verifiable by any device, no server. A **rejected** vouch is still relayed: this device refusing it usually means only that *this device* has never heard of the voucher, and a phone three hops on may hold that anchor. Refusing to forward would make each device's ignorance contagious.
- [x] Vouch cap (5 per verified volunteer) carried **inside the signed vouch**. Two guards, deliberately. The wire cap is refused above 5 — "carried inside the vouch" only helps if the receiver also declines to believe a voucher that grants itself a cap of 500. And enforcement is the receiver *ranking* a voucher's vouches by the logical clock it signed and taking the first five, because delivery is out of order and "the first five this device happened to hear" would give two devices two different answers about one voucher.
- [x] A vouch signed by a `vouchedProvisional` node → **rejected** (`TrustWriteRejection.voucherNotVerified`)
- [x] `NodeTrust` + `NodeCapabilities` (`lib/identity/node_trust.dart`) and `VouchRegistry` (`lib/identity/vouch_registry.dart`)

**Nothing is campaign-verified in any build today,** so no vouch is currently accepted from anyone: the whole web hangs off the `trust_anchors` table, and issuing campaign credentials is B's Phase 4 work. That is the right failure direction — nobody is trusted by accident — but it does mean vouching cannot be exercised end to end until B's half lands. There is deliberately no convenience bypass; a trust registry with one is not a trust registry.

**Doc drift found, flagged not resolved.** `MAYDAY_PROJECT_CONTEXT.md` §2.2 says two independent campaign-verified vouches promote a node to "full trust", but `CLAIM_SCHEMA.md` §11 fixes `NodeTrust` at three values with no slot for it. Rather than invent a fourth enum value — a §11 change needs all three of us — the promotion is expressed as a capability (`NodeCapabilities.canPledgeResources`) and the tier stays `vouchedProvisional`. **Raise at the next team sync.**

### Day 2 — Revocation
- [x] `kind: 4` revocation envelope — `lib/mesh/messages/revocation_message.dart`
- [x] Propagates like any other claim and overrides the vouch — flooded, never droppable, so it can outrun the vouch it cancels
- [x] Most recent valid revocation wins, ordered by logical clock. It cancels vouches at or **below** its own counter, so a genuine re-vouch signed afterwards stands again — "most recent wins" has to cut both ways, or a revoked volunteer could never be reinstated, there being no network to do it over.
- [x] Revocation signed by someone other than the original voucher → rejected (`notTheOriginalVoucher`). Without it, one shouted 100-byte message strips any volunteer of their status — a denial of service aimed squarely at the responders.
- [x] A revoked node's later messages stop being volunteer-weighted — `capabilitiesOf` drops to `unverified`, so its beacons are dropped and its clock readings lose volunteer weight

### Day 3 — Volunteer beaconing
This replaces "directional relay," which cannot work — **BLE has no directional information, and in a full flood there's nothing left to prefer.**
- [x] `kind: 5` beacon — `lib/mesh/messages/beacon_message.dart`. **The hop count is deliberately not a field in the body**, and cannot be: the body is exactly what `originSig` covers, so the first relay to increment a counter would invalidate the signature and every device past it would drop the beacon. Hop distance is derived from what is left of the envelope's `hopLimit` — the field designed to change per hop, and the same reasoning §9.1 uses to exclude it from the signature.
- [x] Volunteer nodes broadcast periodically — `MeshBootstrap.beaconInterval`. `emitBeacon()` returns null on a device the mesh has not vouched for, so an ordinary phone spends no radio on this at all.
- [ ] **Interval tuned against battery** — 60s is a placeholder. That is Day 5's job, and Day 5 has no numbers yet.
- [x] Receiving devices build a gradient — `VolunteerGradient`, keyed by volunteer, best route chosen by beacon sequence first and hops second. Sequence first matters: a beacon that took a slow four-hop route can easily arrive after a newer one-hop beacon, and letting it win would point the gradient at the longer path.
- [x] Gradient entries expire, and routes through a departed neighbour are forgotten outright. **In memory, never persisted** — reloading yesterday's gradient after a restart would send SOS traffic confidently toward a volunteer who left hours ago, which is worse than having no preference, because the device would stop looking.
- [x] Send ordering uses the gradient — `RelayQueue._orderTargets`. **Order, never the set:** every neighbour is still written to, so this is send ordering and not an eviction rule (§1.1). If it ever becomes a filter, that is the bug.
- [x] Beacons rate-limited — two guards. `RoutingPolicy` classes them droppable, and `BeaconIngestion` refuses to re-relay the same volunteer's beacon inside a minimum interval. Per volunteer, not globally: two volunteers beaconing at once are two facts the gradient needs, and silencing one because the other just spoke hides a whole route.
- [x] A beacon from a key nobody has vouched for is **dropped, never believed.** A beacon is a self-assertion — anyone can sign "volunteer here" — and believing one would let any phone put itself at the front of the queue for every SOS in range.

### Day 4 — Time gossip transport
- [x] `kind: 6` — `lib/mesh/messages/time_gossip_message.dart` + `TimeGossipIngestion`. Never relayed: a clock reading is evidence about the two devices that exchanged it, and forwarding one secondhand would let a single skewed clock propagate as though many devices had independently observed it — exactly what a median is supposed to prevent.
- [x] Readings handed to B's layer, with the volunteer flag it has no way to work out for itself
- [ ] **B's layer does not compute a median.** `MeshTimeGossip.receiveGossip` does a running weighted average instead. That is a `data/` change and therefore B's (§3.3) — raised with B, not reimplemented on my side.
- [x] Gossip **piggybacks on existing connections** — `MeshNode.gossipTime()` writes only to peers the transport already has and opens nothing. One BLE connection is a connect, a negotiate, a write and a disconnect; spending that to swap a timestamp on a 72-hour budget is the trade §1.1 says to make the other way round.
- [ ] Measure real clock drift between our test devices over 24h — not started. `TimeGossipIngestion.samples` and `meanAbsoluteOffsetMs` exist to read it off a phone when it is.

**This is gossip, not sync, and the difference is the whole point.** §1.2 rules out NTP because there is no network to sync against; it does not rule out two phones that meet comparing notes. Nobody is authoritative, no single reading is believed, and the output may only ever render "about 2 hours ago" beside a pin. Ordering, merging, decay and claim identity stay on logical clocks (§4).

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
- **A production `lib/mesh/` must never set the advertisement name on Android.** Doing so silently renames the whole phone system-wide and persistently — found the hard way in Phase 0 (`PHASE0_MESH_FINDINGS.md` §6). Node labels travel in manufacturer-specific data instead.
- **BLE address is not stable device identity.** Android rotates it per advertising session (§7, observed twice more in §12/§13). `origin_device_id` must always come from the persistent Ed25519 keypair — now enforced in code: `DeviceKeyPair.deviceId` derives from the public key (`lib/identity/keypair.dart`).
- **`msgId` is preserved across relay hops, minted fresh only at origination.** A new id per hop makes one flooded message look like N distinct messages to every downstream device — each stored and re-relayed. That is a self-inflicted broadcast storm, not a density problem.

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


| Date | Week/Day | Branch | What landed | Blocked on / notes |
|---|---|---|---|---|
| 2026-08-18 | Wk1 D1–2 | `a/ble-mesh-spike` | Spike scaffold, package decision (`bluetooth_low_energy` ^6.2.1), Flutter SDK + Android toolchain installed, two real bugs fixed (`respondWriteRequest` arg mismatch, `locationWhenInUse` wrongly requested on API 31+). Windows cross-drive Kotlin incremental-compiler bug worked around (`kotlin.incremental=false`). **Day 1–2 complete on real hardware:** both phones advertise, discover (245ms clean sample), write, receive both directions; de-dup cache confirmed. | Day 3 blocked on a third phone at this point. Day 4 mostly outstanding. |
| 2026-08-19 | Wk1 D3–4 | `a/ble-mesh-spike` | Liveness heartbeat → later redesigned as advertisement-based (no connections). Three real bugs found and fixed on hardware: ping-vs-Send race crashing the plugin, silent Advertise/Scan failures with no try/catch, GATT client-registration exhaustion (`status=257`) at 3 phones (`PHASE0_MESH_FINDINGS.md` §8). Found and fixed the big one: `Advertisement(name:)` on Android silently renames the whole phone and can hang `startAdvertising()` forever if the adapter name doesn't change (§6) — misdiagnosed twice before finding the real cause. | Day 3 blocked differently: Motorola couldn't advertise at all until the §6 fix (unrelated to the name-hang root cause investigation — same underlying bug). |
| 2026-08-20 | Wk1 D3 | `a/ble-mesh-spike` | First real three-phone Day 3 attempt. **Inconclusive:** middle phone (B) never had Scan on, so its peer list stayed empty and relay was a structural no-op regardless of the relay toggle — root cause was a gap in the Day 3 protocol itself, not a mesh/plugin bug (§12). Also recorded A-C separation (~100m outdoor) and a second BLE-address-rotation sighting. | Day 3 still not done — protocol gap fixed but needed a clean re-run. |
| 2026-08-20 | Wk1 D4 | `a/ble-mesh-spike` | Outdoor write-range session, two phones, ~50m informal estimate. RSSI correlated cleanly with write success across the session (weak → `TIMED OUT`/status 133, strong → `OK`), confirming write range is meaningfully shorter than discovery range on the TX-HIGH build (§13). Reconfirmed the stale-peer-UUID artifact from §7. | Still not a controlled, walked/marked-distance measurement. |
| 2026-08-20 | Wk1 D3 | `a/ble-mesh-spike` | **Redesigned the Day 3 test itself**, having concluded distance-based separation can't work: it can't guarantee no direct path, and worse, when both direct and relayed paths exist, de-dup hides a working relay (direct `hops=0` usually wins the race, so C never sees `hops=1` even if relay succeeded). Added tap-to-block on peer chips (blocks by node label, not peripheral UUID, since BLE addresses rotate), a write-quality hint next to RSSI (`write ok`/`write marginal`/`advert only`, thresholds from §13's own data), and split the README's Day 3 into 3a (relay logic, desk test) and 3b (relay across real range). `flutter analyze` clean, debug APK builds. | **Day 3 still the one open item** — needs a run with the new tooling. Not yet attempted. |
| 2026-08-21 | Wk2 D1 | `ab/transport-data-wiring` | `Envelope` + CBOR round-trip per §9.1. Byte-identical round-trip for all 7 `kind` values; typed `EnvelopeDecodeResult` so malformed input never throws; `signingPayload()` excludes `hopLimit`/`msgId`. Real sizes measured for all 4 claim types. | Nothing. Sizes well under the 400B budget. |
| 2026-08-21 | Wk2 D1 | `ab/transport-data-wiring` | Reviewed B's Phase 1 data layer across five rounds. Found a `Uint8Buffer`/sqflite bug that would have made **every** `insertClaim()` throw, `origin_sequence` being aliased to the Lamport clock, a `signalStrength` sentinel that promoted the weakest signal to the strongest weight, and signatures held in a Dart `String`. All fixed on `ab/`. | B's branch tip was pushed post-merge; cherry-picked onto `ab/`, which is now source of truth. |
| 2026-08-21 | Wk2 D2 | `ab/transport-data-wiring` | Ed25519 sign/verify in `lib/identity/`, package `cryptography ^2.7.0`. `EnvelopeSigner.sign`/`.verify`; verify never throws. **Found and fixed a hole in §9.1**: no public key on the wire meant a relay could not verify a claim from a device it had never met. Added `originPubKey`. | `identity/` opened ahead of its Phase 4 assignment — B and C both need to be aware, per that folder's own reviewer rule. |
| 2026-08-21 | Wk2 D3 | `ab/transport-data-wiring` | Receive pipeline in exact §9.3 order + persisted `SeenMessageCache` with eviction. Relay preserves `msgId`; rejected envelopes are not recorded as seen. 96/96 tests green, `flutter analyze` clean. | Store step goes through an `EnvelopeSink` interface — **real wiring waits on B's `ingestClaim()`**. |
| 2026-08-25 | Wk2 D5 | `ab/transport-data-wiring` | **Day 5 routing policy.** `RoutingPolicy` (full flood for sos/sosProxy/hazard/resolution/vouch/revocation, selective for resource, time gossip never relayed) and `RelayQueue` (volunteer-first drain, backpressure). SOS and resolutions sit in a priority class with no cap and no eviction branch — §1.1 means a queue cap is an eviction rule. 18 new tests. | `hopLimit` defaults still provisional; 3b never ran, so nobody knows what one hop buys. |
| 2026-08-25 | Wk2 D4 | `ab/transport-data-wiring` | **Day 4 code, not Day 4 evidence.** `MeshTransport` seam + `MeshNode` joining radio → pipeline → ingestion → relay queue, and `BleMeshTransport` porting Phase 0's GATT setup with all four hardware lessons. New rule: a claim rejected for `deviceIdMismatch`/`forgedClaimId` is not relayed — an honest device must not amplify a lie the signature cannot catch. 137/137 tests green, `flutter analyze` clean. | **Nothing here has touched a radio.** Needs two phones, manifest permissions, and C's app shell (`origin/c/app-shell`) before the Day 4 boxes can be ticked. |
| 2026-09-06 | Wk3 D1, D3 | `a/phase3-4-message-kinds` | **Rescue flow, transport side.** `SosOrigination` with all three SOS sub-types through one path, outbound id-rule check so a bug in our own factory cannot mint a colliding SOS id. `kind: 2` resolution: both signatures verified before anything is applied, floods at SOS reach and SOS priority, and a resolution that outruns its claim is **parked and replayed** when the claim arrives (`PendingResolutionStore`, persisted). QR payload build/parse + counter-sign in `flows/rescue/`. | **Code, not evidence.** No radio, no tests yet. Replay rejection is D4 and is explicitly not built. |
| 2026-09-06 | Wk4 D1–D4 | `a/phase3-4-message-kinds` | **The four message kinds.** `kind: 3` vouch (cap of 5 enforced by ranking, provisional nodes cannot vouch), `kind: 4` revocation (only the original voucher, most-recent-wins by logical clock, re-vouch reinstates), `kind: 5` beacon + `VolunteerGradient` + gradient-ordered sends + per-volunteer relay rate limit, `kind: 6` time gossip piggybacked on existing connections and never relayed. `EnvelopeRouter` added: before it, every non-claim kind was rejected by `ClaimIngestion` **and** silently stopped from relaying. | Vouching cannot run end to end until B lands campaign credentials — `trust_anchors` is empty, so nothing is campaign-verified. Beacon interval and gradient lifetime are placeholders pending D5. |

### Open questions I'm carrying

- [ ] **`trust_anchors` is empty in every build, so no device is campaign-verified and no vouch is accepted.** Vouching, revocation and beaconing are all written and all inert until B's Phase 4 credential issuing lands. Not a bug and not a placeholder to "fix" locally — a bypass here would defeat the whole web of trust. **Needs B.**
- [ ] **`NodeTrust` has no value for the two-vouch "full trust" promotion.** Context doc §2.2 describes it; `CLAIM_SCHEMA.md` §11 fixes the enum at three values. Expressed as a capability for now (`canPledgeResources`) rather than adding a fourth value, because §11 needs all three of us. **Team sync.**
- [ ] **Three new tables are not in `CLAIM_SCHEMA.md` §10** — `pending_resolutions`, `vouches`, `revocations`, `trust_anchors`, added under schema version 2 (`_createMeshIdentityTables`). §10 has no single owner, so recording them needs the §12 three-person sync. **Do not edit §10 alone.**
- [ ] **`MeshTimeGossip` does a weighted average, not the median Wk4 D4 specifies.** `data/` is B's; raised rather than reimplemented.
- [ ] **Beacon interval (60s) and gradient entry lifetime (5 min) are placeholders.** Both are Wk4 D5 tuning against battery numbers that do not exist. So is `BeaconIngestion.minRelayInterval` (20s).
- [ ] **Manual resolve: does it archive immediately, or resolve and let §6.4's window archive it?** §6.3 says "archives rather than clears"; implemented as `status = resolved` on the reading that this means *the record survives*, not *skip to ARCHIVED*. **Confirm with B** — it is on the Wk3 D4 list.
- [ ] `hopLimit` default per message type — **TBD pending Phase 0 range data.** Don't let anyone pick a number before that lands. **A provisional `10` is now in `ClaimFactory.provisionalHopLimit`** — named, not inlined, so the real value is a one-line change. Still a placeholder, not a decision.
- [ ] **Two provisional hop limits now exist, in two folders.** `ClaimFactory.provisionalHopLimit = 10` stamps the stored `Claim.hopLimit` (B's `data/`); `RoutingPolicy.initialHopLimitFor()` stamps the envelope at transmission (my `mesh/`) with 8/5/3 by type. The wire value governs propagation, so nothing is broken today — but a locally raised SOS is stored saying 10 and sent saying 8, and that is exactly the kind of quiet disagreement §7 warns about. **Do not fix by editing across folders unilaterally** — routing is mine, the stored field is B's, and per-type vs single-value is a schema question. Settle with B, and note that a per-type answer touches `CLAIM_SCHEMA.md`.
- [ ] `SeenMessageCache.maxEntries` — provisional `2000`. Depends on real traffic rates nobody has measured. Deliberately generous: evicting too eagerly re-admits messages still in flight, which costs duplicate relays, not lost data.
- [x] Where does `matchesDeviceId()` get called? **Settled: in `ClaimIngestion.ingest()`**, the sink, not the pipeline — it needs the decoded body. `MeshNode` also suppresses relay when ingestion rejects for that reason.
- [ ] Who owns `identity/`? Opened early in Phase 2 because Day 2 needed signing. Officially Phase 4, unassigned. Secure key storage is explicitly *not* built — `loadOrCreateProvisional()` writes the seed to `SharedPreferences` in plaintext.
- [ ] Is Wi-Fi Direct needed for MVP at all? — Phase 0, Wk1 D5. Not yet answered; 3a passing removes one blocker, still needs 3b and a proper walked outdoor range figure.
- [ ] Broadcast storms at relief-camp density? — Wk5 D1. First small preview already seen at n=3 in Phase 0 (§8, GATT client exhaustion) — real evidence the failure mode exists, just not yet at scale.
- [ ] Real clock-drift rate over 72h+ — first number Wk4 D4
- [ ] Do we need fixed relay points? — Wk5 D5, my data decides
- [ ] Android background BLE limits — how much relay survives backgrounding? Wk5 D3
- [ ] Which physical phone models were used in specific Phase 0 test sessions — several findings-doc entries (§2, §12, §13) still have unconfirmed device labels; fill these in before the Day 5 write-up is final.
- [x] `flutter_blue_plus` vs `flutter_reactive_ble` — **neither.** Both are central-role only and cannot advertise. Decided: `bluetooth_low_energy` ^6.2.1, the only Dart option doing both BLE roles.

### Measurements (fill Wk1 D4–5, revise Wk5)

| Measurement | Wk1 | Wk5 revised | Device / conditions |
|---|---|---|---|
| Range, indoors through walls | No write-range boundary found, <10m total distance; RSSI -39 to -94 | | 2 phones, TX-HIGH build, closed doors, one leg through wall+bathroom |
| Range, outdoors line of sight | Discovery only, informal: ~40m (pre-patch), ~100m (TX-HIGH, badly). Write range, informal: ~50m (TX-HIGH) | | None walked/marked to a known distance yet — see `PHASE0_MESH_FINDINGS.md` §10, §12, §13 |
| Discovery time (best / worst of 10) | 245ms (1 sample only) | | Same room, both phones already advertising before scan starts |
| Battery, 1hr continuous scan | Not started | | |
| Battery, 1hr duty-cycled 10s/50s | Not started — duty cycling not implemented yet | | |
| Max single-write payload | **512B confirmed, both directions, even at RSSI -91** | | TX-HIGH build, negotiated ATT MTU 517 |
| **Encoded envelope size, per claim type** | SOS 222B · SOS_PROXY 252B · HAZARD 227B · RESOURCE 232B | | Wk2 D2, after `originPubKey` added. Target ≤400B, ceiling 512B (§9.2) — comfortable headroom |
| Delivery latency, 2 hops | | | |
| Delivery latency, 3 hops | | | |
| Max devices tested in one mesh | 3 (registration exhaustion hit at this count, §8) | | |
| Clock drift over 24h | | | |
| **Multi-hop relay works?** | **Relay logic: yes (3a passed).** Detail not yet backfilled; 3b (relay at real distance) not attempted | | |
| **Wi-Fi Direct needed for MVP?** | Not yet answered | | |
| **72-hour target achievable?** | Not yet answered | | |
