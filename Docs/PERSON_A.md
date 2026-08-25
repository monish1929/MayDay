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

- [ ] Claim created on phone 1 arrives in phone 2's store, intact and verified
- [ ] Corroboration from a genuinely second physical device upgrades trust correctly
- [ ] **Relaying between two phones does NOT move trust** — verify on real hardware, not just B's harness
- [ ] Join C: a claim raised on phone 1 renders on phone 2's map
- [ ] Two SOS in the same geohash bucket → **two pins**, not one

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

### Open questions I'm carrying

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
