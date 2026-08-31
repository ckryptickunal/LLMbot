import Foundation
import UniformTypeIdentifiers

/// Turning what a drag actually carries into file paths.
///
/// This lives in the core rather than in the composer for one reason: the test bundle links this
/// module and not the app, so logic left in a SwiftUI view cannot be checked by anything except
/// running the app and dragging a file onto it by hand. Dragging is exactly the kind of thing
/// nobody re-tests, which is how it came to be broken without anyone noticing.
///
/// **What was actually wrong, having checked.** The first theory was that
/// `provider.loadObject(ofClass: URL.self)` — what the composer used — cannot read the data
/// representation Finder registers. That theory is wrong: a test that registers a provider the way
/// Finder does passes against both the old call and this one, so the extraction was never the
/// defect. The comment is left here because a plausible-sounding wrong cause is worth recording
/// next to the real one.
///
/// The defects were the ones around it:
///
/// - **The only drop target was the composer pill** — about forty points tall, at the very bottom
///   of the window. People aim at the conversation, which is the large obvious area with the
///   messages in it, and dropping there did nothing at all. The conversation is a target now.
/// - **Only `public.file-url` was accepted**, so a path dragged out of a terminal or an editor —
///   which arrives as text — was refused.
/// - **Paths went into the draft unquoted.** Most screenshots are named "Screen Shot …", and an
///   unquoted path with a space in it reads as two paths: the bot went looking for a file called
///   "Screen" and truthfully reported it did not exist.
/// - **The same file could be attached twice**, because one drag registers a file under several
///   type identifiers.
public enum DroppedFiles {

    /// The type identifiers worth accepting on a drop.
    ///
    /// `fileURL` is what Finder sends. `url` is included because some apps promote a file URL to
    /// the more general type, and `text`/`utf8PlainText` because dragging a selection out of a
    /// terminal or an editor hands over a string that is very often a path someone means to
    /// attach.
    public static let accepted: [UTType] = [.fileURL, .url, .utf8PlainText, .text]

    /// Read a file URL out of whatever a provider is carrying.
    ///
    /// Ordered by how likely each representation is, and every branch returns a *path* rather
    /// than a URL so that a caller cannot accidentally hold a security-scoped reference it never
    /// started accessing.
    public static func path(from item: Any?) -> String? {
        switch item {
        case let url as URL:
            return normalise(url)
        case let data as Data:
            // The Finder case. A `public.file-url` item is the URL's `dataRepresentation`, not a
            // UTF-8 string, and reading it as text yields a percent-encoded mess with a scheme.
            if let url = URL(dataRepresentation: data, relativeTo: nil) { return normalise(url) }
            if let text = String(data: data, encoding: .utf8) { return path(from: text) }
            return nil
        case let text as String:
            return path(from: text)
        case let string as NSString:
            return path(from: string as String)
        default:
            return nil
        }
    }

    /// A path from a plain string, which may be a `file://` URL, a `~` path, or a bare path.
    public static func path(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            return normalise(url)
        }
        // A dragged selection is only a path if it looks like one *and* something is there. A
        // sentence of prose dropped on the composer should stay prose, not become a broken
        // attachment — so existence is the test, not shape.
        let expanded = PathGuard.expand(trimmed)
        guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) else {
            return nil
        }
        return expanded
    }

    private static func normalise(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        return path.isEmpty ? nil : path
    }

    // MARK: - How a path is written into a message

    /// Quote a path for a message only when it needs it.
    ///
    /// A path with a space in it — `~/Desktop/Screen Shot.png`, which is most screenshots — read
    /// as two paths once it was in the draft, and the bot went looking for a file called
    /// "Screen". Quoting is the difference between an attachment that works and one that fails
    /// in a way the user has to diagnose.
    public static func quoted(_ path: String) -> String {
        let needsQuoting = path.rangeOfCharacter(from: CharacterSet(charactersIn: " \t'\"\\()")) != nil
        guard needsQuoting else { return path }
        return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The line a drop adds to the draft: one path per line, each quoted if it needs it.
    public static func draftLines(for paths: [String]) -> String {
        paths.map(quoted).joined(separator: "\n")
    }

    /// Ask every provider for the best representation it has, and hand back the paths in the
    /// order they were dragged.
    ///
    /// Shared by the composer and by the conversation pane so there is one implementation of the
    /// thing that was broken, rather than two that can drift apart.
    public static func load(from providers: [NSItemProvider],
                            completion: @escaping @Sendable ([String]) -> Void) {
        let group = DispatchGroup()
        let collected = Collector()

        for (index, provider) in providers.enumerated() {
            let identifier = accepted
                .map(\.identifier)
                .first { provider.hasItemConformingToTypeIdentifier($0) }
            // Nothing recognisable: skip rather than load a representation we cannot read.
            guard let identifier else { continue }

            group.enter()
            provider.loadItem(forTypeIdentifier: identifier) { item, _ in
                if let path = path(from: item) { collected.add(path, at: index) }
                group.leave()
            }
        }

        group.notify(queue: .main) { completion(deduplicated(collected.ordered())) }
    }

    /// Gathers results from several concurrent load callbacks, keeping the drag's own order.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var byIndex: [(Int, String)] = []

        func add(_ path: String, at index: Int) {
            lock.lock(); byIndex.append((index, path)); lock.unlock()
        }
        func ordered() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return byIndex.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Drop the duplicates a single drag can produce.
    ///
    /// A Finder drag registers the same file under several type identifiers, so asking for all of
    /// them — which is what makes the drop robust — also means the same path can arrive more than
    /// once. Order is kept because the order files were dragged in is meaningful to the person
    /// who dragged them.
    public static func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}
