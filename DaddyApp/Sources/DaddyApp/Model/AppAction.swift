import Foundation
import DaddyCore

/// The single seam every kanban/dispatch action goes through, whether it was
/// triggered by a click or (later) a voice command. Everything here is pure
/// delegation to the `MockStore`/`MockStore+Orchestrator` methods that already
/// do the work — this adds no new state and no new persistence path.
enum AppAction {
    case createWorkItem(OrchestratorWorkItem)
    case moveWorkItem(id: UUID, status: OrchestratorWorkStatus, category: OrchestratorWorkCategory?)
    case replaceWorkItem(OrchestratorWorkItem)
    case deleteWorkItem(id: UUID)
    case dispatchOntoAgent(workItemID: UUID, agentID: String)
    case dispatchLaunchingAgent(workItemID: UUID, kind: AgentKind)
    case dispatchBundleOntoAgent(workItemIDs: [UUID], agentID: String)
    case dispatchBundleLaunchingAgent(workItemIDs: [UUID], kind: AgentKind)
    case launchSession(kind: AgentKind, projectID: String)
}

/// A brief on-screen confirmation for a voice-triggered action. `undoAction`
/// is nil for actions that aren't meaningfully reversible (dispatch/launch).
struct VoiceToast: Identifiable {
    let id = UUID()
    let label: String
    let undoAction: AppAction?
    /// SF Symbol shown beside the label. Voice-triggered toasts default to the
    /// waveform; non-voice ones (e.g. a keyboard delete) pass `nil` to omit it.
    var icon: String? = "waveform"
    /// True when the label explains why nothing happened, rather than
    /// confirming that something did. Only the spoken layer reads it so far —
    /// the two are announced as separate events, because wanting to hear your
    /// confirmations and wanting to hear your failures are different wants.
    var isFailure = false
}

enum AppActionOutcome {
    case workItemCreated(OrchestratorWorkItem)
    case workItemMoved(OrchestratorWorkItem)
    case workItemUnchanged(OrchestratorWorkItem)
    case workItemReplaced(OrchestratorWorkItem)
    case workItemDeleted(id: UUID)
    case dispatched(item: OrchestratorWorkItem, agent: MockAgent)
    case bundleDispatched(items: [OrchestratorWorkItem], agent: MockAgent)
    case sessionLaunched(MockAgent)
    case failed(String)
}

@MainActor
struct AppActionDispatcher {
    let store: MockStore

    @discardableResult
    func perform(_ action: AppAction) -> AppActionOutcome {
        switch action {
        case .createWorkItem(let item):
            store.addWorkItem(item)
            return .workItemCreated(item)

        case .moveWorkItem(let id, let status, let category):
            let changed = store.moveWorkItem(id, to: status, category: category)
            guard let item = store.workItem(id) else {
                return .failed("Work item no longer exists")
            }
            return changed ? .workItemMoved(item) : .workItemUnchanged(item)

        case .replaceWorkItem(let item):
            store.replaceWorkItem(item)
            return .workItemReplaced(item)

        case .deleteWorkItem(let id):
            guard store.workItem(id) != nil else {
                return .failed("Work item no longer exists")
            }
            store.deleteWorkItem(id)
            return .workItemDeleted(id: id)

        case .dispatchOntoAgent(let workItemID, let agentID):
            guard let agent = store.agents.first(where: { $0.id == agentID }) else {
                return .failed("That session is no longer running")
            }
            guard store.workItem(workItemID) != nil else {
                return .failed("Work item no longer exists")
            }
            store.dispatchWorkItem(workItemID, onto: agent)
            guard let item = store.workItem(workItemID) else {
                return .failed("Work item no longer exists")
            }
            return .dispatched(item: item, agent: agent)

        case .dispatchLaunchingAgent(let workItemID, let kind):
            guard store.workItem(workItemID) != nil else {
                return .failed("Work item no longer exists")
            }
            store.dispatchWorkItem(workItemID, launching: kind)
            guard let item = store.workItem(workItemID),
                  let sessionID = item.linkedSessionIDs.last,
                  let agent = store.agents.first(where: { $0.id == sessionID }) else {
                return .failed(store.launchError ?? "Could not launch a session for this work item")
            }
            return .dispatched(item: item, agent: agent)

        case .dispatchBundleOntoAgent(let workItemIDs, let agentID):
            guard let agent = store.agents.first(where: { $0.id == agentID }) else {
                return .failed("That session is no longer running")
            }
            store.dispatchWorkItemBundle(workItemIDs, onto: agent)
            let items = workItemIDs.compactMap { store.workItem($0) }
            guard !items.isEmpty else { return .failed("Work items no longer exist") }
            return .bundleDispatched(items: items, agent: agent)

        case .dispatchBundleLaunchingAgent(let workItemIDs, let kind):
            store.dispatchWorkItemBundle(workItemIDs, launching: kind)
            let items = workItemIDs.compactMap { store.workItem($0) }
            guard let first = items.first,
                  let sessionID = first.linkedSessionIDs.last,
                  let agent = store.agents.first(where: { $0.id == sessionID }) else {
                return .failed(store.launchError ?? "Could not launch a session for this bundle")
            }
            return .bundleDispatched(items: items, agent: agent)

        case .launchSession(let kind, let projectID):
            guard let project = store.project(projectID) else {
                return .failed("That project is no longer available")
            }
            guard let agent = store.launchReal(kind, in: project) else {
                return .failed(store.launchError ?? "Could not launch a session")
            }
            // Launching a session from the Launch menu or the compass takes you
            // into it. Landing back on the grid meant a second click to reach
            // the thing you just started, every time.
            //
            // This sits here rather than in `launchReal` on purpose: dispatching
            // a work item from the board and handing off context also launch
            // sessions, and neither should pull you out of what you were doing.
            store.openDetail(agent.id)
            return .sessionLaunched(agent)
        }
    }
}
