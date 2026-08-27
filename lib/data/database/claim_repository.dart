import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:cbor/cbor.dart';
import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/corroboration.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/database/database_helper.dart';

import 'package:mayday/data/identity/geohash_utils.dart';

class ClaimRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<void> insertClaim(Claim claim) async {
    final db = await _dbHelper.database;
    await db.insert(
      'claims',
      _toMap(claim),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateClaim(Claim claim) async {
    final db = await _dbHelper.database;
    await db.update(
      'claims',
      _toMap(claim),
      where: 'id = ?',
      whereArgs: [claim.id],
    );
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

  Map<String, dynamic> _toMap(Claim claim) {
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
