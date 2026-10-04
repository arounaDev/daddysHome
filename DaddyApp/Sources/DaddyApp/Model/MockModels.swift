import Foundation
import DaddyCore

// MARK: - View Models
//
// DaddyCore's `Session` is a non-observable `final class`, so SwiftUI cannot
// see mutations on it. These are value types so the `@Observable` store can
// diff them properly. `AgentKind` and `AgentState` are reused straight from
// DaddyCore, so `StateColors` and the badge rendering stay shared with the
// real session path.

struct MockProject: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    /// Nil for sidebar roots; otherwise the selectable directory containing it.
    let parentID: String?
}

/// One of your own shells in the right-hand pane, as the tab strip sees it.
///
/// The pty itself lives in `ShellSessions`, keyed by this `id`. What is here is
/// only what the interface needs: which project the tab belongs to and the
/// number shown after the project name. `ordinal` counts up from the highest
/// ever issued rather than from the tab count, so closing the middle tab never
/// leaves two shells called "daddy 2".
struct ShellTab: Identifiable, Hashable {
    let id: String
    let projectID: String
    let ordinal: Int
}

/// A project open in the strip across the top of the fleet.
///
/// A tab is a project with its own place on screen: its own agents, its own
/// shell, its own tree. What is remembered here is only what the interface
/// needs to put you back where you left it — which agent the tab was showing,
/// whether it was in focus mode, and which folders its tree had open. The
/// processes themselves are keyed by agent id, not tab id: closing a tab
/// never touches an agent, and opening the same project again finds everything
/// still running.
struct ProjectTab: Identifiable, Hashable, Codable {
    let projectID: String
    var title: String

    /// Which agent's output this tab was showing. Nil means "land on whatever
    /// the project is currently best at" — see `applyActiveTabSelection`.
    var selectedAgentID: String?

    /// Which agent was in focus mode, if any.
    var detailAgentID: String?

    /// The tree expansion this tab owns, by absolute path.
    var expandedPaths: Set<String>

    var id: String { projectID }
}

struct MockAgent: Identifiable {
    let id: String
    let projectID: String
    let agent: AgentKind
    var workUnitID: String
    var model: String
    var state: AgentState
    var startedAt: Date

    /// When the agent itself last printed something — not when you last clicked
    /// a button at it. `MockStore.tick()` copies this from the live session
    /// every second; the action methods seed it so a fresh card is not blank.
    var lastOutputAt: Date

    /// The last thing the agent actually said, read off its rendered screen.
    ///
    /// Cached here rather than derived in a view body: rendering the screen
    /// costs a pass over every row, and a tile would ask for this once per
    /// agent per frame. `tick()` computes it once a second.
    var lastLine: String = ""

    /// What this conversation is about, from the CLI's own title for it.
    /// Nil for the providers that do not name their conversations, and for the
    /// first moments of any session.
    var title: String?

    /// What to call this session on screen.
    ///
    /// The work-unit id is a filing reference — `live-0827-1041-3` — and it was
    /// what every card, tooltip and switcher row showed. It says when the
    /// session started and nothing about what it is for, which is the only
    /// question you are asking when you are looking at four of them.
    var label: String { title ?? workUnitID }

    /// How full this session's context window is, or why Daddy cannot say.
    /// `ContextHandoff` watches it; `ContextMeter` shows it.
    var context: ContextAvailability = .notReported

    var contextPercent: Double? { context.percent }

    /// Non-nil when this card is backed by a real `SessionManager` session and
    /// a live pty. Nil means it is seeded demo data with a scripted transcript.
    var sessionID: String?

    /// True when a real process is behind this card, as opposed to seeded
    /// demo data. Distinct from `isRunning`, which is about agent state.
    var isRealSession: Bool { sessionID != nil }

    /// What to show where the model goes.
    ///
    /// Empty means Daddy has not read the agent's own record yet — true for
    /// the first moments of a session, and permanently for any CLI that does
    /// not write one down. Showing "—" is the honest answer; the hardcoded
    /// guess this replaced was wrong for three of the four providers.
    var modelLabel: String { model.isEmpty ? "—" : model }

    var displayName: String { agent.rawValue.uppercased() }

    var uptime: String {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m \(elapsed % 60)s" }
        return "\(elapsed / 3600)h \((elapsed % 3600) / 60)m"
    }

    var isLive: Bool {
        if case .exited = state { return false }
        return true
    }

    /// Mid-task. Interrupting is the useful control here; continuing is not.
    var isBusy: Bool {
        if case .working = state { return true }
        return false
    }

    /// 0-based start-order among live same-provider siblings. Nil when this
    /// provider has only one live agent — the logo is enough.
    static func siblingIndex(for agent: MockAgent, among agents: [MockAgent]) -> Int? {
        let siblings = agents
            .filter { $0.isLive && $0.agent == agent.agent }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id < $1.id
            }
        guard siblings.count >= 2 else { return nil }
        return siblings.firstIndex { $0.id == agent.id }
    }

    /// I, II, III… from a 0-based sibling index. Roman has no zero.
    static func romanNumeral(forZeroBased index: Int) -> String {
        var n = index + 1
        let table: [(Int, String)] = [
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var out = ""
        for (value, glyph) in table {
            while n >= value {
                out += glyph
                n -= value
            }
        }
        return out
    }
}

struct MockWorkUnit: Identifiable {
    enum Status: String {
        case active = "ACTIVE"
        case idle = "IDLE"
        case done = "DONE"
    }

    let id: String
    let projectID: String
    var name: String
    var status: Status
    var summary: String
    var lastActivityAt: Date
}

struct VoiceEntry: Identifiable {
    let id = UUID()
    let at: Date
    let transcript: String
    let resolution: String
    let didSucceed: Bool
}

/// A work item waiting to land in a live composer's input.
///
/// Not written to the pty until `TerminalSurface` is attached: dumping a
/// multi-line prompt into a detached session is what froze the pane.
struct PendingComposerPaste: Equatable {
    let id: UUID
    let agentID: String
    let text: String

    init(agentID: String, text: String) {
        self.id = UUID()
        self.agentID = agentID
        self.text = text
    }
}

// MARK: - Formatting

func formatTimeAgo(_ date: Date) -> String {
    let elapsed = Date().timeIntervalSince(date)
    if elapsed < 60 { return "now" }
    if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
    return "\(Int(elapsed / 3600))h"
}

/// `@MainActor` because `RelativeDateTimeFormatter` is not `Sendable` and this
/// one is only ever touched while drawing a menu row.
@MainActor
extension PastChat {
    /// "2h ago" rather than a timestamp: which conversation you want is a
    /// question of how long ago you had it, not of what o'clock it was.
    var age: String {
        Self.relativeAge.localizedString(for: updatedAt, relativeTo: Date())
    }

    private static let relativeAge: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
