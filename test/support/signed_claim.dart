// test/support/signed_claim.dart
//
// Test-only helper for building claims that are allowed to reach the store.
//
// `ClaimFactory.createClaim()` deliberately returns an UNSIGNED claim — it
// says so in its own doc comment — because signing is the caller's job at
// origination (`MeshNode.originate`). `ClaimRepository` refuses anything whose
// signature is not exactly 64 bytes (CLAUDE.md §2.5, CLAIM_SCHEMA.md §5), so
// `createClaim()` followed by `insertClaim()` throws `UnsignedClaimException`
// by design. That is the guard working, not a bug to route around.
//
// Tests about persistence, reactivity or UI still need claims in the store.
// They sign here rather than hand-writing 64 dummy bytes, so the fixture goes
// through the same `cbor.encode(toSignedCoreCbor())` path the real originator
// uses. If the signed core ever changes shape, these break too.
//
// What this does NOT establish: the signature is made with a throwaway key
// that has nothing to do with `originDeviceId`, so the claim is well-formed,
// not cryptographically coherent. Nothing in the store checks that — the
// store's guard is a shape check, and real verification happens at the hop in
// `mesh/`. Tests that care about verification belong in `test/mesh/` and
// `test/identity/`, where they already live.

import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:mayday/data/claim_factory.dart';
import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/identity/keypair.dart';
import 'package:mayday/identity/signature.dart';

/// One key per test process, generated on first use.
///
/// Ed25519 keygen is not free and no test here depends on claims coming from
/// distinct keys — where that matters, pass an explicit [keyPair].
DeviceKeyPair? _cachedKey;

Future<DeviceKeyPair> _testKey() async {
  return _cachedKey ??= await DeviceKeyPair.generate();
}

/// Signs [claim] in place and returns it, so it can be stored.
Future<Claim> signForTest(Claim claim, {DeviceKeyPair? keyPair}) async {
  final key = keyPair ?? await _testKey();
  claim.originSignature = await ClaimSignature.sign(
    Uint8List.fromList(cbor.encode(claim.toSignedCoreCbor())),
    key,
  );
  return claim;
}

/// `ClaimFactory.createClaim()` plus the signing step the real origination
/// path performs, for tests that just need a storable claim.
///
/// Deliberately a wrapper rather than a change to `ClaimFactory`: the factory
/// returning something unsigned is the invariant, and a test helper must not
/// soften it for production callers.
Future<Claim> createSignedClaim({
  required ClaimPayload payload,
  required String originDeviceId,
  DeviceKeyPair? keyPair,
}) async {
  final claim = await ClaimFactory.createClaim(
    payload: payload,
    originDeviceId: originDeviceId,
  );
  return signForTest(claim, keyPair: keyPair);
}
