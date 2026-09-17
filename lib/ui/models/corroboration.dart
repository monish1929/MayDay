import 'enums.dart';
import 'logical_clock.dart';

/// Corroboration record — CLAIM_SCHEMA.md §1.
/// Records a single device's corroboration of a claim.
class Corroboration {
  final String deviceId;
  final int hopDistance;
  final double signalStrength;

  /// DeviceId of whoever relayed it to us — CLAIM_SCHEMA.md §3.2.
  /// NULL if self-generated (independent observation).
  /// Used to enforce the anti-echo rule: a device cannot corroborate a claim
  /// it first learned about from the mesh — CLAUDE.md §2.2.
  final String? firstSeenVia;

  final LogicalClock logicalClock;
  final bool isVolunteer;

  /// Only two kinds exist: independentGeneration and explicitAttestation.
  /// Relaying is deliberately NOT a kind — CLAUDE.md §2.2.
  final CorroborationKind kind;

  const Corroboration({
    required this.deviceId,
    required this.hopDistance,
    required this.signalStrength,
    required this.firstSeenVia,
    required this.logicalClock,
    required this.isVolunteer,
    required this.kind,
  });
}
