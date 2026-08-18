// lib/data/identity/report_identity.dart

import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../enums.dart';

/// HAZARD_REPORT and RESOURCE — merges by design.
///
/// CLAIM_SCHEMA.md §2:
/// Merging is the goal. These are separate from SOS by design.
/// 
/// Time is never part of either ID. No timestamp, no time bucket, in either formula.
String generateMergeableClaimId(ClaimType type, String geohashBucket) {
  assert(type != ClaimType.sos && type != ClaimType.sosProxy, 'SOS types must use generateSosClaimId');
  
  final input = "${type.name}:$geohashBucket";
  final bytes = utf8.encode(input);
  final digest = sha256.convert(bytes);
  return digest.toString();
}
