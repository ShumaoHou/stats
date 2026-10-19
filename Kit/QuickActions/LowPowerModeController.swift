import Cocoa

internal protocol LowPowerSettings {
    var isEnabled: Bool { get }
    func toggle(completion: @escaping (Result<Void, Error>) -> Void)
}

/// Persistent system setting: unlike clamshell protection, this has no restore-on-exit ownership.
internal final class LowPowerModeController {
    private let settings: LowPowerSettings
    private(set) var isBusy = false
    var isEnabled: Bool { self.settings.isEnabled }
    var onChange: (() -> Void)?

    init(settings: LowPowerSettings = PmsetLowPowerSettings()) {
        self.settings = settings
    }

    func toggle(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !self.isBusy else { completion(.failure(SleepControlError.busy)); return }
        self.isBusy = true
        self.onChange?()
        self.settings.toggle { result in
            self.isBusy = false
            self.onChange?()
            completion(result)
        }
    }
}

internal final class PmsetLowPowerSettings: LowPowerSettings {
    private let command: QuickActionCommand.Runner
    private let queue = DispatchQueue(label: "eu.exelban.Stats.QuickActions.lowPower", qos: .userInitiated)

    var isEnabled: Bool {
        if #available(macOS 12.0, *) { return ProcessInfo.processInfo.isLowPowerModeEnabled }
        return false
    }

    init(command: @escaping QuickActionCommand.Runner = QuickActionCommand.run) {
        self.command = command
    }

    func toggle(completion: @escaping (Result<Void, Error>) -> Void) {
        self.queue.async {
            let result: Result<Void, Error> = Result {
                guard let current = QuickActionCommand.booleanSetting("lowpowermode", in: try self.read(["-g"])),
                      Self.parseProfiles(try self.read(["-g", "custom"])) != nil else {
                    throw QuickActionSystemError.lowPowerUnavailable
                }
                let enabled = !current
                let script = "do shell script \"/usr/bin/pmset -a lowpowermode \(enabled ? 1 : 0)\" with administrator privileges"
                let response = try self.command("/usr/bin/osascript", ["-e", script])
                guard response.status == 0 else { throw QuickActionSystemError.authorizationFailed }
                let profiles = Self.parseProfiles(try self.read(["-g", "custom"]))
                let active = QuickActionCommand.booleanSetting("lowpowermode", in: try self.read(["-g"]))
                guard let values = profiles, values.allSatisfy({ $0 == enabled }), active == enabled else {
                    throw QuickActionSystemError.verificationFailed
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func read(_ arguments: [String]) throws -> String {
        let response = try self.command("/usr/bin/pmset", arguments)
        guard response.status == 0 else { throw QuickActionSystemError.lowPowerUnavailable }
        return response.output
    }

    /// Require one valid value per reported power profile; never silently ignore an unsupported source.
    static func parseProfiles(_ text: String) -> [Bool]? {
        var values: [Bool] = []
        var profile: [String] = []
        var hasProfile = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") {
                if hasProfile {
                    guard let value = QuickActionCommand.booleanSetting("lowpowermode", in: profile.joined(separator: "\n")) else { return nil }
                    values.append(value)
                }
                hasProfile = true
                profile = []
            } else {
                profile.append(line)
            }
        }
        guard hasProfile, let value = QuickActionCommand.booleanSetting("lowpowermode", in: profile.joined(separator: "\n")) else { return nil }
        values.append(value)
        return values
    }
}
