import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The contents of one project, as rows under its sidebar entry.
///
/// Flat, not recursive. `FileTreeStore.rows(under:)` has already walked the
/// expanded subtree and stamped each row with its depth, so the indent is a
/// leading pad and a change three levels down redraws one row instead of
/// rebuilding every container above it.
struct ProjectFileTree: View {
    @Environment(MockStore.self) private var store

    let root: String
    let fileTree: FileTreeStore

    /// False while the rail is only hover-open. You can still drag into the
    /// tree — that is the whole point of spring-loading — but rename, delete
    /// and the context menu belong to a rail that is going to still be there
    /// when you reach for the keyboard.
    let actionsEnabled: Bool

    /// Reported on every row that a drag enters or leaves, so the rail can keep
    /// itself open for as long as something is in flight over it.
    let onDragTarget: (Bool) -> Void

    var body: some View {
        let rows = fileTree.rows(under: root)

        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(rows) { row in
                FileTreeRow(
                    entry: row.entry,
                    depth: row.depth,
                    fileTree: fileTree,
                    actionsEnabled: actionsEnabled,
                    isProject: store.project(row.entry.id) != nil,
                    onDragTarget: onDragTarget,
                    onSelectProject: { path in
                        guard let project = store.project(path) else { return }
                        withAnimation(.smooth(duration: 0.3)) {
                            _ = AppActionDispatcher(store: store).perform(.openProject(projectID: project.id))
                        }
                    }
                )
            }

            if rows.isEmpty {
                Text("empty")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DaddyTheme.textVeryDim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Row

struct FileTreeRow: View {
    let entry: FileTreeStore.Entry
    let depth: Int
    let fileTree: FileTreeStore
    let actionsEnabled: Bool

    /// True when this directory is also something `MockStore` knows about, and
    /// so also sets where the next agent launches.
    ///
    /// Only project roots and their immediate subdirectories are ever projects —
    /// that is as deep as `ProjectScanner` looks — so this reproduces the old
    /// two-level behaviour without the tree having to count its own depth.
    let isProject: Bool

    let onDragTarget: (Bool) -> Void
    let onSelectProject: (String) -> Void

    @State private var hovering = false

    private var isSelected: Bool { fileTree.selection == entry.id }
    private var isRenaming: Bool { fileTree.renaming == entry.id }
    private var isDropTarget: Bool { fileTree.dropTarget == entry.id }
    private var isExpanded: Bool { fileTree.isExpanded(entry.id) }

    var body: some View {
        Group {
            // No button around a text field: clicking into the name you are
            // editing must put the caret there, not re-trigger the row.
            if isRenaming {
                rowContent
            } else {
                Button(action: tapped) { rowContent }
                    .buttonStyle(.plain)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    isDropTarget ? DaddyTheme.accent.opacity(0.18)
                        : isSelected ? DaddyTheme.insetFillSelected
                        : hovering ? DaddyTheme.insetFill
                        : Color.clear
                )
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(DaddyTheme.accent.opacity(0.75), lineWidth: 1.5)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // Out of the tree and into anything that takes a file: Finder, another
        // app, or the agent's own terminal — `DroppableTerminalView` accepts
        // `.fileURL` and types the escaped path at the cursor.
        .onDrag {
            fileTree.beginInternalDrag(entry.id)
            return NSItemProvider(object: entry.url as NSURL)
        }
        .modifier(
            FolderDropTarget(
                accepts: true,
                onFiles: { fileTree.receive($0, into: dropDestination) },
                onTargetChanged: { targeted in
                    onDragTarget(targeted)
                    if targeted {
                        fileTree.dropTarget = dropDestination
                    } else if fileTree.dropTarget == dropDestination {
                        fileTree.dropTarget = nil
                    }
                },
                onSpringLoad: {
                    guard entry.isDirectory, !isExpanded else { return }
                    withAnimation(.smooth(duration: 0.2)) { fileTree.expand(entry.id) }
                }
            )
        )
        .contextMenu {
            if actionsEnabled {
                FileTreeMenu(entry: entry, fileTree: fileTree)
            }
        }
    }

    /// The row's contents, at full width with the padding inside the hit shape.
    ///
    /// Padding has to be *inside* whatever carries the gesture. Put it outside
    /// and the clickable area is the glyphs and nothing else — which is what
    /// `ProjectRow` did for its whole life, and is why a row that looks like a
    /// single wide target behaves like a link.
    private var rowContent: some View {
        HStack(spacing: 5) {
            // The indent stops growing at six levels. Past that the name has
            // more to say than the depth does, and the rail is 264pt wide.
            Color.clear.frame(width: CGFloat(min(depth, 6)) * 11, height: 1)

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(DaddyTheme.textMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
            } else {
                Color.clear.frame(width: 10, height: 1)
            }

            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(iconTint)
                .frame(width: 13)

            if isRenaming {
                RenameField(
                    text: entry.name,
                    selectionLength: renameSelectionLength,
                    onCommit: { fileTree.rename(entry, to: $0) },
                    onCancel: { fileTree.renaming = nil }
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
                Text(entry.name)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(nameTint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func tapped() {
        TreeKeyboard.claim()
        fileTree.select(entry.id)

        if entry.isDirectory {
            withAnimation(.smooth(duration: 0.2)) { fileTree.toggle(entry.id) }
            // Only the levels `ProjectScanner` calls projects move the launch
            // scope. Clicking into `src/components` to find a file must not
            // quietly change where the next agent starts.
            if isProject { onSelectProject(entry.id) }
        }
    }

    /// Where a drop on this row actually lands.
    ///
    /// A folder takes it. A **file** hands it to the folder it sits in, which
    /// is what Finder does and what this was missing: file rows accepted
    /// nothing and highlighted nothing, so in a tree that is mostly files most
    /// of the rail was dead space. You had to hit one of the few folder rows
    /// exactly, and everywhere else a drag just died with no feedback at all.
    private var dropDestination: String {
        entry.isDirectory ? entry.id : entry.url.deletingLastPathComponent().path
    }

    /// How much of the name Finder would have highlighted: everything, unless
    /// it is a file with a real extension, in which case the extension is left
    /// out — you are almost always renaming the stem, not the type.
    ///
    /// A dotfile has no extension by this reckoning (`.env` is all stem), so it
    /// selects whole, which is what you want there too.
    private var renameSelectionLength: Int {
        let name = entry.name as NSString
        guard !entry.isDirectory else { return name.length }

        let stem = name.deletingPathExtension as NSString
        return stem.length > 0 ? stem.length : name.length
    }

    private var nameTint: Color {
        if isSelected { return DaddyTheme.textPrimary }
        return entry.isDirectory ? DaddyTheme.textSecondary : DaddyTheme.textTertiary
    }

    private var iconTint: Color {
        entry.isDirectory ? DaddyTheme.accent.opacity(0.75) : DaddyTheme.textMuted
    }

    private var icon: String {
        guard !entry.isDirectory else { return isExpanded ? "folder.fill" : "folder" }

        switch (entry.name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "svg", "icns":
            return "photo"
        case "mp4", "mov", "m4v", "webm":
            return "film"
        case "mp3", "wav", "aiff", "m4a":
            return "waveform"
        case "pdf":
            return "doc.richtext"
        case "md", "markdown", "txt", "rtf":
            return "doc.text"
        case "json", "yml", "yaml", "toml", "plist", "xml":
            return "curlybraces"
        case "zip", "tar", "gz", "dmg":
            return "archivebox"
        case "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs",
             "c", "h", "m", "cpp", "sh", "html", "css":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc"
        }
    }
}

// MARK: - Menu

/// The same actions the keyboard has, for the hand that is already on the mouse.
struct FileTreeMenu: View {
    let entry: FileTreeStore.Entry
    let fileTree: FileTreeStore

    var body: some View {
        Button("Rename") {
            fileTree.select(entry.id)
            fileTree.renaming = entry.id
        }
        Button("Move to Trash") { fileTree.trash(entry) }

        Divider()

        Button("New File") { fileTree.createFile(in: creationDirectory) }
        Button("New Folder") { fileTree.createFolder(in: creationDirectory) }

        Divider()

        Button("Reveal in Finder") { fileTree.revealInFinder(entry.id) }
        Button("Copy Path") { fileTree.copyPath(entry.id) }

        Divider()

        Toggle("Show Hidden Files", isOn: hiddenFilesBinding)
    }

    /// Right-clicking a folder creates inside it; right-clicking a file creates
    /// beside it. Same rule Finder uses.
    private var creationDirectory: String {
        entry.isDirectory
            ? entry.id
            : entry.url.deletingLastPathComponent().path
    }

    private var hiddenFilesBinding: Binding<Bool> {
        Binding(
            get: { fileTree.showsHiddenFiles },
            set: { fileTree.setShowsHiddenFiles($0) }
        )
    }
}

// MARK: - Spring loading

/// A row that accepts a drag, and opens itself if you hold there.
///
/// ## Why `onDrop` and not `dropDestination`
///
/// `dropDestination(for: URL.self)` is the modern spelling and it does not
/// work for this. Finder puts `public.file-url` on the drag pasteboard, and
/// asking SwiftUI to decode that into a `URL` through `Transferable` silently
/// matched nothing — no targeting, no highlight, no drop. The rows looked inert
/// while a file was dragged straight across them.
///
/// `onDrop(of: [.fileURL])` names the pasteboard type outright, which is what
/// `DroppableTerminalView` already does in this codebase — via
/// `registerForDraggedTypes([.fileURL, …])` — and that path has always worked.
///
/// The URLs are then read straight off the drag pasteboard rather than through
/// `NSItemProvider`, because a provider only loads asynchronously and `perform`
/// has to answer immediately. The drag pasteboard is valid for the whole drop,
/// so it can just be read.
///
/// ## Why the targeting cannot be `onHover`
///
/// A hover callback fires for a *mouse* moving over a view, and during a drag
/// session AppKit is not sending those — the pointer belongs to the drag. The
/// drop target's own targeting is the only signal there is while something is
/// in flight, so it does double duty: it highlights the row, and it drives the
/// dwell timer that unfolds the tree ahead of the file you are carrying.
struct FolderDropTarget: ViewModifier {
    /// False for files and for the collapsed rail. Such a target still reports
    /// targeting — so the rail can open, and so a file row can refuse visibly —
    /// but it never springs open and never accepts.
    let accepts: Bool

    let onFiles: ([URL]) -> Void
    let onTargetChanged: (Bool) -> Void
    let onSpringLoad: () -> Void

    @State private var springTask: Task<Void, Never>?
    @State private var targeted = false

    /// Near enough to Finder's own. Long enough that crossing a folder on the
    /// way to the one below it does not open the wrong one.
    private static let springDelay: Duration = .milliseconds(500)

    func body(content: Content) -> some View {
        content
            .onDrop(
                of: [.fileURL],
                isTargeted: Binding(
                    get: { targeted },
                    set: { targetingChanged($0) }
                )
            ) { _ in
                endTargeting()
                guard accepts else { return false }

                let files = Self.draggedFiles()
                guard !files.isEmpty else { return false }

                onFiles(files)
                return true
            }
            .onDisappear { springTask?.cancel() }
    }

    private func targetingChanged(_ value: Bool) {
        targeted = value
        onTargetChanged(value)

        springTask?.cancel()
        guard value, accepts else {
            springTask = nil
            return
        }

        springTask = Task {
            try? await Task.sleep(for: Self.springDelay)
            guard !Task.isCancelled else { return }
            onSpringLoad()
        }
    }

    private func endTargeting() {
        springTask?.cancel()
        springTask = nil
        targeted = false
        onTargetChanged(false)
    }

    /// What is being dragged, read synchronously off the drag pasteboard.
    ///
    /// Same call `DroppableTerminalView` makes, and for the same reason: it is
    /// the one place the file URLs are already sitting, in full, right now.
    private static func draggedFiles() -> [URL] {
        let objects = NSPasteboard(name: .drag).readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        return (objects as? [URL]) ?? []
    }
}

// MARK: - Rename field

/// Finder's rename box: opens focused, with the name already selected.
///
/// A SwiftUI `TextField` could not do this. `@FocusState` set in `onAppear`
/// fires before the view is in a window, so the field came up unfocused and you
/// had to click into it before you could type — and SwiftUI has no way at all
/// to say "select this range", which is the part that makes renaming one
/// gesture instead of three.
///
/// An `NSTextField` gives both, explicitly: make it first responder, then set
/// the field editor's selection. No guessing about when focus lands, because
/// this code is what makes it land.
struct RenameField: NSViewRepresentable {
    /// The name to start from. Read once — after that the field owns its text,
    /// and re-syncing it from outside would fight the caret.
    let text: String

    /// How much to highlight when it opens. Finder selects the stem and leaves
    /// the extension alone.
    let selectionLength: Int

    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11.5)
        field.textColor = .white
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        // Otherwise the field hugs its text and the row's spacer takes the rest.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // The closures are re-made every time SwiftUI rebuilds the row, and the
        // coordinator outlives all of them.
        context.coordinator.parent = self

        guard !context.coordinator.hasOpened else { return }
        context.coordinator.hasOpened = true

        // A hop, because `updateNSView` can run before the view is in a window,
        // and there is no first responder to become until it is.
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)

            let total = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = NSRange(
                location: 0, length: min(selectionLength, total)
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameField
        var hasOpened = false

        /// Set by whichever exit happened first, so committing does not then
        /// also fire as an "editing ended" commit on the way out.
        private var finished = false

        init(_ parent: RenameField) { self.parent = parent }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finish { parent.onCommit(textView.string) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish { parent.onCancel() }
                return true
            default:
                return false
            }
        }

        /// Clicking away commits, the way Finder does. Losing a rename because
        /// you looked at something else is not a behaviour anybody wants.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            finish { parent.onCommit(field.stringValue) }
        }

        private func finish(_ body: () -> Void) {
            guard !finished else { return }
            finished = true
            body()
        }
    }
}
