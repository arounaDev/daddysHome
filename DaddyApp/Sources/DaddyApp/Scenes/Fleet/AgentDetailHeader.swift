import SwiftUI
import DaddyCore

/// The focus-mode toolbar. Identity and navigation stay visible; everything
/// secondary moves into the overflow so the terminal owns the screen.
struct AgentDetailHeader: View {
    @Environment(MockStore.self) private var store
    @State private var backHovering = false
    @State private var killHovering = false
    @State private var modeHovering = false
    @State private var buildHovering = false

    let agent: MockAgent
    let onOpenProgress: (String) -> Void
    let onBack: () -> Void
    @Binding var launchMenuOpen: Bool
    /// Ctrl+Tab preview. Nil when idle. `FocusAgentSwitcher.plusID` means the plus.
    var highlightID: String? = nil
    var stripIDs: [String] = []

    @Namespace private var deckNamespace

    var body: some View {
        HStack(spacing: 10) {
            // Glyph only. The label spelled out what a back chevron already
            // says, and the identity that follows it is the logo — the project
            // and agent names were repeating what the sidebar and the bubble
            // both show.
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DaddyTheme.textPrimary)
                    .frame(width: 34, height: 34)
                    .background {
                        Circle()
                            .fill(Color.white.opacity(backHovering ? 0.16 : 0.10))
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(backHovering ? 0.24 : 0.16))
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { backHovering = $0 }
            .animation(.easeOut(duration: 0.14), value: backHovering)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to Fleet (⌘[ or ⌘←)")

            CompactAgentIcon(
                agent: agent,
                isSelected: false,
                size: 32,
                siblingIndex: MockAgent.siblingIndex(for: agent, among: liveAgents),
                onTap: {}
            )
            .scaleEffect(highlightID == agent.id ? 1.14 : 1)
            .offset(y: highlightID == agent.id ? -3 : 0)
            .zIndex(highlightID == agent.id ? 20 : 0)
            .matchedGeometryEffect(id: agent.id, in: deckNamespace, properties: .position)
            .animation(.smooth(duration: 0.18), value: highlightID)

            // The others sit *beside* the one you are in, not across the
            // toolbar from it — they are the same kind of thing, and reading
            // "who is running" should not mean crossing the whole window.
            //
            // What keeps them from merging into one undifferentiated row is the
            // seam: identity on the left of it, everything you could switch to
            // on the right. A gap alone would not have done it, because the
            // deck already overlaps its own bubbles by nine points.
            // The seam stays conditional — with nothing to switch to, the deck
            // is only the plus, and a rule with one circle on the far side of it
            // is a scratch on the toolbar.
            if hasAlternatives {
                GlassHairline(axis: .vertical, length: 28)
                    .padding(.horizontal, 3)
            }

            // Live agents only. Switching to a dead one lands you on
            // "Session ended" — a full-window dead end — so a stopped agent
            // has no business being one of the bubbles you can jump to. It
            // is still reachable from the Fleet, which is where you go to
            // resume or clear it.
            //
            // The deck ends in a plus. Starting another agent belongs with the
            // agents you already have, not across the toolbar among the actions
            // that end this one.
            FocusAgentSwitcher(
                agents: liveAgents,
                activeID: agent.id,
                launchTarget: launchTarget,
                launchMenuOpen: $launchMenuOpen,
                highlightID: highlightID,
                stripIDs: stripIDs,
                deckNamespace: deckNamespace,
                onSelect: { id in
                    withAnimation(.smooth(duration: 0.36)) {
                        store.openDetail(id)
                    }
                }
            )

            Spacer(minLength: 10)

            // No wrapper: it sits in the header like everything else. Fixed
            // width throughout, so it can never shove its neighbours around.
            ProviderUsageBattery(snapshot: store.providerUsage[agent.agent])

            modeIconButton

            policyIconButton

            // The state as a fixed dot, not a word: READY vs WORKING had
            // different widths and shoved the whole right edge around. The
            // name and uptime live in the tooltip.
            StatusBadge(state: agent.state, compact: true)
                .frame(width: 30)
                .help("\(StateColors.name(for: agent.state)) · up \(agent.uptime)")

            GlassDropdown(items: menuItems, width: 250) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DaddyTheme.textSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .help("Session details and actions")

            // Ending a session was two levels deep in the overflow menu, which
            // is the wrong depth for the thing you reach for most. `stop` also
            // clears the card, so this is the whole gesture in one button.
            Button {
                if agent.isLive {
                    store.stop(agent.id)
                } else {
                    store.dismiss(agent.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DaddyTheme.failure)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle()
                            .fill(DaddyTheme.failure.opacity(killHovering ? 0.24 : 0.13))
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(DaddyTheme.failure.opacity(killHovering ? 0.6 : 0.35))
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { killHovering = $0 }
            .animation(.easeOut(duration: 0.14), value: killHovering)
            .help(agent.isLive ? "Stop and dismiss this agent" : "Dismiss this agent")
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58)
        .animation(.smooth(duration: 0.36), value: agent.id)
        // A card, not a bar. The hairline that used to run along the bottom was
        // there to separate this from the terminal it sat directly on top of;
        // there is a gap between them now, and a border does that job better
        // than a rule on one edge.
        .background(
            RoundedRectangle(cornerRadius: DaddyTheme.focusedPaneRadius, style: .continuous)
                .fill(DaddyTheme.focusSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DaddyTheme.focusedPaneRadius, style: .continuous)
                .strokeBorder(DaddyTheme.insetStroke, lineWidth: 1)
        }
    }

    private var liveAgents: [MockAgent] {
        store.visibleAgents.filter(\.isLive)
    }

    /// Whether there is anything to switch *to*. The switcher draws nothing
    /// without alternatives, and a seam with nothing on the far side of it is
    /// just a scratch on the toolbar.
    private var hasAlternatives: Bool {
        liveAgents.contains { $0.id != agent.id }
    }

    /// Where the deck's plus launches: the project of the agent you are looking
    /// at, not whatever the sidebar happens to have selected — launching from
    /// inside a session should start the new agent alongside it.
    private var launchTarget: MockProject? {
        store.project(agent.projectID) ?? store.selectedProject
    }

    /// Work mode + build policy as rail icons: fixed 34pt circles showing the
    /// current value's SF Symbol, name in the tooltip, same menus as before.
    /// Glyphs may swap with the value, but the circle never changes size, so
    /// nothing on either side moves.
    @ViewBuilder
    private var modeIconButton: some View {
        let current = store.workMode(of: agent)
        GlassDropdown(items: modeItems(current: current), width: 250, chromelessLabel: true) {
            Image(systemName: current.iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DaddyTheme.textSecondary)
                .frame(width: 34, height: 34)
                .background {
                    Circle().fill(Color.white.opacity(modeHovering ? 0.12 : 0.06))
                }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(modeHovering ? 0.22 : 0.12))
                }
                .contentShape(Circle())
        }
        .help("Work mode: \(current.displayName) — click to change")
        .disabled(!agent.isLive)
        .opacity(agent.isLive ? 1 : 0.4)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { modeHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: modeHovering)
    }

    @ViewBuilder
    private var policyIconButton: some View {
        let current = store.buildPolicy(of: agent)
        GlassDropdown(items: buildItems(current: current), width: 250, chromelessLabel: true) {
            Image(systemName: current.iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DaddyTheme.textSecondary)
                .frame(width: 34, height: 34)
                .background {
                    Circle().fill(Color.white.opacity(buildHovering ? 0.12 : 0.06))
                }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(buildHovering ? 0.22 : 0.12))
                }
                .contentShape(Circle())
        }
        .help("Builds: \(current.displayName) — click to change")
        .disabled(!agent.isLive)
        .opacity(agent.isLive ? 1 : 0.4)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { buildHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: buildHovering)
    }

    /// The four modes as dropdown rows.
    ///
    /// Each carries its own summary as the note, because "Explore" alone does
    /// not tell you it is the one that will not touch your code.
    private func modeItems(current: WorkMode) -> [GlassDropdownItem] {
        WorkMode.allCases.map { mode in
            GlassDropdownItem(
                id: "mode-\(mode.rawValue)",
                title: mode.displayName,
                note: mode == current ? "current" : mode.slashCommand,
                isEnabled: mode != current,
                isSelected: mode == current
            ) {
                setWorkMode(mode)
            }
        }
    }

    private func setWorkMode(_ mode: WorkMode) {
        store.setWorkMode(mode, for: agent.id)
    }

    private func buildItems(current: BuildPolicy) -> [GlassDropdownItem] {
        BuildPolicy.allCases.map { policy in
            GlassDropdownItem(
                id: "build-\(policy.rawValue)",
                title: policy.displayName,
                note: policy == current ? "current" : policy.slashCommand,
                isEnabled: policy != current,
                isSelected: policy == current
            ) {
                store.setBuildPolicy(policy, for: agent.id)
            }
        }
    }

    private var menuItems: [GlassDropdownItem] {
        var items = [
            GlassDropdownItem(id: "model", title: "Model", note: agent.modelLabel, isEnabled: false) {},
            GlassDropdownItem(
                id: "conversation",
                title: "Conversation",
                note: agent.title ?? "untitled",
                isEnabled: false
            ) {},
            GlassDropdownItem(id: "work", title: "Work unit", note: agent.workUnitID, isEnabled: false) {},
            processItem,
            GlassDropdownItem(id: "docs", title: "View project docs") {
                onOpenProgress(agent.projectID)
            },
            GlassDropdownItem(
                id: "shell",
                title: store.userShellCollapsed ? "Show your shell" : "Hide your shell"
            ) {
                store.userShellCollapsed.toggle()
            },
        ]

        if agent.isLive {
            for kind in [AgentKind.claude, .codex, .cursor, .opencode]
            where kind != agent.agent {
                items.append(
                    GlassDropdownItem(
                        id: "handoff-\(kind.rawValue)",
                        title: "Hand off to \(kind.rawValue.capitalized)",
                        note: store.isInstalled(kind) ? nil : "not installed",
                        isEnabled: store.isInstalled(kind)
                    ) {
                        store.handOff(agent.id, to: kind)
                    }
                )
            }

            // The end of the session ends the menu. It was sitting third from
            // the top, one row away from "View project docs", which is the
            // wrong neighbourhood for the only item here you cannot take back —
            // and "Stop agent" undersold it: stopping already clears the card,
            // so the word for it is the same one the red X uses.
            items.append(
                GlassDropdownItem(id: "dismiss", title: "Dismiss agent", isDestructive: true) {
                    store.stop(agent.id)
                }
            )
        } else {
            if store.canResumeChat(agent.agent) {
                items.append(GlassDropdownItem(id: "resume", title: "Resume chat") {
                    store.relaunch(agent.id, continuingConversation: true)
                })
                items.append(GlassDropdownItem(id: "fresh", title: "Fresh start") {
                    store.relaunch(agent.id)
                })
            } else {
                items.append(GlassDropdownItem(id: "relaunch", title: "Relaunch") {
                    store.relaunch(agent.id)
                })
            }
            items.append(
                GlassDropdownItem(id: "dismiss", title: "Dismiss agent", isDestructive: true) {
                    store.dismiss(agent.id)
                }
            )
        }

        return items
    }

    private var processItem: GlassDropdownItem {
        if let pty = store.pty(for: agent) {
            if pty.isProcessRunning {
                return GlassDropdownItem(
                    id: "process",
                    title: "Process",
                    note: "pid \(pty.pid)",
                    isEnabled: false
                ) {}
            }
            if let code = pty.exitCode {
                return GlassDropdownItem(
                    id: "process",
                    title: "Process",
                    note: "exit \(code)",
                    isEnabled: false
                ) {}
            }
        }
        return GlassDropdownItem(
            id: "process",
            title: "Process",
            note: "unavailable",
            isEnabled: false
        ) {}
    }
}
