import Foundation

/// Gemini, over the Interactions API. The primary brain.
///
/// Chosen because it is the model that officially supports driving a **desktop** — not just a
/// browser — and because it is the account the user actually has. Note what is *not* a reason:
/// which credentials happened to be lying around on the development machine. That is an
/// observation about a laptop, not a product decision, and the adapter boundary exists so it
/// can never become one.
///
/// Written with no dependencies: URLSession and JSONSerialization. See ADR 0002.
///
/// **Verification status, stated honestly.** Every field name, model ID, coordinate
/// convention and safety key below is copied from Google's live documentation
/// (`docs/research/gemini-computer-use.md`, fetched 2026-08-29). None of it has yet been
/// exercised against a real key, because none is configured. The response parser is therefore
/// deliberately forgiving and keeps the raw body on every reply, so that the first live run
/// reports exactly how the documentation and reality differ instead of failing opaquely.
public struct GeminiAdapter: BrainAdapter {

    public let name: String
    public let model: String

    /// Recommended for computer use as of 2026-08. $0.75/1M in, $3.75/1M out through
    /// 2026-12-31, then doubling.
    public static let defaultModel = "gemini-3.7-flash"

    /// Lower latency and roughly half the cost. Right for watchers and routine classification.
    public static let cheapModel = "gemini-3.5-flash-lite"

    private let endpoint = "https://generativelanguage.googleapis.com/v1beta/interactions"

    public init(model: String = GeminiAdapter.defaultModel) {
        self.model = model
        self.name = "gemini/\(model)"
    }

    public var canDriveComputer: Bool { true }

    public func isConfigured() async -> Bool { Keychain.has("gemini") }

    // MARK: - One turn

    public func step(_ request: BrainRequest) async throws -> BrainResponse {
        guard let key = Keychain.get("gemini") else {
            throw BrainError.notConfigured("Your Gemini API key")
        }

        var body: [String: Any] = [
            "model": model,
            "input": buildInput(request),
        ]

        var tools: [[String: Any]] = []

        if request.computerUse != .off {
            var computerUse: [String: Any] = [
                "type": "computer_use",
                "environment": request.computerUse == .desktop ? "desktop" : "browser",
                // Screenshot scanning for hidden adversarial instructions. On by default and
                // never exposed as a setting: content the agent reads is data, and a page that
                // tells a bot what to do does not get to.
                "enable_prompt_injection_detection": true,
            ]
            // Deliberately not sending `disabled_safety_policies`. Google's own docs note it
            // is only a preference and the model may still require confirmation — and our
            // floor is the authority regardless, so weakening theirs buys nothing.
            _ = computerUse["disabled_safety_policies"]
            tools.append(computerUse)
        }

        if !request.tools.isEmpty {
            tools.append([
                "type": "function",
                "functions": request.tools.map { tool in
                    [
                        "name": tool.id.replacingOccurrences(of: ".", with: "__"),
                        "description": tool.summary,
                        "parameters": (try? JSONSerialization.jsonObject(with: Data(tool.schema.utf8))) ?? [:],
                    ] as [String: Any]
                },
            ])
        }

        if !tools.isEmpty { body["tools"] = tools }
        if !request.system.isEmpty { body["system_instruction"] = request.system }

        var url = URLComponents(string: endpoint)!
        url.queryItems = [URLQueryItem(name: "key", value: key)]

        var http = URLRequest(url: url.url!)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = try JSONSerialization.data(withJSONObject: body)
        http.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: http)
        let text = String(data: data, encoding: .utf8) ?? ""

        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw BrainError.malformedResponse("no HTTP status")
        }
        guard (200..<300).contains(status) else {
            throw BrainError.http(status: status, body: text)
        }

        return try parse(data, raw: text)
    }

    // MARK: - Input

    /// The Interactions API takes `input` as either a string or a list of content parts.
    /// A single user turn is sent as a plain string; anything richer becomes parts.
    private func buildInput(_ request: BrainRequest) -> Any {
        var parts: [[String: Any]] = []

        if let observation = request.observation, !observation.isEmpty {
            parts.append(["text": "Current state of the computer:\n\(observation)"])
        }

        for turn in request.turns {
            switch turn.role {
            case .user:      parts.append(["text": turn.text])
            case .assistant: parts.append(["text": turn.text])
            case .tool:
                let label = turn.toolCallID.map { "Result of \($0):" } ?? "Tool result:"
                parts.append(["text": "\(label)\n\(turn.text)"])
            }
        }

        if let shot = request.screenshot {
            parts.append([
                "inline_data": ["mime_type": "image/png", "data": shot.base64EncodedString()]
            ])
        }

        if parts.count == 1, let only = parts.first, let text = only["text"] as? String {
            return text
        }
        return parts
    }

    // MARK: - Output

    /// Forgiving on purpose.
    ///
    /// Google currently ships two API surfaces that disagree with each other — the docs teach
    /// `interactions.create` with dict tools, while their own reference repository runs
    /// `models.generate_content` with typed constants — so the response may arrive in more
    /// than one shape. This walks whichever it gets, and keeps the raw body either way.
    private func parse(_ data: Data, raw: String) throws -> BrainResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrainError.malformedResponse("response was not a JSON object")
        }

        var text: String?
        var actions: [BrainAction] = []

        // Documented shape: { "steps": [ { "type": "function_call", ... } ] }
        let steps = (root["steps"] as? [[String: Any]])
            ?? (root["output"] as? [[String: Any]])
            ?? []

        for (index, step) in steps.enumerated() {
            let kind = step["type"] as? String
            if kind == "function_call" || step["name"] != nil {
                actions.append(action(from: step, index: index))
            } else if let t = step["text"] as? String {
                text = (text ?? "") + t
            }
        }

        // generate_content shape: candidates[].content.parts[].functionCall
        if actions.isEmpty, steps.isEmpty,
           let candidates = root["candidates"] as? [[String: Any]],
           let content = candidates.first?["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for (index, part) in parts.enumerated() {
                if let call = part["functionCall"] as? [String: Any] {
                    actions.append(action(from: call, index: index))
                } else if let t = part["text"] as? String {
                    text = (text ?? "") + t
                }
            }
        }

        if text == nil, let t = root["text"] as? String { text = t }

        var usage = BrainResponse.Usage()
        if let u = (root["usage"] as? [String: Any]) ?? (root["usageMetadata"] as? [String: Any]) {
            usage.promptTokens = (u["prompt_tokens"] ?? u["promptTokenCount"]) as? Int ?? 0
            usage.completionTokens = (u["completion_tokens"] ?? u["candidatesTokenCount"]) as? Int ?? 0
            usage.costUSD = Self.cost(model: model, prompt: usage.promptTokens, completion: usage.completionTokens)
        }

        return BrainResponse(text: text, actions: actions, usage: usage, raw: raw)
    }

    private func action(from step: [String: Any], index: Int) -> BrainAction {
        let name = (step["name"] as? String) ?? "unknown"
        var args = (step["arguments"] as? [String: Any]) ?? (step["args"] as? [String: Any]) ?? [:]

        let intent = args["intent"] as? String
        args.removeValue(forKey: "intent")

        var safety: BrainAction.SafetyDecision?
        if let s = args["safety_decision"] as? [String: Any] {
            safety = .init(
                decision: (s["decision"] as? String) ?? "allowed",
                explanation: (s["explanation"] as? String) ?? ""
            )
            args.removeValue(forKey: "safety_decision")
        }

        return BrainAction(
            id: (step["id"] as? String) ?? "\(name)-\(index)",
            // Function names round-trip through "__" because Gemini rejects dots in them.
            name: name.replacingOccurrences(of: "__", with: "."),
            arguments: args,
            intent: intent,
            safety: safety
        )
    }

    /// Published rates as of 2026-08-29, per million tokens. Worth re-checking: the docs note
    /// 3.7 Flash doubles on 2027-01-01.
    public static func cost(model: String, prompt: Int, completion: Int) -> Double {
        let (inRate, outRate): (Double, Double)
        switch model {
        case "gemini-3.7-flash":       (inRate, outRate) = (0.75, 3.75)
        case "gemini-3.5-flash-lite":  (inRate, outRate) = (0.30, 2.50)
        default:                       (inRate, outRate) = (0.75, 3.75)
        }
        return Double(prompt) / 1_000_000 * inRate + Double(completion) / 1_000_000 * outRate
    }
}
