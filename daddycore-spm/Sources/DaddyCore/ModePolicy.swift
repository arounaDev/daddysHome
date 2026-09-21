import Foundation

/// The resource policy a `WorkMode` stands for.
///
/// Before this existed, picking a mode changed one string — the text in
/// `WorkMode.systemPrompt` — and nothing else. Targeted and Plan & Build
/// launched the same CLI with the same flags, the same tools and the same
/// licence to run for as long as they liked, and differed only in how politely
/// the prompt asked. That makes the two dropdowns personalities rather than
/// controls.
///
/// A mode is a budget. It says how hard to think, how much of the action space
/// to expose, whether the work may be delegated, and how many times a failed
/// attempt may be retried before the approach itself is the thing that is
/// wrong. Some of that the harness can enforce at launch; the rest can only be
/// said. Both halves come from here so the numbers cannot drift apart.
public struct ModePolicy: Sendable, Equatable, Codable {

    // MARK: Enforced at launch

    /// How hard the model should think. Mapped to each CLI's own flag by the
    /// adapter — `--effort` on Claude, a config override on Codex — and simply
    /// dropped by a CLI that has no equivalent.
    public var effort: Effort

    /// How much of the action space the session gets.
    public var toolProfile: ToolProfile

    /// Whether this mode is meant to change files at all.
    ///
    /// Declarative. It decides what the prompt says and what `SessionPolicy`
    /// can treat as verifiable; on its own it denies nothing.
    public var editsCode: Bool

    /// Whether `editsCode: false` is enforced by denying the editing tools at
    /// launch, rather than being asked for in the prompt.
    ///
    /// Off by default, and deliberately. A hard denial is not a stricter
    /// version of the same thing — it changes what the session *is*. An
    /// Explore session that turns out to need a one-line fix can no longer
    /// make it, cannot be talked into making it, and has to be relaunched to
    /// get the tool back, because a launch flag is not revocable from inside
    /// the conversation. That trade is worth offering and wrong to impose, so
    /// it is a per-session choice and the default is the softer one.
    public var enforcesReadOnly: Bool

    // MARK: Carried by the prompt

    /// Whether the agent may spend context on subagents.
    ///
    /// Not a licence so much as a budget: delegation is how a long, noisy
    /// search stays out of the implementation context, and it is also how a
    /// two-file fix turns into an orchestration festival.
    public var allowsSubagents: Bool

    /// Whether a plan has to be agreed before any code is written.
    public var requiresPlanApproval: Bool

    /// How many times the same failing approach may be retried before the
    /// agent is expected to stop and revise the approach itself.
    ///
    /// The failure this bounds is specific: an agent commits to a wrong
    /// explanation early, and every subsequent edit is made to defend it. A
    /// cap turns that into a forced re-plan instead of a widening blast radius.
    public var maxRepairLoops: Int

    public init(
        effort: Effort,
        toolProfile: ToolProfile,
        editsCode: Bool,
        enforcesReadOnly: Bool = false,
        allowsSubagents: Bool,
        requiresPlanApproval: Bool,
        maxRepairLoops: Int
    ) {
        self.effort = effort
        self.toolProfile = toolProfile
        self.editsCode = editsCode
        self.enforcesReadOnly = enforcesReadOnly
        self.allowsSubagents = allowsSubagents
        self.requiresPlanApproval = requiresPlanApproval
        self.maxRepairLoops = maxRepairLoops
    }

    /// Whether the editing tools should actually be taken away.
    ///
    /// Both halves have to be true: a mode that does not edit, and a session
    /// that asked for that to be enforced.
    public var deniesEditingTools: Bool { !editsCode && enforcesReadOnly }
}

/// How hard the model should think, in the one vocabulary all four CLIs can be
/// mapped onto.
///
/// Deliberately three values rather than Claude's five. The extra rungs are
/// real, but a control plane that has to speak to four CLIs can only promise
/// what all four can approximate, and `xhigh` has no meaning to tell Codex.
public enum Effort: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
}

/// How much of the action space a session is given.
///
/// Every exposed MCP server widens what the model might choose to do and costs
/// its schema in the prompt whether or not it is ever called. A two-file Swift
/// refactor does not need the browser, the database and the design tool in
/// scope; it needs files, shell and git.
public enum ToolProfile: String, Codable, Sendable, CaseIterable {
    /// Built-in tools only — no MCP servers.
    case minimal

    /// Built-ins plus whatever MCP the project configures.
    case standard
}

/// What counts as proof that the work is done.
///
/// Distinct from `BuildPolicy`, which says who is *allowed* to run things.
/// This says what has to pass before "finished" may be claimed — the two are
/// related but not the same, and conflating them is how a session ends with
/// the agent's own assurance standing in for a green build.
public enum VerificationProfile: String, Codable, Sendable, CaseIterable {
    /// Nothing can be checked here. The work is unverified and must say so.
    case none

    /// Build, typecheck, and the tests that cover the change.
    case targeted

    /// The above plus the full suite, and running the thing where that is what
    /// actually demonstrates the fix.
    case broad

    public var displayName: String {
        switch self {
        case .none: return "Unverified"
        case .targeted: return "Targeted"
        case .broad: return "Broad"
        }
    }

    /// How demanding this is, for comparing two of them.
    ///
    /// Not `Comparable`: the ordering is only meaningful for "is this a bigger
    /// claim than that one", and conforming would invite `<` to be used for
    /// things it does not mean.
    var rank: Int {
        switch self {
        case .none: return 0
        case .targeted: return 1
        case .broad: return 2
        }
    }
}

// MARK: - WorkMode policies

extension WorkMode {

    /// The budget this mode stands for.
    public var policy: ModePolicy {
        switch self {
        case .targeted:
            // The whole point of this mode is that the fix costs less than the
            // ceremony around it. High effort and a wide tool surface are the
            // ceremony.
            return ModePolicy(
                effort: .low,
                toolProfile: .minimal,
                editsCode: true,
                allowsSubagents: false,
                requiresPlanApproval: false,
                maxRepairLoops: 2
            )

        case .planAndBuild:
            return ModePolicy(
                effort: .high,
                toolProfile: .standard,
                editsCode: true,
                allowsSubagents: true,
                requiresPlanApproval: true,
                maxRepairLoops: 4
            )

        case .exploreAndResearch:
            // Subagents are on because this is exactly the mode whose
            // searches should happen somewhere other than the context that has
            // to hold the answer.
            //
            // `enforcesReadOnly` stays at its default of false: the mode says
            // it makes no changes, and that is where it stops unless the
            // session opts into the harder version.
            return ModePolicy(
                effort: .medium,
                toolProfile: .standard,
                editsCode: false,
                allowsSubagents: true,
                requiresPlanApproval: false,
                maxRepairLoops: 1
            )

        case .debug:
            // Two attempts per hypothesis, then the hypothesis is what is
            // wrong. Debug is the mode most prone to defending a bad first
            // guess, so it gets the tightest loop cap of the editing modes.
            return ModePolicy(
                effort: .high,
                toolProfile: .standard,
                editsCode: true,
                allowsSubagents: true,
                requiresPlanApproval: false,
                maxRepairLoops: 2
            )
        }
    }
}

// MARK: - BuildPolicy verification

extension BuildPolicy {

    /// What this policy makes it possible to prove.
    public var verification: VerificationProfile {
        switch self {
        case .frozen: return .none
        case .compile: return .targeted
        case .run, .free: return .broad
        }
    }
}

// MARK: - Resolved session policy

/// A work mode and a build policy, resolved against each other.
///
/// They are orthogonal but not independent at the edges: Explore & Research in
/// Free build policy should still not build anything, because there is nothing
/// to build when nothing may be edited. Resolving in one place means the UI,
/// the launch path and the verification badge all read the same answer instead
/// of each re-deriving it slightly differently.
public struct SessionPolicy: Sendable, Equatable {
    public let workMode: WorkMode
    public let buildPolicy: BuildPolicy
    public let mode: ModePolicy
    public let verification: VerificationProfile

    /// `enforceReadOnly` turns a non-editing mode's intent into a launch flag.
    /// Off by default; see `ModePolicy.enforcesReadOnly` for why that is not
    /// simply the timid setting.
    public init(workMode: WorkMode, buildPolicy: BuildPolicy, enforceReadOnly: Bool = false) {
        self.workMode = workMode
        self.buildPolicy = buildPolicy

        var mode = workMode.policy
        mode.enforcesReadOnly = enforceReadOnly && !mode.editsCode
        self.mode = mode

        // A mode that cannot edit has nothing of its own to verify, whatever
        // the build policy would otherwise permit.
        self.verification = mode.editsCode ? buildPolicy.verification : .none
    }

    /// The budget lines that no CLI flag can carry.
    ///
    /// Kept to the differences only — a budget already at its default says
    /// nothing, because spending tokens to say "behave normally" is how a
    /// system prompt becomes a document nobody reads.
    ///
    /// Verification is the one exception: it always speaks, including in the
    /// default combination that otherwise injects nothing. What the agent is
    /// *allowed* to run is not the same statement as what it has to prove
    /// before claiming it is finished, and leaving the second one unsaid is
    /// exactly how a session ends with the agent's own assurance in place of a
    /// green build.
    public var promptClause: String? {
        var lines: [String] = []

        if !mode.allowsSubagents {
            lines.append("Use no subagents; do this work yourself.")
        }
        if mode.requiresPlanApproval {
            lines.append("Agree a plan with me before writing any code.")
        }
        if mode.maxRepairLoops <= 2 {
            lines.append(
                "Retry budget: at most \(mode.maxRepairLoops) attempts at the same "
                + "approach. If it still fails, stop and tell me why the approach "
                + "itself is wrong rather than widening the change."
            )
        }
        if mode.deniesEditingTools {
            lines.append("Change no files. Your editing tools are denied at "
                + "launch, so this is not something to work around.")
        } else if !mode.editsCode {
            lines.append("Change no files. If you believe the answer requires "
                + "one, say what you would change and why, and let me decide.")
        }

        switch verification {
        case .none:
            lines.append("Nothing here can be verified by you. Say plainly that the "
                + "work is unverified and hand me the command to run.")
        case .targeted:
            lines.append("Done means it builds and the tests covering this change "
                + "pass — not that it looks right.")
        case .broad:
            lines.append("Done means it builds, the suite passes, and you have run "
                + "the thing where that is what demonstrates the change.")
        }

        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}
