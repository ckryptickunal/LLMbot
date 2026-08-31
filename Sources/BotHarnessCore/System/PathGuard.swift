import Foundation

/// One place where a path is turned into something comparable, and one place where two paths are
/// compared. Every guard in the app calls this and nothing rolls its own.
///
/// It exists because the same three mistakes were made independently in `FileExecutor`,
/// `ShellFloor` and `ShellExecutor`, and each one was a hole:
///
/// 1. **Case.** Every comparison used `==` / `hasPrefix` / `contains` on raw strings, but the
///    home volume here is APFS **case-insensitive**. `cat ~/.SSH/id_rsa` reads the private key
///    the floor believes it is protecting. Comparisons here fold case, which over-denies on a
///    case-sensitive volume — the safe direction for a deny list.
/// 2. **`$HOME` in the middle.** The old `expand` substituted `$HOME` only as a strict *prefix*,
///    so `curl --data-binary "@$HOME/…/credentials.json"` never expanded and never matched. The
///    leading `@` was enough to defeat the whole guard. Substitution here happens anywhere in
///    the string.
/// 3. **Only the file, never its container.** A deny pattern naming a file matched the file and
///    things below it, so `cp -r "$HOME/Library/Application Support/Bot-Harness" /tmp/x` copied
///    the keys without ever naming them. `isAncestor` exists for exactly that, and is applied to
///    bulk commands only — extending it to every command would deny `ls ~`.
public enum PathGuard {

    // MARK: - Expansion

    /// Substitute `~` and `$HOME` wherever they appear, not only at the start.
    ///
    /// Deliberately does *not* try to be a shell. Runtime assembly (`P=$HOME; cat $P/…`) still
    /// gets through, and no amount of string work fixes that — `Authority` on the executor is
    /// what catches those, which is why this is one guard of several and not the guard.
    public static func expand(_ path: String) -> String {
        let home = NSHomeDirectory()
        var out = path

        for form in ["${HOME}", "$HOME"] {
            out = out.replacingOccurrences(of: form, with: home)
        }
        // `~` only counts as home at the start of a path segment, so `foo~bar` is left alone.
        if out == "~" { return home }
        if out.hasPrefix("~/") { out = home + out.dropFirst(1) }
        out = out.replacingOccurrences(of: "=~/", with: "=" + home + "/")
        out = out.replacingOccurrences(of: "@~/", with: "@" + home + "/")
        out = out.replacingOccurrences(of: ":~/", with: ":" + home + "/")
        return out
    }

    /// The form two paths are compared in: expanded, `.`/`..` collapsed, symlinks resolved where
    /// they already exist, trailing slash dropped, case folded.
    public static func canonical(_ path: String) -> String {
        let expanded = expand(path)
        guard !expanded.isEmpty else { return "" }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let resolved = (standardized as NSString).resolvingSymlinksInPath
        var out = resolved
        while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out.lowercased()
    }

    /// Whether a pattern is a *name prefix* — `…/credentials.json.**` — rather than a subtree.
    ///
    /// The distinction is not cosmetic. `scripts/set-key.sh` writes
    /// `credentials.json.<random>.tmp`, a complete plaintext copy of every key, and a deny entry
    /// naming it can only be a prefix. Written as a subtree pattern it silently matched nothing:
    /// the rule looked present, read correctly to anyone auditing the list, and protected
    /// exactly zero files. A test now asserts the real file name rather than the pattern.
    static func isNamePrefix(_ pattern: String) -> Bool {
        let p = expand(pattern)
        guard p.hasSuffix("*") else { return false }
        return !p.hasSuffix("/**") && !p.hasSuffix("/*")
    }

    /// The literal part of a pattern, with any wildcard suffix removed.
    public static func stem(of pattern: String) -> String {
        var p = expand(pattern)
        if p.hasSuffix("/**") { p = String(p.dropLast(3)) }
        else if p.hasSuffix("/*") { p = String(p.dropLast(2)) }
        else { while p.hasSuffix("*") { p.removeLast() } }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: - Comparison

    /// Is `path` the pattern itself, or inside it? Allow-list semantics.
    ///
    /// Compares whole path components, so `~/.ssh` does not match `~/.sshhh` — a plain
    /// `hasPrefix` on the raw string would.
    public static func isInside(_ path: String, _ pattern: String) -> Bool {
        let p = canonical(path)
        guard !p.isEmpty else { return false }

        if isNamePrefix(pattern) {
            // `…/credentials.json.` matches `…/credentials.json.abc.tmp`. Compared without
            // standardising the stem as a path, because it is half a file name rather than one.
            let prefix = canonical_text(stem(of: pattern))
            return !prefix.isEmpty && p.hasPrefix(prefix)
        }

        let s = canonical(stem(of: pattern))
        guard !s.isEmpty else { return false }
        if s == "/" { return true }
        return p == s || p.hasPrefix(s + "/")
    }

    /// Is `path` a *container* of the pattern? `~/Library/Application Support` is an ancestor of
    /// the credential file, and copying it copies the keys.
    ///
    /// Only for bulk operations. Applying it to every command would refuse `ls ~`, and a guard
    /// that refuses ordinary work is one people learn to route around.
    public static func isAncestor(_ path: String, of pattern: String) -> Bool {
        let p = canonical(path)
        let s = canonical(stem(of: pattern))
        guard !p.isEmpty, !s.isEmpty, p != s else { return false }
        return s.hasPrefix(p + "/")
    }

    /// Does this operand mention the protected path *anywhere* inside it?
    ///
    /// Containment rather than equality, because a real command wraps the path in punctuation the
    /// parser keeps: `@/Users/…/credentials.json`, `if=/Users/…`, `--data=@/Users/…`,
    /// `user@host:/Users/…`. Safe from false positives because the needle is a full absolute
    /// path, not a file name — a project's own `credentials.json` cannot contain it.
    public static func mentions(_ text: String, _ pattern: String) -> Bool {
        let haystack = canonical_text(text)
        let needle = canonical(stem(of: pattern))
        guard needle.count > 1 else { return false }
        return haystack.contains(needle)
    }

    /// Case-folded, shell-unquoted text for scanning a whole command line. Not a path, so it is
    /// not standardized — only unescaped and folded.
    public static func canonical_text(_ text: String) -> String {
        expand(text)
            .replacingOccurrences(of: "\\ ", with: " ")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .lowercased()
    }

    // MARK: - Deny evaluation

    /// The one call a guard makes: does `candidate` touch anything on `patterns`?
    ///
    /// `bulk` widens the test to containers, for commands that copy or archive whole trees.
    public static func denied(_ candidate: String, by patterns: [String], bulk: Bool = false) -> String? {
        for pattern in patterns {
            if isInside(candidate, pattern) { return stem(of: pattern) }
            if bulk && isAncestor(candidate, of: pattern) { return stem(of: pattern) }
        }
        return nil
    }
}
