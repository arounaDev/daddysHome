import SwiftUI
import DaddyCore

/// The rail down the left: what you have, and what is running in it.
///
/// This replaces `ProjectsSidebar` as the container. The difference that
/// matters is not that it grew an agents list — it is that **it never goes
/// away**. Focusing an agent used to hide the entire left side of the app, so
/// the moment you started working you could no longer see the project tree, the
/// other agents, or whether any of them had finished, errored or gone quiet.
/// The one thing you most want while a terminal is open is the state of
/// everything that is not that terminal.
///
/// Two sections, one scroll view: the project tree, and every live agent. Both
/// stay legible when the rail is collapsed to a strip of dots.
struct WorkspaceRail: View {
    @Environment(MockStore.self) private var store

    @Binding var expanded: Bool
    var hoverExpansionEnabled = true

    /// Held open by the chevron / folder button rather than by the cursor.
    /// A pinned rail ignores hover entirely.
    ///
    /// Owned by `FleetView` rather than held here, because ⌘B has to be able to
    /// set it: a keyboard toggle that only moved `expanded` would be undone by
    /// the next hover, which is not what a deliberate keypress means.
    @Binding var pinned: Bool
    @State private var expandedProjectIDs: Set<String> = []

    /// What is on disk under each project, and what you are doing to it.
    /// Owned here rather than by the section, so expansion, selection and the
    /// open directory watchers survive the section being rebuilt.
    @State private var fileTree = FileTreeStore()

    /// The project list is folded to its first eight by default (`daddy`, then recency).
    @State private var showingAllProjects = false

    /// True while a drag is somewhere over the rail.
    ///
    /// This exists because `.onHover` is silent during a drag session — AppKit
    /// is not sending mouse-moved events, the pointer belongs to the drag — so
    /// none of the hover machinery below can see a file being carried across
    /// the rail. Without it, the rail collapses out from under a drag exactly
    /// when it is most in the way.
    @State private var dragHovering = false
    @State private var dragClearTask: Task<Void, Never>?

    /// The file tree's shortcuts, read from the event stream.
    @State private var treeKeyMonitor: Any?

    /// Disarms the tree on any click, so a click into a terminal hands the
    /// keyboard straight back. A row click re-arms it on mouse-*up*, which is
    /// after this fires.
    @State private var treeClickMonitor: Any?

    /// Leaving the panel starts a short countdown instead of collapsing at
    /// once. Without it, clipping the edge on the way to the grid — or crossing
    /// the gap between the rail and its own popovers — slams it shut
    /// mid-movement.
    @State private var collapseTask: Task<Void, Never>?

    /// Entering the trigger strip starts a countdown too. Expanding used to be
    /// instant while only collapsing was debounced, and that asymmetry is what
    /// made one pass across the left of the window pop the rail open: there was
    /// no way to cross it without opening it.
    @State private var expandTask: Task<Void, Never>?

    /// Hover, remembered rather than only acted on, so a synthesized repeat of
    /// the transition we are already in is ignored. Two sources, because the
    /// trigger strip and the panel are separate hit regions that overlap.
    @State private var pointerInTrigger = false
    @State private var pointerInPanel = false

    /// Set while the width animates, during which the rail will not *collapse*.
    ///
    /// The rail's hover region *is* its animating frame. Between 50pt and 264pt
    /// it sweeps across a stationary pointer, and AppKit reports that as the
    /// pointer entering and leaving — so an expansion synthesizes an exit,
    /// which schedules a collapse, whose animation synthesizes an entry, which
    /// expands again. That is the flicker. `FleetView.suppressSidebarHover`
    /// already applies this remedy to the detail transition, for the same
    /// reason and with the same comment; the rail's own animation is the far
    /// more frequent one.
    ///
    /// Only collapsing is suppressed. Blocking *expansion* during the window
    /// meant a pointer that arrived just after a collapse got a dwell that was
    /// silently dropped, and since a stationary pointer produces no further
    /// hover events, the rail then refused to open at all.
    @State private var settling = false
    @State private var settleTask: Task<Void, Never>?

    private static let expandDwell: Duration = .milliseconds(180)
    private static let collapseDelay: Duration = .milliseconds(200)
    private static let settleWindow: Duration = .milliseconds(360)

    /// How long "no drag is over me" has to hold before it counts.
    ///
    /// Moving between two rows reports a leave and then an enter, with a gap
    /// between them. Acting on the leave would schedule a collapse every time
    /// the pointer crossed a row boundary.
    private static let dragClearDelay: Duration = .milliseconds(400)

    /// How long the rail stays open after a file lands, so you can see where
    /// it went before it gets out of the way.
    private static let postDropHold: Duration = .seconds(2)

    private var liveAgents: [MockAgent] {
        store.agents
            .filter(\.isLive)
            .sorted { $0.lastOutputAt > $1.lastOutputAt }
    }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            if expanded {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ProjectsSection(
                            expandedProjectIDs: $expandedProjectIDs,
                            showingAllProjects: $showingAllProjects,
                            fileTree: fileTree,
                            // Pinned, or with a file in flight. There is no way
                            // to pin the rail once a drag has started, so a
                            // drag has to be able to unfold the tree itself.
                            showsFileTree: pinned || dragHovering,
                            actionsEnabled: pinned,
                            onDragTarget: dragTargetChanged
                        )

                        if !liveAgents.isEmpty {
                            GlassHairline()
                            agentsSection
                        }
                    }
                    .padding(10)
                }

                GlassHairline()
                focusFooter
            } else {
                collapsed
            }
        }
        // Each state lays out at its own final width, not at whatever the
        // animating frame currently proposes.
        //
        // The branch above flips the instant `expanded` changes, while the
        // frame `FleetView` gives us takes 300ms to follow. Sized by the
        // proposal, the expanded content — whose header alone needs ~150pt —
        // spends that 300ms crushed into a 50pt frame and then *overflowing* it,
        // because `.frame(width:)` does not clip. That is both the mangled
        // animation and a hover region reaching well past the visible rail.
        // Pinned to a constant, growing the frame simply reveals it.
        .frame(
            width: expanded ? DaddyTheme.railWideWidth : DaddyTheme.railNarrowWidth,
            alignment: .leading
        )
        .animation(nil, value: expanded)
        .glassPanel()
        // Hover follows the shape you can see, not the layout rectangle.
        .contentShape(Rectangle())
        // Double-click anywhere on the rail pins it, the way double-clicking a
        // title bar zooms a window. Aiming at a 10pt chevron to keep the thing
        // open is a bad deal for the most common gesture there is.
        //
        // Rows are safe from this: a `Button` consumes its own clicks, so a
        // double-click on a project or a file never reaches here.
        .onTapGesture(count: 2) { togglePin() }
        // Anywhere on the panel keeps an open rail open.
        .onHover { hovering in
            pointerInPanel = hovering
            hoverChanged()
        }
        // The trigger that *opens* it: the collapsed rail's own width, pinned to
        // the leading edge, present whether or not the rail is open.
        //
        // It has to be a region that never moves. The rail's trailing edge
        // sweeps from 50pt to 264pt and back, and a hover target that animates
        // under a stationary pointer is reported as the pointer entering and
        // leaving — which is the flicker this whole mechanism exists to avoid.
        // The leading edge is pinned by the layout, so a leading-aligned strip
        // of the collapsed width is geometrically fixed.
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: DaddyTheme.railNarrowWidth)
                .contentShape(Rectangle())
                .onHover { hovering in
                    pointerInTrigger = hovering
                    hoverChanged()
                }
        }
        .onChange(of: fileTree.lastDropAt) { _, landed in
            if landed != nil { holdOpenAfterDrop() }
        }
        .onAppear {
            syncTreeRoots()
            installTreeKeyMonitor()
        }
        .onChange(of: store.projects) { _, _ in syncTreeRoots() }
        // A trashed or renamed project root is still a row until `MockStore`
        // rescans, and it does that on a 30-second timer. Ask it now instead.
        .onChange(of: fileTree.lastStructuralChangeAt) { _, changed in
            if changed != nil { store.refreshProjects() }
        }
        .onChange(of: store.selectedProjectID) { _, _ in syncTreeRoots() }
        .alert(
            fileTree.errorMessage ?? "",
            isPresented: Binding(
                get: { fileTree.errorMessage != nil },
                set: { if !$0 { fileTree.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
        .onDisappear {
            collapseTask?.cancel()
            expandTask?.cancel()
            settleTask?.cancel()
            dragClearTask?.cancel()
            removeTreeKeyMonitor()
        }
    }

    // MARK: Expanded

    private var header: some View {
        HStack(spacing: 12) {
            Text("PROJECTS")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(DaddyTheme.textPrimary)

            Spacer()

            Button(action: { togglePin() }) {
                Image(systemName: pinned ? "pin.fill" : "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(pinned ? DaddyTheme.textSecondary : DaddyTheme.textMuted)
            }
            .buttonStyle(.plain)
            .help(pinned ? "Unpin" : "Keep open")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("AGENTS")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(DaddyTheme.textMuted)

                Text("\(liveAgents.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DaddyTheme.textVeryDim)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)

            ForEach(liveAgents) { agent in
                RailAgentRow(
                    agent: agent,
                    projectName: store.project(agent.projectID)?.name ?? agent.projectID,
                    isFocused: store.detailAgentID == agent.id
                ) {
                    withAnimation(.smooth(duration: 0.2)) { store.openDetail(agent.id) }
                }
            }
        }
    }

    private var focusFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FOCUS")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(DaddyTheme.textMuted)

            Text(focusDescription)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DaddyTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: Collapsed
    //
    // A strip of dots, and it has to carry both kinds of state: which projects
    // have agents, and what those agents are doing. A collapsed rail that only
    // showed projects would be the same blindness this view exists to fix.

    private var collapsed: some View {
        VStack(spacing: 4) {
            Button(action: { togglePin() }) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DaddyTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)

            Divider()
                .opacity(0.2)
                .padding(.vertical, 4)

            ScrollView {
                VStack(spacing: 8) {
                    // Folded the same way the open rail is. A strip of thirty
                    // identical dots is not a glance at anything.
                    ForEach(store.previewRootProjects) { project in
                        Button(action: {
                            withAnimation(.smooth(duration: 0.3)) {
                                _ = AppActionDispatcher(store: store).perform(.openProject(projectID: project.id))
                            }
                        }) {
                            Circle()
                                .fill(store.agentCount(for: project.id) > 0
                                      ? DaddyTheme.working : DaddyTheme.textVeryDim)
                                .frame(width: 8, height: 8)
                                .overlay(
                                    Circle().strokeBorder(
                                        store.selectedProjectID == project.id
                                            ? DaddyTheme.textPrimary.opacity(0.6) : Color.clear,
                                        lineWidth: 1.5
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .help(project.name)
                    }

                    if !liveAgents.isEmpty {
                        Divider()
                            .opacity(0.2)
                            .padding(.vertical, 4)

                        ForEach(liveAgents) { agent in
                            Button(action: {
                                withAnimation(.smooth(duration: 0.2)) {
                                    store.openDetail(agent.id)
                                }
                            }) {
                                ProviderLogo.badge(for: agent.agent, diameter: 22)
                                    .overlay(alignment: .bottomTrailing) {
                                        Circle()
                                            .fill(StateColors.accent(for: agent.state))
                                            .frame(width: 7, height: 7)
                                            .overlay(
                                                Circle().strokeBorder(
                                                    DaddyTheme.bubbleRim, lineWidth: 1
                                                )
                                            )
                                    }
                            }
                            .buttonStyle(.plain)
                            .help("\(store.project(agent.projectID)?.name ?? "") · \(StateColors.name(for: agent.state))")
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .frame(maxHeight: .infinity)
        // The drag equivalent of the hover trigger strip, and it belongs *on*
        // the collapsed content rather than in an overlay above it.
        //
        // It was an overlay first, and that broke the rail outright: a
        // `Color.clear` with a content shape is hit-testable like anything
        // else, so a strip laid over the collapsed rail ate the hover that
        // opens it and the click on the folder button underneath. Attached
        // here it is the same region, but the buttons inside it are hit first
        // and the drop target only catches what nothing else wanted.
        //
        // `accepts: false` on purpose: this opens the rail and then gets out
        // of the way. The drag is still in flight, and the folder you actually
        // want is a row that has not been drawn yet. It disappears with the
        // collapsed branch, so an open rail lets its own rows take the drop.
        .modifier(
            FolderDropTarget(
                accepts: false,
                onFiles: { _ in },
                onTargetChanged: dragTargetChanged,
                onSpringLoad: {}
            )
        )
    }

    // MARK: The file tree's keyboard

    /// Keeps `FileTreeStore` told which project roots exist and which one is
    /// selected, so the key handler below can work out where a new file goes
    /// without reaching into the environment from an event monitor.
    private func syncTreeRoots() {
        fileTree.setProjectRoots(store.rootProjects.map(\.path))

        guard let selected = store.selectedProject else {
            fileTree.setSelectedRoot(nil)
            return
        }
        let rootID = selected.parentID ?? selected.id
        fileTree.setSelectedRoot(store.project(rootID)?.path ?? selected.path)
    }

    private func installTreeKeyMonitor() {
        if treeKeyMonitor == nil {
            treeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleTreeKey(event) ? nil : event
            }
        }

        // Every click disarms the tree, and a click that lands on a row arms it
        // again from the row's own action — which runs on mouse-up, after this.
        // So clicking a terminal, the dashboard, or the rail's own header all
        // give the keyboard back, without any of them needing to know the tree
        // exists.
        if treeClickMonitor == nil {
            treeClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                fileTree.deactivate()
                return event
            }
        }
    }

    private func removeTreeKeyMonitor() {
        if let treeKeyMonitor { NSEvent.removeMonitor(treeKeyMonitor) }
        treeKeyMonitor = nil
        if let treeClickMonitor { NSEvent.removeMonitor(treeClickMonitor) }
        treeClickMonitor = nil
    }

    /// Enter, ⌘⌫ and the rest — but only when all three gates are open.
    ///
    /// **Pinned**, because a hover rail is gone before your hand arrives.
    /// **Armed**, meaning a tree row was the last thing clicked. **Not
    /// renaming**, because the field owns every key while it is up.
    ///
    /// The middle one used to ask AppKit who held first responder, and that is
    /// why Enter would stop working once a folder was expanded: first responder
    /// moves during a relayout, so inserting rows was enough to make the tree go
    /// deaf. What you last clicked cannot drift out from under you like that.
    ///
    /// `charactersIgnoringModifiers` rather than `characters`, so Option stays
    /// out of it. On a Spanish layout Option is a compose layer and ⌥⌘C would
    /// otherwise arrive as something that is not a "c" at all.
    private func handleTreeKey(_ event: NSEvent) -> Bool {
        guard pinned, fileTree.isActive, fileTree.renaming == nil else { return false }

        let chord = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Creating needs no selection: with nothing picked it lands in the
        // selected project's root.
        if let directory = fileTree.creationDirectory {
            if chord == [.command], character == "n" {
                fileTree.createFile(in: directory)
                return true
            }
            if chord == [.command, .shift], character == "n" {
                fileTree.createFolder(in: directory)
                return true
            }
        }

        // Finder's chord. Shift survives `charactersIgnoringModifiers`, so the
        // key arrives as ">" rather than ".".
        if chord == [.command, .shift], character == "." || character == ">" {
            fileTree.toggleHiddenFiles()
            return true
        }

        guard let path = fileTree.selection, let entry = fileTree.entry(at: path) else {
            return false
        }

        // Return (36) and the keypad's own Enter (76).
        if chord.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            fileTree.beginRenamingSelection()
            return true
        }
        // 51 is Delete — the backspace key, which is what ⌘⌫ means on a Mac.
        if chord == [.command], event.keyCode == 51 {
            fileTree.trash(entry)
            return true
        }
        if chord == [.command, .shift], character == "r" {
            fileTree.revealInFinder(path)
            return true
        }
        if chord == [.command, .option], character == "c" {
            fileTree.copyPath(path)
            return true
        }

        return false
    }

    // MARK: Behaviour

    private func togglePin() {
        pinned.toggle()
        cancelPending()
        setExpanded(pinned)
    }

    /// Whether the pointer is on the rail at all, by any route.
    ///
    /// A drag counts. It is the same question — is this rail the thing the user
    /// is currently pointed at — asked of a pointer that hover events cannot
    /// see.
    private var pointerIsOver: Bool { pointerInTrigger || pointerInPanel || dragHovering }

    /// One entry point for both hover targets, so the two can never disagree
    /// about what the pointer is doing.
    private func hoverChanged() {
        if pointerIsOver {
            collapseTask?.cancel()
            collapseTask = nil
            scheduleExpand()
        } else {
            expandTask?.cancel()
            expandTask = nil
            scheduleCollapse()
        }
    }

    /// Opening waits for the pointer to stay put.
    ///
    /// Expanding used to be instant while only collapsing was debounced, so
    /// there was no way to cross the left of the window without opening the
    /// rail. Short enough to still feel like hover, long enough that a sweep
    /// past it is not an instruction.
    private func scheduleExpand() {
        // `hoverExpansionEnabled` is `FleetView` suppressing hover after a
        // transition, and it is about a pointer wandering past. A drag is not
        // wandering, and refusing it would leave the file with nowhere to go.
        guard !expanded, !pinned, hoverExpansionEnabled || dragHovering else { return }

        expandTask?.cancel()
        expandTask = Task {
            try? await Task.sleep(for: Self.expandDwell)
            guard !Task.isCancelled, pointerIsOver else { return }
            setExpanded(true)
        }
    }

    private func scheduleCollapse() {
        guard !pinned, expanded, !settling else { return }

        collapseTask?.cancel()
        collapseTask = Task {
            try? await Task.sleep(for: Self.collapseDelay)
            guard !Task.isCancelled, !pointerIsOver else { return }
            setExpanded(false)
        }
    }

    /// Every change to the width goes through here, and every one of them opens
    /// the settling window on the way out.
    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        withAnimation(.smooth(duration: 0.3)) { expanded = value }

        settling = true
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: Self.settleWindow)
            guard !Task.isCancelled else { return }
            settling = false
            // A collapse that wanted to happen during the animation was
            // refused rather than queued, so ask again now that the geometry
            // has stopped moving.
            if !pointerIsOver { scheduleCollapse() }
        }
    }

    /// One entry point for every drop target in the rail, from the strip over
    /// the collapsed edge down to the deepest folder row.
    private func dragTargetChanged(_ targeted: Bool) {
        dragClearTask?.cancel()
        dragClearTask = nil

        if targeted {
            if !dragHovering {
                dragHovering = true
                // Carrying a file onto Daddy is a statement that you want
                // Daddy. Left alone, macOS keeps a background window behind
                // whatever you dragged from until its own raise-on-hover dwell
                // elapses, which is a long time to hold a file over a window
                // you cannot see.
                NSApp.activate()
            }
            hoverChanged()
            return
        }

        dragClearTask = Task {
            try? await Task.sleep(for: Self.dragClearDelay)
            guard !Task.isCancelled else { return }
            dragHovering = false
            hoverChanged()
        }
    }

    /// Held open after a drop lands.
    ///
    /// Collapsing the instant the file is released would be the fastest thing
    /// and the least useful: a drop into a spring-loaded folder three levels
    /// down is exactly the case where you want to see it arrive. Moving the
    /// pointer onto the rail during the hold picks it up as ordinary hover.
    private func holdOpenAfterDrop() {
        dragClearTask?.cancel()
        dragHovering = true

        dragClearTask = Task {
            try? await Task.sleep(for: Self.postDropHold)
            guard !Task.isCancelled else { return }
            dragHovering = false
            hoverChanged()
        }
    }

    private func cancelPending() {
        collapseTask?.cancel()
        collapseTask = nil
        expandTask?.cancel()
        expandTask = nil
    }

    private var focusDescription: String {
        guard let project = store.selectedProject else { return "all projects" }
        guard let agent = store.selectedAgent, agent.projectID == project.id else {
            return project.name
        }
        return "\(project.name) › \(agent.label)"
    }
}

// MARK: - Agent row

/// One live agent, as the rail shows it: the project it is working in, then
/// what it is doing and which CLI is doing it.
///
/// The project name leads rather than the provider, because "daddy" is what you
/// are looking for and "claude" is a detail about it — the same order the
/// reference tool uses, and the opposite of the breadcrumb in the toolbar.
private struct RailAgentRow: View {
    let agent: MockAgent
    let projectName: String
    let isFocused: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                ProviderLogo.badge(for: agent.agent, diameter: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(projectName)
                        .font(.system(size: 11.5, weight: isFocused ? .semibold : .regular))
                        .foregroundStyle(isFocused ? DaddyTheme.textPrimary : DaddyTheme.textSecondary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(StateColors.name(for: agent.state).lowercased())
                            .foregroundStyle(StateColors.accent(for: agent.state))

                        Text("·")
                            .foregroundStyle(DaddyTheme.textVeryDim)

                        Text(agent.agent.rawValue)
                            .foregroundStyle(DaddyTheme.textMuted)
                    }
                    .font(.system(size: 9.5, design: .monospaced))
                    .lineLimit(1)
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    isFocused ? DaddyTheme.insetFillSelected
                        : (hovering ? DaddyTheme.insetFill : Color.clear)
                )
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(DaddyTheme.insetStrokeSelected, lineWidth: 1)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
