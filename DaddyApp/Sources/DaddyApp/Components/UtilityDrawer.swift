import SwiftUI
import DaddyCore

enum UtilityPanel: Equatable {
    case hex
    case settings
}

/// Contextual utilities that sit over Fleet without changing its geometry.
struct UtilityDrawer: View {
    @Environment(MockStore.self) private var store

    let panel: UtilityPanel
    let onClose: () -> Void
    let onSwitchPanel: (UtilityPanel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                // The transcripts panel is *inside* settings, reached by a row
                // with a chevron on it, so it needs the way back out. The icon
                // slot is where a back button belongs.
                if panel == .hex {
                    Button { onSwitchPanel(.settings) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(DaddyTheme.textSecondary)
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .insetSurface(cornerRadius: 13)
                    .help("Back to settings")
                } else {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DaddyTheme.textSecondary)
                }

                Text(panel == .hex ? "TRANSCRIPTS" : "SETTINGS")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(DaddyTheme.textPrimary)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DaddyTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .insetSurface(cornerRadius: 14)
                .help("Close")
            }
            .padding(16)

            GlassHairline()

            switch panel {
            case .hex:
                HEXUtilityPanel()
            case .settings:
                SettingsUtilityPanel(onOpenHEX: { onSwitchPanel(.hex) })
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(DaddyTheme.popoverBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(DaddyTheme.insetStroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 28, x: -8, y: 12)
        .onExitCommand(perform: onClose)
    }
}

private struct HEXUtilityPanel: View {
    @Environment(MockStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SESSION HISTORY")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(DaddyTheme.textMuted)
                Spacer()
                Text("\(store.voiceLog.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(DaddyTheme.textMuted)
            }

            if store.voiceLog.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 18))
                        .foregroundStyle(DaddyTheme.textVeryDim)
                    Text("No HEX transcripts this session.")
                        .font(.system(size: 11))
                        .foregroundStyle(DaddyTheme.textMuted)

                    Text("Transcripts appear here when HEX dictates into Daddy.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(DaddyTheme.textVeryDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.voiceLog) { entry in
                            HEXHistoryRow(entry: entry)
                        }
                    }
                }
            }
        }
        .padding(14)
    }
}

private struct HEXHistoryRow: View {
    let entry: VoiceEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.didSucceed ? "waveform" : "questionmark.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(entry.didSucceed ? DaddyTheme.working : DaddyTheme.limited)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("“\(entry.transcript)”")
                    .font(.system(size: 11))
                    .foregroundStyle(DaddyTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(entry.resolution)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(entry.didSucceed ? DaddyTheme.textMuted : DaddyTheme.limited)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Text(formatTimeAgo(entry.at))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DaddyTheme.textMuted)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetSurface(cornerRadius: 12)
    }
}

private struct SettingsUtilityPanel: View {
    @Environment(MockStore.self) private var store

    let onOpenHEX: () -> Void

    /// Every shortcut that does something Daddy owns, in one place. The app
    /// binds Command chords and Control chords; everything else — Escape
    /// included — belongs to the agent in the terminal, which is worth saying
    /// out loud, because Escape used to leave the focus view.
    private static let shortcuts: [(String, String)] = [
        ("⌘←", "Shrink full terminal chat view"),
        ("⌘→", "Open full terminal chat view"),
        ("⌘↩", "Open the launch menu in Fleet"),
        ("⌃Q", "Quit and end chat session"),
        ("⌃⇥", "Switch between active chat sessions"),
        ("⌘B", "Toggle sidebar directory menu"),
        ("⌃O", "Open or close the Orchestrator"),
        ("⌘K", "Open or close the Board"),
        ("⎋", "Goes to the agent, not to Daddy"),
    ]

    @State private var glossaryOpen = false
    @State private var isConnectingDrive = false
    @State private var driveConnectError: String?

    var body: some View {
        @Bindable var store = store

        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("TERMINAL") {
                    setting(
                        "Font size",
                        "Both terminals. Resizes the grid the agent draws into."
                    ) {
                        fontSizeStepper(store: store)
                    }
                }

                section("AGENTS") {
                    setting(
                        "Work mode",
                        "\(store.workMode.summary) New sessions only — switch a running one from its card menu."
                    ) {
                        // Short names, not display names: four segments of
                        // "plan & build" and "explore" in a drawer this wide
                        // truncate to ellipses.
                        Picker("", selection: $store.workMode) {
                            ForEach(WorkMode.allCases, id: \.self) { mode in
                                Text(mode.shortName.lowercased()).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    setting(
                        "Build policy",
                        "\(store.buildPolicy.summary) New sessions only — switch a running one from its card menu."
                    ) {
                        Picker("", selection: $store.buildPolicy) {
                            ForEach(BuildPolicy.allCases, id: \.self) { policy in
                                Text(policy.shortName.lowercased()).tag(policy)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    setting(
                        "Approval policy",
                        store.approvalPolicy == .safeAuto
                            ? "Pause before writes outside the work unit."
                            : "Run without approval pauses."
                    ) {
                        Picker("", selection: $store.approvalPolicy) {
                            Text("safe-auto").tag(ApprovalPolicy.safeAuto)
                            Text("full-bypass").tag(ApprovalPolicy.fullBypass)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    toggleSetting(
                        "Notify when ready",
                        "Only while Daddy is in the background.",
                        binding: $store.notifyOnReady
                    )

                    setting(
                        "Orchestrator model",
                        "Local Ollama model tag used by the Orchestrator workspace."
                    ) {
                        TextField("gemma4:e4b", text: $store.orchestratorModel)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                section("VOICE") {
                    setting(
                        "Speaking",
                        store.speechController.mode == .off
                            ? "Daddy stays silent unless you press Test."
                            : "Daddy speaks the events switched on below."
                    ) {
                        Picker("", selection: Binding(
                            get: { store.speechController.mode },
                            set: { store.speechController.mode = $0 }
                        )) {
                            ForEach(SpeechMode.allCases, id: \.self) { mode in
                                Text(mode.label.lowercased()).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    toggleSetting(
                        "Say when an agent needs you",
                        "Spoken the moment a session goes idle.",
                        binding: speechEvent(.agentIdle)
                    )

                    toggleSetting(
                        "Say confirmations",
                        "Reads out what a voice command just did.",
                        binding: speechEvent(.actionConfirmed)
                    )

                    toggleSetting(
                        "Say failures",
                        "Reads out why a voice command did nothing.",
                        binding: speechEvent(.actionFailed)
                    )

                    Button("Test voice") {
                        store.speechController.speak("Daddy here. The voice is working.")
                    }
                    .controlSize(.small)
                }

                section("SHORTCUTS") {
                    VStack(alignment: .leading, spacing: 10) {
                        // Folded away by default. The list is reference
                        // material — you read it once and then you know it —
                        // and left open it pushed the settings people actually
                        // change down past the fold.
                        Button {
                            withAnimation(.smooth(duration: 0.22)) { glossaryOpen.toggle() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "keyboard")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(DaddyTheme.accent)
                                Text("Shortcut glossary")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(DaddyTheme.textPrimary)
                                Spacer()
                                Image(systemName: glossaryOpen ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(DaddyTheme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .insetSurface(cornerRadius: 12)
                        }
                        .buttonStyle(.plain)

                        if glossaryOpen {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Self.shortcuts, id: \.0) { chord, meaning in
                                    HStack(spacing: 11) {
                                        Text(chord)
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(DaddyTheme.textPrimary)
                                            .frame(width: 34, height: 22)
                                            .insetSurface(cornerRadius: 7)

                                        Text(meaning)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(DaddyTheme.textSecondary)

                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                            .padding(.horizontal, 2)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }

                section("STATE") {
                    HStack(spacing: 10) {
                        stateTile("\(store.projects.count)", "projects")
                        stateTile("\(store.liveAgentCount)", "live")
                        stateTile("session", "storage")
                    }
                }

                section("STORAGE") {
                    if store.syncCoordinator.isConnected {
                        setting("Google Drive", driveStatusLine) {
                            Button("Disconnect") {
                                store.syncCoordinator.disconnect()
                            }
                        }
                    } else {
                        setting(
                            "Google Drive",
                            driveConnectError ?? "Kanban cards sync to Drive and back up locally."
                        ) {
                            Button(isConnectingDrive ? "Connecting…" : "Connect Google Drive") {
                                connectDrive()
                            }
                            .disabled(isConnectingDrive)
                        }
                    }
                }

                section("UTILITIES") {
                    Button(action: onOpenHEX) {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DaddyTheme.accent)
                            Text("Transcript history")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(DaddyTheme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DaddyTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .insetSurface(cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    /// Numbers first, labels under them — three tiles read at a glance where
    /// three `label value` rows had to be read one at a time.
    private func stateTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(DaddyTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(DaddyTheme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .insetSurface(cornerRadius: 12)
    }

    private func fontSizeStepper(store: MockStore) -> some View {
        HStack(spacing: 0) {
            stepperButton("minus") { store.nudgeTerminalFont(by: -1) }

            Text(store.terminalFontSize.formatted(.number.precision(.fractionLength(0...1))))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(DaddyTheme.textPrimary)
                .frame(width: 46)

            stepperButton("plus") { store.nudgeTerminalFont(by: 1) }
        }
        .insetSurface(cornerRadius: 11)
    }

    private var driveStatusLine: String {
        let count = store.syncCoordinator.pendingSyncCount
        let email = Defaults.string(.driveAccountEmail) ?? "unknown account"
        guard count > 0 else { return "Connected as \(email)" }
        return "Connected as \(email) — \(count) item\(count == 1 ? "" : "s") waiting to sync"
    }

    private func connectDrive() {
        isConnectingDrive = true
        driveConnectError = nil
        Task {
            do {
                _ = try await store.syncCoordinator.connect()
                store.reloadWorkItems()
            } catch {
                driveConnectError = error.localizedDescription
            }
            isConnectingDrive = false
        }
    }

    private func stepperButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DaddyTheme.textSecondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(DaddyTheme.textMuted)

            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(14)
            .insetSurface(cornerRadius: 15)
        }
    }

    private func setting<Control: View>(
        _ title: String,
        _ detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(DaddyTheme.textPrimary)
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(DaddyTheme.textMuted)
            control()
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The per-event switches live in a `Set` on the controller rather than as
    /// three stored properties, so each one needs a binding built by hand.
    private func speechEvent(_ event: SpeechEvent) -> Binding<Bool> {
        Binding(
            get: { store.speechController.isEnabled(event) },
            set: { store.speechController.setEnabled($0, for: event) }
        )
    }

    private func toggleSetting(
        _ title: String,
        _ detail: String,
        binding: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DaddyTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(DaddyTheme.textMuted)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}
