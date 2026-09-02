import Foundation

/// Which appearance the app draws in.
///
/// The app follows the system by default, which is what a Mac app should do and what it now
/// actually can do — every colour in `DS` resolves per appearance rather than being a dark
/// value written down once.
///
/// The override exists for the reason every Mac app that has one has it: appearance is a
/// working preference, not an identity. Someone editing photographs keeps the system light and
/// wants their tools dark; someone on a bright desk wants the opposite regardless of what the
/// clock did at sunset. It is also the only way to look at both halves of the design system
/// without changing the whole machine, which is a real cost when the machine belongs to someone
/// who is using it.
public enum Appearance: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    public var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }
}
