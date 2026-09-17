// lib/identity/node_trust.dart

/// Confidence in a **person/device** — `node_trust` in CLAUDE.md §7's naming
/// table.
///
/// **Not `claimTrust`.** That one answers "is this claim true"; this one
/// answers "is this device someone the mesh should let act". v1 of the design
/// used "trust tier" for both and it caused real confusion — keep them apart.
///
/// Canonical values, fixed by CLAIM_SCHEMA.md §11: it names exactly
/// `campaignVerified | vouchedProvisional | unverified` and says the enum
/// lives in the identity model rather than in the claim schema. Adding a
/// value here is a §11 team-sync change, not a local decision.
enum NodeTrust {
  /// Registered and verified before the disaster, during the readiness
  /// campaign (MAYDAY_PROJECT_CONTEXT.md §2.1). The credential is the
  /// campaign organiser's signature over this device's public key.
  campaignVerified,

  /// Onboarded mid-disaster by a vouch from a campaign-verified volunteer
  /// (§2.2). May respond to SOS and record ground confirmations. **May not
  /// vouch for anyone else** — that is what stops one compromised phone
  /// minting unbounded trust.
  vouchedProvisional,

  /// Everyone else. The default, and the state every device starts in.
  unverified,
}

/// Why a vouch was withdrawn. Travels inside the signed revocation so a
/// receiving device can distinguish "this person turned out to be a fraud"
/// from "this person went home", without asking anyone.
///
/// The distinction is advisory only: **every reason revokes**. Nothing in the
/// registry branches on it, and nothing should — a revocation that only
/// sometimes revoked would be worse than none.
enum RevocationReason {
  /// The voucher no longer stands behind the person.
  withdrawn,

  /// The key is believed to be in someone else's hands.
  compromised,

  /// The volunteer has left the response.
  standDown,
}

/// What a device is allowed to do, derived from its [NodeTrust] and the
/// vouches standing behind it.
///
/// Separate from the enum because MAYDAY_PROJECT_CONTEXT.md §2.2 gates
/// *powers*, not tiers: one vouch buys SOS response, two independent
/// campaign-verified vouches additionally buy resource pledging. Expressing
/// that as capabilities keeps CLAIM_SCHEMA.md §11's three canonical enum
/// values intact — see [canPledgeResources] for the drift this deliberately
/// avoids papering over.
class NodeCapabilities {
  final NodeTrust trust;

  /// Vouches currently standing (not revoked) from **campaign-verified**
  /// vouchers, counted one per distinct voucher.
  final int standingVouches;

  const NodeCapabilities({
    required this.trust,
    required this.standingVouches,
  });

  /// Unvouched, unverified — the default for a device nobody has spoken for.
  static const NodeCapabilities none = NodeCapabilities(
    trust: NodeTrust.unverified,
    standingVouches: 0,
  );

  /// Counts as a volunteer for routing, beaconing and trust weighting.
  ///
  /// Both verified tiers qualify: §2.2 gives a single vouch the power to
  /// respond to SOS, and a responder the mesh will not route toward is not
  /// actually a responder.
  bool get isVolunteer => trust != NodeTrust.unverified;

  /// May sign a vouch for someone else.
  ///
  /// **Campaign-verified only.** MAYDAY_PROJECT_CONTEXT.md §2.2: "Provisional
  /// nodes cannot vouch for anyone. Prevents unbounded trust minting from a
  /// single compromise." If this ever becomes `isVolunteer`, one stolen phone
  /// can grow an arbitrarily large web of provisional volunteers, and every
  /// device in the mesh will believe all of them.
  bool get canVouch => trust == NodeTrust.campaignVerified;

  /// May respond to an SOS and record ground confirmations.
  bool get canRespondToSos => isVolunteer;

  /// May write `pledgedCount` — the authoritative resource figure (§7).
  ///
  /// Campaign-verified always; a provisional node only once **two independent
  /// campaign-verified volunteers** have vouched for it (§2.2). Resource
  /// pledging is the spam-sensitive power, so it stays gated behind a higher
  /// bar than SOS response.
  ///
  /// **Known doc drift, flagged not resolved (CLAUDE.md §8):**
  /// MAYDAY_PROJECT_CONTEXT.md §2.2 calls the two-vouch state "promoted to
  /// full trust", but CLAIM_SCHEMA.md §11 fixes `NodeTrust` at three values
  /// with no slot for it. Rather than invent a fourth value — a §11 change
  /// needs all three people — the promotion is expressed here as a capability
  /// and the tier stays `vouchedProvisional`. Raise it at the next team sync;
  /// do not quietly add an enum value to "fix" it.
  static const int vouchesForResourcePledging = 2;

  bool get canPledgeResources {
    if (trust == NodeTrust.campaignVerified) return true;
    return trust == NodeTrust.vouchedProvisional &&
        standingVouches >= vouchesForResourcePledging;
  }

  @override
  String toString() =>
      'NodeCapabilities(${trust.name}, vouches=$standingVouches, '
      'volunteer=$isVolunteer, canVouch=$canVouch, '
      'canPledge=$canPledgeResources)';
}

/// Answers "what is this device allowed to do" for a raw Ed25519 public key.
///
/// An interface rather than a concrete class because `mesh/` needs the answer
/// at several points — beacon acceptance, resolution counter-signing, trust
/// weighting — and none of them should depend on how the answer is stored.
abstract class NodeTrustDirectory {
  /// Never throws and never returns null: an unknown key is
  /// [NodeCapabilities.none], which is the safe answer and the common one.
  Future<NodeCapabilities> capabilitiesOf(List<int> publicKey);
}
