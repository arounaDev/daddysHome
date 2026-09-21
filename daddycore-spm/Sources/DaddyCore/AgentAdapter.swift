import Foundation

public enum ApprovalPolicy: String {
    case safeAuto = "safe-auto"
    case fullBypass = "full-bypass"
}

/// What a launch should do about the conversation that came before it.
///
/// This is a whole-launch concern rather than a flag to append, because not
/// every CLI expresses it as a flag: Codex resumes through a *subcommand*
/// (`codex resume [flags] <id>`), which no amount of appending can produce.
public enum Resumption: Equatable, Sendable {
    /// A new conversation. `sessionID` is Daddy's chosen id for it, used by
    /// the CLIs that let a caller pre-assign one; the rest ignore it and mint
    /// their own.
    case fresh(sessionID: String?)

    /// Reopen this exact conversation.
    case conversation(id: String)

    /// Reopen whichever conversation in this directory is newest. The fallback
    /// for CLIs whose ids Daddy cannot know at launch — and the reason sibling
    /// agents in one project used to collide.
    case mostRecent
}

public protocol AgentAdapter: AnyObject {
    static var kind: AgentKind { get }
    static var executablePath: String { get }

    /// What this CLI treats as "stop what you are doing, but stay alive".
    /// Claude and Cursor listen for ESC; Codex and OpenCode want Ctrl-C.
    var interruptInput: TerminalInput { get }

    func launchArgs(
        cwd: URL,
        model: ModelRef?,
        approvalPolicy: ApprovalPolicy,
        resumption: Resumption
    ) -> [String]

    /// Whether this CLI can reopen a previous conversation at all.
    ///
    /// Relaunching without it gets you the same agent in the same directory
    /// with no memory of what you were doing, which is rarely what "relaunch"
    /// means to the person clicking it.
    var canReopenConversations: Bool { get }

    /// Arguments that append `text` to this CLI's system prompt, or nil if it
    /// has no such flag.
    ///
    /// A system prompt is the right home for a work mode: it cannot be
    /// compacted away halfway through a long session, the way an opening
    /// message can. Only Claude Code offers it, so for the others the mode is
    /// carried by `AGENTS.md` and by an explicit switch message.
    func systemPromptArgs(_ text: String) -> [String]?

    /// Arguments that enforce as much of `policy` as this CLI can express.
    ///
    /// A work mode is a budget, and the half of it that can be a flag should
    /// be a flag. Saying "use no subagents" in a system prompt is a request;
    /// denying the editing tools at launch is not. Each CLI can express a
    /// different amount of it, so what this cannot enforce falls through to
    /// `SessionPolicy.promptClause` and is merely said.
    func policyArgs(_ policy: ModePolicy) -> [String]

    /// Whether this CLI lets the caller choose the conversation's id before it
    /// starts.
    ///
    /// Only Claude Code does (`--session-id`). It is the difference between
    /// knowing which conversation a card owns and guessing that it is the most
    /// recent one in the directory — which is wrong the moment two agents run
    /// in the same project.
    var mintsSessionID: Bool { get }

    func modelFlagValue(for humanName: String) -> String?

    func sendPrompt(_ text: String, to pty: PTYProcess) throws

    /// Drop text into the composer without submitting. Dispatch from the
    /// board uses this so you can edit before hitting enter.
    func pastePrompt(_ text: String, to pty: PTYProcess) throws

    func selectModel(_ model: ModelRef, on pty: PTYProcess) throws

    func interrupt(_ pty: PTYProcess) throws

    /// Tell an agent that has stopped — interrupted, or paused waiting on you —
    /// to keep going.
    func resume(_ pty: PTYProcess) throws

    /// What the agent's terminal currently *shows*, not the bytes that produced
    /// it. See `OutputHeuristics` for why that distinction is the whole fix.
    func detectState(from screen: ScreenSnapshot) -> AgentState
}

// Every adapter used to carry its own copy of these four, identical except for
// the interrupt byte. That duplication is why one bug had to be fixed four
// times. They live here now; an adapter overrides only what it genuinely does
// differently.
extension AgentAdapter {

    /// Most CLIs cannot be told what to call a conversation before it exists.
    public var mintsSessionID: Bool { false }

    /// Most CLIs have no way to append to their system prompt.
    public func systemPromptArgs(_ text: String) -> [String]? { nil }

    /// A CLI that cannot express any of it enforces none of it. The policy
    /// still reaches the agent as prompt text; it just has nothing behind it.
    public func policyArgs(_ policy: ModePolicy) -> [String] { [] }

    /// The plain form, for callers with no opinion about history.
    public func launchArgs(
        cwd: URL,
        model: ModelRef?,
        approvalPolicy: ApprovalPolicy
    ) -> [String] {
        launchArgs(
            cwd: cwd,
            model: model,
            approvalPolicy: approvalPolicy,
            resumption: .fresh(sessionID: nil)
        )
    }

    public func sendPrompt(_ text: String, to pty: PTYProcess) throws {
        try pty.send(.text(text))
        // A TTY submits on carriage return. `\n` is a line feed, which some of
        // these composers insert as a newline instead of sending.
        try pty.send(.key(.enter))
    }

    public func pastePrompt(_ text: String, to pty: PTYProcess) throws {
        try pty.send(.text(text))
    }

    public func selectModel(_ model: ModelRef, on pty: PTYProcess) throws {
        try sendPrompt("/model " + model.rawValue, to: pty)
    }

    public func interrupt(_ pty: PTYProcess) throws {
        try pty.send(interruptInput)
    }

    public func resume(_ pty: PTYProcess) throws {
        try sendPrompt("continue", to: pty)
    }
}

public final class ClaudeAdapter: AgentAdapter {
    public static let kind = AgentKind.claude
    public static let executablePath = "claude"

    public let interruptInput = TerminalInput.key(.escape)

    public let canReopenConversations = true

    /// `claude --session-id <uuid>` names the conversation at launch, so Daddy
    /// knows which file on disk belongs to which card without having to guess
    /// at the newest one.
    public let mintsSessionID = true

    /// From `claude --help`: `--append-system-prompt <prompt>`.
    public func systemPromptArgs(_ text: String) -> [String]? {
        ["--append-system-prompt", text]
    }

    /// Claude expresses more of a mode policy as flags than any of the others.
    ///
    /// From `claude --help`:
    ///   `--effort <level>` (low, medium, high, xhigh, max)
    ///   `--disallowedTools <tools...>` — comma or space separated
    ///   `--strict-mcp-config` — ignore every MCP configuration but `--mcp-config`
    public func policyArgs(_ policy: ModePolicy) -> [String] {
        var args = ["--effort", policy.effort.rawValue]

        if policy.deniesEditingTools {
            // Comma-separated in a single argument, not three separate ones.
            // The flag is variadic, so spelled as separate argv entries it
            // would swallow whichever flag came after it — and a swallowed
            // `--session-id` is a card that has lost its conversation.
            //
            // These three names are checked against the installed CLI, which
            // warns on the terminal for a name it does not know — in a window
            // the human is watching, a typo here is visible noise as well as a
            // denial that silently does nothing.
            args += ["--disallowedTools", "Edit,Write,NotebookEdit"]
        }

        if policy.toolProfile == .minimal {
            // No `--mcp-config` accompanies this, so it resolves to no MCP
            // servers at all — built-in tools only, which is the point.
            args.append("--strict-mcp-config")
        }

        return args
    }

    public init() {}

    public func launchArgs(
        cwd: URL,
        model: ModelRef?,
        approvalPolicy: ApprovalPolicy,
        resumption: Resumption
    ) -> [String] {
        var args: [String]

        switch approvalPolicy {
        case .safeAuto:
            args = ["--permission-mode", "acceptEdits"]
        case .fullBypass:
            args = ["--dangerously-skip-permissions"]
        }

        if let model = model {
            args.append("--model")
            args.append(model.rawValue)
        }

        switch resumption {
        case .fresh(let sessionID):
            // Must be a UUID; Claude rejects anything else outright, and a
            // rejected flag means the agent never starts.
            if let sessionID, UUID(uuidString: sessionID) != nil {
                args += ["--session-id", sessionID]
            }
        case .conversation(let id):
            args += ["--resume", id]
        case .mostRecent:
            args.append("--continue")
        }

        return args
    }

    public func modelFlagValue(for humanName: String) -> String? {
        let normalized = humanName.lowercased().trimmingCharacters(in: .whitespaces)

        let aliases: [String: String] = [
            "opus": "opus",
            "sonnet": "sonnet",
            "haiku": "haiku",
            "fable": "fable",
        ]

        return aliases[normalized]
    }

    public func detectState(from screen: ScreenSnapshot) -> AgentState {
        // Claude Code has no idle prompt to end on. It keeps a mode footer
        // pinned below the composer at all times:
        //
        //   ⏵⏵ accept edits on (shift+tab to cycle) · ↔ for agents
        //
        // That footer is there whether or not the agent is busy, so on its own
        // it is not an idle signal — it means "there is a composer here". Idle
        // is that, *and* nothing in the live status area saying otherwise.
        //
        // On the old byte stream this could not work: the "last line" of a
        // redraw is whatever bytes were written last, which is usually cursor
        // positioning rather than the footer. On a rendered screen the bottom
        // of the screen is the bottom of the screen.
        let tail = screen.tail(OutputHeuristics.tailRows).lowercased()
        let hasComposer = tail.contains("accept edits on")
            || tail.contains("shift+tab to cycle")
            || tail.contains("bypass permissions")
            || tail.contains("for shortcuts")

        if hasComposer,
           !OutputHeuristics.indicatesWorking(screen),
           !OutputHeuristics.indicatesRateLimit(screen),
           !OutputHeuristics.indicatesFailure(screen) {
            return .ready
        }

        return OutputHeuristics.resolve(screen: screen) { screen in
            OutputHeuristics.endsWithPrompt(screen)
        }
    }
}

public final class CodexAdapter: AgentAdapter {
    public static let kind = AgentKind.codex
    public static let executablePath = "codex"

    public let interruptInput = TerminalInput.interrupt

    /// Confirmed against the installed CLI, which the previous "unknown" note
    /// here had not been. `codex resume --help`:
    ///
    ///     Usage: codex resume [OPTIONS] [SESSION_ID] [PROMPT]
    ///       --last   Continue the most recent session without showing the picker
    ///
    /// It takes `-m`, `-s` and `-a` like a normal launch, so the flags below
    /// are unchanged by resuming — only their position moves.
    public let canReopenConversations = true

    public init() {}

    public func launchArgs(
        cwd: URL,
        model: ModelRef?,
        approvalPolicy: ApprovalPolicy,
        resumption: Resumption
    ) -> [String] {
        // `resume` is a subcommand, so it has to come first — before the flags,
        // not after them. This is why the whole list is built here rather than
        // having resume arguments appended by the caller.
        var args: [String] = []
        if case .fresh = resumption {} else { args.append("resume") }

        if let model = model {
            args.append("-m")
            args.append(model.rawValue)
        }

        switch approvalPolicy {
        case .safeAuto:
            args += ["--ask-for-approval", "on-request", "--sandbox", "workspace-write"]
        case .fullBypass:
            args += ["--ask-for-approval", "never", "--sandbox", "danger-full-access"]
        }

        // The session id is a positional argument and must come after the
        // flags that take values, or it would be swallowed as one of them.
        switch resumption {
        case .fresh:
            break
        case .conversation(let id):
            args.append(id)
        case .mostRecent:
            args.append("--last")
        }

        return args
    }

    /// Codex has no flag for any of this, but it has `-c key=value`, which
    /// overrides the same keys `~/.codex/config.toml` sets.
    ///
    /// The value is parsed as TOML and the quotes are part of the argument,
    /// not shell punctuation — nothing here goes through a shell, so they have
    /// to be written literally. This is the form `codex --help` documents
    /// (`-c model="o3"`). The bare word is also accepted by the installed CLI,
    /// but so is every other string: Codex validates neither the key nor the
    /// value, which means a wrong one here fails silently rather than loudly.
    /// Spelled the documented way for that reason.
    ///
    /// Tool scope and read-only have no equivalent; they fall through to the
    /// prompt clause.
    public func policyArgs(_ policy: ModePolicy) -> [String] {
        ["-c", "model_reasoning_effort=\"\(policy.effort.rawValue)\""]
    }

    public func modelFlagValue(for humanName: String) -> String? {
        humanName.lowercased().trimmingCharacters(in: .whitespaces)
    }

    public func detectState(from screen: ScreenSnapshot) -> AgentState {
        // The check here was once `contains(">") || contains("codex")`, which
        // is true of essentially every byte Codex ever prints.
        OutputHeuristics.resolve(screen: screen) { screen in
            OutputHeuristics.endsWithPrompt(screen)
        }
    }
}

public final class CursorAdapter: AgentAdapter {
    public static let kind = AgentKind.cursor
    public static let executablePath = "agent"

    public let interruptInput = TerminalInput.key(.escape)

    /// From `agent --help`: `--resume [chatId]  Select a session to resume`
    /// and `--continue  Continue previous session`.
    public let canReopenConversations = true

    public init() {}

    public func launchArgs(
        cwd: URL,
        model: ModelRef?,
        approvalPolicy: ApprovalPolicy,
        resumption: Resumption
    ) -> [String] {
        var args: [String] = []

        if let model = model {
            args.append("--model")
            args.append(model.rawValue)
        }

        // From `agent --help`:
        //   --auto-review  server classifier auto-runs safe tool calls and
        //                  prompts for the rest
        //   -f, --force    allow commands unless explicitly denied (`--yolo`
        //                  is an alias)
        switch approvalPolicy {
        case .safeAuto:
            args.append("--auto-review")
        case .fullBypass:
            args.append("--force")
        }

        switch resumption {
        case .fresh:
            break
        case .conversation(let id):
            args += ["--resume", id]
        case .mostRecent:
            args.append("--continue")
        }

        return args
    }

    /// From `agent --help`: `--mode <mode>` takes `plan` or `ask`, both of
    /// which are read-only.
    ///
    /// Only the read-only half maps, and only when the session asked for it to
    /// be enforced — see `ModePolicy.enforcesReadOnly`, which is off by
    /// default. `--mode plan` looks like the obvious home
    /// for Plan & Build and is the wrong one — Cursor's plan mode never writes,
    /// and Plan & Build has to write once the plan is agreed. Effort is
    /// expressible only inside a parameterised model string
    /// (`claude-opus-4-8[effort=high]`), and rewriting the model the human
    /// picked to smuggle it in is worse than not having it.
    public func policyArgs(_ policy: ModePolicy) -> [String] {
        policy.deniesEditingTools ? ["--mode", "ask"] : []
    }

    public func modelFlagValue(for humanName: String) -> String? {
        humanName.lowercased().trimmingCharacters(in: .whitespaces)
    }

    public func detectState(from screen: ScreenSnapshot) -> AgentState {
        OutputHeuristics.resolve(screen: screen) { screen in
            OutputHeuristics.endsWithPrompt(screen)
        }
    }
}

public final class OpenCodeAdapter: AgentAdapter {
    public static let kind = AgentKind.opencode
    public static let executablePath = "opencode"

    public let interruptInput = TerminalInput.interrupt

    /// From `opencode --help`: `-c, --continue  continue the last session` and
    /// `-s, --session  session id to continue`.
    public let canReopenConversations = true

    public init() {}

    public func launchArgs(
        cwd: URL,
        model: ModelRef?,
        approvalPolicy: ApprovalPolicy,
        resumption: Resumption
    ) -> [String] {
        var args: [String] = []

        if let model = model {
            args.append("-m")
            args.append(model.rawValue)
        }

        // From `opencode --help`: `--auto` auto-approves permissions that are
        // not explicitly denied. There is no separate "safe" flag — prompting
        // is the default — so safeAuto simply adds nothing.
        if approvalPolicy == .fullBypass {
            args.append("--auto")
        }

        switch resumption {
        case .fresh:
            break
        case .conversation(let id):
            args += ["--session", id]
        case .mostRecent:
            args.append("--continue")
        }

        return args
    }

    /// `opencode agent list` ships a primary `plan` agent that is read-only,
    /// which is the only part of a mode policy this CLI can be told at launch —
    /// and only when the session opted into enforcing it.
    /// Effort and tool scope belong to the agent definition rather than the
    /// command line, so they fall through to the prompt clause.
    public func policyArgs(_ policy: ModePolicy) -> [String] {
        policy.deniesEditingTools ? ["--agent", "plan"] : []
    }

    public func modelFlagValue(for humanName: String) -> String? {
        humanName.lowercased().trimmingCharacters(in: .whitespaces)
    }

    public func detectState(from screen: ScreenSnapshot) -> AgentState {
        OutputHeuristics.resolve(screen: screen) { screen in
            OutputHeuristics.endsWithPrompt(screen)
        }
    }
}
