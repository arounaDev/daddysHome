import SwiftUI

/// Several work items sent together in one multi-task dispatch, drawn as one
/// card. The items themselves stay independent — this is only how the board
/// groups them; each row opens the same `BoardDetailPane` a lone card would.
///
/// Distinct from `BoardCard` on purpose: a gradient header and a stacked-cards
/// glyph mark it as "several things", not another flavor of the plain card.
struct BoardBundleCard: View {
    let bundleID: UUID
    let items: [OrchestratorWorkItem]
    let isCollapsed: Bool
    /// Dimmed while this bundle is the card in hand — same role as
    /// `BoardCard.isDragging`.
    let isDragging: Bool
    /// Cmd+B keyboard cursor — same role as `BoardCard.isSelectionCursor`.
    var isSelectionCursor: Bool = false
    /// Cmd+B picked — same role as `BoardCard.isPicked`.
    var isPicked: Bool = false
    /// When true, a header click picks the bundle instead of collapsing.
    var selectionModeActive: Bool = false
    let selectedID: UUID?
    let showsCategory: Bool
    let projectName: (OrchestratorWorkItem) -> String?
    let onToggleCollapsed: () -> Void
    let onSelectItem: (OrchestratorWorkItem) -> Void
    /// Picks the whole bundle in Cmd+B mode (header click).
    let onPickBundle: () -> Void
    /// Opens the bundle-level summary pane — the only way to see the whole
    /// bundle at once or unbundle it, since the card itself has no fields.
    let onOpenDetail: () -> Void
    /// Same board-space drag callbacks as `BoardCard`. The representative
    /// item is the first member; `BoardView` expands to the whole bundle.
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void

    @State private var hoveringHeader = false

    private var tints: [Color] { Array(Set(items.map(\.category.tint))).prefix(4).map { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.055))
        }
        .overlay {
            if isSelectionCursor || isPicked {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DaddyTheme.accent.opacity(isPicked ? 0.16 : 0.10))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: tints.isEmpty ? [DaddyTheme.accent] : tints,
                        startPoint: .leading,
                        endPoint: .trailing
                    ).opacity(isSelectionCursor || isPicked ? 0 : 0.55),
                    lineWidth: 1
                )
        }
        .overlay {
            if isSelectionCursor || isPicked {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        DaddyTheme.accent.opacity(isPicked ? 0.95 : 0.75),
                        lineWidth: isPicked ? 2.5 : 2
                    )
            }
        }
        .overlay(alignment: .topLeading) {
            if isSelectionCursor || isPicked {
                selectionBadge
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(isDragging ? 0.3 : 1)
    }

    private var selectionBadge: some View {
        Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isPicked ? DaddyTheme.accent : DaddyTheme.textMuted)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .padding(6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(headerTint)

            Text("\(items.count) TASKS BUNDLED")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(DaddyTheme.textSecondary)

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                ForEach(Array(tints.enumerated()), id: \.offset) { _, tint in
                    Circle().fill(tint).frame(width: 5, height: 5)
                }
            }

            Button(action: onOpenDetail) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(headerTint)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Bundle details — see every task, or unbundle")

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(DaddyTheme.textMuted)
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                .animation(.easeOut(duration: 0.12), value: isCollapsed)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background {
            LinearGradient(
                colors: (tints.isEmpty ? [DaddyTheme.accent] : tints).map { $0.opacity(hoveringHeader ? 0.22 : 0.14) },
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .contentShape(Rectangle())
        // Same click-vs-drag split as `BoardCard`: past the threshold this
        // header lifts the whole bundle; otherwise it toggles collapsed —
        // or picks the bundle while Cmd+B selection is active.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(BoardSpace.name))
                .onChanged { value in
                    guard Self.isDrag(value.translation) else { return }
                    onDragChanged(value.location)
                }
                .onEnded { value in
                    if Self.isDrag(value.translation) {
                        onDragEnded(value.location)
                    } else if selectionModeActive {
                        onPickBundle()
                    } else {
                        onToggleCollapsed()
                    }
                }
        )
        .onHover { hoveringHeader = $0 }
    }

    private var headerTint: Color { tints.first ?? DaddyTheme.accent }

    private static func isDrag(_ translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) > 4
    }

    // MARK: - Rows

    private func row(_ item: OrchestratorWorkItem) -> some View {
        BundleRow(
            item: item,
            isSelected: selectedID == item.id,
            projectName: projectName(item),
            onSelect: { onSelectItem(item) },
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded
        )
    }
}

/// One line inside a bundle card — same click-vs-drag gesture as `BoardCard`,
/// but a drag lifts the whole bundle (callbacks come from the parent), not
/// this row alone. Archiving/deleting still happens from the detail pane.
private struct BundleRow: View {
    let item: OrchestratorWorkItem
    let isSelected: Bool
    let projectName: String?
    let onSelect: () -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(item.category.tint)
                .frame(width: 5, height: 5)

            Text(item.title.isEmpty ? "Untitled" : item.title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(DaddyTheme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let projectName {
                Text(projectName)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(DaddyTheme.textVeryDim)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(DaddyTheme.textVeryDim)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.10 : (hovering ? 0.06 : 0)))
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(BoardSpace.name))
                .onChanged { value in
                    guard Self.isDrag(value.translation) else { return }
                    onDragChanged(value.location)
                }
                .onEnded { value in
                    if Self.isDrag(value.translation) {
                        onDragEnded(value.location)
                    } else {
                        onSelect()
                    }
                }
        )
        .onHover { hovering = $0 }
    }

    private static func isDrag(_ translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) > 4
    }
}
