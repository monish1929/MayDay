// lib/data/enums.dart

enum ClaimType { sos, sosProxy, hazardReport, resource }
enum ClaimTrust { unconfirmed, corroborated, groundConfirmed }
enum DispatchPriority { low, seenByVolunteer, enRoute }
enum ClaimStatus { active, resolved, archived }
enum ResolutionMethod { qr, manual, autoExpired }
enum CorroborationKind { independentGeneration, explicitAttestation }
enum HeadcountBucket { twoToFive, sixToFifteen, fifteenPlus }
enum HazardType { flood, roadBlock, structuralDamage, other }
enum ResourceCategory { foodWater, shelter, medical, equipment }
