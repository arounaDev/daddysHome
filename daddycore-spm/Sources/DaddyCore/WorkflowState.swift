import Foundation

public final class WorkflowState: Codable {
    public struct ProjectState: Codable, Identifiable {
        public let id: String
        public let name: String
        public let path: URL
        public let discoveredAt: Date
        public var lastAccessedAt: Date

        public init(id: String, name: String, path: URL, discoveredAt: Date, lastAccessedAt: Date) {
            self.id = id
            self.name = name
            self.path = path
            self.discoveredAt = discoveredAt
            self.lastAccessedAt = lastAccessedAt
        }

        enum CodingKeys: String, CodingKey {
            case id, name
            case path = "path_string"
            case discoveredAt, lastAccessedAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            let pathStr = try container.decode(String.self, forKey: .path)
            path = URL(fileURLWithPath: pathStr)
            discoveredAt = try container.decode(Date.self, forKey: .discoveredAt)
            lastAccessedAt = try container.decode(Date.self, forKey: .lastAccessedAt)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(path.path, forKey: .path)
            try container.encode(discoveredAt, forKey: .discoveredAt)
            try container.encode(lastAccessedAt, forKey: .lastAccessedAt)
        }
    }

    public struct SessionState: Codable, Identifiable {
        public let id: String
        public let projectID: String
        public let workUnitID: String
        public let agent: AgentKind
        public var model: ModelRef?
        public var agentState: AgentState
        public let createdAt: Date
        public var lastActivityAt: Date

        /// What the session was for. Survives a relaunch, which is the whole
        /// point: the goal outlives the conversation that was pursuing it.
        public var contract: TaskContract?

        /// Whether anything outside the agent had confirmed the work when this
        /// was last written.
        public var verification: Verification?

        public init(
            id: String,
            projectID: String,
            workUnitID: String,
            agent: AgentKind,
            model: ModelRef?,
            agentState: AgentState,
            createdAt: Date,
            lastActivityAt: Date,
            contract: TaskContract? = nil,
            verification: Verification? = nil
        ) {
            self.id = id
            self.projectID = projectID
            self.workUnitID = workUnitID
            self.agent = agent
            self.model = model
            self.agentState = agentState
            self.createdAt = createdAt
            self.lastActivityAt = lastActivityAt
            self.contract = contract
            self.verification = verification
        }

        enum CodingKeys: String, CodingKey {
            case id, projectID, workUnitID, agent, model
            case agentState = "state"
            case createdAt, lastActivityAt
            case contract, verification
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            projectID = try container.decode(String.self, forKey: .projectID)
            workUnitID = try container.decode(String.self, forKey: .workUnitID)
            agent = try container.decode(AgentKind.self, forKey: .agent)
            model = try container.decodeIfPresent(ModelRef.self, forKey: .model)
            agentState = try container.decode(AgentState.self, forKey: .agentState)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)
            // Optional on the way in, not just in the type: every state file
            // written before these existed has neither key, and a `decode`
            // here would make the whole workflow fail to load rather than one
            // session come back without a goal.
            contract = try container.decodeIfPresent(TaskContract.self, forKey: .contract)
            verification = try container.decodeIfPresent(Verification.self, forKey: .verification)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(projectID, forKey: .projectID)
            try container.encode(workUnitID, forKey: .workUnitID)
            try container.encode(agent, forKey: .agent)
            try container.encodeIfPresent(model, forKey: .model)
            try container.encode(agentState, forKey: .agentState)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(lastActivityAt, forKey: .lastActivityAt)
            try container.encodeIfPresent(contract, forKey: .contract)
            try container.encodeIfPresent(verification, forKey: .verification)
        }
    }

    public struct FocusState: Codable {
        public var projectID: String?
        public var workUnitID: String?
        public var sessionID: String?
    }

    public var projects: [String: ProjectState] = [:]
    public var sessions: [String: SessionState] = [:]
    public var focus: FocusState = FocusState()
    public var lastUpdatedAt: Date = Date()

    public init() {}
}

public final class WorkflowStateManager {
    private let stateFilePath: URL
    private var state: WorkflowState
    private let lock = NSLock()
    private let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser

    public init(stateFile: URL? = nil) {
        if let stateFile = stateFile {
            self.stateFilePath = stateFile
        } else {
            let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
            let daddyDir = appSupportDir.appendingPathComponent("Daddy")
            try? FileManager.default.createDirectory(at: daddyDir, withIntermediateDirectories: true)
            self.stateFilePath = daddyDir.appendingPathComponent("workflow-state.json")
        }

        self.state = Self.loadState(from: self.stateFilePath) ?? WorkflowState()
    }

    public func discoverProjects() -> [WorkflowState.ProjectState] {
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        let documentsDir = documentsURL
        var projects: [WorkflowState.ProjectState] = []

        do {
            let contents = try fileManager.contentsOfDirectory(at: documentsDir, includingPropertiesForKeys: nil)
            for url in contents {
                guard url.hasDirectoryPath else { continue }

                let projectName = url.lastPathComponent
                let projectID = projectName.lowercased().replacingOccurrences(of: " ", with: "-")

                if !state.projects.keys.contains(projectID) {
                    let projectState = WorkflowState.ProjectState(
                        id: projectID,
                        name: projectName,
                        path: url,
                        discoveredAt: Date(),
                        lastAccessedAt: Date()
                    )
                    state.projects[projectID] = projectState
                    projects.append(projectState)
                }
            }
        } catch {
            return []
        }

        saveState()
        return projects
    }

    public func addSession(_ session: Session) {
        lock.lock()
        defer { lock.unlock() }

        let sessionState = WorkflowState.SessionState(
            id: session.id,
            projectID: session.projectID,
            workUnitID: session.workUnitID,
            agent: session.agent,
            model: session.model,
            agentState: session.state,
            createdAt: session.createdAt,
            lastActivityAt: session.lastOutputAt
        )

        state.sessions[session.id] = sessionState
        saveState()
    }

    public func updateSessionState(_ sessionID: String, newState: AgentState) {
        lock.lock()
        defer { lock.unlock() }

        if var sessionState = state.sessions[sessionID] {
            sessionState.agentState = newState
            sessionState.lastActivityAt = Date()
            state.sessions[sessionID] = sessionState
            saveState()
        }
    }

    public func setFocus(projectID: String? = nil, workUnitID: String? = nil, sessionID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        state.focus.projectID = projectID
        state.focus.workUnitID = workUnitID
        state.focus.sessionID = sessionID
        saveState()
    }

    public func getFocus() -> WorkflowState.FocusState {
        lock.lock()
        defer { lock.unlock() }
        return state.focus
    }

    public func getProject(_ id: String) -> WorkflowState.ProjectState? {
        lock.lock()
        defer { lock.unlock() }
        return state.projects[id]
    }

    public func getSession(_ id: String) -> WorkflowState.SessionState? {
        lock.lock()
        defer { lock.unlock() }
        return state.sessions[id]
    }

    public func getAllProjects() -> [WorkflowState.ProjectState] {
        lock.lock()
        defer { lock.unlock() }
        return Array(state.projects.values)
    }

    public func getAllSessions() -> [WorkflowState.SessionState] {
        lock.lock()
        defer { lock.unlock() }
        return Array(state.sessions.values)
    }

    public func getSessionsForProject(_ projectID: String) -> [WorkflowState.SessionState] {
        lock.lock()
        defer { lock.unlock() }
        return state.sessions.values.filter { $0.projectID == projectID }
    }

    public func getActiveAgents() -> Set<AgentKind> {
        lock.lock()
        defer { lock.unlock() }
        let activeSessions = state.sessions.values.filter { session in
            switch session.agentState {
            case .exited:
                return false
            default:
                return true
            }
        }
        return Set(activeSessions.map { $0.agent })
    }

    public func getRateLimitedAgents() -> Set<AgentKind> {
        lock.lock()
        defer { lock.unlock() }
        let rateLimitedSessions = state.sessions.values.filter { session in
            if case .rateLimited = session.agentState {
                return true
            }
            return false
        }
        return Set(rateLimitedSessions.map { $0.agent })
    }

    private func saveState() {
        state.lastUpdatedAt = Date()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: stateFilePath, options: .atomic)
        } catch {
            print("Failed to save workflow state: \(error)")
        }
    }

    private static func loadState(from url: URL) -> WorkflowState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WorkflowState.self, from: data)
        } catch {
            print("Failed to load workflow state: \(error)")
            return nil
        }
    }
}
