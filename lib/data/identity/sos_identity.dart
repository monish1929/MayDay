// lib/data/identity/sos_identity.dart

import 'dart:convert';
import 'package:crypto/crypto.dart';

/// SOS and SOS_PROXY — globally unique, never merges, ever.
///
/// CLAIM_SCHEMA.md §2:
/// The single most important thing in this file. Get it wrong and resolving one person's
/// rescue can silently delete a stranger's.
/// 
/// Two separate functions. Never one generateClaimId() with a type branch inside 
/// — that branch is exactly the kind of thing a future refactor "simplifies" away.
String generateSosClaimId(String originDeviceId, int localSequenceNumber) {
  // Time is never part of this ID. No timestamp, no time bucket.
  final input = "$originDeviceId:$localSequenceNumber";
  final bytes = utf8.encode(input);
  final digest = sha256.convert(bytes);
  return digest.toString();
}
