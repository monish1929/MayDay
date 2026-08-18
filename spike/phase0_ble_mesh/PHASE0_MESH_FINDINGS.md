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
| Range, outdoors line of sight | | |
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
