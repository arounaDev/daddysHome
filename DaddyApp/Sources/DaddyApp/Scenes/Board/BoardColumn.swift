import SwiftUI

/// One status column: a coloured header band, category groups inside it, and
/// drop targets at both levels.
///
/// Dropping on bare column space changes only the status. Dropping on a
/// category group changes the status *and* refiles the card, so a card can be
/// moved and recategorised in one gesture.
struct BoardColumn: View {
    let status: OrchestratorWorkStatus
    let items: [OrchestratorWorkItem]
    let selectedID: UUID?
    /// Nil when the board is already filtered to one category — a single group
    /// header above every card in every column says nothing.
    let groupByCategory: Bool
    let collapsed: Set<BoardGroupKey>
    /// Bundle cards folded shut — see `BoardBundleCard`.
    let collapsedBundleIDs: Set<UUID>
    /// Non-nil only in the all-projects scope; see `BoardCard.projectName`.
    let projectName: (OrchestratorWorkItem) -> String?

    let onSelect: (OrchestratorWorkItem) -> Void
    let onArchive: (OrchestratorWorkItem) -> Void
    let onDelete: (OrchestratorWorkItem) -> Void
    let onSendToOrchestrator: (OrchestratorWorkItem) -> Void
    let onToggleBundleCollapsed: (UUID) -> Void
    let onOpenBundle: (UUID) -> Void
    /// Cmd+B: pick the whole bundle as one unit (lead item). Distinct from
    /// `onSelect`, which opens a member's detail when a row is clicked.
    let onPickBundle: (OrchestratorWorkItem) -> Void
    let draggingID: UUID?
    let isDropTarget: Bool
    let onDragChanged: (OrchestratorWorkItem, CGPoint) -> Void
    let onDragEnded: (OrchestratorWorkItem, CGPoint) -> Void
    let onToggleGroup: (BoardGroupKey) -> Void
    let onAdd: () -> Void
    let onAddInCategory: (OrchestratorWorkCategory) -> Void
    /// Whether this column is the one Cmd+T will add into.
    let isSelected: Bool
    let onSelectColumn: () -> Void
    /// Whether this is the destination the Cmd+M move flow is currently
    /// pointed at. Blurs its own cards (there's nothing to read mid-move)
    /// and shows "Move to <column>" in their place.
    var isMoveTarget: Bool = false
    /// Cmd+B multi-select — see `BoardView`. `cursorID`/`pickedIDs` drive the
    /// highlight on individual (never-bundled) cards only.
    var selectionModeActive: Bool = false
    var cursorID: UUID?
    var pickedIDs: Set<UUID> = []

    static let width: CGFloat = 244

    /// One board card's worth of content: a lone item, or every item sharing
    /// a `bundleID` collapsed into one `BoardBundleCard`. Bundled items are
    /// grouped in the order they first appear so the card lands where its
    /// first member would have.
    private struct Unit: Identifiable {
        let id: String
        let bundleID: UUID?
        let category: OrchestratorWorkCategory
        let items: [OrchestratorWorkItem]
    }

    private var units: [Unit] {
        var seenBundles: Set<UUID> = []
        var result: [Unit] = []
        for item in items {
            if let bundleID = item.bundleID {
                guard !seenBundles.contains(bundleID) else { continue }
                seenBundles.insert(bundleID)
                let members = items.filter { $0.bundleID == bundleID }
                result.append(Unit(id: bundleID.uuidString, bundleID: bundleID, category: members[0].category, items: members))
            } else {
                result.append(Unit(id: item.id.uuidString, bundleID: nil, category: item.category, items: [item]))
            }
        }
        return result
    }

    private var groups: [(category: OrchestratorWorkCategory, units: [Unit], count: Int)] {
        OrchestratorWorkCategory.allCases.compactMap { category in
            let matching = units.filter { $0.category == category }
            guard !matching.isEmpty else { return nil }
            let key = BoardGroupKey(status: status, category: category)
            let visible = collapsed.contains(key) ? [] : matching
            return (category, visible, matching.count)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .overlay {
                    if isMoveTarget {
                        moveTargetOverlay
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelectColumn)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(status.boardTint.opacity(isDropTarget ? 0.10 : (isSelected ? 0.075 : 0.035)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    status.boardTint.opacity(isDropTarget ? 0.75 : (isSelected ? 0.9 : 0.16)),
                    lineWidth: isSelected && !isDropTarget ? 2 : 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background {
            // Publishes where this column is, so a drag location can be
            // resolved to a column without the system drag machinery.
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BoardColumnFrameKey.self,
                    value: [status: proxy.frame(in: .named(BoardSpace.name))]
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(status.title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(status.boardTint)

            Spacer(minLength: 0)

            Text("\(items.count)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(status.boardTint.opacity(0.8))

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(status.boardTint.opacity(0.9))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New item in \(status.title)")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(status.boardTint.opacity(isSelected ? 0.24 : 0.16))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(status.boardTint.opacity(0.35))
                .frame(height: 1)
        }
    }

    // MARK: - Body

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if groupByCategory {
                        ForEach(groups, id: \.category) { group in
                            LazyVStack(alignment: .leading, spacing: 6) {
                                groupHeader(group.category, count: group.count)
                                ForEach(group.units) { unit($0, showsCategory: false) }
                            }
                        }
                    } else {
                        ForEach(units) { unit($0, showsCategory: true) }
                    }

                    if items.isEmpty {
                        Text("drop here")
                            .font(.system(size: 9.5))
                            .foregroundStyle(DaddyTheme.textVeryDim)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 26)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            // Only worth blurring if there's something to blur — an empty
            // column's "drop here" already reads fine under the overlay.
            .blur(radius: isMoveTarget && !items.isEmpty ? 10 : 0)
            // The selection cursor moves by keyboard, not scroll — nothing
            // was carrying the viewport along, so arrowing past the fold
            // left the cursor sitting off-screen, unseen. `scrollTo` is a
            // no-op for a column that doesn't contain this id, so every
            // column's reader can react to the same `cursorID` safely.
            .onChange(of: cursorID) { _, newCursorID in
                guard selectionModeActive, let newCursorID else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newCursorID, anchor: .center)
                }
            }
        }
    }

    /// "Move to <column>" — the only thing meant to be legible in this
    /// column while it's the Cmd+M destination.
    private var moveTargetOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(status.boardTint)
            Text("Move to \(status.title)")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(DaddyTheme.textPrimary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DaddyTheme.focusSurface.opacity(0.92))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func groupHeader(
        _ category: OrchestratorWorkCategory,
        count: Int
    ) -> some View {
        let key = BoardGroupKey(status: status, category: category)
        return GroupHeader(
            category: category,
            count: count,
            isCollapsed: collapsed.contains(key),
            onToggle: { onToggleGroup(key) },
            onAdd: { onAddInCategory(category) }
        )
    }

    @ViewBuilder
    private func unit(_ unit: Unit, showsCategory: Bool) -> some View {
        if unit.items.count > 1, let bundleID = unit.bundleID {
            // Drag uses the first member as the representative — `BoardView`
            // expands to every item sharing this `bundleID` on drop.
            let lead = unit.items[0]
            BoardBundleCard(
                bundleID: bundleID,
                items: unit.items,
                isCollapsed: collapsedBundleIDs.contains(bundleID),
                isDragging: unit.items.contains { $0.id == draggingID },
                isSelectionCursor: selectionModeActive && cursorID == lead.id,
                isPicked: selectionModeActive && pickedIDs.contains(lead.id),
                selectionModeActive: selectionModeActive,
                selectedID: selectedID,
                showsCategory: showsCategory,
                projectName: projectName,
                onToggleCollapsed: { onToggleBundleCollapsed(bundleID) },
                onSelectItem: { onSelect($0) },
                onPickBundle: { onPickBundle(lead) },
                onOpenDetail: { onOpenBundle(bundleID) },
                onDragChanged: { onDragChanged(lead, $0) },
                onDragEnded: { onDragEnded(lead, $0) }
            )
            .id(lead.id)
        } else {
            card(unit.items[0], showsCategory: showsCategory)
                .id(unit.items[0].id)
        }
    }

    private func card(_ item: OrchestratorWorkItem, showsCategory: Bool) -> some View {
        BoardCard(
            item: item,
            isSelected: selectedID == item.id,
            isDragging: draggingID == item.id,
            showsCategory: showsCategory,
            projectName: projectName(item),
            isSelectionCursor: selectionModeActive && cursorID == item.id,
            isPicked: selectionModeActive && pickedIDs.contains(item.id),
            onSelect: { onSelect(item) },
            onDragChanged: { onDragChanged(item, $0) },
            onDragEnded: { onDragEnded(item, $0) },
            onArchive: { onArchive(item) },
            onDelete: { onDelete(item) },
            onSendToOrchestrator: { onSendToOrchestrator(item) }
        )
    }

}

/// The category divider inside a column. Its own drop target, so a card can be
/// refiled and moved in one gesture.
private struct GroupHeader: View {
    let category: OrchestratorWorkCategory
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void
    let onAdd: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(category.tint.opacity(0.8))
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                .animation(.easeOut(duration: 0.12), value: isCollapsed)

            Text(category.boardTitle)
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(category.tint)

            Rectangle()
                .fill(category.tint.opacity(0.22))
                .frame(height: 1)

            Text("\(count)")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(category.tint.opacity(0.7))

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(category.tint.opacity(0.9))
                    .frame(width: 15, height: 15)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New \(category.boardTitle.capitalized) item")
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(category.tint.opacity(hovering ? 0.10 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
    }
}
