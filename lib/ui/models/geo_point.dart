/// A geographic coordinate — CLAIM_SCHEMA.md §9.2.
/// Two floats (not doubles): ~1m precision is plenty at a 150m geohash bucket.
class GeoPoint {
  final double lat;
  final double lon;

  const GeoPoint({required this.lat, required this.lon});

  @override
  String toString() => 'GeoPoint($lat, $lon)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeoPoint && lat == other.lat && lon == other.lon;

  @override
  int get hashCode => Object.hash(lat, lon);
}
