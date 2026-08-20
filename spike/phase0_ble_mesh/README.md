# Phase 0 — BLE mesh spike

**Throwaway.** Not the MayDay app. Nothing here graduates into `lib/mesh/`.
Owner: A. See `Docs/PERSON_A.md` §3.

It exists to answer four questions with evidence:

1. Does multi-hop relay work on our hardware?
2. What is the realistic range and discovery time?
3. What does continuous vs duty-cycled scanning cost in battery?
4. How many bytes fit in one write?

Findings go to `PHASE0_MESH_FINDINGS.md` in this same folder — not the shared
`Docs/`, since this is throwaway working material specific to A's track, not
a team-facing doc like `CLAIM_SCHEMA.md` — and into the table at the bottom
of `Docs/PERSON_A.md`.

---

## Package choice — and why it isn't `flutter_blue_plus`

`Docs/PERSON_A.md` day 1 says "pick `flutter_blue_plus` or
`flutter_reactive_ble`, note why". Both are the wrong shape for this spike, and
the reason matters beyond Phase 0:

**A mesh node is simultaneously a peripheral and a central.** It must advertise
so neighbours can find it *and* scan so it can find neighbours. Every phone
plays both roles at once — that is what "mesh" means here.

| Package | Central | Peripheral (advertise) | GATT server (writable characteristic) |
|---|---|---|---|
| `flutter_blue_plus` | yes | **no — central role only** | no |
| `flutter_reactive_ble` | yes | **no** | no |
| `flutter_ble_peripheral` | no | yes (Android) | **no — advertising only** |
| **`bluetooth_low_energy`** | yes | yes | **yes** (`PeripheralManager`, `characteristicWriteRequested`) |

`flutter_blue_plus` + `flutter_ble_peripheral` together still doesn't work: the
receiving phone needs a *writable characteristic* to be written to, and
`flutter_ble_peripheral` only broadcasts advertisement packets.

**Decision: `bluetooth_low_energy` ^6.2.1** — one package, both roles, GATT
server included. Recorded in `Docs/PERSON_A.md` §9.

Risk to watch, since it is the less-travelled package: it has a smaller user
base than `flutter_blue_plus`. If it turns out unusable on our devices, the
fallback is a hand-written Android platform channel over `BluetoothGattServer`
— more work, no dependency risk. Note which way it went in the findings doc.

---

## Setup

Flutter is **not currently installed on this machine** — install it first
(https://docs.flutter.dev/get-started/install/windows) and confirm:

```bash
flutter doctor
```

Then, from this directory, generate the Android host project around the files
already committed here:

```bash
flutter create --platforms=android --org com.mayday.spike .
```

`flutter create` will overwrite `pubspec.yaml` and `lib/main.dart`. Put ours
back, then fetch:

```bash
git checkout -- pubspec.yaml lib/main.dart && flutter pub get
```

### Android permissions

Add to `android/app/src/main/AndroidManifest.xml`, above `<application>`:

```xml
<!-- Android 12+ (API 31+) -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

<!-- Android 11 and below -->
<uses-permission android:name="android.permission.BLUETOOTH"
    android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN"
    android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"
    android:maxSdkVersion="30" />
```

Set `minSdkVersion 21` in `android/app/build.gradle` if it is lower.

> If you later need the scan results to carry location (we don't), drop
> `neverForLocation` — but then Android demands runtime location permission on
> API 31+ too, which is a worse user experience in a disaster app.

---

## Test protocol

Set the node name field on each phone before starting — `A`, `B`, `C`. The log
is unreadable otherwise.

### Day 1–2 — two phones

1. Both phones: **Advertise**, then **Scan**.
2. Wait for `FOUND` on each. Note the `after Nms` figure — that is the
   discovery time measurement.
3. Phone A: **Send**. Phone B should log `RX "hello from A" hops=0`.
4. Repeat in the other direction. Both must work.

### Day 3 — three phones, the important one

**Run this as two separate tests.** They answer two different questions and
conflating them is what made the first attempts so hard to interpret:

- **3a — does the relay *logic* work?** Software question. Desk test, five
  minutes, deterministic.
- **3b — does relay *extend real range*?** Radio question. Needs distance.

Do 3a first. If it fails, 3b can't succeed and you'd be walking around
debugging code. If it passes, 3b becomes readable: any failure out in the
field is then radio, not logic.

#### 3a — relay logic, all three phones on a desk

No walking. Enforce the topology in software instead — **tap peer chips to
block** rather than trying to get out of range.

1. All three phones together. On each: set the node name, then **Advertise +
   Scan** on. Wait until every phone shows the other two as peers.
2. **On A:** tap C's chip → it greys out, `BLOCKED`. **On C:** tap A's chip →
   same. Leave B unblocked everywhere. A and C can still *see* each other;
   neither will *write* to the other. That is the whole negative control, and
   unlike distance it is a fact you can point at rather than hope for.
3. **On B:** relay switch **ON**, Advertise and Scan both on. B must show
   `FOUND A` and `FOUND C` — relay forwards by writing to B's discovered-peer
   list, so if B isn't scanning that list is empty and relay is silently a
   no-op even with the switch on. (That exact mistake cost a whole run:
   `PHASE0_MESH_FINDINGS.md` §12.)
4. **A: Send.** Expected, and all three parts matter:
   - A logs `BLOCKED to C (test topology)` — the direct path really was cut
   - B logs `RX ... from A hops=0`, then forwards
   - **C logs `RX "hello from A" from A hops=1`** ← the result. `hops=1`
     cannot come from A directly; A always sends `hops=0`.
5. **Negative control — B: relay switch OFF.** A: Send again. **C must receive
   nothing.** B still logs `RX ... relay OFF — stopping here`.
6. Repeat 4–5 in the other direction (C sends, A receives `hops=1`).

> **Why block instead of walking apart?** Two reasons, both learned the hard
> way. First, discovery range materially exceeds write range (§10, §13) and
> both edges are fuzzy — "far enough apart" is never something you can
> assert. Second and worse: if *both* paths exist, de-dup hides the relay.
> A's direct copy (`hops=0`) and B's relayed copy (`hops=1`) race, direct
> usually wins on one hop instead of two, C logs `hops=0` and drops the
> relayed copy as a dup. **The relay worked and the log says it didn't.**
> Blocking removes the direct path outright, so `hops=1` is unambiguous.

#### 3b — relay across real distance

Only after 3a passes. This is the one that needs geography.

1. **Unblock everything** (tap the greyed chips again) — 3b tests real radio,
   so software blocks must be off or you prove nothing about range.
2. Put A and C far enough apart that neither can *write* to the other. Watch
   the chip hint, not just the colour: you want **`advert only`**, or no peer
   at all. Green with `write ok` means still connected — go further.
3. Verify the negative control **before** introducing B: A: Send. It must
   fail to C (`TIMED OUT` / `FAILED`) and C must log no `RX`. If C receives
   anything, they're still in write range — go further apart.
4. Place B between them, Advertise + Scan + relay all on, showing both peers.
5. **A: Send.** C should log `hops=1`.
6. **B: relay OFF** (or walk B away). Send again — delivery to C must stop.

Record the A↔C distance and B's position. That distance *is* the multi-hop
range result.

### Day 4 — measurements

- **Range**: walk apart until `FOUND` stops / writes start failing. Indoors
  through walls, then outdoors line of sight. Record metres.
- **Discovery time**: 10 runs of Advertise-then-Scan, record best and worst
  `after Nms`.
- **Battery, continuous scan**: full charge, scanning on, screen off, one hour.
  Record `%` consumed and the exact device model.
- **Battery, duty-cycled 10s on / 50s off**: same, one hour. This is what we
  would actually ship, so it is the number that feeds the 72-hour target in
  `CLAUDE.md` §9.
- **Max payload**: **Probe 400B**, then **Probe 512B**. Note where it starts
  failing and what MTU was negotiated.

> Duty cycling is not implemented in the app yet — for the day 4 measurement,
> drive it by hand (start/stop scanning on a timer) or add a crude
> `Timer.periodic` before running it. Do not build a real duty-cycle
> scheduler here; that belongs in `lib/mesh/`, tuned against real numbers.

### The number to take to B before the week 1 sync

`CLAIM_SCHEMA.md` §9.2 assumes an envelope of **≤400 bytes fits in one write**.
If the measured maximum is lower, the schema has to change — and that is a
three-person conversation, not a quiet fragmentation feature.
`Docs/PERSON_A.md` §4.
