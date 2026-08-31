import Foundation

/// A Model Context Protocol client, in about four hundred lines of Foundation.
///
/// This is the piece that turns a long list of hoped-for integrations into real ones. Five MCP
/// servers are already configured on this machine — Perplexity, Lightroom, Magic over stdio,
/// Framer and Figma Desktop over HTTP — and none of them were reachable from Bot-Harness
/// because it had no way to speak the protocol. Everything downstream of this file (the
/// capability registry, the resolver, the Connections screen) is only as real as this is.
///
/// Written against the wire format rather than adopting an SDK, for the reason in ADR 0002 and
/// one more: the official Swift SDK is a full spec revision behind with no release in months,
/// so adopting it would mean inheriting its lag as well as its dependency.
///
/// Two transports, because that is what the configured servers actually use:
/// - **stdio** — spawn the process, exchange newline-delimited JSON-RPC on its pipes.
/// - **HTTP** — POST JSON-RPC, accepting either a JSON body or an SSE stream in reply.

// MARK: - Configuration

public struct MCPServerConfig: Identifiable, Sendable, Hashable {
    public var id: String
    public var transport: Transport

    public enum Transport: Sendable, Hashable {
        case stdio(command: String, args: [String], env: [String: String])
        case http(url: URL, headers: [String: String])
    }

    public init(id: String, transport: Transport) {
        self.id = id
        self.transport = transport
    }

    /// Read the servers configured for Claude Code on this machine.
    ///
    /// Deliberately reuses that file rather than inventing a second place to configure the
    /// same servers. A user who has already made Perplexity work once should not have to do
    /// it again, and `~/.claude.json` is where they did it.
    ///
    /// Secrets in that file are read at spawn time and never copied anywhere else.
    public static func fromClaudeConfig(at path: String = NSHomeDirectory() + "/.claude.json") -> [MCPServerConfig] {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: [String: Any]]
        else { return [] }

        return servers.compactMap { name, spec in
            let kind = (spec["type"] as? String) ?? (spec["url"] != nil ? "http" : "stdio")
            switch kind {
            case "http", "sse":
                guard let raw = spec["url"] as? String, let url = URL(string: raw) else { return nil }
                return MCPServerConfig(id: name, transport: .http(
                    url: url, headers: (spec["headers"] as? [String: String]) ?? [:]))
            default:
                guard let command = spec["command"] as? String else { return nil }
                return MCPServerConfig(id: name, transport: .stdio(
                    command: command,
                    args: (spec["args"] as? [String]) ?? [],
                    env: (spec["env"] as? [String: String]) ?? [:]))
            }
        }
        .sorted { $0.id < $1.id }
    }
}

// MARK: - What a server offers

public struct MCPTool: Sendable, Hashable {
    public var name: String
    public var description: String
    /// JSON Schema for the arguments, as a string.
    public var schema: String
}

// MARK: - The client

public actor MCPClient {

    public let config: MCPServerConfig
    public private(set) var tools: [MCPTool] = []
    public private(set) var serverName: String?
    public private(set) var lastError: String?
    public private(set) var isConnected = false

    private var process: Process?
    private var toServer: FileHandle?
    private var fromServer: FileHandle?
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1
    private var readBuffer = Data()

    /// Protocol versions to offer, newest first. A server that rejects one usually names the
    /// version it wants, but offering a short ladder is cheaper than parsing that.
    private static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public init(config: MCPServerConfig) {
        self.config = config
    }

    // MARK: Connecting

    public func connect(timeout: TimeInterval = 30) async throws {
        guard !isConnected else { return }
        do {
            switch config.transport {
            case .stdio: try startProcess()
            case .http:  break   // stateless; nothing to hold open
            }
            let result = try await initializeHandshake(timeout: timeout)
            serverName = ((result["serverInfo"] as? [String: Any])?["name"] as? String) ?? config.id
            isConnected = true
            lastError = nil
            tools = try await fetchTools()
        } catch {
            lastError = error.localizedDescription
            await disconnect()
            throw error
        }
    }

    public func disconnect() async {
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError.disconnected)
        }
        pending.removeAll()
        process?.terminate()
        process = nil
        toServer = nil
        fromServer = nil
        isConnected = false
    }

    // MARK: Calling

    /// Invoke a tool. Returns its output flattened to text, which is what a language model
    /// can actually use — MCP results are an array of typed content blocks.
    public func call(_ name: String, arguments: [String: Any], timeout: TimeInterval = 120) async throws -> String {
        let result = try await request("tools/call",
                                       params: ["name": name, "arguments": arguments],
                                       timeout: timeout)

        if let isError = result["isError"] as? Bool, isError {
            throw MCPError.toolFailed(flatten(result))
        }
        return flatten(result)
    }

    private func flatten(_ result: [String: Any]) -> String {
        guard let content = result["content"] as? [[String: Any]] else {
            return String(describing: result["structuredContent"] ?? result)
        }
        return content.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text":     return block["text"] as? String
            case "image":    return "[image: \((block["mimeType"] as? String) ?? "image")]"
            case "resource": return (block["resource"] as? [String: Any])?["text"] as? String
            default:         return nil
            }
        }.joined(separator: "\n")
    }

    private func fetchTools() async throws -> [MCPTool] {
        let result = try await request("tools/list", params: [:], timeout: 30)
        guard let list = result["tools"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let schema = entry["inputSchema"] as? [String: Any] ?? [:]
            let encoded = (try? JSONSerialization.data(withJSONObject: schema))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return MCPTool(name: name,
                           description: (entry["description"] as? String) ?? name,
                           schema: encoded)
        }
    }

    // MARK: Handshake

    private func initializeHandshake(timeout: TimeInterval) async throws -> [String: Any] {
        var lastFailure: Error = MCPError.noResponse
        for version in Self.protocolVersions {
            do {
                let result = try await request("initialize", params: [
                    "protocolVersion": version,
                    "capabilities": ["tools": [:] as [String: Any]],
                    "clientInfo": ["name": "Bot-Harness", "version": "0.1"],
                ], timeout: timeout)
                // Servers expect this notification before any other call.
                try? await notify("notifications/initialized")
                return result
            } catch {
                lastFailure = error
            }
        }
        throw lastFailure
    }

    // MARK: JSON-RPC

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let envelope: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]

        switch config.transport {
        case .stdio:
            let body = try JSONSerialization.data(withJSONObject: envelope)
            return try await withThrowingTaskGroup(of: [String: Any].self) { group in
                group.addTask { try await self.awaitResponse(id: id, sending: body) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw MCPError.timedOut(method)
                }
                do {
                    guard let first = try await group.next() else { throw MCPError.noResponse }
                    group.cancelAll()
                    return first
                } catch {
                    // The timeout won. `cancelAll` does not reach the waiting child: it is parked
                    // on a `CheckedContinuation` that only `receive` can resume, and a hung server
                    // never sends the line that would. The task group then waits forever for that
                    // child, so a single unresponsive MCP server hung the whole run rather than
                    // failing after `timeout` seconds. Failing the continuation by hand is what
                    // lets the group actually unwind.
                    await self.failPending(id: id, with: error)
                    group.cancelAll()
                    throw error
                }
            }

        case .http(let url, let headers):
            return try await httpRequest(url: url, headers: headers, envelope: envelope, timeout: timeout)
        }
    }

    private func notify(_ method: String) async throws {
        let envelope: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": [:]]
        switch config.transport {
        case .stdio:
            var data = try JSONSerialization.data(withJSONObject: envelope)
            data.append(0x0A)
            try toServer?.write(contentsOf: data)
        case .http(let url, let headers):
            _ = try? await httpRequest(url: url, headers: headers, envelope: envelope, timeout: 10)
        }
    }

    // MARK: stdio transport

    private func startProcess() throws {
        guard case .stdio(let command, let args, let env) = config.transport else { return }

        let process = Process()
        // A GUI app inherits a minimal PATH, so `npx` and `node` are not on it. Resolve
        // through a login shell, which is where the user's own tools actually live.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let quoted = ([command] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        process.arguments = ["-lc", "exec " + quoted.joined(separator: " ")]

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Servers are chatty on stderr; drain it so the pipe never fills and blocks them.
        stderr.fileHandleForReading.readabilityHandler = { _ = $0.availableData }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            Task { await self.receive(chunk) }
        }

        try process.run()
        self.process = process
        self.toServer = stdin.fileHandleForWriting
        self.fromServer = stdout.fileHandleForReading
    }

    /// Resume a request that will never get an answer, so its task can finish.
    private func failPending(id: Int, with error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func awaitResponse(id: Int, sending body: Data) async throws -> [String: Any] {
        var framed = body
        framed.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try toServer?.write(contentsOf: framed)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    /// Accumulate bytes and dispatch each complete line. Servers split messages across reads, so
    /// buffering is not optional.
    private func receive(_ chunk: Data) {
        readBuffer.append(chunk)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer[readBuffer.startIndex..<newline]
            readBuffer.removeSubrange(readBuffer.startIndex...newline)
            guard !line.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            deliver(message)
        }
    }

    private func deliver(_ message: [String: Any]) {
        guard let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) else {
            return   // a notification, or a response to something we stopped waiting for
        }
        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: MCPError.server((error["message"] as? String) ?? "unknown error"))
        } else {
            continuation.resume(returning: (message["result"] as? [String: Any]) ?? [:])
        }
    }

    // MARK: HTTP transport

    private func httpRequest(url: URL, headers: [String: String],
                             envelope: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Streamable HTTP servers may answer with either, so accept both.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: envelope)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw MCPError.noResponse }
        guard (200..<300).contains(status) else {
            throw MCPError.server("HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }

        // An SSE reply carries the JSON in `data:` lines.
        if let text = String(data: data, encoding: .utf8), text.hasPrefix("event:") || text.contains("\ndata:") {
            for line in text.split(separator: "\n") where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let parsed = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                    if let error = parsed["error"] as? [String: Any] {
                        throw MCPError.server((error["message"] as? String) ?? "unknown error")
                    }
                    return (parsed["result"] as? [String: Any]) ?? [:]
                }
            }
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.malformed
        }
        if let error = parsed["error"] as? [String: Any] {
            throw MCPError.server((error["message"] as? String) ?? "unknown error")
        }
        return (parsed["result"] as? [String: Any]) ?? [:]
    }
}

// MARK: - Errors

public enum MCPError: LocalizedError {
    case timedOut(String)
    case noResponse
    case malformed
    case disconnected
    case server(String)
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let method): return "\(method) timed out"
        case .noResponse:           return "the server did not answer"
        case .malformed:            return "the server's reply could not be read"
        case .disconnected:         return "the connection closed"
        case .server(let message):  return message
        case .toolFailed(let text): return text
        }
    }
}
