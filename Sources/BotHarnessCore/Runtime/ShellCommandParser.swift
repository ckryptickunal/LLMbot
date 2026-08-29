import Foundation

// A small POSIX-shell reader, written so that the safety floor can judge what a command *is*
// rather than what its text happens to spell.
//
// The floor used to match substrings against the command. That misses everything a shell
// considers equivalent: `rm -fr /` is `rm -rf /` with the flags the other way round, and
// `rm -rf "$HOME"` names your home directory without the character `~` appearing anywhere.
// It also has no way to see a redirect or a pipe, so `echo k >> ~/.ssh/authorized_keys` and
// `curl … | sh` read as ordinary text. See `docs/decisions/0010-parse-shell-before-judging-it.md`.
//
// This is deliberately not a shell. It never expands anything and it never runs anything. It
// answers three questions: which programs would run, what were they handed, and where does
// output go. Anything it cannot answer it reports as unreadable, which the floor treats as a
// reason to ask rather than as a reason to proceed.

// MARK: - What a parse produces

/// One argument, with the part that matters for safety: whether its value is knowable.
public struct ShellArgument: Equatable, Sendable {

    public enum Kind: String, Sendable {
        /// A plain word, or a quoted string with nothing interpolated. `value` is exact.
        case literal
        /// Contains `$VAR` or `${VAR}`. The real value is not knowable here.
        case variable
        /// Contains `$(…)` or backticks. The real value is the output of another command.
        case substitution
    }

    public let kind: Kind
    /// Quotes removed; variables and substitutions left as written, since they cannot be
    /// resolved without running something.
    public let value: String
    /// Exactly as it appeared, for showing a person.
    public let raw: String

    /// True when the value cannot be determined without executing something. A dangerous verb
    /// pointed at an unknowable target is more alarming than one pointed at a known path, not
    /// less, and this is what lets the floor say so.
    public var isDynamic: Bool { kind != .literal }

    public init(kind: Kind, value: String, raw: String) {
        self.kind = kind; self.value = value; self.raw = raw
    }
}

/// Where a command's output goes, or where its input comes from.
public struct ShellRedirect: Equatable, Sendable {
    /// The operator as written: `>`, `>>`, `2>`, `&>`, `<`, `<<`.
    public let op: String
    /// The file descriptor written before the operator, if any. `2>` gives 2.
    public let fileDescriptor: Int?
    public let target: ShellArgument
    /// True for anything that writes to its target.
    public let writes: Bool
    public let appends: Bool

    /// `2>/dev/null` is a redirect and is not interesting. Being able to say so is the
    /// difference between a rule people keep and a rule people turn off.
    public var isDevNull: Bool { target.value == "/dev/null" }
}

/// One program that would run, with its arguments already sorted into flags and operands.
public struct ShellCommand: Equatable, Sendable {
    /// The program name with any path removed, so `/bin/rm` and `rm` are the same thing.
    public let executable: String
    /// The executable exactly as written, path and all.
    public let executableRaw: String
    public let arguments: [ShellArgument]
    public let redirects: [ShellRedirect]

    /// Short flags exploded and long flags kept whole, both without leading dashes: `-rf`,
    /// `-fr`, `-r -f` and `--recursive --force` all contain `r`/`f` or `recursive`/`force`.
    /// This is what makes flag order and flag spelling stop mattering.
    public let flags: Set<String>
    /// The arguments that are not flags — what the command is pointed at.
    public let operands: [ShellArgument]

    /// Which pipeline this belongs to, and where in it. `curl x | sh` is one pipeline of two,
    /// which is the only way to see that the second one is being fed by the first.
    public let pipeline: Int
    public let positionInPipeline: Int

    /// True when this command was found inside `$(…)`, backticks, or a `sh -c` string rather
    /// than at the top level. Still a command that would run.
    public let nested: Bool

    public func hasFlag(_ names: String...) -> Bool { names.contains { flags.contains($0) } }
}

/// Everything the floor gets to look at.
public struct ShellParse: Sendable {

    /// False when the text could not be read with confidence. **The only correct response to
    /// this is to ask a person.** It is a separate value rather than an empty result because
    /// "I found nothing dangerous" and "I could not tell" must never be the same answer.
    public let readable: Bool
    /// Why it could not be read, for the approval prompt.
    public let unreadableReason: String?

    public let commands: [ShellCommand]
    public let redirects: [ShellRedirect]

    public var hasSubstitution: Bool { commands.contains { $0.nested } }

    /// True when every redirect in the command goes to `/dev/null`, so none of them is a write
    /// anyone should be asked about.
    public var allRedirectsAreDevNull: Bool {
        let writes = redirects.filter(\.writes)
        return !writes.isEmpty && writes.allSatisfy(\.isDevNull)
    }

    /// The commands in `pipeline`, in order.
    public func pipelineMembers(_ pipeline: Int) -> [ShellCommand] {
        commands.filter { $0.pipeline == pipeline }.sorted { $0.positionInPipeline < $1.positionInPipeline }
    }

    static func unreadable(_ reason: String) -> ShellParse {
        ShellParse(readable: false, unreadableReason: reason, commands: [], redirects: [])
    }
}

// MARK: - The parser

public enum ShellCommandParser {

    /// Programs that stand in front of the real command. `sudo rm -rf /` is both a privilege
    /// escalation and a recursive delete, and the floor has to see both, so the wrapper is
    /// recorded *and* the command behind it is unwrapped.
    private static let wrappers: Set<String> = [
        "sudo", "doas", "su", "env", "nohup", "time", "command", "builtin", "exec",
        "nice", "ionice", "stdbuf", "xargs", "timeout", "caffeinate", "script",
    ]

    /// Programs that take a program in a string argument. Whatever is in that string would run.
    private static let interpretersWithInlineCode: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "ruby", "perl",
        "node", "deno", "bun", "osascript",
    ]

    private static let maxDepth = 4

    public static func parse(_ source: String) -> ShellParse {
        var pipelineCounter = 0
        var collected: [ShellCommand] = []
        do {
            try parse(source, depth: 0, nested: false,
                      pipelineCounter: &pipelineCounter, into: &collected)
        } catch let error as ParseFailure {
            return .unreadable(error.reason)
        } catch {
            return .unreadable("it could not be read")
        }
        return ShellParse(readable: true, unreadableReason: nil,
                          commands: collected,
                          redirects: collected.flatMap(\.redirects))
    }

    private struct ParseFailure: Error { let reason: String }

    // MARK: Tokens

    private enum Token: Equatable {
        case word(ShellArgument)
        /// A control operator that separates commands: `;` `&` `&&` `||` newline.
        case separator(String)
        /// `|` — the next command is fed by this one.
        case pipe
        /// A redirect operator, with its file descriptor if one was written.
        case redirect(op: String, fd: Int?)
        case openSubshell
        case closeSubshell
    }

    // MARK: Tokenizing

    private static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(source)
        var i = 0

        var value = ""          // quotes removed
        var raw = ""            // exactly as written
        var kind = ShellArgument.Kind.literal
        var open = false        // a word is being accumulated

        func flush() {
            guard open else { return }
            tokens.append(.word(ShellArgument(kind: kind, value: value, raw: raw)))
            value = ""; raw = ""; kind = .literal; open = false
        }
        // A variable beats a literal; a substitution beats both, because it is the least
        // knowable and the floor should describe a word by its most uncertain part.
        func promote(_ new: ShellArgument.Kind) {
            if new == .substitution || (new == .variable && kind == .literal) { kind = new }
        }

        while i < chars.count {
            let c = chars[i]

            switch c {
            case "\\":
                guard i + 1 < chars.count else { throw ParseFailure(reason: "it ends in a backslash") }
                open = true; value.append(chars[i + 1]); raw += "\\\(chars[i + 1])"; i += 2

            case "'":
                // Single quotes are literal all the way to the next single quote.
                guard let end = chars[(i + 1)...].firstIndex(of: "'") else {
                    throw ParseFailure(reason: "it has an unclosed quote")
                }
                open = true
                let body = String(chars[(i + 1)..<end])
                value += body; raw += "'\(body)'"; i = end + 1

            case "\"":
                // Double quotes interpolate, so the contents still have to be scanned.
                var j = i + 1
                var body = ""
                var closed = false
                while j < chars.count {
                    if chars[j] == "\\", j + 1 < chars.count { body.append(chars[j + 1]); j += 2; continue }
                    if chars[j] == "\"" { closed = true; break }
                    if chars[j] == "$" { promote(chars[safe: j + 1] == "(" ? .substitution : .variable) }
                    if chars[j] == "`" { promote(.substitution) }
                    body.append(chars[j]); j += 1
                }
                guard closed else { throw ParseFailure(reason: "it has an unclosed quote") }
                open = true; value += body; raw += "\"\(body)\""; i = j + 1

            case "$":
                open = true
                if chars[safe: i + 1] == "(" {
                    let end = try matching(chars, from: i + 1, open: "(", close: ")")
                    let inner = String(chars[(i + 2)..<end])
                    promote(.substitution)
                    value += "$(\(inner))"; raw += "$(\(inner))"
                    i = end + 1
                } else {
                    promote(.variable)
                    var j = i + 1
                    if chars[safe: j] == "{" {
                        guard let close = chars[j...].firstIndex(of: "}") else {
                            throw ParseFailure(reason: "it has an unclosed ${")
                        }
                        j = close + 1
                    } else {
                        while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                    }
                    let text = String(chars[i..<j])
                    value += text; raw += text; i = j
                }

            case "`":
                let end = try matching(chars, from: i, open: "`", close: "`")
                let inner = String(chars[(i + 1)..<end])
                open = true; promote(.substitution)
                value += "`\(inner)`"; raw += "`\(inner)`"; i = end + 1

            case " ", "\t":
                flush(); i += 1

            case "\n", ";":
                flush(); tokens.append(.separator(String(c))); i += 1

            case "&":
                // `&>` is a redirect; `&&` and a bare `&` are separators.
                if chars[safe: i + 1] == ">" {
                    flush(); tokens.append(.redirect(op: "&>", fd: nil)); i += 2
                } else if chars[safe: i + 1] == "&" {
                    flush(); tokens.append(.separator("&&")); i += 2
                } else {
                    flush(); tokens.append(.separator("&")); i += 1
                }

            case "|":
                if chars[safe: i + 1] == "|" { flush(); tokens.append(.separator("||")); i += 2 }
                else { flush(); tokens.append(.pipe); i += 1 }

            case ">", "<":
                // A word of digits touching the operator is a file descriptor: `2>`.
                var fd: Int?
                if open, kind == .literal, !value.isEmpty, value.allSatisfy(\.isNumber) {
                    fd = Int(value); value = ""; raw = ""; open = false
                }
                flush()
                var op = String(c)
                if chars[safe: i + 1] == c { op += String(c); i += 1 }            // >> or <<
                else if chars[safe: i + 1] == "&" { op += "&"; i += 1 }           // >& or <&
                if op == "<<", chars[safe: i + 1] == "<" { op += "<"; i += 1 }    // <<<
                tokens.append(.redirect(op: op, fd: fd))
                i += 1

            case "(":
                flush(); tokens.append(.openSubshell); i += 1
            case ")":
                flush(); tokens.append(.closeSubshell); i += 1

            default:
                open = true; value.append(c); raw.append(c); i += 1
            }
        }
        flush()
        return tokens
    }

    /// Index of the delimiter that closes the one at `from`, counting nesting.
    private static func matching(_ chars: [Character], from: Int,
                                 open: Character, close: Character) throws -> Int {
        var depth = 0
        var i = from
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if open != close, chars[i] == open { depth += 1 }
            else if chars[i] == close {
                if open == close { if i > from { return i } }   // backticks do not nest
                else { depth -= 1; if depth == 0 { return i } }
            }
            i += 1
        }
        throw ParseFailure(reason: "it has an unclosed \(open)")
    }

    // MARK: Assembling commands

    private static func parse(_ source: String, depth: Int, nested: Bool,
                              pipelineCounter: inout Int,
                              into out: inout [ShellCommand]) throws {
        guard depth <= maxDepth else { throw ParseFailure(reason: "it nests too deeply to read") }

        let tokens = try tokenize(source)
        var words: [ShellArgument] = []
        var redirects: [ShellRedirect] = []
        var pipeline = { pipelineCounter += 1; return pipelineCounter }()
        var position = 0
        var subshellDepth = 0
        var subshellText = ""

        func finish() throws {
            defer { words = []; redirects = [] }
            guard !words.isEmpty else { return }
            try emit(words: words, redirects: redirects, pipeline: pipeline, position: position,
                     depth: depth, nested: nested, pipelineCounter: &pipelineCounter, into: &out)
            position += 1
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]

            // A subshell is collected whole and read on its own.
            if subshellDepth > 0 {
                switch token {
                case .openSubshell: subshellDepth += 1; subshellText += "("
                case .closeSubshell:
                    subshellDepth -= 1
                    if subshellDepth == 0 {
                        try parse(subshellText, depth: depth + 1, nested: true,
                                  pipelineCounter: &pipelineCounter, into: &out)
                        subshellText = ""
                    } else { subshellText += ")" }
                case .word(let w): subshellText += " \(w.raw) "
                case .pipe: subshellText += " | "
                case .separator(let s): subshellText += " \(s) "
                case .redirect(let op, let fd): subshellText += " \(fd.map(String.init) ?? "")\(op) "
                }
                index += 1
                continue
            }

            switch token {
            case .openSubshell:
                subshellDepth = 1
            case .closeSubshell:
                throw ParseFailure(reason: "it has an unmatched )")
            case .word(let w):
                words.append(w)
            case .redirect(let op, let fd):
                guard case .word(let target)? = tokens[safe: index + 1] else {
                    // `2>&1` leaves nothing to consume; that is fine and is not a file write.
                    redirects.append(ShellRedirect(op: op, fileDescriptor: fd,
                                                   target: ShellArgument(kind: .literal, value: "", raw: ""),
                                                   writes: false, appends: false))
                    index += 1
                    continue
                }
                let writes = op.hasPrefix(">") || op == "&>"
                redirects.append(ShellRedirect(op: op, fileDescriptor: fd, target: target,
                                              writes: writes, appends: op == ">>"))
                index += 1                                      // the target is not an argument
            case .pipe:
                try finish()                                    // same pipeline, next position
            case .separator:
                try finish()
                pipeline = { pipelineCounter += 1; return pipelineCounter }()
                position = 0
            }
            index += 1
        }
        guard subshellDepth == 0 else { throw ParseFailure(reason: "it has an unclosed (") }
        try finish()
    }

    /// Turn one run of words into a command — unwrapping wrappers and reading inline code.
    private static func emit(words: [ShellArgument], redirects: [ShellRedirect],
                             pipeline: Int, position: Int, depth: Int, nested: Bool,
                             pipelineCounter: inout Int,
                             into out: inout [ShellCommand]) throws {
        var words = words

        // `FOO=bar cmd` — leading assignments are not the command.
        while let first = words.first,
              first.kind == .literal,
              first.value.contains("="),
              !first.value.hasPrefix("="),
              first.value.prefix(while: { $0 != "=" }).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            words.removeFirst()
        }
        guard let head = words.first else { return }

        let executable = String(head.value.split(separator: "/").last ?? "")
        let rest = Array(words.dropFirst())

        var flags: Set<String> = []
        var operands: [ShellArgument] = []
        var afterDoubleDash = false
        for argument in rest {
            if afterDoubleDash { operands.append(argument); continue }
            if argument.kind == .literal, argument.value == "--" { afterDoubleDash = true; continue }
            if argument.kind == .literal, argument.value.hasPrefix("--"), argument.value.count > 2 {
                flags.insert(String(argument.value.dropFirst(2).prefix(while: { $0 != "=" })))
            } else if argument.kind == .literal, argument.value.hasPrefix("-"), argument.value.count > 1 {
                // Short flags are a bag of letters, which is what makes -rf and -fr identical.
                for letter in argument.value.dropFirst() where letter.isLetter { flags.insert(String(letter)) }
                // …and the whole word as well, because not every single-dash option is a bag
                // of letters: `find -delete` and `git branch -D` are one option each, and
                // exploding them into d/e/l/t would lose the only part that mattered.
                flags.insert(String(argument.value.dropFirst()))
            } else {
                operands.append(argument)
            }
        }

        out.append(ShellCommand(executable: executable, executableRaw: head.value,
                                arguments: rest, redirects: redirects,
                                flags: flags, operands: operands,
                                pipeline: pipeline, positionInPipeline: position,
                                nested: nested))

        // Whatever is hiding behind a wrapper still runs.
        if wrappers.contains(executable), !rest.isEmpty {
            try emit(words: rest, redirects: [], pipeline: pipeline, position: position,
                     depth: depth + 1, nested: nested, pipelineCounter: &pipelineCounter, into: &out)
        }

        // `sh -c "…"` and friends: the string is a program.
        if interpretersWithInlineCode.contains(executable),
           let flagIndex = rest.firstIndex(where: { $0.kind == .literal && ($0.value == "-c" || $0.value == "-e") }),
           let code = rest[safe: flagIndex + 1], depth < maxDepth {
            try parse(code.value, depth: depth + 1, nested: true,
                      pipelineCounter: &pipelineCounter, into: &out)
        }

        // Anything inside $(…) or backticks runs too.
        for argument in words where argument.kind == .substitution {
            for inner in innerSubstitutions(argument.value) where depth < maxDepth {
                try parse(inner, depth: depth + 1, nested: true,
                          pipelineCounter: &pipelineCounter, into: &out)
            }
        }
    }

    /// The bodies of every `$(…)` and backtick pair in a word.
    private static func innerSubstitutions(_ text: String) -> [String] {
        var found: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "$", chars[safe: i + 1] == "(",
               let end = try? matching(chars, from: i + 1, open: "(", close: ")") {
                found.append(String(chars[(i + 2)..<end])); i = end + 1; continue
            }
            if chars[i] == "`", let end = try? matching(chars, from: i, open: "`", close: "`") {
                found.append(String(chars[(i + 1)..<end])); i = end + 1; continue
            }
            i += 1
        }
        return found
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
