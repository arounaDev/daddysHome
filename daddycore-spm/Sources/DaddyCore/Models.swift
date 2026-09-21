import Foundation

public enum AgentKind: String, Codable, Sendable {
    case claude
    case codex
    case cursor
    case opencode
}

public enum AgentState: Equatable, Codable {
    case launching
    case ready
    case working
    case rateLimited
    case error(String)
    case exited(exitCode: Int32)

    /// The output does not say. Distinct from `.ready`, which is a claim that
    /// the agent is idle and waiting for you — a claim worth being wrong about,
    /// because acting on it means interrupting something mid-thought.
    case unknown

    enum CodingKeys: String, CodingKey {
        case launching, ready, working, rateLimited, error, exited, unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .launching:
            try container.encodeNil(forKey: .launching)
        case .unknown:
            try container.encodeNil(forKey: .unknown)
        case .ready:
            try container.encodeNil(forKey: .ready)
        case .working:
            try container.encodeNil(forKey: .working)
        case .rateLimited:
            try container.encodeNil(forKey: .rateLimited)
        case .error(let msg):
            try container.encode(msg, forKey: .error)
        case .exited(let code):
            try container.encode(code, forKey: .exited)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.launching) {
            self = .launching
        } else if container.contains(.unknown) {
            self = .unknown
        } else if container.contains(.ready) {
            self = .ready
        } else if container.contains(.working) {
            self = .working
        } else if container.contains(.rateLimited) {
            self = .rateLimited
        } else if container.contains(.error) {
            let msg = try container.decode(String.self, forKey: .error)
            self = .error(msg)
        } else if container.contains(.exited) {
            let code = try container.decode(Int32.self, forKey: .exited)
            self = .exited(exitCode: code)
        } else {
            self = .launching
        }
    }
}

public struct ModelRef: Codable {
    public let agent: AgentKind
    public let rawValue: String

    public init(agent: AgentKind, rawValue: String) {
        self.agent = agent
        self.rawValue = rawValue
    }
}

public struct Project: Identifiable, Codable {
    public let id: String
    public let name: String
    public let path: URL
}

public struct WorkUnit: Identifiable, Codable {
    public enum Status: String, Codable {
        case active
        case idle
        case done
    }

    public let id: String
    public let projectID: String
    public let name: String
    public var status: Status
    public let markdownDir: URL
    public let createdAt: Date
    public var lastActivityAt: Date
}

public final class Session: Identifiable {
    public let id: String
    public let projectID: String
    public let workUnitID: String
    public let agent: AgentKind
    public var model: ModelRef?
    public let cwd: URL
    public var state: AgentState
    public let createdAt: Date
    public var lastOutputAt: Date

    /// The id the *CLI* knows this conversation by, which is not `id` — that
    /// one is Daddy's own handle and means nothing to the agent.
    ///
    /// Set at launch for CLIs that accept a pre-assigned id, and it is what
    /// makes reopening this exact conversation possible later. Nil means the
    /// best Daddy can offer is "the newest conversation in this directory".
    public var providerSessionID: String?

    /// How much process this agent wraps around the work. Set at launch and
    /// updated by `SessionManager.switchWorkMode`, so a card can show what its
    /// agent is actually operating under rather than what the global default
    /// happened to be when it started.
    public var workMode: WorkMode = .default

    /// What this agent may build. Set at launch and updated by
    /// `SessionManager.switchBuildPolicy`, for the same reason `workMode` is:
    /// the card should show what its agent is actually operating under.
    public var buildPolicy: BuildPolicy = .default

    /// What this session is for and when it is finished.
    ///
    /// Nil for a session started without one — a card opened to poke around
    /// does not need a contract, and demanding one before anything can run
    /// would make the cheap case expensive.
    public var contract: TaskContract?

    /// Whether anything other than the agent has confirmed the work.
    ///
    /// Separate from `state` deliberately. `state` knows whether the process
    /// is busy; this knows whether the result stood up to something. A session
    /// can be idle and unverified, which is the most common way work is
    /// quietly wrong.
    public var verification: Verification = Verification(profile: BuildPolicy.default.verification)

    /// The mode, the build policy and their resolved consequences.
    public var policy: SessionPolicy {
        SessionPolicy(workMode: workMode, buildPolicy: buildPolicy, enforceReadOnly: enforcesReadOnly)
    }

    /// Whether a non-editing mode should have its editing tools taken away at
    /// launch rather than merely being asked not to use them.
    ///
    /// Off unless the session asks. See `ModePolicy.enforcesReadOnly`.
    public var enforcesReadOnly: Bool = false

    public init(
        id: String = UUID().uuidString,
        projectID: String,
        workUnitID: String,
        agent: AgentKind,
        model: ModelRef? = nil,
        cwd: URL,
        providerSessionID: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.workUnitID = workUnitID
        self.agent = agent
        self.model = model
        self.cwd = cwd
        self.providerSessionID = providerSessionID
        self.state = .launching
        self.createdAt = Date()
        self.lastOutputAt = Date()
    }
}

public struct Focus {
    public var projectID: String?
    public var workUnitID: String?
    public var sessionID: String?

    public var isEmpty: Bool {
        projectID == nil && workUnitID == nil && sessionID == nil
    }
}
