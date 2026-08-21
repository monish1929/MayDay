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

  // Utility to strictly encode 32-bit float as a 4-byte CBOR byte string
  // to avoid cbor package defaulting to 8-byte doubles.
  static CborBytes encodeFloat32(double value) {
    final bytes = Float32List.fromList([value]).buffer.asUint8List();
    return CborBytes(bytes.toList());
  }

  static double decodeFloat32(CborValue cbor) {
    final bytes = Uint8List.fromList((cbor as CborBytes).bytes);
    return Float32List.view(bytes.buffer)[0];
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

  const SosProxyPayload({
    required this.location,
    this.headcount,
    required this.reporterDeviceId,
  });

  @override
  CborValue toCbor() {
    return CborMap({
      _kLat: ClaimPayload.encodeFloat32(location.lat),
      _kLon: ClaimPayload.encodeFloat32(location.lon),
      _kReporterDeviceId: CborString(reporterDeviceId),
      if (headcount != null) _kHeadcount: CborSmallInt(headcount!.index),
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

    return SosProxyPayload(
      location: GeoPoint(lat: lat, lon: lon),
      headcount: hc,
      reporterDeviceId: reporterDeviceId,
    );
  }
}

class HazardReportPayload extends ClaimPayload {
  final GeoPoint location;
  final HazardType hazardType;
  final int confirmationCount;

  const HazardReportPayload({
    required this.location,
    required this.hazardType,
    required this.confirmationCount,
  });

  @override
  CborValue toCbor() {
    return CborMap({
      _kLat: ClaimPayload.encodeFloat32(location.lat),
      _kLon: ClaimPayload.encodeFloat32(location.lon),
      _kHazardType: CborSmallInt(hazardType.index),
      _kConfirmationCount: CborSmallInt(confirmationCount),
    });
  }

  factory HazardReportPayload.fromCbor(CborMap map) {
    final lat = ClaimPayload.decodeFloat32(map[_kLat]!);
    final lon = ClaimPayload.decodeFloat32(map[_kLon]!);
    final typeIdx = (map[_kHazardType] as CborSmallInt).value;
    
    final CborValue countVal = map[_kConfirmationCount]!;
    int count = countVal is CborSmallInt ? countVal.value : (countVal as CborInt).toInt();

    return HazardReportPayload(
      location: GeoPoint(lat: lat, lon: lon),
      hazardType: HazardType.values[typeIdx],
      confirmationCount: count,
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
