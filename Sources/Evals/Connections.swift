import Foundation
import BotHarnessCore

/// Connect to every configured MCP server and report what it offers.
///
///     scripts/eval.sh --connections
///
/// This is how we find out whether an integration is real rather than assumed. A server that
/// needs a key, or whose local process is not running, shows as unhealthy with the reason —
/// it never silently disappears from the list.
enum Connections {

    static func run() async {
        let configs = MCPServerConfig.fromClaudeConfig()
        guard !configs.isEmpty else {
            print("No MCP servers configured in ~/.claude.json")
            return
        }

        print("Connecting to \(configs.count) configured MCP server\(configs.count == 1 ? "" : "s")")
        print(String(repeating: "─", count: 78))

        for config in configs {
            let transport: String
            switch config.transport {
            case .stdio(let command, let args, _): transport = "stdio · \(command) \(args.joined(separator: " "))"
            case .http(let url, _):                transport = "http · \(url.host ?? url.absoluteString)"
            }

            let client = MCPClient(config: config)
            let started = Date()
            do {
                try await client.connect(timeout: 45)
                let tools = await client.tools
                let name = await client.serverName ?? config.id
                print(String(format: "healthy   %-16@ %5.1fs  %2d tools",
                             config.id as NSString, Date().timeIntervalSince(started), tools.count))
                print("          \(name) — \(transport)")
                for tool in tools.prefix(8) {
                    print("            · \(tool.name) — \(tool.description.prefix(64))")
                }
                if tools.count > 8 { print("            · … and \(tools.count - 8) more") }
            } catch {
                print(String(format: "OFFLINE   %-16@ %5.1fs",
                             config.id as NSString, Date().timeIntervalSince(started)))
                print("          \(transport)")
                print("          \(error.localizedDescription.prefix(140))")
            }
            await client.disconnect()
            print("")
        }
    }
}
