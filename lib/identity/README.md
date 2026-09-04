# identity/ — Keypairs, credentials, vouching

**Owner:** assigned in Phase 4 · **Required reviewer:** both others (security-sensitive, CLAUDE.md §3.3)

Ed25519 device keypair, volunteer credentials, vouching and revocation.
Provisional (vouched) nodes cannot vouch for others; the vouch cap is carried
inside the signed vouch; revocation propagates and overrides (§4.5).

Identity does not survive app uninstall — recovery is via vouching (§9).

---

## Opened early in Phase 2 — what exists now, and what does not

Phase 2 Day 2 needs Ed25519 sign/verify immediately: `data/` signs a claim at
origination, `mesh/` verifies at every hop (§9.3 step 2). The primitive lives
here rather than in either of those folders because both need it and neither
owns it — putting it in one would force the other to import across an
ownership boundary.

**Built (A+B, Phase 2):**
- `signature.dart` — `ClaimSignature.sign` / `.verify`. Verify never throws;
  malformed input returns false, because on this transport the sender is a
  stranger's phone (§9.3).
- `keypair.dart` — `DeviceKeyPair`. `deviceId` is derived from the public key,
  never from the BLE address, which Android rotates per advertising session
  (`PHASE0_MESH_FINDINGS.md` §7).

**Explicitly NOT built — still Phase 4:**
- **Secure key storage.** `loadOrCreateProvisional()` writes the seed to
  `SharedPreferences`, which is plaintext on disk. It is a placeholder that
  keeps the signing path testable on a real device. Android Keystore replaces
  it. Do not build anything security-sensitive on top of it.
- Volunteer credentials, `NodeTrust`, vouching, vouch caps, revocation.
- Any check of *whether a signer is a volunteer* — `TrustEngine.markGroundConfirmed`
  is unguarded today precisely because there is no identity system to ask yet.

Since this folder had no assigned owner when the above landed, all three
people were made aware rather than it being decided by whoever was typing.
