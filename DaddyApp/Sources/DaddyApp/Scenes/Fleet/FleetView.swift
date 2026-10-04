import SwiftUI
import DaddyCore

/// The fleet: the rail on the left, agents in the middle, the agent's terminal
/// on the right — until you drill into one agent, at which point the terminal
/// takes the whole middle underneath one compact toolbar.
///
/// ## Focus is not a mode
///
/// It used to be: drilling into an agent hid the rail outright, so the project
/// tree and every other agent's state disappeared exactly when you started
/// working. Now the rail is permanent and focusing an agent only changes what
/// occupies the space to the right of it. `store.detailAgentID` still means
/// "which agent the middle column is showing" — it just no longer takes the
/// window hostage.
///
/// ## Why this is a ZStack over a GeometryReader rather than an HStack
///
/// The terminal has to *move* between two places. Expressed as two branches of
/// an `if`, SwiftUI would tear down one `TerminalPane` and build another — and
/// `TerminalSurface` wraps a SwiftTerm `NSView`. On rebuild it replays
/// `PTYProcess.recentOutput`, but that buffer is capped at 200 lines, so a long
/// session would silently lose its scrollback every time you opened or closed
/// the detail view.
///
/// So there is exactly one `TerminalPane` in the hierarchy, always, and what
/// changes is the rectangle it is given. Same view, same NSView, no teardown —
/// and because it is a frame change rather than a branch, it genuinely slides.
struct FleetView: View {
    @Environment(MockStore.self) private var store

    @State private var sidebarExpanded = false
    /// Held open deliberately — by the rail's own chevron or by ⌘B — as opposed
    /// to being held open by the pointer sitting on it.
    @State private var sidebarPinned = false
    @State private var progressPanelOpen = false
    @State private var progressPanelProjectID: String?
    @State private var keyboardMonitor: Any?
    @State private var sidebarHoverEnabled = true
    @State private var hoverRestoreTask: Task<Void, Never>?
    @State private var providerLaunchOpen = false
    /// The `+` picker on the tab strip. State, not a `Menu`, so ⌘T can open it.
    @State private var newTabPickerOpen = false
    /// `store.userShellCollapsed`, but lagged by the shell's own exit
    /// animation when it is going away. Reopening still shrinks the terminal
    /// instantly — the shell then slides into space already vacated, which
    /// reads fine. Collapsing used to expand the terminal instantly too, so
    /// it snapped to fill the shell's spot while the shell was still visible
    /// there sliding out, and the exit read as a jump-cut instead of a slide.
    /// Deferring the terminal's claim on that space until the shell has
    /// actually finished leaving makes the two directions match.
    @State private var shellCollapsedForLayout = false
    @State private var plusLaunchFrame: CGRect = .zero
    /// Frozen left-to-right agent ids for a Ctrl+Tab burst. Empty when idle.
    @State private var focusCycleIDs: [String] = []
    /// Index into `focusCycleIDs`, or `focusCycleIDs.count` when the plus is the stop.
    @State private var focusCycleIndex = 0
    @State private var focusCycleHasPlus = false
    @State private var focusCycleCommitTask: Task<Void, Never>?
    @State private var compassArmedKind: AgentKind?
    /// Live agents in header order: identity, then bubbles left-to-right.
    @State private var focusStripIDs: [String] = []

    private var focusHighlightID: String? {
        guard !focusCycleIDs.isEmpty else { return nil }
        if focusCycleIndex < focusCycleIDs.count {
            return focusCycleIDs[focusCycleIndex]
        }
        return FocusAgentSwitcher.plusID
    }

    private let gap: CGFloat = 16
    /// Shared with `WorkspaceRail`, which lays its content out at these widths
    /// whatever the animating frame currently proposes.
    private let sidebarWide = DaddyTheme.railWideWidth
    private let sidebarNarrow = DaddyTheme.railNarrowWidth
    private let terminalDockedWidth: CGFloat = 496
    private let detailToolbarHeight: CGFloat = 58

    /// The shell takes 30% and the agent keeps 70%, because the agent's
    /// transcript is what you are reading and the shell is what you are
    /// occasionally typing into. Floored so it stays usable on a narrow window
    /// and capped so it does not become the main event on a wide one.
    private let shellFraction: CGFloat = 0.30
    private let shellMinWidth: CGFloat = 280
    private let shellMaxWidth: CGFloat = 620

    private func shellWidth(for contentWidth: CGFloat) -> CGFloat {
        min(shellMaxWidth, max(shellMinWidth, contentWidth * shellFraction))
    }

    private var isDetail: Bool { store.detailAgent != nil }

    var body: some View {
        VStack(spacing: 8) {
            // The projects, and the one currently on screen. Below it, the
            // rail, agents and terminals all scope to that tab.
            ProjectTabStrip(openPicker: $newTabPickerOpen)

            GeometryReader { geo in
            let sidebarWidth = sidebarExpanded ? sidebarWide : sidebarNarrow

            // An open rail pushes focus mode aside — but by *translation*, not
            // by resizing it.
            //
            // The rail used to float over the terminal here, because pushing
            // meant the terminal resized every time the pointer brushed the
            // left edge, and a terminal resize is a TIOCSWINSZ, a SIGWINCH and
            // a full TUI reflow at the far end. It also meant the rail covered
            // the left of the transcript, which is where the text is.
            //
            // So focus lays out against the *narrow* rail and the whole column
            // slides right by the difference when the rail opens. The agent
            // pane keeps its width to the pixel — no reflow, ever — and the
            // room it moves into is made by parking your own shell offscreen
            // for as long as the rail is open.
            //
            // Collapsing the shell is the exception: there is no parked pane
            // to steal space from, so the session takes whatever is left.
            let usePushLayout = isDetail && !store.userShellCollapsed
            let layoutX = (usePushLayout ? sidebarNarrow : sidebarWidth) + gap
            let contentWidth = max(0, geo.size.width - layoutX)
            let railPush = usePushLayout && sidebarExpanded ? sidebarWide - sidebarNarrow : 0
            let contentX = layoutX + railPush
            let terminal = terminalFrame(in: geo.size, contentX: contentX, contentWidth: contentWidth)
            // Focus keeps its own shell only while the rail is out of the way
            // and the shell has not been collapsed for a full-width session.
            let shellVisible = isDetail && !sidebarExpanded && !store.userShellCollapsed
            // Always the focus-with-narrow-rail size, even while collapsed —
            // parking at a different width would TIOCSWINSZ a hidden shell.
            let parkedShellWidth = shellWidth(for: max(0, geo.size.width - sidebarNarrow - gap))

            ZStack(alignment: .topLeading) {
                middleColumn(
                    // Focus: the toolbar spans the content area it was laid out
                    // for, minus whatever the open rail pushed it by, so its
                    // right edge stays on the window rather than sliding off.
                    width: isDetail
                        ? max(0, contentWidth - railPush)
                        : max(0, contentWidth - terminalDockedWidth - gap),
                    // Always the full height — the container itself never
                    // resizes, only what it holds. Sizing this to
                    // `detailToolbarHeight` in detail mode used to animate the
                    // container's height alongside the dashboard's leading-edge
                    // transition, which read as a diagonal slide out of the top
                    // left instead of a straight slide from the left.
                    height: geo.size.height
                )
                // Same top edge as the rail and the docked OUTPUT column —
                // RootView already insets the fleet 18pt, and that inset is the
                // gap. The focus toolbar used to carry an extra 16pt here,
                // which is what left it sitting visibly below the top of the
                // rail beside it.
                .offset(x: contentX)

                // The one and only agent terminal. Only its rectangle changes.
                // Never animate this frame: interpolating width is a SIGWINCH
                // per tick, and Cursor replays the chat for each one.
                TerminalPane(isFocused: isDetail)
                    .frame(width: terminal.width, height: terminal.height)
                    .offset(x: terminal.minX, y: terminal.minY)
                    .transaction { $0.animation = nil }

                // Your own shell, to the right of the agent's.
                //
                // Mounted permanently and moved *offscreen* when there is no
                // agent focused, rather than being branched away or given a
                // zero width. Same rule as the agent pane — rebuilding it would
                // tear down SwiftTerm's NSView and truncate scrollback to the
                // 200 lines `recentOutput` retains — and a zero-width frame
                // would hand the child a 0-column TIOCSWINSZ, which is not a
                // terminal size any shell should be asked to lay out for.
                ShellPane(project: store.selectedProject)
                    .frame(width: parkedShellWidth, height: terminal.height)
                    // Offscreen on the fleet, and offscreen again while an open
                    // rail is borrowing its space. Its width never changes, so
                    // it comes back to the same shell it left.
                    .offset(
                        x: shellVisible ? terminal.maxX + gap : geo.size.width,
                        y: terminal.minY
                    )
                    // Keep the native terminal alive at a real size for
                    // scrollback, but do not let its border or renderer bleed
                    // past the Fleet's right edge while it is parked offscreen.
                    .opacity(shellVisible ? 1 : 0)
                    .allowsHitTesting(shellVisible)
                    .accessibilityHidden(!shellVisible)
                    .animation(.smooth(duration: 0.3), value: shellVisible)

                if isDetail, store.userShellCollapsed {
                    restoreShellHandle
                        .offset(x: terminal.maxX - 40, y: terminal.minY + 8)
                }

                // Last, so the rail owns its edge outright: nothing can draw
                // over it mid-animation, while the column it displaces slides
                // out from under it.
                WorkspaceRail(
                    expanded: $sidebarExpanded,
                    hoverExpansionEnabled: sidebarHoverEnabled,
                    pinned: $sidebarPinned
                )
                .frame(width: sidebarWidth, height: geo.size.height)
                // The rail's content is laid out at its final width, so growing
                // this frame reveals it. Without the clip it would spill out of
                // the collapsed strip for the length of the animation and take
                // its hover region with it.
                .clipped()

                if let project = launchProject {
                    RadialProviderMenuOverlay(
                        project: project,
                        plusFrame: plusLaunchFrame,
                        isOpen: providerLaunchOpen,
                        armedKind: compassArmedKind,
                        onDismiss: closeProviderLaunch
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(providerLaunchOpen)
                }
            }
            .coordinateSpace(name: FleetCoordinateSpace.name)
            .onPreferenceChange(PlusLaunchFrameKey.self) { plusLaunchFrame = $0 }
            .frame(height: geo.size.height)
            // No implicit animation on `sidebarExpanded`: the rail already wraps
            // every change to it in a `withAnimation`, and `expanded` is a
            // binding to this state, so one toggle used to run two nested
            // transactions on one property.
            .animation(.smooth(duration: 0.3), value: progressPanelOpen)
            .animation(.smooth(duration: 0.3), value: isDetail)
            }
        }
        .onAppear {
            installKeyboardMonitor()
            shellCollapsedForLayout = store.userShellCollapsed
        }
        .onDisappear { removeKeyboardMonitor() }
        .onChange(of: store.userShellCollapsed) { _, collapsed in
            guard collapsed else {
                // Reopening: shrink the terminal right away so the shell
                // slides into space that is already free.
                shellCollapsedForLayout = false
                return
            }
            // Collapsing: give the shell's own exit transition (0.3s, see
            // `shellVisible`'s `.animation` below) time to finish before the
            // terminal claims the space it is leaving.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard store.userShellCollapsed else { return }
                shellCollapsedForLayout = true
            }
        }
        .onChange(of: store.detailAgentID) { _, detailID in
            if let detailID {
                syncFocusStrip(current: detailID)
            } else {
                focusStripIDs = []
                providerLaunchOpen = false
                suppressSidebarHover()
            }
            // A click, launch, or commit restacked identity — drop the burst.
            clearFocusCycle()
        }
    }

    /// Docked on the right, or — with an agent focused — sharing the content
    /// area with your own shell: 70% agent, 30% shell.
    private func terminalFrame(
        in size: CGSize,
        contentX: CGFloat,
        contentWidth: CGFloat
    ) -> CGRect {
        if isDetail {
            // Below the toolbar. A collapsed shell donates its width to the
            // session — that reflow is the point of collapsing. The frame
            // itself is not animated, so it is one SIGWINCH, not a dozen.
            let top = detailToolbarHeight + gap
            let shellTaken = shellCollapsedForLayout
                ? 0 : shellWidth(for: contentWidth) + gap
            return CGRect(
                x: contentX,
                y: top,
                width: max(0, contentWidth - shellTaken),
                height: max(0, size.height - top)
            )
        }

        // Docked: pinned to the right edge, but never wider than the content
        // area — a narrow window with the rail pinned open must not put the
        // terminal underneath it.
        let width = min(terminalDockedWidth, contentWidth)
        return CGRect(
            x: size.width - width,
            y: 0,
            width: width,
            height: size.height
        )
    }

    @ViewBuilder
    private func middleColumn(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            if let agent = store.detailAgent {
                AgentDetailHeader(
                    agent: agent,
                    onOpenProgress: openProgress,
                    onBack: closeDetail,
                    launchMenuOpen: $providerLaunchOpen,
                    highlightID: focusHighlightID,
                    stripIDs: focusStripIDs
                )
                .frame(height: detailToolbarHeight)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                AgentDashboard(
                    progressOpen: $progressPanelOpen,
                    launchMenuOpen: $providerLaunchOpen,
                    onOpenProgress: openProgress
                )
                .transition(.move(edge: .leading).combined(with: .opacity))

                if progressPanelOpen {
                    Divider()
                    let panelProject = store.project(progressPanelProjectID ?? "") ?? store.selectedProject
                    FileTreeView(project: panelProject)
                        .frame(height: 280)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .clipped()
    }

    /// Reopens the parked shell from the session's right edge. The collapse
    /// control lives on the shell itself, so once it is gone this is the way
    /// back without digging through the overflow menu.
    private var restoreShellHandle: some View {
        Button {
            store.userShellCollapsed = false
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DaddyTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background { Circle().fill(Color.white.opacity(0.10)) }
                .overlay { Circle().strokeBorder(DaddyTheme.insetStroke, lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Show your shell")
    }

    /// Where the plus launches: the focused agent's project, same as the header.
    private var launchProject: MockProject? {
        guard let agent = store.detailAgent else { return nil }
        return store.project(agent.projectID) ?? store.selectedProject
    }

    private func closeProviderLaunch() {
        providerLaunchOpen = false
        compassArmedKind = nil
        if !focusCycleIDs.isEmpty {
            scheduleFocusCycleCommit()
        }
    }

    private func openProgress(_ projectID: String) {
        progressPanelProjectID = projectID
        if isDetail { closeDetail() }
        withAnimation(.smooth(duration: 0.3)) { progressPanelOpen = true }
    }

    private func closeDetail() {
        providerLaunchOpen = false
        clearFocusCycle()
        suppressSidebarHover()
        withAnimation(.smooth(duration: 0.3)) {
            store.closeDetail()
        }
    }

    /// Layout changes under a stationary pointer can synthesize hover
    /// transitions. Ignore that brief teardown window, then restore normal
    /// sidebar hover behavior.
    ///
    /// Called on the way out of the detail view *and* from `onChange`, because
    /// the store closes the detail view itself when the focused agent stops —
    /// that route never passes through `closeDetail`.
    private func suppressSidebarHover() {
        sidebarHoverEnabled = false
        hoverRestoreTask?.cancel()
        hoverRestoreTask = Task {
            // Stay suppressed through the 300ms detail-to-Fleet transition.
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            sidebarHoverEnabled = true
        }
    }

    /// Command-[ and Command-Left back out of whatever is open, innermost first.
    /// Ctrl+Tab walks the project strip; arrows pick a compass slot while it
    /// is open.
    ///
    /// Escape dismisses Daddy's own overlays and nothing else. It deliberately
    /// does *not* leave the focus view: inside the pty, Escape belongs to the
    /// agent CLI, where it cancels a running generation and steps back through
    /// inline menus (`/model` → model → thinking effort). Leaving on Escape
    /// meant backing out of one of those menus threw away the whole view.
    /// The replacement is a Command chord because macOS terminals never
    /// transmit Command to the pty, so no CLI can ever see it — no timers, no
    /// buffered first keystroke, no per-provider special-casing.
    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Fleet stays in the hierarchy under the board. Without this
            // guard, ⌘B / ⌘T / ⌘← would still fire while you are looking
            // at cards.
            guard store.workspace == .fleet else { return event }

            if handleFocusShortcut(event) { return nil }

            let chords = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // ⌘B, not ⌃B. Control-B is a real control character — readline's
            // backward-char and tmux's prefix — so binding it here would eat a
            // keystroke the agent in the terminal is entitled to. Command never
            // reaches a pty, which is the same reasoning behind ⌘← above.
            if chords == [.command], event.charactersIgnoringModifiers?.lowercased() == "b" {
                toggleSidebar()
                return nil
            }

            // ⌘T opens a project tab. Same reasoning as ⌘B: Command never
            // reaches a pty, so no CLI can ever see it. (It used to toggle
            // the shell in focus mode; that moved to the shell's own button
            // and the focus overflow menu.)
            if chords == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "t" {
                newTabPickerOpen.toggle()
                return nil
            }

            // ⌘W closes the project tab on screen. AppKit would otherwise
            // take this as "close the window", and the window is the app.
            if chords == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "w",
               let active = store.activeTabID {
                withAnimation(.smooth(duration: 0.2)) { store.closeTab(active) }
                return nil
            }

            // ⌘1…⌘9 jumps straight to a tab on the strip.
            if chords == [.command],
               let digit = event.charactersIgnoringModifiers?.first,
               let number = digit.wholeNumberValue,
               (1...9).contains(number),
               store.projectTabs.count >= number {
                withAnimation(.smooth(duration: 0.2)) {
                    store.activateTab(store.projectTabs[number - 1].id)
                }
                return nil
            }

            // Modified escapes (Option-Escape is Meta-Escape) stay the pty's.
            let isEscape = event.keyCode == 53 && chords.isEmpty
            let isCommandBack = chords == [.command]
                && (event.charactersIgnoringModifiers == "[" || event.keyCode == 123)
            let isCommandForward = chords == [.command] && event.keyCode == 124

            // ⌘→ is ⌘←'s mirror: into the selected session's focus view, from
            // the fleet only. Inside focus there is nothing further right to go.
            if isCommandForward, !providerLaunchOpen, store.detailAgent == nil {
                guard let id = store.selectedAgentID else { return event }
                withAnimation(.smooth(duration: 0.2)) { store.openDetail(id) }
                return nil
            }

            guard isEscape || isCommandBack else { return event }

            if providerLaunchOpen {
                closeProviderLaunch()
                return nil
            }
            if progressPanelOpen {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { progressPanelOpen = false }
                return nil
            }
            // Escape stops here — with no overlay of ours open it is the
            // agent's key, so it falls through to the terminal untouched.
            if isCommandBack, store.detailAgent != nil {
                closeDetail()
                return nil
            }
            return event
        }
    }

    /// Open the rail and hold it open, or close it and let it stay closed.
    ///
    /// Pinning is half the point. Toggling `expanded` alone would leave the rail
    /// at the mercy of the next hover — open it with the keyboard, move the
    /// pointer, and it shuts again as though the keypress had not happened.
    private func toggleSidebar() {
        let opening = !sidebarExpanded
        sidebarPinned = opening
        withAnimation(.smooth(duration: 0.3)) { sidebarExpanded = opening }
    }

    private func handleFocusShortcut(_ event: NSEvent) -> Bool {
        let chords = event.modifierFlags.intersection([.command, .option, .control, .shift])

        let isCommandEnter = chords == [.command] && (event.keyCode == 36 || event.keyCode == 76)
        if isCommandEnter, store.detailAgent == nil, store.selectedProject != nil {
            providerLaunchOpen = true
            return true
        }

        if chords.contains(.control),
           !chords.contains(.command),
           !chords.contains(.option),
           !chords.contains(.shift),
           event.charactersIgnoringModifiers?.lowercased() == "q" {
            if store.detailAgent != nil {
                dismissFocusedSession()
                return true
            }
            // In the fleet the same chord closes the *selected card* and only
            // that one — the other sessions are someone else's work and are not
            // implicated by dismissing this one.
            if let id = store.selectedAgentID {
                dismissSession(id)
                return true
            }
            // Nothing selected: not ours to take. Ctrl-Q is a real control
            // character, so it goes to whatever has the keyboard.
            return false
        }

        if providerLaunchOpen,
           store.detailAgent != nil,
           chords.isEmpty,
           let kind = RadialProviderMenuOverlay.kind(for: event) {
            compassArmedKind = kind
            launchCompassKind(kind)
            return true
        }

        // Ctrl+Tab walks the project strip, terminal-app style; Ctrl+Shift+Tab
        // walks it backwards. With only one tab open there is nothing to walk,
        // so the chord keeps its old meaning: focus sessions and provider tiles
        // within this project.
        if event.keyCode == 48,
           chords.contains(.control),
           !chords.contains(.command),
           !chords.contains(.option),
           store.projectTabs.count > 1 {
            withAnimation(.smooth(duration: 0.2)) {
                store.cycleTab(forward: !chords.contains(.shift))
            }
            return true
        }

        let isControlTab = event.keyCode == 48
            && chords.contains(.control)
            && !chords.contains(.command)
            && !chords.contains(.option)
            && !chords.contains(.shift)
        guard isControlTab else { return false }

        // In the fleet the same chord walks the provider tiles rather than the
        // focus strip.
        if store.detailAgent == nil {
            advanceFleetProvider()
            return true
        }

        if providerLaunchOpen {
            providerLaunchOpen = false
            compassArmedKind = nil
            advanceFocusCycle(fromPlus: true)
            return true
        }

        advanceFocusCycle()
        return true
    }

    private func launchCompassKind(_ kind: AgentKind) {
        guard let project = launchProject else { return }
        guard store.isInstalled(kind) else { return }
        clearFocusCycle()
        providerLaunchOpen = false
        compassArmedKind = nil
        AppActionDispatcher(store: store).perform(.launchSession(kind: kind, projectID: project.id))
    }

    private func beginFocusCycleIfNeeded() {
        guard focusCycleIDs.isEmpty, let current = store.detailAgent else { return }
        syncFocusStrip(current: current.id)
        focusCycleIDs = focusStripIDs
        focusCycleIndex = 0
        focusCycleHasPlus = launchProject != nil
    }

    private func advanceFocusCycle(fromPlus: Bool = false) {
        beginFocusCycleIfNeeded()
        guard !focusCycleIDs.isEmpty else { return }

        if fromPlus, focusCycleHasPlus {
            focusCycleIndex = focusCycleIDs.count
        }

        let plusIndex = focusCycleHasPlus ? focusCycleIDs.count : nil
        let lastIndex = plusIndex ?? (focusCycleIDs.count - 1)
        guard lastIndex >= 0 else { return }

        var next = focusCycleIndex + 1
        if next > lastIndex {
            next = 0
        }
        focusCycleIndex = next

        if let plusIndex, next == plusIndex {
            focusCycleCommitTask?.cancel()
            compassArmedKind = nil
            providerLaunchOpen = true
            return
        }

        store.previewDetail(focusCycleIDs[next])
        scheduleFocusCycleCommit()
    }

    /// Keep identity as strip[0]; bubbles stay in this sequence, not recency.
    private func syncFocusStrip(current: String) {
        let live = store.visibleAgents.filter(\.isLive)
        let liveIDs = Set(live.map(\.id))
        focusStripIDs.removeAll { !liveIDs.contains($0) }

        let newcomers = live
            .filter { !focusStripIDs.contains($0.id) }
            .sorted { $0.lastOutputAt > $1.lastOutputAt }
            .map(\.id)
        focusStripIDs.append(contentsOf: newcomers)

        if focusStripIDs.isEmpty {
            let others = live
                .filter { $0.id != current }
                .sorted { $0.lastOutputAt > $1.lastOutputAt }
            focusStripIDs = [current] + others.map(\.id)
        }

        rotateFocusStrip(to: current)
    }

    private func rotateFocusStrip(to id: String) {
        guard let i = focusStripIDs.firstIndex(of: id) else { return }
        focusStripIDs = Array(focusStripIDs[i...]) + Array(focusStripIDs[..<i])
    }

    private func successorStripID(after id: String) -> String? {
        let remaining = focusStripIDs.filter { $0 != id }
        guard !remaining.isEmpty else { return nil }
        if let i = focusStripIDs.firstIndex(of: id) {
            let right = focusStripIDs[(i + 1)...].first { $0 != id && remaining.contains($0) }
            return right ?? remaining[0]
        }
        return remaining[0]
    }

    /// Ctrl-Tab in the fleet: the next provider tile that has anything in it.
    ///
    /// Walks the same order the tiles are laid out in
    /// (`AgentDashboard`: claude, codex, cursor, opencode) and skips providers
    /// with no sessions, so the chord matches what is actually on screen rather
    /// than stopping on gaps.
    private func advanceFleetProvider() {
        let order: [AgentKind] = [.claude, .codex, .cursor, .opencode]
        let grouped = Dictionary(grouping: store.visibleAgents) { $0.agent }
        let present = order.filter { !(grouped[$0] ?? []).isEmpty }
        guard !present.isEmpty else { return }

        let next: AgentKind
        if let current = store.selectedAgent?.agent,
           let index = present.firstIndex(of: current) {
            next = present[(index + 1) % present.count]
        } else {
            next = present[0]
        }

        guard let target = mostRecentlyUsed(in: grouped[next] ?? []) else { return }
        withAnimation(.smooth(duration: 0.18)) {
            store.select(agent: target.id)
        }
    }

    /// A provider with several sessions lands on the one you were last dealing
    /// with, not the oldest or an arbitrary one.
    ///
    /// `lastOutputAt` is when the agent last printed, which is the closest thing
    /// to "last used" that is actually recorded — it moves whenever you send a
    /// prompt, because the reply follows. `startedAt` covers a session that has
    /// not spoken yet, so a freshly launched card is not sorted to the back.
    private func mostRecentlyUsed(in agents: [MockAgent]) -> MockAgent? {
        agents.max { lhs, rhs in
            max(lhs.lastOutputAt, lhs.startedAt) < max(rhs.lastOutputAt, rhs.startedAt)
        }
    }

    private func dismissFocusedSession() {
        let id: String?
        if !focusCycleIDs.isEmpty, focusCycleIndex < focusCycleIDs.count {
            id = focusCycleIDs[focusCycleIndex]
        } else {
            id = store.selectedAgentID ?? store.detailAgentID
        }
        guard let id else { return }
        dismissSession(id)
    }

    /// Stop one session and take its card off the screen.
    ///
    /// `store.stop` terminates the pty and discards the card; `store.dismiss`
    /// is the same minus the terminate, for a session that already exited.
    /// Both move the selection on themselves, so nothing here has to guess
    /// where to land in the fleet.
    private func dismissSession(_ id: String) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return }

        let successor = successorStripID(after: id)
        providerLaunchOpen = false
        compassArmedKind = nil
        clearFocusCycle()
        focusStripIDs.removeAll { $0 == id }

        if agent.isLive {
            store.stop(id)
        } else {
            store.dismiss(id)
        }

        // Only the focus view needs somewhere to go next; the fleet still has
        // every other card on screen.
        if let successor, store.detailAgentID != nil {
            withAnimation(.smooth(duration: 0.36)) {
                store.openDetail(successor)
            }
        }
    }

    private func scheduleFocusCycleCommit() {
        focusCycleCommitTask?.cancel()
        focusCycleCommitTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            commitFocusCycle()
        }
    }

    private func commitFocusCycle() {
        guard !focusCycleIDs.isEmpty else { return }
        let id: String
        if focusCycleIndex < focusCycleIDs.count {
            id = focusCycleIDs[focusCycleIndex]
        } else {
            id = store.selectedAgentID ?? focusCycleIDs[0]
        }
        focusCycleCommitTask?.cancel()
        focusCycleCommitTask = nil
        withAnimation(.smooth(duration: 0.36)) {
            store.openDetail(id)
            focusCycleIDs = []
            focusCycleIndex = 0
            focusCycleHasPlus = false
        }
    }

    private func clearFocusCycle() {
        focusCycleCommitTask?.cancel()
        focusCycleCommitTask = nil
        focusCycleIDs = []
        focusCycleIndex = 0
        focusCycleHasPlus = false
    }

    private func removeKeyboardMonitor() {
        hoverRestoreTask?.cancel()
        hoverRestoreTask = nil
        clearFocusCycle()
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }
}
