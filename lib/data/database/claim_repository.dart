import 'dart:async';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:cbor/cbor.dart';
import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/corroboration.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/database/database_helper.dart';
import 'package:mayday/identity/signature.dart';

import 'package:mayday/data/identity/geohash_utils.dart';

/// Thrown when a write is attempted with a claim whose signature is not the
/// shape an Ed25519 signature has.
///
/// A real exception rather than an `assert`: asserts are compiled out of a
/// release build, and this is the one guard standing between a bug in calling
/// code and an unsigned claim sitting in the store looking exactly like a real
/// one (CLAIM_SCHEMA.md §5, CLAUDE.md §2.5).
class UnsignedClaimException implements Exception {
  /// The claim that was refused. Named so the failure points at a record
  /// rather than just a stack trace.
  final String claimId;

  /// What the caller actually supplied. Zero means `ClaimFactory`'s unsigned
  /// placeholder went straight to the store without being signed at
  /// origination — the specific mistake this guard exists to catch.
  final int actualLength;

  const UnsignedClaimException(this.claimId, this.actualLength);

  @override
  String toString() => 'UnsignedClaimException: claim $claimId carries a '
      '$actualLength-byte signature, but §5 requires '
      '${ClaimSignature.signatureLength}. An unsigned claim must never reach '
      'the store. Sign at origination (MeshNode.originate) and rebuild the '
      'local copy from the signed bytes.';
}

class ClaimRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  /// Fires once per committed write, so a reader can re-query.
  ///
  /// Static because the store it reports on is a single SQLite file behind a
  /// singleton `DatabaseHelper`. A per-instance controller would mean a UI
  /// holding one `ClaimRepository` never hears about a write made through the
  /// `ClaimRepository` the mesh receive path constructed -- which is the exact
  /// case that matters: a claim arriving from another phone must reach the map
  /// without anyone refreshing.
  ///
  /// Carries no payload. Readers re-query rather than being handed the changed
  /// row, because what a reader wants is the CURRENT active set, and a claim
  /// can leave that set (resolved, archived) as easily as join it.
  static final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  /// Never closed -- see [_changeController]; it lives as long as the process.
  /// Guarded anyway so a test that does close it fails loudly at the point of
  /// the close rather than here.
  static void _notifyChange() {
    if (!_changeController.isClosed) {
      _changeController.add(null);
    }
  }

  Future<void> insertClaim(Claim claim) async {
    final db = await _dbHelper.database;
    await db.insert(
      'claims',
      _toMap(claim),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifyChange();
  }

  Future<void> updateClaim(Claim claim) async {
    final db = await _dbHelper.database;
    await db.update(
      'claims',
      _toMap(claim),
      where: 'id = ?',
      whereArgs: [claim.id],
    );
    _notifyChange();
  }

  /// Records one device's corroboration of a claim.
  ///
  /// `INSERT OR IGNORE`, because the table's `PRIMARY KEY (claim_id,
  /// device_id)` is itself a rule: one device is one witness, however many
  /// times it says so. A device that repeats itself must not be able to talk a
  /// claim up on its own — that is the per-device cap expressed in the schema
  /// rather than left to calling code to remember (§2.2, and §9's admission
  /// that Sybil resistance is mitigated, not solved).
  ///
  /// Ignoring rather than replacing keeps the FIRST account of what a device
  /// witnessed. A later copy arriving by a longer path carries a worse
  /// `hop_distance`, and overwriting would let a claim's weight drift with
  /// routing noise.
  Future<void> insertCorroboration(String claimId, Corroboration c) async {
    final db = await _dbHelper.database;
    await db.insert(
      'corroborations',
      {
        'claim_id': claimId,
        'device_id': c.deviceId,
        'hop_distance': c.hopDistance,
        'signal_strength': c.signalStrength,
        'first_seen_via': c.firstSeenVia,
        'kind': c.kind.index,
        'is_volunteer': c.isVolunteer ? 1 : 0,
        'clock_counter': c.logicalClock.counter,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    // A corroboration changes the claim's trust, and trust is what a pin's
    // appearance is drawn from (PERSON_C.md Wk2 D2: "pins update in place when
    // trust tier changes"). Without this notify, a claim corroborated over the
    // mesh would sit on the map still rendered faint. `INSERT OR IGNORE` can
    // be a no-op for a repeat device, which costs one redundant re-query --
    // cheaper than tracking whether the row actually landed.
    _notifyChange();
  }

  Future<List<Corroboration>> getCorroborations(String claimId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'corroborations',
      where: 'claim_id = ?',
      whereArgs: [claimId],
    );
    return rows.map((r) => Corroboration(
          deviceId: r['device_id'] as String,
          hopDistance: r['hop_distance'] as int,
          signalStrength: r['signal_strength'] as double?,
          firstSeenVia: r['first_seen_via'] as String?,
          kind: CorroborationKind.values[r['kind'] as int],
          isVolunteer: (r['is_volunteer'] as int) == 1,
          logicalClock: LogicalClock(
            deviceId: r['device_id'] as String,
            counter: r['clock_counter'] as int,
          ),
        )).toList();
  }

  Future<Claim?> getClaim(String id) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'claims',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      final claim = _fromMap(maps.first);
      // Hydrated on read: trust is recomputed from the corroboration list, so
      // a claim loaded without it would score zero and silently read as less
      // corroborated than it is.
      claim.corroborations = await getCorroborations(claim.id);
      return claim;
    }
    return null;
  }

  Future<List<Claim>> getActiveClaims() async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'claims',
      where: 'status = ?',
      whereArgs: [ClaimStatus.active.index],
    );

    final claims = List.generate(maps.length, (i) => _fromMap(maps[i]));
    for (final claim in claims) {
      claim.corroborations = await getCorroborations(claim.id);
    }
    return claims;
  }

  /// The active claim set, re-emitted on every write.
  ///
  /// Emits the current snapshot on subscribe, so a caller never has to pair
  /// this with a one-off [getActiveClaims] to paint its first frame.
  ///
  /// Reads are COALESCED: while one re-query is in flight, further writes set
  /// a flag rather than queueing their own read, and a single extra read runs
  /// when the first finishes. This is not premature optimisation -- claims
  /// arrive from the mesh in bursts (a relay flushing its queue on reconnect
  /// delivers many at once), and each read here is a query plus one
  /// corroboration query per claim. Uncoalesced, a burst of 50 would be 50
  /// full re-reads to arrive at a set the last one alone describes.
  ///
  /// Coalescing is safe because the events carry no payload: every emission is
  /// the whole current set, so dropping an intermediate read loses nothing but
  /// a frame that was already stale. The loop is structured so the LAST write
  /// always produces an emission -- a change that lands mid-read is not lost.
  Stream<List<Claim>> watchActiveClaims() {
    late final StreamController<List<Claim>> controller;
    StreamSubscription<void>? changeSub;
    var reading = false;
    var dirty = false;

    Future<void> emit() async {
      if (reading) {
        dirty = true;
        return;
      }
      reading = true;
      try {
        do {
          dirty = false;
          try {
            final claims = await getActiveClaims();
            if (!controller.isClosed) controller.add(claims);
          } catch (e, stack) {
            // Surfaced to the subscriber rather than thrown: the caller is a
            // UI, and a store read failing must not take the map down with it.
            if (!controller.isClosed) controller.addError(e, stack);
          }
        } while (dirty && !controller.isClosed);
      } finally {
        reading = false;
      }
    }

    controller = StreamController<List<Claim>>(
      onListen: () {
        // Subscribed before the first read, so a write landing during that
        // read still triggers a follow-up emission.
        changeSub = _changeController.stream.listen((_) => emit());
        emit();
      },
      onCancel: () async {
        await changeSub?.cancel();
        changeSub = null;
      },
    );

    return controller.stream;
  }

  Map<String, dynamic> _toMap(Claim claim) {
    // An unsigned claim must never reach the store — CLAIM_SCHEMA.md §5,
    // CLAUDE.md §2.5.
    //
    // Checked here, inside _toMap, rather than at each public write. This is
    // the single point every write already passes through, so a call site
    // added later is covered without anyone having to remember the rule. A
    // guard that depends on being remembered is the kind that survives right
    // up until someone adds a fourth caller.
    //
    // Deliberately a SHAPE check and not a verification, and the difference
    // matters: verifying needs the originating public key, and a Claim does
    // not carry one — `originDeviceId` is a hash of it, not the key itself.
    // Real signature verification happens at the hop, in `mesh/`
    // (CLAIM_SCHEMA.md §9.3 step 2), and that remains the only place a
    // signature is proven good. What this stops is the LOCAL path, which has
    // no verification step at all: a claim built by `ClaimFactory` — which
    // returns an empty signature by design, expecting the caller to sign it —
    // being handed straight to the store, never signed, and then rendered,
    // merged and corroborated exactly like a real one.
    if (claim.originSignature.length != ClaimSignature.signatureLength) {
      throw UnsignedClaimException(claim.id, claim.originSignature.length);
    }

    // Declared on the sealed base, so a new payload type is a compile error
    // rather than a silent (0, 0) fallback.
    final location = claim.payload.location;
    // cbor.encode() hands back a Uint8Buffer, which sqflite refuses to bind
    // ("Invalid sql argument type"). It must be a Uint8List to reach a BLOB.
    final payloadCbor = Uint8List.fromList(cbor.encode(claim.payload.toCbor()));

    return {
      'id': claim.id,
      'type': claim.type.index,
      'origin_device_id': claim.originDeviceId,
      // Identity, not ordering. Deliberately NOT logicalClock.counter: that
      // is a Lamport clock and moves on receive (§4), which would rewrite the
      // number hashed into a SOS id (§2). See DeviceClock.
      'origin_sequence': claim.originSequence,
      'clock_device_id': claim.logicalClock.deviceId,
      'clock_counter': claim.logicalClock.counter,
      'lat': location.lat,
      'lon': location.lon,
      'geohash_bucket': getGeohashBucket(location),
      'origin_signature': claim.originSignature,
      'claim_trust': claim.claimTrust.index,
      'dispatch_priority': claim.dispatchPriority.index,
      'status': claim.status.index,
      'payload': payloadCbor,
      'resolution_method': claim.resolutionMethod?.index,
      'resolved_by': claim.resolvedByVolunteerId,
      'resolved_at_logical_device_id': claim.resolvedAtLogical?.deviceId,
      'resolved_at_logical_counter': claim.resolvedAtLogical?.counter,
      'hop_limit': claim.hopLimit,
      'display_lifetime_ms': claim.displayLifetime?.inMilliseconds,
      'created_at_logical_device_id': claim.createdAtLogical?.deviceId ?? claim.logicalClock.deviceId,
      'created_at_logical_counter': claim.createdAtLogical?.counter ?? claim.logicalClock.counter,
      'last_confirmed_at_logical_device_id': claim.lastConfirmedAtLogical?.deviceId,
      'last_confirmed_at_logical_counter': claim.lastConfirmedAtLogical?.counter,
      'archived_at_logical_device_id': claim.archivedAtLogical?.deviceId,
      'archived_at_logical_counter': claim.archivedAtLogical?.counter,
    };
  }

  Claim _fromMap(Map<String, dynamic> map) {
    final type = ClaimType.values[map['type'] as int];
    
    // Decode payload
    final payloadBytes = map['payload'] as List<int>;
    final decodedCbor = cbor.decode(payloadBytes) as CborMap;
    final payload = ClaimPayload.fromCbor(type, decodedCbor);

    return Claim(
      id: map['id'] as String,
      type: type,
      originDeviceId: map['origin_device_id'] as String,
      originSequence: map['origin_sequence'] as int,
      originSignature: Uint8List.fromList(map['origin_signature'] as List<int>),
      logicalClock: LogicalClock(
        deviceId: map['clock_device_id'] as String,
        counter: map['clock_counter'] as int,
      ),
      claimTrust: ClaimTrust.values[map['claim_trust'] as int],
      dispatchPriority: DispatchPriority.values[map['dispatch_priority'] as int],
      status: ClaimStatus.values[map['status'] as int],
      resolutionMethod: map['resolution_method'] != null 
          ? ResolutionMethod.values[map['resolution_method'] as int] 
          : null,
      resolvedByVolunteerId: map['resolved_by'] as String?,
      resolvedAtLogical: map['resolved_at_logical_device_id'] != null
          ? LogicalClock(
              deviceId: map['resolved_at_logical_device_id'] as String,
              counter: map['resolved_at_logical_counter'] as int,
            )
          : null,
      hopLimit: map['hop_limit'] as int,
      displayLifetime: map['display_lifetime_ms'] != null
          ? Duration(milliseconds: map['display_lifetime_ms'] as int)
          : null,
      createdAtLogical: LogicalClock(
        deviceId: map['created_at_logical_device_id'] as String,
        counter: map['created_at_logical_counter'] as int,
      ),
      lastConfirmedAtLogical: map['last_confirmed_at_logical_device_id'] != null
          ? LogicalClock(
              deviceId: map['last_confirmed_at_logical_device_id'] as String,
              counter: map['last_confirmed_at_logical_counter'] as int,
            )
          : null,
      archivedAtLogical: map['archived_at_logical_device_id'] != null
          ? LogicalClock(
              deviceId: map['archived_at_logical_device_id'] as String,
              counter: map['archived_at_logical_counter'] as int,
            )
          : null,
      payload: payload,
    );
  }
}
