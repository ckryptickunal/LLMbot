// Capability probe. Reports what this machine will and will not let Bot-Harness do,
// using only non-prompting APIs so running it never shows the user a dialog.
// Invoked by scripts/doctor.sh.
import Foundation
import ApplicationServices
import CoreGraphics
import AVFoundation

func line(_ label: String, _ value: Any) {
    print(label.padding(toLength: 52, withPad: " ", startingAt: 0) + ": \(value)")
}

line("bundle identifier", Bundle.main.bundleIdentifier ?? "<none — unbundled CLI>")
line("accessibility trusted (AXIsProcessTrusted)", AXIsProcessTrusted())
line("screen capture allowed (CGPreflight…)", CGPreflightScreenCaptureAccess())
line("microphone authorization", AVCaptureDevice.authorizationStatus(for: .audio).rawValue)

let source = CGEventSource(stateID: .hidSystemState)
line("input synthesis available (CGEventSource)", source != nil)
line("mouse event constructible", CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                          mouseCursorPosition: .zero, mouseButton: .left) != nil)
line("main display (points)", CGDisplayBounds(CGMainDisplayID()).size)

if !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() {
    print("""

    note: a command-line binary inherits the permissions of whatever launched it. These
          values describe the parent process, not BotHarness.app, which must obtain its
          own grants under its own bundle identifier.
    """)
}
