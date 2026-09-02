import XCTest
@testable import BotHarnessCore

/// Does the authority the app ships actually permit the tools the app ships?
///
/// Nothing checked this before, and two of them did not. The catalogue and the grant list were
/// written in different files months apart, and a tool whose capability is absent from both
/// `granted` and `requiresApproval` is not "ungranted pending a decision" — it is refused on
/// every call, for the life of the install, with a message the user never sees because the
/// model is the one being told.
final class AuthorityCoverageTests: XCTestCase {

    private let authority = Authority.forWorkspace(NSHomeDirectory() + "/ws")

    private func decision(for tool: ToolDescriptor) -> PermissionDecision {
        let contract = TaskContract(botID: UUID(), conversationID: UUID(),
                                    objective: "do the thing", authority: authority)
        let engine = PermissionEngine(contract: contract, rules: [])
        return engine.decide(ProposedAction(tool: tool.id, summary: tool.id, detail: "",
                                            botID: contract.botID, arguments: [:]),
                             tool: tool)
    }

    /// Every built-in tool must resolve to allowed or asked. Refused-by-default means the tool
    /// is in the catalogue, is offered to the model, is chosen by it, and cannot ever run.
    func testNoBuiltInToolIsRefusedByTheAuthorityTheAppShips() {
        var dead: [String] = []
        for tool in ToolRegistry.builtIn {
            let outcome = decision(for: tool).outcome
            if outcome == .refused { dead.append("\(tool.id) needs \(tool.capability)") }
        }
        XCTAssertEqual(dead, [], "these ship in the catalogue and can never run")
    }

    /// The two that were dead. Named individually so a regression says which one.
    func testTheMetaToolsCanRun() {
        for tool in ToolRegistry.metaTools {
            XCTAssertNotEqual(decision(for: tool).outcome, .refused,
                              "\(tool.id) is how a run reaches anything not in its first twelve tools")
        }
    }

    /// The other direction: the grant list must not hand out anything no tool asks for.
    /// A capability granted to nothing is either a typo or a tool that was deleted, and both
    /// read to a person auditing the list as permission that is actually in use.
    func testNothingIsGrantedThatNoToolAsksFor() {
        let asked = Set(ToolRegistry.builtIn.map(\.capability))
        // Four are asked for by something other than a built-in descriptor and are checked
        // elsewhere: `capability.use` is what `CapabilityRegistry.descriptors(for:)` stamps on
        // every operation a connector provides, and `web.read`, `git.read` and `browser.use`
        // name families whose descriptors ask for the narrower capability individually.
        let knownFamilies: Set<String> = ["capability.use", "web.read", "git.read", "browser.use"]
        let unused = authority.granted.subtracting(asked).subtracting(knownFamilies)
        XCTAssertEqual(unused.sorted(), [], "granted to no tool in the catalogue")
    }

    /// The capability every connector operation is stamped with must itself be usable, or
    /// loading one would swap a missing schema for a guaranteed refusal.
    func testAnOperationFromALoadedConnectorIsPermitted() {
        let fromConnector = ToolDescriptor(
            id: "linear_create_issue", domain: .external, surface: .api,
            summary: "Create an issue", schema: #"{"type":"object"}"#,
            capability: "capability.use")
        XCTAssertNotEqual(decision(for: fromConnector).outcome, .refused)
    }
}
