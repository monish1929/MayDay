# CLAIM_SCHEMA.md — MayDay

**No single owner.** All three people read and write claims. Changing this file requires all three to be aware before the commit lands — see `CLAUDE.md` §4.3.

This is the *data contract* — the exact shape of a Claim, the two identity rules, and the state machines that govern it. `CLAUDE.md` explains why these rules exist; this file is the reference for what to actually implement.

Last changed by: — (fill in on every edit)
Last changed on: — (fill in on every edit)

---

## 1. The Claim object

```dart
class Claim {
  String id;                        // see §2 — computed differently per type
  ClaimType type;                   // sos | sosProxy | hazardReport | resource
  String originDeviceId;
  String originSignature;           // Ed25519, over the full signed payload — see §5
  LogicalClock logicalClock;        // see §4

  ClaimTrust claimTrust;            // unconfirmed | corroborated | groundConfirmed — see §3
  DispatchPriority dispatchPriority;// low | seenByVolunteer | enRoute — see §3.4
  List<Corroboration> corroborations;

  ClaimStatus status;               // active | resolved | archived — see §6
  ResolutionMethod? resolutionMethod; // qr | manual | autoExpired | null
  String? resolvedByVolunteerId;
  DateTime? resolvedAtLogical;      // logical time, not wall clock — see §4

  int hopLimit;                     // decrements per relay hop — see §7
  Duration displayLifetime;         // how long it stays on the map — see §7

  DateTime? createdAtLogical;
  DateTime? lastConfirmedAtLogical;
  DateTime? archivedAtLogical;

  // Type-specific payload — see §8
  ClaimPayload payload;
}
```

```dart
class Corroboration {
  String deviceId;
  int hopDistance;
  double signalStrength;
  String firstSeenVia;              // deviceId of whoever relayed it to us — see §3.2
  LogicalClock logicalClock;
  bool isVolunteer;
  CorroborationKind kind;            // independentGeneration | explicitAttestation
}
```

`ClaimType`, `ClaimTrust`, `ClaimStatus`, `CorroborationKind`, `DispatchPriority`, `ResolutionMethod` are **enums, not strings.** Do not stringly-type any of these.

---

## 2. Claim identity — two rules, never one

This is the single most important thing in this file. Get it wrong and resolving one person's rescue can silently delete a stranger's.

```dart
// SOS and SOS_PROXY — globally unique, never merges, ever.
String sosClaimId(String originDeviceId, int localSequenceNumber) =>
    sha256("$originDeviceId:$localSequenceNumber");

// HAZARD_REPORT and RESOURCE — merges by design.
String mergeableClaimId(ClaimType type, String geohashBucket) =>
    sha256("$type:$geohashBucket");
```

**Rules:**
- These are **two separate functions.** Never one `generateClaimId()` with a type branch inside — that branch is exactly the kind of thing a future refactor "simplifies" away.
- `localSequenceNumber` is a per-device counter that only ever increments. It does not reset, ever, even across app reinstall if the identity survives (it usually won't — see identity doc).
- **Time is never part of either ID.** No timestamp, no time bucket, in either formula. See §4.
- Geohash bucket size: **150–300m.** This is deliberately coarse for hazards/resources (merging is the goal) and is exactly why SOS cannot share this scheme.

**The test that must exist:** two SOS claims, same geohash bucket, same minute, different origin devices → two distinct IDs, two pins, two independent resolutions. If this test doesn't exist yet, write it before anything else in `data/`.

---

## 3. Trust state machine

```
UNCONFIRMED → CORROBORATED → GROUND_CONFIRMED
```

No skipping stages. No going backward once GROUND_CONFIRMED (a volunteer physically assessed it — that doesn't get un-true).

### 3.1 What moves a claim to CORROBORATED

Exactly two things, and nothing else:

| Kind | Definition |
|---|---|
| `independentGeneration` | A different device created a matching claim (same merge-hash, for mergeable types) **without having received the original claim first** |
| `explicitAttestation` | A human on a different device deliberately tapped "I can see this too" |

**Relaying a claim is neither of these and must never appear in this list.** A device that forwarded a message knows nothing it didn't know before. This was the actual bug in v1 — corroboration briefly included "generated or relayed," which let a single hop fabricate CORROBORATED status.

### 3.2 Anti-echo rule

A device cannot corroborate a claim it **first learned about from the mesh.** Check `firstSeenVia`: if it's non-null and the corroborating device only knows about this claim because it arrived over the wire, that device's attestation doesn't count. Without this, ten people confirming a claim they all read on the same relayed message is one witness plus nine repeaters — not ten witnesses.

### 3.3 What moves a claim to GROUND_CONFIRMED

Only a Volunteer node, physically at the location, doing one of:
- Scanning the signed QR handshake to resolve an SOS (§6.2)
- Explicit on-site confirmation for a Report or Resource

This is the only tier that reflects someone with eyes on the actual situation.

### 3.4 `dispatchPriority` is a different field, moved by different things

`dispatchPriority` (`low → seenByVolunteer → enRoute`) tracks how urgently a volunteer should look at something — it moves when a volunteer relays or sees a claim. `claimTrust` tracks how likely the claim is *true* — it moves only per §3.1/§3.3.

A claim can be `enRoute` while still `UNCONFIRMED`. That's intentional: a volunteer heading toward something unverified is an acceptable bias toward speed. **Never let a priority change also change trust**, and never let a trust change silently affect priority either — write to them independently.

---

## 4. Time — logical clocks, never wall clock

No device can trust its own clock (no network to sync from) or another device's clock (same reason).

```dart
class LogicalClock {
  String deviceId;
  int counter;   // increments on every message this device sends
}
```

- Ordering between two events from different devices: compare logical clocks. This answers "which happened more recently, relative to each other" — which is all the merge/decay logic actually needs.
- **Mesh time gossip** (separate mechanism, for the *display* layer only): when devices meet, they exchange clock readings and maintain a running estimate of mesh-median time, weighting volunteer nodes' clocks higher.
- UI shows **relative time only** — "about 2 hours ago." Never render a precise timestamp; it would be fabricated precision.
- `createdAtLogical`, `lastConfirmedAtLogical`, `resolvedAtLogical`, `archivedAtLogical` are all logical-clock values, not `DateTime.now()`. Naming keeps this explicit — don't rename these to drop `Logical`.

---

## 5. Signing

Every claim carries `originSignature`: an Ed25519 signature by the originating device's key, over the full claim payload (excluding the signature field itself and any mutable fields like `corroborations`, `claimTrust`, `dispatchPriority` — sign the immutable core: `id`, `type`, `originDeviceId`, `logicalClock`, `payload`, `createdAtLogical`).

**Claims are signed, never encrypted.** Every relay must be able to read content to draw the pin, compute the geohash bucket, and corroborate. Signature ≠ encryption: it proves who sent it and that it's untampered, while leaving it fully readable.

Every hop verifies the signature before doing anything else with the claim. Unsigned or malformed → drop silently, don't relay, don't store.

---

## 6. Status and resolution

```
ACTIVE → RESOLVED → ARCHIVED
```

### 6.1 Status vs. trust vs. priority

Three separate fields answering three separate questions. Don't conflate them:

| Field | Question it answers |
|---|---|
| `claimTrust` | Is this real? |
| `dispatchPriority` | How urgently should a volunteer look? |
| `status` | Is this rescue/report still open? |

### 6.2 Resolving an SOS — signed QR, not a bare ID

The QR code must prove **presence**, not just knowledge of the SOS ID — an SOS ID travels across the whole mesh in the clear, so knowing it proves nothing.

QR payload:
```
{ sosId, nonce (fresh, generated at display time), signature (by requester's device key, over sosId+nonce) }
```

Flow:
1. Volunteer scans the QR.
2. Volunteer's device counter-signs `{sosId, nonce, requesterSignature}`.
3. Resulting resolution record proves two specific devices were physically co-present (a QR must be optically scanned).
4. `status → RESOLVED`, `resolutionMethod = qr`, `resolvedByVolunteerId` set, `resolvedAtLogical` set.
5. Resolution propagates through the mesh exactly like the original SOS did.

**Because SOS IDs are unique per person (§2), resolving one claim can never resolve a neighbour's.**

### 6.3 Manual resolution fallback

For a dead/lost/damaged phone. Always tagged `resolutionMethod = manual`, always lower-confidence. **Archives rather than clears** the pin — a mistaken or malicious manual resolve must not erase the record that someone needed help.

### 6.4 Archiving and purge

`RESOLVED → ARCHIVED` after a defined window. Archived claims are eligible for storage eviction — see storage policy in the context doc §7.1. **`ACTIVE` claims of type SOS/SOS_PROXY are never evicted, at any storage pressure**, regardless of status elsewhere in the system.

---

## 7. Hop limit and display lifetime — two different things

```dart
int hopLimit;             // how many more times this claim may be relayed
Duration displayLifetime; // how long it stays visible on the map before decay
```

These are **not the same quantity** and must not share a variable, a config key, or a name. (v1 called both "TTL" and it caused real confusion.)

`hopLimit` decrements once per relay hop, regardless of claim type. Exact default: **TBD — pending Phase 0 hop-range data.**

`displayLifetime` behavior is type-specific:

| Type | Decay |
|---|---|
| `sos` / `sosProxy` | **`displayLifetime` is not applicable — these never decay.** Only `status` transitions clear them. An old unresolved SOS should render with *more* visual urgency over logical time, not fade. |
| `hazardReport` | Long window. Exact value TBD. |
| `resource` | Shortest window. Exact value TBD. |

---

## 8. Type-specific payloads

```dart
sealed class ClaimPayload {}

class SosPayload extends ClaimPayload {
  GeoPoint location;
  HeadcountBucket? headcount;   // 2-5 | 6-15 | 15+, for group SOS
}

class SosProxyPayload extends ClaimPayload {
  GeoPoint location;             // marked by the reporter, not the person in danger
  HeadcountBucket? headcount;
  String reporterDeviceId;       // distinct from originDeviceId if relayed on their behalf
}

class HazardReportPayload extends ClaimPayload {
  GeoPoint location;
  HazardType hazardType;         // flood | roadBlock | structuralDamage | other
  int confirmationCount;         // rises as independent reports merge in — see §2
}

class ResourcePayload extends ClaimPayload {
  GeoPoint location;
  ResourceCategory category;     // foodWater | shelter | medical | equipment — canonical 4, don't add more without team sync
  int pledgedCount;               // volunteer-written only, add-only, authoritative
  int claimedReports;             // any user, rate-limited, add-only, soft signal
}
```

### 8.1 Resource counters — add-only, never stored as a single mutable number

```dart
int available(ResourcePayload p) => max(0, p.pledgedCount - p.claimedReports);
```

- `pledgedCount` — **volunteers only.** Add-only. This is the authoritative figure.
- `claimedReports` — **any user, rate-limited.** Add-only. Shown as a separate soft signal ("reportedly running low"), never merged silently into `pledgedCount`.
- **`available` is always computed at display time, never persisted as its own field.** Persisting it is how a naive CRDT counter goes negative when twenty offline devices each record the last item taken and later merge.
- When replicas disagree, show a **range** ("2–6 packets"), not a false precise number.
- Only a Volunteer physically on site may reset `pledgedCount` to reflect ground truth.

---

## 9. Wire format — the A↔B contract

**This section is the agreement between `mesh/` and `data/`. Neither track can finish Phase 2 without it. Changing it needs the same three-person sync as any other part of this file.**

Encoding: **CBOR** (compact binary; Dart package `cbor`). JSON is too verbose for BLE payloads.

### 9.1 Envelope

```
Envelope {
  v          : uint8      // protocol version, start at 1
  msgId      : bytes(16)  // random per transmission — for the de-dup cache.
                          // NOT the claim id. A claim can be sent many times.
  hopLimit   : uint8      // decremented at each hop
  kind       : uint8      // 0=claim 1=corroboration 2=resolution
                          // 3=vouch 4=revocation 5=volunteerBeacon 6=timeGossip
  body       : bytes      // CBOR, shape depends on kind
  originSig  : bytes(64)  // Ed25519 over (v || kind || body)
}
```

**The signature deliberately excludes `hopLimit` and `msgId`.** `hopLimit` changes at every hop — signing it would invalidate the signature after the first forward. This is why §5's "sign the immutable core" rule matters at the transport layer too.

### 9.2 Size budget

| Constraint | Value |
|---|---|
| BLE characteristic write, practical | ~512 bytes |
| **Target envelope size** | **≤ 400 bytes** |
| Ceiling before fragmentation is required | 512 bytes |

A claim must fit in **one write**. If a payload pushes past 400 bytes, raise it with the team rather than quietly adding fragmentation — fragmentation is a real feature with real failure modes (partial delivery, reassembly timeouts), not an implementation detail.

Consequences that affect `data/` directly:
- Free-text fields (`proxyNote`, hazard `note`) capped at **80 characters**
- Enums serialize as **ints**, never names
- `GeoPoint` as two 4-byte floats, not doubles — ~1m precision is plenty at a 150m bucket

### 9.3 Receive pipeline — order matters

Every receiving device, in this exact order:

1. **De-dup** — `msgId` in the seen cache? Drop silently, do not relay.
2. **Verify** — `originSig` invalid, malformed, or missing? **Drop. Do not relay, do not store.**
3. **Decrement** `hopLimit`. If zero, store locally but do not relay further.
4. **Store**, then relay per routing policy — full flood for `sos`/`sosProxy`/`hazardReport`, selective for `resource`.

Verification comes *before* storage so a malformed claim can never enter the store, and before relay so a tampered claim can't be propagated by an honest device.

---

## 10. SQLite tables

```sql
CREATE TABLE claims (
  id                  TEXT PRIMARY KEY,
  type                INTEGER NOT NULL,
  origin_device_id    TEXT    NOT NULL,
  origin_sequence     INTEGER NOT NULL,
  clock_device_id     TEXT    NOT NULL,
  clock_counter       INTEGER NOT NULL,
  lat                 REAL    NOT NULL,
  lon                 REAL    NOT NULL,
  geohash_bucket      TEXT    NOT NULL,
  origin_signature    BLOB    NOT NULL,
  claim_trust         INTEGER NOT NULL,
  dispatch_priority   INTEGER NOT NULL,
  status              INTEGER NOT NULL,
  payload             BLOB    NOT NULL,   -- CBOR, per §8
  resolution_method   INTEGER,            -- NULL while ACTIVE
  resolved_by         TEXT,
  hop_limit           INTEGER NOT NULL,
  display_lifetime_ms INTEGER,            -- NULL for sos / sosProxy — see below
  created_at_logical  INTEGER NOT NULL,
  archived_at_logical INTEGER
);

CREATE INDEX idx_claims_status_type ON claims(status, type);
CREATE INDEX idx_claims_geohash     ON claims(geohash_bucket);

CREATE TABLE corroborations (
  claim_id        TEXT    NOT NULL,
  device_id       TEXT    NOT NULL,
  hop_distance    INTEGER NOT NULL,
  signal_strength REAL,
  first_seen_via  TEXT,                   -- relaying device id, NULL if self-generated
  kind            INTEGER NOT NULL,       -- CorroborationKind
  is_volunteer    INTEGER NOT NULL,
  clock_counter   INTEGER NOT NULL,
  PRIMARY KEY (claim_id, device_id)       -- one corroboration per device per claim
);

CREATE TABLE seen_messages (
  msg_id  BLOB PRIMARY KEY,
  seen_at INTEGER NOT NULL
);
```

### 10.1 `display_lifetime_ms` must be NULL for SOS

Not a large number — **NULL**. A large value invites someone to "tune it down" later during optimisation. NULL forces a code change and a conversation. Enforce it at write time:

```dart
assert(!(type == ClaimType.sos || type == ClaimType.sosProxy)
       || displayLifetimeMs == null);
```

Likewise `ResolutionMethod.autoExpired` is **never** valid for `sos` or `sosProxy`. Assert this too.

### 10.2 Storage budget and eviction

Target cap: **200 MB** for the claim store, tuned during testing.

Eviction order:
1. Archived and resolved
2. Oldest resolved
3. Oldest low-priority resource pins

**`ACTIVE` claims of type `sos`/`sosProxy` are never evicted, at any storage pressure — after map tiles if it comes to that.** Warn the user before storage becomes critical.

---

## 11. Canonical enums — do not add values without a team sync

```dart
enum ClaimType { sos, sosProxy, hazardReport, resource }
enum ClaimTrust { unconfirmed, corroborated, groundConfirmed }
enum DispatchPriority { low, seenByVolunteer, enRoute }
enum ClaimStatus { active, resolved, archived }
enum ResolutionMethod { qr, manual, autoExpired }
enum CorroborationKind { independentGeneration, explicitAttestation }
enum HeadcountBucket { twoToFive, sixToFifteen, fifteenPlus }
enum HazardType { flood, roadBlock, structuralDamage, other }
enum ResourceCategory { foodWater, shelter, medical, equipment }
```

`NodeTrust` (campaignVerified | vouchedProvisional | unverified) lives in the identity model, not here — it describes a *device/person*, not a claim. Don't confuse `claimTrust` with `nodeTrust`; see `CLAUDE.md` §5 naming table.

---

## 12. Changing this file

1. Don't. Not alone.
2. Propose the change, ping both other people, get explicit acknowledgment.
3. Update "Last changed by / on" at the top.
4. If the change affects claim identity (§2), trust transitions (§3), or resource counting (§8.1), also update `CLAUDE.md` §2 to match — those invariants quote this file's logic directly, and drift between the two documents is itself a bug worth flagging.
