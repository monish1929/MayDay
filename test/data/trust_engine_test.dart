// test/data/trust_engine_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:mayday/data/trust_engine.dart';
import 'package:mayday/data/models/claim.dart';
import 'package:mayday/data/models/corroboration.dart';
import 'package:mayday/data/models/logical_clock.dart';
import 'package:mayday/data/enums.dart';
import 'package:mayday/data/models/claim_payload.dart';
import 'package:mayday/data/models/geo_point.dart';

void main() {
  group('Trust Engine State Machine', () {
    late Claim baseClaim;

    setUp(() {
      baseClaim = Claim(
        id: 'test_claim',
        type: ClaimType.hazardReport,
        originDeviceId: 'device1',
        originSignature: 'sig',
        logicalClock: LogicalClock(deviceId: 'device1', counter: 1),
        claimTrust: ClaimTrust.unconfirmed,
        dispatchPriority: DispatchPriority.low,
        status: ClaimStatus.active,
        hopLimit: 10,
        displayLifetime: const Duration(hours: 1),
        payload: HazardReportPayload(
          location: const GeoPoint(lat: 0, lon: 0),
          hazardType: HazardType.other,
          confirmationCount: 1,
        ),
        corroborations: [],
      );
    });

    test('UNCONFIRMED → CORROBORATED when threshold is met', () {
      baseClaim.corroborations = [
        Corroboration(
          deviceId: 'device2',
          hopDistance: 0,
          signalStrength: 1.0,
          logicalClock: LogicalClock(deviceId: 'device2', counter: 1),
          isVolunteer: false,
          kind: CorroborationKind.independentGeneration,
        ),
        Corroboration(
          deviceId: 'device3',
          hopDistance: 0,
          signalStrength: 1.0,
          logicalClock: LogicalClock(deviceId: 'device3', counter: 1),
          isVolunteer: false,
          kind: CorroborationKind.explicitAttestation,
        ),
      ];

      TrustEngine.recomputeTrustAndPriority(baseClaim, isNewcomer: (_) => false);
      expect(baseClaim.claimTrust, equals(ClaimTrust.corroborated));
    });

    test('Relaying (not independent or explicit) does not raise trust', () {
      // Assuming if it were relaying, it wouldn't have CorroborationKind as one of the two allowed types.
      // But since we can't create one with an invalid kind (it's an enum), we test firstSeenVia (Anti-echo).
      baseClaim.corroborations = [
        Corroboration(
          deviceId: 'device2',
          hopDistance: 0,
          signalStrength: 1.0,
          firstSeenVia: 'device4', // This means they learned about it from mesh
          logicalClock: LogicalClock(deviceId: 'device2', counter: 1),
          isVolunteer: false,
          kind: CorroborationKind.explicitAttestation,
        ),
        Corroboration(
          deviceId: 'device3',
          hopDistance: 0,
          signalStrength: 1.0,
          firstSeenVia: 'device4',
          logicalClock: LogicalClock(deviceId: 'device3', counter: 1),
          isVolunteer: false,
          kind: CorroborationKind.independentGeneration, // Contradictory but possible if malformed
        ),
      ];

      TrustEngine.recomputeTrustAndPriority(baseClaim, isNewcomer: (_) => false);
      expect(baseClaim.claimTrust, equals(ClaimTrust.unconfirmed), reason: 'Anti-echo rule must prevent corroboration from counting');
    });

    test('Anti-echo rule: firstSeenVia excludes corroboration from trust score', () {
      baseClaim.corroborations = [
        Corroboration(
          deviceId: 'device2',
          hopDistance: 0,
          signalStrength: 1.0,
          logicalClock: LogicalClock(deviceId: 'device2', counter: 1),
          isVolunteer: false,
          kind: CorroborationKind.independentGeneration, // Counts
        ),
        Corroboration(
          deviceId: 'device3',
          hopDistance: 0,
          signalStrength: 1.0,
          firstSeenVia: 'mesh_relay', // Does not count
          logicalClock: LogicalClock(deviceId: 'device3', counter: 1),
          isVolunteer: false,
          kind: CorroborationKind.explicitAttestation, 
        ),
      ];

      TrustEngine.recomputeTrustAndPriority(baseClaim, isNewcomer: (_) => false);
      // Only 1 point of trust, threshold is 2.0
      expect(baseClaim.claimTrust, equals(ClaimTrust.unconfirmed));
    });

    test('Volunteer seeing a claim raises dispatchPriority, not trust', () {
      baseClaim.corroborations = [
        Corroboration(
          deviceId: 'device_vol',
          hopDistance: 2,
          signalStrength: 0.5,
          firstSeenVia: 'relay', // Does not count for trust
          logicalClock: LogicalClock(deviceId: 'device_vol', counter: 1),
          isVolunteer: true,
          kind: CorroborationKind.explicitAttestation,
        ),
      ];

      TrustEngine.recomputeTrustAndPriority(baseClaim, isNewcomer: (_) => false);
      
      expect(baseClaim.claimTrust, equals(ClaimTrust.unconfirmed));
      expect(baseClaim.dispatchPriority, equals(DispatchPriority.seenByVolunteer));
    });

    test('GROUND_CONFIRMED cannot be downgraded', () {
      baseClaim.claimTrust = ClaimTrust.groundConfirmed;
      // Empty corroborations wouldn't naturally support corroboration, but it shouldn't matter
      
      TrustEngine.recomputeTrustAndPriority(baseClaim, isNewcomer: (_) => false);
      expect(baseClaim.claimTrust, equals(ClaimTrust.groundConfirmed));
    });
    
    test('markGroundConfirmed upgrades trust', () {
      TrustEngine.markGroundConfirmed(baseClaim, 'volunteer1');
      expect(baseClaim.claimTrust, equals(ClaimTrust.groundConfirmed));
    });

    test('Newcomer discount heavily reduces score', () {
      baseClaim.corroborations = [
        Corroboration(
          deviceId: 'device2',
          hopDistance: 0,
          signalStrength: 1.0,
          logicalClock: LogicalClock(deviceId: 'device2', counter: 1),
          isVolunteer: false,
          kind: CorroborationKind.independentGeneration,
        ),
        Corroboration(
          deviceId: 'device3',
          hopDistance: 0,
          signalStrength: 1.0,
          logicalClock: LogicalClock(deviceId: 'device3', counter: 1),
          isVolunteer: false,
          kind: CorroborationKind.independentGeneration,
        ),
      ];

      // If they are newcomers, they each contribute 0.1 instead of 1.0. Total 0.2 < 2.0
      TrustEngine.recomputeTrustAndPriority(baseClaim, isNewcomer: (_) => true);
      expect(baseClaim.claimTrust, equals(ClaimTrust.unconfirmed));
    });

    test('Weighting by hopDistance works', () {
      // 5 devices, but very far away (hopDistance 4 -> weight 0.2 each, total 1.0 < 2.0)
      for (int i = 0; i < 5; i++) {
        baseClaim.corroborations.add(
          Corroboration(
            deviceId: 'device$i',
            hopDistance: 4, 
            signalStrength: 1.0,
            logicalClock: LogicalClock(deviceId: 'device$i', counter: 1),
            isVolunteer: false,
            kind: CorroborationKind.independentGeneration,
          ),
        );
      }
      
      TrustEngine.recomputeTrustAndPriority(baseClaim, isNewcomer: (_) => false);
      expect(baseClaim.claimTrust, equals(ClaimTrust.unconfirmed));

      // Closer devices (hopDistance 0 -> weight 1.0 each. 2 devices = 2.0 -> corroborated)
      baseClaim.corroborations = [
        Corroboration(
          deviceId: 'deviceA',
          hopDistance: 0, 
          signalStrength: 1.0,
          logicalClock: LogicalClock(deviceId: 'deviceA', counter: 1),
          isVolunteer: false,
          kind: CorroborationKind.independentGeneration,
        ),
        Corroboration(
          deviceId: 'deviceB',
          hopDistance: 0, 
          signalStrength: 1.0,
          logicalClock: LogicalClock(deviceId: 'deviceB', counter: 1),
          isVolunteer: false,
          kind: CorroborationKind.independentGeneration,
        )
      ];
      TrustEngine.recomputeTrustAndPriority(baseClaim, isNewcomer: (_) => false);
      expect(baseClaim.claimTrust, equals(ClaimTrust.corroborated));
    });
  });
}
