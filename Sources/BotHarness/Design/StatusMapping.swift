import SwiftUI
import BotHarnessCore

/// How a tool's status is spoken in the interface.
///
/// Mapped in one place rather than at each call site, so "Needs approval" is worded the same
/// everywhere and a new status cannot be added without deciding how it reads.
extension ToolActivity.Status {
    var pillState: StatusPill.State {
        switch self {
        case .running:            return .running
        case .done:               return .done
        case .failed, .refused:   return .failed
        case .waitingForApproval: return .waiting
        }
    }

    var label: String {
        switch self {
        case .running:            return "Running"
        case .done:               return "Done"
        case .failed:             return "Failed"
        case .refused:            return "Refused"
        case .waitingForApproval: return "Needs approval"
        }
    }
}
