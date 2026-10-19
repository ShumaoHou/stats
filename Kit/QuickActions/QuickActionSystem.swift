import Cocoa

internal enum QuickActionSystemError: LocalizedError {
    case accessibilityDenied, lockUnavailable, lowPowerUnavailable, authorizationFailed, verificationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return localizedString("Allow Stats in System Settings > Privacy & Security > Accessibility, then click Lock screen again.")
        case .lockUnavailable:
            return localizedString("The system lock shortcut could not be sent.")
        case .lowPowerUnavailable:
            return localizedString("Low Power Mode is unavailable on this Mac or its settings could not be read.")
        case .authorizationFailed:
            return localizedString("Administrator authorization was cancelled or Low Power Mode could not be changed.")
        case .verificationFailed:
            return localizedString("Low Power Mode could not be verified for all power sources. Check the system Battery or Energy settings.")
        }
    }
}

/// Uses the public event-posting permission check and system lock shortcut, not display sleep or private APIs.
internal struct ScreenLocker {
    private let hasAccess: () -> Bool
    private let requestAccess: () -> Bool
    private let post: (CGEvent) -> Void

    init(hasAccess: @escaping () -> Bool = CGPreflightPostEventAccess,
         requestAccess: @escaping () -> Bool = CGRequestPostEventAccess,
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.hasAccess = hasAccess
        self.requestAccess = requestAccess
        self.post = post
    }

    func lock() throws {
        guard self.hasAccess() || self.requestAccess() else { throw QuickActionSystemError.accessibilityDenied }
        // Virtual key 12 is kVK_ANSI_Q; Control-Command-Q invokes macOS Lock Screen.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: false) else {
            throw QuickActionSystemError.lockUnavailable
        }
        down.flags = [.maskControl, .maskCommand]
        up.flags = [.maskControl, .maskCommand]
        self.post(down)
        self.post(up)
    }
}

internal enum QuickActionCommand {
    typealias Runner = (String, [String]) throws -> (status: Int32, output: String)

    static func run(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        // Drain while the process runs rather than waiting with a potentially full pipe.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    static func booleanSetting(_ key: String, in text: String) -> Bool? {
        let rows = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }
        let settings = rows.filter { $0.first == Substring(key) }
        guard settings.count == 1, settings[0].count == 2 else { return nil }
        switch settings[0][1] {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }
}
