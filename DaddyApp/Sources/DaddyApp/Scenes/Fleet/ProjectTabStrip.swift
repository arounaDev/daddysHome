import SwiftUI

/// The strip of project tabs across the top of the fleet.
///
/// Each tab is a project with its own agents, its own shell and its own tree —
/// like terminal tabs, except the unit of work is a project rather than a
/// shell. The strip only changes which project the rest of the fleet is
/// pointed at; nothing below it is rebuilt when it moves.
///
/// Deliberately chrome, not glass. Everything else in the window is a floating
/// panel over the aurora; the strip is a solid dark bar, so the tabs read as
/// the thing the whole window belongs to rather than one more card in it.
struct ProjectTabStrip: View {
    @Environment(MockStore.self) private var store

    /// The `+` picker. Owned by the caller (`FleetView`) because ⌘T has to open
    /// it from a keyboard monitor, and only the picker — not a `Menu` — can be
    /// opened programmatically.
    @Binding var openPicker: Bool

    @State private var hoveredTabID: String?
    @State private var plusHovering = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(store.projectTabs) { tab in
                tabButton(tab)
                    .frame(minWidth: 130, maxWidth: 220)
            }

            plusButton
                .padding(.leading, 2)
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DaddyTheme.focusSurface.opacity(0.92))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DaddyTheme.insetStroke, lineWidth: 1)
        }
    }

    // MARK: Tabs

    private func tabButton(_ tab: ProjectTab) -> some View {
        let isActive = store.activeTabID == tab.id
        let isHovering = hoveredTabID == tab.id
        let liveCount = store.agentCount(for: tab.projectID)

        return HStack(spacing: 7) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? DaddyTheme.accent : DaddyTheme.textMuted)

            Text(tab.title)
                .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? DaddyTheme.textPrimary : DaddyTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if liveCount > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DaddyTheme.working)
                        .frame(width: 6, height: 6)
                    Text("\(liveCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DaddyTheme.working)
                }
            }

            Spacer(minLength: 2)

            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    store.closeTab(tab.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(
                        (isActive || isHovering)
                            ? DaddyTheme.textSecondary : DaddyTheme.textVeryDim
                    )
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isActive || isHovering ? 1 : 0.55)
            .help("Close \(tab.title)")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isActive ? Color.white.opacity(0.13)
                        : (isHovering ? Color.white.opacity(0.06) : Color.clear)
                )
        }
        .overlay {
            if isActive || isHovering {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isActive ? DaddyTheme.insetStrokeSelected : DaddyTheme.insetStroke,
                        lineWidth: 1
                    )
            }
        }
        // The active tab gets an accent underline, so "which project am I in"
        // is answered by a mark rather than by comparing two shades of grey.
        .overlay(alignment: .bottom) {
            if isActive {
                Capsule()
                    .fill(DaddyTheme.accent)
                    .frame(width: 32, height: 2.5)
                    .offset(y: 5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            withAnimation(.smooth(duration: 0.2)) {
                store.activateTab(tab.id)
            }
        }
        .onHover { hoveredTabID = $0 ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID) }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .help("\(tab.title) — click to switch")
    }

    private var plusButton: some View {
        Button { openPicker = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(plusHovering ? DaddyTheme.textPrimary : DaddyTheme.textMuted)
                .frame(width: 26, height: 26)
                .background { Circle().fill(Color.white.opacity(plusHovering ? 0.14 : 0.06)) }
                .overlay { Circle().strokeBorder(DaddyTheme.insetStroke, lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { plusHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: plusHovering)
        .help("Open a project (⌘T)")
        .popover(isPresented: $openPicker, arrowEdge: .bottom) {
            openProjectPicker
                .padding(.vertical, 4)
        }
    }

    // MARK: The picker

    private var openProjectPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("OPEN A PROJECT")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(DaddyTheme.textMuted)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)

            ForEach(openableProjects) { project in
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        store.openTab(projectID: project.id)
                    }
                    openPicker = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DaddyTheme.textMuted)
                            .frame(width: 14)

                        Text(project.name)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DaddyTheme.textPrimary)

                        Spacer(minLength: 8)

                        if store.agentCount(for: project.id) > 0 {
                            Circle()
                                .fill(DaddyTheme.working)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if openableProjects.isEmpty {
                Text("All projects are open")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DaddyTheme.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: 240)
    }

    /// Roots only — a subdirectory is reached by opening its parent and walking
    /// in, not by a tab of its own.
    private var openableProjects: [MockProject] {
        store.rootProjects.filter { project in
            store.tab(for: project.id) == nil
        }
    }
}
