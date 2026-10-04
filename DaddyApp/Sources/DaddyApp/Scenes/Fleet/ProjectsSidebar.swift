import SwiftUI

/// The project tree, as one section of `WorkspaceRail`.
///
/// This used to be the whole left sidebar — its own glass panel, its own hover
/// and pin behaviour, its own scroll view, its own FOCUS footer. All of that
/// moved up to the rail when the rail gained a second section, so what is left
/// here is the tree itself and the row it is built from.
///
/// It used to list every project and let you open the tree under one of them.
/// Now the tab strip owns the project list, so there is exactly one project to
/// render: the active tab's. The tree under it is stored on the tab
/// (`expandedPaths`), not here, so switching tabs puts each tree back the way
/// you left it.
struct ActiveProjectSection: View {
    @Environment(MockStore.self) private var store

    let fileTree: FileTreeStore

    /// Rename, delete, create, right-click. Pinned only: these want a rail that
    /// will still be there when your hand reaches the keyboard, and a
    /// hover-open rail is gone the moment it leaves the pointer.
    let actionsEnabled: Bool

    let onDragTarget: (Bool) -> Void

    var body: some View {
        if let project = store.selectedProject {
            VStack(alignment: .leading, spacing: 4) {
                ProjectRow(
                    project: project,
                    isSelected: true,
                    sessionCount: store.agentCount(for: project.id),
                    hasChildren: false,
                    isExpanded: true,
                    isDropTarget: fileTree.dropTarget == project.path,
                    isRenaming: fileTree.renaming == project.path,
                    onRename: { renameProject(project, to: $0) },
                    onCancelRename: { fileTree.renaming = nil },
                    onDisclosure: {}
                ) {
                    // Selects it in the *tree* as well as in the store. Without
                    // this the root row was unreachable from the keyboard —
                    // `fileTree.selection` stayed on whatever file you last
                    // touched, so ⌘⌫ deleted that instead of doing nothing, and
                    // Enter renamed it. Only sub-rows were ever selectable.
                    TreeKeyboard.claim()
                    fileTree.select(project.path)
                }
                .modifier(
                    FolderDropTarget(
                        accepts: true,
                        onFiles: { fileTree.receive($0, into: project.path) },
                        onTargetChanged: { targeted in
                            onDragTarget(targeted)
                            if targeted {
                                fileTree.dropTarget = project.path
                            } else if fileTree.dropTarget == project.path {
                                fileTree.dropTarget = nil
                            }
                        },
                        onSpringLoad: {}
                    )
                )

                ProjectFileTree(
                    root: project.path,
                    fileTree: fileTree,
                    actionsEnabled: actionsEnabled,
                    onDragTarget: onDragTarget
                )
                .padding(.leading, 6)
            }
            // An unpinned rail is about to disappear; a half-typed rename
            // inside it would be committed by nothing and lost.
            .onChange(of: actionsEnabled) { _, enabled in
                if !enabled { fileTree.renaming = nil }
            }
        } else {
            Text("No project")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DaddyTheme.textVeryDim)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
    }

    private func renameProject(_ project: MockProject, to name: String) {
        guard let entry = fileTree.entry(at: project.path) else {
            fileTree.renaming = nil
            return
        }
        fileTree.rename(entry, to: name)
    }
}

// MARK: - Row
//
// Inside a glass panel, so: no glass. Selection is a plain white-alpha inset.

struct ProjectRow: View {
    let project: MockProject
    let isSelected: Bool
    let sessionCount: Int
    let hasChildren: Bool
    let isExpanded: Bool
    /// A drag is hovering here. Reads as the accent rather than the selection
    /// inset, because it is about where a file is going to land, not about what
    /// the app is pointed at.
    let isDropTarget: Bool

    /// A project is renamed in place, exactly like any other folder — it is one.
    let isRenaming: Bool
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    let onDisclosure: () -> Void
    let onTap: () -> Void

    @State private var hovering = false

    /// The whole row is the button.
    ///
    /// It used to be the *name* — an inner `Button` around the text and the
    /// badge, with the leading padding, the chevron gutter and the status dot
    /// outside it. The `contentShape` on the outer stack looked like it fixed
    /// that and did nothing at all: a content shape only shapes hit-testing for
    /// a gesture attached to the same view, and there was no gesture there.
    /// Clicking a project meant hitting the text.
    ///
    /// The chevron stays separately clickable by sitting in an overlay, which
    /// is hit-tested ahead of the button underneath it.
    var body: some View {
        Group {
            // No button around a text field: clicking into the name you are
            // editing must put the caret there, not re-trigger the row.
            if isRenaming {
                rowContent
            } else {
                Button(action: onTap) { rowContent }
                    .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .leading) {
            if hasChildren, !isRenaming {
                Button(action: onDisclosure) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DaddyTheme.textMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 11)
                .help(isExpanded ? "Collapse folder" : "Show contents")
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    isDropTarget ? DaddyTheme.accent.opacity(0.18)
                        : isSelected ? DaddyTheme.insetFillSelected
                        : hovering ? DaddyTheme.insetFill
                        : Color.clear
                )
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(DaddyTheme.accent.opacity(0.75), lineWidth: 1.5)
            } else if isSelected {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(DaddyTheme.insetStrokeSelected, lineWidth: 1)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
                // The gutter the chevron overlay sits in.
                Color.clear.frame(width: 12, height: 16)

                Circle()
                    .fill(sessionCount > 0 ? DaddyTheme.working : DaddyTheme.textVeryDim)
                    .frame(width: 6, height: 6)

                if isRenaming {
                    RenameField(
                        text: project.name,
                        selectionLength: (project.name as NSString).length,
                        onCommit: onRename,
                        onCancel: onCancelRename
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(DaddyTheme.accent.opacity(0.8), lineWidth: 1)
                    }
                } else {
                    Text(project.name)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? DaddyTheme.textPrimary : DaddyTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if sessionCount > 0 {
                    Text("\(sessionCount)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DaddyTheme.working)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .insetCapsule(tint: DaddyTheme.working, opacity: 0.10)
                }
            }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
