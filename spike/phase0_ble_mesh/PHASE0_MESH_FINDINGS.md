# PHASE0_MESH_FINDINGS.md — BLE mesh spike

**Owner:** A · **Status:** IN PROGRESS — no measurements taken yet
**Spike code:** `spike/phase0_ble_mesh/` (throwaway, not `lib/mesh/`)

> Fill this in as measurements land. Rough numbers are fine; absent ones are
> not. Everything below is blocked on physical devices — nothing here can be
> answered on an emulator (`CLAUDE.md` §6.1).

---

## 1. The four questions

### 1.1 Does multi-hop relay work on our hardware?

**Answer:** _not yet tested_

Protocol used, and the negative control (delivery to C stops when B is
removed), is in `spike/phase0_ble_mesh/README.md` → "Day 3".

### 1.2 Realistic range and discovery time

**Answer:** _not yet tested_

### 1.3 Continuous vs duty-cycled scanning battery cost

**Answer:** _not yet tested_

Feeds directly into the 72-hour target (`CLAUDE.md` §9) and into whether fixed
relay points move from open question to needed (`CLAUDE.md` §8).

### 1.4 How many bytes fit in one write?

**Answer:** _not yet tested_

`CLAIM_SCHEMA.md` §9.2 assumes ≤400 bytes. **If the measured number is lower,
the schema changes and that is a three-person conversation** — not a quiet
fragmentation feature.

---

## 2. Measurements

| Measurement | Result | Device / conditions |
|---|---|---|
| Range, indoors through walls | | |
| Range, outdoors line of sight | Discovery still working (intermittently) at ~40m; writes already failing (status 133) at that distance — see §10. **Not an official measurement**, informal check | Redmi + OPPO, open pathway, no walls, light foot traffic. Medium TX power (pre-§9 patch) |
| Discovery time, best of 10 | 245ms (1 sample, not yet a real best-of-10) | B scanning for A, A already advertising. Same room, both M2101K7BI |
| Discovery time, worst of 10 | | |
| Battery, 1 hr continuous scan | | |
| Battery, 1 hr duty-cycled 10s/50s | | |
| Negotiated ATT MTU | | |
| Max single-write payload | | |
| Multi-hop relay works? | | |

**Methodology note:** the first attempt (A scanning for B, both buttons tapped
manually and staggered) read 5.8s — that number is contaminated by human
button-tapping lag between starting A's scan and starting B's advertise, not
radio discovery latency. Discard it. **For every real measurement: tap
Advertise on both phones first, confirm both show "advertising as X" on
screen, then start Scan** — only then does the timer measure the radio, not
you. The 245ms figure above is the first sample taken this way (B scanning
while A was already advertising) and is the one to trust; it still needs 9
more runs to be a real best/worst-of-10.

Devices under test:

| Label | Model | Android version | API level |
|---|---|---|---|
| A | | | |
| B | | | |
| C | | | |

---

## 3. Recommendation — is Wi-Fi Direct needed for MVP?

**Answer:** _pending §2_

This closes an open question in `CLAUDE.md` §8. Answer it explicitly either
way; "we didn't get to it" is a valid answer but must be written down as one.

---

## 4. What this does NOT tell us

Stated so nobody reads more into these numbers than they carry:

- **Density.** Three phones says nothing about a relief camp with hundreds.
  Whether full-flood routing causes broadcast storms needs a bigger test than
  week 1 can run (`Docs/PERSON_A.md` §9).
- **Clock drift.** Not measured here. Still open (`CLAUDE.md` §8), and it needs
  72+ hours of elapsed time, not a day of testing.
- **Sustained operation.** One hour of battery data extrapolated to 72 hours is
  an estimate, not a measurement. Say "estimated" in any slide that uses it.
- **`hopLimit` default.** Range data narrows it; it does not pick it. Do not
  let a number get chosen off the back of this document without a team sync
  (`CLAUDE.md` §8).

---

## 5. Package choice

**`bluetooth_low_energy` ^6.2.1**, not `flutter_blue_plus`.

`flutter_blue_plus` and `flutter_reactive_ble` are **central-role only** — they
cannot advertise. A mesh node has to be peripheral and central at the same
time. `flutter_ble_peripheral` advertises but exposes no GATT server, so there
is no writable characteristic for a neighbour to write into. Full comparison in
`spike/phase0_ble_mesh/README.md`.

Fallback if it proves unusable on our devices: hand-written Android platform
channel over `BluetoothGattServer`. Record which way it went here.

**Verdict so far: usable, but with real defects — see §6 and §8.** It is the
only Dart option that does both BLE roles, so the choice stands. But two
genuine bugs were found in it during Phase 0 (an advertising call that hangs
forever, and GATT client registrations that leak until Android refuses more),
both requiring workarounds in spike code. Phase 2 should budget time for
plugin-level problems rather than assuming this dependency is solid, and
should keep the platform-channel fallback genuinely on the table.

---

## 6. Real bug in `bluetooth_low_energy`: passing an advertisement `name` hangs `startAdvertising()` forever

**This one cost most of a day and was misdiagnosed twice. Read the whole
section before touching advertising code.**

### Symptom

On one phone (Motorola, Android 16 / API 36) `startAdvertising()` never
returned. No exception, no callback, no log — the Advertise button simply did
nothing. Survived **every** reset we could throw at it:

| Attempt | Result |
|---|---|
| Stop then Advertise again | Hangs |
| Full phone reboot | Hangs |
| Fresh app reinstall (never launched before) | Hangs |
| `adb shell am force-stop com.android.bluetooth` (restart the Bluetooth *system process*) | Hangs |

### Two wrong diagnoses along the way — both recorded because the reasoning matters

1. **"Advertise restart is broken, cold start is fine."** Wrong: a fresh
   install hung on its very first tap. The one early success was luck, not a
   pattern.
2. **"It's an Android 16 / OEM framework bug, nothing we can do."** Also
   wrong, and nearly led to writing off every Android 16+ device. The tell
   that disproved it: in the failing case there were **no
   `D/BluetoothLeAdvertiser` log lines at all**, whereas the one working case
   had them. The hang was happening *before* Android's advertiser was ever
   reached — i.e. inside the plugin, not the OS.

### Actual root cause

`Advertisement(name: ...)` does something non-obvious on Android. From
`bluetooth_low_energy_android/lib/src/peripheral_manager_impl.dart`:

```dart
Future<void> startAdvertising(Advertisement advertisement) async {
  final nameArgs = advertisement.name;
  if (nameArgs != null) {
    final newNameArgs = await _api.setName(nameArgs);   // <-- hangs here
  }
  // ...real startAdvertising call never reached
```

and `PeripheralManagerImpl.kt`:

```kotlin
override fun setName(nameArgs: String, callback: (Result<String?>) -> Unit) {
    val setting = adapter.setName(nameArgs)   // renames the WHOLE PHONE, returns true
    if (!setting) { throw IllegalStateException() }
    mSetNameCallback = callback               // parked, waiting for a broadcast
}
```

resolved *only* by:

```kotlin
BluetoothAdapter.ACTION_LOCAL_NAME_CHANGED -> {
    val callback = mSetNameCallback ?: return
    callback(Result.success(nameArgs))        // the only thing completing the Future
}
```

**If the adapter name already equals the requested name, Android fires no
`ACTION_LOCAL_NAME_CHANGED` broadcast — nothing changed — so the callback is
never invoked and the Dart Future never completes.** `adapter.setName()`
still returns `true`, so the plugin's own error check passes cleanly.

Confirmed decisively: `adb shell settings get secure bluetooth_name` returned
**`B`** on the stuck phone — exactly the name being set.

This also explains why nothing fixed it. The Bluetooth adapter name is a
**persisted system setting**, not app-owned data, so it survives reboots,
reinstalls, and Bluetooth-service restarts alike. The Motorola was never
special; it was simply the phone that happened to already be named `B`. The
other two worked only because their names were changing to *new* values.

### Fix

Do not pass `name` to `Advertisement`. The node label now travels in
**manufacturer-specific data** (id `0xFFFF`, the SIG's reserved test value)
inside the advertising payload, read back on discovery from
`advertisement.manufacturerSpecificData`. Touches no global state.

Verified on the previously-broken phone: five consecutive start/stop cycles,
all clean, payload 26 bytes (within the 31-byte legacy advertising budget;
scan response now 0 bytes since no device name is included).

### Two things worth carrying into Phase 2

- **A production `lib/mesh/` must never set the advertisement name on
  Android** — and more generally must not let a library silently mutate
  device-global settings. Renaming the user's phone as a side effect of
  starting a mesh node is unacceptable behaviour in a disaster app, entirely
  separate from the hang.
- **Every native BLE call needs its own timeout.** The `.timeout(5s)` wrapper
  added here is what turned "button does nothing" into a diagnosable error
  and ultimately exposed the real cause. `CLAUDE.md` §9 asks for honest
  limitations; a call that can hang forever with no error is one.

**Side effect to clean up:** the earlier code permanently renamed the three
test phones' Bluetooth names to `A`, `B`, `C`. Restore via
Settings then Bluetooth then Device name on each.

---

## 7. Confirmed on real hardware — BLE address is not a stable device identity

After one phone's app restarted, the scanning phone saw it as a **brand-new
peer** (different `Peripheral.uuid`) rather than the same physical device it
had already discovered. Cross-referencing session logs shows the same phones
presenting different BLE addresses across runs (`42:F2:BE:A0:45:06`,
`75:3C:84:9F:E6:56`, and others) with no address reused between runs.

**Read as:** Android randomizes the BLE advertising address for privacy, and
a fresh `startAdvertising()` can be issued a new one. BLE identity is scoped
to *the current advertising session*, not to the device.

**Not a spike bug and nothing to fix** — it is exactly why `CLAIM_SCHEMA.md`
and `CLAUDE.md` §2.5 specify that `origin_device_id` comes from a persistent
Ed25519 keypair, never from the transient BLE address. Had the design trusted
BLE-layer identity, one phone rotating its MAC mid-session would fragment its
corroboration history, hop tracking, and de-dup cache into what looks like
several devices. Worth citing as empirical evidence the next time someone
asks "can't we just use the BLE address as the device id."

---

## 8. GATT client registration exhaustion at just 3 devices — a small, real preview of the broadcast-storm question

**Symptom:** reliable with 2 phones. Add a **third** and within minutes every
peer on one device went permanently unreachable — not flaky, just dead — while
sitting inches apart with Bluetooth confirmed on.

**Root cause,** confirmed via raw `adb logcat`:

```
D/BluetoothGatt: connect() - device: XX:XX:XX:XX:69:AA, ...
D/BluetoothGatt: registerApp() - UUID=<fresh random UUID, different every time>
D/BluetoothGatt: onClientRegistered() - status=257 clientIf=0
D/BluetoothGatt: close()
```

`status=257` is Android refusing a new GATT client registration — the
process's quota is full. The plugin registers a **brand-new client identity
on every single `connect()`** rather than reusing one (dozens of distinct
UUIDs captured, none reused). Three phones each pinging 2 peers every few
seconds hit the per-process cap for real. Every attempt then failed *before
reaching the peer* — indistinguishable from "unreachable" in app-level logs,
but actually a local resource-table problem, not radio or range.

**Mitigation applied at the time:** ping interval widened 4s to 12s. A
mitigation, not a fix — the registration-per-call behaviour is inside the
plugin. Recovery once capped: force-close and relaunch (releases the
registrations).

**Superseded, not just mitigated.** The connect-based ping heartbeat this
section describes was later removed entirely and replaced with liveness
derived from advertisement reception (zero connections, so this failure mode
no longer applies to liveness tracking at all). The registration-exhaustion
mechanism itself is still real and still applies to manual Send/Probe under
heavy connection churn — the analysis above stands — but the specific
heartbeat that triggered it here is gone.

**Why this is not a footnote:** `Docs/PERSON_A.md` §9 flags *"does flood
routing cause broadcast storms at relief-camp density (hundreds of phones)?"*
as needing a bigger test than Phase 0 can run. **This is that failure mode,
at n=3.** A resource that silently exhausts under load, surfacing to the app
as "peers are gone", is exactly what makes flood routing dangerous at density.
Phase 2 needs either connection pooling (reuse one client, don't churn) or
hard rate-limiting on connection attempts — and must distinguish "peer
unreachable" from "local resource exhausted", because the real corroboration
and relay logic will otherwise draw wrong conclusions from a failed send.


---

## 9. Advertising TX power is capped at MEDIUM, and the public API cannot change it

**Not something in this spike's code — a gap in the plugin itself.**

The Android platform layer of `bluetooth_low_energy` supports TX power
selection internally:

```dart
enum TXPowerLevelArgs { ultraLow, low, medium, high }
```

But the **public, cross-platform API never exposes it.**
`PeripheralManager.startAdvertising(Advertisement advertisement)` takes an
`Advertisement`, which has no TX power field at all — and the plugin's own
`peripheral_manager_impl.dart` never populates `txPowerLevelArgs` when
building the native settings object, leaving it null. Android's own default
then applies. Confirmed directly in the native log on every successful
advertise in this spike:

```
D/BluetoothLeAdvertiser: TxPower == ADVERTISE_TX_POWER_MEDIUM
```

**Consequence for Day 4 range numbers:** whatever range this spike measures
reflects **medium** transmit power, not the phone's hardware maximum. Any
range figure recorded in §2 should be captioned with this — it is a
measurement of "range at medium TX power on this plugin," not "the range
this hardware can achieve." A production implementation using a patched
plugin, a different plugin, or the hand-written platform-channel fallback
already noted in §5 could plausibly do meaningfully better on range than
anything Phase 0 records.

**Not worth fixing in the spike.** Patching the plugin's Kotlin source to
wire through `txPowerLevelArgs=high` is real engineering effort disproportionate
to a throwaway measurement exercise, and the resulting number would then be
specific to a hand-patched dependency nobody plans to ship. Better to record
the caveat honestly (`CLAUDE.md` §9 — state limitations, don't paper over)
than quietly measure a number that looks like a hardware ceiling but isn't
one.

**Worth carrying into Phase 2:** if range ever becomes the limiting factor
for mesh connectivity in the field, TX power is a real, currently-untapped
lever — and the fact that the chosen dependency doesn't expose it through
its public API is itself a data point for the "is this the right transport
library" question raised in §5.


---

## 10. First real outdoor range data point — and the bug it exposed

**Not an official Day 4 measurement — recorded here as informal evidence,
per the same standard as everything else in this doc.** Redmi and OPPO,
open pathway, no walls, some people walking through (mild crowding).
Unpatched build — medium TX power (§9), pre-write-timeout fix (below).

### What the RSSI trend shows

```
15:04:40  FOUND B  rssi=-48        <- close together at start
15:05:02  rssi=-86
15:05:41  rssi=-95
15:06:07  rssi=-92
15:06:54  rssi=-78
15:07:40  rssi=-97
```

Repeated `"back in range"` transitions (not one steady green period) between
these means advertisement reception itself kept dropping for >4s stretches
at ~40m and then recovering — this is the edge of the discovery boundary,
not comfortably inside it. RSSI mostly -85 to -97 matches "about to drop"
per general BLE guidance, consistent with being right at the range limit
rather than well within it.

### The write failure — and what it confirms

```
FAILED ... IllegalStateException: Connect failed with status: 133
```

Status 133 is Android's generic GATT connection failure, commonly triggered
by attempting to *connect* (not just passively receive an advertisement) at
marginal signal strength. This is the first empirical confirmation of a
caveat stated when liveness moved to advertisement-based tracking: **write
range is shorter than discovery range.** Adverts were still (barely)
arriving at -92 dBm; the GATT connect a real Send needs failed outright at
that same distance.

### The bug this exposed: no timeout on the manual write path

```
15:06:26.808  TX "hello from A" to 1 peer(s)     <- no result line ever printed
15:06:27.456  TX "hello from A" to 1 peer(s)
15:06:27.456       -> SKIPPED (write in flight, retry)
15:06:35.886  TX "hello from A" to 1 peer(s)
15:06:35.886       -> SKIPPED (write in flight, retry)
15:06:56.849       -> FAILED ... status: 133      <- presumably the 26.808 attempt
```

`connect()` from 15:06:26.808 didn't fail — it hung for roughly 30 seconds,
holding `_busyPeers` locked the whole time and silently skipping two more
Send taps. `_writeToAllPeers` had a timeout on `disconnect()` (added earlier
for a different reason) but never on the `connect -> discoverGATT -> write`
chain itself — the exact class of bug already fixed for the advertising
path and the (now-removed) ping heartbeat, just never applied here.

**Fixed:** `.timeout(8s)` around the whole write attempt, with a distinct
`TIMED OUT` log line separate from `FAILED` — worth distinguishing, since
the status-133 failures above returned in well under a second. "Timed out"
vs "failed fast" is itself a signal worth reading separately once Day 4
range testing starts producing failures near the boundary.

### What to actually do with this at Day 4

Confirms the write-range check in the README's range protocol (Send/Probe,
not just Scan restart) is the right one — discovery alone would have shown
this as "still findable" well past where writes actually work. Record range
as two numbers, not one: discovery boundary and write boundary. They will
not be the same distance.
