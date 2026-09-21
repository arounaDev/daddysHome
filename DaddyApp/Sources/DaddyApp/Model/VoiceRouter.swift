import Foundation
import DaddyCore

// The missing link. `CommandParser` has existed and been unit-tested since
// milestone 5, and nothing ever called it: the voice view appended a log entry
// and stopped. This turns a parsed command into something that actually reaches
// a running agent.
//
// Deliberately not a speech recogniser. Dictation is HEX's job — it is already
// system-wide and already has the hotkey. Daddy reads the text that lands in its
// own composer while it is frontmost, which needs no microphone permission and
// no Full Disk Access. On this branch that costs nothing, because the terminal
// is in Daddy: you are already here.

struct VoiceOutcome {
    let summary: String
    let didSucceed: Bool

    static func ok(_ summary: String) -> VoiceOutcome {
        VoiceOutcome(summary: summary, didSucceed: true)
    }

    static func refused(_ summary: String) -> VoiceOutcome {
        VoiceOutcome(summary: summary, didSucceed: false)
    }
}

@MainActor
struct VoiceRouter {
    let store: MockStore

    private var parser: CommandParser { store.commandParser }

    func route(_ transcript: String) -> VoiceOutcome {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .refused("nothing heard") }

        let command = parser.parse(trimmed)

        // Kanban intents don't target a live agent session — resolve and
        // execute through the same seam manual clicks use.
        switch command.intent {
        case .createWorkItem, .moveWorkItem, .dispatchWorkItem:
            return routeKanban(command.intent)
        default:
            break
        }

        // Launch intent doesn't need a running target.
        if case .launch = command.intent {
            return launchAgent(command)
        }

        guard let target = resolveTarget(command) else {
            return .refused(
                command.agent.map { "no live \($0.rawValue) session" }
                    ?? "no agent selected"
            )
        }

        switch command.intent {
        case .stop:
            store.stop(target.id)
            return .ok("stopped \(target.displayName)")

        case .interrupt:
            store.interrupt(target.id)
            return .ok("interrupted \(target.displayName)")

        case .work, .resume:
            // "Claude, fix the login bug" carries an instruction; "Claude,
            // continue" does not. One is a new prompt, the other is a nudge.
            if let prompt = command.prompt, isInstruction(prompt) {
                store.send(prompt, to: target.id)
                return .ok("sent to \(target.displayName): \(prompt)")
            }
            store.resume(target.id)
            return .ok("told \(target.displayName) to continue")

        case .review:
            store.send(command.prompt ?? "review the recent changes", to: target.id)
            return .ok("\(target.displayName) reviewing")

        case .runTests:
            store.send("run the tests", to: target.id)
            return .ok("\(target.displayName) running tests")

        case .switchModel:
            guard let model = command.model else {
                return .refused("no model named")
            }
            return store.switchModel(model, on: target.id)
                ? .ok("\(target.displayName) → \(model)")
                : .refused("\(target.displayName) has no model \"\(model)\"")

        case .handoff:
            guard let kind = command.targetAgent else {
                return .refused("no agent to hand off to")
            }
            store.handOff(target.id, to: kind)
            return .ok("handed \(target.workUnitID) to \(kind.rawValue)")

        case .status:
            return .ok("\(target.displayName): \(StateColors.name(for: target.state).lowercased())")

        case .launch:
            // Handled before resolving target; never reached.
            fatalError("launch intent should be handled before target resolution")

        case .createWorkItem, .moveWorkItem, .dispatchWorkItem:
            // Handled before resolving target; never reached.
            fatalError("kanban intents should be handled before target resolution")

        case .unknown:
            // A sentence with no recognised command word is almost always just
            // something to say to the agent. Pasting it beats discarding it.
            //
            // Pasted, not sent: this is the one path where the words are a
            // raw transcript rather than a command anyone matched on, so it
            // is also the one most likely to have come out wrong. Leaving it
            // in the composer costs a keystroke and buys the chance to read
            // it first. The command cases above still submit — you said a
            // command word, you meant it to run.
            store.paste(trimmed, to: target.id)
            return .ok("pasted to \(target.displayName): \(trimmed)")
        }
    }

    /// Which agent the command is about: the one it names, else the selected one.
    private func resolveTarget(_ command: ParsedCommand) -> MockAgent? {
        if let kind = command.agent {
            let live = store.agents.filter { $0.agent == kind && $0.isLive }
            if let selected = live.first(where: { $0.id == store.selectedAgentID }) {
                return selected
            }
            return live.first
        }
        return store.selectedAgent
    }

    /// A prompt that says what to do, rather than just "keep going".
    private func isInstruction(_ prompt: String) -> Bool {
        let filler: Set<String> = [
            "continue", "keep going", "go", "go on", "resume", "restart",
            "dale", "dal", "segui", "seguí", "prosigue",
        ]
        let cleaned = prompt
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?"))
            .lowercased()
        return !filler.contains(cleaned) && cleaned.split(separator: " ").count > 1
    }

    /// Resolves a kanban intent against live store state and executes it
    /// through `AppActionDispatcher` — the same seam manual clicks use.
    /// Reversible actions get a toast with Undo; dispatch gets a plain
    /// confirmation.
    private func routeKanban(_ intent: CommandIntent) -> VoiceOutcome {
        switch VoiceKanbanResolver(store: store).resolve(intent) {
        case .reversible(let action, let confirmLabel, let undoAction):
            AppActionDispatcher(store: store).perform(action)
            store.showVoiceToast(VoiceToast(label: confirmLabel, undoAction: undoAction))
            return .ok(confirmLabel)

        case .irreversible(let action, let confirmLabel):
            AppActionDispatcher(store: store).perform(action)
            store.showVoiceToast(VoiceToast(label: confirmLabel, undoAction: nil))
            return .ok(confirmLabel)

        case .boardDispatch(let ids, let confirmLabel):
            store.workspace = .board
            store.pendingBoardDispatchIDs = ids
            store.showVoiceToast(VoiceToast(label: confirmLabel, undoAction: nil))
            return .ok(confirmLabel)

        case .failed(let reason):
            store.showVoiceToast(VoiceToast(label: reason, undoAction: nil))
            return .refused(reason)
        }
    }

    /// Launch a new agent in the selected project.
    private func launchAgent(_ command: ParsedCommand) -> VoiceOutcome {
        guard let project = store.selectedProject else {
            return .refused("no project selected")
        }

        guard let kind = command.agent else {
            return .refused("no agent named")
        }

        if store.launchReal(kind, in: project) != nil {
            return .ok("launched \(kind.rawValue) in \(project.name)")
        } else {
            let error = store.launchError ?? "unknown error"
            return .refused("failed to launch: \(error)")
        }
    }
}
