import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/enums.dart';
import 'package:cbor/cbor.dart';
import 'dart:io';

void main() {
  final loc = const GeoPoint(lat: 12.9716, lon: 77.5946);
  
  final sos = SosPayload(location: loc, headcount: HeadcountBucket.twoToFive).toCbor();
  final sosProxy = SosProxyPayload(location: loc, headcount: HeadcountBucket.twoToFive, reporterDeviceId: 'device_xyz_123').toCbor();
  final hazard = HazardReportPayload(location: loc, hazardType: HazardType.flood, confirmationCount: 10).toCbor();
  final resource = ResourcePayload(location: loc, category: ResourceCategory.foodWater, pledgedCount: 50, claimedReports: 20).toCbor();

  print('SOS: ${cbor.encode(sos).length} bytes');
  print('SOS_PROXY: ${cbor.encode(sosProxy).length} bytes');
  print('HAZARD_REPORT: ${cbor.encode(hazard).length} bytes');
  print('RESOURCE: ${cbor.encode(resource).length} bytes');
}
