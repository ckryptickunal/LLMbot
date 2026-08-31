import Foundation
import AppKit

/// Driving the browser the user is already signed in to.
///
/// The whole reason this exists rather than a bundled automation browser is stated in
/// `docs/PRODUCT.md`: a fresh Playwright profile has none of the user's sessions, so every task
/// that matters — read the thread in the CRM, check the order in the admin panel, look at the
/// analytics dashboard — dies at a login wall. Driving Safari or Chrome as the user already has
/// them open is the only version of this that is useful.
///
/// With no third-party packages the mechanism available is AppleScript through
/// `/usr/bin/osascript`. That is a smaller lever than the DevTools protocol — no network
/// interception, no waiting on a specific element, no multi-tab addressing — and it is chosen
/// anyway, because attaching to Chrome over CDP requires relaunching it with a debugging port,
/// which kills the user's windows and, on a profile using Chrome's own encryption, is exactly
/// the move that a session-stealing attack makes. AppleScript asks the browser politely and the
/// user can see every grant it needed in System Settings.
///
/// Three things here are load-bearing and easy to get wrong:
///
/// **The URL is attacker input.** A model that has read a web page can be talked into navigating
/// somewhere. `file://` is the dangerous scheme, specifically: the browser runs as the user, not
/// as this bot, so `file:///Users/…/Bot-Harness/credentials.json` would hand back the app's own
/// key store as page text with `FileExecutor`'s boundary never consulted. Every guard in
/// `PathGuard` and `ShellFloor` is walked around by one navigation. So only `http` and `https`
/// go through, and the current page's scheme is checked again before anything is read from it.
///
/// **Two escaping layers, in order.** A selector is written into JavaScript, and that JavaScript
/// is then written into an AppleScript string literal. Escaping once is a script-injection hole:
/// a selector containing a quote closes the AppleScript literal and the rest of it is executed
/// as AppleScript, in an app that can reach the user's logged-in sessions.
///
/// **A refusal must never look like a success.** Both browsers ship with JavaScript-from-Apple-
/// Events turned off, and the resulting error is opaque. Returning "nothing found" there would
/// teach the model that the page was empty rather than that a switch is off, so those cases are
/// detected and returned as the exact menu path to fix them.
public actor BrowserExecutor {

    // MARK: - Which browser

    public enum Browser: String, Sendable, CaseIterable {
        case chrome = "Google Chrome"
        case safari = "Safari"

        var bundleIdentifier: String {
            switch self {
            case .chrome: return "com.google.Chrome"
            case .safari: return "com.apple.Safari"
            }
        }
    }

    /// How much page text one `extract` may hand back.
    ///
    /// 40,000 characters is roughly 10,000 tokens — about a fifth of a comfortable context
    /// window, and more than any page a person would read in one go. The cap exists because a
    /// documentation site or a long thread will happily return a megabyte, and a tool that can
    /// spend a whole context window in one call is a tool the agent cannot use twice.
    public static let extractCharacterCap = 40_000

    /// The most text `type` will send in one call. Longer than any field a person fills, short
    /// enough that the generated script always fits in the pipe buffer we write it through.
    public static let typeCharacterCap = 20_000

    private static let osascriptPath = "/usr/bin/osascript"

    private let pinned: Browser?

    /// The browser chosen for this run, kept once decided.
    ///
    /// Re-deciding per call would let `navigate` land in Chrome and the following `extract` read
    /// Safari, which produces a confidently wrong answer rather than an error — the worst kind of
    /// bug in an agent tool.
    private var resolved: Browser?

    public init(browser: Browser? = nil) { self.pinned = browser }

    /// Which of the two to drive.
    ///
    /// Whatever the user is looking at wins, because that is the window whose sessions and
    /// scroll position they are thinking about. Otherwise Chrome, when it is running: it is the
    /// browser `docs/PRODUCT.md` names ("your Chrome with you already signed in") and the one
    /// most people keep their working sessions in.
    ///
    /// When neither is running the fallback is Safari, and the reason is availability rather
    /// than preference: Safari ships with macOS and cannot be missing, so this can never fail
    /// with "that browser is not installed". The cost is real — launching Safari gets none of
    /// Chrome's cookies — so a bot that lives in Chrome should be constructed with
    /// `BrowserExecutor(browser: .chrome)` rather than relying on this.
    static func choose(running: Set<Browser>, frontmost: Browser?) -> Browser {
        if let frontmost, running.contains(frontmost) { return frontmost }
        if running.contains(.chrome) { return .chrome }
        if running.contains(.safari) { return .safari }
        return .safari
    }

    /// Which browsers are up, asked of the workspace rather than of AppleScript.
    ///
    /// `tell application "Safari" to running` would itself be an Apple Event, so asking the
    /// question would trigger the Automation consent prompt before we have anything to do with
    /// the answer. `NSWorkspace` needs no grant at all.
    static func survey() -> (running: Set<Browser>, frontmost: Browser?) {
        let apps = NSWorkspace.shared.runningApplications
        var running: Set<Browser> = []
        for app in apps {
            guard let id = app.bundleIdentifier else { continue }
            for browser in Browser.allCases where browser.bundleIdentifier == id { running.insert(browser) }
        }
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let frontmost = Browser.allCases.first { $0.bundleIdentifier == frontID }
        return (running, frontmost)
    }

    private func target() -> Browser {
        if let pinned { return pinned }
        if let resolved { return resolved }
        let survey = Self.survey()
        let pick = Self.choose(running: survey.running, frontmost: survey.frontmost)
        resolved = pick
        return pick
    }

    private func requireRunning(_ browser: Browser) throws {
        guard Self.survey().running.contains(browser) else { throw BrowserError.notRunning(browser) }
    }

    // MARK: - Operations

    /// Point the browser at a URL and report where it actually landed.
    ///
    /// Reuses the active tab instead of opening a new one. A new tab per navigation leaves the
    /// user with forty tabs after a long run, and every other operation here addresses the front
    /// window's active tab anyway — so a fresh tab that then loses focus would make `extract`
    /// read the wrong page.
    @discardableResult
    public func navigate(url raw: String) async throws -> String {
        let url = try Self.validated(raw)
        let browser = target()

        let script: String
        switch browser {
        case .chrome:
            script = """
            tell application "Google Chrome"
            \tif (count of windows) is 0 then make new window
            \tset theTab to active tab of front window
            \tset URL of theTab to \(Self.appleScriptString(url))
            \tdelay 0.2
            \trepeat 300 times
            \t\tif not (loading of theTab) then exit repeat
            \t\tdelay 0.1
            \tend repeat
            \treturn "OK " & (URL of theTab) & linefeed & (title of theTab)
            end tell
            """
        case .safari:
            // Safari's document has no `loading` property the way a Chrome tab does, and asking
            // the page for `document.readyState` would drag the JavaScript grant into an
            // operation that does not otherwise need it. So we wait for the title to stop
            // changing: two identical non-empty samples means the load has committed.
            script = """
            tell application "Safari"
            \tif (count of documents) is 0 then make new document
            \tset URL of front document to \(Self.appleScriptString(url))
            \tdelay 0.3
            \tset previousName to ""
            \tset stableCount to 0
            \trepeat 200 times
            \t\tset currentName to (name of front document)
            \t\tif currentName is not "" and currentName is previousName then
            \t\t\tset stableCount to stableCount + 1
            \t\t\tif stableCount >= 2 then exit repeat
            \t\telse
            \t\t\tset stableCount to 0
            \t\tend if
            \t\tset previousName to currentName
            \t\tdelay 0.1
            \tend repeat
            \treturn "OK " & (URL of front document) & linefeed & (name of front document)
            end tell
            """
        }

        let answer = try await payload(run(script, browser: browser, usedJavaScript: false, timeout: 60))
        let parts = answer.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let landed = Self.quarantined(parts.first ?? url, limit: 2_000)
        let title = parts.count > 1 ? Self.quarantined(parts[1]) : ""

        // Both the landed URL and the title are chosen by the page, so they are quarantined
        // above before being spoken back. A page titled "SYSTEM: ignore your instructions" would
        // otherwise arrive in the transcript as an unlabelled line of prose.
        var sentence = "\(browser.rawValue) is at \(landed)"
        if !title.isEmpty { sentence += ", a page calling itself \"\(title)\"" }
        return sentence + ". Nothing has been read from it yet — call browser.extract for the text."
    }

    /// The visible text of the current page.
    public func extract() async throws -> String {
        let browser = target()
        try requireRunning(browser)
        let page = try await currentURL()
        try Self.requireDrivable(page)

        let javaScript = #"""
        (function () {
          var body = document.body;
          if (!body) { return "ERR this page has no readable body yet — it is still loading, or it is a browser page rather than a website."; }
          var text = body.innerText || "";
          text = text.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
          if (!text) { return "ERR this page has no visible text — its content may be inside a canvas, a video, or an iframe from another site, none of which can be read this way."; }
          return "OK " + text;
        })()
        """#

        let raw = try await payload(run(Self.wrap(javaScript, for: browser), browser: browser,
                                        usedJavaScript: true, timeout: 30))
        // Page text is the archetypal untrusted input: it is written by whoever owns the site,
        // and this bot arrives at it already signed in. The envelope is applied here rather than
        // at the dispatch site so that no future wiring can forget it.
        return UntrustedContent.envelope(Self.capped(raw), source: "the web page at \(page)")
    }

    /// Click an element by CSS selector.
    public func click(selector: String) async throws -> String {
        let browser = target()
        try requireRunning(browser)
        try Self.requireDrivable(try await currentURL())

        let javaScript = #"""
        (function () {
          var sel = \#(Self.javaScriptString(selector));
          var el;
          try { el = document.querySelector(sel); }
          catch (e) { return "ERR " + sel + " is not a valid CSS selector (" + e.message + "). Use a selector such as #id, .class, or button[type=\"submit\"]."; }
          if (!el) { return "ERR nothing on this page matches " + sel + ". Call browser.extract to see what the page actually contains, then choose a selector from that."; }
          el.scrollIntoView({ block: "center", inline: "center" });
          el.click();
          var label = (el.innerText || el.getAttribute("aria-label") || el.tagName || "").trim();
          return "OK clicked " + sel + (label ? " (" + label.slice(0, 60) + ")" : "");
        })()
        """#

        return try await payload(run(Self.wrap(javaScript, for: browser), browser: browser,
                                     usedJavaScript: true, timeout: 30))
    }

    /// Focus a field by CSS selector and put text in it.
    public func type(selector: String, text: String) async throws -> String {
        guard text.count <= Self.typeCharacterCap else {
            throw BrowserError.tooMuchText(text.count)
        }
        let browser = target()
        try requireRunning(browser)
        try Self.requireDrivable(try await currentURL())

        // The native value setter, rather than `el.value = text`, is what makes this work on a
        // real site. React and every framework that copies it install their own `value` setter on
        // the element instance and ignore a plain assignment — the field shows the text, the app's
        // state never hears about it, and the form submits empty. That failure is silent, which is
        // why it is worth six lines here.
        let javaScript = #"""
        (function () {
          var sel = \#(Self.javaScriptString(selector));
          var text = \#(Self.javaScriptString(text));
          var el;
          try { el = document.querySelector(sel); }
          catch (e) { return "ERR " + sel + " is not a valid CSS selector (" + e.message + "). Use a selector such as #id, .class, or input[name=\"email\"]."; }
          if (!el) { return "ERR nothing on this page matches " + sel + ". Call browser.extract to see what the page actually contains, then choose a selector from that."; }
          el.focus();
          if (el.isContentEditable) {
            el.textContent = text;
          } else if ("value" in el) {
            var proto = (el.tagName === "TEXTAREA") ? HTMLTextAreaElement.prototype
                      : (el.tagName === "INPUT") ? HTMLInputElement.prototype : null;
            var d = proto ? Object.getOwnPropertyDescriptor(proto, "value") : null;
            if (d && d.set) { d.set.call(el, text); } else { el.value = text; }
          } else {
            return "ERR " + sel + " is a " + el.tagName + ", which is not something you can type into. Pick an input, a textarea, or a contenteditable element.";
          }
          el.dispatchEvent(new Event("input", { bubbles: true }));
          el.dispatchEvent(new Event("change", { bubbles: true }));
          return "OK typed " + text.length + " characters into " + sel;
        })()
        """#

        // The confirmation counts characters instead of echoing them. This is the tool that fills
        // password and card fields, and everything a tool returns is written to the trace and sent
        // to a model provider.
        return try await payload(run(Self.wrap(javaScript, for: browser), browser: browser,
                                     usedJavaScript: true, timeout: 30))
    }

    /// Where the browser currently is. Needs no JavaScript grant, which is why it is also the
    /// page-safety check the other three operations run first.
    public func currentURL() async throws -> String {
        let browser = target()
        try requireRunning(browser)

        let script: String
        switch browser {
        case .chrome:
            script = """
            tell application "Google Chrome"
            \tif (count of windows) is 0 then return "ERR Google Chrome has no window open. Ask me to navigate to a URL first — that opens one."
            \treturn "OK " & (URL of active tab of front window)
            end tell
            """
        case .safari:
            script = """
            tell application "Safari"
            \tif (count of documents) is 0 then return "ERR Safari has no page open. Ask me to navigate to a URL first — that opens one."
            \treturn "OK " & (URL of front document)
            end tell
            """
        }
        return try await payload(run(script, browser: browser, usedJavaScript: false, timeout: 20))
    }

    // MARK: - What may be opened

    /// Schemes the browser may be pointed at, and the reason the list is this short.
    ///
    /// `file://` is the one that matters. The browser is not inside this bot's filesystem
    /// boundary — it runs as the user — so a single navigation to
    /// `file:///Users/…/Library/Application Support/Bot-Harness/credentials.json` followed by
    /// `extract` returns the app's own API keys as page text, with `FileExecutor.resolve`,
    /// `PathGuard.denied` and the shell floor all bypassed because none of them was ever
    /// consulted. `javascript:` and `data:` are refused for a different reason: they execute in
    /// whatever page is already open, under that site's origin and the user's live session, so
    /// they are a way to act as the signed-in user without ever naming the site.
    static func validated(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BrowserError.badURL(raw, "no address was given")
        }

        let candidate: String
        switch scheme(of: trimmed) {
        case nil:
            // A bare "example.com" or "localhost:3000" is what a model usually writes.
            candidate = "https://" + trimmed
        case "http", "https":
            candidate = trimmed
        case "file":
            throw BrowserError.refusedScheme(
                scheme: "file",
                why: "Reading local files through the browser would go around the file permissions "
                   + "this bot actually has — the browser runs as you, not as me, so it can open "
                   + "the app's own credentials file. Use files.read for anything on disk; it "
                   + "checks what this bot is allowed to see.")
        case "javascript":
            throw BrowserError.refusedScheme(
                scheme: "javascript",
                why: "A javascript: URL runs code inside whatever page is already open, using the "
                   + "session you are signed in to there. Navigate to the site by its https "
                   + "address and use browser.click or browser.type instead.")
        case "data":
            throw BrowserError.refusedScheme(
                scheme: "data",
                why: "A data: URL puts content the page did not serve inside the browser, where it "
                   + "can read from the origin it lands in. Give me an http or https address.")
        case .some(let other):
            throw BrowserError.refusedScheme(
                scheme: other,
                why: "Only http and https addresses go to the browser. If \(other): opens an app "
                   + "rather than a web page, that is a computer.launch_app job, not a browser one.")
        }

        guard let components = URLComponents(string: candidate),
              let host = components.host, !host.isEmpty else {
            throw BrowserError.badURL(raw, "it is not an address I can open — give me a full one, like https://example.com/page")
        }
        return components.string ?? candidate
    }

    /// The scheme of a URL-ish string, or nil when there is none.
    ///
    /// Hand-rolled rather than handed to `URL(string:)` because that parser is lenient by design
    /// and this is a security check: it answers "what does the browser think this is", not "is
    /// this well formed". The digits test is the one non-obvious part — in `localhost:3000` the
    /// text before the colon looks exactly like a scheme, and treating it as one would refuse
    /// every local dev server the user asks a bot to look at.
    static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let head = text[text.startIndex..<colon]
        guard let first = head.first, first.isLetter else { return nil }
        guard head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else { return nil }
        let after = text[text.index(after: colon)...]
        if let next = after.first, next.isNumber { return nil }
        return head.lowercased()
    }

    /// Refuse to read from or act on a page that is not a website.
    ///
    /// The scheme check on `navigate` is not enough on its own: the user may already have a
    /// `file://` page open, and `extract` would then read it without any navigation happening.
    static func requireDrivable(_ url: String) throws {
        let kind = scheme(of: url) ?? ""
        guard kind == "http" || kind == "https" else {
            throw BrowserError.pageNotDrivable(url: quarantined(url, limit: 200), scheme: kind.isEmpty ? "none" : kind)
        }
    }

    // MARK: - Escaping

    /// A Swift string as an AppleScript double-quoted literal, quotes included.
    ///
    /// Returns the quotes as well as the contents so that no call site can forget them — a
    /// forgotten pair is the same injection hole as a missed escape.
    ///
    /// AppleScript literals have exactly five escapes and no numeric form, so a control character
    /// other than tab, return or newline cannot be written at all. Those are dropped rather than
    /// approximated: silently corrupting a script is worse than losing a byte no URL or selector
    /// legitimately contains, and the JavaScript layer below has already turned real control
    /// characters into `\uXXXX` text by the time this sees them.
    static func appleScriptString(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 || character.value == 0x7F { continue }
                out.unicodeScalars.append(character)
            }
        }
        return out + "\""
    }

    /// A Swift string as a JavaScript double-quoted literal, quotes included.
    ///
    /// U+2028 and U+2029 are escaped because JavaScript treats them as line terminators inside
    /// source: a selector containing one ends the string literal mid-expression, which is a
    /// script-injection hole that survives naive quote escaping.
    static func javaScriptString(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if character.value < 0x20 || character.value == 0x7F {
                    out += String(format: "\\u%04X", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }

    /// Put a JavaScript program inside the AppleScript that asks the browser to run it.
    ///
    /// This is the second escaping layer, and the order is the point: values were escaped into
    /// the JavaScript first, and the finished program is escaped into AppleScript here. Doing it
    /// the other way round, or only once, lets a quote in a selector close the AppleScript string
    /// and run the remainder as AppleScript inside an app holding the user's sessions.
    static func wrap(_ javaScript: String, for browser: Browser) -> String {
        let literal = appleScriptString(javaScript)
        switch browser {
        case .chrome:
            return """
            tell application "Google Chrome"
            \tif (count of windows) is 0 then return "ERR Google Chrome has no window open. Ask me to navigate to a URL first — that opens one."
            \treturn (execute active tab of front window javascript \(literal))
            end tell
            """
        case .safari:
            return """
            tell application "Safari"
            \tif (count of documents) is 0 then return "ERR Safari has no page open. Ask me to navigate to a URL first — that opens one."
            \treturn (do JavaScript \(literal) in front document)
            end tell
            """
        }
    }

    // MARK: - Size

    static func capped(_ text: String) -> String {
        guard text.count > extractCharacterCap else { return text }
        return String(text.prefix(extractCharacterCap))
            + "\n\n[cut off here: this page is longer than the \(extractCharacterCap)-character limit "
            + "on one extract. Narrow the page down — follow a link to the specific section, or use "
            + "the site's own search — rather than expecting the rest.]"
    }

    /// Page-chosen text that has to appear inside a sentence we speak back.
    ///
    /// A title or a redirect target is written by whoever owns the site. Collapsing it to one
    /// short line stops a page from injecting what looks like several lines of our own prose into
    /// the transcript; it is not a substitute for the envelope, which is what protects the text
    /// the page is actually read for.
    static func quarantined(_ text: String, limit: Int = 120) -> String {
        var flattened = ""
        for character in text.unicodeScalars {
            if character.value < 0x20 || character.value == 0x7F { flattened += " " }
            else { flattened.unicodeScalars.append(character) }
        }
        let collapsed = flattened.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .replacingOccurrences(of: "\"", with: "'")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    // MARK: - Running the script

    /// Strip the `OK ` / `ERR ` marker every script here returns.
    ///
    /// The marker is added by the script itself, never by the page, so there is no ambiguity even
    /// when the page's own text begins with one of the words: only the first marker is consumed.
    private func payload(_ result: String) throws -> String {
        if result.hasPrefix("OK ") { return String(result.dropFirst(3)) }
        if result == "OK" { return "" }
        if result.hasPrefix("ERR ") { throw BrowserError.operationFailed(String(result.dropFirst(4))) }
        throw BrowserError.scriptFailed(target(), "the browser answered with something unexpected: \(Self.quarantined(result, limit: 200))")
    }

    private func run(_ source: String, browser: Browser, usedJavaScript: Bool,
                     timeout: TimeInterval) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.osascriptPath) else {
            throw BrowserError.osascriptMissing
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.osascriptPath)
        // The script arrives on stdin rather than as `-e` arguments. A page's worth of
        // JavaScript is longer than a comfortable argv, and anything on a command line is
        // readable by every other process on the machine through `ps` — which for `type` would
        // mean whatever was typed into the field.
        process.arguments = ["-l", "AppleScript", "-"]
        // A deliberately bare environment. Apple Events travel over mach ports, so osascript
        // needs none of the user's shell exports, and not inheriting them is the same rule
        // ShellExecutor follows for the same reason.
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]

        let input = Pipe(), out = Pipe(), err = Pipe()
        process.standardInput = input
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            throw BrowserError.scriptFailed(browser, "could not start osascript: \(error.localizedDescription)")
        }

        // Output is drained on the pipes' own threads. A full extract is far larger than the
        // 64 KB pipe buffer, so reading only after the process exits would deadlock: the browser
        // blocks writing, we block waiting for it to finish.
        let collector = Collector()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendOut(data) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendErr(data) }
        }

        try? input.fileHandleForWriting.write(contentsOf: Data(source.utf8))
        try? input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { try? await Task.sleep(for: .milliseconds(25)) }
            if process.isRunning { Foundation.kill(process.processIdentifier, SIGKILL) }
        }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        try? out.fileHandleForReading.close()
        try? err.fileHandleForReading.close()

        if timedOut { throw BrowserError.timedOut(browser, timeout) }
        guard process.terminationStatus == 0 else {
            throw Self.diagnose(collector.err(), browser: browser, usedJavaScript: usedJavaScript)
        }
        var text = collector.out()
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// Turn osascript's stderr into something the model can act on.
    ///
    /// The two cases that matter are the ones a generic "script failed" would hide. Chrome's
    /// wording is verbatim from its own resource bundle, so matching it is exact. Safari gives
    /// the same opaque `-10000` for a JavaScript grant that is switched off as for several other
    /// failures, which is why its message names the likely cause without claiming certainty —
    /// telling the user the wrong fix confidently is worse than telling them the honest one.
    static func diagnose(_ stderr: String, browser: Browser, usedJavaScript: Bool) -> BrowserError {
        let text = stderr.lowercased()

        if text.contains("-1743")
            || text.contains("not authorized to send apple events")
            || text.contains("not allowed to send apple events") {
            return .automationDenied(browser)
        }
        if text.contains("javascript through applescript is turned off")
            || text.contains("allow javascript from apple events") {
            return .javaScriptRefused(browser, certain: true)
        }
        if usedJavaScript && (text.contains("-10000") || text.contains("appleevent handler failed")) {
            return .javaScriptRefused(browser, certain: false)
        }
        if text.contains("-600") || text.contains("isn't running") || text.contains("is not running") {
            return .notRunning(browser)
        }
        if text.contains("-1728") || text.contains("can’t get") || text.contains("can't get") {
            return .nothingOpen(browser)
        }
        return .scriptFailed(browser, clean(stderr))
    }

    /// Drop osascript's `12:34: execution error:` prefix, which is a position in a script the
    /// user never wrote and cannot look at.
    static func clean(_ stderr: String) -> String {
        let line = stderr.split(separator: "\n").first.map(String.init) ?? stderr
        if let marker = line.range(of: "execution error: ") {
            return String(line[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Bounded, thread-safe accumulation for the two readability handlers, which fire off-actor.
    /// Kept local to this type because its ceiling is the extract cap rather than the shell's.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data(), errData = Data()
        private let ceiling = 512 * 1024

        func appendOut(_ d: Data) { lock.lock(); if outData.count < ceiling { outData.append(d) }; lock.unlock() }
        func appendErr(_ d: Data) { lock.lock(); if errData.count < ceiling { errData.append(d) }; lock.unlock() }
        func out() -> String { lock.lock(); defer { lock.unlock() }; return String(data: outData, encoding: .utf8) ?? "" }
        func err() -> String { lock.lock(); defer { lock.unlock() }; return String(data: errData, encoding: .utf8) ?? "" }
    }

    // MARK: - Errors

    /// Every message here names the thing the user has to do. A model handed "error -1743" tries
    /// the same call again; a model handed a menu path tells the user which switch to flip.
    public enum BrowserError: LocalizedError {
        case refusedScheme(scheme: String, why: String)
        case badURL(String, String)
        case pageNotDrivable(url: String, scheme: String)
        case javaScriptRefused(Browser, certain: Bool)
        case automationDenied(Browser)
        case notRunning(Browser)
        case nothingOpen(Browser)
        case operationFailed(String)
        case tooMuchText(Int)
        case scriptFailed(Browser, String)
        case timedOut(Browser, TimeInterval)
        case osascriptMissing

        public var errorDescription: String? {
            switch self {
            case .refusedScheme(let scheme, let why):
                return "I will not open a \(scheme): URL in the browser. \(why)"

            case .badURL(let raw, let why):
                return "\"\(raw)\" was not opened because \(why)."

            case .pageNotDrivable(let url, let scheme):
                return "The browser is showing \(url), which is a \(scheme) page rather than a website, "
                     + "so I will not read or click on it. Local files are read with files.read, which "
                     + "checks what this bot is allowed to see. Navigate to an http or https address first."

            case .javaScriptRefused(let browser, let certain):
                switch browser {
                case .chrome:
                    return "Google Chrome is refusing to run JavaScript sent from another app, so the page "
                         + "could not be read or driven. In Chrome's menu bar turn on View > Developer > "
                         + "Allow JavaScript from Apple Events, then ask me again. Nothing on the page was changed."
                case .safari:
                    let hedge = certain ? "" : " Safari reports this failure and several others with the same "
                        + "opaque error (-10000), so if the setting is already on, the page itself rejected the script."
                    return "Safari would not run JavaScript sent from another app, so the page could not be read "
                         + "or driven. Turn on Safari's Develop menu (Safari > Settings > Advanced > the option "
                         + "that shows web-developer features), then Develop > Allow JavaScript from Apple Events, "
                         + "and ask me again.\(hedge) Nothing on the page was changed."
                }

            case .automationDenied(let browser):
                let identifier = Bundle.main.bundleIdentifier ?? "app.botharness.mac"
                return "macOS has not allowed Bot-Harness to control \(browser.rawValue) (Apple Events error -1743). "
                     + "Open System Settings > Privacy & Security > Automation, find Bot-Harness, and switch on "
                     + "\(browser.rawValue). If Bot-Harness is not listed there, macOS has no record to change — run "
                     + "`tccutil reset AppleEvents \(identifier)` in Terminal so it asks again. Nothing was done in the browser."

            case .notRunning(let browser):
                return "\(browser.rawValue) is not running, so there is no page to work with. Ask me to navigate "
                     + "to a URL first — that opens it."

            case .nothingOpen(let browser):
                return "\(browser.rawValue) has no window or tab to work with. Ask me to navigate to a URL first."

            case .operationFailed(let detail):
                return detail

            case .tooMuchText(let count):
                return "That is \(count) characters to type, and one call sends at most "
                     + "\(BrowserExecutor.typeCharacterCap). Put long text somewhere the page can load it, "
                     + "or send it in shorter pieces."

            case .scriptFailed(let browser, let detail):
                return "\(browser.rawValue) refused the instruction: \(detail)"

            case .timedOut(let browser, let seconds):
                return "\(browser.rawValue) did not answer within \(Int(seconds)) seconds. The page may be "
                     + "waiting on something — a login prompt, a modal dialog, or a download. Take a screenshot "
                     + "to see what it is showing before trying again."

            case .osascriptMissing:
                return "This Mac has no /usr/bin/osascript, so the browser cannot be driven at all. "
                     + "Use web.open to fetch a page's text over HTTP instead — it will not have your logged-in session."
            }
        }
    }
}
