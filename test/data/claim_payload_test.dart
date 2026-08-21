import 'package:flutter_test/flutter_test.dart';
import 'package:cbor/cbor.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/enums.dart';

void main() {
  group('ClaimPayload CBOR encoding', () {
    test('Float32 exact roundtrip with Endian.little', () {
      const testVal = 12.34567;
      final encoded = ClaimPayload.encodeFloat32(testVal);
      final decoded = ClaimPayload.decodeFloat32(encoded);
      expect(decoded, closeTo(testVal, 0.0001));
      expect(encoded.bytes.length, 4);
    });

    test('SosPayload integer keys and float32 sizes', () {
      final payload = SosPayload(
        location: GeoPoint(lat: 40.7128, lon: -74.0060),
        headcount: HeadcountBucket.sixToFifteen,
      );
      final cbor = payload.toCbor() as CborMap;
      expect(cbor.containsKey(CborSmallInt(0)), isTrue);
      expect(cbor.containsKey(CborSmallInt(1)), isTrue);
      expect(cbor.containsKey(CborSmallInt(2)), isTrue);
      expect((cbor[CborSmallInt(0)] as CborBytes).bytes.length, 4);
      expect((cbor[CborSmallInt(1)] as CborBytes).bytes.length, 4);
      final decoded = SosPayload.fromCbor(cbor);
      expect(decoded.location.lat, closeTo(40.7128, 0.0001));
      expect(decoded.location.lon, closeTo(-74.0060, 0.0001));
      expect(decoded.headcount, HeadcountBucket.sixToFifteen);
    });
  });
}
