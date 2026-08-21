// lib/data/models/claim_payload.dart

import 'dart:typed_data';
import 'package:cbor/cbor.dart';
import '../enums.dart';
import 'geo_point.dart';

sealed class ClaimPayload {
  const ClaimPayload();

  CborValue toCbor();
  
  static ClaimPayload fromCbor(ClaimType type, CborMap map) {
    switch (type) {
      case ClaimType.sos:
        return SosPayload.fromCbor(map);
      case ClaimType.sosProxy:
        return SosProxyPayload.fromCbor(map);
      case ClaimType.hazardReport:
        return HazardReportPayload.fromCbor(map);
      case ClaimType.resource:
        return ResourcePayload.fromCbor(map);
    }
  }

  // Utility to strictly encode 32-bit float as a 4-byte CBOR byte string.
  // We use CborBytes instead of CborFloat because the Dart `cbor` package 
  // automatically encodes all Dart doubles as 8-byte CBOR floats.
  // Using bytes loses the self-describing nature of CBOR numbers, but 
  // guarantees the exact 4-byte footprint required by the §9.2 budget.
  // Endianness is explicitly little-endian for wire transit.
  static CborBytes encodeFloat32(double value) {
    final byteData = ByteData(4)..setFloat32(0, value, Endian.little);
    return CborBytes(byteData.buffer.asUint8List().toList());
  }

  static double decodeFloat32(CborValue cbor) {
    final bytes = Uint8List.fromList((cbor as CborBytes).bytes);
    return ByteData.view(bytes.buffer).getFloat32(0, Endian.little);
  }
}

// Map Keys
const _kLat = CborSmallInt(0);
const _kLon = CborSmallInt(1);
const _kHeadcount = CborSmallInt(2);
const _kReporterDeviceId = CborSmallInt(3);
const _kHazardType = CborSmallInt(4);
const _kConfirmationCount = CborSmallInt(5);
const _kCategory = CborSmallInt(6);
const _kPledgedCount = CborSmallInt(7);
const _kClaimedReports = CborSmallInt(8);
const _kProxyNote = CborSmallInt(9);
const _kNote = CborSmallInt(10);

class SosPayload extends ClaimPayload {
  final GeoPoint location;
  final HeadcountBucket? headcount;

  const SosPayload({
    required this.location,
    this.headcount,
  });

  @override
  CborValue toCbor() {
    return CborMap({
      _kLat: ClaimPayload.encodeFloat32(location.lat),
      _kLon: ClaimPayload.encodeFloat32(location.lon),
      if (headcount != null) _kHeadcount: CborSmallInt(headcount!.index),
    });
  }

  factory SosPayload.fromCbor(CborMap map) {
    final lat = ClaimPayload.decodeFloat32(map[_kLat]!);
    final lon = ClaimPayload.decodeFloat32(map[_kLon]!);
    
    HeadcountBucket? hc;
    if (map.containsKey(_kHeadcount)) {
      hc = HeadcountBucket.values[(map[_kHeadcount] as CborSmallInt).value];
    }

    return SosPayload(
      location: GeoPoint(lat: lat, lon: lon),
      headcount: hc,
    );
  }
}

class SosProxyPayload extends ClaimPayload {
  final GeoPoint location;
  final HeadcountBucket? headcount;
  final String reporterDeviceId;
  final String? proxyNote;

  const SosProxyPayload({
    required this.location,
    this.headcount,
    required this.reporterDeviceId,
    this.proxyNote,
  });

  @override
  CborValue toCbor() {
    return CborMap({
      _kLat: ClaimPayload.encodeFloat32(location.lat),
      _kLon: ClaimPayload.encodeFloat32(location.lon),
      _kReporterDeviceId: CborString(reporterDeviceId),
      if (headcount != null) _kHeadcount: CborSmallInt(headcount!.index),
      if (proxyNote != null) _kProxyNote: CborString(proxyNote!),
    });
  }

  factory SosProxyPayload.fromCbor(CborMap map) {
    final lat = ClaimPayload.decodeFloat32(map[_kLat]!);
    final lon = ClaimPayload.decodeFloat32(map[_kLon]!);
    final reporterDeviceId = (map[_kReporterDeviceId] as CborString).toString();
    
    HeadcountBucket? hc;
    if (map.containsKey(_kHeadcount)) {
      hc = HeadcountBucket.values[(map[_kHeadcount] as CborSmallInt).value];
    }
    
    String? proxyNote;
    if (map.containsKey(_kProxyNote)) {
      proxyNote = (map[_kProxyNote] as CborString).toString();
    }

    return SosProxyPayload(
      location: GeoPoint(lat: lat, lon: lon),
      headcount: hc,
      reporterDeviceId: reporterDeviceId,
      proxyNote: proxyNote,
    );
  }
}

class HazardReportPayload extends ClaimPayload {
  final GeoPoint location;
  final HazardType hazardType;
  final int confirmationCount;
  final String? note;

  const HazardReportPayload({
    required this.location,
    required this.hazardType,
    required this.confirmationCount,
    this.note,
  });

  @override
  CborValue toCbor() {
    return CborMap({
      _kLat: ClaimPayload.encodeFloat32(location.lat),
      _kLon: ClaimPayload.encodeFloat32(location.lon),
      _kHazardType: CborSmallInt(hazardType.index),
      _kConfirmationCount: CborSmallInt(confirmationCount),
      if (note != null) _kNote: CborString(note!),
    });
  }

  factory HazardReportPayload.fromCbor(CborMap map) {
    final lat = ClaimPayload.decodeFloat32(map[_kLat]!);
    final lon = ClaimPayload.decodeFloat32(map[_kLon]!);
    final typeIdx = (map[_kHazardType] as CborSmallInt).value;
    
    final CborValue countVal = map[_kConfirmationCount]!;
    int count = countVal is CborSmallInt ? countVal.value : (countVal as CborInt).toInt();

    String? note;
    if (map.containsKey(_kNote)) {
      note = (map[_kNote] as CborString).toString();
    }

    return HazardReportPayload(
      location: GeoPoint(lat: lat, lon: lon),
      hazardType: HazardType.values[typeIdx],
      confirmationCount: count,
      note: note,
    );
  }
}

class ResourcePayload extends ClaimPayload {
  final GeoPoint location;
  final ResourceCategory category;
  final int pledgedCount;
  final int claimedReports;

  const ResourcePayload({
    required this.location,
    required this.category,
    required this.pledgedCount,
    required this.claimedReports,
  });

  int get available => pledgedCount > claimedReports ? pledgedCount - claimedReports : 0;

  @override
  CborValue toCbor() {
    return CborMap({
      _kLat: ClaimPayload.encodeFloat32(location.lat),
      _kLon: ClaimPayload.encodeFloat32(location.lon),
      _kCategory: CborSmallInt(category.index),
      _kPledgedCount: CborSmallInt(pledgedCount),
      _kClaimedReports: CborSmallInt(claimedReports),
    });
  }

  factory ResourcePayload.fromCbor(CborMap map) {
    final lat = ClaimPayload.decodeFloat32(map[_kLat]!);
    final lon = ClaimPayload.decodeFloat32(map[_kLon]!);
    final catIdx = (map[_kCategory] as CborSmallInt).value;
    
    final CborValue pledgedVal = map[_kPledgedCount]!;
    int pledged = pledgedVal is CborSmallInt ? pledgedVal.value : (pledgedVal as CborInt).toInt();

    final CborValue claimedVal = map[_kClaimedReports]!;
    int claimed = claimedVal is CborSmallInt ? claimedVal.value : (claimedVal as CborInt).toInt();

    return ResourcePayload(
      location: GeoPoint(lat: lat, lon: lon),
      category: ResourceCategory.values[catIdx],
      pledgedCount: pledged,
      claimedReports: claimed,
    );
  }
}
