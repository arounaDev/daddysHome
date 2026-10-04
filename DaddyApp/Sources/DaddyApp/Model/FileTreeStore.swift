import AppKit
import Foundation
import Observation

/// What is actually on disk under each project, and what you are doing to it.
///
/// The rail's tree used to be `ProjectScanner`'s output and nothing else: a
/// project, and the one level of subdirectories the scanner happened to
/// collect. You could look at it, and that was all — every rename, every
/// delete, every image that had to end up in `assets/` meant leaving Daddy for
/// Finder and coming back.
///
/// This is the other half. It reads real directory contents on demand, and it
/// owns the mutations, because they all share the same three obligations that
/// are easy to get wrong in a view: the listing has to be re-read afterwards,
/// the expansion state is keyed by **path** and a rename changes every path
/// beneath it, and a failure has to say so out loud rather than leaving a row
/// that looks renamed and is not.
///
/// Nothing here is a project. `MockStore` still owns which project is selected
/// and where agents launch; this only knows about files.
@MainActor
@Observable
final class FileTreeStore {

    /// One row's worth of disk. Identified by absolute path, which is also how
    /// `MockProject` identifies itself — that is what lets a directory row ask
    /// `MockStore` whether it is also a project without a second lookup table.
    struct Entry: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let isDirectory: Bool

        var url: URL { URL(fileURLWithPath: id) }
    }

    /// A flattened row, ready for a `ForEach`.
    ///
    /// The tree is rendered flat rather than by recursive views. A recursive
    /// `ForEach` rebuilds an entire subtree whenever any node in it changes,
    /// and in a 264pt rail there is nothing to gain from the nesting — the
    /// indent is a leading pad either way.
    struct Row: Identifiable, Hashable {
        let entry: Entry
        let depth: Int

        var id: String { entry.id }
    }

    // MARK: State

    /// Directory path → its listing. Absent means "not read yet".
    private(set) var children: [String: [Entry]] = [:]

    private(set) var expanded: Set<String> = []

    /// The row the keyboard acts on. A path, not an `Entry`, so it survives a
    /// reload replacing the struct.
    var selection: String?

    /// Whether the tree is the thing you are currently working in.
    ///
    /// This replaces asking AppKit who holds first responder, which turned out
    /// to be an unreliable way to gate a keyboard shortcut: the answer changes
    /// under relayout, focus gets handed around during an expand, and the tree
    /// would go deaf for reasons that had nothing to do with what the user was
    /// doing. Clicking a row arms it; the next mouse-down anywhere disarms it,
    /// and a row click re-arms it on the way back up.
    ///
    /// It is the whole gate now. Deterministic, and it never has to guess.
    private(set) var isActive = false

    func activate() { isActive = true }
    func deactivate() { isActive = false }

    /// The row currently showing a text field instead of its name.
    var renaming: String?

    /// The directory a drag is hovering over, highlighted as the drop target.
    var dropTarget: String?

    /// Off by default, `⇧⌘.` toggles it — the same chord Finder uses.
    ///
    /// `.git` stays hidden either way. It is thousands of files, it is never
    /// something you want to rename by hand, and expanding it once would open
    /// a watcher on a directory that changes on every single commit.
    private(set) var showsHiddenFiles = false

    /// Set when an operation fails. The rail shows it as an alert.
    ///
    /// Every mutation below writes here rather than swallowing the error. A
    /// read-only volume, a permission we do not have, a name the filesystem
    /// rejects — all of them look identical to success from a view that only
    /// checks whether the call returned.
    var errorMessage: String?

    /// Stamped every time a drop lands, so the rail can hold itself open long
    /// enough for you to see where the file went.
    ///
    /// A published instant rather than a callback the rail installs: a closure
    /// stored here would capture the rail's own view struct, and the rail owns
    /// this store — the two would keep each other alive.
    private(set) var lastDropAt: Date?

    /// Stamped whenever something is created, renamed or trashed.
    ///
    /// `MockStore` keeps its own list of projects and rescans on a 30-second
    /// timer, so deleting a top-level project left a row in the rail pointing
    /// at a folder that was already in the Trash. The rail watches this and
    /// asks for a rescan straight away.
    private(set) var lastStructuralChangeAt: Date?

    private var watchers: [String: DirectoryWatcher] = [:]
    private var reloadTasks: [String: Task<Void, Never>] = [:]

    // MARK: Reading

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    func toggle(_ path: String) {
        if expanded.contains(path) { collapse(path) } else { expand(path) }
    }

    func expand(_ path: String) {
        guard !expanded.contains(path) else { return }
        expanded.insert(path)
        watch(path)
        reload(path)
    }

    /// Replace the expansion wholesale.
    ///
    /// Tab switches land here: each project tab remembers the folders it had
    /// open, and the tree has to forget all of it and remember that set in one
    /// move. Like `collapse`, the watchers stop but the listings stay cached,
    /// so switching back is instant.
    func applyExpansion(_ paths: Set<String>) {
        guard expanded != paths else { return }

        for path in expanded.subtracting(paths) {
            watchers[path] = nil
            reloadTasks[path]?.cancel()
            reloadTasks[path] = nil
        }

        expanded = paths

        for path in paths {
            watch(path)
            if children[path] == nil { reload(path) }
        }
    }

    func collapse(_ path: String) {
        guard expanded.contains(path) else { return }

        // Everything below it goes too. Leaving descendants expanded would keep
        // their watchers open for rows nobody can see, and re-opening the folder
        // later would unfold three levels you did not ask for.
        let prefix = path + "/"
        let closing = expanded.filter { $0 == path || $0.hasPrefix(prefix) }
        expanded.subtract(closing)
        for key in closing {
            watchers[key] = nil
            reloadTasks[key]?.cancel()
            reloadTasks[key] = nil
        }
    }

    /// Everything visible under `root`, depth-first, in display order.
    ///
    /// `root` itself is not included — the project row is drawn by the sidebar.
    func rows(under root: String) -> [Row] {
        var result: [Row] = []
        append(children: root, depth: 0, into: &result)
        return result
    }

    private func append(children path: String, depth: Int, into result: inout [Row]) {
        guard let listing = children[path] else { return }
        for entry in listing {
            result.append(Row(entry: entry, depth: depth))
            if entry.isDirectory, expanded.contains(entry.id) {
                append(children: entry.id, depth: depth + 1, into: &result)
            }
        }
    }

    func setShowsHiddenFiles(_ value: Bool) {
        guard showsHiddenFiles != value else { return }
        showsHiddenFiles = value
        for path in expanded { reload(path) }
    }

    func toggleHiddenFiles() {
        setShowsHiddenFiles(!showsHiddenFiles)
    }

    /// Re-reads one directory. Coalesced, because a watcher fires per write and
    /// copying ten files in is ten events for one listing worth reading.
    func reload(_ path: String, debounce: Duration = .zero) {
        reloadTasks[path]?.cancel()
        reloadTasks[path] = Task { [showsHidden = showsHiddenFiles] in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }

            let listing = await Self.read(path, showsHidden: showsHidden)
            guard !Task.isCancelled else { return }

            if let listing {
                children[path] = listing
            } else {
                // The directory is gone. Drop it rather than keeping a listing
                // of files that no longer exist.
                forget(subtreeOf: path)
            }
            reloadTasks[path] = nil
        }
    }

    private nonisolated static func read(_ path: String, showsHidden: Bool) async -> [Entry]? {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard let names = try? fileManager.contentsOfDirectory(atPath: path) else {
                return nil
            }

            var entries: [Entry] = []
            entries.reserveCapacity(names.count)

            for name in names {
                guard name != ".git", name != ".DS_Store" else { continue }
                guard showsHidden || !name.hasPrefix(".") else { continue }

                let full = path + "/" + name
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: full, isDirectory: &isDirectory) else {
                    continue
                }

                entries.append(
                    Entry(id: full, name: name, isDirectory: isDirectory.boolValue)
                )
            }

            // Folders first, then files. Finder interleaves them; a narrow rail
            // does not have the width for you to find the folders by eye.
            return entries.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }.value
    }

    private func watch(_ path: String) {
        guard watchers[path] == nil else { return }
        watchers[path] = DirectoryWatcher(path: path) { [weak self] in
            Task { @MainActor in
                guard let self, self.expanded.contains(path) else { return }
                self.reload(path, debounce: .milliseconds(150))
            }
        }
    }

    /// Drops a path and everything under it out of every cache.
    private func forget(subtreeOf path: String) {
        let prefix = path + "/"
        func owned(_ key: String) -> Bool { key == path || key.hasPrefix(prefix) }

        // Keys snapshotted before the loop: every one of these mutates the
        // collection it is walking.
        for key in Array(children.keys) where owned(key) { children[key] = nil }
        for key in Array(watchers.keys) where owned(key) { watchers[key] = nil }
        for key in Array(reloadTasks.keys) where owned(key) {
            reloadTasks[key]?.cancel()
            reloadTasks[key] = nil
        }
        expanded.subtract(expanded.filter(owned))
        if let selection, owned(selection) { self.selection = nil }
        if let renaming, owned(renaming) { self.renaming = nil }
    }

    /// Rewrites every cached path after a directory is renamed.
    ///
    /// Expansion, selection and the listing cache are all keyed by absolute
    /// path, so renaming `src` to `source` orphans every one of them at once:
    /// the folder collapses, the selection vanishes, and the children reappear
    /// under a key nothing reads. Re-keying is cheaper than re-reading the
    /// subtree, and it keeps the tree looking like the rename happened in place.
    private func remap(from old: String, to new: String) {
        let oldPrefix = old + "/"
        func moved(_ key: String) -> String? {
            if key == old { return new }
            guard key.hasPrefix(oldPrefix) else { return nil }
            return new + "/" + String(key.dropFirst(oldPrefix.count))
        }

        // Snapshotted keys throughout: each loop mutates what it walks.
        for key in Array(children.keys) {
            guard let destination = moved(key), let value = children[key] else { continue }
            children[key] = nil
            children[destination] = value.map {
                Entry(
                    id: moved($0.id) ?? $0.id,
                    name: $0.name,
                    isDirectory: $0.isDirectory
                )
            }
        }

        for key in Array(expanded) {
            guard let destination = moved(key) else { continue }
            expanded.remove(key)
            expanded.insert(destination)
        }

        // Rebuilt rather than re-keyed: a watcher's descriptor follows the
        // inode, so the old one is technically still watching the right
        // directory — but it reports under the old path, which no longer names
        // anything the store knows about.
        for key in Array(watchers.keys) {
            guard let destination = moved(key) else { continue }
            watchers[key] = nil
            if expanded.contains(destination) { watch(destination) }
        }

        if let selection, let destination = moved(selection) { self.selection = destination }
        if let renaming, let destination = moved(renaming) { self.renaming = destination }
    }

    // MARK: Selection

    func select(_ path: String) {
        isActive = true
        selection = path
        if renaming != path { renaming = nil }
    }

    func beginRenamingSelection() {
        guard let selection else { return }
        renaming = selection
    }

    /// Every project root the rail can show, and the one currently selected.
    ///
    /// Pushed in by the rail rather than read from `MockStore` on demand. The
    /// keyboard shortcuts are served from an `NSEvent` monitor, and a monitor's
    /// closure outlives the view update that created it — reaching into
    /// SwiftUI's environment from there is not something you are allowed to do.
    /// Two strings kept in sync is the cheap way to stay out of it.
    private(set) var projectRoots: [String] = []
    private(set) var selectedRoot: String?

    func setProjectRoots(_ roots: [String]) {
        guard projectRoots != roots else { return }
        projectRoots = roots
    }

    func setSelectedRoot(_ root: String?) {
        guard selectedRoot != root else { return }
        selectedRoot = root
    }

    /// The directory a new file belongs in: the selection if it is one, its
    /// parent if the selection is a file, and the enclosing project otherwise.
    var creationDirectory: String? {
        let root = selection.flatMap { selected in
            projectRoots.first { selected == $0 || selected.hasPrefix($0 + "/") }
        } ?? selectedRoot

        guard let root else { return nil }
        guard let selection, selection.hasPrefix(root) else { return root }

        if let entry = entry(at: selection), entry.isDirectory { return selection }
        return URL(fileURLWithPath: selection).deletingLastPathComponent().path
    }

    /// The row at `path`, cached or not.
    ///
    /// The cache lookup alone was not enough, and that is what stopped ⌘⌫ from
    /// deleting a top-level project: a project row's parent is `~/Documents`,
    /// nothing ever lists `~/Documents`, so there was no cached listing to find
    /// it in and every keyboard action guarded on this quietly did nothing.
    /// Falling back to the filesystem costs one `stat` on a path the user just
    /// clicked.
    func entry(at path: String) -> Entry? {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path

        if let cached = children[parent]?.first(where: { $0.id == path }) {
            return cached
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        return Entry(id: path, name: url.lastPathComponent, isDirectory: isDirectory.boolValue)
    }

    /// Reloads a directory only if it is one we are actually showing.
    ///
    /// After acting on a project root the parent is `~/Documents`, which is not
    /// a directory the tree lists — reading it would cache a listing nothing
    /// renders and start a watcher on the busiest folder on the disk.
    private func reloadIfListed(_ path: String) {
        guard children[path] != nil else { return }
        reload(path)
    }

    // MARK: Mutations

    /// Commits an inline rename. Rejects the three names the filesystem or the
    /// tree cannot survive, and says which one it was.
    func rename(_ entry: Entry, to rawName: String) {
        renaming = nil

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != entry.name else { return }

        guard !name.contains("/"), !name.contains(":") else {
            errorMessage = "A name cannot contain “/” or “:”."
            return
        }

        let parent = entry.url.deletingLastPathComponent()
        let destination = parent.appendingPathComponent(name)

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "“\(name)” already exists in \(parent.lastPathComponent)."
            return
        }

        do {
            try FileManager.default.moveItem(at: entry.url, to: destination)
        } catch {
            errorMessage = "Could not rename “\(entry.name)”. \(error.localizedDescription)"
            return
        }

        if entry.isDirectory { remap(from: entry.id, to: destination.path) }
        selection = destination.path
        reloadIfListed(parent.path)
        lastStructuralChangeAt = Date()
    }

    /// Finder's delete, not `rm`. `recycle` is reversible from the Trash, which
    /// is the only reason this is bound to a single keystroke with no
    /// confirmation sheet in front of it.
    func trash(_ entry: Entry) {
        let parent = entry.url.deletingLastPathComponent().path

        NSWorkspace.shared.recycle([entry.url]) { [weak self] _, error in
            // Reduced to a string here, on whatever queue `recycle` answers on.
            // `Error` is an existential and not `Sendable`, so it cannot cross
            // into the actor; its description can.
            let failure = error?.localizedDescription

            Task { @MainActor in
                guard let self else { return }
                if let failure {
                    self.errorMessage =
                        "Could not move “\(entry.name)” to the Trash. \(failure)"
                    return
                }
                self.forget(subtreeOf: entry.id)
                self.reloadIfListed(parent)
                self.lastStructuralChangeAt = Date()
            }
        }
    }

    func createFile(in directory: String) {
        create(in: directory, name: "untitled", isDirectory: false)
    }

    func createFolder(in directory: String) {
        create(in: directory, name: "untitled folder", isDirectory: true)
    }

    private func create(in directory: String, name: String, isDirectory: Bool) {
        let destination = uniqueDestination(for: name, in: directory)

        do {
            if isDirectory {
                try FileManager.default.createDirectory(
                    at: destination, withIntermediateDirectories: false
                )
            } else {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    errorMessage = "Could not create a file in \(URL(fileURLWithPath: directory).lastPathComponent)."
                    return
                }
            }
        } catch {
            errorMessage = "Could not create “\(name)”. \(error.localizedDescription)"
            return
        }

        // Straight into rename, like Finder: a folder called "untitled folder"
        // is not a folder anybody wanted.
        expand(directory)
        reload(directory)
        selection = destination.path
        renaming = destination.path
        lastStructuralChangeAt = Date()
    }

    /// Remembered at the moment a row starts being dragged, so a drop can tell
    /// which of the two things it is.
    ///
    /// The URLs alone cannot: a file dragged from Finder and the same file
    /// dragged from this tree arrive on the pasteboard looking identical, and
    /// the two have to behave differently — one copies, the other moves. There
    /// is no drag-end callback to clear this, so a drop that does not match
    /// clears it instead and is treated as external, which is the safe way
    /// round: the worst case is a copy where you wanted a move.
    private var internalDragPaths: Set<String> = []

    func beginInternalDrag(_ path: String) {
        internalDragPaths = [path]
    }

    /// The one entry point for a drop. Moves within the tree, copies from
    /// outside it.
    func receive(_ urls: [URL], into directory: String) {
        let dropped = Set(urls.map(\.standardizedFileURL.path))
        let isInternal = !internalDragPaths.isEmpty && internalDragPaths.isSuperset(of: dropped)
        internalDragPaths = []

        if isInternal {
            move(urls, into: directory)
        } else {
            copy(urls, into: directory)
        }
    }

    /// Files arriving from outside the tree — Finder, a browser, the Desktop.
    ///
    /// Copies rather than moves. A drag out of Finder onto a folder on the same
    /// volume is a *move* in Finder's own rules, and doing that here would mean
    /// dragging a screenshot into a project silently emptied the folder you
    /// dragged it from. Inside the tree, where both ends are visible, `move`
    /// below does the other thing.
    func copy(_ urls: [URL], into directory: String) {
        var landed: String?

        for url in urls where url.isFileURL {
            let destination = uniqueDestination(for: url.lastPathComponent, in: directory)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                landed = destination.path
            } catch {
                errorMessage = "Could not copy “\(url.lastPathComponent)”. \(error.localizedDescription)"
            }
        }

        finishDrop(into: directory, selecting: landed)
    }

    /// A row dragged onto a folder in the same tree.
    func move(_ urls: [URL], into directory: String) {
        var landed: String?

        for url in urls where url.isFileURL {
            let source = url.standardizedFileURL.path
            let parent = URL(fileURLWithPath: source).deletingLastPathComponent().path

            // Already there, or being dropped into itself or its own subtree —
            // the last of which `moveItem` would happily do, and the directory
            // would be gone.
            guard parent != directory else { continue }
            guard directory != source, !directory.hasPrefix(source + "/") else {
                errorMessage = "“\(url.lastPathComponent)” cannot be moved into itself."
                continue
            }

            let destination = uniqueDestination(for: url.lastPathComponent, in: directory)
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                forget(subtreeOf: source)
                reload(parent)
                landed = destination.path
            } catch {
                errorMessage = "Could not move “\(url.lastPathComponent)”. \(error.localizedDescription)"
            }
        }

        finishDrop(into: directory, selecting: landed)
    }

    private func finishDrop(into directory: String, selecting landed: String?) {
        dropTarget = nil
        expand(directory)
        reload(directory)
        if let landed { selection = landed }
        lastDropAt = Date()
        lastStructuralChangeAt = Date()
    }

    /// `name`, or `name 2`, `name 3`… — never an overwrite.
    ///
    /// The suffix goes before the extension, so dropping a second `logo.png`
    /// gives you `logo 2.png` and not `logo.png 2`, which no image viewer
    /// would open.
    private func uniqueDestination(for name: String, in directory: String) -> URL {
        let base = URL(fileURLWithPath: directory)
        var candidate = base.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2

        repeat {
            let next = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            candidate = base.appendingPathComponent(next)
            index += 1
        } while FileManager.default.fileExists(atPath: candidate.path)

        return candidate
    }

    // MARK: Finder and the clipboard

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}
