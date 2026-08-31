import Foundation

/// Where Bot-Harness keeps things.
///
/// Everything lives under Application Support in formats the user can read without this app:
/// JSON for state, JSONL for traces, PNG for screenshots. If the app is deleted, the record
/// of what it did survives and remains legible.
public enum Paths {

    /// Every directory here is created owner-only.
    ///
    /// These hold the credential file, the full text of every conversation, and traces
    /// containing real commands, real paths and real file contents. Created with the default
    /// umask they were world-readable (0755), which quietly undid the care taken over the mode
    /// of the individual files inside them.
    private static func directory(_ url: URL) -> URL {
        let manager = FileManager.default
        try? manager.createDirectory(at: url, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        // Re-asserted rather than set once at creation: a directory that already existed from an
        // earlier version was made with the umask, and a mode is something you keep rather than
        // something you establish.
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    public static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory(base.appendingPathComponent("Bot-Harness", isDirectory: true))
    }()

    /// Bots, conversations, plugins, routines. One JSON document, loaded at launch.
    public static var state: URL { root.appendingPathComponent("state.json") }

    /// One directory per run. See `TraceWriter`.
    public static var traces: URL {
        directory(root.appendingPathComponent("traces", isDirectory: true))
    }

    /// Installed plugin manifests and their working directories.
    public static var plugins: URL {
        directory(root.appendingPathComponent("plugins", isDirectory: true))
    }

    /// Chrome profile used by the browser tool, kept separate from the user's own profile
    /// unless they explicitly attach to theirs.
    public static var browserProfile: URL {
        directory(root.appendingPathComponent("browser", isDirectory: true))
    }
}
