import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cbor/cbor.dart';
import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';
import 'package:mayday/data/enums.dart';

void main() {
  test('Claim.toSignedCoreCbor produces expected array', () {
    final claim = Claim(
      id: 'test-id',
      type: ClaimType.sos,
      originDeviceId: 'dev-1',
      originSequence: 1,
      originSignature: Uint8List(64),
      logicalClock: LogicalClock(deviceId: 'dev-1', counter: 1),
      claimTrust: ClaimTrust.unconfirmed,
      dispatchPriority: DispatchPriority.low,
      status: ClaimStatus.active,
      hopLimit: 5,
      createdAtLogical: LogicalClock(deviceId: 'dev-1', counter: 1),
      payload: SosPayload(location: GeoPoint(lat: 1.0, lon: 2.0)),
    );

    final cbor = claim.toSignedCoreCbor() as CborList;
    expect(cbor.length, 6);
    expect((cbor[0] as CborString).toString(), 'test-id');
    expect((cbor[1] as CborSmallInt).value, ClaimType.sos.index);
    expect((cbor[2] as CborString).toString(), 'dev-1');
    
    final clockCbor = cbor[3] as CborList;
    expect((clockCbor[0] as CborString).toString(), 'dev-1');
    expect((clockCbor[1] as CborSmallInt).value, 1);
  });
}
