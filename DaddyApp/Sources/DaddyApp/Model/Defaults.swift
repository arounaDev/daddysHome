import Foundation

/// The handful of settings that should still be true tomorrow.
///
/// Every setting in the drawer used to reset on every launch — you would pick
/// full-bypass, quit, and come back to safe-auto without being told. A picker
/// that forgets is worse than no picker, because you stop trusting what it
/// says.
///
/// Deliberately small: a `UserDefaults` key per setting, no model layer. Agent
/// cards are a different problem with a different lifetime and live in
/// `SessionStore`.
enum Defaults {
    enum Key: String {
        case approvalPolicy = "daddy.approvalPolicy"
        case workMode = "daddy.workMode"
        case buildPolicy = "daddy.buildPolicy"
        case terminalFontSize = "daddy.terminalFontSize"
        case orchestratorModel = "daddy.orchestratorModel"
        case userShellCollapsed = "daddy.userShellCollapsed"
        case driveConnected = "daddy.driveConnected"
        case driveAccountEmail = "daddy.driveAccountEmail"
        case speechMode = "daddy.speechMode"
        case speechEvents = "daddy.speechEvents"
    }

    static func set(_ value: String, for key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    static func set(_ value: Double, for key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    static func set(_ value: Bool, for key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    static func string(_ key: Key) -> String? {
        UserDefaults.standard.string(forKey: key.rawValue)
    }

    /// Nil rather than 0 when unset, so "never chosen" and "chosen as zero" stay
    /// distinguishable — `UserDefaults.double(forKey:)` cannot tell them apart.
    static func double(_ key: Key) -> Double? {
        guard UserDefaults.standard.object(forKey: key.rawValue) != nil else { return nil }
        return UserDefaults.standard.double(forKey: key.rawValue)
    }

    /// Nil when never chosen, so a stored `false` is not the same as unset.
    static func bool(_ key: Key) -> Bool? {
        guard UserDefaults.standard.object(forKey: key.rawValue) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: key.rawValue)
    }
}
