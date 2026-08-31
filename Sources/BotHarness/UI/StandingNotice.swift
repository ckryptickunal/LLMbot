import AppKit
import SwiftUI

/// A condition the user has to know about without having gone looking for it.
///
/// Two of these exist and both were previously buried. Whether the key file is still owner-only
/// was read once, inside Settings → Providers, on the frame that pane appeared. Whether macOS
/// has actually granted Screen Recording and Accessibility — the two grants the entire "your
/// bots use your Mac" proposition rests on — lived in a tab of a sheet nobody opens twice. A
/// security condition you can only see by navigating to it is a security condition nobody sees.
///
/// **Deliberately not an alert, and deliberately not a toast.** Both of these are standing
/// states rather than events: an alert interrupts once and is then gone, and a toast fades on a
/// timer. Neither can express "this is still true". This stays on screen until the thing it is
/// about is fixed, and disappears the moment it is.
///
/// The action lives on the notice for the same reason. A warning whose remedy is somewhere else
/// is a warning people learn to scroll past.
struct StandingNotice: View {
    let systemImage: String
    let title: String
    let detail: String
    let actionTitle: String
    var tint: Color = DS.Status.awaitingApproval.mark
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.md) {
                Image(systemName: systemImage)
                    .font(DS.Text.glyphSmall)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(DS.Text.caption.weight(.semibold))
                    .foregroundStyle(DS.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(DS.Text.micro)
                .foregroundStyle(DS.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecondaryButton(actionTitle, action: action)
        }
        .padding(DS.Space.lg)
        // Not a `Surface`. That primitive carries a 180-point minimum width because it is a
        // card in a transcript, and this has to sit inside a roster column the user is allowed
        // to drag down to exactly that width before its own padding is taken off.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .stroke(tint.opacity(0.25), lineWidth: DS.Size.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(detail)")
    }
}

extension View {
    /// Re-read a condition every time the app comes back to the front.
    ///
    /// Both standing notices are about state that is changed *outside* this app — in System
    /// Settings, or by a `chmod` from a backup restore — so the moment the answer can change is
    /// the moment the window regains focus. Checking only in `onAppear` is what left the
    /// Computers tab still saying "not granted" after the user had just granted it, and it
    /// would have left the roster warning about a key file the user had already locked down.
    ///
    /// Polling was the alternative and is the wrong one: it burns a timer for the whole life of
    /// the app to detect something that cannot change while the app is frontmost.
    func refreshingOnActivation(_ refresh: @escaping () -> Void) -> some View {
        onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
}
