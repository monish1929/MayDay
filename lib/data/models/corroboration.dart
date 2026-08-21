// lib/data/models/corroboration.dart

import '../enums.dart';
import 'logical_clock.dart';

class Corroboration {
  final String deviceId;
  final int hopDistance;
  final double? signalStrength;
  final String? firstSeenVia;
  final LogicalClock logicalClock;
  final bool isVolunteer;
  final CorroborationKind kind;

  const Corroboration({
    required this.deviceId,
    required this.hopDistance,
    this.signalStrength,
    this.firstSeenVia,
    required this.logicalClock,
    required this.isVolunteer,
    required this.kind,
  });
}
