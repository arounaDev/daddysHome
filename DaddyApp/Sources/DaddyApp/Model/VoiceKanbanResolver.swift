import Foundation
import DaddyCore

/// Resolves the raw string hints `CommandParser`'s kanban intents carry
/// against live app state — project/column/category names `CommandParser`
/// (in DaddyCore) has no access to — into a concrete `AppAction`.
///
/// Matching is deliberately simple (normalized substring/equality, plus a
/// small hand-written category alias table), not a fuzzy-matching library —
/// same spirit as `CommandParser`'s own alias tables.
@MainActor
struct VoiceKanbanResolver {
    let store: MockStore

        enum Resolution {
        /// A reversible action: `undoAction` restores the prior state.
        case reversible(AppAction, confirmLabel: String, undoAction: AppAction)
        /// Not meaningfully reversible (e.g. dispatch launches a session) —
        /// confirmation only, no Undo button.
        case irreversible(AppAction, confirmLabel: String)
        /// Open the board's agent picker without moving yet — same gate as
        /// dropping a card onto DISPATCHED.
        case boardDispatch(ids: [UUID], confirmLabel: String)
        case failed(String)
    }

    func resolve(_ intent: CommandIntent) -> Resolution {
        switch intent {
        case .createWorkItem(let title, let projectHint, let statusHint, let categoryHint):
            return resolveCreate(title: title, projectHint: projectHint, statusHint: statusHint, categoryHint: categoryHint)
        case .moveWorkItem(let targetHint, let statusHint, let categoryHint):
            return resolveMove(targetHint: targetHint, statusHint: statusHint, categoryHint: categoryHint)
        case .dispatchWorkItem(let targetHint, let agentHint):
            return resolveDispatch(targetHint: targetHint, agentHint: agentHint)
        default:
            return .failed("not a kanban command")
        }
    }

    // MARK: - Create

    private func resolveCreate(
        title: String,
        projectHint: String?,
        statusHint: String?,
        categoryHint: String?
    ) -> Resolution {
        if let projectHint, resolveProject(projectHint) == nil {
            return .failed("didn't catch which project — \"\(projectHint)\" doesn't match a project")
        }
        if let categoryHint, resolveCategory(categoryHint) == nil {
            return .failed("didn't catch the category \"\(categoryHint)\"")
        }

        let projectID = projectHint.flatMap { resolveProject($0)?.id }
        let status = statusHint.flatMap(resolveStatus) ?? .inbox
        let category = categoryHint.flatMap(resolveCategory) ?? .other
        let cleanTitle = title.prefix(1).uppercased() + title.dropFirst()

        let item = OrchestratorWorkItem(
            title: cleanTitle,
            summary: "",
            rawCapture: title,
            category: category,
            status: status,
            projectID: projectID
        )

        return .reversible(
            .createWorkItem(item),
            confirmLabel: "Added \"\(item.title)\" to \(status.title)",
            undoAction: .deleteWorkItem(id: item.id)
        )
    }

    // MARK: - Move

    private func resolveMove(targetHint: String, statusHint: String?, categoryHint: String?) -> Resolution {
        guard let item = resolveItem(targetHint) else {
            return .failed("couldn't find a card matching \"\(targetHint)\"")
        }
        if let statusHint, resolveStatus(statusHint) == nil {
            return .failed("didn't catch the status \"\(statusHint)\"")
        }
        if let categoryHint, resolveCategory(categoryHint) == nil {
            return .failed("didn't catch the category \"\(categoryHint)\"")
        }

        let status = statusHint.flatMap(resolveStatus)
        let category = categoryHint.flatMap(resolveCategory)
        guard status != nil || category != nil else {
            return .failed("didn't catch where to move \"\(item.title)\"")
        }

        // DISPATCHED always means "start a session" — never a silent status
        // write. Hand the cohort to the board picker (bundle members included).
        if status == .dispatched {
            let ids: [UUID]
            if let bundleID = item.bundleID {
                let members = store.orchestratorWorkItems.filter { $0.bundleID == bundleID }
                ids = members.isEmpty ? [item.id] : members.map(\.id)
            } else {
                ids = [item.id]
            }
            return .boardDispatch(
                ids: ids,
                confirmLabel: "Pick an agent for \"\(item.title)\""
            )
        }

        return .reversible(
            .moveWorkItem(id: item.id, status: status ?? item.status, category: category),
            confirmLabel: "Moved \"\(item.title)\"",
            undoAction: .moveWorkItem(id: item.id, status: item.status, category: item.category)
        )
    }

    // MARK: - Dispatch

    private func resolveDispatch(targetHint: String, agentHint: AgentKind?) -> Resolution {
        guard let item = resolveItem(targetHint) else {
            return .failed("couldn't find a card matching \"\(targetHint)\"")
        }
        guard let kind = agentHint else {
            return .failed("didn't catch which agent to send \"\(item.title)\" to")
        }
        return .irreversible(
            .dispatchLaunchingAgent(workItemID: item.id, kind: kind),
            confirmLabel: "Dispatched \"\(item.title)\" to \(kind.rawValue)"
        )
    }

    // MARK: - Matching against live state

    private func resolveProject(_ hint: String) -> MockProject? {
        let needle = normalize(hint)
        return store.projects.first { normalize($0.name) == needle }
            ?? store.projects.first { normalize($0.name).contains(needle) || needle.contains(normalize($0.name)) }
    }

    private func resolveStatus(_ hint: String) -> OrchestratorWorkStatus? {
        let needle = normalize(hint)
        return OrchestratorWorkStatus.boardColumns.first { normalize($0.title) == needle }
    }

    private static let categoryAliases: [String: OrchestratorWorkCategory] = [
        "ui": .uiux, "ux": .uiux, "ui ux": .uiux, "uiux": .uiux, "ui slash ux": .uiux,
        "feature": .futureFeatures, "features": .futureFeatures, "future feature": .futureFeatures,
        "future features": .futureFeatures,
        "bug": .bugs, "bugs": .bugs,
        "concept": .concepts, "concepts": .concepts,
        "other": .other, "misc": .other,
    ]

    private func resolveCategory(_ hint: String) -> OrchestratorWorkCategory? {
        let needle = normalize(hint)
        if let mapped = Self.categoryAliases[needle] { return mapped }
        return OrchestratorWorkCategory.allCases.first {
            normalize($0.title) == needle || normalize($0.boardTitle) == needle
        }
    }

    private func resolveItem(_ hint: String) -> OrchestratorWorkItem? {
        let needle = normalize(hint)
        guard !needle.isEmpty else { return nil }
        return store.orchestratorWorkItems.first { normalize($0.title).contains(needle) }
            ?? store.orchestratorWorkItems.first { needle.contains(normalize($0.title)) }
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
