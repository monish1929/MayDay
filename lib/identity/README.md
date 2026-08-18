# identity/ — Keypairs, credentials, vouching

**Owner:** assigned in Phase 4 · **Required reviewer:** both others (security-sensitive, CLAUDE.md §3.3)

Ed25519 device keypair, volunteer credentials, vouching and revocation.
Provisional (vouched) nodes cannot vouch for others; the vouch cap is carried
inside the signed vouch; revocation propagates and overrides (§4.5).

Identity does not survive app uninstall — recovery is via vouching (§9).
