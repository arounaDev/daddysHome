import Foundation

/// `@unchecked Sendable` for the same reason `PTYProcess` is: every mutable
/// field below is guarded by `lock`, and this type has always been reached from
/// more than one queue — the pty's read callbacks have called into it since
/// launch callbacks existed. The deferred state-detection run made the compiler
/// say so out loud.
public final class SessionManager: @unchecked Sendable {
    private var sessions: [String: Session] = [:]
    private var ptyProcesses: [String: PTYProcess] = [:]
    private var adapters: [AgentKind: AgentAdapter] = [:]
    private var sessionErrors: [String: (error: String, count: Int, lastAt: Date)] = [:]
    private var retryAttempts: [String: Int] = [:]
    private let markdownWriter = MarkdownWriter()
    private let lock = NSLock()
    private let maxRetries = 3
    private let errorThresholdCount = 5

    // MARK: State detection
    //
    // Detection runs on the pty's own read queue, so whatever it costs is paid
    // *before the next chunk reaches the renderer*. It is much cheaper than it
    // used to be — rendering the shadow screen instead of stripping ANSI out of
    // a 64KB buffer — but it is still throttled, because `DispatchIO` delivers
    // one TUI repaint as many separate chunks.

    private var lastDetectionAt: [String: Date] = [:]
    private let detectionQueue = DispatchQueue(label: "com.daddy.session.detection")

    /// A state change is noticed within a quarter second, far faster than the
    /// one-second cadence the dashboard reads at.
    private static let detectionInterval: TimeInterval = 0.25

    // MARK: Settle timer
    //
    // Detection used to be triggered only by output. An idle agent produces
    // none, so the last verdict was always computed on the tail of the working
    // burst and nothing ever revisited it: a card that went WORKING stayed
    // WORKING until the agent spoke again. This is what revisits it.
    //
    // One timer for the manager rather than one work item per session. A dead
    // session is skipped because its pty is no longer in `ptyProcesses` — a
    // fact, rather than a cancellation four different teardown paths each have
    // to remember to perform.

    private var settleTimer: DispatchSourceTimer?
    private var lastScreenRevision: [String: UInt64] = [:]
    private static let settleInterval: TimeInterval = 0.5

    deinit {
        // A `DispatchSourceTimer` holds its handler until cancelled, and the
        // handler is what keeps firing into a manager nobody owns any more.
        settleTimer?.cancel()
        settleTimer = nil
    }

    public init() {
        self.adapters = [
            .claude: ClaudeAdapter(),
            .codex: CodexAdapter(),
            .cursor: CursorAdapter(),
            .opencode: OpenCodeAdapter(),
        ]
    }

    public func createSession(
        id: String = UUID().uuidString,
        projectID: String,
        workUnitID: String,
        agent: AgentKind,
        model: ModelRef? = nil,
        cwd: URL,
        providerSessionID: String? = nil
    ) throws -> Session {
        let session = Session(
            id: id,
            projectID: projectID,
            workUnitID: workUnitID,
            agent: agent,
            model: model,
            cwd: cwd,
            providerSessionID: providerSessionID
        )

        lock.lock()
        defer { lock.unlock() }
        sessions[session.id] = session
        return session
    }

    /// Puts back a session from a previous run of the app, with no process
    /// behind it.
    ///
    /// The card it belongs to is dead by definition — the pty died with the app
    /// that owned it — so the session is registered as exited. What it carries
    /// that a brand new session would not is `providerSessionID`, which is what
    /// lets "Resume chat" reopen the actual conversation rather than guessing.
    @discardableResult
    public func restoreSession(
        id: String,
        projectID: String,
        workUnitID: String,
        agent: AgentKind,
        model: ModelRef? = nil,
        cwd: URL,
        providerSessionID: String?
    ) -> Session {
        let session = Session(
            id: id,
            projectID: projectID,
            workUnitID: workUnitID,
            agent: agent,
            model: model,
            cwd: cwd,
            providerSessionID: providerSessionID
        )
        session.state = .exited(exitCode: 0)

        lock.lock()
        defer { lock.unlock() }
        sessions[session.id] = session
        return session
    }

    /// Whether this agent can pick up its previous conversation on relaunch.
    public func canContinueConversation(_ kind: AgentKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return adapters[kind]?.canReopenConversations ?? false
    }

    public func launchSession(
        _ session: Session,
        approvalPolicy: ApprovalPolicy = .safeAuto,
        continuingConversation: Bool = false,
        workMode: WorkMode = .default,
        buildPolicy: BuildPolicy = .default,
        contract: TaskContract? = nil
    ) throws {
        guard let adapter = adapters[session.agent] else {
            throw SessionError.unknownAgent(session.agent)
        }

        let resumption = resumption(for: session, adapter: adapter, continuing: continuingConversation)

        // Committed to the session *before* launch, so the card owns the id
        // even if the process dies on its first breath.
        if case .fresh(let minted?) = resumption {
            session.providerSessionID = minted
        }

        session.workMode = workMode
        session.buildPolicy = buildPolicy
        if let contract { session.contract = contract }

        // A relaunch starts the work over, so whatever the last run proved is
        // a statement about a process that no longer exists.
        session.verification = Verification(
            profile: SessionPolicy(
                workMode: workMode,
                buildPolicy: buildPolicy,
                enforceReadOnly: session.enforcesReadOnly
            ).verification
        )

        let execPath = type(of: adapter).executablePath
        var args = adapter.launchArgs(
            cwd: session.cwd,
            model: session.model,
            approvalPolicy: approvalPolicy,
            resumption: resumption
        )

        // The half of the policy this CLI can enforce goes on as flags —
        // effort, denied editing tools, MCP scope. That half is not a request
        // the agent can talk itself out of halfway through a long session,
        // which is the entire reason to prefer it over prose.
        //
        // Appended after `launchArgs`, which for Codex ends in a positional
        // session id. Safe because every flag these emit starts with a dash
        // and so cannot be mistaken for Codex's trailing PROMPT positional —
        // but it is the reason `ClaudeAdapter` comma-joins its variadic
        // `--disallowedTools` value instead of spelling it as separate
        // arguments, which would swallow whatever came next.
        let policy = SessionPolicy(
            workMode: workMode,
            buildPolicy: buildPolicy,
            enforceReadOnly: session.enforcesReadOnly
        )
        args += adapter.policyArgs(policy.mode)

        // Plan & Build and Compile are the contract's own defaults, so they
        // inject nothing — and a CLI with no system-prompt flag gets both from
        // AGENTS.md instead, which is why that file has to define them.
        //
        // The budget clause carries what no flag can: subagents, plan
        // approval, the retry cap, and what "done" has to mean here. It comes
        // last so it reads as the qualifier on the mode named above it.
        //
        // One combined injection rather than four: an adapter's system-prompt
        // flag is not guaranteed to be repeatable, and the second one silently
        // replacing the first is the kind of bug that only shows up as an
        // agent ignoring a policy you know you set.
        let launchPrompt = [
            workMode.systemPrompt,
            buildPolicy.systemPrompt,
            policy.promptClause,
            session.contract?.promptClause
        ]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        if !launchPrompt.isEmpty,
           let modeArgs = adapter.systemPromptArgs(launchPrompt) {
            args += modeArgs
        }

        let ptyProcess = PTYProcess(executablePath: execPath, arguments: args, cwd: session.cwd)

        try ptyProcess.launch()

        // Create handoff document in /documents/handoffs/ directory
        createHandoffDocument(projectID: session.projectID, workUnitID: session.workUnitID, agent: session.agent)

        lock.lock()
        ptyProcesses[session.id] = ptyProcess

        // `Session` is a reference type — this mutates the caller's instance
        // too. Named accordingly so it does not read as a copy.
        session.state = .ready
        sessions[session.id] = session
        lock.unlock()

        // Registered *after* unlocking, deliberately.
        //
        // This used to call a helper that took the lock again while this method
        // still held it. `NSLock` is not recursive, so launching an agent
        // deadlocked the calling thread — the main thread, in the app — and the
        // window beachballed forever. It was masked for a long time by a crash
        // that happened earlier in the same click.
        ptyProcess.registerActivityCallback { [weak self] in
            self?.noteActivity(sessionID: session.id)
        }

        startSettleTimerIfNeeded()
    }

    /// Decides what this launch should do about history.
    ///
    /// A fresh launch on a CLI that accepts a pre-assigned id gets one minted
    /// here, so the conversation is identifiable from the first byte. A
    /// continuing launch reopens the exact conversation when the id is known
    /// and otherwise falls back to the newest one in the directory — which is
    /// the best those CLIs can currently do, and is wrong whenever two agents
    /// share a project. See the batch document for what closing that needs.
    private func resumption(
        for session: Session,
        adapter: AgentAdapter,
        continuing: Bool
    ) -> Resumption {
        guard continuing, adapter.canReopenConversations else {
            // A fresh launch always gets a *new* id, even on a session that
            // already carries one. Reusing it would be the opposite of what
            // "fresh start" means, and Claude rejects an id that is already on
            // disk anyway — which would stop the agent from starting at all.
            guard adapter.mintsSessionID else { return .fresh(sessionID: nil) }
            return .fresh(sessionID: UUID().uuidString)
        }

        if let known = session.providerSessionID {
            return .conversation(id: known)
        }
        return .mostRecent
    }

    /// Change a running session's mode.
    ///
    /// A launched process cannot have its system prompt rewritten, so this is a
    /// message rather than a flag — which is also why it works on all four CLIs
    /// while the launch-time injection only works on Claude. Pasted, not sent:
    /// picking a mode used to submit immediately, which fought with also
    /// picking a build policy right after — one or the other would land as its
    /// own message instead of both riding into the same prompt. Left in the
    /// composer, the two combine and whatever else you type goes out together
    /// on one Enter.
    public func switchWorkMode(_ mode: WorkMode, for sessionID: String) throws {
        let (pty, adapter) = try liveSession(sessionID)
        try adapter.pastePrompt(mode.switchInstruction + " ", to: pty)

        lock.lock()
        defer { lock.unlock() }
        sessions[sessionID]?.workMode = mode
        sessions[sessionID]?.lastOutputAt = Date()
        retargetVerificationLocked(sessionID)
    }

    /// Change a running session's build policy. Pasted, for the same reason
    /// `switchWorkMode` is.
    public func switchBuildPolicy(_ policy: BuildPolicy, for sessionID: String) throws {
        let (pty, adapter) = try liveSession(sessionID)
        try adapter.pastePrompt(policy.switchInstruction + " ", to: pty)

        lock.lock()
        defer { lock.unlock() }
        sessions[sessionID]?.buildPolicy = policy
        sessions[sessionID]?.lastOutputAt = Date()
        retargetVerificationLocked(sessionID)
    }

    /// Move a session's verification to whatever its mode and build policy
    /// now demand. Caller holds the lock; the name says so because this file
    /// has already deadlocked once on an `NSLock` that is not recursive.
    private func retargetVerificationLocked(_ sessionID: String) {
        guard let session = sessions[sessionID] else { return }
        session.verification.retarget(to: session.policy.verification)
    }

    // MARK: - Task contract

    /// Give a running session its goal, or change it.
    ///
    /// Sent as well as stored. The stored copy is what the card and a later
    /// relaunch read; the sent copy is what the agent is actually working to.
    /// Storing without sending would give you a card that displays a goal the
    /// agent has never been told.
    public func setContract(_ contract: TaskContract, for sessionID: String) throws {
        lock.lock()
        guard let session = sessions[sessionID] else {
            lock.unlock()
            throw SessionError.sessionNotFound(sessionID)
        }
        session.contract = contract
        lock.unlock()

        guard let clause = contract.promptClause else { return }
        let (pty, adapter) = try liveSession(sessionID)
        // Pasted rather than sent, for the same reason the mode switches are:
        // setting a goal and then typing the first instruction should leave on
        // one Enter, not as two messages the agent answers separately.
        try adapter.pastePrompt(clause + "\n\n", to: pty)
    }

    public func contract(for sessionID: String) -> TaskContract? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionID]?.contract
    }

    // MARK: - Verification

    /// Record what a check actually did.
    ///
    /// There is no `setVerified(true)` anywhere in this API, and that is the
    /// design. `passed` is reachable only by handing this an exit code, which
    /// means some process ran and returned it — not by anyone, agent or UI,
    /// deciding the work looks done.
    ///
    /// `summary` is for the card to display and never decides the outcome.
    @discardableResult
    public func recordVerification(
        exitCode: Int32,
        command: String?,
        summary: String? = nil,
        for sessionID: String
    ) throws -> Verification {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionID] else {
            throw SessionError.sessionNotFound(sessionID)
        }
        session.verification.record(exitCode: exitCode, command: command, summary: summary)
        return session.verification
    }

    /// Mark a check as in flight, so a card can say "verifying" rather than
    /// showing the previous run's result as though it still applied.
    public func beginVerification(command: String?, for sessionID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionID] else {
            throw SessionError.sessionNotFound(sessionID)
        }
        session.verification.markRunning(command: command)
    }

    /// Call when the working tree moves after a pass.
    ///
    /// Daddy does not watch the filesystem, so this is the caller's to invoke
    /// — from a diff refresh, a commit, or the next prompt sent into a session
    /// that had already gone green. Without it, "Verified" degrades into "was
    /// verified at some point", which is worse than no badge at all because it
    /// still looks like an answer.
    public func invalidateVerification(for sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        sessions[sessionID]?.verification.invalidate()
    }

    public func verification(for sessionID: String) -> Verification? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionID]?.verification
    }

    /// Internal, for tests: the resume decision without launching anything.
    ///
    /// Exercising it through `launchSession` would mean running a real agent
    /// CLI, which is exactly the kind of test that only passes on the machine
    /// it was written on.
    func resumptionForTesting(session: Session, continuing: Bool) -> Resumption {
        guard let adapter = adapters[session.agent] else { return .fresh(sessionID: nil) }
        return resumption(for: session, adapter: adapter, continuing: continuing)
    }

    public func sendPrompt(_ prompt: String, to sessionID: String) throws {
        lock.lock()
        guard let ptyProcess = ptyProcesses[sessionID],
              let session = sessions[sessionID],
              let adapter = adapters[session.agent] else {
            lock.unlock()
            throw SessionError.sessionNotFound(sessionID)
        }
        lock.unlock()

        try adapter.sendPrompt(prompt, to: ptyProcess)

        lock.lock()
        defer { lock.unlock() }
        if sessions[sessionID] != nil {
            sessions[sessionID]?.lastOutputAt = Date()
        }
    }

    /// Text only — no enter. For stuffing a work item into a live composer.
    public func pastePrompt(_ prompt: String, to sessionID: String) throws {
        let (pty, adapter) = try liveSession(sessionID)
        try adapter.pastePrompt(prompt, to: pty)

        lock.lock()
        defer { lock.unlock() }
        sessions[sessionID]?.lastOutputAt = Date()
    }

    public func interruptSession(_ sessionID: String) throws {
        let (pty, adapter) = try liveSession(sessionID)
        try adapter.interrupt(pty)
    }

    /// Tell a stopped agent to keep going. The other half of `interruptSession`
    /// — without it you can halt an agent but never restart its train of
    /// thought, which is most of the point of holding the process.
    public func resumeSession(_ sessionID: String) throws {
        let (pty, adapter) = try liveSession(sessionID)
        try adapter.resume(pty)

        lock.lock()
        defer { lock.unlock() }
        sessions[sessionID]?.lastOutputAt = Date()
    }

    /// Switch a running agent to a different model, by its human name.
    ///
    /// This types `/model <name>` at the agent and returns. It does not try to
    /// confirm the switch from the terminal output, and it deliberately no
    /// longer keeps a "pending switch" to reconcile later: that reconciliation
    /// matched the bare substrings "error" and "failed" anywhere in the recent
    /// window — the exact mistake `OutputHeuristics.indicatesFailure` was
    /// rewritten to stop making — and the entry was never cleared when a
    /// session was torn down, so it outlived the session it described.
    ///
    /// Whether the switch took is answered by reading the agent's own
    /// transcript; see `transcriptReading(for:)`.
    public func selectModel(_ humanName: String, for sessionID: String) throws {
        lock.lock()
        guard let pty = ptyProcesses[sessionID],
              let session = sessions[sessionID],
              let adapter = adapters[session.agent] else {
            lock.unlock()
            throw SessionError.sessionNotFound(sessionID)
        }
        lock.unlock()

        guard let rawValue = adapter.modelFlagValue(for: humanName) else {
            throw SessionError.unknownModel(humanName, session.agent)
        }

        let model = ModelRef(agent: session.agent, rawValue: rawValue)
        try adapter.selectModel(model, on: pty)
    }

    /// Kill whatever is running and start the same session again from scratch.
    ///
    /// Distinct from `resumeSession`: this throws the conversation away. It is
    /// what "relaunch" on a dead card should do.
    public func restartSession(
        _ sessionID: String,
        approvalPolicy: ApprovalPolicy = .safeAuto,
        continuingConversation: Bool = false,
        workMode: WorkMode? = nil,
        buildPolicy: BuildPolicy? = nil
    ) throws {
        lock.lock()
        guard let session = sessions[sessionID] else {
            lock.unlock()
            throw SessionError.sessionNotFound(sessionID)
        }
        lock.unlock()

        teardownPTY(for: sessionID)

        session.state = .launching
        try launchSession(
            session,
            approvalPolicy: approvalPolicy,
            continuingConversation: continuingConversation,
            // Nil means "whatever this session was already running under" — a
            // relaunch should not silently drop a card back to the global
            // default just because the default is what a new card would get.
            workMode: workMode ?? session.workMode,
            buildPolicy: buildPolicy ?? session.buildPolicy
        )
    }

    public func terminateSession(_ sessionID: String) throws {
        lock.lock()
        guard let ptyProcess = ptyProcesses[sessionID] else {
            lock.unlock()
            throw SessionError.sessionNotFound(sessionID)
        }
        lock.unlock()

        // Synchronous: the session is removed from the table on the next line,
        // so this is the last chance to reach the process group. A fire-and-
        // forget terminate would leak the agent and all of its descendants.
        ptyProcess.shutdown()

        lock.lock()
        defer { lock.unlock() }
        ptyProcesses.removeValue(forKey: sessionID)

        if let session = sessions[sessionID] {
            // Report what actually happened, not a hardcoded success.
            session.state = .exited(exitCode: ptyProcess.exitCode ?? 0)
            sessions[sessionID] = session
        }
    }

    /// Swaps the adapter used for a kind.
    ///
    /// Internal: tests use it to launch a harmless stand-in binary through the
    /// real `launchSession` path, so the lifecycle can be exercised without an
    /// agent CLI installed.
    func register(_ adapter: AgentAdapter, for kind: AgentKind) {
        lock.lock()
        defer { lock.unlock() }
        adapters[kind] = adapter
    }

    /// Attaches an already-launched process to a session.
    ///
    /// Internal, not public: the app always goes through `launchSession`. Tests
    /// use this to drive the lifecycle with a stand-in process rather than
    /// requiring an agent CLI to be installed.
    func attach(_ pty: PTYProcess, to sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        ptyProcesses[sessionID] = pty
    }

    /// Removes a session entirely, killing it first if it is still running.
    ///
    /// `terminateSession` deliberately keeps the record so the card can still
    /// show how the agent ended. This is the other half: once you have read
    /// that, you need a way to be rid of it, or dead sessions accumulate for as
    /// long as the app is open.
    public func forgetSession(_ sessionID: String) {
        teardownPTY(for: sessionID)

        lock.lock()
        defer { lock.unlock() }
        sessions.removeValue(forKey: sessionID)
        sessionErrors.removeValue(forKey: sessionID)
        retryAttempts.removeValue(forKey: sessionID)
        lastDetectionAt.removeValue(forKey: sessionID)
        lastScreenRevision.removeValue(forKey: sessionID)
    }

    /// Shuts down the pty attached to a session, leaving the session itself in
    /// the table.
    ///
    /// Both restart and recover used to just drop the reference, which leaked
    /// the old agent and every process it had spawned.
    func teardownPTY(for sessionID: String) {
        lock.lock()
        let existing = ptyProcesses.removeValue(forKey: sessionID)
        lock.unlock()

        existing?.shutdown()
    }

    private func liveSession(_ sessionID: String) throws -> (PTYProcess, AgentAdapter) {
        lock.lock()
        defer { lock.unlock() }

        guard let pty = ptyProcesses[sessionID],
              let session = sessions[sessionID],
              let adapter = adapters[session.agent] else {
            throw SessionError.sessionNotFound(sessionID)
        }
        return (pty, adapter)
    }

    public func session(_ sessionID: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionID]
    }

    public func allSessions() -> [Session] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.values)
    }

    /// Called on the pty's read queue for every chunk.
    ///
    /// Keeps the cheap part — when did this agent last speak — exact, and
    /// throttles the part that looks at the screen.
    private func noteActivity(sessionID: String) {
        lock.lock()
        guard let session = sessions[sessionID], adapters[session.agent] != nil else {
            lock.unlock()
            return
        }
        // A process that has exited stays exited. Output can still arrive after
        // termination — the final flush — and it must not resurrect the session.
        if case .exited = session.state {
            lock.unlock()
            return
        }

        // Free, and read by the dashboard every second, so keep it truthful at
        // the moment the output actually arrived.
        session.lastOutputAt = Date()

        let now = Date()
        let elapsed = lastDetectionAt[sessionID].map { now.timeIntervalSince($0) }
            ?? .greatestFiniteMagnitude
        let shouldRun = elapsed >= Self.detectionInterval
        if shouldRun { lastDetectionAt[sessionID] = now }
        lock.unlock()

        // Nothing is scheduled for the chunks skipped here. That used to matter
        // enormously — the last chunk of a burst is exactly the one that says
        // the agent finished, and dropping it left the card on WORKING forever
        // — but the settle timer now re-reads the screen half a second after
        // things go quiet, which covers it without a second scheduling path.
        guard shouldRun else { return }
        runStateDetection(sessionID: sessionID)
    }

    /// Reads the agent's rendered screen and updates the session's state.
    private func runStateDetection(sessionID: String) {
        lock.lock()
        guard let session = sessions[sessionID],
              let adapter = adapters[session.agent],
              let pty = ptyProcesses[sessionID] else {
            lock.unlock()
            return
        }
        if case .exited = session.state {
            lock.unlock()
            return
        }
        lock.unlock()

        // Rendered outside the lock: `currentScreen` takes the pty's own screen
        // lock, and holding both at once is how this deadlocked before.
        let screen = pty.currentScreen()
        let revision = pty.screenRevision
        let newState = adapter.detectState(from: screen)

        lock.lock()
        defer { lock.unlock() }

        // Re-checked, because detection runs unlocked: the session can have
        // exited in between.
        guard let updatedSession = sessions[sessionID] else { return }
        if case .exited = updatedSession.state { return }

        lastScreenRevision[sessionID] = revision

        // `.unknown` means the screen did not say, which is not a reason to
        // discard what it last did say. Keep the previous state instead.
        if newState != .unknown {
            updatedSession.state = newState
        }

        sessions[sessionID] = updatedSession
    }

    /// Starts the one shared settle timer, if it is not already running.
    private func startSettleTimerIfNeeded() {
        lock.lock()
        guard settleTimer == nil else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: detectionQueue)
        timer.schedule(
            deadline: .now() + Self.settleInterval,
            repeating: Self.settleInterval
        )
        timer.setEventHandler { [weak self] in self?.settleTick() }
        settleTimer = timer
        lock.unlock()

        timer.resume()
    }

    /// Re-examines any session whose screen has moved since it was last looked
    /// at, plus any that is currently claiming to be working.
    ///
    /// The second half is the point: a latched WORKING is re-checked every half
    /// second until the screen stops saying so, which is the only way a card
    /// that stopped producing output ever gets to be READY again.
    private func settleTick() {
        lock.lock()
        var candidates: [String] = []
        for (sessionID, pty) in ptyProcesses {
            guard let session = sessions[sessionID] else { continue }
            if case .exited = session.state { continue }

            let moved = lastScreenRevision[sessionID] != pty.screenRevision
            let claimsBusy: Bool
            if case .working = session.state { claimsBusy = true } else { claimsBusy = false }
            if moved || claimsBusy { candidates.append(sessionID) }
        }
        lock.unlock()

        for sessionID in candidates {
            runStateDetection(sessionID: sessionID)
        }
    }

    /// Sessions that still have a process behind them. This used to be a second
    /// copy of `allSessions()`, which made the name a lie.
    public func getActiveSessions() -> [Session] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.filter { session in
            if case .exited = session.state { return false }
            return ptyProcesses[session.id]?.isProcessRunning ?? false
        }
    }

    /// How stale a transcript reading may be and still be believed.
    ///
    /// Beyond this it is describing a turn that ended long ago, and the screen —
    /// which at least reflects the terminal as it is now — is the better guess.
    private static let transcriptFreshness: TimeInterval = 120

    /// What the CLI's own transcript says this session is running and doing.
    ///
    /// Does real file and database I/O — never call this on the main thread.
    /// The model used to come from a hardcoded table in the app that was wrong
    /// for three of the four providers; this asks the agent instead.
    public func transcriptReading(for sessionID: String) -> TranscriptReading? {
        lock.lock()
        guard let session = sessions[sessionID] else {
            lock.unlock()
            return nil
        }
        let agent = session.agent
        let cwd = session.cwd
        var providerSessionID = session.providerSessionID
        let pid = ptyProcesses[sessionID]?.pid ?? 0
        lock.unlock()

        let source = AgentTranscripts.source(for: agent)

        // Re-derive the link before reading it, rather than trusting the id
        // handed over at launch forever. A conversation is not a process:
        // `/clear` starts a new one inside the same CLI, and the id from launch
        // then names a file that will never be written to again — which shows
        // up as a percentage frozen at whatever it was, not as an error.
        let live = pid > 0 ? source.liveConversation(pid: pid, cwd: cwd) : nil
        if let live, live.id != providerSessionID {
            providerSessionID = live.id
            lock.lock()
            sessions[sessionID]?.providerSessionID = live.id
            lock.unlock()
        }

        // A stated activity beats an inferred one. The transcript's answer is
        // read off the shape of the last record written — a `stop_reason`, a
        // `tool_result` — which is a good guess and still a guess; this is the
        // CLI saying so. It also fills the gap the transcript cannot cover: a
        // turn that has started but written nothing yet still says `busy`.
        if let reading = source.read(cwd: cwd, providerSessionID: providerSessionID) {
            return reading.stating(live?.activity).titled(live?.name)
        }

        // Nothing readable for this session. For a CLI that keeps transcripts
        // that means the link is broken — the id Daddy is holding does not
        // name a file on disk — and saying so is the difference between a
        // fixable problem and a blank meter nobody can explain.
        let context: ContextAvailability = source.reportsContextUsage
            ? .transcriptMissing
            : .notReported

        // No transcript to read, but the status file may still know what the
        // process is doing — an unlinked card should not also go stateless.
        let model = source.defaultModel()
        return TranscriptReading(
            model: model,
            activity: live?.activity,
            observedAt: Date(),
            context: context,
            title: live?.name
        )
    }

    /// Reads the transcript once and uses everything it can tell us: whose
    /// turn it is, which is applied to the session's state, and the model and
    /// context consumption, which come back for the caller to show.
    ///
    /// The screen is the fast path — it updates within a quarter second and is
    /// the only signal Cursor has at all — but it is inferential: it reads
    /// markers a TUI happens to print. A transcript says outright that a turn
    /// started or finished. Where the two disagree and the transcript is recent,
    /// the transcript wins.
    ///
    /// Deliberately conservative. `.rateLimited` and `.error` are never
    /// overridden: a transcript has nothing to say about either, and losing them
    /// would hide the two states you most need to see.
    @discardableResult
    public func refreshFromTranscript(_ sessionID: String) -> TranscriptReading? {
        guard let reading = transcriptReading(for: sessionID) else { return nil }

        guard let activity = reading.activity,
              Date().timeIntervalSince(reading.observedAt) <= Self.transcriptFreshness else {
            return reading
        }

        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionID] else { return reading }

        switch session.state {
        case .exited, .rateLimited, .error, .launching:
            return reading
        case .ready, .working, .unknown:
            break
        }

        switch activity {
        case .idle:
            session.state = .ready
        case .prompted, .responding:
            session.state = .working
        }
        sessions[sessionID] = session

        return reading
    }

    /// The opening of a conversation, for titling it. Real file I/O — never
    /// call it on the main thread.
    public func openingExcerpt(for sessionID: String) -> String? {
        lock.lock()
        guard let session = sessions[sessionID] else {
            lock.unlock()
            return nil
        }
        let agent = session.agent
        let cwd = session.cwd
        let providerSessionID = session.providerSessionID
        lock.unlock()

        return AgentTranscripts.source(for: agent)
            .openingExcerpt(cwd: cwd, providerSessionID: providerSessionID)
    }

    /// Whether this CLI names its own conversations, and so needs no help.
    public func titlesOwnConversations(_ kind: AgentKind) -> Bool {
        AgentTranscripts.source(for: kind).titlesConversations
    }

    /// Tell a session which conversation on disk is its own.
    ///
    /// The id is normally learned at launch — minted by Daddy, or carried in
    /// from the chat you reopened. It is missing whenever the CLI chose the id
    /// itself (`--continue`, or a conversation started in a plain terminal),
    /// and a session with no id can never be read. This is the repair.
    public func linkConversation(_ providerSessionID: String, to sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        sessions[sessionID]?.providerSessionID = providerSessionID
    }

    public func getPTYProcess(for sessionID: String) -> PTYProcess? {
        lock.lock()
        defer { lock.unlock() }
        return ptyProcesses[sessionID]
    }

    public func recordSessionError(_ sessionID: String, error: String) {
        lock.lock()
        defer { lock.unlock() }

        if let existing = sessionErrors[sessionID] {
            sessionErrors[sessionID] = (error, existing.count + 1, Date())
        } else {
            sessionErrors[sessionID] = (error, 1, Date())
        }
    }

    public func getSessionError(_ sessionID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionErrors[sessionID]?.error
    }

    public func sessionHasCriticalErrors(_ sessionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (sessionErrors[sessionID]?.count ?? 0) >= errorThresholdCount
    }

    public func recoverSession(_ sessionID: String) throws {
        lock.lock()
        guard let session = sessions[sessionID] else {
            lock.unlock()
            throw SessionError.sessionNotFound(sessionID)
        }

        // `retryAttempts` used to be read and written outside the lock.
        let attempts = (retryAttempts[sessionID] ?? 0) + 1
        guard attempts <= maxRetries else {
            lock.unlock()
            throw SessionError.retryLimitReached(sessionID)
        }
        retryAttempts[sessionID] = attempts
        sessionErrors[sessionID] = nil
        lock.unlock()

        // Kills the old process group rather than orphaning it.
        teardownPTY(for: sessionID)

        session.state = .launching
        try launchSession(session)
    }

    private func createHandoffDocument(projectID: String, workUnitID: String, agent: AgentKind) {
        // Create handoff document in project's /documents/handoffs/ directory.
        // File is named after the work unit with .md extension.
        let fm = FileManager.default
        let projectPath = projectID
        let handoffsDir = projectPath + "/documents/handoffs"

        do {
            try fm.createDirectory(atPath: handoffsDir, withIntermediateDirectories: true)

            let filename = workUnitID + ".md"
            let filepath = handoffsDir + "/" + filename

            // Create initial handoff document if it doesn't exist
            if !fm.fileExists(atPath: filepath) {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let timestamp = dateFormatter.string(from: Date())

                let content = """
                # \(workUnitID)

                **Agent**: \(agent.rawValue)
                **Created**: \(timestamp)
                **Status**: In Progress

                ## Task
                [Task description here]

                ## Progress
                - Agent started

                ## Changes
                [Changes will be documented here]

                ## Next Steps
                [To be determined]
                """

                try content.write(toFile: filepath, atomically: true, encoding: String.Encoding.utf8)
            }
        } catch {
            // Silently fail if we can't create the document — don't crash the session
            print("Failed to create handoff document: \(error)")
        }
    }

    public enum SessionError: LocalizedError {
        case sessionNotFound(String)
        case unknownAgent(AgentKind)
        case retryLimitReached(String)
        case unknownModel(String, AgentKind)

        public var errorDescription: String? {
            switch self {
            case .sessionNotFound(let id):
                return "Session not found: \(id)"
            case .unknownAgent(let agent):
                return "Unknown agent: \(agent)"
            case .retryLimitReached(let id):
                return "Gave up recovering session \(id) after repeated failures"
            case .unknownModel(let name, let agent):
                return "\(agent.rawValue) has no model called \"\(name)\""
            }
        }
    }
}
