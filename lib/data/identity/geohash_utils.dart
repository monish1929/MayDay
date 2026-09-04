// lib/data/identity/geohash_utils.dart

import 'package:dart_geohash/dart_geohash.dart';
import '../models/geo_point.dart';

/// Geohash bucketing at 7 chars (~150m)
/// 
/// CLAIM_SCHEMA.md §2:
/// Geohash bucket size: 150–300m. This is deliberately coarse for hazards/resources 
/// (merging is the goal) and is exactly why SOS cannot share this scheme.
String getGeohashBucket(GeoPoint location) {
  final hasher = GeoHasher();
  // dart_geohash takes longitude, latitude
  final hash = hasher.encode(location.lon, location.lat, precision: 7);
  return hash;
}
