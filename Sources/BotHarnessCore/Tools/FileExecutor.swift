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
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let real = URL(fileURLWithPath: (url.path as NSString).resolvingSymlinksInPath)

        for pattern in authority.denied where matches(real.path, pattern) {
            throw FileError.denied(real.path, "it is on the never-allowed list")
        }
        let allowed = forWriting ? authority.writable : authority.readable
        guard allowed.isEmpty || allowed.contains(where: { matches(real.path, $0) }) else {
            throw FileError.denied(real.path, forWriting
                ? "this bot may only write inside its workspace"
                : "this bot may only read inside the paths you gave it")
        }
        return real
    }

    /// Glob matching for authority patterns: `~/Desktop/jewel/**`.
    private func matches(_ path: String, _ pattern: String) -> Bool {
        let expanded = (pattern as NSString).expandingTildeInPath
        if expanded.hasSuffix("/**") {
            return path.hasPrefix(String(expanded.dropLast(2)))
        }
        return path == expanded || path.hasPrefix(expanded + "/")
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
