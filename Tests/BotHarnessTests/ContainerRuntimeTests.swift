import XCTest
@testable import BotHarnessCore

/// The parts of a bot's own computer that hold whether or not `container` is installed.
///
/// Everything here is pure or observes the not-installed path, because that is the state of a
/// stock Mac and the state this project is verified in. The live path — creating a machine,
/// running a command inside it — is covered by `ContainerLiveTests`, which is skipped unless the
/// tool is actually present. What must never happen is this file quietly passing because the
/// runtime declined to do anything.
final class ContainerRuntimeTests: XCTestCase {

    // MARK: Naming

    func testNameIsDerivedFromTheBotIDAndIsStable() {
        let id = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        XCTAssertEqual(ContainerRuntime.name(for: id), "bh-3f2504e04f89")
        XCTAssertEqual(ContainerRuntime.name(for: id), ContainerRuntime.name(for: id),
                       "the name must be derivable, not stored — a run after a restart needs it")
    }

    func testNameIsAcceptableToATool() {
        // Container names are DNS-ish. Uppercase and dashes from a raw UUID are not universally
        // accepted, and a name that fails at creation time fails on the user's first run.
        let name = ContainerRuntime.name(for: UUID())
        XCTAssertTrue(name.hasPrefix("bh-"))
        XCTAssertEqual(name.count, 15)
        XCTAssertTrue(name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" },
                      "\(name) contains a character a container name may reject")
    }

    func testDifferentBotsGetDifferentComputers() {
        XCTAssertNotEqual(ContainerRuntime.name(for: UUID()), ContainerRuntime.name(for: UUID()))
    }

    // MARK: Path translation

    func testGuestAndHostPathsRoundTrip() {
        let workspace = "/Users/someone/Bots/scout"
        let host = workspace + "/notes/today.md"

        let guest = ContainerRuntime.guestPath(fromHost: host, workspace: workspace)
        XCTAssertEqual(guest, "/work/notes/today.md")
        XCTAssertEqual(ContainerRuntime.hostPath(fromGuest: guest, workspace: workspace), host)
    }

    func testTheWorkspaceRootItselfTranslates() {
        let workspace = "/Users/someone/Bots/scout"
        XCTAssertEqual(ContainerRuntime.guestPath(fromHost: workspace, workspace: workspace), "/work")
        XCTAssertEqual(ContainerRuntime.hostPath(fromGuest: "/work", workspace: workspace), workspace)
    }

    /// The dangerous near-miss: a sibling directory whose name starts with the workspace's name.
    /// A prefix check without the separator turns `/Bots/scout-old` into a path inside `/work`,
    /// which is how a boundary check and the thing executed end up disagreeing about which file
    /// is meant.
    func testASiblingWithASharedPrefixIsNotTranslated() {
        let workspace = "/Users/someone/Bots/scout"
        let sibling = "/Users/someone/Bots/scout-old/secret.txt"
        XCTAssertEqual(ContainerRuntime.guestPath(fromHost: sibling, workspace: workspace), sibling)

        XCTAssertEqual(ContainerRuntime.hostPath(fromGuest: "/workshop/x", workspace: workspace),
                       "/workshop/x")
    }

    func testAPathOutsideTheWorkspaceIsLeftAlone() {
        let workspace = "/Users/someone/Bots/scout"
        XCTAssertEqual(ContainerRuntime.hostPath(fromGuest: "/etc/hosts", workspace: workspace),
                       "/etc/hosts")
        XCTAssertEqual(ContainerRuntime.guestPath(fromHost: "/etc/hosts", workspace: workspace),
                       "/etc/hosts")
    }

    // MARK: What may be shared

    func testTheHomeDirectoryAndDiskRootAreRefused() {
        // Sharing these into a container is not giving a bot a workspace, it is handing over the
        // machine — and the container would then be isolation in name only.
        for path in ["/", "/Users", "/System", "/Library", "/Applications", "/usr", "/bin",
                     "/etc", "/var", NSHomeDirectory()] {
            XCTAssertFalse(ContainerRuntime.isShareable(path), "\(path) must not be shareable")
        }
    }

    func testATrailingSlashDoesNotDefeatTheCheck() {
        XCTAssertFalse(ContainerRuntime.isShareable(NSHomeDirectory() + "/"))
        XCTAssertFalse(ContainerRuntime.isShareable("/Users/"))
    }

    func testAnOrdinaryWorkspaceIsShareable() {
        XCTAssertTrue(ContainerRuntime.isShareable(NSHomeDirectory() + "/Bots/scout"))
        XCTAssertTrue(ContainerRuntime.isShareable("/Users/someone/Projects/thing"))
    }

    func testARelativePathIsRefused() {
        // A relative path means the mount depends on where the app happened to be launched from.
        XCTAssertFalse(ContainerRuntime.isShareable("Bots/scout"))
        XCTAssertFalse(ContainerRuntime.isShareable(""))
    }

    // MARK: Behaviour when the tool is absent

    func testAvailabilityIsHonestWhenTheToolIsNotInstalled() async throws {
        try XCTSkipIf(FileManager.default.isExecutableFile(atPath: ContainerRuntime.executable),
                      "container is installed on this machine; see ContainerLiveTests")
        let availability = await ContainerRuntime().availability()
        XCTAssertEqual(availability, .notInstalled)
        XCTAssertFalse(availability.isReady)
    }

    func testPreparingWithoutTheToolThrowsInsteadOfHanging() async throws {
        try XCTSkipIf(FileManager.default.isExecutableFile(atPath: ContainerRuntime.executable),
                      "container is installed on this machine; see ContainerLiveTests")
        do {
            _ = try await ContainerRuntime().prepare(botID: UUID(),
                                                     workspace: NSHomeDirectory() + "/Bots/x")
            XCTFail("expected .notInstalled")
        } catch let failure as ContainerRuntime.Failure {
            XCTAssertEqual(failure, .notInstalled)
            XCTAssertNotNil(failure.errorDescription)
        }
    }

    /// The failure the user actually sees, in the place they see it. A run that falls back to the
    /// Mac must be able to say why in one sentence.
    func testEveryFailureExplainsItselfInPlainWords() {
        let failures: [ContainerRuntime.Failure] = [
            .notInstalled, .serviceStopped, .diskFull(freeBytes: 900_000_000),
            .refusedWorkspace("/Users/someone"), .commandFailed("boot failed"),
        ]
        for failure in failures {
            let text = failure.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty, "\(failure) has no description")
            XCTAssertFalse(text.contains("Optional("), "\(failure) leaks Swift syntax at the user")
        }
    }

    func testDestroyingAComputerThatCannotExistIsSilent() async {
        // Called on every bot deletion, including on machines that have never had the tool.
        await ContainerRuntime().destroy(botID: UUID())
        await ContainerRuntime().collectGarbage(keeping: [UUID()])
    }

    // MARK: Output handling

    func testFirstLineIsWhatAUserWouldRead() {
        XCTAssertEqual(ContainerRuntime.firstLine("boot failed\nstack trace\nmore"), "boot failed")
        // CLI errors are routinely indented, and an indented fragment dropped into a sentence
        // reads as a layout bug.
        XCTAssertEqual(ContainerRuntime.firstLine("   padded   "), "padded")
        XCTAssertEqual(ContainerRuntime.firstLine("\n\n  real reason\n"), "real reason")
        // Never empty: a blank where the reason goes tells the user nothing at all.
        XCTAssertEqual(ContainerRuntime.firstLine(""), "no detail given")
        XCTAssertEqual(ContainerRuntime.firstLine("   \n  "), "no detail given")
    }

    func testAVeryLongErrorIsTruncatedRatherThanFloodingTheCard() {
        XCTAssertEqual(ContainerRuntime.firstLine(String(repeating: "x", count: 5_000)).count, 200)
    }
}
