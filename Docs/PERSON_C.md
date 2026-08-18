# PERSON_C.md — App Shell, Map & UI

**Owner:** C
**Branch prefix:** `c/`
**Primary folder:** `lib/ui/`
**Reviews my PRs:** A or B (whoever's area my change touches)
**I review:** the `ab/` pairing branch in Phase 2, and flow PRs

Read `CLAUDE.md` and `CLAIM_SCHEMA.md` first. This file is my task list and progress log — update the checkboxes as I go, and fill in the log at the bottom.

---

## 1. What I own

Everything the user actually sees and touches.

- Entry screen, navigation, app shell
- The offline map (MapLibre GL + pre-bundled `.mbtiles`)
- Layer toggle: Emergency layer / Resource layer
- Bottom sheet with Rescue / Report / Contribute
- Pin rendering — different icons and states per claim type and trust tier
- Volunteer ops screen: rescue queue, report review, resource coordination
- Later: the Contribute flow

**What I don't own:** how trust is computed, how claims are identified, how bytes move between phones. My layer **reads** from B's data layer and renders it.

---

## 2. The one rule for my layer

**No business logic in widgets.**

The UI never computes trust, never decides decay, never generates a claim ID, never decrements a resource count. It asks the data layer and renders the answer.

Why this matters more than usual here: the invariants in `CLAUDE.md` §2 exist because v1 got them wrong in ways that could cost someone a rescue. If trust logic gets duplicated into a widget, we now have two implementations and only one of them is tested. When I need a number the data layer doesn't give me, the fix is to ask B for it — not to compute it in the view.

---

## 3. Week 1 — App shell with mock data

I don't wait on anyone this week. I fake the shape of a Claim from `CLAIM_SCHEMA.md` and build against that. B's real store arrives next week.

### Day 1 — Shell and navigation

- [ ] Flutter project structure per `CLAUDE.md` §5.1
- [ ] Entry screen: **User** / **Volunteer** buttons
- [ ] Navigation scaffold, route definitions
- [ ] A `MockClaim` class matching `CLAIM_SCHEMA.md` §1 field-for-field — same names, same enums

**Use the real field names from day one.** If I invent `urgency` where the schema says `dispatchPriority`, next week's swap becomes a rename job instead of a plug-in.

### Day 2 — The map

- [ ] MapLibre GL integrated
- [ ] One small `.mbtiles` file bundled as a placeholder (any district — pick something small for now)
- [ ] Map renders fully offline — **test with the device in airplane mode**
- [ ] Pan, zoom, sensible initial position

**Airplane mode is the real test.** It's easy to accidentally ship a map that quietly fetches tiles from the network in dev and fails silently in the field.

### Day 3 — Bottom sheet and forms

- [ ] Bottom sheet with three actions: **Rescue**, **Report**, **Contribute**
- [ ] Rescue form: type selector (Individual / Group / **Proxy**), headcount bucket, optional proxy note (80 char cap)
- [ ] Report form: hazard kind, optional note (80 char cap)
- [ ] Contribute form: resource category (the canonical four), pledged count
- [ ] Forms print to console for now — no data layer yet

**Don't forget Proxy SOS.** It's the case where someone raises an alarm for a neighbour whose phone is dead. Our own research says rural families typically share one phone between them, so the person needing rescue often isn't the person holding a device. It's easy to leave out because it wasn't in v1 of the design.

### Day 4 — Pins and layers

- [ ] Layer toggle: **Emergency** (SOS + hazard reports) / **Resource**
- [ ] Distinct icons: SOS, Proxy SOS, hazard, each resource category
- [ ] Trust tier changes appearance — UNCONFIRMED faint, CORROBORATED full opacity, GROUND_CONFIRMED distinct
- [ ] Hazard pins show a confirmation count ("12 reports")
- [ ] Resource pins show availability as a **range** when uncertain ("2–6 packets")
- [ ] SOS pins cluster visually at low zoom ("3 SOS here") — **display only, records stay separate**
- [ ] An aging unresolved SOS renders with **more** visual urgency, not less

Two things worth getting right early because they're easy to get backwards:

- **Relative time only.** "About 2 hours ago" — never a precise timestamp. Devices can't sync clocks with no network, so a precise time would be a fabrication.
- **Aging SOS gets louder.** The instinct is to fade old pins. Here that's exactly wrong: an unresolved SOS that's been sitting for six hours is *more* urgent, not less.

### Day 5 — Volunteer ops screen

- [ ] Rescue queue, sorted by `dispatchPriority` then trust
- [ ] Report review list
- [ ] Resource coordination view
- [ ] QR scanner screen skeleton (camera permission, viewfinder — no verification logic yet, that's Phase 3)
- [ ] All showing mock data

### Exit criteria

A fully clickable app that looks like the real thing, running on mock data, ready to have B's store dropped in underneath.

---

## 4. The week 1 sync — what I bring

I'm not the blocker this week, but two things are worth raising:

- [ ] Any field I needed that isn't in `CLAIM_SCHEMA.md` — better to catch a gap now than after B has built against it
- [ ] Rough `.mbtiles` size for one district, since it feeds the storage budget in `CLAIM_SCHEMA.md` §10.2 and the "map tiles get evicted before SOS records" rule

---

## 5. Week 2 — Swap mocks for real data

A and B pair on the transport↔data seam (`ab/` branch). **I work solo**, replacing `MockClaim` with real queries against B's store from Phase 1 — which already works standalone, so I'm not blocked on their pairing.

- [ ] Replace `MockClaim` with B's real `Claim`
- [ ] Map pins render from live SQLite queries
- [ ] Volunteer queue reads real `dispatchPriority`
- [ ] Forms actually write claims through B's data layer
- [ ] Reactive updates — a claim arriving updates the map without a manual refresh

### Day 3–4 — Three-way integration

The real end-to-end test, all three of us: **can my UI display a claim that originated on a different phone and arrived over A's mesh?**

- [ ] Claim raised on phone 1 appears on phone 2's map
- [ ] Trust tier change on one device reflects on the other
- [ ] Two SOS in the same geohash bucket render as **two pins**, not one

That last one is the visual proof of the most important bug we fixed. Worth checking with my own eyes rather than trusting the test suite.

### Day 4 onward — Phase 3

- [ ] I take the **Contribute** flow — volunteer gating, pledged/claimed split

---

## 6. Invariants that show up in my layer

Most invariants live in B's code, but these surface in the UI and I can break them from here:

- **Availability is computed, never stored.** I display `max(0, pledged − claimed)` from the data layer. I never cache it in widget state and mutate it locally — that's how it drifts from truth.
- **General Users can't pledge resources**, only report a resource as running low. Gate the Contribute form on `nodeTrust`.
- **SOS clustering is display-only.** Clustering nearby pins is a zoom-level rendering choice. It must never merge records or resolve more than one claim at a time.
- **Relative time only.** Never a precise timestamp.
- **Aging SOS gets more urgent, not faded.**
- **Nothing in the UI implies connectivity.** No "syncing…", no "offline mode" banner, no retry spinner, no cloud icons. There's no online state to contrast with — the app has one mode. A "reconnecting" spinner would be actively misleading to someone waiting for rescue.

That last one is easy to violate by habit, since almost every app we've built has an online state to indicate.

---

## 7. My PR checklist

Beyond the standard checks in `CLAUDE.md` §4.5:

- [ ] No business logic in widgets — no trust, decay, ID generation, or count arithmetic in the view layer
- [ ] Map tested in **airplane mode**
- [ ] Field names match `CLAIM_SCHEMA.md` exactly — no local renames
- [ ] Nothing in the UI implies connectivity or a sync state
- [ ] Availability read from the data layer, not cached and mutated locally
- [ ] Reviewer named per `CLAUDE.md` §3.3

---

## 8. Progress log

Update after each work session. Short entries — this is for the team sync.

| Date | Branch | What landed | Blocked on / notes |
|---|---|---|---|
| | | | |
| | | | |
| | | | |

### Open questions I'm carrying

- [ ] Which district's `.mbtiles` to bundle for real (placeholder is fine for week 1)
- [ ] Icon set — needs to work for low-literacy users, icon-first over text. Field validation is a known open question in `CLAUDE.md` §8.
- [ ] How to visually distinguish Proxy SOS from self-raised SOS — reporter details may be less reliable, and that should be legible at a glance
- [ ] Rendering the "2–6 packets" uncertainty range without looking like a bug to the user

### Screens status

| Screen | Mock | Real data | Notes |
|---|---|---|---|
| Entry | ☐ | ☐ | |
| Map + layers | ☐ | ☐ | |
| Bottom sheet | ☐ | ☐ | |
| Rescue form | ☐ | ☐ | incl. Proxy |
| Report form | ☐ | ☐ | |
| Contribute form | ☐ | ☐ | |
| Volunteer queue | ☐ | ☐ | |
| QR scanner | ☐ | ☐ | logic in Phase 3 |
