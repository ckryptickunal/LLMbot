import Foundation

/// Markdown split into what can be set as prose and what cannot.
///
/// The transcript used to parse with inline-only markdown, which silently destroys a fenced
/// code block: the language tag leaks into the sentence, the newlines vanish, and two commands
/// fuse into one line nobody can run. In an app whose bots write shell commands that is not a
/// cosmetic problem — it hands the user something that looks copyable and is wrong.
public enum ProseBlock: Identifiable {
    case prose(String)
    case code(language: String?, body: String)

    public var id: String {
        switch self {
        case .prose(let t):          return "p\(t.hashValue)"
        case .code(let l, let b):    return "c\(l ?? "")\(b.hashValue)"
        }
    }

    /// Splits on fenced blocks. Everything outside a fence keeps its inline markdown; a fence
    /// keeps its newlines and is never parsed as prose.
    public static func parse(_ text: String) -> [ProseBlock] {
        guard text.contains("```") else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.prose(trimmed)]
        }
        var blocks: [ProseBlock] = []
        var inFence = false
        var language: String?
        var buffer: [String] = []

        func flush() {
            let body = buffer.joined(separator: "\n")
            buffer.removeAll()
            if inFence {
                blocks.append(.code(language: language, body: body))
            } else {
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { blocks.append(.prose(trimmed)) }
            }
        }

        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                if !inFence {
                    let tag = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
                        .trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : String(tag)
                } else {
                    language = nil
                }
                inFence.toggle()
                continue
            }
            buffer.append(line)
        }
        flush()
        return blocks
    }
}

