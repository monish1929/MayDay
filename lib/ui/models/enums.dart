// Canonical enums — CLAIM_SCHEMA.md §11.
// Do not add values without a team sync.
// These are real Dart enums, never raw strings or ints (CLAUDE.md §5.2).

/// The four claim types — CLAIM_SCHEMA.md §1.
/// SOS and sosProxy have unique IDs (§2); hazardReport and resource merge by geohash.
enum ClaimType { sos, sosProxy, hazardReport, resource }

/// How likely the claim is true — CLAIM_SCHEMA.md §3.
/// Moves only on evidence (independentGeneration or explicitAttestation).
/// Relaying never upgrades this — CLAUDE.md §2.2.
enum ClaimTrust { unconfirmed, corroborated, groundConfirmed }

/// How urgently a volunteer should look — CLAIM_SCHEMA.md §3.4.
/// Separate from claimTrust — CLAUDE.md §2.4.
/// A volunteer touching a claim raises priority, never trust.
enum DispatchPriority { low, seenByVolunteer, enRoute }

/// Is this rescue/report still open? — CLAIM_SCHEMA.md §6.
enum ClaimStatus { active, resolved, archived }

/// How the claim was resolved — CLAIM_SCHEMA.md §6.2/§6.3.
/// autoExpired is never valid for sos/sosProxy — CLAIM_SCHEMA.md §10.1.
enum ResolutionMethod { qr, manual, autoExpired }

/// What triggered the corroboration — CLAIM_SCHEMA.md §3.1.
/// Relaying is deliberately NOT in this list — CLAUDE.md §2.2.
enum CorroborationKind { independentGeneration, explicitAttestation }

/// Headcount bucket for group/proxy SOS — CLAIM_SCHEMA.md §8.
enum HeadcountBucket { twoToFive, sixToFifteen, fifteenPlus }

/// Hazard subtypes — CLAIM_SCHEMA.md §8.
enum HazardType { flood, roadBlock, structuralDamage, other }

/// Resource categories — the canonical four — CLAIM_SCHEMA.md §8.
/// Don't add more without team sync — CLAUDE.md §7.
enum ResourceCategory { foodWater, shelter, medical, equipment }
