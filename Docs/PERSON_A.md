# PERSON_A.md — Mesh & Transport

**Owner:** A
**Branch prefix:** `a/`
**Primary folder:** `lib/mesh/`
**Reviews my PRs:** B (always, for anything in `mesh/`)
**I review:** B's `data/` PRs

Read `CLAUDE.md` and `CLAIM_SCHEMA.md` first. This file is my task list and progress log — update the checkboxes as I go, and fill in the log at the bottom.

---

## 1. What I own

Getting bytes from one phone to another with no internet, no router, no cell tower. Everything below the data layer.

- BLE advertising, scanning, connection, GATT read/write
- Wi-Fi Direct, **if** Phase 0 shows it's needed
- The envelope format and the receive pipeline (`CLAIM_SCHEMA.md` §9)
- Signature verification at each hop
- Hop-limit decrement and the message de-dup cache
- Routing policy — full flood vs selective relay
- Volunteer beaconing (later phase)

**What I don't own:** what a Claim *means*. I move opaque signed bytes. Trust logic, decay, merging — all B's. If I find myself writing an `if (claimType == ...)` outside of routing policy, I've drifted into B's territory and should stop and talk to them.

---

## 2. Why I go first

The whole project rests on one unproven assumption: **phones can find each other and pass messages over BLE reliably enough to matter.** That's not a software design question — it's a "does the hardware and OS cooperate" question, and no amount of good architecture fixes bad radio range.

If BLE mesh turns out to be painful on our test devices, everyone needs to know in week 1, not week 4 after a trust engine and a map have been built on top of it. My Phase 0 output is the input to everyone else's risk assessment.

---

## 3. Week 1 — Phase 0: BLE mesh spike

**This is throwaway code.** A separate Flutter project, not the real app. The deliverable is *knowledge*, not code I'll keep. Resist making it nice.

### Day 1–2 — Two phones talking

- [✔] New scratch Flutter project — `spike/phase0_ble_mesh/`. Package: **`bluetooth_low_energy`**, *not* `flutter_blue_plus`; see §9 open questions for why
- [✔] Android BLE permissions sorted — manifest block in place; fixed a real bug where the spike unconditionally requested `locationWhenInUse` and treated any denial as fatal, when it's correctly unrequestable on API 31+ (manifest declares it `maxSdkVersion=30`, matching the `neverForLocation` flag on `BLUETOOTH_SCAN`). Verified clean on a real API 33 device
- [✔] Phone 1 advertises a custom service UUID — confirmed via `BluetoothGattServer addService()`/`onServiceAdded() status=0`
- [✔] Phone 2 scans and discovers it — `FOUND` fired, 245ms on the one clean-methodology sample (advertiser already live before scan started)
- [✔] Connect, write a hardcoded string over a GATT characteristic — `20B OK` write confirmed on real hardware
- [✔] Phone 2 displays the received string on screen — confirmed by direct observation on phone B
- [✔] **Both directions** — A→B and B→A both confirmed. Bonus: de-dup cache also verified working (A correctly dropped its own message after B relayed it back — `RX dup A-0 — dropped, not relayed`)

**Gotcha to expect:** Android 12+ permission model for BLE is genuinely fiddly and the plugin docs lag behind. Budget time for this; it is not a sign anything is wrong.

### Day 3 — Three phones, the actual mesh question

- [ ] Phone A and Phone C placed deliberately **out of range** of each other (different rooms/floors — verify they can't see each other directly first)
- [ ] Phone B positioned between them, in range of both
- [ ] Message from A arrives at C, via B
- [ ] Confirm B genuinely relayed it rather than A reaching C directly — move B out of the picture and confirm delivery *stops*

**This is the single most important test of the week.** If multi-hop doesn't work, the architecture needs rethinking and everyone needs to know immediately.

### Day 4 — Measurements

Real numbers, written down. Rough is fine; absent is not.

- [ ] Effective range indoors (through walls) — metres
- [ ] Effective range outdoors, line of sight — metres
- [~] Time from advertising start to discovery — 1 clean sample (245ms), need 9 more for a real best/worst-of-10. **Methodology fix applied:** advertise on both phones first, confirm both show "advertising as X," *then* start scanning — an earlier 5.8s reading was contaminated by human button-tapping lag, not radio latency; discarded, see `spike/phase0_ble_mesh/PHASE0_MESH_FINDINGS.md` §2
- [ ] Battery drain: 1 hour of continuous scanning, % consumed, note the device model
- [ ] Same over 1 hour of **duty-cycled** scanning (10s on / 50s off) — this is what we'll actually ship
- [ ] Max payload size that reliably writes in one go — buttons wired (Probe 400B / 512B), not yet run

### Day 5 — Write it up + the size question

- [ ] One-page findings doc: `spike/phase0_ble_mesh/PHASE0_MESH_FINDINGS.md` (skeleton created; numbers pending). *Lives inside the spike folder, not the shared `Docs/` — this is throwaway, A-owned working material, not a team-facing doc like `CLAIM_SCHEMA.md`.*
- [ ] Recommendation: **is Wi-Fi Direct needed for MVP, or is BLE alone enough?**
- [ ] **Take the max payload number to B before the week 1 sync.** `CLAIM_SCHEMA.md` §9.2 assumes ≤400 bytes fits in one write. If my measured number is lower, the schema has to change, and that's a three-person conversation.

### Exit criteria

I can answer, with evidence:
1. Does multi-hop relay work on our hardware?
2. What's the realistic range and discovery time?
3. What does continuous vs duty-cycled scanning cost in battery?
4. How many bytes fit in one message?

---

## 4. The week 1 sync — what I bring

One question, and it's mine to raise: **does my measured payload capacity match what B's claims need to serialize?**

`CLAIM_SCHEMA.md` §9.2 targets ≤400 bytes per envelope. If BLE gives me less in practice, we either shrink the schema or build fragmentation — and fragmentation is a real feature with real failure modes (partial delivery, reassembly timeouts), not something to slip in quietly.

I also bring the battery numbers, because they feed directly into the 72-hour target in `CLAUDE.md` §9 and into whether fixed relay points move from "open question" to "needed."

---

## 5. Week 2 — Phase 2, pairing with B

I stop working solo here. A+B pair on wiring transport to the data layer, on branch prefix `ab/`.

- [ ] Serialize a Claim (B's code) → CBOR → BLE write
- [ ] Receive → deserialize → **verify signature** → hand to B's store
- [ ] Receive pipeline in the right order (`CLAIM_SCHEMA.md` §9.3): de-dup → verify → decrement → store → relay
- [ ] Message-ID de-dup cache working — same message received twice is not stored twice
- [ ] `hopLimit` decrements; at zero, store but don't relay
- [ ] Malformed / unsigned / tampered claims dropped and **not relayed**
- [ ] Corroboration from a genuinely second physical device upgrades trust tier correctly

**Why pair rather than split:** this seam is where the subtle bugs live. I can't see B's assumptions about the schema and B can't see mine about the wire. Two people at one keyboard for a few days is cheaper than debugging a corrupted trust state later.

C works in parallel this week swapping their mocks for B's real store — C doesn't need either of us for most of that.

---

## 6. Later phases

**Phase 3** — I take one of the three flows. Likely **Rescue**, since I'll have the deepest grip on how SOS propagates after Phase 2, and Rescue is where the never-merge and never-decay rules matter most.

**Phase 4+** — routing policy refinement:
- [ ] Full flood for `sos`/`sosProxy`/`hazardReport`; selective relay for `resource`
- [ ] **Volunteer beaconing** — volunteer nodes broadcast a signed "volunteer here" beacon with a hop count, so devices learn "a volunteer is ~3 hops away via this neighbour"
- [ ] Volunteer-first send ordering when airtime is limited
- [ ] Duty-cycled scanning tuned against the 72-hour target

**Do not implement "directional relay toward volunteers."** BLE has no directional information, and in a full flood there's nothing left to prefer. The two mechanisms above are the working replacement — see `CLAUDE.md` §1.2.

---

## 7. Invariants I'm personally responsible for

These are mine to get right. Others may not catch them in review.

- **Claims are signed, never encrypted** (`CLAUDE.md` §2.5). Every relay must read content to corroborate and render pins. If I ever feel tempted to encrypt a payload, the answer is no — see the reasoning before arguing for it.
- **Verify before store, verify before relay** (§9.3). Order matters: a malformed claim must never enter the store, and a tampered one must never be propagated by an honest device.
- **The signature excludes `hopLimit` and `msgId`.** They change per hop. Signing them breaks verification after the first forward.
- **`hopLimit` is not TTL.** It's a hop count, unrelated to `displayLifetime`. Never share a variable, config key, or name between them.
- **No server, endpoint, or sync path.** If I find myself writing a retry-until-connected loop, something's wrong — there's nothing to connect to.

---

## 8. My PR checklist

Beyond the standard checks in `CLAUDE.md` §4.5:

- [ ] Tested on **at least two physical devices**. Emulator does not count for mesh code, ever.
- [ ] Signature verified at hop; unsigned/malformed dropped and not relayed
- [ ] `hopLimit` decrements; de-dup cache prevents re-broadcast
- [ ] Battery impact noted in the PR description if scan behaviour changed
- [ ] Reviewer named: **B**, per `CLAUDE.md` §3.3
- [ ] No new reference to a server, endpoint, or connectivity path

---

## 9. Progress log

Update after each work session. Keep it short — this is for the team sync, not a diary.

| Date | Branch | What landed | Blocked on / notes |
|---|---|---|---|
| 2026-08-18 | `a/ble-mesh-spike` | Spike scaffold: `spike/phase0_ble_mesh/` (pubspec, `main.dart` covering advertise + scan + write + relay + payload probe, README with test protocol). `spike/phase0_ble_mesh/PHASE0_MESH_FINDINGS.md` skeleton (later moved out of `Docs/` into the spike folder — see 2026-08-18 entry below). Package decision made. | **Blocked: Flutter SDK not installed on this machine.** Android SDK + JDK are present, `adb` sees 0 devices. Nothing is compiled or run yet — `main.dart` has not been through `flutter analyze`. |
| 2026-08-18 | `a/ble-mesh-spike` | Flutter SDK installed (`D:\Applications\flutter`), Android cmdline-tools installed via Android Studio, JDK pointed at Studio's bundled JBR 21. `flutter analyze` clean after fixing two real bugs: (1) `respondWriteRequest` was called with an extra `central` arg that doesn't exist in `bluetooth_low_energy` 6.2.1 — it's `respondWriteRequest(GATTWriteRequest request)`, single-arg; (2) permission logic unconditionally requested `locationWhenInUse` and treated denial as fatal — wrong on API 31+, where it's correctly ungrantable per the manifest's `maxSdkVersion=30` + `BLUETOOTH_SCAN` `neverForLocation`. Deleted boilerplate `test/widget_test.dart` (referenced a nonexistent `MyApp`; spike has no automated tests by design). Added Android 12+ permission block to the generated manifest. Worked around a Windows cross-drive Kotlin incremental-compiler bug (project on D:, pub cache on C: — `kotlin.incremental=false` in `android/gradle.properties`, spike-only). **Day 1–2 complete on real hardware:** both phones (M2101K7BI ×2, Android 13/API 33) advertise, discover (245ms clean sample), write, and receive in both directions; de-dup cache confirmed working. | Day 3 (multi-hop) blocked on a third phone. Day 4 measurements mostly outstanding — only 1 discovery sample so far. |
| 2026-08-19 | `a/ble-mesh-spike` | Added a live liveness heartbeat (per-peer ping every 12s, on-screen in-range/out-of-range chips) for the Day 4 range test, plus Advertise/Scan toggles, a per-peer connection lock (`_busyPeers`) shared between the heartbeat and manual Send/Probe, and timeouts on every native BLE call. All three found and fixed on real hardware: a ping-vs-manual-Send race that crashed the plugin (`IllegalStateException: GATT is disconnected`), silent failures on Advertise/Scan with no try/catch, and GATT client-registration exhaustion (`status=257`) once a third phone joined — see `PHASE0_MESH_FINDINGS.md` §8, directly relevant to the flood-routing-at-density open question below. Confirmed the 3rd-party `bluetooth_low_energy_android` plugin cannot start advertising **at all** on one specific phone (Motorola, Android 16/API 36) — tried reboot, fresh reinstall, and restarting the system Bluetooth process directly; all three failed identically at `startAdvertising()`. See `PHASE0_MESH_FINDINGS.md` §6 (corrected from an earlier, too-narrow "restart only" conclusion). | **Day 3 now blocked differently:** have 3 physical phones (Redmi, OPPO, Motorola) but the Motorola cannot advertise on this plugin+OS combo at all, and every mesh position needs both advertise and scan. Need either a 4th working phone or to accept Day 3 as unprovable with current hardware and say so plainly (`CLAUDE.md` §9). |
| | | | |

### Open questions I'm carrying

- [ ] `hopLimit` default per message type — **TBD pending my Phase 0 range data.** Don't let anyone pick a number before that lands.
- [ ] Is Wi-Fi Direct needed for MVP at all? — Phase 0 answers this
- [ ] Does flood routing cause broadcast storms at relief-camp density (hundreds of phones)? — needs a later, bigger test than I can run in week 1
- [✔] `flutter_blue_plus` vs `flutter_reactive_ble` — **neither.** Both are BLE *central-role only*: they scan and connect, they cannot advertise. A mesh node has to be peripheral **and** central simultaneously, or nobody can find anybody. `flutter_ble_peripheral` advertises but exposes no GATT server, so there is no writable characteristic to be written into — pairing it with `flutter_blue_plus` still doesn't close the loop. **Decided: `bluetooth_low_energy` ^6.2.1**, which does both roles including a GATT server with write callbacks. Trade-off: smaller user base than `flutter_blue_plus`. Fallback if it misbehaves on our devices is a hand-written Android platform channel over `BluetoothGattServer`.

### Phase 0 findings (fill in day 5)

| Measurement | Result | Device / conditions |
|---|---|---|
| Range, indoors through walls | | |
| Range, outdoors line of sight | | |
| Discovery time (best / worst of 10) | | |
| Battery, 1hr continuous scan | | |
| Battery, 1hr duty-cycled 10s/50s | | |
| Max single-write payload | | |
| **Multi-hop relay works?** | | |
| **Wi-Fi Direct needed for MVP?** | | |
