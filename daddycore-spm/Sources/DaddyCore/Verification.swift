import Foundation

/// Whether anything outside the agent has confirmed the work.
///
/// "The agent stopped talking" and "the work is correct" are different facts,
/// and `AgentState` only ever knew the first one. A card that goes quiet and
/// green after the agent says *all tests pass* is reporting the agent's
/// account of itself, which is the one source with an interest in the answer.
///
/// The failure this guards against is narrower and more common than lying. An
/// agent forms a hypothesis, looks for evidence of it, finds some, fixes what
/// it found, runs a check its fix passes, and reports success. Every statement
/// is true. The selection is what is wrong. So this type cannot be set from a
/// claim — only from a command's exit code, via `recording(exitCode:…)`.
public struct Verification: Codable, Sendable, Equatable {

    public enum Outcome: String, Codable, Sendable {
        /// Nothing has been run.
        case unverified

        /// A check is in flight.
        case running

        /// A check exited zero.
        case passed

        /// A check exited non-zero.
        case failed

        /// It passed, and then the tree moved underneath it.
        ///
        /// A pass is a statement about a specific state of the code. Keeping
        /// the green badge after the next edit is how "verified" quietly comes
        /// to mean "was verified once".
        case stale
    }

    public private(set) var outcome: Outcome

    /// What a pass would have to cover here, from the session's build policy.
    /// A pass under `.targeted` is not the same claim as one under `.broad`,
    /// and a badge that does not say which is overstating the weaker one.
    public var profile: VerificationProfile

    /// The command whose exit code decided this.
    public private(set) var command: String?

    /// A short human line — "12/12 targeted tests", "3 failures in AuthTests".
    /// Display only; it is never what decides `outcome`.
    public private(set) var summary: String?

    public private(set) var checkedAt: Date?

    public init(profile: VerificationProfile) {
        self.outcome = .unverified
        self.profile = profile
    }

    /// Whether this session may be described as verified right now.
    public var isVerified: Bool { outcome == .passed }

    /// What the card should say.
    public var displayName: String {
        switch outcome {
        case .unverified: return profile == .none ? "Unverifiable" : "Unverified"
        case .running: return "Verifying"
        case .passed: return "Verified"
        case .failed: return "Failed"
        case .stale: return "Stale"
        }
    }

    // MARK: Transitions

    public mutating func markRunning(command: String?) {
        outcome = .running
        self.command = command
        summary = nil
        checkedAt = nil
    }

    /// The only way to reach `.passed`.
    ///
    /// Takes the exit code rather than a `Bool` on purpose. A `Bool` parameter
    /// is something a caller can compute from anything at all, including an
    /// agent's own report of how it went; an exit code has to have come from a
    /// process that actually ran.
    public mutating func record(exitCode: Int32, command: String?, summary: String? = nil) {
        outcome = exitCode == 0 ? .passed : .failed
        self.command = command
        self.summary = summary
        checkedAt = Date()
    }

    /// Point this at a different bar, because the session's build policy
    /// changed under it.
    ///
    /// A pass earned under `.targeted` is not a pass under `.broad` — it is
    /// the same evidence being asked to support a larger claim. Raising the
    /// bar therefore stales it; lowering the bar does not, because what was
    /// already proved is still proved.
    public mutating func retarget(to newProfile: VerificationProfile) {
        guard newProfile != profile else { return }
        let wasWeaker = profile.rank < newProfile.rank
        profile = newProfile
        if wasWeaker { invalidate() }
    }

    /// Call when the tree changes after a pass.
    ///
    /// Only a pass can go stale. A failure stays a failure until something is
    /// run again, because an edit is not evidence that the failure is gone.
    public mutating func invalidate() {
        guard outcome == .passed else { return }
        outcome = .stale
    }

    /// Non-mutating form, for building one in an expression.
    public func recording(exitCode: Int32, command: String?, summary: String? = nil) -> Verification {
        var copy = self
        copy.record(exitCode: exitCode, command: command, summary: summary)
        return copy
    }
}
