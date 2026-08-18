# test/

Mirrors `lib/`. Coverage required by CLAUDE.md §6:

- `data/` — every `claim_trust` transition, **both ID paths separately**, all three decay behaviours
- `harness/` — multi-device simulation (fake devices, one shared store), written *before* real networking
- `mesh/` — **two physical devices minimum**; emulator testing does not count
- signature handling — malformed, unsigned and tampered claims rejected at hop

## Adversarial tests that must exist (§6.2)

| Test | Expected |
|---|---|
| Two SOS in the same geohash bucket, same minute | Two distinct claims, two pins, independent resolution |
| QR replayed without a fresh nonce | Resolution rejected |
| Device corroborates a claim it first heard via mesh | Rejected by anti-echo rule |
| One device presenting multiple identities | Corroboration weight capped |
| Twenty offline devices each claim the last resource, then merge | Availability floors at 0, never negative |
| Storage pressure with active SOS present | SOS retained; map tiles evicted first |

**Write the first one early** — it is the single most important test in the repo.
