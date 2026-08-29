import Foundation

/// Where Bot-Harness keeps things.
///
/// Everything lives under Application Support in formats the user can read without this app:
/// JSON for state, JSONL for traces, PNG for screenshots. If the app is deleted, the record
/// of what it did survives and remains legible.
public enum Paths {
    public static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Bot-Harness", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Bots, conversations, plugins, routines. One JSON document, loaded at launch.
    public static var state: URL { root.appendingPathComponent("state.json") }

    /// One directory per run. See `TraceWriter`.
    public static var traces: URL {
        let dir = root.appendingPathComponent("traces", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Installed plugin manifests and their working directories.
    public static var plugins: URL {
        let dir = root.appendingPathComponent("plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Chrome profile used by the browser tool, kept separate from the user's own profile
    /// unless they explicitly attach to theirs.
    public static var browserProfile: URL {
        let dir = root.appendingPathComponent("browser", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
