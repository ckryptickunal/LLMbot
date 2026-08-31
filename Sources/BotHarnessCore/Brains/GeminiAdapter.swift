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
/// **Verified against the live API on 2026-08-29**, and the documentation was wrong in three
/// places that each would have broken the product silently:
///
/// 1. **Function tools are one-per-entry with the name at the top level** —
///    `{"type":"function","name":…,"description":…,"parameters":…}`. The nested
///    `{"function":{…}}` form and the older `function_declarations` array are both rejected.
/// 2. **Replies arrive as `model_output` with a `content` array**, not as a `text` field. A
///    parser looking for `step["text"]` finds nothing, so every reply the model made would
///    have been dropped and the conversation would have looked dead.
/// 3. **Usage keys are `total_input_tokens` / `total_output_tokens` / `total_tokens`**, not
///    `prompt_tokens` or `promptTokenCount`, so cost and token accounting read zero.
///
/// Conversations continue with `previous_interaction_id` rather than by resending history,
/// which is both cheaper and what the server expects.
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

    public func isConfigured() async -> Bool { CredentialStore.has("gemini") }

    // MARK: - One turn

    public func step(_ request: BrainRequest) async throws -> BrainResponse {
        guard let key = CredentialStore.get("gemini") else {
            throw BrainError.notConfigured("Your Gemini API key")
        }

        var body: [String: Any] = [
            "model": model,
            "input": buildInput(request),
        ]

        // Continue the server-side conversation rather than resending it. Cheaper, and it is
        // how the API expects multi-turn work to proceed.
        if let previous = request.previousInteractionID {
            body["previous_interaction_id"] = previous
        }

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

        // One entry per function, name at the top level. Verified: the nested
        // {"type":"function","function":{…}} form returns
        // "Unknown parameter 'function' at 'tools[0]'".
        for tool in request.tools {
            tools.append([
                "type": "function",
                // Dots are rejected in function names, so they round-trip through "__".
                "name": tool.id.replacingOccurrences(of: ".", with: "__"),
                "description": tool.summary,
                "parameters": (try? JSONSerialization.jsonObject(with: Data(tool.schema.utf8))) ?? [:],
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
    func buildInput(_ request: BrainRequest) -> Any {
        var parts: [[String: Any]] = []
        // When continuing, send only what is new — the server already has the history.
        //
        // "New" is everything after the last assistant turn, not `suffix(1)`. A single model turn
        // can return several function calls, and the loop appends one `.tool` turn per result —
        // so taking only the last one silently dropped every result but one, and the model was
        // left to reason about calls it never saw answered. The assistant turn is the boundary
        // because it is the last thing the server itself produced.
        let turns: [BrainTurn]
        if request.previousInteractionID == nil {
            turns = request.turns
        } else if let boundary = request.turns.lastIndex(where: { $0.role == .assistant }) {
            turns = Array(request.turns[request.turns.index(after: boundary)...])
        } else {
            turns = request.turns
        }

        // Every part carries a type. Without it the API answers
        // "Provide a 'role' field (for Turn[]), or a 'type' field (for Step[])".
        if let observation = request.observation, !observation.isEmpty {
            parts.append(["type": "text", "text": "Current state of the computer:\n\(observation)"])
        }

        for turn in turns {
            switch turn.role {
            case .user:      parts.append(["type": "text", "text": turn.text])
            case .assistant: parts.append(["type": "text", "text": turn.text])
            case .tool:
                let label = turn.toolCallID.map { "Result of \($0):" } ?? "Tool result:"
                parts.append(["type": "text", "text": "\(label)\n\(turn.text)"])
            }
        }

        if let shot = request.screenshot {
            parts.append(["type": "image", "mime_type": "image/png",
                          "data": shot.base64EncodedString()])
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

        for (index, step) in ((root["steps"] as? [[String: Any]]) ?? []).enumerated() {
            switch step["type"] as? String {
            case "function_call":
                actions.append(action(from: step, index: index))

            case "model_output", "message", "content":
                // Replies are a content array of typed parts, not a plain string.
                if let content = step["content"] as? [[String: Any]] {
                    let joined = content.compactMap { $0["text"] as? String }.joined()
                    if !joined.isEmpty { text = (text ?? "") + joined }
                } else if let t = step["text"] as? String {
                    text = (text ?? "") + t
                }

            case "thought":
                // An opaque signature, not readable reasoning. Nothing to show or store.
                continue

            default:
                if let t = step["text"] as? String { text = (text ?? "") + t }
            }
        }

        var usage = BrainResponse.Usage()
        if let u = root["usage"] as? [String: Any] {
            usage.promptTokens = (u["total_input_tokens"] as? Int) ?? 0
            usage.completionTokens = (u["total_output_tokens"] as? Int) ?? 0
            usage.costUSD = Self.cost(model: model, prompt: usage.promptTokens,
                                      completion: usage.completionTokens)
        }

        return BrainResponse(text: text, actions: actions, usage: usage,
                             interactionID: root["id"] as? String,
                             needsAction: (root["status"] as? String) == "requires_action",
                             raw: raw)
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
