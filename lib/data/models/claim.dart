// lib/data/models/claim.dart

import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import '../enums.dart';
import 'logical_clock.dart';
import 'corroboration.dart';
import 'claim_payload.dart';

class Claim {
  String id;
  ClaimType type;
  String originDeviceId;

  /// The `SequenceCounter` value this device used when originating the claim.
  ///
  /// Kept as its own field rather than read back off `logicalClock.counter`:
  /// for SOS types this is the number hashed into `id` (§2), so it must stay
  /// pinned to that moment. `logicalClock` is a Lamport clock and moves on
  /// receive (§4) — reusing it here would silently rewrite `origin_sequence`
  /// as unrelated mesh traffic arrives. See `DeviceClock`.
  int originSequence;

  /// Ed25519 signature bytes — raw, exactly 64 bytes (§5). Binary, not text:
  /// a signature is arbitrary bytes and does not survive a round-trip through
  /// a Dart `String`, which is UTF-16.
  Uint8List originSignature;

  LogicalClock logicalClock;

  ClaimTrust claimTrust;
  DispatchPriority dispatchPriority;
  List<Corroboration> corroborations;

  ClaimStatus status;
  ResolutionMethod? resolutionMethod;
  String? resolvedByVolunteerId;
  LogicalClock? resolvedAtLogical;

  int hopLimit;
  Duration? displayLifetime;

  LogicalClock? createdAtLogical;
  LogicalClock? lastConfirmedAtLogical;
  LogicalClock? archivedAtLogical;

  ClaimPayload payload;

  Claim({
    required this.id,
    required this.type,
    required this.originDeviceId,
    required this.originSequence,
    required this.originSignature,
    required this.logicalClock,
    required this.claimTrust,
    required this.dispatchPriority,
    List<Corroboration>? corroborations,
    required this.status,
    this.resolutionMethod,
    this.resolvedByVolunteerId,
    this.resolvedAtLogical,
    required this.hopLimit,
    this.displayLifetime,
    this.createdAtLogical,
    this.lastConfirmedAtLogical,
    this.archivedAtLogical,
    required this.payload,
  }) : corroborations = corroborations ?? [] {
    // Assertions as per CLAIM_SCHEMA.md §10.1
    assert(
      !(type == ClaimType.sos || type == ClaimType.sosProxy) || displayLifetime == null,
      'displayLifetime must be null for SOS claims',
    );
    assert(
      !(type == ClaimType.sos || type == ClaimType.sosProxy) || resolutionMethod != ResolutionMethod.autoExpired,
      'autoExpired is never valid for SOS claims',
    );
  }

  /// CBOR of the immutable core — the exact bytes `originSignature` covers
  /// (CLAIM_SCHEMA.md §5). Mutable fields are excluded by design:
  /// `corroborations`, `claimTrust`, `dispatchPriority` and `status` are each
  /// device's own conclusion about a claim, not the originator's to assert.
  ///
  /// `originSequence` is included even though §5's original list omitted it.
  /// Without it a receiver cannot rebuild the claim (`origin_sequence` is
  /// NOT NULL in §10), and more importantly cannot check that the id really
  /// is `hash(originDeviceId, originSequence)` — see [verifyIdIntegrity].
  CborValue toSignedCoreCbor() {
    return CborList([
      CborString(id),
      CborSmallInt(type.index),
      CborString(originDeviceId),
      CborSmallInt(originSequence),
      logicalClock.toCbor(),
      payload.toCbor(),
      if (createdAtLogical != null) createdAtLogical!.toCbor() else const CborNull(),
    ]);
  }

  /// Rebuilds a claim from the signed core received over the wire.
  ///
  /// Returns null rather than throwing on anything malformed: the bytes came
  /// off the radio from a stranger's phone, so a bad shape is expected input
  /// and must not become an exception on the receive path (§9.3).
  ///
  /// The rebuilt claim starts at the *receiver's* defaults — `unconfirmed`,
  /// `low`, `active`, no corroborations. Trust and priority are never taken
  /// from the sender: a claim that arrived asserting its own trustworthiness
  /// is exactly what §2.2 exists to prevent.
  static Claim? fromSignedCoreCbor(
    CborValue value, {
    required Uint8List originSignature,
    required int hopLimit,
    Duration? displayLifetime,
  }) {
    try {
      if (value is! CborList || value.length != 7) return null;

      final idField = value[0];
      final typeField = value[1];
      final deviceField = value[2];
      final sequenceField = value[3];
      final clockField = value[4];
      final payloadField = value[5];
      final createdField = value[6];

      if (idField is! CborString) return null;
      if (typeField is! CborSmallInt) return null;
      if (deviceField is! CborString) return null;
      if (sequenceField is! CborSmallInt) return null;
      if (payloadField is! CborMap) return null;

      if (typeField.value < 0 || typeField.value >= ClaimType.values.length) {
        return null;
      }
      final type = ClaimType.values[typeField.value];

      final logicalClock = LogicalClock.fromCbor(clockField);
      if (logicalClock == null) return null;

      final createdAtLogical =
          createdField is CborNull ? null : LogicalClock.fromCbor(createdField);
      if (createdField is! CborNull && createdAtLogical == null) return null;

      return Claim(
        id: idField.toString(),
        type: type,
        originDeviceId: deviceField.toString(),
        originSequence: sequenceField.value,
        originSignature: originSignature,
        logicalClock: logicalClock,
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: hopLimit,
        // SOS never decays (§2.3); the constructor asserts this too.
        displayLifetime: (type == ClaimType.sos || type == ClaimType.sosProxy)
            ? null
            : displayLifetime,
        createdAtLogical: createdAtLogical,
        payload: ClaimPayload.fromCbor(type, payloadField),
      );
    } catch (_) {
      return null;
    }
  }

  /// True if `id` really is what §2's rules produce for this claim's own
  /// fields.
  ///
  /// A valid signature proves the originator wrote these bytes; it does not
  /// prove they computed the id honestly. A device could sign a claim whose
  /// id was lifted from someone else's id space — for SOS that means minting
  /// ids that collide with a stranger's rescue, which §2 exists to prevent.
  /// Checked at ingestion, not here, because the geohash bucket for mergeable
  /// types is derived from the payload location.
  bool verifyIdIntegrity({required String Function() expectedId}) {
    return id == expectedId();
  }
}
