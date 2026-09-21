import Foundation
import DaddyCore

extension MockStore {
    func restoreOrchestratorConversations() {
        let snapshots = orchestratorMarkdownStore.loadConversations()
        for snapshot in snapshots.values {
            setMessages(snapshot.messages, for: snapshot.key)
            setAttachments(snapshot.attachments, for: snapshot.key)
            setPendingAttachmentIDs(snapshot.pendingAttachmentIDs, for: snapshot.key)
            orchestratorConversationCreatedAtByCategory[snapshot.key] = snapshot.createdAt
            orchestratorConversationLongTermByCategory[snapshot.key] = snapshot.keepLongTerm
        }
        applyOrchestratorConversation(for: orchestratorConversationKey(orchestratorCategory))
    }

    func orchestratorChatCount(for category: OrchestratorWorkCategory?) -> Int {
        if let category {
            return orchestratorConversationHasActivity(orchestratorConversationKey(category)) ? 1 : 0
        }

        let keys = Set(
            ["all"] +
            OrchestratorWorkCategory.allCases.map(\.rawValue) +
            Array(orchestratorMessagesByCategory.keys) +
            Array(orchestratorAttachmentsByCategory.keys) +
            Array(orchestratorBusyByCategory.keys)
        )
        return keys.filter(orchestratorConversationHasActivity).count
    }

    func orchestratorCategoryIsBusy(_ category: OrchestratorWorkCategory?) -> Bool {
        guard let category else {
            return orchestratorBusyByCategory.values.contains(true)
        }
        return orchestratorBusyByCategory[orchestratorConversationKey(category)] ?? false
    }

    var currentOrchestratorConversationIsLongTerm: Bool {
        orchestratorConversationLongTermByCategory[orchestratorConversationKey(orchestratorCategory)] ?? false
    }

    func toggleCurrentOrchestratorConversationLongTerm() {
        let key = orchestratorConversationKey(orchestratorCategory)
        guard orchestratorConversationHasActivity(key) else { return }
        var longTermValues = orchestratorConversationLongTermByCategory
        longTermValues[key] = !currentOrchestratorConversationIsLongTerm
        orchestratorConversationLongTermByCategory = longTermValues
        persistOrchestratorConversation(for: key)
    }

    func dismissCurrentOrchestratorError() {
        setError(nil, for: orchestratorConversationKey(orchestratorCategory))
    }

    private static var orchestratorSystemPrompt: String {
        """
        You are an internal project assistant for the operator who built Daddy.
        The operator already knows what you are, what Daddy is, and what the
        available agents do. Do not explain your role, the app, your workflow,
        or your capabilities.

        Answer the actual request immediately. Be direct, concrete, and useful.
        Usually answer in one to three complete sentences or short paragraphs:
        concise, but never cryptic or reduced to a one-word reply. No greetings,
        introductions, motivational framing, metaphors, filler, disclaimers,
        canned offers to help, or repeated context. Do not say "I'm here to
        help" or ask "what are we working on today?" Never restate the user's
        request unless needed to resolve ambiguity. If the request is
        underspecified, ask only the one most useful focused question.

        You do not write code yourself. Use tools when asked to inspect Daddy
        state or save/update an organized work item. Never claim that an agent
        was launched or messaged unless a dispatch was explicitly approved.
        Categories are bugs, uiux, future-features, concepts, and other.
        """
    }

    private static var orchestratorTools: [OllamaTool] {
        [
        OllamaTool(function: .init(
            name: "list_projects",
            description: "List projects Daddy can launch coding agents in.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        )),
        OllamaTool(function: .init(
            name: "list_active_agents",
            description: "List coding agents currently running under Daddy.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        )),
        OllamaTool(function: .init(
            name: "list_work_items",
            description: "List saved orchestrator work items, optionally filtered by category.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "category": .object([
                        "type": .string("string"),
                        "description": .string("bugs, uiux, future-features, concepts, or other"),
                    ])
                ]),
            ])
        )),
        OllamaTool(function: .init(
            name: "create_work_item",
            description: "Save a new organized idea or task as a Markdown work item.",
            parameters: .object([
                "type": .string("object"),
                "required": .array([.string("title"), .string("summary"), .string("category")]),
                "properties": .object([
                    "title": .object(["type": .string("string")]),
                    "summary": .object(["type": .string("string")]),
                    "raw_capture": .object(["type": .string("string")]),
                    "category": .object(["type": .string("string")]),
                    "priority": .object(["type": .string("string")]),
                    "project_id": .object(["type": .string("string")]),
                    "attachment_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
            ])
        )),
        OllamaTool(function: .init(
            name: "update_work_item",
            description: "Update an existing Markdown work item after the user asks for a change.",
            parameters: .object([
                "type": .string("object"),
                "required": .array([.string("work_item_id")]),
                "properties": .object([
                    "work_item_id": .object(["type": .string("string")]),
                    "title": .object(["type": .string("string")]),
                    "summary": .object(["type": .string("string")]),
                    "category": .object(["type": .string("string")]),
                    "priority": .object(["type": .string("string")]),
                    "status": .object(["type": .string("string")]),
                ]),
            ])
        )),
        OllamaTool(function: .init(
            name: "request_agent_dispatch",
            description: "Prepare a work item to be sent to a coding agent. Daddy will ask the user for confirmation before acting.",
            parameters: .object([
                "type": .string("object"),
                "required": .array([.string("work_item_id"), .string("agent")]),
                "properties": .object([
                    "work_item_id": .object(["type": .string("string")]),
                    "agent": .object(["type": .string("string")]),
                    "project_id": .object(["type": .string("string")]),
                    "existing_session_id": .object(["type": .string("string")]),
                    "prompt": .object(["type": .string("string")]),
                ]),
            ])
        )),
        ]
    }

    func attachOrchestratorFile(_ url: URL) {
        let key = orchestratorConversationKey(orchestratorCategory)
        do {
            let attachment = try OrchestratorAttachmentLoader.load(url)
            guard !orchestratorAttachments.contains(where: { $0.path == attachment.path }) else { return }
            setAttachments(orchestratorAttachments + [attachment], for: key)
            setPendingAttachmentIDs(pendingOrchestratorAttachmentIDs + [attachment.id], for: key)
            persistOrchestratorConversation(for: key)
        } catch {
            setError(error.localizedDescription, for: key)
        }
    }

    func removeOrchestratorAttachment(_ attachment: OrchestratorAttachment) {
        let key = orchestratorConversationKey(orchestratorCategory)
        setAttachments(orchestratorAttachments.filter { $0.id != attachment.id }, for: key)
        setPendingAttachmentIDs(pendingOrchestratorAttachmentIDs.filter { $0 != attachment.id }, for: key)
        persistOrchestratorConversation(for: key)
    }

    func switchOrchestratorCategory(to category: OrchestratorWorkCategory?) {
        guard category != orchestratorCategory else { return }

        let currentKey = orchestratorConversationKey(orchestratorCategory)
        setMessages(orchestratorMessages, for: currentKey)
        setAttachments(orchestratorAttachments, for: currentKey)
        setPendingAttachmentIDs(pendingOrchestratorAttachmentIDs, for: currentKey)
        setStreamingText(orchestratorStreamingText, for: currentKey)
        setBusy(orchestratorBusy, for: currentKey)
        setError(orchestratorError, for: currentKey)
        if let pendingOrchestratorDispatch {
            pendingOrchestratorDispatchByCategory[currentKey] = pendingOrchestratorDispatch
        } else {
            pendingOrchestratorDispatchByCategory.removeValue(forKey: currentKey)
        }

        orchestratorCategory = category
        let nextKey = orchestratorConversationKey(category)
        applyOrchestratorConversation(for: nextKey)
    }

    func sendOrchestratorMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = orchestratorConversationKey(orchestratorCategory)
        guard !trimmed.isEmpty, !(orchestratorBusyByCategory[key] ?? false) else { return }

        let attachmentIDs = pendingOrchestratorAttachmentIDs
        setMessages(
            orchestratorMessages + [
                OrchestratorMessage(role: .user, content: trimmed, attachmentIDs: attachmentIDs)
            ],
            for: key
        )
        setPendingAttachmentIDs([], for: key)
        setStreamingText("", for: key)
        setBusy(true, for: key)
        setError(nil, for: key)
        pendingOrchestratorDispatchByCategory.removeValue(forKey: key)
        if key == orchestratorConversationKey(orchestratorCategory) {
            pendingOrchestratorDispatch = nil
        }
        persistOrchestratorConversation(for: key)

        let turnID = UUID()
        orchestratorTurnIDsByCategory[key] = turnID

        orchestratorTurnTasksByCategory[key]?.cancel()
        orchestratorTurnTasksByCategory[key] = Task { [weak self] in
            guard let self else { return }
            await self.runOrchestratorTurn(text: trimmed, turnID: turnID, key: key)
        }
    }

    func cancelOrchestratorTurn() {
        let key = orchestratorConversationKey(orchestratorCategory)
        guard orchestratorBusyByCategory[key] ?? false else { return }
        let partial = orchestratorStreamingTextByCategory[key] ?? ""
        orchestratorTurnTasksByCategory[key]?.cancel()
        orchestratorTurnTasksByCategory.removeValue(forKey: key)
        orchestratorTurnIDsByCategory.removeValue(forKey: key)
        setBusy(false, for: key)
        setStreamingText("", for: key)
        setError(nil, for: key)
        if !partial.isEmpty {
            var messages = messages(for: key)
            messages.append(OrchestratorMessage(role: .assistant, content: partial, wasStopped: true))
            setMessages(messages, for: key)
        }
        persistOrchestratorConversation(for: key)
    }

    func clearOrchestratorConversation() {
        let key = orchestratorConversationKey(orchestratorCategory)
        guard !(orchestratorBusyByCategory[key] ?? false) else { return }
        resetOrchestratorConversation()
    }

    func resetOrchestratorConversation() {
        let key = orchestratorConversationKey(orchestratorCategory)
        setMessages([], for: key)
        setAttachments([], for: key)
        setPendingAttachmentIDs([], for: key)
        orchestratorMessagesByCategory.removeValue(forKey: key)
        orchestratorAttachmentsByCategory.removeValue(forKey: key)
        pendingOrchestratorAttachmentIDsByCategory.removeValue(forKey: key)
        orchestratorStreamingTextByCategory.removeValue(forKey: key)
        orchestratorBusyByCategory.removeValue(forKey: key)
        orchestratorErrorByCategory.removeValue(forKey: key)
        orchestratorConversationCreatedAtByCategory.removeValue(forKey: key)
        orchestratorConversationLongTermByCategory.removeValue(forKey: key)
        pendingOrchestratorDispatchByCategory.removeValue(forKey: key)
        applyOrchestratorConversation(for: key)
        orchestratorMarkdownStore.deleteConversation(key: key)
    }

    func approveOrchestratorDispatch() {
        let key = orchestratorConversationKey(orchestratorCategory)
        guard let pending = pendingOrchestratorDispatch,
              let project = project(pending.projectID) else { return }

        let target: MockAgent?
        if let existingID = pending.existingSessionID,
           let existing = agents.first(where: { $0.id == existingID && $0.isLive }) {
            target = existing
        } else {
            target = launchReal(pending.agent, in: project, workUnitID: workItem(pending.workItemID)?.id.uuidString)
        }

        guard let target else {
            setError(launchError ?? "Could not launch the requested agent", for: key)
            return
        }

        send(pending.prompt, to: target.id)
        markWorkItemDispatched(pending.workItemID, session: target.id)
        pendingOrchestratorDispatch = nil
        pendingOrchestratorDispatchByCategory.removeValue(forKey: key)
        setMessages(messages(for: key) + [
            OrchestratorMessage(
                role: .assistant,
                content: "Dispatched \(workItem(pending.workItemID)?.title ?? "the work item") to \(pending.agent.rawValue)."
            )
        ], for: key)
        persistOrchestratorConversation(for: key)
    }

    func rejectOrchestratorDispatch() {
        let key = orchestratorConversationKey(orchestratorCategory)
        guard pendingOrchestratorDispatch != nil else { return }
        pendingOrchestratorDispatch = nil
        pendingOrchestratorDispatchByCategory.removeValue(forKey: key)
        setMessages(messages(for: key) + [
            OrchestratorMessage(role: .assistant, content: "Dispatch cancelled. The work item remains saved.")
        ], for: key)
        persistOrchestratorConversation(for: key)
    }

    func workItem(_ id: UUID) -> OrchestratorWorkItem? {
        orchestratorWorkItems.first { $0.id == id }
    }

    func replaceWorkItem(_ item: OrchestratorWorkItem) {
        guard let index = orchestratorWorkItems.firstIndex(where: { $0.id == item.id }) else { return }
        orchestratorWorkItems[index] = item
        Task {
            await syncCoordinator.save(item)
            noteSyncOutcome(for: item)
        }
        syncGitPushWatchers()
    }

    /// Clears `bundleID` on every member of the bundle — the full store, not
    /// whatever the board filter currently shows. One array write so the UI
    /// drops the bundle card immediately; disk follows on the sync queue.
    func unbundleWorkItems(bundleID: UUID) {
        let now = Date()
        var next = orchestratorWorkItems
        var changed: [OrchestratorWorkItem] = []
        for index in next.indices {
            guard next[index].bundleID == bundleID else { continue }
            next[index].bundleID = nil
            next[index].updatedAt = now
            changed.append(next[index])
        }
        guard !changed.isEmpty else { return }
        orchestratorWorkItems = next
        Task {
            for item in changed {
                await syncCoordinator.save(item)
                noteSyncOutcome(for: item)
            }
        }
        syncGitPushWatchers()
    }

    /// Board dispatch: mark the card, hop, paste once the live terminal exists.
    func dispatchWorkItem(_ id: UUID, onto agent: MockAgent) {
        guard let item = workItem(id) else { return }
        markWorkItemDispatched(id, session: agent.id)
        hopToFleetSession(agent.id)
        enqueueComposerPaste(dispatchPrompt(for: item), onto: agent.id)
    }

    /// Board dispatch: launch, hop immediately, paste once the composer exists.
    func dispatchWorkItem(_ id: UUID, launching kind: AgentKind) {
        guard let item = workItem(id) else { return }
        let projectID = item.projectID ?? selectedProjectID
        guard let projectID, let project = project(projectID) else {
            launchError = "Choose a project before dispatching this work item"
            return
        }
        guard let target = launchReal(kind, in: project, workUnitID: item.id.uuidString) else { return }
        markWorkItemDispatched(id, session: target.id)
        hopToFleetSession(target.id)
        enqueueComposerPaste(dispatchPrompt(for: item), onto: target.id)
    }

    /// Board multi-select dispatch: several items sent together as one prompt
    /// to one session. Each item keeps its own id/status/file — the only new
    /// thing is a shared `bundleID` so the board can draw them as one card.
    func dispatchWorkItemBundle(_ ids: [UUID], onto agent: MockAgent) {
        let items = markBundleDispatched(ids, session: agent.id)
        guard !items.isEmpty else { return }
        hopToFleetSession(agent.id)
        enqueueComposerPaste(dispatchBundlePrompt(for: items), onto: agent.id)
    }

    /// Board multi-select dispatch: launch, hop immediately, paste once the
    /// composer exists — the bundle equivalent of `dispatchWorkItem(_:launching:)`.
    func dispatchWorkItemBundle(_ ids: [UUID], launching kind: AgentKind) {
        guard let firstID = ids.first, let firstItem = workItem(firstID) else { return }
        let projectID = firstItem.projectID ?? selectedProjectID
        guard let projectID, let project = project(projectID) else {
            launchError = "Choose a project before dispatching this bundle"
            return
        }
        guard let target = launchReal(kind, in: project, workUnitID: firstItem.id.uuidString) else { return }
        let items = markBundleDispatched(ids, session: target.id)
        guard !items.isEmpty else { return }
        hopToFleetSession(target.id)
        enqueueComposerPaste(dispatchBundlePrompt(for: items), onto: target.id)
    }

    /// Stamps every item with a shared `bundleID`, moves it to Dispatched and
    /// links the session — same bookkeeping as `markWorkItemDispatched`, done
    /// once per item in the set.
    @discardableResult
    private func markBundleDispatched(_ ids: [UUID], session agentID: String) -> [OrchestratorWorkItem] {
        let bundleID = UUID()
        var items: [OrchestratorWorkItem] = []
        for id in ids {
            guard var item = workItem(id) else { continue }
            item.bundleID = bundleID
            item.status = .dispatched
            if !item.linkedSessionIDs.contains(agentID) {
                item.linkedSessionIDs.append(agentID)
            }
            item.updatedAt = Date()
            replaceWorkItem(item)
            items.append(item)
        }
        return items
    }

    func markWorkItemDispatched(_ id: UUID, session agentID: String) {
        guard var item = workItem(id) else { return }
        item.status = .dispatched
        if !item.linkedSessionIDs.contains(agentID) {
            item.linkedSessionIDs.append(agentID)
        }
        item.updatedAt = Date()
        replaceWorkItem(item)
    }

    /// The one way a work item enters the app. The Ollama `create_work_item`
    /// tool and the board's "+" button both come through here, so there is a
    /// single place where "new item" means insert, select and write to disk.
    func addWorkItem(_ item: OrchestratorWorkItem) {
        orchestratorWorkItems.insert(item, at: 0)
        selectedOrchestratorWorkItemID = item.id
        Task {
            await syncCoordinator.save(item)
            noteSyncOutcome(for: item)
        }
        syncGitPushWatchers()
    }

    func deleteWorkItem(_ id: UUID) {
        guard let index = orchestratorWorkItems.firstIndex(where: { $0.id == id }) else { return }
        let item = orchestratorWorkItems.remove(at: index)
        if selectedOrchestratorWorkItemID == id { selectedOrchestratorWorkItemID = nil }
        recentlyDirtyItemIDs.remove(id)
        Task {
            await syncCoordinator.delete(item)
            pendingSyncBuckets = syncCoordinator.pendingBuckets
        }
        syncGitPushWatchers()
    }

    /// Records whether `item`'s save actually made it to Drive. Drive syncs
    /// a whole bucket file at once, but the "not backed up" badge should only
    /// flag the item that was just touched, not every card sharing its file.
    private func noteSyncOutcome(for item: OrchestratorWorkItem) {
        pendingSyncBuckets = syncCoordinator.pendingBuckets
        let bucket = CategoryBucket(
            projectFolderName: orchestratorMarkdownStore.projectFolderName(for: item.projectID),
            categoryFolderName: item.category.folderName
        )
        if pendingSyncBuckets.contains(bucket) {
            recentlyDirtyItemIDs.insert(item.id)
        } else {
            recentlyDirtyItemIDs.remove(item.id)
        }
    }

    /// This specific item hasn't made it to Drive yet — shown as a small
    /// "not backed up" badge on its board card.
    func isItemNotBackedUp(_ item: OrchestratorWorkItem) -> Bool {
        recentlyDirtyItemIDs.contains(item.id)
    }

    /// Manual "sync now" — retries every queued bucket immediately instead of
    /// waiting for the next throttled tick, then clears the badge for any
    /// item whose bucket made it through.
    func syncPendingNow() {
        Task {
            await syncCoordinator.syncNow()
            refreshPendingSyncState()
        }
    }

    /// Drops any item from the "not backed up" set once its bucket is no
    /// longer pending — called after a flush (manual or tick-driven), since
    /// those don't go through `noteSyncOutcome` per item.
    func refreshPendingSyncState() {
        let pending = syncCoordinator.pendingBuckets
        if pendingSyncBuckets != pending {
            pendingSyncBuckets = pending
        }
        let dirty = recentlyDirtyItemIDs.filter { id in
            guard let item = workItem(id) else { return false }
            let bucket = CategoryBucket(
                projectFolderName: orchestratorMarkdownStore.projectFolderName(for: item.projectID),
                categoryFolderName: item.category.folderName
            )
            return pending.contains(bucket)
        }
        if recentlyDirtyItemIDs != dirty {
            recentlyDirtyItemIDs = dirty
        }
    }

    /// Shows a voice-action confirmation toast, auto-dismissing after ~5s. A
    /// second call (another voice command) replaces whatever's showing and
    /// resets the dismiss timer.
    func showVoiceToast(_ toast: VoiceToast) {
        voiceToastDismissTask?.cancel()
        voiceToast = toast
        // Every action confirmation and every refusal already passes through
        // here on its way to the screen, so this is the one place the spoken
        // version has to hook in to cover both.
        announce(toast.label, event: toast.isFailure ? .actionFailed : .actionConfirmed)
        voiceToastDismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            voiceToast = nil
        }
    }

    /// Undo button on the toast: replays the captured inverse action and
    /// dismisses immediately.
    func undoVoiceToast() {
        guard let action = voiceToast?.undoAction else { return }
        voiceToastDismissTask?.cancel()
        voiceToast = nil
        AppActionDispatcher(store: self).perform(action)
    }

    /// Moving a card between columns. Returns false when nothing changed, so a
    /// drop onto the column a card already sits in does not churn `updatedAt`
    /// and reshuffle the column under the cursor.
    /// `category` is supplied when the drop landed on a category group rather
    /// than on bare column space, which is how a card gets refiled and moved
    /// in one gesture.
    @discardableResult
    func moveWorkItem(
        _ id: UUID,
        to status: OrchestratorWorkStatus,
        category: OrchestratorWorkCategory? = nil
    ) -> Bool {
        guard var item = workItem(id) else { return false }
        let newCategory = category ?? item.category
        guard item.status != status || item.category != newCategory else { return false }

        // Recategorising moves the file between category folders, which
        // `OrchestratorMarkdownStore.save` already handles: it deletes any
        // same-named copy sitting in another folder before writing.
        item.status = status
        item.category = newCategory
        item.boardPosition = orchestratorWorkItems
            .filter { $0.id != id && $0.status == status && $0.category == newCategory }
            .compactMap(\.boardPosition)
            .max()
            .map { $0 + 1 } ?? 1
        item.updatedAt = Date()
        replaceWorkItem(item)
        return true
    }

    /// Board-appear refresh. Local disk only — no Drive walk, no Touch ID.
    /// `reloadWorkItems()` reconciles against Drive, which hangs the open on
    /// network; the board opens constantly, while Drive merges at launch, on
    /// manual sync and on the auto flush.
    func reloadLocalWorkItems() {
        let onDisk = orchestratorMarkdownStore.loadWorkItems()
        guard onDisk != orchestratorWorkItems else { return }
        orchestratorWorkItems = onDisk
        if let selected = selectedOrchestratorWorkItemID,
           !onDisk.contains(where: { $0.id == selected }) {
            selectedOrchestratorWorkItemID = nil
        }
        syncGitPushWatchers()
    }

    /// Work items are Markdown on disk, and the Orchestrator's tools are not
    /// the only writer — a dispatched agent can be told to edit one, and so
    /// can you, in any editor. `loadWorkItems()` otherwise runs once at launch.
    func reloadWorkItems() {
        Task {
            let onDisk = await syncCoordinator.loadWorkItems()
            guard onDisk != orchestratorWorkItems else { return }
            orchestratorWorkItems = onDisk
            if let selected = selectedOrchestratorWorkItemID,
               !onDisk.contains(where: { $0.id == selected }) {
                selectedOrchestratorWorkItemID = nil
            }
            syncGitPushWatchers()
        }
    }

    /// The board's query. `scope` is three-way, not a filter: `.all` ignores
    /// the project entirely, `.unassigned` is the bucket a capture with no
    /// project lands in, `.project(id)` is one project.
    func boardWorkItems(
        scope: BoardProjectScope,
        category: OrchestratorWorkCategory?,
        includeArchived: Bool
    ) -> [OrchestratorWorkItem] {
        orchestratorWorkItems.filter { item in
            switch scope {
            case .all: break
            case .unassigned: if item.projectID != nil { return false }
            case .project(let id): if item.projectID != id { return false }
            }
            if let category, item.category != category { return false }
            if !includeArchived, item.status == .archived { return false }
            return true
        }
        .sorted(by: Self.boardOrder)
    }

    /// Existing cards retain their legacy priority/recency order. Once moved,
    /// a card gets an explicit position after the current destination stack.
    private static func boardOrder(_ a: OrchestratorWorkItem, _ b: OrchestratorWorkItem) -> Bool {
        switch (a.boardPosition, b.boardPosition) {
        case let (a?, b?) where a != b: return a < b
        case (nil, .some): return true
        case (.some, nil): return false
        default: break
        }
        let ra = priorityRank(a.priority)
        let rb = priorityRank(b.priority)
        if ra != rb { return ra < rb }
        return a.updatedAt > b.updatedAt
    }

    private static func priorityRank(_ priority: OrchestratorPriority) -> Int {
        switch priority {
        case .urgent: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        }
    }

    func prepareOrchestratorDispatch(
        for item: OrchestratorWorkItem,
        agent: AgentKind,
        projectID: String?,
        existingSessionID: String?
    ) {
        let resolvedProjectID = projectID ?? item.projectID ?? selectedProjectID
        guard let resolvedProjectID, project(resolvedProjectID) != nil else {
            setError("Choose a project before dispatching this work item", for: orchestratorConversationKey(orchestratorCategory))
            return
        }

        let pending = PendingOrchestratorDispatch(
            workItemID: item.id,
            agent: agent,
            projectID: resolvedProjectID,
            existingSessionID: existingSessionID,
            prompt: dispatchPrompt(for: item)
        )
        let key = orchestratorConversationKey(orchestratorCategory)
        pendingOrchestratorDispatch = pending
        pendingOrchestratorDispatchByCategory[key] = pending
    }

    private func runOrchestratorTurn(text: String, turnID: UUID, key: String) async {
        var ollamaMessages: [OllamaMessage] = [
            OllamaMessage(role: .system, content: Self.orchestratorSystemPrompt)
        ]

        for message in self.messages(for: key) where message.role == .user || message.role == .assistant {
            ollamaMessages.append(
                OllamaMessage(
                    role: message.role == .user ? .user : .assistant,
                    content: messageContent(message, in: key),
                    images: imageData(for: message.attachmentIDs, in: key)
                )
            )
        }

        defer {
            if orchestratorTurnIDsByCategory[key] == turnID {
                setBusy(false, for: key)
                setStreamingText("", for: key)
                orchestratorTurnTasksByCategory.removeValue(forKey: key)
                orchestratorTurnIDsByCategory.removeValue(forKey: key)
                persistOrchestratorConversation(for: key)
            }
        }

        let tools = shouldUseOrchestratorTools(for: text) ? Self.orchestratorTools : []

        for _ in 0..<4 {
            var response: OllamaResponse?
            setStreamingText("", for: key)

            do {
                for try await event in ollamaClient.chatStream(
                    model: orchestratorModel,
                    messages: ollamaMessages,
                    tools: tools
                ) {
                    switch event {
                    case .text(let chunk):
                        guard !Task.isCancelled, orchestratorTurnIDsByCategory[key] == turnID else { return }
                        setStreamingText((orchestratorStreamingTextByCategory[key] ?? "") + chunk, for: key)
                    case .finished(let value):
                        guard !Task.isCancelled, orchestratorTurnIDsByCategory[key] == turnID else { return }
                        response = value
                    }
                }
            } catch {
                guard !Task.isCancelled, orchestratorTurnIDsByCategory[key] == turnID else { return }
                setError(error.localizedDescription, for: key)
                return
            }

            guard !Task.isCancelled, orchestratorTurnIDsByCategory[key] == turnID else { return }
            guard let response else {
                setError("Ollama returned no response", for: key)
                return
            }

            ollamaMessages.append(response.message)
            guard let calls = response.message.toolCalls, !calls.isEmpty else {
                if let streamingText = orchestratorStreamingTextByCategory[key], !streamingText.isEmpty {
                    setMessages(self.messages(for: key) + [
                        OrchestratorMessage(role: .assistant, content: streamingText)
                    ], for: key)
                }
                return
            }

            var approvalNeeded = false
            for call in calls {
                let result = executeOrchestratorTool(call, in: key)
                ollamaMessages.append(
                    OllamaMessage(
                        role: .tool,
                        content: result.content,
                        toolName: call.function.name
                    )
                )
                if result.needsApproval { approvalNeeded = true }
            }

            if approvalNeeded {
                setMessages(self.messages(for: key) + [
                    OrchestratorMessage(
                        role: .assistant,
                        content: "I prepared a dispatch request. Review it before I contact a coding agent."
                    )
                ], for: key)
                return
            }
        }

        setError("The orchestrator reached its tool-call limit for this turn", for: key)
    }

    private struct ToolResult {
        let content: String
        let needsApproval: Bool
    }

    private func executeOrchestratorTool(_ call: OllamaToolCall, in key: String) -> ToolResult {
        let args = call.function.arguments

        switch call.function.name {
        case "list_projects":
            let projects = self.projects.map { "\($0.id): \($0.name) (\($0.path))" }
            return ToolResult(content: projects.isEmpty ? "No projects found." : projects.joined(separator: "\n"), needsApproval: false)

        case "list_active_agents":
            let active = agents.filter(\.isLive).map {
                "\($0.id): \($0.agent.rawValue) in project \($0.projectID), work \($0.workUnitID), state \(StateColors.name(for: $0.state))"
            }
            return ToolResult(content: active.isEmpty ? "No active agents." : active.joined(separator: "\n"), needsApproval: false)

        case "list_work_items":
            let category = args["category"].flatMap { $0.stringValue }.flatMap(normalizeCategory)
            let items = orchestratorWorkItems.filter { category == nil || $0.category == category }
            let output = items.map { "\($0.id.uuidString): [\($0.category.title)] \($0.title) (\($0.status.title))" }
            return ToolResult(content: output.isEmpty ? "No matching work items." : output.joined(separator: "\n"), needsApproval: false)

        case "create_work_item":
            guard let title = args["title"]?.stringValue,
                  let summary = args["summary"]?.stringValue,
                  let categoryValue = args["category"]?.stringValue,
                  let category = normalizeCategory(categoryValue) else {
                return ToolResult(content: "Missing or invalid title, summary, or category.", needsApproval: false)
            }

            let item = OrchestratorWorkItem(
                title: title,
                summary: summary,
                rawCapture: args["raw_capture"]?.stringValue ?? summary,
                category: category,
                priority: normalizePriority(args["priority"]?.stringValue),
                projectID: args["project_id"]?.stringValue ?? selectedProjectID,
                attachmentIDs: attachmentIDs(from: args["attachment_ids"])
                    ?? latestAttachmentIDs(in: key)
            )
            addWorkItem(item)
            return ToolResult(content: "Created work item \(item.id.uuidString): \(item.title)", needsApproval: false)

        case "update_work_item":
            guard let idValue = args["work_item_id"]?.stringValue,
                  let id = UUID(uuidString: idValue),
                  var item = workItem(id) else {
                return ToolResult(content: "Work item not found.", needsApproval: false)
            }
            if let value = args["title"]?.stringValue { item.title = value }
            if let value = args["summary"]?.stringValue { item.summary = value }
            if let value = args["category"]?.stringValue, let category = normalizeCategory(value) { item.category = category }
            if let value = args["priority"]?.stringValue { item.priority = normalizePriority(value) }
            if let value = args["status"]?.stringValue, let status = OrchestratorWorkStatus(rawValue: value) { item.status = status }
            item.updatedAt = Date()
            replaceWorkItem(item)
            return ToolResult(content: "Updated work item \(item.id.uuidString).", needsApproval: false)

        case "request_agent_dispatch":
            guard let idValue = args["work_item_id"]?.stringValue,
                  let id = UUID(uuidString: idValue),
                  let item = workItem(id),
                  let agentValue = args["agent"]?.stringValue,
                  let agent = AgentKind(rawValue: agentValue.lowercased()) else {
                return ToolResult(content: "Work item or coding agent not found.", needsApproval: false)
            }
            let projectID = args["project_id"]?.stringValue ?? item.projectID ?? selectedProjectID
            guard let projectID, project(projectID) != nil else {
                return ToolResult(content: "No valid project is associated with this work item.", needsApproval: false)
            }
            let prompt = args["prompt"]?.stringValue ?? dispatchPrompt(for: item)
            let pending = PendingOrchestratorDispatch(
                workItemID: item.id,
                agent: agent,
                projectID: projectID,
                existingSessionID: args["existing_session_id"]?.stringValue,
                prompt: prompt
            )
            pendingOrchestratorDispatchByCategory[key] = pending
            if key == orchestratorConversationKey(orchestratorCategory) {
                pendingOrchestratorDispatch = pending
            }
            return ToolResult(content: "Dispatch prepared and waiting for user approval.", needsApproval: true)

        default:
            return ToolResult(content: "Unknown tool: \(call.function.name)", needsApproval: false)
        }
    }

    private func imageData(for ids: [UUID], in key: String) -> [String]? {
        let values = ids.compactMap { id -> String? in
            guard let attachment = attachments(for: key).first(where: { $0.id == id }),
                  attachment.kind == .image,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: attachment.path)) else { return nil }
            return data.base64EncodedString()
        }
        return values.isEmpty ? nil : values
    }

    private func messageContent(_ message: OrchestratorMessage, in key: String) -> String {
        let context = message.attachmentIDs.compactMap { id -> String? in
            guard let attachment = attachments(for: key).first(where: { $0.id == id }),
                  !attachment.extractedText.isEmpty else { return nil }
            return "\n\n--- Attached context: \(attachment.name) ---\n\(attachment.extractedText)\n--- End attached context ---"
        }
        return message.content + context.joined()
    }

    private func attachmentIDs(from value: JSONValue?) -> [UUID]? {
        guard case .array(let values) = value else { return nil }
        let ids = values.compactMap { $0.stringValue }.compactMap(UUID.init(uuidString:))
        return ids.isEmpty ? nil : ids
    }

    private func latestAttachmentIDs(in key: String) -> [UUID] {
        messages(for: key).reversed().first(where: { !$0.attachmentIDs.isEmpty })?.attachmentIDs ?? []
    }

    private func orchestratorConversationKey(_ category: OrchestratorWorkCategory?) -> String {
        category?.rawValue ?? "all"
    }

    private func shouldUseOrchestratorTools(for text: String) -> Bool {
        let normalized = text.lowercased()
        let toolIntentTerms = [
            "organize", "work item", "work items", "create", "save", "update",
            "dispatch", "agent", "project", "active", "list"
        ]
        return toolIntentTerms.contains { normalized.contains($0) }
    }

    private func dispatchPrompt(for item: OrchestratorWorkItem) -> String {
        var prompt = "Work on this Daddy work item.\n\n"
        prompt += "# \(item.title)\n\n"
        prompt += "## Summary\n\(item.summary)\n\n"
        prompt += "## Original Capture\n\(item.rawCapture)\n"

        let attachments = item.attachmentIDs.compactMap { id in
            attachment(id)
        }
        if !attachments.isEmpty {
            prompt += "\n## Attached Context\n"
            for attachment in attachments {
                prompt += "\n### \(attachment.name)\n"
                if attachment.extractedText.isEmpty {
                    prompt += "File: \(attachment.path)\n"
                } else {
                    prompt += attachment.extractedText + "\n"
                }
            }
        }

        prompt += "\nWhen you finish, move this card to VERIFY: find the block with `id: \(item.id.uuidString)` in \(orchestratorMarkdownStore.fileURL(for: item).path) (that file lists every item in this bucket — edit only this item's block) and set `status: refined` there. Do not leave it dispatched, and do not mark it done.\n"
        return prompt
    }

    /// Several `dispatchPrompt` blocks, one per bundled item, under a single
    /// intro line. Each block is already self-contained — its own id, file
    /// path and "move to VERIFY" instruction — so the agent finishes them one
    /// at a time exactly as it would separate work items.
    private func dispatchBundlePrompt(for items: [OrchestratorWorkItem]) -> String {
        var prompt = "Here are \(items.count) Daddy work items bundled together for you to do in one pass. Work through each one in turn, in order.\n\n"
        for (index, item) in items.enumerated() {
            prompt += "=== Task \(index + 1) of \(items.count) ===\n\n"
            prompt += dispatchPrompt(for: item)
            prompt += "\n"
        }
        return prompt
    }

    private func normalizeCategory(_ value: String) -> OrchestratorWorkCategory? {
        let normalized = value.lowercased().replacingOccurrences(of: "_", with: "-")
        if normalized.contains("bug") { return .bugs }
        if normalized.contains("ui") || normalized.contains("ux") || normalized.contains("design") { return .uiux }
        if normalized.contains("future") || normalized.contains("feature") { return .futureFeatures }
        if normalized.contains("concept") || normalized.contains("idea") { return .concepts }
        if normalized == "other" { return .other }
        return nil
    }

    private func normalizePriority(_ value: String?) -> OrchestratorPriority {
        guard let value, let priority = OrchestratorPriority(rawValue: value.lowercased()) else { return .medium }
        return priority
    }

    private func applyOrchestratorConversation(for key: String) {
        orchestratorMessages = orchestratorMessagesByCategory[key] ?? []
        orchestratorAttachments = orchestratorAttachmentsByCategory[key] ?? []
        pendingOrchestratorAttachmentIDs = pendingOrchestratorAttachmentIDsByCategory[key] ?? []
        orchestratorStreamingText = orchestratorStreamingTextByCategory[key] ?? ""
        orchestratorBusy = orchestratorBusyByCategory[key] ?? false
        orchestratorError = orchestratorErrorByCategory[key]
        pendingOrchestratorDispatch = pendingOrchestratorDispatchByCategory[key]
    }

    private func messages(for key: String) -> [OrchestratorMessage] {
        if key == orchestratorConversationKey(orchestratorCategory) {
            return orchestratorMessages
        }
        return orchestratorMessagesByCategory[key] ?? []
    }

    private func attachments(for key: String) -> [OrchestratorAttachment] {
        if key == orchestratorConversationKey(orchestratorCategory) {
            return orchestratorAttachments
        }
        return orchestratorAttachmentsByCategory[key] ?? []
    }

    private func pendingAttachmentIDs(for key: String) -> [UUID] {
        if key == orchestratorConversationKey(orchestratorCategory) {
            return pendingOrchestratorAttachmentIDs
        }
        return pendingOrchestratorAttachmentIDsByCategory[key] ?? []
    }

    private func setMessages(_ messages: [OrchestratorMessage], for key: String) {
        var values = orchestratorMessagesByCategory
        if messages.isEmpty {
            values.removeValue(forKey: key)
        } else {
            values[key] = messages
        }
        orchestratorMessagesByCategory = values
        if key == orchestratorConversationKey(orchestratorCategory) {
            orchestratorMessages = messages
        }
    }

    private func setAttachments(_ attachments: [OrchestratorAttachment], for key: String) {
        var values = orchestratorAttachmentsByCategory
        if attachments.isEmpty {
            values.removeValue(forKey: key)
        } else {
            values[key] = attachments
        }
        orchestratorAttachmentsByCategory = values
        if key == orchestratorConversationKey(orchestratorCategory) {
            orchestratorAttachments = attachments
        }
    }

    private func setPendingAttachmentIDs(_ ids: [UUID], for key: String) {
        var values = pendingOrchestratorAttachmentIDsByCategory
        if ids.isEmpty {
            values.removeValue(forKey: key)
        } else {
            values[key] = ids
        }
        pendingOrchestratorAttachmentIDsByCategory = values
        if key == orchestratorConversationKey(orchestratorCategory) {
            pendingOrchestratorAttachmentIDs = ids
        }
    }

    private func setStreamingText(_ text: String, for key: String) {
        var values = orchestratorStreamingTextByCategory
        if text.isEmpty {
            values.removeValue(forKey: key)
        } else {
            values[key] = text
        }
        orchestratorStreamingTextByCategory = values
        if key == orchestratorConversationKey(orchestratorCategory) {
            orchestratorStreamingText = text
        }
    }

    private func setBusy(_ busy: Bool, for key: String) {
        var values = orchestratorBusyByCategory
        if busy {
            values[key] = true
        } else {
            values.removeValue(forKey: key)
        }
        orchestratorBusyByCategory = values
        if key == orchestratorConversationKey(orchestratorCategory) {
            orchestratorBusy = busy
        }
    }

    private func setError(_ error: String?, for key: String) {
        var values = orchestratorErrorByCategory
        if let error {
            values[key] = error
        } else {
            values.removeValue(forKey: key)
        }
        orchestratorErrorByCategory = values
        if key == orchestratorConversationKey(orchestratorCategory) {
            orchestratorError = error
        }
    }

    private func persistOrchestratorConversation(for key: String) {
        guard orchestratorConversationHasActivity(key) else {
            orchestratorMarkdownStore.deleteConversation(key: key)
            return
        }

        let existingCreatedAt = orchestratorConversationCreatedAtByCategory[key]
        let createdAt = existingCreatedAt
            ?? messages(for: key).first?.createdAt
            ?? Date()
        let keepLongTerm = orchestratorConversationLongTermByCategory[key] ?? false
        var createdValues = orchestratorConversationCreatedAtByCategory
        createdValues[key] = createdAt
        orchestratorConversationCreatedAtByCategory = createdValues

        var longTermValues = orchestratorConversationLongTermByCategory
        longTermValues[key] = keepLongTerm
        orchestratorConversationLongTermByCategory = longTermValues

        orchestratorMarkdownStore.saveConversation(
            OrchestratorConversationSnapshot(
                key: key,
                category: category(from: key),
                messages: messages(for: key),
                attachments: attachments(for: key),
                pendingAttachmentIDs: pendingAttachmentIDs(for: key),
                createdAt: createdAt,
                updatedAt: Date(),
                keepLongTerm: keepLongTerm
            )
        )
    }

    private func orchestratorConversationHasActivity(_ key: String) -> Bool {
        if key == orchestratorConversationKey(orchestratorCategory) {
            return !orchestratorMessages.isEmpty ||
                !orchestratorAttachments.isEmpty ||
                !pendingOrchestratorAttachmentIDs.isEmpty ||
                !orchestratorStreamingText.isEmpty ||
                orchestratorBusy
        }
        return !(orchestratorMessagesByCategory[key] ?? []).isEmpty ||
            !(orchestratorAttachmentsByCategory[key] ?? []).isEmpty ||
            !(pendingOrchestratorAttachmentIDsByCategory[key] ?? []).isEmpty ||
            !(orchestratorStreamingTextByCategory[key] ?? "").isEmpty ||
            (orchestratorBusyByCategory[key] ?? false)
    }

    private func category(from key: String) -> OrchestratorWorkCategory? {
        OrchestratorWorkCategory(rawValue: key)
    }

    private func attachment(_ id: UUID) -> OrchestratorAttachment? {
        if let current = orchestratorAttachments.first(where: { $0.id == id }) {
            return current
        }
        for attachments in orchestratorAttachmentsByCategory.values {
            if let attachment = attachments.first(where: { $0.id == id }) {
                return attachment
            }
        }
        return nil
    }
}
