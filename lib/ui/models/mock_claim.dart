import 'enums.dart';
import 'logical_clock.dart';
import 'corroboration.dart';
import 'claim_payloads.dart';

/// MockClaim — matches CLAIM_SCHEMA.md §1 field-for-field.
///
/// This is the mock data class for Week 1 of Person C's work. It mirrors the
/// exact shape of the real Claim from CLAIM_SCHEMA.md so that swapping to B's
/// real store in Week 2 is a drop-in, not a rename job.
///
/// **Use the real field names from day one.** If we invent `urgency` where the
/// schema says `dispatchPriority`, next week's swap becomes a rename job instead
/// of a plug-in. — PERSON_C.md §3 Day 1.
class MockClaim {
  /// Computed differently per type — CLAIM_SCHEMA.md §2.
  /// SOS/SOS_PROXY: hash(originDeviceId + localSequenceNumber) — globally unique.
  /// HAZARD_REPORT/RESOURCE: hash(type + geohashBucket) — merges by design.
  final String id;

  final ClaimType type;
  final String originDeviceId;
  final String originSignature;
  final LogicalClock logicalClock;

  /// UNCONFIRMED → CORROBORATED → GROUND_CONFIRMED — CLAIM_SCHEMA.md §3.
  /// Moves only on evidence (independent generation or explicit attestation).
  /// Relaying never upgrades this — CLAUDE.md §2.2.
  final ClaimTrust claimTrust;

  /// LOW → SEEN_BY_VOLUNTEER → EN_ROUTE — CLAIM_SCHEMA.md §3.4.
  /// Separate from claimTrust — CLAUDE.md §2.4.
  /// A volunteer touching a claim raises priority, NEVER trust.
  final DispatchPriority dispatchPriority;

  final List<Corroboration> corroborations;

  /// ACTIVE → RESOLVED → ARCHIVED — CLAIM_SCHEMA.md §6.
  final ClaimStatus status;

  /// qr | manual | autoExpired | null.
  /// autoExpired is NEVER valid for sos/sosProxy — CLAIM_SCHEMA.md §10.1.
  final ResolutionMethod? resolutionMethod;

  final String? resolvedByVolunteerId;
  final LogicalClock? resolvedAtLogical;

  /// How many more times this claim may be relayed — CLAIM_SCHEMA.md §7.
  /// NOT the same as displayLifetime. They share neither a variable nor a name.
  final int hopLimit;

  /// How long it stays visible on the map — CLAIM_SCHEMA.md §7.
  /// NULL for sos/sosProxy — they NEVER decay — CLAUDE.md §2.3.
  /// An isolated person has nobody nearby to corroborate; blanket decay
  /// deletes the call for help from the person in the most danger.
  final Duration? displayLifetime;

  final LogicalClock? createdAtLogical;
  final LogicalClock? lastConfirmedAtLogical;
  final LogicalClock? archivedAtLogical;

  /// Type-specific payload — CLAIM_SCHEMA.md §8.
  final ClaimPayload payload;

  /// Week-1-only mock display timestamp. NOT the same as createdAtLogical
  /// (LogicalClock) — this field exists purely so Day 4's aging-urgency
  /// visual has something to compare against before B's real mesh time
  /// gossip lands. Remove this field when Week 2 swaps in real Claim data
  /// and real relative-time display arrives from the data layer.
  /// — CLAIM_SCHEMA.md §4.
  final DateTime mockCreatedAt;

  MockClaim({
    required this.id,
    required this.type,
    required this.originDeviceId,
    required this.originSignature,
    required this.logicalClock,
    required this.claimTrust,
    required this.dispatchPriority,
    required this.corroborations,
    required this.status,
    this.resolutionMethod,
    this.resolvedByVolunteerId,
    this.resolvedAtLogical,
    required this.hopLimit,
    this.displayLifetime,
    required this.mockCreatedAt,
    this.createdAtLogical,
    this.lastConfirmedAtLogical,
    this.archivedAtLogical,
    required this.payload,
  })  :
        // SOS never decays — CLAUDE.md §2.3.
        // displayLifetime must be NULL for sos/sosProxy — CLAIM_SCHEMA.md §10.1.
        // Not a large number — NULL. A large value invites someone to
        // "tune it down" later during optimisation. NULL forces a code
        // change and a conversation.
        assert(
          !(type == ClaimType.sos || type == ClaimType.sosProxy) ||
              displayLifetime == null,
          'displayLifetime must be NULL for SOS/SOS_PROXY — CLAIM_SCHEMA.md §10.1. '
          'SOS never decays — CLAUDE.md §2.3.',
        ),
        // autoExpired is never valid for sos/sosProxy — CLAIM_SCHEMA.md §10.1.
        assert(
          !(type == ClaimType.sos || type == ClaimType.sosProxy) ||
              resolutionMethod != ResolutionMethod.autoExpired,
          'ResolutionMethod.autoExpired is NEVER valid for SOS/SOS_PROXY — '
          'CLAIM_SCHEMA.md §10.1.',
        );
}
