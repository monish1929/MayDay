# Form-to-Storage Pipeline: Ground Truth Investigation

## Bottom Line Up Front

> **YES — your forms currently write real Claims to the data layer via SQLite.** They do NOT stop at `debugPrint`. Your progress log is accurate about the *current working-tree state*. However, **none of this work has been committed yet** — it exists only as unstaged changes in your working directory.

---

## 1. Does `mock_claim.dart` still exist?

| Location | Status |
|---|---|
| On disk (`lib/ui/models/mock_claim.dart`) | **No** — `Test-Path` returns `False` |
| In git HEAD (last commit `e1f3d4e` on `c/app-shell`) | **Yes** — still tracked in the committed tree |
| In `git status` | Shows as `D lib/ui/models/mock_claim.dart` (unstaged deletion) |

**Verdict**: `MockClaim` has been deleted from the working tree but the deletion **has not been committed**. The file was created in commit [`64b4b2b`](file:///c:/Users/monish/AndroidProjects/MayDay) (Aug 20) and never had a deletion commit. It is dead code — no current file imports it. The barrel file [`models.dart`](file:///c:/Users/monish/AndroidProjects/MayDay/lib/ui/models/models.dart) was rewritten to re-export from `lib/data/` instead.

Along with `mock_claim.dart`, the following Week 1 mock models were also deleted from disk but not committed:
- `D lib/ui/models/claim_payloads.dart`
- `D lib/ui/models/corroboration.dart`
- `D lib/ui/models/enums.dart`
- `D lib/ui/models/geo_point.dart`
- `D lib/ui/models/logical_clock.dart`
- `D lib/ui/models/mock_data.dart`

---

## 2. Do the form submit handlers write to SQLite or stop at debugPrint?

**All three forms call `ClaimFactory.createClaim(...)` → `ClaimRepository().insertClaim(claim)`**. There is no `debugPrint` anywhere in the submit path.

### Exact submit handler endings:

#### [`rescue_form_sheet.dart`](file:///c:/Users/monish/AndroidProjects/MayDay/lib/ui/forms/rescue_form_sheet.dart#L61-L118) — `_submitForm()` (lines 61–118):
```dart
    // Assemble real Claim via ClaimFactory — PERSON_C.md Week 2 Day 1
    final claim = await ClaimFactory.createClaim(
      payload: payload,
      originDeviceId: deviceId,
    );

    // TODO: SIGNING GAP — ...
    await ClaimRepository().insertClaim(claim);

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(...);
```

#### [`report_form_sheet.dart`](file:///c:/Users/monish/AndroidProjects/MayDay/lib/ui/forms/report_form_sheet.dart#L45-L82) — `_submitForm()` (lines 45–82):
```dart
    final claim = await ClaimFactory.createClaim(
      payload: payload,
      originDeviceId: deviceId,
    );

    // TODO: SIGNING GAP — ...
    await ClaimRepository().insertClaim(claim);

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(...);
```

#### [`contribute_form_sheet.dart`](file:///c:/Users/monish/AndroidProjects/MayDay/lib/ui/forms/contribute_form_sheet.dart#L61-L97) — `_submitForm()` (lines 61–97):
```dart
    final claim = await ClaimFactory.createClaim(
      payload: payload,
      originDeviceId: deviceId,
    );

    // TODO: SIGNING GAP — ...
    await ClaimRepository().insertClaim(claim);

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(...);
```

All three carry the `// TODO: SIGNING GAP` comment as your PERSON_C.md predicted.

---

## 3. Does `lib/ui/` import from `lib/data/`?

**Yes — indirectly through the barrel file.** No file in `lib/ui/` has a direct `import 'package:mayday/data/...'` import. Instead, they all import [`lib/ui/models/models.dart`](file:///c:/Users/monish/AndroidProjects/MayDay/lib/ui/models/models.dart), which re-exports everything from `lib/data/`:

```dart
// lib/ui/models/models.dart (lines 5–12)
export 'package:mayday/data/enums.dart';
export 'package:mayday/data/models/geo_point.dart';
export 'package:mayday/data/models/logical_clock.dart';
export 'package:mayday/data/models/corroboration.dart';
export 'package:mayday/data/models/claim_payload.dart';
export 'package:mayday/data/models/claim.dart';
export 'package:mayday/data/claim_factory.dart';
export 'package:mayday/data/database/claim_repository.dart';
```

This is how the form files access `ClaimFactory` and `ClaimRepository` without direct data-layer imports.

---

## 4. `originSignature` — type and value across the codebase

| File | Type | Value |
|---|---|---|
| [`lib/data/models/claim.dart:28`](file:///c:/Users/monish/AndroidProjects/MayDay/lib/data/models/claim.dart#L28) | `Uint8List` | (field declaration) |
| [`lib/data/claim_factory.dart:53`](file:///c:/Users/monish/AndroidProjects/MayDay/lib/data/claim_factory.dart#L53) | `Uint8List` | **`Uint8List(0)`** — empty placeholder |
| [`lib/data/database/claim_repository.dart:132`](file:///c:/Users/monish/AndroidProjects/MayDay/lib/data/database/claim_repository.dart#L132) | `Uint8List` | Serialized as blob to SQLite |
| [`lib/data/database/claim_repository.dart:165`](file:///c:/Users/monish/AndroidProjects/MayDay/lib/data/database/claim_repository.dart#L165) | `Uint8List` | Deserialized from blob |
| Tests (`volunteer_ops_reactive_test.dart`) | `Uint8List` | `Uint8List(0)` |
| Tests (`envelope_test`, `trust_engine_test`, `simulation_test`, `claim_test`, `claim_repository_test`) | `Uint8List` | `Uint8List(64)` |
| [`CLAIM_SCHEMA.md:19`](file:///c:/Users/monish/AndroidProjects/MayDay/Docs/CLAIM_SCHEMA.md#L19) | `String` | Schema doc still says `String` — **stale spec** |
| `MockClaim` (deleted, in git only) | `String` | Was `String originSignature` with values like `'mock-sig-001'` |

> [!WARNING]
> **Confirmed**: `ClaimFactory.createClaim` sets `originSignature: Uint8List(0)` at [line 53](file:///c:/Users/monish/AndroidProjects/MayDay/lib/data/claim_factory.dart#L53). `MockClaim` (deleted) used `String` with literal `'mock-sig-001'`. The schema doc `CLAIM_SCHEMA.md` still declares it as `String` — the implementation has moved to `Uint8List` but the doc hasn't been updated.

---

## 5. Git history vs. progress log

### Most recent commits touching each file:

| File | Last Committed | Commit | Message |
|---|---|---|---|
| `rescue_form_sheet.dart` | 2026-08-20 | `fbb2009` | `feat(ui): add bottom sheet forms...` |
| `report_form_sheet.dart` | 2026-08-20 | `fbb2009` | `feat(ui): add bottom sheet forms...` |
| `contribute_form_sheet.dart` | 2026-08-20 | `fbb2009` | `feat(ui): add bottom sheet forms...` |
| `mock_claim.dart` | 2026-08-20 | `64b4b2b` | `feat(ui): add MockClaim, payloads...` |

### What `git status` shows NOW (uncommitted working tree):

The entire "Week 2 Day 1" migration is present as **unstaged working-directory changes**:

```
 M lib/ui/forms/contribute_form_sheet.dart     ← modified to use ClaimFactory + ClaimRepository
 M lib/ui/forms/report_form_sheet.dart          ← same
 M lib/ui/forms/rescue_form_sheet.dart          ← same
 D lib/ui/models/mock_claim.dart                ← deleted
 D lib/ui/models/mock_data.dart                 ← deleted
 D lib/ui/models/claim_payloads.dart            ← deleted (replaced by lib/data/models/claim_payload.dart)
 D lib/ui/models/enums.dart                     ← deleted (replaced by lib/data/enums.dart)
 D lib/ui/models/geo_point.dart                 ← deleted
 D lib/ui/models/logical_clock.dart             ← deleted
 D lib/ui/models/corroboration.dart             ← deleted
 M lib/ui/models/models.dart                    ← rewritten to re-export from lib/data/
A  lib/data/claim_factory.dart                  ← NEW (added to index)
A  lib/data/database/claim_repository.dart      ← NEW (added to index)
A  lib/data/models/claim.dart                   ← NEW
A  lib/data/enums.dart                          ← NEW
   ... (full lib/data/ layer added)
```

### Does this match the progress log?

Your PERSON_C.md Wk2 D1 entry (dated **2026-08-23**) claims:
> "Mock models deleted, real Claim / ClaimPayload / LogicalClock / DatabaseHelper wired... forms assemble real Claims via ClaimFactory and persist to SQLite"

**The work described is real and present on disk — but:**

> [!IMPORTANT]
> 1. **It was never committed.** The `lib/data/` additions are staged (`A`) but the form modifications and mock deletions are unstaged (` M` / ` D`). No commit exists for any of this.
> 2. **The date in the log (Aug 23) doesn't match the last committed state (Aug 20).** The committed versions of the form files (`fbb2009`, Aug 20) are the Week 1 versions. The current on-disk versions with `ClaimFactory`/`ClaimRepository` wiring have never been snapshotted in git.
> 3. **There is no separate branch where this landed.** The branch list shows only `c/app-shell` (current), `main`, and other teammates' branches. None contain this work as committed code.

---

## 6. What's stale?

> [!CAUTION]
> **Your log is aspirationally correct but git-historically false.** The work your log describes (Wk2 D1, Aug 23) exists in the working tree — the code is real, the forms do call `ClaimFactory.createClaim()` → `ClaimRepository().insertClaim()`, and `MockClaim` is deleted from disk. But **none of it was ever committed**. If you lose this working tree (checkout another branch, reset, clone fresh), all of it vanishes.

### Summary:

| Question | Answer |
|---|---|
| Do forms write real claims to SQLite? | **Yes** — on disk right now |
| Is this committed? | **No** — entirely uncommitted working-tree changes |
| Is `MockClaim` deleted? | **Yes on disk, no in git** — unstaged deletion |
| Does `ClaimFactory` set `originSignature: Uint8List(0)`? | **Yes** — [line 53](file:///c:/Users/monish/AndroidProjects/MayDay/lib/data/claim_factory.dart#L53) |
| Is there a branch where this landed? | **No** — only exists as dirty working tree on `c/app-shell` |
| Is the progress log accurate? | **Describes real code, but claims it as done work when it's uncommitted** |

### Recommended immediate action:
Stage and commit this work before it's lost. Something like:
```bash
git add -A
git commit -m "feat(data+ui): wire forms to real Claim/ClaimFactory/ClaimRepository, delete Week 1 mocks"
```
