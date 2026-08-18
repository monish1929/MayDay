// lib/data/models/claim.dart

import 'package:cbor/cbor.dart';
import '../enums.dart';
import 'logical_clock.dart';
import 'corroboration.dart';
import 'claim_payload.dart';

class Claim {
  String id;
  ClaimType type;
  String originDeviceId;
  String originSignature;
  LogicalClock logicalClock;

  ClaimTrust claimTrust;
  DispatchPriority dispatchPriority;
  List<Corroboration> corroborations;

  ClaimStatus status;
  ResolutionMethod? resolutionMethod;
  String? resolvedByVolunteerId;
  DateTime? resolvedAtLogical;

  int hopLimit;
  Duration? displayLifetime;

  DateTime? createdAtLogical;
  DateTime? lastConfirmedAtLogical;
  DateTime? archivedAtLogical;

  ClaimPayload payload;

  Claim({
    required this.id,
    required this.type,
    required this.originDeviceId,
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

  // To be implemented: CBOR serialization for the full claim if needed over the wire, 
  // but typically the wire format is handled at the envelope level (Envelope in §9.1)
  // containing the body (which is the payload). The `payload` encodes to CBOR.
}
