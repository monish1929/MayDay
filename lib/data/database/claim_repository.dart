import 'dart:async';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:cbor/cbor.dart';
import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/database/database_helper.dart';

import 'package:mayday/data/identity/geohash_utils.dart';

class ClaimRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  static final StreamController<void> _changeController =
      StreamController<void>.broadcast();

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

  Future<Claim?> getClaim(String id) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'claims',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return _fromMap(maps.first);
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

    return List.generate(maps.length, (i) {
      return _fromMap(maps[i]);
    });
  }

  /// Returns a stream of active claims that emits immediately with the current
  /// snapshot and re-emits whenever claims are inserted, updated, or modified.
  Stream<List<Claim>> watchActiveClaims() {
    late StreamController<List<Claim>> controller;
    StreamSubscription<void>? changeSub;

    controller = StreamController<List<Claim>>(
      onListen: () async {
        // Subscribe to changes immediately so no events are missed
        changeSub = _changeController.stream.listen((_) async {
          try {
            final claims = await getActiveClaims();
            if (!controller.isClosed) {
              controller.add(claims);
            }
          } catch (e) {
            if (!controller.isClosed) controller.addError(e);
          }
        });

        // Emit initial snapshot
        try {
          final claims = await getActiveClaims();
          if (!controller.isClosed) {
            controller.add(claims);
          }
        } catch (e) {
          if (!controller.isClosed) controller.addError(e);
        }
      },
      onCancel: () {
        changeSub?.cancel();
      },
    );

    return controller.stream;
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
