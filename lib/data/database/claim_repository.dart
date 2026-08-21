import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:cbor/cbor.dart';
import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/database/database_helper.dart';

import 'package:mayday/data/identity/geohash_utils.dart';
import 'package:mayday/data/models/geo_point.dart';

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

  Map<String, dynamic> _toMap(Claim claim) {
    // Extract location dynamically since it's common across all payload types
    // but the getter is defined in subclasses. For storage indexing (lat, lon).
    double lat = 0.0;
    double lon = 0.0;
    
    if (claim.payload is SosPayload) {
      lat = (claim.payload as SosPayload).location.lat;
      lon = (claim.payload as SosPayload).location.lon;
    } else if (claim.payload is SosProxyPayload) {
      lat = (claim.payload as SosProxyPayload).location.lat;
      lon = (claim.payload as SosProxyPayload).location.lon;
    } else if (claim.payload is HazardReportPayload) {
      lat = (claim.payload as HazardReportPayload).location.lat;
      lon = (claim.payload as HazardReportPayload).location.lon;
    } else if (claim.payload is ResourcePayload) {
      lat = (claim.payload as ResourcePayload).location.lat;
      lon = (claim.payload as ResourcePayload).location.lon;
    }
    
    // Convert origin_signature to bytes (assuming it's a base64 or hex string, or just string for now)
    // Actually the schema uses BLOB for origin_signature. We'll store it as bytes or string if needed.
    // For now we'll just store the string as bytes for SQLite compatibility.
    // Wait, the Claim object holds it as String. Let's just use utf8.encode or similar.
    final originSignatureBlob = Uint8List.fromList(claim.originSignature.codeUnits);
    
    // Payloads
    final payloadCbor = cbor.encode(claim.payload.toCbor());

    return {
      'id': claim.id,
      'type': claim.type.index,
      'origin_device_id': claim.originDeviceId,
      'origin_sequence': claim.logicalClock.counter, // The local sequence num when created
      'clock_device_id': claim.logicalClock.deviceId,
      'clock_counter': claim.logicalClock.counter,
      'lat': lat,
      'lon': lon,
      'geohash_bucket': getGeohashBucket(GeoPoint(lat: lat, lon: lon)),
      'origin_signature': originSignatureBlob,
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

    // Decode signature
    final sigBytes = map['origin_signature'] as List<int>;
    final sig = String.fromCharCodes(sigBytes);

    return Claim(
      id: map['id'] as String,
      type: type,
      originDeviceId: map['origin_device_id'] as String,
      originSignature: sig,
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
