// lib/data/time/decay.dart

import '../enums.dart';

/// Defines the display lifetime (decay window) for each claim type.
/// A null return indicates the claim type never decays (e.g. SOS).
Duration? displayLifetimeFor(ClaimType type) {
  switch (type) {
    case ClaimType.sos:
    case ClaimType.sosProxy:
      // §7: displayLifetimeFor(type) returns null for SOS types
      return null;
    case ClaimType.hazardReport:
      // Hazard: long window. Value TBD.
      return hazardDisplayLifetime;
    case ClaimType.resource:
      // Resource: shortest window. Value TBD.
      return resourceDisplayLifetime;
  }
}

// TODO: Values TBD, flag for review in team sync
const Duration hazardDisplayLifetime = Duration(hours: 48);
const Duration resourceDisplayLifetime = Duration(hours: 4);
