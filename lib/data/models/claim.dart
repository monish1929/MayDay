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

  /// Returns the CBOR representation of the immutable core of the claim.
  /// This is the data that the originSignature is computed over.
  CborValue toSignedCoreCbor() {
    return CborList([
      CborString(id),
      CborSmallInt(type.index),
      CborString(originDeviceId),
      logicalClock.toCbor(),
      payload.toCbor(),
      if (createdAtLogical != null) createdAtLogical!.toCbor() else const CborNull(),
    ]);
  }
}
