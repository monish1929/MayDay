# CLAUDE.md — MayDay

Agent instructions for this repository. Read this fully before making any change.

**Companion documents:**
- `Docs/MAYDAY_PROJECT_CONTEXT.md` — full design reasoning, architecture, and the record of what was deliberately ruled out. The authority on *why* things are the way they are.
- `Docs/CLAIM_SCHEMA.md` — the shared data contract. No single owner. Changing it requires both other team members' awareness (§4.3).

If this file and the context document ever disagree, **stop and flag it** rather than picking one. A drift between them is itself a bug.

---

## 1. What this project is

MayDay is an **offline-first mesh disaster response app** for rural India. Phones talk directly to each other over Bluetooth Low Energy and Wi-Fi Direct. There is no server, no internet, no cell network — not as a fallback, not "eventually," not at all.

Three core actions: **Rescue** (location-tagged SOS), **Report** (hazard flagging), **Contribute** (resource pinning). All three sit on one shared trust primitive: the **Corroboration Engine**, which assigns confidence to a claim with no central authority to check it against.

Target: **Flutter, Android-first**, low-end devices.

### 1.1 The single rule that overrides everything

> **Life-critical data is never silently discarded.**
>
> No decay rule, no de-duplication rule, no storage eviction, and no merge rule may ever cause an unresolved SOS to disappear from a device holding it. Where saving battery or storage conflicts with keeping an SOS visible, **the SOS wins.**

When a design question has no obvious answer, resolve it against this rule first.

### 1.2 Never suggest these — they were ruled out deliberately

The agent should not propose these as solutions, and should push back if asked to add them without a stated reason to reverse the decision:

| Do not suggest | Why it's out |
|---|---|
| Any backend, server, cloud sync, or REST API | The entire premise is no internet, ever. There is nothing to sync to. |
| SMS / USSD / OTP / phone-number login | Requires a cell tower. Volunteer identity is a local keypair; the phone number is a display label only. |
| Encrypting claim payloads | Relay phones **must** read content to corroborate, merge, and render pins. Sign, don't encrypt. |
| AI/ML trust or fraud scoring | Needs connectivity or hardware we don't have. Trust is rule-based. |
| Photo-based rescue confirmation | No offline way to verify authenticity. Use the signed QR handshake. |
| NTP or network time sync | No network. Use logical clocks + mesh time gossip. |
| Time-bucketed claim IDs | Clocks drift with no sync; identical events would produce different IDs and never merge. |
| Treating relay as corroboration | A relaying device learned nothing. This was a real bug in v1 of the design. |

---

## 2. The five invariants

These are the design decisions most likely to be broken by a plausible-looking change. Check every PR against them.

### 2.1 SOS claims have a different identity rule from everything else

```
SOS / SOS_PROXY   →  id = hash(origin_device_id + local_sequence_number)   // UNIQUE, never merges
HAZARD / RESOURCE →  id = hash(type + geohash_bucket)                      // merges by design
```

**Why:** the geohash bucket is 150–300m. Under a single shared rule, two families on the same street raising SOS simultaneously produce the *same ID*, get shown as one pin, count as corroborating each other — and when a volunteer resolves one via QR, the other vanishes from every device in the mesh.

**Enforce:** these must be two separate code paths. Never a shared function with a conditional inside. Grouping nearby SOS pins is a **display-only** concern; the underlying records stay separate and individually resolvable.

### 2.2 Relaying is not corroboration

`claim_trust` upgrades to CORROBORATED on exactly two things:

1. **Independent generation** — a different device created a matching claim *without having received the original first*.
2. **Explicit attestation** — a human deliberately tapped "I can see this too."

Forwarding a message is neither. A relaying device knows nothing more than it did before.

**Also enforce the anti-echo rule:** a device cannot corroborate a claim it first learned about from the mesh. The `first_seen_via` field exists for this. Ten people confirming a rumour they all read on the same screen is one witness and nine repeaters.

### 2.3 SOS never decays

| Type | Decay |
|---|---|
| SOS / SOS_PROXY | **Never.** Clears only on confirmed resolution. Ages into *more* visual urgency, not less. |
| HAZARD_REPORT | Long window |
| RESOURCE | Fastest |

**Why:** a person trapped alone is UNCONFIRMED precisely *because* nobody is nearby to corroborate. A blanket decay rule deletes the call for help from the person in the most danger.

### 2.4 Trust and priority are separate fields

- `claim_trust` — how likely the claim is **true**. Moves only on evidence.
- `dispatch_priority` — how urgently a volunteer should **look at it**. Moves when a volunteer sees or relays it.

A volunteer touching a claim raises priority, never trust. A claim can be `EN_ROUTE` while still `UNCONFIRMED` — that's an accepted bias toward response speed.

### 2.5 Claims are signed, never encrypted

Ed25519 signature from the originating device on every claim. Verified at every hop; malformed or unsigned claims are dropped. Content stays readable by relays, because relays must read it to do their job.

---

## 3. Work split

### 3.1 Current phase

> **UPDATE THIS SECTION AT THE START OF EVERY PHASE.** Ownership changes between phases; a stale table sends PRs to the wrong reviewer.

**Current phase:** Week 1 — independent slices, no cross-dependencies.

| Person | Owns this week | Deliverable |
|---|---|---|
| **A** | BLE mesh spike (`mesh/`) | Two then three phones discovering + passing a message. Real numbers on range, discovery time, battery drain per hour. |
| **B** | Claim schema + trust engine (`data/`) | Claim table in SQLite, both ID paths, trust state machine, type-specific decay, logical clocks. Unit tested with a simulated multi-device harness. |
| **C** | App shell + map (`ui/`) | Entry screen, navigation, MapLibre GL map with a placeholder `.mbtiles`, layer toggle, bottom sheet, mock pins, volunteer ops screen skeleton. |

Each person has a per-track task list and progress log — `Docs/PERSON_A.md`, `Docs/PERSON_B.md`, `Docs/PERSON_C.md`. They expand this table into checkboxes and record what actually happened. **This file stays authoritative on invariants and workflow;** if a PERSON doc contradicts it, the PERSON doc is the one that is wrong. When working on someone's track, read their file alongside this one and update its checkboxes as work lands.

Nothing imports across these three this week. C fakes the shape of a Claim rather than waiting on B.

### 3.2 Phase roadmap

| Phase | What | Notes |
|---|---|---|
| **0** | BLE mesh spike | Throwaway code. Answers "is mesh viable on our hardware" before anything is built on it. |
| **1** | Data layer, no networking | Pure logic, testable on one device. |
| **2** | Wire transport to data | **A+B pair on this.** Where the subtle bugs live. C swaps mocks for the real store in parallel. |
| **3** | Core flows — Rescue, then Report, then Contribute | One per person. Rescue goes to whoever came out of Phase 2 with the deepest grip on trust-tier logic. |
| **4** | Volunteer identity + vouching | Self-contained. Whoever finishes their Phase 3 flow first. |
| **5** | Map, UI polish, offline tiles | Last, deliberately. Least architecturally risky. Shared ownership. |

### 3.3 Ownership and required reviewers

| Area | Owner | Required reviewer | Why |
|---|---|---|---|
| `mesh/` | A | **B specifically** | B is the one who'll notice if the wire format breaks what the schema needs |
| `data/` | B | **A specifically** | Same, in reverse |
| `ui/` | C | whoever's flow it touches | |
| `flows/rescue/` | assign in Phase 3 | the other Phase-2 pairer | |
| `flows/report/` | assign in Phase 3 | the other Phase-2 pairer | |
| `flows/contribute/` | C | A or B | |
| `identity/` | assign in Phase 4 | both others | Vouching + revocation is security-sensitive |
| `CLAIM_SCHEMA.md` | **no single owner** | **both others, always** | Silent field renames are the most likely way this project quietly breaks |

**Note for the agent:** with three people, "the other person" is ambiguous — always name a specific reviewer from this table, never say "get someone to review it." PRs drift toward whoever approves fastest otherwise.

---

## 4. Git workflow — follow this exactly, every time

This section exists so the agent enforces version control discipline even if a human forgets a step.

### 4.1 Branch naming
- Person A: `a/<short-description>` — e.g. `a/ble-discovery-spike`
- Person B: `b/<short-description>` — e.g. `b/claim-schema`
- Person C: `c/<short-description>` — e.g. `c/app-shell`
- Pairing branches: `ab/<description>`, `bc/<description>`, `ac/<description>` — used for Phase 2 integration work and anything else two people write together.

The prefix alone should make it obvious whose track a branch belongs to — never branch without it.

### 4.2 The loop, in order — do not skip steps
1. `git pull origin main` — always, before creating a new branch.
2. `git checkout -b <prefix>/<description>`
3. Work, commit in small increments (see 4.4 for message format).
4. `git push origin <branch-name>`
5. Open a PR. Determine the required reviewer from the ownership table in §3.3 and **name them in the PR description, with which area triggered it.** Do not let it merge without that review.
6. After merge, **all three** run `git pull origin main` before starting the next branch.

### 4.3 Rules the agent should actively enforce
- **Never commit directly to `main`.** If asked to make a change, create a branch first.
- **Never suggest force-pushing** to a shared branch.
- If a change touches `CLAIM_SCHEMA.md`, **pause and confirm both other team members are aware** before committing. This file has no single owner.
- If a PR diff touches more than one person's owned folder, **flag it explicitly and name the folders** — it likely means the work should have been split differently, or a shared contract needs updating first.
- If a PR touches `mesh/` or `data/`, require review from the *other* of A/B specifically — even if the author is C.
- Pairing branches still need the **third** person's review before merge. The pairing already had two sets of eyes; the third person is what catches "made sense to the two of us" bugs.
- Keep commits scoped to one logical change. Don't bundle unrelated fixes because they happened in the same session.
- If asked to implement something in the §1.2 ruled-out list, **stop and ask why** before writing code.

### 4.4 Commit message convention
```
feat: add claim ID split for SOS vs report/resource
fix: prevent relay from upgrading claim_trust
chore: tighten BLE scan duty cycle to 10s on / 50s off
docs: update CLAIM_SCHEMA with resolution_method field
test: add multi-device corroboration harness
```

### 4.5 Before opening a PR — confirm this checklist, don't just push

General:
- [ ] Builds without errors (`flutter build apk --debug`)
- [ ] `flutter analyze` clean
- [ ] Commit messages follow §4.4
- [ ] PR description names the required reviewer per §3.3, and which area triggered it

If the PR touches `data/`:
- [ ] SOS unique-ID path and report/resource merge-hash path tested **separately** — confirmed they are not a shared code path (§2.1)
- [ ] Relay does **not** upgrade `claim_trust` (§2.2)
- [ ] Anti-echo rule holds: a device cannot corroborate a claim it first saw via mesh
- [ ] SOS/SOS_PROXY exempt from decay (§2.3)
- [ ] `claim_trust` and `dispatch_priority` still separate fields (§2.4)

If the PR touches `mesh/`:
- [ ] Tested on **at least two physical devices** — emulator alone is not sufficient
- [ ] Signature verified at hop; unsigned/malformed claims dropped (§2.5)
- [ ] `hop_limit` decrements; message-ID cache prevents re-broadcast
- [ ] Battery impact noted in the PR description if scan behaviour changed

If the PR touches `identity/`:
- [ ] Provisional (vouched) nodes cannot vouch for others
- [ ] Vouch cap enforced and carried inside the signed vouch
- [ ] Revocation propagates and overrides

If the PR touches storage or eviction:
- [ ] **Active SOS records are never evicted**, at any storage pressure (§1.1)

---

## 5. Repo structure & code conventions

### 5.1 Layout
```
lib/
  mesh/          # BLE + Wi-Fi Direct transport.        Owner: A
  data/          # Claim model, SQLite, trust engine.   Owner: B
  identity/      # Keypairs, credentials, vouching.     Phase 4
  flows/
    rescue/
    report/
    contribute/
  ui/            # Screens, map, widgets.               Owner: C
  common/        # Shared utilities only — resist putting logic here
test/            # mirrors lib/, plus harness/ for the multi-device simulation
CLAUDE.md        # this file — agent instructions. Stays at the repo root so it loads automatically.
Docs/
  CLAIM_SCHEMA.md              # shared data contract, no single owner
  MAYDAY_PROJECT_CONTEXT.md    # design reasoning and what was ruled out
  PERSON_A.md                  # A's task list and progress log (mesh/)
  PERSON_B.md                  # B's task list and progress log (data/)
  PERSON_C.md                  # C's task list and progress log (ui/)
```

### 5.2 Dart / Flutter
- Explicit types on public APIs; inference is fine locally.
- **No business logic in widgets.** UI reads from the data layer; it never computes trust, decay, or claim IDs.
- Everything in `data/` must be testable with no Flutter widget tree and no real radio.
- Every enum in `CLAIM_SCHEMA.md` is a real Dart enum, never a raw string.
- Async via `Future`/`Stream`. No callback pyramids.

### 5.3 Comment the *why*, especially at invariant boundaries

Anything that looks like a redundant branch or an odd exception must say which invariant it protects — otherwise a future refactor will helpfully "simplify" it away:

```dart
// SOS never decays — CLAUDE.md §2.3.
// An isolated person has nobody nearby to corroborate them, which is
// exactly WHY they're UNCONFIRMED. Do not unify this with the
// hazard/resource decay path, however similar it looks.
if (claim.type == ClaimType.sos || claim.type == ClaimType.sosProxy) return;
```

---

## 6. Testing

### 6.1 Required coverage
- `data/` — unit tests for every `claim_trust` transition, **both ID paths separately**, all three decay behaviours
- `data/` — a multi-device simulation harness (fake devices, one shared store) written *before* any real networking exists
- `mesh/` — **two physical devices minimum. Emulator testing does not count for mesh code.**
- Signature handling — malformed, unsigned, and tampered claims all rejected at hop

### 6.2 Adversarial tests that must exist

These are real attack paths in this design, not hypotheticals:

| Test | Expected |
|---|---|
| Two SOS in the same geohash bucket, same minute | **Two distinct claims, two pins, independent resolution** |
| QR replayed without a fresh nonce | Resolution rejected |
| Device corroborates a claim it first heard via mesh | Rejected by anti-echo rule |
| One device presenting multiple identities | Corroboration weight capped |
| Twenty offline devices each claim the last resource, then merge | Availability floors at 0, never negative |
| Storage pressure with active SOS present | SOS retained; map tiles evicted first |

**Write the first one early.** It is the single most important test in the repo — it's the bug that would have made the system lose people.

---

## 7. Naming — get these right

v1 of the design used one word for two different things in several places. These are now distinct and must stay distinct:

| Use this | Not this | Because |
|---|---|---|
| `hop_limit` | TTL | How many times a message may be forwarded |
| `display_lifetime` | TTL | How long a pin stays visible. Unrelated quantity. |
| `claim_trust` | trust_tier | Confidence in a **claim** |
| `node_trust` | trust_tier | Confidence in a **person/device** |
| `pledged_count` | count | Volunteer-written, authoritative, add-only |
| `claimed_reports` | count | User-written, soft signal, add-only |

Availability is **computed, never stored**: `available = max(0, pledged − claimed)`.

Resource categories, canonical list: **Food & Water / Shelter / Medical / Equipment**.

---

## 8. Known open questions

Do not silently pick an answer to these — flag them.

- Exact `hop_limit` and `display_lifetime` defaults per message type. Pending real hop-range data from Phase 0.
- CRDT library choice. Semantics are settled (add-only counters, §7.4 of context doc) — the library is not.
- Whether fixed relay points (generator-powered node at a relief camp) are in scope. Also the most credible answer to the 72-hour battery ceiling.
- Clock drift tolerance width — depends on measured drift rates on target hardware.
- Whether Wi-Fi Direct is needed for MVP at all, or BLE alone suffices. Phase 0 answers this.

## 9. Honest limitations — state these, don't paper over them

The design's strongest quality is that it names what it cannot do. Preserve that. The agent should not write code or docs that imply these are solved:

- **Sybil resistance is mitigated, not solved.** One phone can present as several. Hardware-backed IDs and radio-path weighting raise the cost; they don't eliminate it.
- **Resource claims cannot be verified offline.** Identity-gating and decay are risk-reduction, not proof.
- **Volunteer identity does not survive app uninstall** — Android deletes Keystore keys. Recovery is via vouching.
- **A person with no phone and no reachable neighbour is outside the system's reach.** Proxy SOS mitigates; it does not close this.
- **72 hours is the battery target, not "permanent."** "Zero power" describes the environment, not a capability.
