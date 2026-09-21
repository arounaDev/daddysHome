import Foundation

/// One directory, watched for "something in here changed".
///
/// The file tree used to be the only thing in Daddy that could go stale without
/// telling you: expand `src/`, let an agent write a file into it, and the rail
/// kept showing the listing from the moment you opened it. Polling every
/// expanded directory on a timer would have been the cheap fix and the wrong
/// one — `FileTreeView` already does that for handoffs and it is a directory
/// read per tick, forever, whether or not anything moved.
///
/// A kqueue on the directory's own descriptor costs nothing until the kernel
/// has something to say.
///
/// One watcher per **expanded** directory, so the number of open descriptors is
/// bounded by what is actually on screen. `FileTreeStore` cancels them as
/// folders collapse.
final class DirectoryWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    /// The queue every watcher reports on. Utility, and never the main one:
    /// a burst of writes into a directory fires this handler per write.
    private static let queue = DispatchQueue(
        label: "com.daddy.file-tree-watch", qos: .utility
    )

    /// Nil when the directory cannot be opened — it was deleted between the
    /// listing and this call, or we do not have permission to look at it.
    init?(path: String, onChange: @escaping @Sendable () -> Void) {
        // O_EVTONLY: open it to be told about it, not to read it. It does not
        // count as a reference that would stop the volume being unmounted.
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            // `.write` is the one that matters — a directory is "written" when
            // an entry is added, removed or renamed inside it. The other two
            // are about this directory itself disappearing, which the store
            // also needs to hear about.
            eventMask: [.write, .delete, .rename],
            queue: Self.queue
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
