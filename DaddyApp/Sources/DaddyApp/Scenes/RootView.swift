import SwiftUI
import AppKit

struct RootView: View {
    @Environment(MockStore.self) private var store
    @State private var utilityPanel: UtilityPanel?
    @State private var keyboardMonitor: Any?

    var body: some View {
        ZStack {
            // A ground colour under everything, so nothing shows through in the
            // frame between the aurora leaving and the terminal arriving.
            DaddyTheme.focusSurface
                .ignoresSafeArea()

            // Rendered again in focus mode, and that reverses a decision from
            // batch 009 on purpose.
            //
            // Suppressing it there was justified by one fact: the focused
            // terminal covered the window completely, so the aurora was
            // animating where nobody could see it. The permanent rail ends
            // that — it is glass, it is always on screen, and glass with a flat
            // colour behind it is just a grey box. The backdrop is the design.
            //
            // The performance work that actually mattered survives untouched:
            // the terminal no longer forces a full-window repaint per chunk,
            // and it is opaque, so its repaints do not drag the aurora and the
            // glass through a recomposite.
            if store.workspace == .fleet {
                AuroraBackground()
            }

            VStack(spacing: 0) {
                ZStack(alignment: .trailing) {
                    // Inset in both modes now. Focus used to run the terminal
                    // to the window edges because it *was* the window; with the
                    // rail permanently beside it, the rail would sit flush
                    // against the frame while every other panel floats.
                    ZStack {
                        // Always mounted, always at a real size, always hit-testable
                        // *while Fleet is the workspace*. When the board or
                        // orchestrator covers it, clicks must not fall through
                        // translucent glass onto the fleet header underneath.
                        FleetView()
                            .allowsHitTesting(store.workspace == .fleet)

                        if store.workspace == .board {
                            workspaceCover(showsAurora: false) { BoardView() }
                                .allowsHitTesting(store.workspace == .board)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                                .zIndex(1)
                        } else if store.workspace == .orchestrator {
                            workspaceCover(showsAurora: true) { OrchestratorView() }
                                .allowsHitTesting(store.workspace == .orchestrator)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                                .zIndex(1)
                        }
                    }
                        .animation(.smooth(duration: 0.3), value: store.workspace)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)

                    // Focus is not a mode: the drawer opens over the terminal
                    // the same way it opens over the grid. It used to be
                    // suppressed here, which meant the settings button in focus
                    // set the state and rendered nothing at all.
                    if let utilityPanel {
                        Color.black.opacity(0.22)
                            .contentShape(Rectangle())
                            .onTapGesture { closeUtilityPanel() }
                            .transition(.opacity)

                        UtilityDrawer(
                            panel: utilityPanel,
                            onClose: closeUtilityPanel,
                            onSwitchPanel: switchUtilityPanel
                        )
                        .frame(width: 420)
                        .frame(maxHeight: .infinity)
                        .padding(.trailing, 18)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            // Over every workspace, because a session filling up is not a
            // Fleet event — it happens while you are on the board, and it is
            // the one thing worth interrupting whatever you are looking at.
            if let pending = store.pendingContextHandoff {
                HandoffApprovalOverlay(pending: pending)
                    .zIndex(2)
            }

            // Voice capture feedback — bottom-center floating pill with a
            // decorative waveform. Reads through the (unobserved)
            // controller reference, which still tracks `state` itself.
            if store.voiceCaptureController.state != .idle {
                VoiceCapturePill(state: store.voiceCaptureController.state)
                    .padding(.bottom, 26)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .zIndex(3)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92)))
            }

            // Bottom-aligned, clear of the voice capture pill above it.
            //
            // Slides in and back out along the bottom edge it lives on, rather
            // than dropping from the top — it stays put while visible and
            // leaves the way it arrived when dismissed or timed out.
            if let toast = store.voiceToast {
                VoiceActionToast(toast: toast)
                    .padding(.bottom, 26)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .zIndex(4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // In the titlebar, not over the content.
            //
            // As a `.topTrailing` overlay it landed on the top-right corner of
            // whatever panel was below it — in focus that is the toolbar, so it
            // sat on the kill button. The window's top strip is the only place
            // in the app that belongs to no panel, and reaching it means
            // `TitlebarAccessory`; content drawn under a transparent titlebar
            // does not receive clicks.
            TitlebarAccessory(size: CGSize(width: 146, height: 28)) {
                HStack(spacing: 6) {
                    boardButton
                    orchestratorButton
                    settingsButton
                }
                // Titlebar accessories sit above the content view in AppKit —
                // glass under them still loses the click. Disable the controls
                // whenever a board/utility modal owns the screen.
                .disabled(titlebarBlocked)
                .opacity(titlebarBlocked ? 0.35 : 1)
            }
            .frame(width: 0, height: 0)
        }
        .animation(.smooth(duration: 0.22), value: store.voiceToast?.id)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: store.voiceCaptureController.state)
        .preferredColorScheme(.dark)
        .onAppear {
            installKeyboardMonitor()
            // Global monitors must register after first render: doing it in
            // MockStore.init (pre-activation) wedges all app input.
            store.voiceCaptureController.start()
        }
        .onDisappear { removeKeyboardMonitor() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                store.tick()
            }
        }
    }

    /// Work-item / bundle / dispatch panes and the utility drawer all sit
    /// under the titlebar strip visually; without this the strip keeps
    /// stealing hover and clicks through the glass.
    private var titlebarBlocked: Bool {
        utilityPanel != nil
            || store.selectedOrchestratorWorkItemID != nil
            || store.boardModalBlocksChrome
    }

    private var settingsButton: some View {
        Button {
            toggleUtilityPanel(.settings)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DaddyTheme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(utilityPanel == .settings ? 1 : 0.6)
        .padding(.trailing, 12)
        .help("Settings")
    }

    private var boardButton: some View {
        Button(action: toggleBoard) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    store.workspace == .board
                        ? DaddyTheme.accent : DaddyTheme.textSecondary
                )
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(store.workspace == .board ? 1 : 0.6)
        .help("Board")
    }

    private var orchestratorButton: some View {
        Button {
            store.workspace = store.workspace == .orchestrator ? .fleet : .orchestrator
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    store.workspace == .orchestrator
                        ? DaddyTheme.accent : DaddyTheme.textSecondary
                )
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(store.workspace == .orchestrator ? 1 : 0.6)
        .help("Orchestrator")
        .keyboardShortcut("o", modifiers: .control)
    }

    private func toggleBoard() {
        store.workspace = store.workspace == .board ? .fleet : .board
    }

    /// Opaque cover so the live terminals stay laid out underneath at a real
    /// size. Instant, no transition — a fading `if` left an invisible view
    /// eating clicks after you came back.
    private func workspaceCover<Content: View>(
        showsAurora: Bool,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        ZStack {
            DaddyTheme.focusSurface
            if showsAurora {
                AuroraBackground()
            }
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// ⌘K has to live here, not on the titlebar button and not in `FleetView`.
    ///
    /// `.keyboardShortcut` on a control inside `TitlebarAccessory` is a
    /// SwiftUI view that is not in the window's key-view loop, so the chord
    /// never fires once the terminal has first responder — the same reason
    /// ⌘B is an `NSEvent` monitor. `FleetView`'s monitor dies with the fleet
    /// when the board opens, so close would have no listener. Root owns both.
    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc cancels a live voice capture first. The global Esc monitor
            // only delivers with Input Monitoring approval; this one always
            // works while the app is frontmost.
            if event.keyCode == 53, store.voiceCaptureController.state != .idle {
                store.voiceCaptureController.cancelRecording()
                return nil
            }
            let chords = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard chords == [.command],
                  event.charactersIgnoringModifiers?.lowercased() == "k" else {
                return event
            }
            toggleBoard()
            return nil
        }
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }

    private func toggleUtilityPanel(_ panel: UtilityPanel) {
        withAnimation(.smooth(duration: 0.24)) {
            utilityPanel = utilityPanel == panel ? nil : panel
        }
    }

    private func switchUtilityPanel(_ panel: UtilityPanel) {
        withAnimation(.smooth(duration: 0.24)) {
            utilityPanel = panel
        }
    }

    private func closeUtilityPanel() {
        withAnimation(.smooth(duration: 0.22)) { utilityPanel = nil }
    }
}
