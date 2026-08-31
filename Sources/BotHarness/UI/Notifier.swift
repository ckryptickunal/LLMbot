import Foundation
import UserNotifications
import AppKit

/// Telling the user something happened while they were not looking.
///
/// This is the half of "delegate the work and go do something else" that was missing: a bot
/// that finishes, fails, or gets blocked on an approval while the app is in the background had
/// no way to say so. The mascot cannot do it — it is paused precisely when the app is inactive,
/// which is exactly when it would matter.
///
/// Three rules:
///
/// **Never interrupt someone who is already looking.** If the app is active and the user is on
/// the conversation in question, the interface already said it; a notification would be noise.
///
/// **Ask for permission at the first moment it is needed, not at launch.** A permission prompt
/// on first run, before the user has made a bot, is a prompt with no context to judge it by.
///
/// **Respect the per-bot switch.** `Bot.notifies` is the user's answer and is checked by the
/// caller before anything here runs.
@MainActor
enum Notifier {

    enum Kind {
        case needsApproval, finished, failed

        var title: String {
            switch self {
            case .needsApproval: return "Needs your approval"
            case .finished:      return "Finished"
            case .failed:        return "That failed"
            }
        }
    }

    /// Whether the system has been asked yet. Asking twice is harmless but pointless.
    private static var requested = false

    /// Notifications require a bundle identifier; running the binary directly from the build
    /// directory has none, and `UNUserNotificationCenter.current()` traps in that case rather
    /// than failing. Guarded so the app is still runnable outside its bundle.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func post(_ kind: Kind, body: String, conversationID: UUID) {
        guard available else { return }

        let content = UNMutableNotificationContent()
        content.title = kind.title
        content.body = String(body.prefix(240))
        content.sound = kind == .needsApproval ? .default : nil
        // Carried so a click can open the right conversation.
        content.userInfo = ["conversation": conversationID.uuidString]

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        let centre = UNUserNotificationCenter.current()

        guard requested else {
            requested = true
            centre.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                guard granted else { return }
                centre.add(request)
            }
            return
        }
        centre.add(request)
    }

    /// True when the user is demonstrably already looking at this conversation.
    static func isWatching(_ conversationID: UUID, selection: UUID?) -> Bool {
        NSApp.isActive && selection == conversationID
    }
}
