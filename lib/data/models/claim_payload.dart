// lib/data/models/claim_payload.dart

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
}

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
      CborString('lat'): CborFloat(location.lat),
      CborString('lon'): CborFloat(location.lon),
      if (headcount != null) CborString('headcount'): CborSmallInt(headcount!.index),
    });
  }

  factory SosPayload.fromCbor(CborMap map) {
    final lat = (map[CborString('lat')] as CborFloat).value;
    final lon = (map[CborString('lon')] as CborFloat).value;
    
    HeadcountBucket? hc;
    if (map.containsKey(CborString('headcount'))) {
      hc = HeadcountBucket.values[(map[CborString('headcount')] as CborSmallInt).value];
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
      CborString('lat'): CborFloat(location.lat),
      CborString('lon'): CborFloat(location.lon),
      CborString('reporterDeviceId'): CborString(reporterDeviceId),
      if (headcount != null) CborString('headcount'): CborSmallInt(headcount!.index),
    });
  }

  factory SosProxyPayload.fromCbor(CborMap map) {
    final lat = (map[CborString('lat')] as CborFloat).value;
    final lon = (map[CborString('lon')] as CborFloat).value;
    final reporterDeviceId = (map[CborString('reporterDeviceId')] as CborString).toString();
    
    HeadcountBucket? hc;
    if (map.containsKey(CborString('headcount'))) {
      hc = HeadcountBucket.values[(map[CborString('headcount')] as CborSmallInt).value];
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
      CborString('lat'): CborFloat(location.lat),
      CborString('lon'): CborFloat(location.lon),
      CborString('hazardType'): CborSmallInt(hazardType.index),
      CborString('confirmationCount'): CborSmallInt(confirmationCount),
    });
  }

  factory HazardReportPayload.fromCbor(CborMap map) {
    final lat = (map[CborString('lat')] as CborFloat).value;
    final lon = (map[CborString('lon')] as CborFloat).value;
    final typeIdx = (map[CborString('hazardType')] as CborSmallInt).value;
    
    // confirmationCount can be CborSmallInt or CborInt depending on size
    final CborValue countVal = map[CborString('confirmationCount')]!;
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

  // Display-time computed availability per schema §8.1
  int get available => pledgedCount > claimedReports ? pledgedCount - claimedReports : 0;

  @override
  CborValue toCbor() {
    return CborMap({
      CborString('lat'): CborFloat(location.lat),
      CborString('lon'): CborFloat(location.lon),
      CborString('category'): CborSmallInt(category.index),
      CborString('pledgedCount'): CborSmallInt(pledgedCount),
      CborString('claimedReports'): CborSmallInt(claimedReports),
    });
  }

  factory ResourcePayload.fromCbor(CborMap map) {
    final lat = (map[CborString('lat')] as CborFloat).value;
    final lon = (map[CborString('lon')] as CborFloat).value;
    final catIdx = (map[CborString('category')] as CborSmallInt).value;
    
    final CborValue pledgedVal = map[CborString('pledgedCount')]!;
    int pledged = pledgedVal is CborSmallInt ? pledgedVal.value : (pledgedVal as CborInt).toInt();

    final CborValue claimedVal = map[CborString('claimedReports')]!;
    int claimed = claimedVal is CborSmallInt ? claimedVal.value : (claimedVal as CborInt).toInt();

    return ResourcePayload(
      location: GeoPoint(lat: lat, lon: lon),
      category: ResourceCategory.values[catIdx],
      pledgedCount: pledged,
      claimedReports: claimed,
    );
  }
}
