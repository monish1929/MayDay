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
- [ ] Flutter project structure per `CLAUDE.md` §5.1
- [ ] Entry screen: **User** / **Volunteer**
- [ ] Navigation scaffold, route definitions
- [ ] A `MockClaim` class matching `CLAIM_SCHEMA.md` §1 **field-for-field** — same names, same enums

**Use the real field names from day one.** If I invent `urgency` where the schema says `dispatchPriority`, next week's swap becomes a rename job instead of a plug-in.

### Day 2 — The map
- [ ] MapLibre GL integrated
- [ ] One small `.mbtiles` bundled as a placeholder
- [ ] Map renders fully offline — **test with the device in airplane mode**
- [ ] Pan, zoom, sensible initial position

**Airplane mode is the real test.** It's easy to ship a map that quietly fetches tiles from the network in dev and fails silently in the field.

### Day 3 — Bottom sheet and forms
- [ ] Three actions: **Rescue**, **Report**, **Contribute**
- [ ] Rescue form: type selector (Individual / Group / **Proxy**), headcount bucket, optional proxy note (80 char cap)
- [ ] Report form: hazard kind, optional note (80 char cap)
- [ ] Contribute form: resource category (canonical four), pledged count
- [ ] Forms print to console for now

The 80-char caps aren't stylistic — a claim must fit in one BLE write (~400 byte envelope), and free text is the biggest variable contributor.

**Don't forget Proxy SOS.** It's the case where someone raises an alarm for a neighbour whose phone is dead. Our own research says rural families typically share one phone, so the person needing rescue often isn't the one holding a device. Easy to leave out because it wasn't in v1.

### Day 4 — Pins and layers
- [ ] Layer toggle: **Emergency** (SOS + hazard) / **Resource**
- [ ] Distinct icons: SOS, Proxy SOS, hazard, each resource category
- [ ] Trust tier changes appearance — unconfirmed faint, corroborated full opacity, groundConfirmed distinct
- [ ] Hazard pins show a confirmation count ("12 reports")
- [ ] Resource pins show availability as a **range** when uncertain ("2–6 packets")
- [ ] SOS pins cluster visually at low zoom ("3 SOS here") — **display only, records stay separate**
- [ ] An aging unresolved SOS renders with **more** visual urgency, not less

Two things easy to get backwards:
- **Relative time only.** "About 2 hours ago" — never a precise timestamp. Devices can't sync clocks, so precision would be a fabrication.
- **Aging SOS gets louder.** The instinct is to fade old pins. Here that's exactly wrong.

### Day 5 — Volunteer ops screen
- [ ] Rescue queue sorted by `dispatchPriority` then trust
- [ ] Report review list
- [ ] Resource coordination view
- [ ] QR scanner skeleton (camera permission, viewfinder — no verification logic yet)
- [ ] All on mock data

**Exit criteria:** a fully clickable app that looks like the real thing, running on mock data, ready to have B's store dropped in underneath.

**Sync — what I bring:** any field I needed that isn't in the schema (better to catch a gap now than after B builds against it), and a rough `.mbtiles` size for one district, since it feeds the storage budget and the "tiles evicted before SOS records" rule.

---

# WEEK 2 — SWAP MOCKS FOR REAL DATA

A and B pair on the transport↔data seam (`ab/`). **I work solo** against B's Phase 1 store, which already works standalone — so I'm not blocked on their pairing.

### Day 1 — Wire in the real Claim
- [ ] Delete `MockClaim`, import B's `Claim`
- [ ] Fix every field mismatch (this is the payment for using real names in week 1)
- [ ] Forms write real claims through B's layer instead of printing
- [ ] Confirm claim creation actually persists to SQLite — kill the app, reopen, it's still there

### Day 2 — Reactive map rendering
- [ ] Bind the map to B's `watchActiveClaims()` stream
- [ ] A claim arriving updates the map **without** a manual refresh
- [ ] Layer filter works against real query results
- [ ] Pins update in place when trust tier changes, rather than flickering out and back
- [ ] Test with 100+ claims — does rendering stay smooth?

### Day 3 — Volunteer queue and resource display
- [ ] Rescue queue reads real `dispatchPriority`, sorted with B's helper
- [ ] Availability read from `availableFor()` — **never cached in widget state and mutated locally**
- [ ] Resource range rendering when replicas disagree
- [ ] Relative-time display using B's logical-clock helper
- [ ] Volunteer gating: Contribute pledge hidden for `unverified` and `vouchedProvisional` nodes

### Day 4 — Three-way integration test
All three of us. The real end-to-end question: **can my UI display a claim that originated on a different phone and arrived over A's mesh?**
- [ ] Claim raised on phone 1 appears on phone 2's map
- [ ] Trust tier change on one device reflects on the other
- [ ] **Two SOS in the same geohash bucket render as two pins, not one**

That last one is the visual proof of the most important bug we fixed. Worth checking with my own eyes rather than trusting the test suite.

### Day 5 — Empty, loading, and error states
- [ ] Empty map (no claims yet) — what does a user see? Not a spinner.
- [ ] Store still loading on cold start
- [ ] Location permission denied → can the user still see the map and place a pin manually?
- [ ] GPS unavailable indoors → manual location placement path
- [ ] **No state anywhere implies connectivity.** No "syncing", no offline banner, no retry spinner.

That last one is the invariant I'm most likely to violate by habit, since almost every app I've built has an online state to indicate.

**Exit criteria:** the app runs entirely on real data from B's store and renders claims that arrived over A's mesh.

---

# WEEK 3 — PHASE 3: CONTRIBUTE FLOW

A takes Rescue, B takes Report, I take Contribute — I already know the UI shell best and this mostly needs volunteer-gating logic layered in.

### Day 1 — Pledging a resource
- [ ] Full flow: volunteer pins a resource with category and count
- [ ] Gated on `NodeTrust` — general users and provisional volunteers cannot pledge
- [ ] Location picker: current GPS or manual map placement
- [ ] Pledge writes through B's layer and propagates via A's mesh
- [ ] Appears on other devices' resource layer

### Day 2 — Claiming and the soft signal
- [ ] Any user can report a resource as running low (increments `claimedReports`)
- [ ] **This is a soft signal, visually distinct from the authoritative count** — "reportedly running low," not a hard number
- [ ] Rate-limited per device; UI communicates the limit without scolding
- [ ] Availability updates as a computed value, never optimistically mutated locally
- [ ] Volunteer-only "reset count" action for someone physically on site

### Day 3 — Uncertainty and staleness
- [ ] Range rendering ("2–6 packets") when replicas disagree — **without it looking like a bug to the user**
- [ ] A resource with `available == 0` is visually distinct but **not hidden** — "was here, now empty" is useful information
- [ ] Stale resource pins fade as they approach their decay window
- [ ] Last-confirmed relative time on the detail view
- [ ] Volunteer ground-confirmation makes a pin visually authoritative

### Day 4 — Resource layer polish
- [ ] Category filter within the resource layer
- [ ] Clustering for dense resource areas (a relief camp with many pins)
- [ ] Detail sheet: category, availability, confidence, last confirmed, who pledged
- [ ] Sort/filter by nearest
- [ ] Empty state: no resources known nearby

### Day 5 — Rescue and Report UI support
A and B own those flows' logic; I own how they look.
- [ ] SOS detail sheet: type, headcount, trust, dispatch state, relative time
- [ ] Proxy SOS visually distinct from self-raised, legible at a glance
- [ ] Hazard detail sheet with confirmation count and attest button
- [ ] "I can see this too" attestation button wired to B's explicit-attestation path
- [ ] Volunteer actions: mark seen, mark en route, ground confirm

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
- [ ] Measure real size; feed it into the storage budget with B
- [ ] Confirm tile eviction happens **before** active SOS records under pressure
- [ ] Bundle at install; verify a fresh install has working maps with no network
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
| | | | | |
| | | | | |
| | | | | |

### Open questions I'm carrying

- [ ] Which district's `.mbtiles` to bundle for real — Wk5 D1
- [ ] Icon set for low-literacy users — field validation is a known open question, not mine alone to settle
- [ ] How to visually distinguish Proxy SOS from self-raised at a glance — Wk3 D5
- [ ] Rendering "2–6 packets" uncertainty without it reading as a bug — Wk3 D3
- [ ] Screen-off behaviour with an active SOS — Wk4 D5, needs A's input
- [ ] Multi-language: MVP scope or backlog? — team call

### Screens status

| Screen | Mock | Real data | Polished | Notes |
|---|---|---|---|---|
| Entry | ☐ | ☐ | ☐ | |
| Map + layers | ☐ | ☐ | ☐ | |
| Bottom sheet | ☐ | ☐ | ☐ | |
| Rescue form | ☐ | ☐ | ☐ | incl. Proxy |
| Report form | ☐ | ☐ | ☐ | |
| Contribute form | ☐ | ☐ | ☐ | |
| SOS detail sheet | ☐ | ☐ | ☐ | |
| Hazard detail sheet | ☐ | ☐ | ☐ | |
| Resource detail sheet | ☐ | ☐ | ☐ | |
| Volunteer queue | ☐ | ☐ | ☐ | |
| QR display (requester) | ☐ | ☐ | ☐ | fresh nonce each show |
| QR scanner (volunteer) | ☐ | ☐ | ☐ | |
| Volunteer identity | ☐ | ☐ | ☐ | |
| Vouching | ☐ | ☐ | ☐ | |
