# MayDay — Offline Disaster Response System — Project Context (v2, corrected)

> A community-mode, offline-first mobile platform for rural disaster response: location-tagged SOS, mesh-based rescue coordination, a corroboration-driven trust engine, and a shared offline resource map.

**Problem Statement (PS2):** Disaster Response Without Infrastructure — develop a mesh-network emergency communication system for disaster-hit rural areas with no internet or power. Must support location-tagged SOS signals, rescue coordination, and a shared resource map offline.

This document is the single source of truth for the project: the reasoning, the flow, the architecture, the tech stack, and — just as importantly — what we deliberately chose *not* to build and why.

> **v2 changelog.** This revision resolves 24 inconsistencies found in v1. The six that changed the design substantively: SOS claims now have their own unique identity and can no longer be merged with each other (§4.1); corroboration no longer counts message relaying as evidence (§4.3); payload encryption is replaced with signing (§7); SOS claims never decay (§4.4); device clock drift is handled explicitly (§4.2); and the last references to a backend server have been removed (§2). Changes are marked **[v2]** throughout.

---

## 1. Core Design Philosophy

> **Note:** An earlier draft assumed eventual internet connectivity (a backend server, NGO web dashboard, SMS/USSD gateways, "opportunistic sync"). That assumption has been **dropped entirely.** The system is pure offline-only, permanently — no internet path anywhere, no backend, no external dashboard. The mesh of Volunteer/NGO-authority phones *is* the response system. This removes the biggest structural risk of the earlier design (usefulness gated on someone eventually reaching the public internet) and forces every feature to be genuinely self-sufficient.

- **Worst case is not just the default assumption — it's the only case.** Zero internet, zero cell towers, no power grid, for the entire disaster window. There is no fallback path to the internet built into the system at all.
- **Offline-first, not offline-tolerant.** Every core action (SOS, report, contribute) writes locally and succeeds instantly. There is no sync-to-server step to design around, because there is no server.
- **No central authority to verify claims, ever.** Trust cannot come from a backend or an AI model — it emerges from the mesh itself, through independent corroboration by physically-distinct devices, and from Volunteer/NGO nodes acting as the trusted human layer.
- **Reliability over efficiency for anything life-critical.** SOS traffic floods aggressively even at battery cost; non-critical traffic (resource pins) uses conservative, selective relay.
- **[v2] Life-critical data is never silently discarded.** No decay, no de-duplication, no storage eviction, and no merge rule may ever cause an unresolved SOS to disappear from a device that is holding it. Where a trade-off exists between saving battery/storage and keeping an SOS visible, the SOS wins. This principle overrides every optimisation in this document.
- **Volunteer nodes are the terminal destination, not a relay to something bigger.** A claim is "done" when a Volunteer/NGO node has **physically reached the location and assessed it** — not when a Volunteer's phone has merely received the message, and not when it reaches a dashboard. **[v2 — §1 previously said "seen and acted on," which conflicted with §6; "seen" is explicitly not sufficient.]** Post-disaster reporting, analytics, or handoff to formal authorities is out of scope (may exist as a separate manual process, not part of the app's architecture).

### 1.1 [v2] Stated operating target

"Zero power, permanently" is the environment, not a capability claim. The system's actual design target:

- **72 hours of useful operation** on a mid-range Android phone starting at 50% charge.
- Achieved through duty-cycled scanning (listening in short repeating bursts instead of continuously), a low-power mode that drops resource traffic while preserving SOS relay, and campaign-time guidance that power banks are part of preparedness.
- Beyond 72 hours, the system depends on either recharging or optional fixed relay points (see §9). This is stated as a limitation, not hidden.

---

## 2. User Roles

### General User
- Anonymous-ish identity: a device keypair generated on first launch. Not tied to a real-world name.
- Can raise SOS, raise a **proxy SOS on behalf of someone else** *[v2, see §3]*, submit Reports, attest to nearby claims, and *request* (but not pledge) Resources.
- Sees the main screen: offline map + bottom sheet.

### Volunteer / NGO-Authority Node
- Registered and verified **before** the disaster, during an offline-readiness awareness campaign.
- Gets an **extra ops screen**: rescue notifications, report review, resource coordination.
- Weighted higher in the trust engine and prioritised as a routing target for SOS traffic.
- Can pledge Resources (General Users cannot, to limit phantom-resource spam).

### 2.1 [v2] Identity — how it actually works with no network

v1 described "phone-number login," which cannot work: phone-number verification means an SMS one-time code, and SMS needs a cell tower. Corrected:

- At campaign registration, the volunteer's device generates a **random keypair** — two matched keys, one kept secret, one shared publicly. Anything signed with the secret key can be verified by anyone holding the public one, with no server involved.
- The public key is signed by the campaign organiser's key, producing a portable **volunteer credential**.
- The phone number is stored only as a **human-readable label** bound to that credential. It is never the credential itself and is never used to log in. *[v2 — "phone-number-derived credential" in v1 was cryptographically unsafe: Indian mobile numbers are a small, guessable space.]*
- The secret key lives in the device's hardware-backed secure storage (Keystore/Keychain).
- **Honest limitation:** Android deletes Keystore keys on app uninstall. Volunteer identity therefore **does not survive a reinstall.** *[v2 — v1 claimed it did; this was factually wrong.]* Recovery is via vouching (§2.2). Optionally, the campaign can issue an encrypted identity backup file to normal device storage; this is a user choice with its own theft risk.

### 2.2 [v2] Mid-disaster onboarding — web-of-trust vouching, fully offline

**Chosen approach:** an already-verified Volunteer signs a vouch message for a new person ("I know this person, they're a nurse"). The vouch propagates like any other signed message.

Rules, all enforceable on-device with no server:

- The new node enters **`VOUCHED_PROVISIONAL`** node trust.
- **One vouch** → may respond to SOS and record ground confirmations. **May not pledge Resources.** *(Resource pledging is the spam-sensitive power, so it stays gated.)*
- **Two vouches from independent campaign-verified volunteers** → promoted to full trust, including resource pledging. **[v2 — this replaces v1's "until it can sync to the backend post-disaster," which contradicted the no-backend rule and left provisional status with no offline resolution path.]**
- **Provisional nodes cannot vouch for anyone.** Prevents unbounded trust minting from a single compromise.
- **Cap of 5 vouches per verified volunteer**, carried inside the signed vouch so any device can check it independently.
- **Revocation:** a signed revocation message propagates like any other claim and overrides the vouch. Devices apply the most recent valid revocation. *[v2 — v1 had no revocation at all.]*

Ruled out for now: pre-issued PKI credential bundles for district authorities to activate volunteers on-site — a real option, but needs groundwork built well in advance. Future work, not MVP scope.

---

## 3. App Flow

1. **Entry screen** — two buttons: **User** / **Volunteer**. Volunteer entry unlocks the stored credential on-device (biometric or PIN). No network step. *[v2 — was "login uses phone number."]*
2. **Main screen** — single offline map with a toggle between two views:
   - **Emergency layer** — active rescue/SOS pins **and hazard report pins**, with distinct icons for each. *[v2 — v1's §3 named this the "SOS layer" and left hazard reports with no layer to live on, though §10 assumed they appeared here.]*
   - **Resource layer** — pins for **Food & Water, Shelter, Medical, Equipment**, each showing type and live count. *[v2 — v1 used two different category lists in different sections.]*
3. **Bottom sheet** — three primary actions: **Rescue**, **Report**, **Contribute**.
4. **Volunteer-only extra screen** — incoming rescue queue, report review, resource coordination.

### Rescue

Three sub-types *[v2 — v1 had two, and had no way to raise an alarm for a person without a working phone]*:

| Type | Meaning | Notes |
|---|---|---|
| **Individual SOS** | I need rescue | Self-raised |
| **Group SOS** | We need rescue — several of us here | Carries a headcount bucket: 2–5 / 6–15 / 15+, so a responding Volunteer knows what to bring |
| **Proxy SOS** *[v2, new]* | Someone else needs rescue and cannot raise it themselves | Reporter marks the location on the map; carries reporter's identity and approximate headcount; shown with a distinct icon because reporter details may be less reliable than first-hand |

**Why Proxy SOS is not optional:** §10 states rural families typically share one smartphone between them. The most common rescue case is therefore a person *without* a phone. v1 forbade filing this under Report ("not for missing/injured people — that's Rescue") while Rescue was self-raised only, leaving the system's most likely scenario with no input path at all.

**[v2] This also settles the Group-SOS open question** carried in v1 §9: "one reporter speaking for others" is **Proxy SOS**; "several people tagging into one shared SOS" does not exist as a data model — each person's SOS stays a separate claim (§4.1), and nearby SOS pins are grouped **visually only**.

Propagation:
- Location-tagged, propagated hop-by-hop with aggressive hop-bounded flood — every device relays SOS traffic (unlike Bridgefy's "silence other nodes" approach), because a missed rescue is catastrophic and extra battery drain is merely costly.
- **[v2] Volunteer-aware routing, corrected.** v1 said nodes "preferentially relay toward known/suspected Volunteer directions" — but BLE gives no directional information, and in a full flood there is nothing left to prefer. Replaced with two mechanisms that work:
  - **Volunteer beaconing** — Volunteer nodes periodically broadcast a small signed "volunteer here" beacon carrying a hop count. Neighbouring devices learn "a volunteer is ~3 hops away via this neighbour," building a gradient the mesh can follow.
  - **Volunteer-first send ordering** — when a device has several neighbours and limited radio airtime, it transmits toward known volunteer directions *first*. Same flood, different queue order.

### [v2] Closing a rescue *(renamed from "Resolution" — v1's heading sat under three open data-model questions and read as though it answered them, which it did not)*

- Resolution is by **QR scan at physical contact**, with a manual fallback.
- **The QR must prove presence, not just knowledge.** v1 encoded the SOS ID alone — but that ID travels across the whole mesh in the clear, so every device already knows it, and anyone could fabricate the code and falsely clear a live emergency. **[v2]** The QR now encodes:
  - the SOS ID,
  - a **fresh random nonce** generated at the moment of display,
  - a **signature from the requester's device key** over both.

  The scanning Volunteer counter-signs. The resulting record proves two specific devices were physically co-present — a QR must be optically scanned, so they were in the same room.
- **Any Volunteer can scan it** — not necessarily the one who first received the alert, since mesh relay means the responder often isn't the first to see it. No personal data is in the QR.
- The resolved state propagates back through the mesh the same way the SOS did, so every device holding that entry clears it.
- **Fallback manual resolve** exists for when the person's phone is dead, lost, or damaged. It is always tagged lower-confidence, and **archives rather than clears** the pin, so a mistaken or malicious manual resolve cannot erase the record that someone needed help.
- Resolved entries are **archived, not deleted** (purge policy in §7.1).

### Report
- For hazards: flood, road blockage, structural damage, etc. **Not** for missing or injured people — that is Rescue, and specifically **Proxy SOS** if the person cannot raise it themselves. *[v2 — v1 closed this door without opening another.]*
- **De-duplication without a central server:** geohash-bucketed by location (~150–300m grid) + type. Reports in the same bucket aren't hidden as duplicates — they merge into one pin with a **rising confirmation count** ("12 people reported flooding here"), which doubles as a live confidence signal.
- **[v2] Merging applies to hazard reports and resources only — never to SOS.** See §4.1.

### Contribute
- Volunteer-only action (identity-gated, to blunt phantom-resource spam — there is no way to verify a claimed resource offline).
- Pins a resource with type and count.
- Starts at a lower-confidence visual state and **decays** if never corroborated or claimed — mitigation, not proof, and stated as such.
- **[v2] Claiming a resource no longer writes to the authoritative count.** v1 said "when someone uses/claims a resource, the count decrements" — but "someone" is a General User, which meant General Users could write to the resource ledger after all, just downward. A malicious or panicking user could zero out a real food supply. Corrected to two separate numbers:

| Field | Who writes it | Meaning |
|---|---|---|
| `pledged_count` | Volunteers only | Authoritative. Add-only. |
| `claimed_reports` | Any user, rate-limited | Soft signal, shown separately as "reportedly running low." Add-only. |

  Displayed availability is computed, never stored: `available = max(0, pledged − claimed)`. Only a Volunteer physically on site can reset the authoritative count.

---

## 4. The Corroboration Engine (shared trust primitive)

Resource verification, report de-duplication, and anonymous-SOS spam resistance are the same underlying problem — "how do we assign confidence to a claim with no central authority to check it against?" One shared primitive backs all three.

```
Claim {
  id                  // see §4.1 — computed differently per type
  type                : SOS | SOS_PROXY | HAZARD_REPORT | RESOURCE
  origin_device_id
  origin_signature    // [v2] every claim is signed by its originator
  logical_clock       // [v2] see §4.2
  corroborations      : [ {device_id, hop_distance, signal_strength,
                           first_seen_via, timestamp, is_volunteer} ]
  claim_trust         : UNCONFIRMED → CORROBORATED → GROUND_CONFIRMED
  dispatch_priority   : LOW → SEEN_BY_VOLUNTEER → EN_ROUTE
  status              : ACTIVE → RESOLVED → ARCHIVED          // [v2] new
  resolution_method   : QR | MANUAL | AUTO_EXPIRED | null     // [v2] new
  resolved_by         : volunteer_id | null                   // [v2] new
  hop_limit           // [v2] renamed from TTL
  display_lifetime    // [v2] renamed from TTL
  created_at, last_confirmed_at, archived_at
}
```

**[v2] Three naming fixes baked into the schema above:**
- `trust_tier` → `claim_trust`, because v1 used the phrase "trust tier" for *claims* in §4 and for *volunteer nodes* in §2. Node trust is now `node_trust`: `CAMPAIGN_VERIFIED / VOUCHED_PROVISIONAL / UNVERIFIED`. Two unrelated ideas no longer share a name.
- `TTL` → **`hop_limit`** (how many times a message may be forwarded) and **`display_lifetime`** (how long a pin stays visible). v1 used "TTL" for both and §9 listed them as one tunable value; they are unrelated quantities and are tuned separately.
- `status` / `resolution_method` / `resolved_by` added — v1's §3 described QR resolution, manual fallback, and archiving in detail, but the schema had no field for any of it, so §6 step 8 propagated a state that did not exist.

### 4.1 [v2] Claim identity — two rules, because SOS is not a report

**This is the most important correction in v2.** v1 used one identity rule for every claim type:

```
id = content-hash(type + geohash-bucket + time-bucket)
```

With a 150–300m bucket, **two different families on the same street raising SOS in the same window produce the same ID.** The system treats them as one claim. One pin appears instead of two. Their independent calls for help are counted as corroborating *each other*. And when a Volunteer rescues family A and scans their QR, the resolved state propagates and **family B disappears from every map in the mesh**, with everyone believing that location is handled.

Merging is correct for hazards — twelve people reporting one flood *should* become one pin reading 12. It is catastrophic for a claim type where each instance is a distinct human being.

| | HAZARD_REPORT / RESOURCE | SOS / SOS_PROXY |
|---|---|---|
| **ID** | `hash(type + geohash-bucket)` — merging is the goal | `hash(origin_device_id + local_sequence_number)` — **globally unique** |
| **Duplicates** | Merged; confirmation count rises | **Never merged, under any condition** |
| **Corroboration** | Independent reports raise the count | Neighbours attest, but the claim remains its own record |
| **Resolution** | Decays out | Resolved individually by its own unique ID |
| **Grouping** | Data-level | **Display only** — pins cluster visually at low zoom ("3 SOS here") while remaining separate records underneath, each independently resolvable |

### 4.2 [v2] Time, when no device knows what time it is

Phones normally set their clocks from the network. **No network means no time sync.** Over days, low-end phones drift by minutes; some boot with the clock reset entirely. v1 put a `time-bucket` inside the claim ID and used timestamps for corroboration and decay — so two people reporting the same flood four minutes apart on drifted clocks would land in different buckets, produce different IDs, and **never merge or corroborate.** The trust engine rested on a clock the design had no way to set. Corrected in three parts:

1. **Time is removed from the claim ID.** Hash on `type + geohash-bucket` only. The time window becomes a *matching rule* applied afterwards, with generous tolerance — not part of identity.
2. **Logical clocks.** Every message carries a counter that increments on each send, alongside the sender ID. This gives reliable *ordering* between devices without either knowing the real time — enough to answer "which update is newer," which is all the merge logic actually needs.
3. **Time gossip.** When devices meet they exchange clock readings and each maintains an estimate of mesh-median time, weighting Volunteer nodes higher. The UI shows **relative** time only — "about 2 hours ago" — never a precise timestamp, because precision here would be a fabrication.

### 4.3 [v2] Trust tiers — and what corroboration actually means

- **UNCONFIRMED** — single device, no independent support. Shown faint on the map. Rate-limited per device.
- **CORROBORATED** — 2+ physically-distinct devices **independently generated** a matching claim, **or explicitly attested** to it. Full-opacity pin.
- **GROUND_CONFIRMED** — a Volunteer node has physically reached the location and assessed it directly (QR scan on rescue, or explicit on-site confirmation for a Report/Resource). The only tier reflecting real verification, because it's the only point where someone with eyes on the situation actually checked.

**[v2] Relaying is not corroboration.** v1 defined CORROBORATED as "2+ independent devices **generated or relayed** the same content-hash" — and then, twenty lines later, argued at length that a Volunteer relaying a claim proves nothing because "they haven't verified anything, they've just received the same message everyone else did." Both cannot be true, and the second is correct — it applies to *every* device, not only Volunteers. As v1 was written, **any fabricated SOS reached CORROBORATED — "genuine evidence," per the document — the moment one neighbouring phone forwarded it.** One hop. The engine's headline feature was defeated by the mesh doing its normal job.

Corroboration now requires exactly one of:

- **Independent generation** — a different device created a matching claim *without having received the original first*, or
- **Explicit attestation** — a human deliberately tapped "I can see this too" on their own device.

Plus an **anti-echo rule**: a device cannot corroborate a claim it first learned about *from the mesh*. The `first_seen_via` field enforces this. Without it, ten people "confirm" a rumour they all read on the same screen — that is one witness and nine repeaters, not ten witnesses.

### 4.4 [v2] Decay — never for SOS

v1: *"unconfirmed claims fade from the map past a TTL if never corroborated."*

Applied to a real case: one person, trapped, alone, no neighbours. Their SOS is UNCONFIRMED precisely *because* there is nobody nearby to corroborate it. Under v1's rule, it fades off the map. **The person in the most danger is the one whose call for help the system deletes first** — a direct contradiction of §1's "reliability over efficiency for anything life-critical."

Decay is now type-specific:

| Claim type | Decay behaviour |
|---|---|
| **SOS / SOS_PROXY** | **Never decays.** Clears only on confirmed resolution. An aging unresolved SOS becomes *more* visually urgent, not less. |
| **HAZARD_REPORT** | Decays over a long window — roads reopen, water recedes. |
| **RESOURCE** | Decays fastest — stale supply information is the most actively misleading. |

### 4.5 Priority is not trust

A Volunteer *relaying* or *seeing* a claim does **not** raise `claim_trust` — at that moment they know no more than any other device. Treating "a Volunteer touched this" as confirmation would let a false SOS gain credibility purely by routing accident, which is the exact failure mode this engine exists to prevent.

What it *does* raise is **`dispatch_priority`** — surfacing the claim higher in that Volunteer's action queue, since it's now known to be within reach of someone who can act. A claim can be `EN_ROUTE` while still `UNCONFIRMED`; a Volunteer heading toward something that turns out to be false is an acceptable cost of erring toward speed. Trust moves only on evidence.

### 4.6 [v2] Anti-spam — and honest limits

v1 rate-limited per "persistent local device ID" and counted "physically-distinct devices." But the user controls the device: uninstall, reinstall, new ID, limits gone. Worse, one phone could present as five and manufacture CORROBORATED status for a fabricated claim — a **Sybil attack**, one actor wearing many identities to fake a crowd.

This **cannot be fully solved offline**, and we state that plainly, in the same spirit as our existing honesty about resource verification. What we do is raise the cost:

- Device identity derives from a **hardware-backed key**, making identity churn harder than a reinstall.
- **Corroboration is weighted by physical evidence, not identity count.** Two reports arriving over genuinely different radio paths at different signal strengths are stronger than two IDs. A single phone can fake identities; it cannot easily fake being in two places. Hence `signal_strength` and `hop_distance` in the corroboration record.
- **Newcomer discount** — corroborating devices must have been observed on the mesh *before* the claim existed. An ID appearing at the same moment as the claim it confirms carries little weight.
- **Contribution cap** — no single device's attestations can move a claim past a fixed ceiling on their own.
- Explicitly **not** solved with AI/ML — infeasible offline. Rule-based, deterministic, cheap.

---

## 5. Routing Strategy — Why Not Pure Bridgefy-Style Relay

Bridgefy's model (pick 1–2 "best" neighbour hops, ask other nodes to stay silent) is tuned for general-purpose messaging in battery-rich, urban, high-density contexts where every message is equally unimportant.

This project's profile differs: a small number of *known-important* destinations (Volunteers), a small number of *high-value, low-frequency* message types, and a context where **battery, not bandwidth, is the scarce resource**.

**Resulting split:**
- **SOS / hazard reports** — full hop-bounded flood, every device relays.
- **Resource / low-priority traffic** — selective, Bridgefy-style relay, since a stale resource pin is an inconvenience, not a life risk.

*[v2 — v1 restated the device-density open question here and again in §9. It now lives in §9 only; see "Target device density."]*

---

## 6. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     MOBILE APP (Client)                     │
│  Offline Map | SOS/Report/Contribute UI | Local Trust Engine│
│  Local DB (Claim store) | Mesh Networking Module            │
└──────────────────────────────┬──────────────────────────────┘
                               │
                   ┌───────────▼────────────┐
                   │       MESH LAYER       │
                   │   BLE + Wi-Fi Direct   │
                   │  Hop-bounded flood     │
                   │  (SOS / Report)  /     │
                   │  selective relay       │
                   │  (Resource)            │
                   │  Content-hash de-dup   │
                   │  Signature verification│
                   └───────────┬────────────┘
                               │
                   ┌───────────▼────────────┐
                   │  VOLUNTEER / NGO NODES │
                   │  Extra ops screen:     │
                   │  rescue queue, report  │
                   │  review, resource      │
                   │  coordination — the    │
                   │  terminal destination  │
                   │  of the system         │
                   └────────────────────────┘
```

There is no internet path, backend server, or external dashboard anywhere in this design.

### End-to-end flow
1. Claim created on-device, fully offline. ID computed per §4.1 (**unique for SOS, merge-hash for reports/resources**), signed with the device key, logical clock attached, `hop_limit` and `display_lifetime` set per type.
2. `claim_trust` computed locally (UNCONFIRMED by default).
3. Stored in the local Claim store (SQLite) and immediately relayed into the mesh — no outbox-awaiting-connectivity concept, since there is nothing to connect to.
4. Mesh relay — SOS/Reports flood; Resource pins relay selectively. **Each hop verifies the originator's signature, discards anything unsigned or malformed**, decrements `hop_limit`, and checks a message-ID cache to avoid re-broadcast. *[v2 — signature verification added.]*
5. As **independent generations or explicit human attestations** arrive from physically-distinct devices, `claim_trust` upgrades to CORROBORATED. **Relaying never does this.** *[v2]*
6. Separately, once a Volunteer node relays or sees a claim, `dispatch_priority` rises. Attention, not truth.
7. GROUND_CONFIRMED only once a Volunteer physically reaches the location and assesses it. The only point genuine verification happens.
8. Rescue resolution (**signed QR handshake**, or lower-confidence manual fallback) sets `status: RESOLVED` and propagates back through the mesh the same way the SOS did. **Because SOS IDs are unique (§4.1), this clears exactly one person's claim and cannot clear a neighbour's.** *[v2]*
9. Archived after a defined window, then purged per the §7.1 storage policy — never before.
10. Nothing leaves the mesh. "Done" means a Volunteer physically assessed and acted, not that a Volunteer's phone relayed a packet.

---

## 7. Tech Stack

Entirely client-side / on-device — there is no server component at all.

| Layer | Choice | Reasoning |
|---|---|---|
| Mobile app | React Native / Flutter, Android-first | Android dominates rural India's device market; low-end compatibility matters more than platform polish |
| Mesh transport | Hybrid **BLE + Wi-Fi Direct** | BLE for low-power discovery and small-payload relay; Wi-Fi Direct for higher-bandwidth close-range transfers |
| Offline maps | Pre-downloaded **OpenStreetMap** tiles (`.mbtiles`), rendered via MapLibre GL | **[v2]** Bundled at campaign time, low zoom, district-scoped. Mesh tile transfer is a *narrow fallback only* — see §7.2 |
| Local storage | SQLite on-device | Claim objects and trust state; instant local writes, no sync concept |
| **Message authenticity** *[v2, replaces payload encryption]* | **Ed25519 signatures** (libsodium) — claims travel **signed but not encrypted** | See §7.3 |
| Shared resource inventory (mesh-local) | **Add-only counter CRDT** | **[v2]** Store `pledged` and `claimed` separately, each only increasing; compute availability at display time — see §7.4 |
| Volunteer identity | Random keypair in hardware-backed secure storage, campaign-signed credential; phone number as label only | §2.1 |
| Time | Logical clocks + mesh time gossip; relative time in UI | §4.2 |

**No backend, no NGO dashboard, no SMS/USSD gateway.** See §8.

### 7.1 [v2] Storage budget and purge policy

v1 promised "archive-then-purge" but never defined a purge rule, leaving unbounded growth on the cheapest phones — which also hold hundreds of megabytes of map tiles.

- Hard cap on the claim store (target: 200 MB, tuned during testing).
- Eviction order: archived-and-resolved first → oldest resolved → oldest low-priority resource pins.
- **Active SOS records are never evicted, at any storage pressure.** They are the last thing on the device, after map tiles if necessary (§1).
- Users are warned before storage becomes critical, with a clear action.

### 7.2 [v2] Map tiles — why mesh distribution is a fallback, not a plan

v1 offered "bundled with the app install **or** distributed peer-to-peer over the mesh" as equal options. Offline tiles for one rural district run to **hundreds of megabytes**. Wi-Fi Direct might manage that in ~10 minutes at close range in ideal conditions, consuming a large share of the very battery §5 calls the scarcest resource. Over BLE it would take days.

Corrected: tiles are **pre-bundled at campaign time**. Mesh transfer is permitted only for single tiles, on explicit user request, over Wi-Fi Direct only, above a battery threshold, and **never on a Volunteer node during active response**.

### 7.3 [v2] Signing, not encrypting — and why the v1 choice was self-defeating

v1 specified "end-to-end payload encryption — relay phones route messages without being able to read their content." But every function of this system requires relay phones to read content: to draw the pin, to compute the geohash bucket for merging, to corroborate. **Every General User is a relay.** If relays cannot read SOS messages, nobody sees an SOS — and an SOS has no addressee anyway. It is a public broadcast, so there are no two "ends" for end-to-end to run between. Encryption and the corroboration engine were mutually exclusive as written.

| | Signing | Encryption |
|---|---|---|
| What it proves | Who sent it, and that it wasn't altered | Nobody can read it but the intended recipient |
| Content readable by relays? | **Yes** | No |
| Fit for this project | **Exactly right** | **Actively harmful** for claims |

All claims travel **signed and readable**. Encryption is reserved for genuinely private one-to-one messages — the current design has none, so it is out of MVP scope. *(v1 §2 already referred to "any other signed message," so signing was assumed in the design but never appeared in the tech stack; this closes that gap.)*

### 7.4 [v2] Why a plain counter CRDT would break

A CRDT lets several devices edit shared data offline and merge automatically with no server — the right family of tool here. But the classic counter CRDT guarantees the merge won't *conflict*; it does not guarantee the result stays sensible. Twenty devices, out of contact, each record one person taking the last food packet. They merge. The count reads **−19**.

v1 named CRDTs as the solution and listed "CRDT library choice" as the open decision — but the hard part is the invariant, not the library. Fixed by storing add-only totals and computing availability at display time (§3, Contribute), and by showing a **range** when replicas disagree ("2–6 packets") rather than a falsely precise number.

---

## 8. Features Ruled Out (and Why)

| Feature | Why it was ruled out / deferred |
|---|---|
| **Backend server, NGO web dashboard, SMS/USSD gateways, opportunistic internet sync** | Any backend-facing design implicitly assumes internet is reachable *eventually*, which is not guaranteed in the weeks-long, zero-infrastructure scenario this targets. Removed entirely. Also removes a category of regulatory/legal risk (SMS/USSD compliance, data-protection law, cloud cost) that doesn't apply to a system with no server. |
| **Per-region physical servers** | Superseded by the backend removal — no longer applicable in any form. |
| **AI/ML-based trust or fraud scoring** | Needs either a live model call (connectivity) or an on-device model too heavy for low-end hardware. Replaced with the rule-based Corroboration Engine. |
| **Photo/image-based rescue confirmation** | Complexity with no offline way to verify authenticity. Replaced with signed QR at point of physical contact. |
| **Cryptographic real-time verification of Contribute claims** | No ground-truth check is possible offline. Mitigated via identity-gating + decay, explicitly risk-reduction rather than proof. |
| **Bridgefy-style "silence other nodes" relay for all traffic** | Dangerous for life-critical traffic. Split: full flood for SOS/reports, selective for resources. |
| **Registration-only volunteer onboarding** | Didn't account for helpers appearing mid-disaster. Extended with vouching at a provisional tier (§2.2). |
| **Instant deletion of resolved rescue records** | Would destroy the only record that someone needed help. Archive-then-purge instead (§7.1). |
| **Fixed "QR-scanner must be original recipient" rule** | The Volunteer who sees an SOS often isn't the one who responds. Opened to any Volunteer, with a signed challenge rather than a bare ID (§3). |
| **[v2] End-to-end encryption of claim payloads** | Structurally incompatible with corroboration, map display, and de-duplication, all of which require relay devices to read content. Replaced with signatures (§7.3). |
| **[v2] Time-bucketed claim IDs** | Depends on synchronised clocks, which cannot exist without a network. Replaced with logical clocks and time gossip (§4.2). |
| **[v2] Relay-as-corroboration** | Made a fabricated claim CORROBORATED after a single hop. Replaced with independent generation or explicit human attestation, plus an anti-echo rule (§4.3). |
| **[v2] Directional relay toward Volunteers** | BLE provides no directional information, and a full flood leaves nothing to prefer. Replaced with volunteer beaconing plus send-order prioritisation (§3). |
| **[v2] Uniform decay across all claim types** | Would erase an isolated person's unanswered SOS — precisely the case the system exists for. SOS now never decays (§4.4). |

---

## 9. Open Decisions & Areas Needing Further Research

**[v2] Closed since v1:** Group SOS data model (→ §3, Proxy SOS + unique SOS identity); CRDT approach (→ §7.4, add-only counters; library choice remains open but is no longer the hard part); mid-disaster volunteer resolution path (→ §2.2, two-vouch promotion, no backend).

**Open decisions**
- Whether to formally support **fixed relay points** (a generator-powered node at a relief camp) as recommended field infrastructure. **[v2] Note this is now also the most credible answer to the 72-hour battery ceiling in §1.1, not just a coverage question** — the two were treated as unrelated in v1. Such nodes remain mesh-local, never internet-connected.
- CRDT library selection (semantics settled in §7.4).
- Exact `hop_limit` and `display_lifetime` defaults per message type, pending hop-range testing. *[v2 — these are two separate tunables, not one.]*
- Whether device-ownership gaps (households with no BLE-capable smartphone at all) are addressed within scope or stated as an accepted limitation. **[v2] Partially mitigated by Proxy SOS (§3)**, which lets a neighbour raise the alarm — but a person with no phone *and* no reachable neighbour remains outside the system's reach, and there is no SMS/USSD fallback. This should be stated openly.

**Needs research before deciding**
- Real-world BLE / Wi-Fi Direct hop range and battery drain under duty-cycled mesh scanning, on **low-end** Android chipsets specifically.
- **[v2] Actual clock-drift rates** on target hardware over 72+ hours without network sync — determines how wide the §4.2 matching tolerance must be.
- Mesh behaviour under high device density (a relief camp with hundreds of phones) — does flood routing create broadcast storms in practice?
- Target device density (households/km²) in deployment regions, to validate whether full-flood SOS relay is battery-survivable and whether the mesh stays connected enough to reach a Volunteer node at all with no fallback path.
- Usability testing with rural, low-literacy users — icon-first UI needs field validation.
- Device-ownership rates in target communities.
- **[v2] Sybil resistance in practice** — how much a hardware-backed device ID plus radio-path weighting (§4.6) actually raises the cost of faking corroboration.
- Liability exposure if the trust engine misclassifies a claim, or a message never reaches a Volunteer — affects how confidently the UI can ever say "help is coming."

---

## 10. Submission Write-Up

**Problem Statement:**
Disasters have become more frequent and more severe, with shorter warning times and less recovery space between them — forcing communities to respond faster with fewer resources. The divide is sharpest in rural India, where mobile coverage is uneven even in normal weather and fails outright during disasters. India's current early warning systems, including the new Cell Broadcast system, depend entirely on working cellular networks and compatible handsets — excluding the population most at risk precisely when reach matters most. In normal conditions only 3.8% of rural households have high-speed connectivity; after power and tower loss, that figure collapses.

This is not a warning problem — it is a coordination problem. During a disaster, rural communities have no way to signal exactly who needs rescue and where, no way to see what resources (food, shelter, medical aid) exist nearby, and no way to organise volunteers and NGO responders on the ground. Offline mesh apps like BitChat and Bridgefy exist, but they are general-purpose messengers — they don't support location-tagged emergencies, verified rescue coordination, or resource tracking. The people affected are rural families who typically share a single smartphone, cut off from power, towers, and data at the moment they most need to communicate. *[v2 — "BitChat" capitalisation corrected.]*

**Proposed Solution:**
A mesh-network mobile app that lets rural communities coordinate disaster response entirely offline, using phone-to-phone communication (Bluetooth LE / Wi-Fi Direct) — no internet, no cell towers, no power grid.

Two roles: General Users (community members) and Volunteers (NGO/authority members verified during a pre-disaster offline-readiness campaign). Both share one map with two views — an Emergency layer for SOS and hazard reports, and a Resource layer for food, shelter, medical aid, and equipment.

Three core actions: **Rescue** lets a user raise a location-tagged SOS — for themselves, for their group, or **on behalf of a neighbour whose phone is dead or lost** — which floods hop-by-hop across nearby phones, routed toward Volunteers. Rescues close via a signed QR handshake at physical contact, proving the responder and the person were actually together, with no photos or connectivity needed. **Report** lets anyone flag hazards like floods or blocked roads, grouped by location and shown with a rising confirmation count. **Contribute** lets Volunteers pin available resources with live counts.

Because there is no server to check claims, all three share a corroboration-based trust engine: claims gain trust only when physically-distinct devices independently report or deliberately attest to the same thing — never merely by being relayed — and fade if unconfirmed. Emergency claims are the one exception: **an SOS never fades and is never merged with another person's**, because the person with no one nearby to confirm them is the person who needs help most.

**Innovation & Impact:**
Unlike general-purpose offline messengers, this is purpose-built for disaster response: location-tagged SOS, verified rescue coordination, and a live offline resource map working as one system. The key innovation is a corroboration-based trust engine — with no central server or AI model possible offline, trust emerges from independent confirmation by physically-distinct devices, weighted by radio-path evidence rather than raw identity counts, with Volunteer nodes weighted higher. This turns the absence of infrastructure from a limitation into a design principle.

Rural households sharing a single smartphone gain a functioning emergency coordination system when cell towers, internet, and power fail simultaneously — exactly when systems like Cell Broadcast are least reliable. Beyond rescue, the same mesh supports resource-sharing through the recovery phase.

**Implementation — Hardware/Software Stack:**
Cross-platform mobile app (React Native or Flutter), Android-first for rural device compatibility. Hybrid BLE + Wi-Fi Direct transport: BLE for low-power discovery and small-message relay, Wi-Fi Direct for occasional higher-bandwidth close-range transfer. Offline maps from pre-bundled OpenStreetMap tiles rendered with MapLibre GL. On-device SQLite storing signed Claim objects and trust state. Ed25519 signatures for message authenticity, with claims deliberately readable by relays so corroboration can work. Add-only CRDT counters for the shared resource ledger. Logical clocks plus mesh time gossip in place of network time sync.

No hardware beyond standard smartphones and no backend infrastructure — deliberately, keeping the system fully self-contained with zero additional infrastructure cost.

---

## 11. Sources Referenced

- ETL Systems, *Global Connectivity Divide 2025* — internet penetration and disaster vulnerability context. **[v2 — verify before submission: ETL Systems is a satellite RF hardware manufacturer, an unusual publisher for this report type. Confirm the citation and attribution are correct.]**
- Business Standard, *Strengthening preparedness: New disaster warning system will protect lives* — Cell Broadcast reliance on cellular infrastructure.
- ScienceDirect, *Community vulnerability to cyclones: empirical evidence from rural India* — telecom failure during disaster events.
- CEDA (Ashoka University), *One Nation, Many Disconnects: Mapping India's Home Internet Gaps* — 3.8% rural connectivity figure. **[v2 — this is the load-bearing statistic in §10; confirm against the primary source.]**
