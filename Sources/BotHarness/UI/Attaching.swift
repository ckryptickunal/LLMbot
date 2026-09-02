import BotHarnessCore
import SwiftUI

/// The one path from "a person put a file in the window" to "the bot may read it".
///
/// There are three ways to attach — drop on the composer, drop on the conversation, choose in
/// the open panel — and before this they did the same thing in three places, which is to say
/// they appended a path to the draft and stopped. None of them granted anything, so all three
/// produced a bot that could see the path and not the file.
///
/// They share one implementation now for the reason `DroppedFiles` gives for living in the
/// core: three copies of a boundary-widening step is three chances for one of them to drift
/// into widening it differently.
@MainActor
enum Attaching {

    /// Grant what the user pointed at, put the granted paths in the draft, and say what was
    /// refused.
    ///
    /// Only granted paths reach the draft. Pasting in a path the app has already declined to
    /// grant would put the bot in the position of discovering the refusal on the user's behalf
    /// and phrasing it as its own failure, which is precisely the confusion being removed.
    static func accept(_ paths: [String], into conversationID: UUID,
                       store: Store, ui: UIState, draft: Binding<String>) {
        guard !paths.isEmpty else { return }
        let result = store.attach(paths, to: conversationID)

        if !result.granted.isEmpty {
            let lines = DroppedFiles.draftLines(for: result.granted.map(\.path))
            draft.wrappedValue += (draft.wrappedValue.isEmpty ? "" : "\n") + lines
        }
        ui.noteAttachmentProblems(result.refused.map(\.sentence), for: conversationID)
    }
}
