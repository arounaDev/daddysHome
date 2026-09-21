import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DaddyCore

struct OrchestratorView: View {
    @Environment(MockStore.self) private var store

    @State private var draft = ""
    @State private var fileImporterPresented = false
    @State private var inspectorTitle = ""
    @State private var inspectorSummary = ""
    @State private var inspectorCategory: OrchestratorWorkCategory = .concepts
    @State private var inspectorStatus: OrchestratorWorkStatus = .inbox
    @State private var inspectorPriority: OrchestratorPriority = .medium
    @State private var inspectorProjectID = ""
    @State private var dispatchAgent: AgentKind = .claude
    @State private var dispatchSessionID = ""

    private var visibleWorkItems: [OrchestratorWorkItem] {
        store.orchestratorWorkItems.filter { store.orchestratorCategory == nil || $0.category == store.orchestratorCategory }
    }

    private var selectedItem: OrchestratorWorkItem? {
        guard let id = store.selectedOrchestratorWorkItemID else { return nil }
        return store.workItem(id)
    }

    var body: some View {
        HStack(spacing: 16) {
            workItemsPane
                .frame(width: 270)

            conversationPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if selectedItem != nil || store.pendingOrchestratorDispatch != nil {
                inspectorPane
                    .frame(width: 310)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(18)
        .animation(.easeOut(duration: 0.2), value: store.selectedOrchestratorWorkItemID)
        .onKeyPress(.escape, phases: .down) { _ in
            guard store.orchestratorBusy else { return .ignored }
            store.cancelOrchestratorTurn()
            return .handled
        }
        .onChange(of: store.selectedOrchestratorWorkItemID) { _, _ in syncInspector() }
        .onAppear {
            syncInspector()
            store.switchOrchestratorCategory(to: store.orchestratorCategory)
        }
        .fileImporter(
            isPresented: $fileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { store.attachOrchestratorFile(url) }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in store.attachOrchestratorFile(url) }
                }
            }
            return true
        }
    }

    private var workItemsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader("WORK ITEMS", detail: "\(store.orchestratorWorkItems.count)")

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    categoryButton(nil, title: "ALL")
                    ForEach(OrchestratorWorkCategory.allCases) { category in
                        categoryButton(category, title: category.title)
                    }

                    GlassHairline()
                        .padding(.vertical, 7)

                    if visibleWorkItems.isEmpty {
                        Text("No work items yet.")
                            .font(.system(size: 11))
                            .foregroundStyle(DaddyTheme.textMuted)
                            .padding(12)
                    } else {
                        ForEach(visibleWorkItems) { item in
                            workItemRow(item)
                        }
                    }
                }
                .padding(12)
            }
        }
        .glassPanel()
    }

    private var conversationPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ORCHESTRATOR")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.9)
                        .foregroundStyle(DaddyTheme.textPrimary)
                    Text("Brainstorm, organize, then dispatch")
                        .font(.system(size: 10))
                        .foregroundStyle(DaddyTheme.textMuted)
                }

                Spacer()

                Button("organize this") {
                    sendQuickInstruction("Organize the ideas in this conversation into distinct work items. Use create_work_item for each item and explain the grouping afterward.")
                }
                .buttonStyle(.inset)
                .disabled(store.orchestratorBusy || store.orchestratorMessages.isEmpty)

                Button {
                    store.toggleCurrentOrchestratorConversationLongTerm()
                } label: {
                    Image(systemName: store.currentOrchestratorConversationIsLongTerm ? "bookmark.fill" : "bookmark")
                }
                .buttonStyle(.inset)
                .disabled(store.orchestratorMessages.isEmpty && store.orchestratorAttachments.isEmpty)
                .help(store.currentOrchestratorConversationIsLongTerm ? "Saved long-term" : "Save chat long-term")

                Button {
                    store.clearOrchestratorConversation()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.inset)
                .disabled(
                    store.orchestratorBusy ||
                    (store.orchestratorMessages.isEmpty && store.orchestratorAttachments.isEmpty)
                )
                .help("Clear conversation")
            }
            .padding(16)

            GlassHairline()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if store.orchestratorMessages.isEmpty && store.orchestratorStreamingText.isEmpty {
                            emptyConversation
                        }

                        ForEach(store.orchestratorMessages) { message in
                            messageRow(message)
                                .id(message.id)
                        }

                        if store.orchestratorBusy && store.orchestratorStreamingText.isEmpty {
                            typingIndicator
                        }

                        if !store.orchestratorStreamingText.isEmpty {
                            messageBubble(
                                role: .assistant,
                                text: store.orchestratorStreamingText,
                                attachments: []
                            )
                        }
                    }
                    .padding(20)
                }
                .onChange(of: store.orchestratorMessages.count) { _, _ in
                    if let id = store.orchestratorMessages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }

            if let error = store.orchestratorError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                        .lineLimit(2)
                    Spacer()
                    Button("dismiss") { store.dismissCurrentOrchestratorError() }
                        .buttonStyle(.inset)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DaddyTheme.failure)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }

            composer
        }
        .glassPanel()
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 7) {
                    if !pendingAttachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(pendingAttachments) { attachment in
                                    HStack(spacing: 5) {
                                        Image(systemName: attachmentGlyph(attachment))
                                        Text(attachment.name)
                                            .lineLimit(1)
                                        Button { store.removeOrchestratorAttachment(attachment) } label: {
                                            Image(systemName: "xmark")
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(DaddyTheme.textSecondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .insetCapsule(opacity: 0.08)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.top, 7)
                        }
                    }

                    TextEditor(text: $draft)
                        .font(.system(size: 12))
                        .foregroundStyle(DaddyTheme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(height: pendingAttachments.isEmpty ? 68 : 54)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 30)
                        .onKeyPress(.return, phases: .down) { keyPress in
                            guard keyPress.modifiers.isEmpty else { return .ignored }
                            submitDraft()
                            return .handled
                        }
                        .onKeyPress(.escape, phases: .down) { _ in
                            guard store.orchestratorBusy else { return .ignored }
                            store.cancelOrchestratorTurn()
                            return .handled
                        }
                }
                .frame(maxWidth: .infinity)

                Button {
                    DispatchQueue.main.async { fileImporterPresented = true }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DaddyTheme.textSecondary)
                .padding(.leading, 10)
                .padding(.bottom, 9)
                .help("Attach text, PDF, or image")

                HStack {
                    Spacer()
                    Button { submitDraft() } label: {
                        Image(systemName: store.orchestratorBusy ? "hourglass" : "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DaddyTheme.textPrimary)
                    .background(Circle().fill(DaddyTheme.accent.opacity(0.8)))
                    .clipShape(Circle())
                    .disabled(store.orchestratorBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(.trailing, 10)
                    .padding(.bottom, 9)
                }
            }
            .frame(maxWidth: .infinity)
            .insetSurface(cornerRadius: 12)

            Text("Drop files here or attach them. Ollama stays local.")
                .font(.system(size: 9.5))
                .foregroundStyle(DaddyTheme.textVeryDim)
        }
        .padding(12)
    }

    private var inspectorPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader("INSPECTOR", detail: selectedItem == nil ? "capture" : "work item")

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if selectedItem != nil {
                        inspectorEditor
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 20))
                                .foregroundStyle(DaddyTheme.accent)
                            Text("Capture first, organize when ready.")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DaddyTheme.textPrimary)
                            Text("The orchestrator can keep the conversation loose until you ask it to turn the ideas into editable work items.")
                                .font(.system(size: 10))
                                .foregroundStyle(DaddyTheme.textMuted)
                        }
                    }

                    if let pending = store.pendingOrchestratorDispatch {
                        dispatchApproval(pending)
                    }
                }
                .padding(16)
            }
        }
        .glassPanel()
    }

    private var inspectorEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkItemFields(
                title: $inspectorTitle,
                summary: $inspectorSummary,
                category: $inspectorCategory,
                status: $inspectorStatus,
                priority: $inspectorPriority,
                projectID: $inspectorProjectID,
                projects: store.rootProjects,
                onSave: saveInspector
            )

            GlassHairline()

            Text("DISPATCH")
                .sectionLabel()
            Picker("Agent", selection: $dispatchAgent) {
                ForEach([AgentKind.claude, .codex, .cursor, .opencode], id: \.self) { kind in
                    Text(kind.rawValue.capitalized).tag(kind)
                }
            }
            Picker("Session", selection: $dispatchSessionID) {
                Text("New session").tag("")
                ForEach(store.agents.filter(\.isLive)) { agent in
                    Text("\(agent.agent.rawValue) · \(agent.label)").tag(agent.id)
                }
            }
            Button("prepare dispatch") {
                guard let item = selectedItem else { return }
                store.prepareOrchestratorDispatch(
                    for: item,
                    agent: dispatchAgent,
                    projectID: inspectorProjectID.isEmpty ? nil : inspectorProjectID,
                    existingSessionID: dispatchSessionID.isEmpty ? nil : dispatchSessionID
                )
            }
            .buttonStyle(.inset)
            .disabled(selectedItem?.projectID == nil && inspectorProjectID.isEmpty && store.selectedProjectID == nil)
        }
    }

    private func dispatchApproval(_ pending: PendingOrchestratorDispatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APPROVAL REQUIRED")
                .sectionLabel(tint: DaddyTheme.limited)
            Text("Send \(workItemTitle(pending.workItemID)) to \(pending.agent.rawValue)?")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DaddyTheme.textPrimary)
            Text(pending.prompt)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DaddyTheme.textMuted)
                .lineLimit(8)
            HStack(spacing: 7) {
                Button("approve") { store.approveOrchestratorDispatch() }
                    .buttonStyle(.inset(DaddyTheme.ready))
                Button("cancel") { store.rejectOrchestratorDispatch() }
                    .buttonStyle(.inset(DaddyTheme.failure))
            }
        }
        .padding(12)
        .insetSurface(cornerRadius: 12, selected: true)
    }

    private var pendingAttachments: [OrchestratorAttachment] {
        store.pendingOrchestratorAttachmentIDs.compactMap { id in
            store.orchestratorAttachments.first { $0.id == id }
        }
    }

    private func messageRow(_ message: OrchestratorMessage) -> some View {
        messageBubble(
            role: message.role,
            text: message.content,
            attachments: message.attachmentIDs.compactMap { id in
                store.orchestratorAttachments.first { $0.id == id }
            },
            wasStopped: message.wasStopped
        )
    }

    private func messageBubble(
        role: OrchestratorMessageRole,
        text: String,
        attachments: [OrchestratorAttachment],
        wasStopped: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: role == .user ? "person.fill" : "sparkles")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(role == .user ? DaddyTheme.textSecondary : DaddyTheme.accent)
                .frame(width: 24, height: 24)
                .insetSurface(cornerRadius: 12)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(role == .user ? "YOU" : "DADDY")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(DaddyTheme.textMuted)
                    Spacer(minLength: 0)
                    if role == .assistant && !text.isEmpty {
                        Button { copyMessage(text) } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DaddyTheme.textMuted)
                        .help("Copy message")
                    }
                    if wasStopped {
                        Text("STOPPED")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(DaddyTheme.failure)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .insetCapsule(opacity: 0.14)
                    }
                }
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(DaddyTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            Label(attachment.name, systemImage: attachmentGlyph(attachment))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(DaddyTheme.textMuted)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .textSelection(.enabled)
        .insetSurface(cornerRadius: 14, selected: role == .user, filled: true)
        .overlay(alignment: .leading) {
            if role == .assistant {
                Capsule()
                    .fill(DaddyTheme.accent.opacity(0.75))
                    .frame(width: 2)
                    .padding(.vertical, 14)
            }
        }
    }

    private func copyMessage(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var typingIndicator: some View {
        TimelineView(.animation(minimumInterval: 0.18)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.18) % 3
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DaddyTheme.accent)
                    .frame(width: 24, height: 24)
                    .insetSurface(cornerRadius: 12)

                VStack(alignment: .leading, spacing: 7) {
                    Text("DADDY")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(DaddyTheme.textMuted)
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(DaddyTheme.textSecondary)
                                .frame(width: 5, height: 5)
                                .opacity(index == phase ? 0.95 : 0.28)
                        }
                    }
                    .frame(height: 16, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .insetSurface(cornerRadius: 14)
        }
    }

    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Give the idea room first.")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(DaddyTheme.textPrimary)
            Text("Describe a bug, paste a thought, attach a screenshot, or drop in a PDF. Daddy can brainstorm with you before turning anything into work.")
                .font(.system(size: 12))
                .foregroundStyle(DaddyTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                suggestion("brainstorm this")
                suggestion("find the real problem")
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(.vertical, 80)
        .padding(.horizontal, 20)
    }

    private func suggestion(_ text: String) -> some View {
        Button(text) { draft = text + ": " }
            .buttonStyle(.inset)
    }

    private func categoryButton(_ category: OrchestratorWorkCategory?, title: String) -> some View {
        let count = store.orchestratorChatCount(for: category)
        let busy = store.orchestratorCategoryIsBusy(category)
        return Button {
            store.switchOrchestratorCategory(to: category)
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: store.orchestratorCategory == category ? .semibold : .regular))
                    .tracking(0.5)
                Spacer()
                if busy {
                    Circle()
                        .fill(DaddyTheme.accent)
                        .frame(width: 6, height: 6)
                }
                Text("\(count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(busy ? DaddyTheme.textSecondary : DaddyTheme.textMuted)
            }
            .foregroundStyle(store.orchestratorCategory == category ? DaddyTheme.textPrimary : DaddyTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .insetSurface(cornerRadius: 10, selected: store.orchestratorCategory == category)
        }
        .buttonStyle(.plain)
    }

    private func workItemRow(_ item: OrchestratorWorkItem) -> some View {
        Button {
            store.selectedOrchestratorWorkItemID = item.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.status == .done ? DaddyTheme.ready : DaddyTheme.accent)
                        .frame(width: 5, height: 5)
                    Text(item.category.title)
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(DaddyTheme.textMuted)
                }
                Text(item.title)
                    .font(.system(size: 11.5, weight: store.selectedOrchestratorWorkItemID == item.id ? .semibold : .regular))
                    .foregroundStyle(DaddyTheme.textPrimary)
                    .lineLimit(2)
                Text(item.status.title)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(DaddyTheme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .insetSurface(cornerRadius: 11, selected: store.selectedOrchestratorWorkItemID == item.id)
        }
        .buttonStyle(.plain)
    }

    private func paneHeader(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(DaddyTheme.textSecondary)
            Spacer()
            Text(detail)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DaddyTheme.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .overlay(alignment: .bottom) { GlassHairline() }
    }

    private func syncInspector() {
        guard let item = selectedItem else { return }
        inspectorTitle = item.title
        inspectorSummary = item.summary
        inspectorCategory = item.category
        inspectorStatus = item.status.boardColumn
        inspectorPriority = item.priority
        inspectorProjectID = item.projectID ?? store.selectedProjectID ?? ""
        if let agent = AgentKind(rawValue: item.linkedSessionIDs.first.flatMap { id in store.agents.first { $0.id == id }?.agent.rawValue } ?? "") {
            dispatchAgent = agent
        }
    }

    private func saveInspector() {
        guard var item = selectedItem else { return }
        let styledTitle = WorkItemTitleCase.apply(inspectorTitle)
        inspectorTitle = styledTitle
        item.title = styledTitle
        item.summary = inspectorSummary
        item.category = inspectorCategory
        item.status = inspectorStatus
        item.priority = inspectorPriority
        item.projectID = inspectorProjectID.isEmpty ? nil : inspectorProjectID
        item.updatedAt = Date()
        AppActionDispatcher(store: store).perform(.replaceWorkItem(item))
    }

    private func sendQuickInstruction(_ text: String) {
        store.sendOrchestratorMessage(text)
    }

    private func submitDraft() {
        guard !store.orchestratorBusy else { return }
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        store.sendOrchestratorMessage(text)
    }

    private func workItemTitle(_ id: UUID) -> String {
        store.workItem(id)?.title ?? "work item"
    }

    private func attachmentGlyph(_ attachment: OrchestratorAttachment) -> String {
        switch attachment.kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        }
    }
}

private extension View {
    func sectionLabel(tint: Color = DaddyTheme.textMuted) -> some View {
        font(.system(size: 9, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(tint)
    }
}
