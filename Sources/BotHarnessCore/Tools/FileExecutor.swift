import Foundation

/// Reading and writing files, inside the boundary the contract allows.
///
/// The boundary is enforced here rather than by the model being asked nicely. A model that has
/// convinced itself it may write to `~/.ssh` gets an error from this type, before anything
/// touches the disk.
public actor FileExecutor {

    private let authority: Authority

    public init(authority: Authority) { self.authority = authority }

    // MARK: - Boundary

    /// Resolve a path and check it against the contract.
    ///
    /// Symlinks are resolved *before* the check, deliberately. Without that, a symlink inside
    /// the workspace pointing at `~/.ssh` is a hole straight through the boundary, and it is
    /// exactly the kind of thing that looks like a clever workaround to a model.
    private func resolve(_ path: String, forWriting: Bool) throws -> URL {
        let expanded = PathGuard.expand(path)
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let real = URL(fileURLWithPath: (url.path as NSString).resolvingSymlinksInPath)

        // The floor is checked separately from the contract's own list, and always. A contract
        // is decodable from `state.json`, so a document written before a path joined the floor
        // would otherwise decode into an Authority that silently permits it — which is exactly
        // how a saved file from last week becomes today's hole.
        if let hit = PathGuard.denied(real.path, by: Authority.alwaysDenied) {
            throw FileError.denied(real.path, "`\(hit)` holds credentials, and no bot may read it")
        }
        if forWriting, let hit = PathGuard.denied(real.path, by: Authority.alwaysDeniedForWriting) {
            throw FileError.denied(real.path, "`\(hit)` is the app's own record and must stay as written")
        }
        if let hit = PathGuard.denied(real.path, by: authority.denied) {
            throw FileError.denied(real.path, "`\(hit)` is on the never-allowed list")
        }

        let allowed = forWriting ? authority.writable : authority.readable
        guard !allowed.isEmpty else {
            // An empty list used to mean "allow everything", which made the default `Authority()`
            // a key to the whole disk. It now means "nothing was granted", because a permission
            // system whose empty state is total access is not a permission system.
            throw FileError.denied(real.path, forWriting
                ? "this bot has no writable paths"
                : "this bot has no readable paths")
        }
        guard allowed.contains(where: { PathGuard.isInside(real.path, $0) }) else {
            throw FileError.denied(real.path, forWriting
                ? "this bot may only write inside its workspace"
                : "this bot may only read inside the paths you gave it")
        }
        return real
    }

    /// Check a path against the contract without touching it.
    ///
    /// For tools that reach the filesystem by some route other than this type — `files.search`
    /// and `files.glob` shell out to `rg` and `find` — so the boundary is stated explicitly at
    /// the call site rather than relying on the shell guard happening to catch it. Two guards
    /// agreeing is the point; one guard by accident is not.
    public func assertReadable(_ path: String) throws -> String {
        try resolve(path, forWriting: false).path
    }

    // MARK: - Operations

    public func read(_ path: String, offset: Int? = nil, limit: Int? = nil) throws -> String {
        let url = try resolve(path, forWriting: false)
        let text = try String(contentsOf: url, encoding: .utf8)
        guard offset != nil || limit != nil else { return text }
        let lines = text.components(separatedBy: .newlines)
        let start = max(0, (offset ?? 1) - 1)
        let end = limit.map { min(lines.count, start + $0) } ?? lines.count
        guard start < lines.count else { return "" }
        return lines[start..<end].enumerated()
            .map { "\(start + $0.offset + 1)\t\($0.element)" }
            .joined(separator: "\n")
    }

    public func write(_ path: String, content: String) throws -> String {
        let url = try resolve(path, forWriting: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "wrote \(content.count) characters to \(url.lastPathComponent)"
    }

    /// Replace an exact string. Preferred over rewriting a file, because it fails loudly when
    /// the file is not what the model thought it was, instead of silently discarding changes
    /// somebody else made.
    public func patch(_ path: String, find: String, replace: String) throws -> String {
        let url = try resolve(path, forWriting: true)
        let text = try String(contentsOf: url, encoding: .utf8)
        let occurrences = text.components(separatedBy: find).count - 1
        guard occurrences > 0 else {
            throw FileError.notFound("that exact text is not in \(url.lastPathComponent)")
        }
        guard occurrences == 1 else {
            throw FileError.ambiguous("that text appears \(occurrences) times in \(url.lastPathComponent) — include more surrounding context so it matches exactly once")
        }
        try text.replacingOccurrences(of: find, with: replace)
            .write(to: url, atomically: true, encoding: .utf8)
        return "patched \(url.lastPathComponent)"
    }

    public func delete(_ path: String) throws -> String {
        let url = try resolve(path, forWriting: true)
        try FileManager.default.removeItem(at: url)
        return "deleted \(url.lastPathComponent)"
    }

    public func exists(_ path: String) -> Bool {
        guard let url = try? resolve(path, forWriting: false) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public enum FileError: LocalizedError {
        case denied(String, String)
        case notFound(String)
        case ambiguous(String)

        public var errorDescription: String? {
            switch self {
            case .denied(let path, let why): return "Refused to touch \(path): \(why)."
            case .notFound(let detail):      return detail
            case .ambiguous(let detail):     return detail
            }
        }
    }
}
