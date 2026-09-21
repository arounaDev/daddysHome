import SwiftUI
import AppKit

/// The project management workspace: work items as a Kanban board.
///
/// It is a *view* over the same `OrchestratorWorkItem`s the Orchestrator
/// captures and dispatches, read from and written to the same Markdown store.
/// There is no second database and no second copy of the truth — a card moved
/// here is the same item the Orchestrator can hand to a coding agent, and an
/// item an agent updates on disk shows up here on the next visit.
struct BoardView: View {
    @Environment(MockStore.self) private var store

    @State private var scope: BoardProjectScope = .all
    @State private var categoryFilter: OrchestratorWorkCategory?
    @State private var showArchived = false

    /// The card(s) dropped into DISPATCHED, or sent via the bundle flow,
    /// waiting on an agent. The move is not committed until one is picked —
    /// see `BoardDispatchPicker`. 2+ items means a bundle send.
    @State private var pendingDispatch: [OrchestratorWorkItem]?

    /// Multi-select for bundling several cards into one dispatch. Off by
    /// default — Cmd+B turns it on, Escape (or a send/cancel) turns it off.
    @State private var selectionModeActive = false
    /// Order matters here, not just membership — Escape unpicks the most
    /// recent one first, so it stays an array rather than a `Set`.
    @State private var pickedItemIDs: [UUID] = []
    /// The card arrow keys move over while selection mode is active.
    @State private var selectionCursorID: UUID?
    @State private var collapsedGroups: Set<BoardGroupKey> = []
    /// Bundle cards default open (that's the point of the checklist); this
    /// tracks the ones you've folded shut.
    @State private var collapsedBundleIDs: Set<UUID> = []
    @State private var draggingID: UUID?
    /// The column under the pointer, updated only when it actually changes.
    /// The cursor location moves every few pixels and the columns must not
    /// rebuild for each one — only the floating card follows the pointer.
    @State private var dropTarget: OrchestratorWorkStatus?
    @State private var columnFrames: [OrchestratorWorkStatus: CGRect] = [:]
    @State private var keyboardMonitor: Any?
    /// The column Cmd+T adds into. Set by clicking a column or a card in it.
    @State private var selectedColumn: OrchestratorWorkStatus?
    /// Cmd+M's move flow: the items in flight, non-nil only while the target
    /// column is being picked. `dropTarget` doubles as the highlighted
    /// candidate — the same visual a real drag lands on.
    @State private var movingItemIDs: [UUID]?
    /// The bundle whose summary pane is open — a bundle card has no fields
    /// of its own to edit, just its members and an unbundle action.
    @State private var openBundleID: UUID?

    @FocusState private var editorTitleFocused: Bool
    @FocusState private var editorSummaryFocused: Bool
    /// The item the last plus-button press created. Closed with an empty title
    /// means the add was abandoned, so it is deleted rather than left behind.
    @State private var justCreatedID: UUID?

    private var selectedItem: OrchestratorWorkItem? {
        guard let id = store.selectedOrchestratorWorkItemID else { return nil }
        return store.workItem(id)
    }

    private var items: [OrchestratorWorkItem] {
        store.boardWorkItems(scope: scope, category: categoryFilter, includeArchived: showArchived)
    }

    private var openBundleItems: [OrchestratorWorkItem] {
        guard let openBundleID else { return [] }
        return items.filter { $0.bundleID == openBundleID }
    }

    private var columns: [OrchestratorWorkStatus] {
        showArchived
            ? OrchestratorWorkStatus.boardColumns + [.archived]
            : OrchestratorWorkStatus.boardColumns
    }

    var body: some View {
        boardPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { boardModalScrim }
            .overlay(alignment: .trailing) { detailOverlay }
            .overlay(alignment: .trailing) { bundleDetailOverlay }
            .overlay { dispatchOverlay }
            .padding(18)
        .onAppear {
            syncScopeFromProject()
            installKeyboardMonitor()
            consumePendingBoardDispatch()
            syncBoardChromeBlock()
        }
        .onDisappear {
            removeKeyboardMonitor()
            store.boardModalBlocksChrome = false
        }
        .onChange(of: store.selectedProjectID) { _, _ in syncScopeFromProject() }
        .onChange(of: store.pendingBoardDispatchIDs) { _, _ in consumePendingBoardDispatch() }
        .onChange(of: store.selectedOrchestratorWorkItemID) { _, _ in syncBoardChromeBlock() }
        .onChange(of: openBundleID) { _, _ in syncBoardChromeBlock() }
        .onChange(of: pendingDispatch?.count) { _, _ in syncBoardChromeBlock() }
    }

    /// True while any board modal owns the interaction — detail, bundle, or
    /// the dispatch picker.
    private var boardModalActive: Bool {
        selectedItem != nil || openBundleID != nil || pendingDispatch != nil
    }

    private func syncBoardChromeBlock() {
        let blocked = boardModalActive
        if store.boardModalBlocksChrome != blocked {
            store.boardModalBlocksChrome = blocked
        }
    }

    /// Full-bleed catcher under the panes. Without it, empty overlay space
    /// (and translucent glass) lets the board — and anything still mounted
    /// under it — keep receiving hover and clicks.
    @ViewBuilder
    private var boardModalScrim: some View {
        if boardModalActive {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture {
                    if pendingDispatch != nil {
                        pendingDispatch = nil
                    } else if openBundleID != nil {
                        openBundleID = nil
                    } else {
                        closeDetail()
                    }
                }
                .transition(.opacity)
        }
    }

    /// Voice (and any other non-board path) can stage IDs on the store; once
    /// the board is up it opens the same agent picker a DISPATCHED drop does.
    private func consumePendingBoardDispatch() {
        guard let ids = store.pendingBoardDispatchIDs else { return }
        store.pendingBoardDispatchIDs = nil
        let moving = ids.compactMap { store.workItem($0) }
        guard !moving.isEmpty else { return }
        pendingDispatch = moving
    }

    // MARK: - Board

    private var boardPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            columnsRow
        }
    }

    // No horizontal `ScrollView` around the columns. A vertical scroll view
    // inside a horizontal one makes a drag ambiguous, and the scroll views win
    // — the cards never lift. The columns share the width instead.
    private var columnsRow: some View {
        HStack(alignment: .top, spacing: 12) {
                let target = dropTarget
                let selectedID = store.selectedOrchestratorWorkItemID
                let visibleItems = items
                ForEach(columns, id: \.self) { status in
                    let columnItems = visibleItems.filter { $0.status.boardColumn == status }
                    BoardColumn(
                        status: status,
                        items: columnItems,
                        selectedID: columnItems.contains { $0.id == selectedID } ? selectedID : nil,
                        groupByCategory: categoryFilter == nil,
                        collapsed: collapsedGroups,
                        collapsedBundleIDs: collapsedBundleIDs,
                        projectName: projectName(for:),
                        onSelect: { handleCardSelect($0) },
                        onArchive: { archive($0) },
                        onDelete: { AppActionDispatcher(store: store).perform(.deleteWorkItem(id: $0.id)) },
                        onSendToOrchestrator: { sendToOrchestrator($0) },
                        onToggleBundleCollapsed: { toggleBundleCollapsed($0) },
                        onOpenBundle: { openBundleID = $0 },
                        onPickBundle: { handleBundlePick($0) },
                        draggingID: draggingID,
                        isDropTarget: target == status,
                        onDragChanged: dragChanged,
                        onDragEnded: dragEnded,
                        onToggleGroup: toggleGroup,
                        onAdd: { addItem(in: status) },
                        onAddInCategory: { addItem(in: status, category: $0) },
                        isSelected: selectedColumn == status,
                        onSelectColumn: { selectedColumn = status },
                        isMoveTarget: movingItemIDs != nil && target == status,
                        selectionModeActive: selectionModeActive,
                        cursorID: selectionCursorID,
                        pickedIDs: Set(pickedItemIDs)
                    )
                    // Move flow: blur every column but the one the arrows
                    // are currently pointed at, so the destination is
                    // unmissable.
                    .blur(radius: movingItemIDs != nil && target != status ? 5 : 0)
                    .animation(.easeOut(duration: 0.16), value: movingItemIDs != nil)
                    .animation(.easeOut(duration: 0.16), value: target)
                }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: BoardSpace.name)
        .onPreferenceChange(BoardColumnFrameKey.self) { new in
            // Preference writes during layout. Assigning every time invalidates
            // the board, and the board is glass over aurora — skip no-ops.
            if new != columnFrames { columnFrames = new }
        }
    }

    private func dragChanged(_ item: OrchestratorWorkItem, to point: CGPoint) {
        // Implicit animation interpolates the floating card toward the cursor
        // and the drop-target fills — that is the clump. Kill it for the drag.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if draggingID != item.id {
                draggingID = item.id
            }
            let target = columnFrames.first { $0.value.contains(point) }?.key
            if target != dropTarget { dropTarget = target }
        }
    }

    private func dragEnded(_ item: OrchestratorWorkItem, at point: CGPoint) {
        // Cards must land instantly. Animating a move reflows every column,
        // which fires column-frame preferences every tick, which invalidates
        // the glass, which is how the board drops to a few frames a second.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            draggingID = nil
            dropTarget = nil
            guard let target = columnFrames.first(where: { $0.value.contains(point) })?.key else { return }
            applyBoardMove(dragCohort(for: item), to: target)
        }
    }

    /// Every path that parks cards on a column — drag, Cmd+M / Cmd+B Enter —
    /// goes through here. DISPATCHED never writes status directly: it opens
    /// the agent picker, and only a confirmed pick commits the move.
    private func applyBoardMove(_ items: [OrchestratorWorkItem], to target: OrchestratorWorkStatus) {
        let moving = items.filter { $0.status.boardColumn != target }
        guard !moving.isEmpty else { return }

        if target == .dispatched {
            pendingDispatch = moving
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            for member in moving {
                AppActionDispatcher(store: store).perform(
                    .moveWorkItem(id: member.id, status: target, category: nil)
                )
            }
        }
    }

    /// The item itself, or every member sharing its `bundleID`.
    private func dragCohort(for item: OrchestratorWorkItem) -> [OrchestratorWorkItem] {
        guard let bundleID = item.bundleID else { return [item] }
        let members = items.filter { $0.bundleID == bundleID }
        return members.isEmpty ? [item] : members
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BOARD")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(DaddyTheme.textPrimary)
                Text(scopeSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(DaddyTheme.textMuted)
            }

            Spacer(minLength: 0)

            if movingItemIDs != nil {
                movePill
            } else if selectionModeActive {
                selectionPill
            }

            scopePicker
            categoryPicker

            if !store.pendingSyncBuckets.isEmpty {
                Button {
                    store.syncPendingNow()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "icloud.slash")
                        Text("\(store.pendingSyncBuckets.count)")
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DaddyTheme.textPrimary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .insetSurface(cornerRadius: 8)
                }
                .buttonStyle(.plain)
                .help("Not backed up to Drive — click to sync now")
            }

            Button {
                showArchived.toggle()
            } label: {
                Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(showArchived ? DaddyTheme.accent : DaddyTheme.textMuted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showArchived ? "Hide archived" : "Show archived")

            Text("\(items.count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DaddyTheme.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { GlassHairline() }
    }

    /// Shown only while Cmd+B selection is active — the only sign this mode
    /// exists at all, since it isn't an everyday feature.
    private var selectionPill: some View {
        HStack(spacing: 8) {
            Text("↑↓ move · ↵ pick · esc cancel")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DaddyTheme.textMuted)

            Button {
                sendBundle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane.fill")
                    Text(pickedItemIDs.count >= 2 ? "Send \(pickedItemIDs.count)" : "Send")
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(pickedItemIDs.count >= 2 ? DaddyTheme.textPrimary : DaddyTheme.textVeryDim)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background {
                    Capsule().fill(DaddyTheme.accent.opacity(pickedItemIDs.count >= 2 ? 0.28 : 0.08))
                }
            }
            .buttonStyle(.plain)
            .disabled(pickedItemIDs.count < 2)

            Button {
                exitSelectionMode()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DaddyTheme.textMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .insetSurface(cornerRadius: 8)
        .transition(.opacity)
    }

    /// Shown only during Cmd+M's move flow — the moment between picking
    /// items and picking their destination.
    private var movePill: some View {
        HStack(spacing: 8) {
            Text("←→ column · ↵ move · esc cancel")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DaddyTheme.textMuted)

            Button {
                cancelMove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DaddyTheme.textMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .insetSurface(cornerRadius: 8)
        .transition(.opacity)
    }

    private var scopePicker: some View {
        GlassDropdown(
            items: [
                GlassDropdownItem(id: "all", title: "All projects") { applyScope(.all) },
                GlassDropdownItem(id: "unassigned", title: "Unassigned") { applyScope(.unassigned) }
            ] + store.rootProjects.map { project in
                GlassDropdownItem(id: project.id, title: project.name) {
                    applyScope(.project(project.id))
                    // The rail and the board share one idea of "the project
                    // you are in", so picking here follows you back to Fleet.
                    store.select(project: project.id)
                }
            },
            width: 240
        ) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 9, weight: .semibold))
                Text(scopeTitle)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(DaddyTheme.textSecondary)
        }
    }

    private var categoryPicker: some View {
        GlassDropdown(
            items: [GlassDropdownItem(id: "all", title: "All categories") { categoryFilter = nil }]
                + OrchestratorWorkCategory.allCases.map { category in
                    GlassDropdownItem(
                        id: category.rawValue,
                        title: category.title,
                        // Doubles as the colour legend: the only place that
                        // pairs every category name with its swatch.
                        leading: AnyView(
                            Circle().fill(category.tint).frame(width: 7, height: 7)
                        )
                    ) {
                        categoryFilter = category
                    }
                },
            width: 210
        ) {
            HStack(spacing: 5) {
                if let categoryFilter {
                    Circle()
                        .fill(categoryFilter.tint)
                        .frame(width: 6, height: 6)
                } else {
                    categorySwatches
                }
                Text(categoryFilter?.title ?? "ALL")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(categoryFilter?.tint ?? DaddyTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// All five swatches in a row when nothing is filtered — a legend small
    /// enough to live in the header, so the card stripes mean something the
    /// first time you look at the board.
    private var categorySwatches: some View {
        HStack(spacing: 2) {
            ForEach(OrchestratorWorkCategory.allCases) { category in
                Circle()
                    .fill(category.tint)
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var scopeTitle: String {
        switch scope {
        case .all: return "All projects"
        case .unassigned: return "Unassigned"
        case .project(let id): return store.project(id)?.name ?? "Unknown project"
        }
    }

    private var scopeSubtitle: String {
        switch scope {
        case .all: return "Every project, plus what has none"
        case .unassigned: return "Captures with no project yet"
        case .project: return "Drag a card to move it"
        }
    }

    // MARK: - Dispatch

    @ViewBuilder
    private var dispatchOverlay: some View {
        if let pendingDispatch {
            BoardDispatchPicker(items: pendingDispatch) {
                self.pendingDispatch = nil
            }
        }
    }

    // MARK: - Detail

    /// Overlay, not a sibling in the board `HStack`. The pane sits on top of
    /// the columns and the columns keep their width. Animation lives on this
    /// container only — wrapping selection in `withAnimation` also interpolated
    /// every card's selected state, which is what made opening a task hitch.
    @ViewBuilder
    private var detailOverlay: some View {
        ZStack(alignment: .trailing) {
            if let item = selectedItem {
                BoardDetailPane(
                    item: item,
                    titleFocus: $editorTitleFocused,
                    summaryFocus: $editorSummaryFocused,
                    onClose: closeDetail,
                    onSendToAgent: { pendingDispatch = [item] }
                )
                .frame(width: 340)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 10)
                .padding(.trailing, 10)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: store.selectedOrchestratorWorkItemID != nil)
    }

    /// The bundle card has nothing of its own to edit — this is a summary of
    /// its members plus the one thing you can't do from the card itself:
    /// unbundle it.
    @ViewBuilder
    private var bundleDetailOverlay: some View {
        ZStack(alignment: .trailing) {
            if openBundleID != nil, !openBundleItems.isEmpty {
                BoardBundleDetailPane(
                    items: openBundleItems,
                    onClose: { openBundleID = nil },
                    onSelectItem: { item in
                        openBundleID = nil
                        select(item)
                    },
                    onUnbundle: unbundleOpenBundle
                )
                .frame(width: 340)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 10)
                .padding(.trailing, 10)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: openBundleID)
    }

    // MARK: - Actions

    /// Escape, through a local `NSEvent` monitor rather than `.onKeyPress`.
    ///
    /// `.onKeyPress` only fires while the view holds keyboard focus, and the
    /// board never takes it — which is why the first attempt did nothing at
    /// all. This is the same mechanism `FleetView` uses for its shortcuts.
    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard store.workspace == .board else { return event }

            let chords = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // The move flow is modal over everything else on the board —
            // once Cmd+M has picked up items, every key until Enter/Escape
            // steers or resolves that move, not whatever it would otherwise
            // do (bundling, column selection, and so on).
            if movingItemIDs != nil {
                switch event.keyCode {
                case 123: // Left
                    moveDropTarget(by: -1)
                case 124: // Right
                    moveDropTarget(by: 1)
                case 36, 76: // Return, keypad Enter
                    commitMove()
                case 53: // Escape
                    cancelMove()
                default: break
                }
                return nil
            }

            // Cmd+M starts the move flow on whatever's selected: the picked
            // set in selection mode, or the single item open in the detail
            // pane — expanded to every member if that item is bundled. Arrow
            // keys then pick the destination column (highlighted the same
            // way a real drag's drop target is) and Enter commits it.
            if event.keyCode == 46, chords == .command {
                let sourceItems = moveSourceItems
                guard !sourceItems.isEmpty else { return event }
                startMoveFlow(for: sourceItems)
                return nil
            }

            // Cmd+B toggles multi-select — pick a few cards, Cmd+B again
            // once 2+ are picked bundles them (a shared `bundleID`, no
            // dispatch) and drops straight into the move flow so you can
            // send the freshly-bundled group to DISPATCHED — or wherever —
            // in the same gesture. With fewer than 2 picked it just exits
            // selection mode, same as it always did.
            if event.keyCode == 11, chords == .command {
                if selectionModeActive, pickedItemIDs.count >= 2 {
                    let bundled = bundlePickedItems()
                    exitSelectionMode()
                    startMoveFlow(for: bundled)
                } else {
                    toggleSelectionMode()
                }
                return nil
            }

            // Enter with a column selected but no card cursor yet starts the
            // same bundling/selection mode Cmd+B does, seeded on that column
            // — so arrowing onto a column and hitting Enter works without
            // reaching for the Cmd+B chord first.
            if !selectionModeActive, chords.isEmpty, !editorTitleFocused, !editorSummaryFocused,
               store.selectedOrchestratorWorkItemID == nil, pendingDispatch == nil,
               selectedColumn != nil, event.keyCode == 36 || event.keyCode == 76 {
                toggleSelectionMode()
                return nil
            }

            if selectionModeActive, !editorTitleFocused, !editorSummaryFocused {
                // Cmd+Return sends the picked set once there are 2+ — with
                // fewer than 2 picked this falls through to the normal
                // single-item Cmd+Return handled by the detail pane.
                if (event.keyCode == 36 || event.keyCode == 76), chords == .command,
                   pickedItemIDs.count >= 2 {
                    sendBundle()
                    return nil
                }
                // Arrows and Enter navigate the picker itself; once a detail
                // pane is open over it, they belong to the pane (or its own
                // fields) instead.
                if chords.isEmpty, store.selectedOrchestratorWorkItemID == nil {
                    switch event.keyCode {
                    case 125: // Down
                        moveSelectionCursor(by: 1)
                        return nil
                    case 126: // Up
                        moveSelectionCursor(by: -1)
                        return nil
                    case 36, 76: // Return, keypad Enter
                        selectionEnter()
                        return nil
                    case 123: // Left
                        moveSelectionColumn(by: -1)
                        return nil
                    case 124: // Right
                        moveSelectionColumn(by: 1)
                        return nil
                    default: break
                    }
                }
            }

            // Left/right arrows step the selected column. Only outside
            // selection mode (which claims up/down/enter for its own card
            // cursor) and only with no task popup open or field focused.
            if !selectionModeActive, chords.isEmpty, !editorTitleFocused, !editorSummaryFocused,
               store.selectedOrchestratorWorkItemID == nil, pendingDispatch == nil {
                switch event.keyCode {
                case 123: // Left
                    moveColumnSelection(by: -1)
                    return nil
                case 124: // Right
                    moveColumnSelection(by: 1)
                    return nil
                default: break
                }
            }

            // Cmd+T creates a new card in the selected column, or BACKLOG if
            // no column is selected.
            if event.keyCode == 17, chords == .command {
                addItem(in: selectedColumn ?? .inbox)
                return nil
            }

            // Cmd+S backs up to Drive and local — the same action as the
            // cloud icon in the header. Only fires with no task popup open;
            // with one open, Cmd+S belongs to WorkItemFields' own handler,
            // which saves and closes that item instead.
            if event.keyCode == 1, chords == .command, store.selectedOrchestratorWorkItemID == nil {
                store.syncPendingNow()
                return nil
            }

            guard event.keyCode == 53, chords.isEmpty else { return event }

            // The dispatch picker is modal over the whole board, so it owns
            // Escape ahead of everything under it.
            if pendingDispatch != nil {
                pendingDispatch = nil
                return nil
            }

            if openBundleID != nil {
                openBundleID = nil
                return nil
            }

            // In selection mode, Escape closes an open detail pane first —
            // back to picking, not out of selection mode. With no pane open
            // it unpicks the most recently picked card, one at a time, and
            // only exits selection mode once nothing is left picked.
            if selectionModeActive {
                if store.selectedOrchestratorWorkItemID != nil {
                    closeDetail()
                } else if !pickedItemIDs.isEmpty {
                    pickedItemIDs.removeLast()
                } else {
                    exitSelectionMode()
                }
                return nil
            }

            if store.selectedOrchestratorWorkItemID != nil {
                closeDetail()
                return nil
            }
            store.workspace = store.workspaceBeforeBoard
            return nil
        }
    }

    // MARK: - Selection mode (bundling)

    /// The order arrow keys move through: the same column-then-category
    /// grouping the board draws. Each bundle counts as **one** stop (its
    /// lead item) — never every member — so the cursor can land on a
    /// bundle and move/pick it as a unit.
    private var selectionTraversalOrder: [OrchestratorWorkItem] {
        var order: [OrchestratorWorkItem] = []
        for status in columns {
            let columnItems = items.filter { $0.status.boardColumn == status }
            let leads = selectionLeads(in: columnItems)
            guard categoryFilter == nil else {
                order.append(contentsOf: leads)
                continue
            }
            for category in OrchestratorWorkCategory.allCases {
                guard !collapsedGroups.contains(BoardGroupKey(status: status, category: category)) else { continue }
                order.append(contentsOf: leads.filter { $0.category == category })
            }
        }
        return order
    }

    /// Solo cards as themselves; multi-item bundles as their first member
    /// only — mirrors `BoardColumn`'s unit grouping.
    private func selectionLeads(in columnItems: [OrchestratorWorkItem]) -> [OrchestratorWorkItem] {
        var seenBundles: Set<UUID> = []
        var leads: [OrchestratorWorkItem] = []
        for item in columnItems {
            if let bundleID = item.bundleID {
                guard !seenBundles.contains(bundleID) else { continue }
                seenBundles.insert(bundleID)
                let members = columnItems.filter { $0.bundleID == bundleID }
                leads.append(members.count > 1 ? members[0] : item)
            } else {
                leads.append(item)
            }
        }
        return leads
    }

    private func toggleSelectionMode() {
        if selectionModeActive {
            exitSelectionMode()
            return
        }
        selectionModeActive = true
        // If the open card is inside a bundle, land on the bundle unit (lead),
        // not a member that isn't in the traversal order.
        let seedID = selectedItem.map { traversalLeadID(for: $0) }
        // With no card open, prefer seeding on the selected column — Enter
        // on a column arrowed into should land the cursor there, not on
        // whatever happens to be traversal-first.
        let columnSeedID = selectedColumn.flatMap { column in
            selectionTraversalOrder.first { $0.status.boardColumn == column }?.id
        }
        selectionCursorID = seedID ?? columnSeedID ?? selectionTraversalOrder.first?.id
        pickedItemIDs = seedID.map { [$0] } ?? []
    }

    /// The id the keyboard cursor uses for this item: itself, or its bundle's
    /// lead when it's part of a multi-item bundle.
    private func traversalLeadID(for item: OrchestratorWorkItem) -> UUID {
        guard let bundleID = item.bundleID else { return item.id }
        let members = items.filter { $0.bundleID == bundleID }
        return members.count > 1 ? members[0].id : item.id
    }

    private func exitSelectionMode() {
        selectionModeActive = false
        pickedItemIDs = []
        selectionCursorID = nil
    }

    /// The items Cmd+M would move: the picked set in selection mode, or the
    /// single item open in the detail pane — either way expanded to every
    /// member sharing a `bundleID`, so moving one row of a bundle takes the
    /// whole bundle with it.
    private var moveSourceItems: [OrchestratorWorkItem] {
        let baseIDs: Set<UUID>
        if selectionModeActive, !pickedItemIDs.isEmpty {
            baseIDs = Set(pickedItemIDs)
        } else if let selectedItem {
            baseIDs = [selectedItem.id]
        } else {
            baseIDs = []
        }
        guard !baseIDs.isEmpty else { return [] }
        var expandedIDs = baseIDs
        for id in baseIDs {
            guard let bundleID = items.first(where: { $0.id == id })?.bundleID else { continue }
            expandedIDs.formUnion(items.filter { $0.bundleID == bundleID }.map(\.id))
        }
        return items.filter { expandedIDs.contains($0.id) }
    }

    /// Stamps the currently-picked cards with a shared `bundleID` — no
    /// status change, no dispatch, just the grouping — so Cmd+B's
    /// bundle-then-move can hand `startMoveFlow` a real bundle to move as
    /// one unit.
    private func bundlePickedItems() -> [OrchestratorWorkItem] {
        let ordered = selectionTraversalOrder.filter { pickedItemIDs.contains($0.id) }
        guard ordered.count >= 2 else { return [] }
        let bundleID = UUID()
        return ordered.map { item in
            var bundled = item
            bundled.bundleID = bundleID
            bundled.updatedAt = Date()
            AppActionDispatcher(store: store).perform(.replaceWorkItem(bundled))
            return bundled
        }
    }

    /// Clears `bundleID` on every member of the open bundle — the board
    /// stops drawing them as one `BoardBundleCard` and closes the pane, but
    /// each item otherwise keeps its status, category, and everything else.
    private func unbundleOpenBundle() {
        guard let bundleID = openBundleID else { return }
        openBundleID = nil
        // Full store, not `openBundleItems` (board-filtered) — a category /
        // project filter would otherwise leave siblings bundled and the card
        // would still draw.
        store.unbundleWorkItems(bundleID: bundleID)
    }

    /// Enters the move flow for a given set of items — shared by Cmd+M and
    /// Cmd+B's bundle-then-move. Defaults the highlight to DISPATCHED (the
    /// usual next step after bundling); if the cards are already there,
    /// steps one column past that instead.
    private func startMoveFlow(for sourceItems: [OrchestratorWorkItem]) {
        guard !sourceItems.isEmpty else { return }
        movingItemIDs = sourceItems.map(\.id)
        let sourceColumn = sourceItems.first?.status.boardColumn
        if sourceColumn != .dispatched, columns.contains(.dispatched) {
            dropTarget = .dispatched
            return
        }
        let sourceIndex = sourceColumn.flatMap { columns.firstIndex(of: $0) }
        if let sourceIndex, columns.indices.contains(sourceIndex + 1) {
            dropTarget = columns[sourceIndex + 1]
        } else if let sourceIndex, columns.indices.contains(sourceIndex - 1) {
            dropTarget = columns[sourceIndex - 1]
        } else {
            dropTarget = columns.first
        }
    }

    /// Left/right during the move flow — steers `dropTarget`, the same
    /// state a real drag highlights, so the highlighted column looks
    /// identical either way.
    private func moveDropTarget(by delta: Int) {
        let order = columns
        guard !order.isEmpty else { return }
        guard let current = dropTarget, let currentIndex = order.firstIndex(of: current) else {
            dropTarget = delta > 0 ? order.first : order.last
            return
        }
        // Wraps rather than stopping dead at either edge — DONE's right
        // arrow lands back on BACKLOG, and vice versa.
        let next = (currentIndex + delta + order.count) % order.count
        dropTarget = order[next]
    }

    private func commitMove() {
        guard let ids = movingItemIDs, let target = dropTarget else {
            cancelMove()
            return
        }
        let moving = ids.compactMap { store.workItem($0) }
        movingItemIDs = nil
        dropTarget = nil
        if selectionModeActive { exitSelectionMode() }
        // Same gate as a drag onto DISPATCHED — never write the column
        // without going through the agent picker first.
        applyBoardMove(moving, to: target)
    }

    private func cancelMove() {
        movingItemIDs = nil
        dropTarget = nil
    }

    /// Left/right arrows step the selected column — the one Cmd+T adds into
    /// and the one drawn with the stronger border/fill in `BoardColumn`.
    private func moveColumnSelection(by delta: Int) {
        let order = columns
        guard !order.isEmpty else { return }
        guard let current = selectedColumn,
              let currentIndex = order.firstIndex(of: current) else {
            selectedColumn = delta > 0 ? order.first : order.last
            return
        }
        // Wraps rather than stopping dead at either edge — DONE's right
        // arrow lands back on BACKLOG, and vice versa.
        let next = (currentIndex + delta + order.count) % order.count
        selectedColumn = order[next]
    }

    private func moveSelectionCursor(by delta: Int) {
        let order = selectionTraversalOrder
        guard !order.isEmpty else { return }
        guard let currentID = selectionCursorID,
              let currentIndex = order.firstIndex(where: { $0.id == currentID }) else {
            selectionCursorID = delta > 0 ? order.first?.id : order.last?.id
            return
        }
        let next = currentIndex + delta
        guard order.indices.contains(next) else { return }
        selectionCursorID = order[next].id
    }

    /// Left/right while the cursor is active: jumps it to the adjacent
    /// column instead of requiring Escape first. Skips columns with nothing
    /// to land on, and keeps `selectedColumn` in step so the column's
    /// highlighted border follows the cursor.
    private func moveSelectionColumn(by delta: Int) {
        let order = selectionTraversalOrder
        guard !columns.isEmpty else { return }
        guard let currentID = selectionCursorID,
              let currentItem = order.first(where: { $0.id == currentID }),
              let columnIndex = columns.firstIndex(of: currentItem.status.boardColumn) else {
            selectionCursorID = order.first?.id
            return
        }
        // Wraps rather than stopping dead at either edge, same as the plain
        // column-selection arrows — capped at one full lap so an all-empty
        // board (nothing left to land the cursor on) doesn't spin forever.
        var nextIndex = (columnIndex + delta + columns.count) % columns.count
        for _ in columns.indices {
            let candidate = columns[nextIndex]
            if let firstInColumn = order.first(where: { $0.status.boardColumn == candidate }) {
                selectionCursorID = firstInColumn.id
                selectedColumn = candidate
                return
            }
            nextIndex = (nextIndex + delta + columns.count) % columns.count
        }
    }

    /// First Enter on a card picks it. Enter again on an already-picked card
    /// opens its detail pane (or the bundle summary, for a bundle unit) —
    /// Escape (or Cmd+S) closes that pane back to the picker.
    private func selectionEnter() {
        guard let id = selectionCursorID,
              let item = store.workItem(id) ?? items.first(where: { $0.id == id }) else { return }
        if pickedItemIDs.contains(id) {
            if let bundleID = item.bundleID,
               items.filter({ $0.bundleID == bundleID }).count > 1 {
                openBundleID = bundleID
            } else {
                select(item)
            }
        } else {
            pickedItemIDs.append(id)
        }
    }

    /// A card click while selection mode is active picks it instead of
    /// opening the detail pane — mirrors keyboard Enter on the cursor.
    /// Rows inside a bundle always open that item's detail instead: the
    /// bundle is picked as a unit from the keyboard (or its header).
    private func handleCardSelect(_ item: OrchestratorWorkItem) {
        if let bundleID = item.bundleID,
           items.filter({ $0.bundleID == bundleID }).count > 1 {
            select(item)
            return
        }
        guard selectionModeActive else {
            select(item)
            return
        }
        selectionCursorID = item.id
        if pickedItemIDs.contains(item.id) {
            pickedItemIDs.removeAll { $0 == item.id }
        } else {
            pickedItemIDs.append(item.id)
        }
    }

    /// Keyboard/header pick of a whole bundle — stores the lead id only;
    /// `moveSourceItems` expands to every member when moving.
    private func handleBundlePick(_ lead: OrchestratorWorkItem) {
        guard selectionModeActive else {
            if let bundleID = lead.bundleID { openBundleID = bundleID }
            return
        }
        selectionCursorID = lead.id
        if pickedItemIDs.contains(lead.id) {
            pickedItemIDs.removeAll { $0 == lead.id }
        } else {
            pickedItemIDs.append(lead.id)
        }
    }

    private func sendBundle() {
        let ordered = selectionTraversalOrder.filter { pickedItemIDs.contains($0.id) }
        let picked = ordered.count >= 2 ? ordered : items.filter { pickedItemIDs.contains($0.id) }
        guard picked.count >= 2 else { return }
        exitSelectionMode()
        pendingDispatch = picked
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }

    private func select(_ item: OrchestratorWorkItem) {
        justCreatedID = nil
        selectedColumn = item.status.boardColumn
        store.selectedOrchestratorWorkItemID = item.id
        // The pane animates in; focusing on the next runloop lands once it
        // exists rather than racing its appearance — same reasoning as
        // `addItem`'s title focus below.
        DispatchQueue.main.async { editorSummaryFocused = true }
    }

    private func closeDetail() {
        // An add abandoned before anything was typed leaves no card behind.
        if let id = justCreatedID,
           let item = store.workItem(id),
           item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AppActionDispatcher(store: store).perform(.deleteWorkItem(id: id))
        }
        justCreatedID = nil
        editorTitleFocused = false
        editorSummaryFocused = false
        store.selectedOrchestratorWorkItemID = nil
    }

    /// The board follows Fleet's current project so cards from one repo do not
    /// keep sitting on another. "All" and "Unassigned" are explicit overrides.
    /// Subdirectories are not projects on this picker — fold them into the
    /// Documents-level folder they sit in.
    private func syncScopeFromProject() {
        if let id = store.selectedProjectID {
            let rootID = store.project(id)?.parentID ?? id
            applyScope(.project(rootID))
        } else {
            applyScope(.all)
        }
    }

    private func applyScope(_ new: BoardProjectScope) {
        scope = new
        guard let item = selectedItem else { return }
        switch new {
        case .all:
            break
        case .unassigned:
            if item.projectID != nil { closeDetail() }
        case .project(let id):
            if item.projectID != id { closeDetail() }
        }
    }

    private func projectName(for item: OrchestratorWorkItem) -> String? {
        guard case .all = scope else { return nil }
        guard let id = item.projectID else { return nil }
        return store.project(id)?.name
    }

    private func toggleBundleCollapsed(_ id: UUID) {
        if collapsedBundleIDs.contains(id) {
            collapsedBundleIDs.remove(id)
        } else {
            collapsedBundleIDs.insert(id)
        }
    }

    private func toggleGroup(_ key: BoardGroupKey) {
        if collapsedGroups.contains(key) {
            collapsedGroups.remove(key)
        } else {
            collapsedGroups.insert(key)
        }
    }

    /// The plus button creates the item straight away and opens it in the
    /// detail pane with the title focused, so naming it is one keystroke. The
    /// title starts empty — closing before typing anything deletes the item.
    private func addItem(in status: OrchestratorWorkStatus, category: OrchestratorWorkCategory? = nil) {
        let item = OrchestratorWorkItem(
            title: "",
            summary: "",
            rawCapture: "",
            category: category ?? categoryFilter ?? .other,
            status: status,
            projectID: addProjectID
        )
        AppActionDispatcher(store: store).perform(.createWorkItem(item))
        justCreatedID = item.id
        selectedColumn = status
        store.selectedOrchestratorWorkItemID = item.id
        // The pane animates in; focusing on the next runloop lands once it
        // exists rather than racing its appearance.
        DispatchQueue.main.async { editorTitleFocused = true }
    }

    private var addProjectID: String? {
        switch scope {
        case .all: return store.selectedProjectID
        case .unassigned: return nil
        case .project(let id): return id
        }
    }

    private func archive(_ item: OrchestratorWorkItem) {
        AppActionDispatcher(store: store).perform(.moveWorkItem(id: item.id, status: .archived, category: nil))
    }

    /// Dispatch lives in the Orchestrator — agent picker, session picker and
    /// an approval step. Rather than grow a second copy of all that here, the
    /// board selects the item and hands the window over.
    private func sendToOrchestrator(_ item: OrchestratorWorkItem) {
        store.selectedOrchestratorWorkItemID = item.id
        store.workspace = .orchestrator
    }
}

/// The detail pane as its own view, so typing in it does not rebuild the
/// board. The editor state used to live in `BoardView`, which meant every
/// keystroke re-evaluated the columns, the cards and the header — and
/// repainted the glass over the animating aurora. Now keystrokes invalidate
/// only this pane. Selection switches re-seed via `item.id`; saves keep the
/// state (seeded from the saved values, which is what is on screen).
private struct BoardDetailPane: View {
    @Environment(MockStore.self) private var store

    let item: OrchestratorWorkItem
    let titleFocus: FocusState<Bool>.Binding?
    let summaryFocus: FocusState<Bool>.Binding?
    let onClose: () -> Void
    /// Cmd+Return, from anywhere in the popup — see `installDeleteMonitor`,
    /// which now carries both chords despite the name.
    let onSendToAgent: () -> Void

    @State private var title: String
    @State private var summary: String
    @State private var category: OrchestratorWorkCategory
    @State private var status: OrchestratorWorkStatus
    @State private var priority: OrchestratorPriority
    @State private var projectID: String
    @State private var deleteKeyMonitor: Any?

    init(
        item: OrchestratorWorkItem,
        titleFocus: FocusState<Bool>.Binding? = nil,
        summaryFocus: FocusState<Bool>.Binding? = nil,
        onClose: @escaping () -> Void,
        onSendToAgent: @escaping () -> Void
    ) {
        self.item = item
        self.titleFocus = titleFocus
        self.summaryFocus = summaryFocus
        self.onClose = onClose
        self.onSendToAgent = onSendToAgent
        _title = State(initialValue: item.title)
        _summary = State(initialValue: item.summary)
        _category = State(initialValue: item.category)
        _status = State(initialValue: item.status.boardColumn)
        _priority = State(initialValue: item.priority)
        _projectID = State(initialValue: item.projectID ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("WORK ITEM")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(DaddyTheme.textSecondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DaddyTheme.textMuted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .overlay(alignment: .bottom) { GlassHairline() }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    WorkItemFields(
                        title: $title,
                        summary: $summary,
                        category: $category,
                        status: $status,
                        priority: $priority,
                        projectID: $projectID,
                        projects: store.rootProjects,
                        titleFocus: titleFocus,
                        summaryFocus: summaryFocus,
                        onSave: save,
                        onSaveAndClose: { save(); onClose() }
                    )

                    GlassHairline()

                    HStack(spacing: 10) {
                        WorkItemDispatchMenu(item: item, onWillDispatch: save)
                            .frame(maxWidth: .infinity)

                        Button("Delete") {
                            AppActionDispatcher(store: store).perform(.deleteWorkItem(id: item.id))
                        }
                        .buttonStyle(.insetLarge(DaddyTheme.failure))
                    }

                    if !item.rawCapture.isEmpty, item.rawCapture != item.summary {
                        Text("ORIGINAL CAPTURE")
                            .workItemFieldLabel()
                        Text(item.rawCapture)
                            .font(.system(size: 10))
                            .foregroundStyle(DaddyTheme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
        }
        .glassPanel()
        .onChange(of: item.id) { _, _ in seed(from: item) }
        .onAppear { installDeleteMonitor() }
        .onDisappear { removeDeleteMonitor() }
    }

    /// Cmd+Backspace (delete) and Cmd+Return (send to agent), alongside the
    /// existing buttons. A local monitor rather than `.onKeyPress` for the
    /// same reason the board's Escape handling is one — the pane never holds
    /// keyboard focus itself while a text field inside it does. Escape's own
    /// handling lives entirely in `BoardView` and is untouched by this.
    private func installDeleteMonitor() {
        guard deleteKeyMonitor == nil else { return }
        deleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let chords = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard chords == .command else { return event }
            // 51 is Delete — the backspace key, which is what ⌘⌫ means on a Mac.
            if event.keyCode == 51 {
                deleteWithUndo()
                return nil
            }
            // 36 is Return.
            if event.keyCode == 36 {
                save()
                onSendToAgent()
                return nil
            }
            return event
        }
    }

    private func removeDeleteMonitor() {
        if let deleteKeyMonitor {
            NSEvent.removeMonitor(deleteKeyMonitor)
            self.deleteKeyMonitor = nil
        }
    }

    /// Deletes the item and closes the pane, leaving a 5s toast with an Undo
    /// that recreates it — the same toast/undo mechanism voice actions use.
    private func deleteWithUndo() {
        guard let current = store.workItem(item.id) else { return }
        AppActionDispatcher(store: store).perform(.deleteWorkItem(id: item.id))
        onClose()
        let label = current.title.trimmingCharacters(in: .whitespacesAndNewlines)
        store.showVoiceToast(VoiceToast(
            label: "Deleted \"\(label.isEmpty ? "Untitled" : label)\"",
            undoAction: .createWorkItem(current),
            icon: nil
        ))
    }

    private func seed(from item: OrchestratorWorkItem) {
        title = item.title
        summary = item.summary
        category = item.category
        status = item.status.boardColumn
        priority = item.priority
        projectID = item.projectID ?? ""
    }

    private func save() {
        guard var fresh = store.workItem(item.id) else { return }
        // Title only — headline case on commit so you can type all-lowercase
        // and Save / Cmd+S / Enter writes the proper capitals.
        let styledTitle = WorkItemTitleCase.apply(title)
        title = styledTitle
        fresh.title = styledTitle
        fresh.summary = summary
        fresh.category = category
        fresh.status = status
        fresh.priority = priority
        fresh.projectID = projectID.isEmpty ? nil : projectID
        fresh.updatedAt = Date()
        AppActionDispatcher(store: store).perform(.replaceWorkItem(fresh))
    }
}

/// A bundle card has no fields of its own — this is a read-only roster of
/// its members (each row opens that item's own `BoardDetailPane`) plus the
/// one action the card itself doesn't offer: unbundling.
private struct BoardBundleDetailPane: View {
    let items: [OrchestratorWorkItem]
    let onClose: () -> Void
    let onSelectItem: (OrchestratorWorkItem) -> Void
    let onUnbundle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(items.count) TASKS BUNDLED")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(DaddyTheme.textSecondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DaddyTheme.textMuted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .overlay(alignment: .bottom) { GlassHairline() }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        Button { onSelectItem(item) } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(item.category.tint)
                                    .frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title.isEmpty ? "Untitled" : item.title)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(DaddyTheme.textPrimary)
                                        .lineLimit(2)
                                    Text(item.status.boardColumn.title)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(DaddyTheme.textMuted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(DaddyTheme.textVeryDim)
                            }
                            .padding(10)
                            .insetSurface(cornerRadius: 10)
                        }
                        .buttonStyle(.plain)
                    }

                    GlassHairline()

                    Button("Unbundle", action: onUnbundle)
                        .buttonStyle(.insetLarge(DaddyTheme.failure))
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
        }
        .glassPanel()
    }
}
