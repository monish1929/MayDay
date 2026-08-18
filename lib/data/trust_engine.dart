// lib/data/trust_engine.dart

import 'enums.dart';
import 'models/claim.dart';
import 'models/corroboration.dart';

class TrustEngine {
  /// The score required to move a claim from UNCONFIRMED to CORROBORATED.
  static const double corroboratedThreshold = 2.0;

  /// The maximum trust score a single device can contribute.
  static const double maxContributionPerDevice = 1.0;

  /// Recomputes and applies the trust state and dispatch priority for a given claim,
  /// based on its corroborations.
  static void recomputeTrustAndPriority(
      Claim claim, {
      required bool Function(String deviceId) isNewcomer,
  }) {
    _updateDispatchPriority(claim);
    _updateTrust(claim, isNewcomer);
  }

  /// Upgrades a claim to GROUND_CONFIRMED.
  /// This can only be done by a volunteer explicitly confirming on site.
  static void markGroundConfirmed(Claim claim, String volunteerDeviceId) {
    // No stage skipping: can only move to GROUND_CONFIRMED if it's at least CORROBORATED.
    // Actually, can a volunteer arrive at an UNCONFIRMED claim and immediately ground confirm it?
    // "UNCONFIRMED → CORROBORATED → GROUND_CONFIRMED, no stage skipping"
    // So if it's unconfirmed, we must push it to corroborated first, then ground confirmed.
    if (claim.claimTrust == ClaimTrust.unconfirmed) {
      claim.claimTrust = ClaimTrust.corroborated;
    }
    claim.claimTrust = ClaimTrust.groundConfirmed;
    
    // As a side effect, priority might move to enRoute or similar, but the user specifies that
    // explicitly elsewhere.
  }

  static void _updateDispatchPriority(Claim claim) {
    // If priority is already enRoute, we don't downgrade it back to seenByVolunteer.
    if (claim.dispatchPriority == DispatchPriority.enRoute) {
      return;
    }

    // A volunteer seeing a claim raises priority, never trust
    bool seenByVolunteer = claim.corroborations.any((c) => c.isVolunteer);
    if (seenByVolunteer && claim.dispatchPriority == DispatchPriority.low) {
      claim.dispatchPriority = DispatchPriority.seenByVolunteer;
    }
  }

  static void _updateTrust(Claim claim, bool Function(String deviceId) isNewcomer) {
    // No going back from GROUND_CONFIRMED
    if (claim.claimTrust == ClaimTrust.groundConfirmed) {
      return;
    }

    double totalTrustScore = _calculateTrustScore(claim, isNewcomer);

    if (claim.claimTrust == ClaimTrust.unconfirmed && totalTrustScore >= corroboratedThreshold) {
      claim.claimTrust = ClaimTrust.corroborated;
    }
  }

  static double _calculateTrustScore(Claim claim, bool Function(String deviceId) isNewcomer) {
    Map<String, double> deviceContributions = {};

    for (var c in claim.corroborations) {
      // 1. Anti-echo rule: if this device first saw the claim from the mesh, 
      // their attestation doesn't count for trust.
      if (c.firstSeenVia != null) {
        continue;
      }

      // 2. Only two things raise trust: independentGeneration and explicitAttestation
      if (c.kind != CorroborationKind.independentGeneration &&
          c.kind != CorroborationKind.explicitAttestation) {
        continue;
      }

      // 3. Weighting by hopDistance and signalStrength
      double hopWeight = 1.0 / (c.hopDistance + 1);
      
      // Assume signal strength is roughly bounded [0, 1] for this calculation, 
      // or we can just add a flat multiplier.
      // If signal strength isn't known, default to 1.0. 
      // Let's assume signal strength is normalized 0.0 to 1.0
      double signalWeight = c.signalStrength > 0.0 ? c.signalStrength : 1.0;

      double score = hopWeight * signalWeight;

      // 4. Newcomer discount: a device unseen before the claim existed carries little weight
      if (isNewcomer(c.deviceId)) {
        score *= 0.1; // drastic reduction
      }

      // 5. Per-device contribution cap
      double currentContribution = deviceContributions[c.deviceId] ?? 0.0;
      double newContribution = (currentContribution + score).clamp(0.0, maxContributionPerDevice);
      deviceContributions[c.deviceId] = newContribution;
    }

    return deviceContributions.values.fold(0.0, (a, b) => a + b);
  }
}
