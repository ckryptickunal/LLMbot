import Foundation
import CoreGraphics
import ScreenCaptureKit
import ApplicationServices
import AppKit
import CryptoKit

/// Driving the actual Mac: screen, keyboard, mouse, and the accessibility tree.
///
/// This is the layer the whole product rests on, and the one nobody ships for you. Google's
/// own computer-use reference implementation is browser-only — Playwright and Browserbase
/// backends and nothing else — so the desktop executor is ours to write regardless of which
/// brain is driving it.
///
/// Two things here are easy to get subtly wrong and expensive to debug:
///
/// **Coordinates.** Gemini returns normalised integers in 0...999 for both axes, and says
/// explicitly not to send display dimensions. Everything on this side is in *points*, and the
/// display is Retina, so pixels are 2× points again. Getting this wrong does not crash — it
/// clicks confidently in the wrong place, which is worse.
///
/// **Not photographing ourselves.** A capture that includes Bot-Harness' own window shows the
/// agent a picture of itself deciding what to do, which is both wasteful and genuinely
/// confusing to a model. `SCContentFilter` excludes this application.
/// There is one Mac, so there is one of these that matters at a time.
///
/// `BotRunner` keeps a dictionary of concurrent runs and each one builds its own
/// `ComputerExecutor`, but every executor posts to the same physical HID event tap and screenshots
/// the same display. Two bots clicking at once do not each get their own desktop; they get one
/// desktop with two sets of clicks interleaved into it, which is not slow or racy so much as
/// nonsense — a click from bot A lands in a window bot B just brought forward.
///
/// This serialises the *use of the machine* so that a bot's look-decide-act sequence is not cut in
/// half by another bot's. It deliberately does not try to be fair or to queue for long: a bot that
/// cannot get the screen right now is told so, and can carry on with work that does not need it.
public actor MachineLock {
    public static let shared = MachineLock()

    private var holder: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Run `body` with exclusive use of the screen, keyboard and mouse.
    public func withExclusiveUse<T: Sendable>(by owner: String,
                                              _ body: @Sendable () async throws -> T) async rethrows -> T {
        while holder != nil, holder != owner {
            await withCheckedContinuation { waiters.append($0) }
        }
        holder = owner
        defer {
            holder = nil
            // One at a time: waking every waiter at once would let them all decide the machine is
            // free and start typing over each other, which is the problem this exists to stop.
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

public actor ComputerExecutor {

    /// The normalised coordinate space the model works in, per Gemini's documentation.
    public static let normalisedMax: Double = 999

    private var lastScreenshot: Data?

    /// Content hash of the last frame, so an unchanged screen costs nothing.
    ///
    /// The common GUI pattern is look, wait, look again — and most of those looks return an
    /// identical image. A full frame is roughly 1,500 tokens, so returning "unchanged" instead
    /// of the same picture again is the single cheapest saving available in a screen-driving
    /// run.
    private var lastFrameHash: String?

    // MARK: - Permissions

    /// Whether the two grants this executor needs are actually held.
    ///
    /// Checked with the non-prompting variants so that asking the question never itself
    /// triggers a dialog. Prompting is a deliberate, user-initiated act — see `requestAccess`.
    public nonisolated static var permissions: (screenRecording: Bool, accessibility: Bool) {
        (CGPreflightScreenCaptureAccess(), AXIsProcessTrusted())
    }

    /// Ask macOS for what we need. Only ever called from a button the user pressed.
    ///
    /// Screen Recording shows a system dialog once. Accessibility cannot be granted by a
    /// prompt at all — the user has to add the app in System Settings — so all we can do is
    /// open the right pane for them.
    public nonisolated static func requestAccess() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
    }

    public static func openPrivacySettings(_ pane: String = "Privacy_ScreenCapture") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Geometry

    /// Size of the main display in points — the space `CGEvent` works in.
    public nonisolated static var displaySize: CGSize {
        CGDisplayBounds(CGMainDisplayID()).size
    }

    /// Turn a model coordinate into a screen point.
    ///
    /// The half-step (`+ 0.5`) centres the point within its normalised cell rather than
    /// landing on its top-left corner. On a 1800-point-wide display each cell is 1.8 points,
    /// so this is worth under a pixel — but it removes a systematic bias toward up-and-left,
    /// which is exactly the kind of thing that makes a click land on a border instead of a
    /// button.
    public nonisolated static func toScreen(x: Int, y: Int, in size: CGSize? = nil) -> CGPoint {
        let display = size ?? displaySize
        let nx = (Double(x) + 0.5) / (normalisedMax + 1)
        let ny = (Double(y) + 0.5) / (normalisedMax + 1)
        return CGPoint(x: nx * display.width, y: ny * display.height)
    }

    /// The inverse, for describing where something is to the model.
    public nonisolated static func toNormalised(_ point: CGPoint, in size: CGSize? = nil) -> (x: Int, y: Int) {
        let display = size ?? displaySize
        let x = Int((point.x / display.width) * normalisedMax)
        let y = Int((point.y / display.height) * normalisedMax)
        return (min(max(x, 0), Int(normalisedMax)), min(max(y, 0), Int(normalisedMax)))
    }

    // MARK: - Observation

    /// Applications whose windows are never captured, whatever is on screen.
    ///
    /// A screenshot is the one channel in this app that no redactor can touch. Everything else a
    /// bot reads is text, and text can be scrubbed for a known key value on its way to the trace
    /// and to the model. Pixels cannot: a password manager window, a Keychain Access row or a
    /// terminal with a token echoed in it is captured verbatim, written to the trace as a PNG,
    /// and base64'd to a third-party model provider.
    ///
    /// Excluding these applications is not a complete answer — anything can be on screen — but it
    /// removes the cases where the secret is the entire point of the window. The rest of the
    /// answer is the capture toggle in Settings and the fact that the user sees every screenshot
    /// in the transcript, which is what makes the exposure visible rather than silent.
    private static let neverCaptured: Set<String> = [
        "com.apple.keychainaccess",
        "com.agilebits.onepassword7", "com.agilebits.onepassword", "com.1password.1password",
        "com.bitwarden.desktop", "com.dashlane.Dashlane", "in.sinew.Enpass-Desktop",
        "org.keepassxc.keepassxc", "com.lastpass.LastPass",
        "com.apple.Passwords", "com.apple.systempreferences",
    ]

    /// Capture the screen, excluding our own window and anything holding a secret.
    public func screenshot(scaleTo maxWidth: Int = 1280) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw ExecutorError.noDisplay
        }

        // Our own window is excluded because a screenshot of the app showing the last screenshot
        // is a hall of mirrors; the credential apps are excluded because the image cannot be
        // redacted afterwards.
        let excluded = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
                || Self.neverCaptured.contains($0.bundleIdentifier.lowercased())
        }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let config = SCStreamConfiguration()
        // Downscale at capture time rather than after. A full Retina frame is ~3600 px wide
        // and costs roughly 1,500 tokens to send; there is no accuracy gained by paying for
        // detail the model cannot act on, since it answers in a 1000-step grid anyway.
        let scale = min(1.0, Double(maxWidth) / Double(display.width))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = true
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let data = Self.png(from: image) else { throw ExecutorError.encodingFailed }
        lastScreenshot = data
        lastFrameHash = Self.hash(data)
        return data
    }

    /// A capture that reports whether anything actually changed.
    ///
    /// Returns nil image data when the frame is byte-identical to the previous one, so the
    /// caller can send a sentence instead of a picture.
    public func observe(scaleTo maxWidth: Int = 1280) async throws -> Observation {
        let previous = lastFrameHash
        let data = try await screenshot(scaleTo: maxWidth)
        let changed = previous != lastFrameHash || previous == nil
        return Observation(image: changed ? data : nil,
                           changed: changed,
                           frameID: lastFrameHash ?? "")
    }

    public struct Observation: Sendable {
        public var image: Data?
        public var changed: Bool
        public var frameID: String

        /// What to tell the model when nothing moved.
        public var unchangedNote: String { "(screen unchanged since the last look)" }
    }

    nonisolated private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func png(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// Structured state: which app is in front, what windows exist, how big the screen is.
    ///
    /// Cheap, and usually enough. The observation ladder in `docs/HARNESS.md` exists because
    /// an agent whose only sense is screenshots is expensively blind.
    public func state() -> String {
        var lines: [String] = []
        let size = Self.displaySize
        lines.append("display: \(Int(size.width))×\(Int(size.height)) points")

        if let front = NSWorkspace.shared.frontmostApplication {
            lines.append("frontmost app: \(front.localizedName ?? "unknown") (\(front.bundleIdentifier ?? "?"))")
        }

        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()
        lines.append("open apps: \(running.joined(separator: ", "))")

        if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            let titled = windows.compactMap { w -> String? in
                guard let owner = w[kCGWindowOwnerName as String] as? String,
                      let title = w[kCGWindowName as String] as? String,
                      !title.isEmpty,
                      let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
                      (bounds["Height"] ?? 0) > 100
                else { return nil }
                return "\(owner): \(title)"
            }
            if !titled.isEmpty {
                lines.append("windows: " + titled.prefix(12).joined(separator: " | "))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The controls in the frontmost app, with roles, names and whether they are enabled.
    ///
    /// This is what lets the model say "click the button named Save" instead of guessing a
    /// coordinate from a picture. When a control is found here, acting on it is both cheaper
    /// and far more reliable than clicking pixels — and the resulting trace is legible, which
    /// matters when someone is auditing what the agent did.
    public func accessibilityTree(maxNodes: Int = 120) -> String {
        guard AXIsProcessTrusted() else {
            return "accessibility permission not granted — cannot read controls"
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "no frontmost application"
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var lines: [String] = ["controls in \(app.localizedName ?? "app"):"]
        var visited = 0

        func walk(_ element: AXUIElement, depth: Int) {
            guard visited < maxNodes, depth < 12 else { return }

            let role = string(element, kAXRoleAttribute as CFString) ?? ""
            let title = string(element, kAXTitleAttribute as CFString)
                ?? string(element, kAXDescriptionAttribute as CFString)
                ?? string(element, kAXValueAttribute as CFString)

            // Only interactive, named things are worth tokens. A tree full of unnamed groups
            // is noise that crowds out the controls the model is looking for.
            let interesting = ["AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
                               "AXPopUpButton", "AXMenuItem", "AXLink", "AXTab", "AXSlider",
                               "AXComboBox", "AXSearchField"]
            if interesting.contains(role), let title, !title.isEmpty {
                var enabled = true
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success,
                   let n = value as? Bool { enabled = n }

                var position = ""
                if let point = self.point(element) {
                    let n = Self.toNormalised(point)
                    position = " at (\(n.x),\(n.y))"
                }
                lines.append("  \(role.dropFirst(2)) \"\(title)\"\(enabled ? "" : " [disabled]")\(position)")
                visited += 1
            }

            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let kids = children as? [AXUIElement] {
                for kid in kids.prefix(40) { walk(kid, depth: depth + 1) }
            }
        }

        walk(axApp, depth: 0)
        return lines.count > 1 ? lines.joined(separator: "\n") : "no named controls found in the frontmost app"
    }

    nonisolated private func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated private func point(_ element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else { return nil }

        var sizeValue: CFTypeRef?
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let sv = sizeValue, CFGetTypeID(sv) == AXValueGetTypeID() {
            AXValueGetValue(sv as! AXValue, .cgSize, &size)
        }
        // Aim at the middle of the control, not its corner.
        return CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
    }

    // MARK: - Action

    public func click(x: Int, y: Int, button: MouseButton = .left, clicks: Int = 1) throws {
        try requireAccessibility()
        let point = Self.toScreen(x: x, y: y)
        try post(point: point, button: button, clicks: clicks)
    }

    public func moveMouse(x: Int, y: Int) throws {
        try requireAccessibility()
        let point = Self.toScreen(x: x, y: y)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left)
        else { throw ExecutorError.eventCreationFailed }
        move.post(tap: .cghidEventTap)
    }

    public func dragAndDrop(fromX: Int, fromY: Int, toX: Int, toY: Int) throws {
        try requireAccessibility()
        let start = Self.toScreen(x: fromX, y: fromY)
        let end = Self.toScreen(x: toX, y: toY)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ExecutorError.eventCreationFailed
        }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        // Intermediate moves: a single jump from down to up is often read as a click rather
        // than a drag by apps that track movement.
        for i in 1...10 {
            let t = Double(i) / 10
            let mid = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: mid, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    public func scroll(dx: Int, dy: Int) throws {
        try requireAccessibility()
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        else { throw ExecutorError.eventCreationFailed }
        event.post(tap: .cghidEventTap)
    }

    /// Type text.
    ///
    /// Uses `keyboardSetUnicodeString` rather than mapping to virtual key codes, so it types
    /// any Unicode correctly regardless of the user's keyboard layout. A layout-dependent
    /// implementation types mojibake on a non-US layout and does it silently.
    public func type(_ text: String, pressEnter: Bool = false) throws {
        try requireAccessibility()
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ExecutorError.eventCreationFailed
        }
        for character in text {
            let utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(4_000)
        }
        if pressEnter { try pressKey("return") }
    }

    public func pressKey(_ key: String) throws {
        try requireAccessibility()
        guard let code = KeyCodes.code(for: key) else { throw ExecutorError.unknownKey(key) }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { throw ExecutorError.eventCreationFailed }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// A chord, e.g. ["cmd", "s"].
    public func hotkey(_ keys: [String]) throws {
        try requireAccessibility()
        var flags: CGEventFlags = []
        var mainKey: String?
        for key in keys {
            switch key.lowercased() {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift":                  flags.insert(.maskShift)
            case "alt", "option":          flags.insert(.maskAlternate)
            case "ctrl", "control":        flags.insert(.maskControl)
            default:                       mainKey = key
            }
        }
        guard let mainKey, let code = KeyCodes.code(for: mainKey) else {
            throw ExecutorError.unknownKey(keys.joined(separator: "+"))
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { throw ExecutorError.eventCreationFailed }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    @discardableResult
    public func launchApp(_ name: String) async throws -> String {
        let workspace = NSWorkspace.shared
        let candidates = ["/Applications/\(name).app", "/System/Applications/\(name).app",
                          "\(NSHomeDirectory())/Applications/\(name).app"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
                ?? workspace.urlForApplication(withBundleIdentifier: name)?.path
        else { throw ExecutorError.appNotFound(name) }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await workspace.openApplication(at: URL(fileURLWithPath: path), configuration: config)
        return "launched \(name)"
    }

    // MARK: - Internals

    private func post(point: CGPoint, button: MouseButton, clicks: Int) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ExecutorError.eventCreationFailed
        }
        let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton) = {
            switch button {
            case .left:   return (.leftMouseDown, .leftMouseUp, .left)
            case .right:  return (.rightMouseDown, .rightMouseUp, .right)
            case .middle: return (.otherMouseDown, .otherMouseUp, .center)
            }
        }()

        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: cgButton)?.post(tap: .cghidEventTap)

        for click in 1...max(1, clicks) {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType,
                                     mouseCursorPosition: point, mouseButton: cgButton),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType,
                                   mouseCursorPosition: point, mouseButton: cgButton)
            else { throw ExecutorError.eventCreationFailed }
            // Without this the OS treats repeats as separate clicks rather than a double.
            down.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if click < clicks { usleep(60_000) }
        }
    }

    private func requireAccessibility() throws {
        guard AXIsProcessTrusted() else { throw ExecutorError.noAccessibilityPermission }
    }

    public enum MouseButton: String, Sendable { case left, right, middle }

    public enum ExecutorError: LocalizedError {
        case noAccessibilityPermission
        case noScreenRecordingPermission
        case noDisplay
        case encodingFailed
        case eventCreationFailed
        case unknownKey(String)
        case appNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .noAccessibilityPermission:
                return "Bot-Harness needs Accessibility permission to control the keyboard and mouse. Grant it in System Settings → Privacy & Security → Accessibility."
            case .noScreenRecordingPermission:
                return "Bot-Harness needs Screen Recording permission to see the screen. Grant it in System Settings → Privacy & Security → Screen Recording."
            case .noDisplay:          return "No display available to capture."
            case .encodingFailed:     return "Could not encode the screenshot."
            case .eventCreationFailed: return "Could not synthesise an input event."
            case .unknownKey(let k):  return "Unknown key: \(k)"
            case .appNotFound(let n): return "Could not find an application named \(n)."
            }
        }
    }
}

/// Virtual key codes for the keys an agent actually presses.
public enum KeyCodes {
    private static let map: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f11": 103, "f12": 111,
        "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50,
    ]

    public static func code(for key: String) -> CGKeyCode? { map[key.lowercased()] }
}
