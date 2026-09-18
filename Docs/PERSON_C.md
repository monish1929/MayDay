# PERSON_C.md — App Shell, Map & UI

**Owner:** C
**Branch prefix:** `c/`
**Primary folder:** `lib/ui/`
**Reviews my PRs:** A or B (whoever's area my change touches)
**I review:** the `ab/` pairing branch in Phase 2, and flow PRs

Read `CLAUDE.md` and `CLAIM_SCHEMA.md` first. This is my task list and progress log — tick boxes as I go, keep the log at the bottom current.

---

## 1. What I own

Everything the user actually sees and touches.

- Entry screen, navigation, app shell
- The offline map (MapLibre GL + pre-bundled `.mbtiles`)
- Layer toggle: Emergency layer / Resource layer
- Bottom sheet with Rescue / Report / Contribute
- Pin rendering — icons and states per claim type and trust tier
- Volunteer ops screen: rescue queue, report review, resource coordination
- Later: the Contribute flow, QR scanner UI, volunteer identity screens

**What I don't own:** how trust is computed, how claims are identified, how bytes move between phones. My layer **reads** from B's data layer and renders it.

---

## 2. The one rule for my layer

**No business logic in widgets.**

The UI never computes trust, never decides decay, never generates a claim ID, never decrements a resource count. It asks the data layer and renders the answer.

Why this matters more than usual: the invariants in `CLAUDE.md` §2 exist because v1 got them wrong in ways that could cost someone a rescue. If trust logic gets duplicated into a widget, there are now two implementations and only one is tested. When I need a number the data layer doesn't give me, the fix is to **ask B for it** — not to compute it in the view.

**Who actually uses this:** rural families sharing one smartphone, during a disaster, possibly at night, possibly panicking, with varying literacy. Icon-first over text. This constraint should drive most of my design calls.

---

# WEEK 1 — APP SHELL WITH MOCK DATA

I don't wait on anyone. I fake the shape of a Claim and build against it; B's real store arrives week 2.

### Day 1 — Shell and navigation
- [✓] Flutter project structure per `CLAUDE.md` §5.1
- [✓] Entry screen: **User** / **Volunteer**
- [✓] Navigation scaffold, route definitions
- [✓] A `MockClaim` class matching `CLAIM_SCHEMA.md` §1 **field-for-field** — same names, same enums

**Use the real field names from day one.** If I invent `urgency` where the schema says `dispatchPriority`, next week's swap becomes a rename job instead of a plug-in.

### Day 2 — The map
- [✓] MapLibre GL integrated
- [✓] One small `.mbtiles` bundled as a placeholder
- [✓] Map renders fully offline — **test with the device in airplane mode**
- [✓] Pan, zoom, sensible initial position

**Airplane mode is the real test.** It's easy to ship a map that quietly fetches tiles from the network in dev and fails silently in the field.

#### Day 2 notes — tile serving architecture

- MapLibre GL (`maplibre_gl ^0.26.2`) can't read tiles directly from a `.mbtiles` SQLite file via `file://` — it expects a real directory of `{z}/{x}/{y}.png` files or a URL. Implemented a lightweight local `HttpServer` (bound strictly to `127.0.0.1`, dynamic port, never `0.0.0.0` — `CLAUDE.md` §1) in `offline_map_manager.dart` that queries the `.mbtiles` database directly per tile request and serves the PNG bytes over `http://127.0.0.1:<port>/{z}/{x}/{y}.png`. MBTiles uses TMS tiling (y-axis inverted from XYZ) — conversion is `tmsY = (2^z - 1 - y)`.
- Added `sqlite3` + `sqlite3_flutter_libs` as dependencies — `sqlite3` alone throws a `dlopen` failure on Android without `sqlite3_flutter_libs`, which bundles the native `libsqlite3.so`.
- Added a scoped Android `network_security_config.xml` permitting cleartext HTTP only for `127.0.0.1`/`localhost`, instead of the app-wide `usesCleartextTraffic` flag, to keep the "no network path" invariant (`CLAUDE.md` §1) as tight as possible.
- Known gotcha: MapLibre Native's Android SDK checks `ConnectivityManager` before attempting ANY HTTP request, including to `127.0.0.1` — so real airplane mode silently blocks all tile requests (zero requests reach the local server, no error, map just stays visually static) unless `MapLibre.setConnected(true)` is called at startup. This required a native Kotlin change in `MainActivity.kt` (calling `MapLibre.getInstance(this)` and `MapLibre.setConnected(true)` in `onCreate`) plus adding `org.maplibre.gl:android-sdk-opengl:13.3.0` directly to `android/app/build.gradle.kts`. Without this override, the app *looks* like it's working offline in normal testing but silently fails to load any tile the moment real airplane mode is on — worth flagging to A given the mesh work will face similar connectivity-detection questions on Android.
- Current placeholder `.mbtiles` (~1.1MB, Bengaluru area, zoom 8-14) is schema-valid with real tile data, but the tiles themselves are flat placeholder colors (cream land / blue-gray border), not real map imagery — swapping in a real district's tiles is still the open question tracked below.
- Added a temporary debug overlay (tile load/fail counter, top-left of map) to `OfflineMapManager` + `MainScreen` for verifying tile serving without needing Logcat. Marked as removable — flag for cleanup before Day 3 sign-off if not needed further.

### Day 3 — Bottom sheet and forms
- [✓] Three actions: **Rescue**, **Report**, **Contribute**
- [✓] Rescue form: type selector (Individual / Group / **Proxy**), headcount bucket, optional proxy note (80 char cap)
- [✓] Report form: hazard kind, optional note (80 char cap)
- [✓] Contribute form: resource category (canonical four), pledged count
- [✓] Forms print to console for now

The 80-char caps aren't stylistic — a claim must fit in one BLE write (~400 byte envelope), and free text is the biggest variable contributor.

**Don't forget Proxy SOS.** It's the case where someone raises an alarm for a neighbour whose phone is dead. Our own research says rural families typically share one phone, so the person needing rescue often isn't the one holding a device. Easy to leave out because it wasn't in v1.

### Day 4 — Pins and layers
- [✓] Layer toggle: **Emergency** (SOS + hazard) / **Resource**
- [✓] Distinct icons: SOS, Proxy SOS, hazard, each resource category
- [✓] Trust tier changes appearance — unconfirmed faint, corroborated full opacity, groundConfirmed distinct
- [✓] Hazard pins show a confirmation count ("12 reports")
- [ ] Resource pins show availability as a **range** when uncertain ("2–6 packets") — **deferred**: requires B's replica-conflict data (CLAIM_SCHEMA.md §8.1), not available in Week 1 mock data. Showing single available count for now.
- [✓] SOS pins cluster visually at low zoom ("3 SOS here") — **display only, records stay separate**
- [✓] An aging unresolved SOS renders with **more** visual urgency, not less

Two things easy to get backwards:
- **Relative time only.** "About 2 hours ago" — never a precise timestamp. Devices can't sync clocks, so precision would be a fabrication.
- **Aging SOS gets louder.** The instinct is to fade old pins. Here that's exactly wrong.

### Day 5 — Volunteer ops screen
- [✓] Rescue queue sorted by `dispatchPriority` then trust
- [✓] Report review list
- [✓] Resource coordination view
- [✓] QR scanner skeleton (camera permission, viewfinder — no verification logic yet)
- [✓] All on mock data

**Exit criteria:** a fully clickable app that looks like the real thing, running on mock data, ready to have B's store dropped in underneath.

**Sync — what I bring:** any field I needed that isn't in the schema (better to catch a gap now than after B builds against it), and a rough `.mbtiles` size for one district, since it feeds the storage budget and the "tiles evicted before SOS records" rule.

#### Week 1 sync findings

- [ ] Any field I needed that isn't in `CLAIM_SCHEMA.md` — better to catch a gap now than after B has built against it
  - §8 doesn't list `proxyNote` (SosProxyPayload) or `note` (HazardReportPayload), but §9.2 references both as capped free-text fields. Built against §9.2 as the more specific source. Needs §8 updated to match, per §12.
  - §1's Claim pseudocode types `resolvedAtLogical`/`createdAtLogical`/`lastConfirmedAtLogical`/`archivedAtLogical` as `DateTime?` and `displayLifetime` as non-nullable `Duration`, but §4 and §10.1 require `LogicalClock`-typed and nullable respectively. Built to §4/§10.1. Worth confirming with B before they build the real Claim class.
- [ ] Rough `.mbtiles` size for one district, since it feeds the storage budget in `CLAIM_SCHEMA.md` §10.2 and the "map tiles get evicted before SOS records" rule

---

# WEEK 2 — SWAP MOCKS FOR REAL DATA

A and B pair on the transport↔data seam (`ab/`). **I work solo** against B's Phase 1 store, which already works standalone — so I'm not blocked on their pairing.

### Day 1 — Wire in the real Claim
- [✓] Delete `MockClaim`, import B's `Claim`
- [✓] Fix every field mismatch (this is the payment for using real names in week 1)
- [✓] Forms write real claims through B's layer instead of printing
- [✓] Confirm claim creation actually persists to SQLite — kill the app, reopen, it's still there

### Day 2 — Reactive map rendering
- [✓] Bind the map to B's `watchActiveClaims()` stream
- [✓] A claim arriving updates the map **without** a manual refresh
- [✓] Layer filter works against real query results
- [✓] Pins update in place when trust tier changes, rather than flickering out and back
- [✓] Test with 100+ claims — does rendering stay smooth?

### Day 3 — Volunteer queue and resource display
- [✓] Rescue queue reads real `dispatchPriority`, sorted with B's helper
- [✓] Availability read from `availableFor()` — **never cached in widget state and mutated locally**
- [ ] Resource range rendering when replicas disagree — still blocked, see notes
- [✓] Relative-time display using B's logical-clock helper
- [ ] Volunteer gating: Contribute pledge hidden for `unverified` and `vouchedProvisional` nodes — still blocked, see notes

### Day 4 — Three-way integration test
All three of us. The real end-to-end question: **can my UI display a claim that originated on a different phone and arrived over A's mesh?**
- [✓] Claim raised on phone 1 appears on phone 2's map
- [✓] Trust tier change on one device reflects on the other
- [✓] **Two SOS in the same geohash bucket render as two pins, not one**

That last one is the visual proof of the most important bug we fixed. Worth checking with my own eyes rather than trusting the test suite.

#### Day 4 notes — three-way integration test

- Ran on 3 physical devices against reconciled `ab/transport-data-wiring` 
  code (commit `7976db9`), after resolving an earlier accidental commit of 
  A/B's files into `c/app-shell` — see progress log note below.
- Used `DebugSosTrigger.testLocation` to raise claims, not the live forms, 
  per A's guidance — this gives deterministic location control for the 
  same-geohash-bucket test.
- Trust tier check required all 3 devices: with only 2 corroborating, the 
  claim correctly stayed UNCONFIRMED (B's threshold is 2.0 against a 1.0 
  per-device cap) — this is expected trust-engine behavior, not a bug, and 
  worth remembering if this test is repeated with fewer than 3 devices.
- Same-bucket SOS test: two SOS raised from two devices in the same 
  geohash bucket rendered as two distinct pins. Resolving one left the 
  second untouched and ACTIVE — visual confirmation of CLAIM_SCHEMA.md §2's 
  core invariant.

### Day 5 — Empty, loading, and error states
- [✓] Empty map (no claims yet) — what does a user see? Not a spinner.
- [✓] Store still loading on cold start
- [✓] Location permission denied → can the user still see the map and place a pin manually?
- [✓] GPS unavailable indoors → manual location placement path
- [✓] **No state anywhere implies connectivity.** No "syncing", no offline banner, no retry spinner.
- [✓] Silent submission failures now surface to the user instead of freezing the form
- [✓] Real GPS location handling (with manual map-tap fallback) implemented for Rescue form

That last one is the invariant I'm most likely to violate by habit, since almost every app I've built has an online state to indicate.

#### Day 5 notes

- **Connectivity-implication audit**: full pass over all 14 files in lib/ui/. 
  No RefreshIndicator, no connectivity icons, no misleading network-implying 
  spinners found. One CircularProgressIndicator confirmed local-only (map 
  init from bundled assets). Found 3 wording issues in rescue_form_sheet.dart 
  implying active BLE transmission on submit ("broadcast signal," "Broadcast 
  … to nearby devices," button labeled "Broadcast"), when submission only 
  persists to local SQLite. Fixed: reworded to describe local recording + 
  opportunistic mesh propagation ("recorded... reaches nearby phones as they 
  come into range"). report_form_sheet.dart and contribute_form_sheet.dart 
  already used neutral wording, unchanged. entry_screen.dart's "Offline 
  Disaster Response" title reviewed and kept as an accurate product 
  description, not a live status claim.
- **Silent failure bug found during testing**: after reconciling with 
  ab/transport-data-wiring (7976db9), all three forms began failing silently 
  on submit — B's new signature-length guard in ClaimRepository.insertClaim 
  correctly rejects claims from ClaimFactory, which still sets 
  originSignature: Uint8List(0) pending real signing (Phase 4). The forms 
  had no error handling, so the rejection was invisible — form just sat 
  unresponsive. Added try/catch around _submitForm() in all three forms; 
  failures now show a SnackBar ("Couldn't save — please try again") and the 
  form stays open for retry. Underlying signing gap remains open — flagged 
  to A/B, tracked in open questions below, not a Day 5 blocker since 
  remaining Day 5 items don't depend on claim persistence.
- **Cold-start loading**: confirmed via on-device testing (fresh install, 
  data cleared) — brief spinner shows during _initializeMap(), resolves 
  cleanly into the map with zero claims, no hang.
- **Empty map state**: confirmed clean — zero claims renders a plain map, 
  no stuck spinner, no error state.
- **Location handling was previously hardcoded**: discovered while testing 
  the permission-denied case — RescueFormSheet had no real GPS/permission 
  handling at all; every claim silently used a hardcoded Bengaluru 
  coordinate (GeoPoint(lat: 12.9716, lon: 77.5946)) regardless of device 
  location. Fixed for RescueFormSheet only (Report/Contribute still 
  hardcoded, tracked in open questions): added geolocator dependency, real 
  permission + GPS fetch with a 4-second timeout, a visible status indicator 
  (Acquiring GPS / Using your current location / Using pinned map location / 
  GPS unavailable — tap to set on map), and a full manual fallback loop in 
  MainScreen (tap red box → banner prompts map tap → tap map → form reopens 
  with the picked coordinate, cancel via X supported). Tested on-device: 
  permission-denied path confirmed working end-to-end (screenshots on file); 
  GPS-timeout path also confirmed working — first form open got a fast GPS 
  fix (green success state), second open on the same indoor spot correctly 
  timed out into the red fallback after ~4s, no hang. The old hardcoded 
  value is retained only as an absolute last-resort fallback if submission 
  is somehow attempted with no location at all, now loudly logged rather 
  than silent.

**Exit criteria:** the app runs entirely on real data from B's store and renders claims that arrived over A's mesh.

---

# WEEK 3 — PHASE 3: CONTRIBUTE FLOW

A takes Rescue, B takes Report, I take Contribute — I already know the UI shell best and this mostly needs volunteer-gating logic layered in.

### Day 1 — Pledging a resource
- [✓] Full flow: volunteer pins a resource with category and count
- [✓] Gated on `NodeTrust` — general users and provisional volunteers cannot pledge — **placeholder gate via widget.isVolunteer, confirmed working both directions on-device (blocked message for general users, full form for volunteers)**
- [✓] Location picker: current GPS or manual map placement — **built during Wk2 D5, confirmed working for Contribute specifically**
- [✓] Pledge writes through B's layer and propagates via A's mesh — **ContributeOrigination handles real signing and storage; known gap: pledgedCount accumulation needs insertOrMerge logic (see open questions)**
- [✓] Appears on other devices' resource layer — **ContributeOrigination handles sign-and-flood**

### Day 2 — Claiming and the soft signal
- [✓] Any user can report a resource as running low (increments `claimedReports`) — **UI built and tested; actual increment to claimedReports still local/scaffolded (not yet built)**
- [✓] **This is a soft signal, visually distinct from the authoritative count** — "reportedly running low," not a hard number — confirmed on-device with real seeded resource claims
- [✓] Rate-limited per device; UI communicates the limit without scolding — **local session-counter scaffolding only (3-tap limit), not real per-device enforcement (not yet built)**
- [✓] Availability updates as a computed value, never optimistically mutated locally — explicitly audited, confirmed the local "running low" counter is structurally isolated from the authoritative pledgedCount, never added/subtracted
- [✓] Volunteer-only "reset count" action for someone physically on site — gated on widget.isVolunteer placeholder, confirmation dialog before reset, confirmed on-device

#### Week 3, Day 1-2 notes

- **Resource seeding blocker discovered and fixed**: testing Day 2's visual 
  states required a real resource claim, but DebugClaimSeeder was silently 
  crashing on its first seed attempt — it called the standard 
  ClaimFactory.createClaim() → ClaimRepository.insertClaim() path and hit 
  the same UnsignedClaimException guard as the real forms, aborting the 
  entire 120-claim seed with zero claims actually inserted (no try/catch in 
  the loop). Fixed: seeder now uses a raw SQL insert, clearly marked 
  // DEBUG ONLY, bypassing ClaimFactory/insertClaim entirely for synthetic 
  test data only — does not touch or weaken B's real signature guard for 
  any production code path. Seeder now also guarantees a portion of seeded 
  claims are RESOURCE type with nonzero pledged counts, located within the 
  bundled placeholder .mbtiles area.
- **NodeTrust gating pattern**: reused the same widget.isVolunteer 
  placeholder approach across Contribute pledging, the resource "reset 
  count" action, and (already existing) volunteer ops screen — consistent 
  pattern ready to swap to real NodeTrust once B's Phase 4 identity work 
  lands.
- **What's real vs. scaffolded in Day 2**: the visual distinction (green 
  authoritative card vs. amber "reportedly running low" indicator), the 
  rate-limit UI behavior, the reset confirmation dialog, and the 
  volunteer-only gating are all real, tested UI logic. The underlying 
  counters (_localRunningLowReports, _localSessionTaps) are ephemeral — 
  reset on sheet close/app restart — since they're not yet wired to B's 
  real claimedReports field or B's real per-device rate limiting. Both are 
  marked with explicit TODO comments pointing to the real fields.
- **Branch note**: Recent work (Week 3 Days 1-5) was done on `ac/app-shell-transport-merge`, not `c/app-shell` directly, since that's where the working ContributeOrigination/MeshBootstrap dependencies resolve. `c/app-shell` itself still needs this branch merged back in eventually.

### Day 3 — Uncertainty and staleness
- [ ] Range rendering ("2–6 packets") when replicas disagree — **blocked on data layer (no replica tracking exists)**
- [✓] A resource with `available == 0` is visually distinct but **not hidden** — "Out, was here now empty" state implemented on map pin and detail sheet
- [ ] Stale resource pins fade as they approach their decay window — **blocked on data layer (MeshTimeGossip.estimateDisplayTime() throws UnimplementedError)**
- [ ] Last-confirmed relative time on the detail view — **blocked on data layer (same UnimplementedError)**
- [✓] Volunteer ground-confirmation makes a pin visually authoritative — **ground-confirmation styling implemented in detail sheet**

### Day 4 — Resource layer polish
- [✓] Category filter within the resource layer — **category filter chips built on map resource layer**
- [✓] Clustering for dense resource areas (a relief camp with many pins) — **already covered resource pins, no changes needed**
- [✓] Detail sheet: category, availability, confidence, last confirmed, who pledged — **category/availability/confidence built. "last confirmed" and "who pledged" blocked on data layer.**
- [ ] Sort/filter by nearest — **deferred: needs design decision on GPS tracking mode (one-shot fetch vs. continuous myLocationEnabled)**
- [✓] Empty state: no resources known nearby — **empty state overlay added for resource layer**

### Day 5 — Rescue and Report UI support
A and B own those flows' logic; I own how they look.
- [✓] SOS detail sheet: type, headcount, trust, dispatch state, relative time — **confirmed already built and working**
- [✓] Proxy SOS visually distinct from self-raised, legible at a glance — **confirmed already built**
- [✓] Hazard detail sheet with confirmation count and attest button — **confirmation count already built. Attest button blocked on data layer (pending firstSeenVia decision).**
- [ ] "I can see this too" attestation button wired to B's explicit-attestation path — **deliberately not built, pending firstSeenVia decision from B (see open questions)**
- [ ] Volunteer actions: mark seen, mark en route, ground confirm — **deferred: data layer lacks clean wrapper methods for seen/en route, flagged for B**

**Exit criteria:** all three flows are fully usable end to end from the UI, with volunteer gating and uncertainty rendered honestly.

---

# WEEK 4 — PHASE 4: IDENTITY UI, QR, ACCESSIBILITY

Phase 4 splits three ways. **My share: volunteer identity screens and the QR flow.** A does vouch/revocation transport; B does keypairs and node trust.

### Day 1 — Volunteer entry and credential
- [ ] Volunteer entry unlocks the stored credential on-device (biometric or PIN) — **no network step**
- [ ] Never call it a "login." There is no server to log into.
- [ ] Campaign registration screen: generate keypair, display public key for the organiser to sign
- [ ] Phone number field labelled clearly as a **display label**, not a credential
- [ ] Identity screen showing node trust state (verified / provisional / unverified)

### Day 2 — Vouching UI
- [ ] Verified volunteer can vouch for a new person; vouch flows through A's transport
- [ ] Vouch count shown against the cap of 5
- [ ] Provisional volunteers see clearly what they **cannot** do (pledge resources, vouch for others)
- [ ] Promotion on a second independent vouch is visible and understandable
- [ ] Revocation UI, with a confirmation step — it's destructive and can't be undone by the person revoked

**Honest state to surface:** identity does not survive app uninstall (Android deletes Keystore keys). The identity screen should say so plainly rather than let someone discover it during a disaster.

### Day 3 — QR resolution flow
- [ ] Requester side: display QR with `sosId` + **fresh nonce** + signature, generated at display time
- [ ] Nonce regenerates each time the QR is shown — never reused
- [ ] Volunteer side: scan, verify, counter-sign, resolve
- [ ] Success state clear enough to read in bad light with shaking hands
- [ ] Failure states distinguishable: expired nonce, wrong signature, unknown claim
- [ ] Manual fallback for a dead phone, clearly marked as lower confidence

### Day 4 — Low-literacy and accessibility pass
- [ ] Every action reachable by icon alone, no reading required
- [ ] Colour is never the only signal — shape and position carry meaning too
- [ ] Tap targets large enough for panic and cold hands
- [ ] High contrast; readable in bright sun and in darkness
- [ ] Confirmation for anything destructive or irreversible
- [ ] Test with someone who hasn't seen the app — can they raise an SOS without instruction?

That last check is worth more than any amount of internal design review.

### Day 5 — Battery-aware UI
- [ ] Low-power mode indicator — **without implying a connectivity state**
- [ ] Dark-first palette (OLED power saving and night usability both point the same way)
- [ ] Avoid continuous animation and repaint loops
- [ ] Map render cost measured on the cheapest test device
- [ ] Screen-off behaviour: what happens to an active SOS when the phone sleeps?

**Exit criteria:** volunteer identity, vouching, and QR resolution work end to end, and the UI has been tested by someone outside the team.

---

# WEEK 5 — REAL TILES, POLISH, FIELD TESTING

### Day 1 — Real offline map tiles
- [ ] Generate `.mbtiles` for an actual target district at low zoom
  - *Blocked: Generating raster tiles via scraping violates OSM policy. Team decision needed on whether to switch map engine to Vector (MapLibre native + tilemaker) or build a heavy local raster pipeline (openstreetmap-carto + Mapnik).*
- `[x]` Measure real size; feed it into the storage budget with B
  - *Note: Wayanad z8-14 is 6.26MB. Budget updated.*
- [ ] Confirm tile eviction happens **before** active SOS records under pressure
- [ ] Bundle at install; verify a fresh install has working maps with no network
  - *Note: Temporarily reverted to placeholder.mbtiles due to OSM policy violation on the Wayanad tiles.*
- [ ] Decide the district-scoping approach with the team

### Day 2 — Map performance on low-end hardware
- [ ] Profile with 1,000+ claims on the cheapest device
- [ ] Clustering thresholds tuned so pins stay legible without dropping frames
- [ ] Pan/zoom smoothness at realistic claim density
- [ ] Memory footprint with the full tile set loaded
- [ ] Cut render cost wherever it's cheap to do so

### Day 3 — Full-app usability run
- [ ] Every flow end to end on real hardware with real mesh data
- [ ] Someone outside the team attempts each of the three actions unaided
- [ ] Note every hesitation and misread — hesitation is a design bug, not a user error
- [ ] Fix the top three friction points
- [ ] Verify no screen anywhere implies connectivity

### Day 4 — Outdoor field test with A
- [ ] Screen readability in direct sunlight
- [ ] Map usable while walking
- [ ] SOS raised outdoors reaches another device and renders correctly
- [ ] Volunteer queue usable one-handed while moving
- [ ] QR scan works outdoors, in bad light, at awkward angles

### Day 5 — Visual consistency and documentation
- [ ] Icon set finalised and consistent across every surface
- [ ] Colour and typography audit
- [ ] Document the design decisions — especially aging-SOS urgency and range rendering, which look like bugs to anyone who doesn't know why
- [ ] Close or re-scope my open questions below
- [ ] Screenshots for the submission write-up

**Exit criteria:** real district tiles bundled, the app performs on low-end hardware, and a stranger can use it unaided outdoors.

---

# BEYOND WEEK 5 — BACKLOG

- [ ] Multi-language support (Tamil, Hindi, regional languages) — real deployment need
- [ ] Voice prompts for non-readers
- [ ] Larger-text accessibility mode
- [ ] Onboarding/tutorial shown during the pre-disaster campaign, not mid-emergency
- [ ] Map tile management UI (which districts are downloaded, storage used)
- [ ] Volunteer shift/handover view for long response operations
- [ ] Haptic feedback for critical confirmations

---

## Invariants that show up in my layer

Most live in B's code, but these surface in the UI and I can break them from here:

- **Nothing implies connectivity.** No "syncing", no offline banner, no retry spinner, no cloud icons, no pull-to-refresh implying a fetch. There is no online state to contrast with, and a "reconnecting" spinner would be actively misleading to someone waiting for rescue.
- **Availability is computed, never cached.** I display what the data layer gives me and never mutate it optimistically in widget state.
- **General Users can't pledge**, only report a resource as running low. Gate on `NodeTrust`.
- **SOS clustering is display-only.** It must never merge records or resolve more than one claim at a time — that's the exact bug the data layer was fixed to prevent, and I could reintroduce it at the view layer.
- **Relative time only.** Never a precise timestamp.
- **Aging SOS gets more urgent, not faded.**

---

## My PR checklist

Beyond the standard checks in `CLAUDE.md` §4.5:

- [ ] No business logic in widgets — no trust, decay, ID generation, or count arithmetic in the view layer
- [ ] Map tested in **airplane mode**
- [ ] Field names match `CLAIM_SCHEMA.md` exactly — no local renames
- [ ] Nothing in the UI implies connectivity or a sync state
- [ ] Availability read from the data layer, not cached and mutated locally
- [ ] Reviewer named per `CLAUDE.md` §3.3

---

## Progress log

| Date | Week/Day | Branch | What landed | Blocked on / notes |
|---|---|---|---|---|
| 2026-08-18 | Wk1 D1 | c/app-shell | Day 1 complete — entry screen, nav scaffold, routing, MockClaim + supporting models matching CLAIM_SCHEMA.md §1 | Two schema gaps found, see open questions below |
| 2026-08-19 | Wk1 D2 | c/app-shell | Day 2 complete — MapLibre GL integrated via a localhost-only HTTP tile server reading directly from the bundled SQLite .mbtiles (no file:// or remote tile paths); verified working in real airplane mode on-device. | See Day 2 notes above for architecture decisions and gotchas future work should know about. |
| 2026-08-20 | Wk1 D3 | c/app-shell | Day 3 complete — Rescue (Individual/Group/Proxy incl. headcount + 80-char proxy note), Report (hazard kind + 80-char note), Contribute (canonical 4 categories + pledged count) bottom sheet forms built in lib/ui/forms/, wired to main_screen.dart buttons, all submits construct correct payload classes and print to console. Verified via logcat against CLAIM_SCHEMA.md §8 — all enum values, payload field names, and null handling (Individual has no headcount, Proxy headcount/note optional) confirmed correct on-device. | None — ready for Day 4 (pins and layers). |
| 2026-08-20 | Wk1 D4 | c/app-shell | Day 4 complete — Emergency/Resource layer toggle, distinct pin rendering per type/trust/priority, confirmation counts on hazard pins, display-only clustering at low zoom (< 11.5), time-driven aging SOS urgency escalation (pulsing halo & speed scaled across 1hr/3hr/6hr+ tiers). Resource range display deferred to Week 2. | Ready for Day 5 (Volunteer ops screen). |
| 2026-08-20 | Wk1 D4 | c/app-shell | Day 4 on-device verification complete. Found and fixed two bugs post-implementation: (1) pin projection ran on onMapCreated before MapLibre's style/camera was ready, silently dropping all pins on first launch — fixed by moving initial projection to onStyleLoadedCallback plus a bounded single retry, with the previously-silent toScreenLocation failures now logged; (2) toScreenLocation() returns physical device pixels but Positioned expects logical pixels, placing every pin off-screen — fixed by dividing by MediaQuery.devicePixelRatio in _buildPinOverlayWidgets(). Confirmed on-device: all three trust tiers render correctly, aging escalates visibly across tier 1 (sos-002, ~2hr) and tier 3 (sos-003, ~6.5hr), clustering separates into individual pins at high zoom and groups at low zoom with detail sheet showing each claim separately, both Emergency and Resource layers toggle correctly, resource pins show single available count with no fabricated range. | None — Day 4 fully closed. Ready for Day 5. |
| 2026-08-20 | Wk1 D5 | c/app-shell | Day 5 complete — volunteer_ops_screen.dart built with three tabs: rescue queue (sorted by dispatchPriority then claimTrust, older-claim tiebreaker), report review (sorted by confirmationCount descending), resource coordination (category filter across canonical four, showing payload.available with pledged/claimed breakdown, no fabricated range). qr_scanner_screen.dart added as a viewfinder + permission-handling skeleton only, no decode/verification logic, per CLAIM_SCHEMA.md §6.2 Phase 3 scope. Refactored shared relative-time and aging-tier logic (previously duplicated across claim_pin_widget.dart and claim_detail_sheet.dart) into lib/ui/models/claim_display_helpers.dart, now consumed by all three call sites including the new rescue queue. router.dart was touched to register the /qr-scanner route — minimal necessary addition, flagged here since it wasn't in original scope. Verified on-device: rescue queue sort order, report sort order, and resource category filtering all match mock data exactly; all list rows correctly open ClaimDetailSheet. | One open visual bug found during testing — see open questions below. |
| 2026-08-23 | Wk2 D1 | c/app-shell | Day 1 complete — Mock models deleted, real Claim / ClaimPayload / LogicalClock / DatabaseHelper wired. Rescue, Report, Contribute forms assemble real Claims via ClaimFactory and persist to SQLite with explicit `// TODO: SIGNING GAP` comments. Verified on-device (force-stop + relaunch preserves all claims) and in CI via connection-interrupt tests. | Signing gap tracked under open questions. |
| 2026-08-24 | Wk2 D2 | c/app-shell | Day 2 complete — `watchActiveClaims()` stream added to `ClaimRepository`, map bound reactively, `ValueKey`-based flicker-free pin updates, live layer filtering confirmed. On-device testing with 120 seeded claims (via new debug long-press seeder) found two real issues the automated scale test missed: (1) hazard/resource pin cards visually overlapped due to a fixed 45px cluster threshold not accounting for card width, compounded by a physical-vs-logical pixel bug shrinking the effective threshold further on high-density screens; (2) noticeable pan/zoom lag from 120+ sequential `toScreenLocation()` platform-channel calls per camera-idle event. Both fixed: dynamic per-type cluster threshold + logical-pixel correction; `toScreenLocationBatch()` + viewport culling (visible region + 20% margin) replacing the sequential loop. Re-tested on-device: overlap resolved, lag substantially reduced but not fully eliminated at 120-claim density. | Residual minor lag carried forward — see open questions. |
| 2026-09-08 | Wk2 D4 | c/app-shell | Day 4 complete — three-way integration test run on real hardware (3 physical devices) against reconciled ab/transport-data-wiring code (commit 7976db9). All three checks passed: (1) claim raised via DebugSosTrigger on phone 1 appeared on phone 2's map without manual refresh; (2) trust tier flip UNCONFIRMED→CORROBORATED observed correctly once a genuine third device corroborated — confirms B's 2.0 threshold/1.0 per-device cap is working as intended; (3) two SOS raised in the same geohash bucket from two devices rendered as two distinct pins, resolving one left the other untouched and ACTIVE. | None — Day 4 fully closed. Ready for Day 5. |
| 2026-09-08 | Wk2 D5 | c/app-shell | Day 5 complete. Connectivity-implication audit across lib/ui/ — 3 wording fixes in rescue_form_sheet.dart (broadcast/signal language implying immediate transmission, corrected to reflect local persistence + delayed mesh propagation). Found and fixed silent submission failures (UnsignedClaimException from B's new signing guard was freezing forms with no feedback) — added try/catch + SnackBar across all three forms. Confirmed cold-start loading and empty-map states are clean on-device. Built real GPS location handling for RescueFormSheet (geolocator, 4s timeout, visible status states, full manual map-tap fallback loop wired through MainScreen) after discovering the form was previously using a hardcoded Bengaluru coordinate for every claim regardless of device location. Both permission-denied and GPS-timeout paths confirmed working on-device. | Signing gap still blocks claims from actually saving (tracked separately, not a Day 5 blocker). Location handling (real GPS + manual map-tap fallback) has since been ported to Report and Contribute forms as well, using an enum-based FormType routing in MainScreen so the correct form reopens after map-tap placement. Confirmed on-device for both — Day 5 fully closed across all three forms. |
| 2026-09-09 | Wk3 D1-D2 | c/app-shell | Contribute pledge flow (Day 1) and claiming/soft-signal flow (Day 2) built and tested on-device. Day 1: full pledge form flow confirmed, NodeTrust placeholder gating confirmed both directions, location picker (built Wk2 D5) confirmed working for Contribute. Day 2: visual distinction between authoritative pledged count and soft "reportedly running low" signal confirmed against real seeded data; local rate-limit UI (3-tap session cap), volunteer-only reset action (with confirmation dialog), and computed-availability isolation all confirmed on-device. Found and fixed DebugClaimSeeder silently crashing on the same signature guard as the real forms — fixed via a debug-only raw SQL insert bypass, seeder now reliably produces test resource claims. | Day 2 persistence items not yet built. |
| 2026-09-17 | Wk3 D1 | ac/app-shell-transport-merge | E2E ContributeOrigination built and wired: signing works (keypair/signature/envelope_signer/mesh_node.originate all real), claims now go through real sign-and-flood. (Commits e2cf5f9, 8b1150e) | pledgedCount accumulation gap flagged. |
| 2026-09-17 | Wk3 D3 | ac/app-shell-transport-merge | Resource display fixes: available==0 shown as "Out, was here now empty" (pin and detail sheet); ground-confirmation styling in detail sheet. Caught and fixed a regression where authoritative pledgedCount was incorrectly derived from local UI state (effectiveAvailable) rather than the real payload. (Commit bbdac8a) | Range rendering and staleness blocked on data layer. |
| 2026-09-17 | Wk3 D4 | ac/app-shell-transport-merge | Resource layer polish: category filter chips added to map resource layer; empty state overlay added when no resources match. (Commit 8363041) | Nearest sorting deferred. "Who pledged" and "last confirmed" blocked on data layer. |
| 2026-09-17 | Wk3 D5 | ac/app-shell-transport-merge | SOS and Hazard UI investigation: confirmed SOS detail sheet fields, relative time, Proxy SOS visual distinction, and hazard confirmation count are all already built and working. | Attestation button deliberately stopped pending firstSeenVia decision. |

### Open questions I'm carrying

- [ ] Which district's `.mbtiles` to bundle for real — Wk5 D1
- [ ] Icon set for low-literacy users — field validation is a known open question, not mine alone to settle
- [ ] How to visually distinguish Proxy SOS from self-raised at a glance — Wk3 D5
- [ ] Rendering "2–6 packets" uncertainty without it reading as a bug — Wk3 D3
- [ ] Resource availability range ('2–6 packets') needs real replica-conflict data from B's store (CLAIM_SCHEMA.md §8.1) — not implementable against Week 1 mock data. Deferred to Week 2.
- [ ] Screen-off behaviour with an active SOS — Wk4 D5, needs A's input
- [ ] Multi-language: MVP scope or backlog? — team call
- [ ] §8 doesn't list `proxyNote` (SosProxyPayload) or `note` (HazardReportPayload), but §9.2 references both as capped free-text fields. Built against §9.2 as the more specific source. Needs §8 updated to match, per §12.
- [ ] §1's Claim pseudocode types `resolvedAtLogical`/`createdAtLogical`/`lastConfirmedAtLogical`/`archivedAtLogical` as `DateTime?` and `displayLifetime` as non-nullable `Duration`, but §4 and §10.1 require `LogicalClock`-typed and nullable respectively. Built to §4/§10.1. Worth confirming with B before they build the real Claim class.
- `[ ]` Aging rescue queue cards show a stray diagonal yellow/black hazard-stripe element with rotated, clipped text on the right edge.
  - *Resolved*: (Update: The original diagnosis of "stray widget" was wrong. It is Flutter's RenderFlex overflow indicator caused by fixed 48x48 constraints on wide pill cards. Reverted to open until verified on-device).
- [ ] **Signing gap resolved:** Signing works (`keypair`, `signature`, `envelope_signer`, `mesh_node.originate` all real). `ContributeOrigination` exists and is wired into `contribute_form_sheet.dart`, and claims now go through real sign-and-flood instead of the placeholder unsigned path.
- [ ] **Pending decision (A/B): pledgedCount accumulation.** `insertClaim` does an unconditional `ConflictAlgorithm.replace`. No add-only merge logic exists for resource pledges from different devices in the same geohash bucket. A recommended a separate `insertOrMergeResourceClaim` method, which is verified as the right approach but not applied yet.
- [ ] **Pending decision (A/B): Range rendering.** Schema §8.1 requires showing uncertain ranges ("2-6 packets"). Blocked on the same root cause as above — no replica tracking exists in the data layer.
- [ ] **Pending decision (A/B): pledgedBy/contributor attribution.** No field exists on `ResourcePayload` for who pledged; only `originDeviceId` (a hash) is available.
- [ ] **Pending decision (A/B): firstSeenVia semantics for explicit attestation.** No code path determines whether a local device's knowledge of a claim came via mesh relay when a user taps "I can see this too". The only existing `firstSeenVia: null` assignment is in `claim_ingestion.dart` for a different case (auto-corroboration of a claim's own author). Building the attestation button was deliberately stopped, as guessing this logic risks violating schema §3.2's anti-echo rule.
- [ ] Residual minor lag remains with 120+ densely clustered claims even after batched projection (`toScreenLocationBatch`) + viewport culling. Not blocking — Day 2's smoothness bar is met for realistic near-term density — but carrying forward to Wk5 D2 (dedicated map performance / 1,000+ claim profiling) rather than treating as fully closed. Also worth revisiting there: hazard/resource pin half-extents (60px/55px) used for the cluster threshold are hand-estimated, not measured from actual rendered widget size — could drift if text scale/accessibility settings change card width.
- [ ] Note for history: c/app-shell briefly carried accidentally-committed copies of lib/data, lib/mesh, lib/identity (from a `git add -A` scoping mistake) between commits `38de94d` and `7976db9`. Reconciled against `origin/ab/transport-data-wiring` before Day 4 testing began, so Day 4 results are against A/B's real code, not stale local copies. Flagging here so the commit history isn't confusing to anyone reading it later.
- [ ] The location-fetching logic, state, and indicator UI are now ~150 lines of identical duplicated code across RescueFormSheet, ReportFormSheet, and ContributeFormSheet. Flagged by the agent as worth extracting into a shared widget/mixin. Deliberately deferred — verified all three forms work correctly first (confirmed on-device), refactor later rather than compounding an untested change on top of another.
- [ ] 4-second GPS timeout in RescueFormSheet's location fetch may need tuning — indoor GPS sometimes needs longer than 4s to lock (observed inconsistent success/timeout on consecutive opens from the same indoor spot). Not broken, just worth revisiting the exact threshold later.
- [ ] DebugClaimSeeder previously silently failed (0 claims inserted, no error surfaced) due to hitting the same signature guard as production forms. Fixed via debug-only raw SQL bypass — flagging as a reminder that any future debug/test utility touching ClaimRepository needs the same consideration until real signing exists.

### Screens status

| Screen | Mock | Real data | Polished | Notes |
|---|---|---|---|---|
| Entry | ✓ | ☐ | ☐ | |
| Map + layers | ✓ | ✓ | ☐ | Live stream reactive rendering wired via watchActiveClaims(), tested with 120+ claims. |
| Bottom sheet | ✓ | ✓ | ☐ | |
| Rescue form | ✓ | ✓ | ☐ | Writes to SQLite via ClaimFactory + ClaimRepository with signing gap comment. |
| Report form | ✓ | ✓ | ☐ | Writes to SQLite via ClaimFactory + ClaimRepository with signing gap comment. |
| Contribute form | ✓ | ✓ | ☐ | Writes through ContributeOrigination — real signing, sign-and-flood, stored via insertClaim (pledgedCount accumulation gap noted separately). |
| SOS detail sheet | ✓ | ✓ | ☐ | Real data fields and Proxy distinctness confirmed built. |
| Hazard detail sheet | ✓ | ✓ | ☐ | Confirmation count confirmed built. |
| Resource detail sheet | ✓ | ✓ | ☐ | Added ground-confirmed banner and out-of-stock ("Out") state. |
| Volunteer queue | ✓ | ☐ | ☐ | incl. rescue/report/resource tabs |
| QR display (requester) | ☐ | ☐ | ☐ | fresh nonce each show |
| QR scanner (volunteer) | ✓ | ☐ | ☐ | skeleton only — logic in Phase 3 |
| Volunteer identity | ☐ | ☐ | ☐ | |
| Vouching | ☐ | ☐ | ☐ | |
