import Cocoa

internal protocol SleepSettings {
    /// Completions run on the main thread; only the backend may perform privileged operations.
    func read(completion: @escaping (Result<Bool, Error>) -> Void)
    func write(_ disabled: Bool, completion: @escaping (Result<Void, Error>) -> Void)
}

internal enum SleepControlError: LocalizedError {
    case busy, readFailed, authorizationFailed, verificationFailed

    var errorDescription: String? {
        switch self {
        case .busy:
            return localizedString("A power operation is in progress. Complete or cancel authorization, then try again.")
        case .readFailed:
            return localizedString("Could not read the system sleep setting. No safe change can be confirmed.")
        case .authorizationFailed:
            return localizedString("Administrator authorization was cancelled or the sleep setting could not be changed.")
        case .verificationFailed:
            return localizedString("The sleep setting could not be verified. Click the lid button again to restore it before quitting.")
        }
    }
}

/// Main-thread policy. Only a verified change activates protection; uncertain writes retain recovery ownership.
internal final class ClamshellSleepController {
    private let settings: SleepSettings
    private var originalSleepDisabled: Bool?
    private(set) var isEnabled = false
    private(set) var isBusy = false
    var onChange: (() -> Void)?
    var needsRestoration: Bool { self.originalSleepDisabled == false }

    init(settings: SleepSettings = PmsetSleepSettings()) {
        self.settings = settings
    }

    func toggle(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !self.isBusy else { completion(.failure(SleepControlError.busy)); return }
        if self.isEnabled || self.needsRestoration {
            self.restore(completion: completion)
            return
        }
        self.isBusy = true
        self.onChange?()
        self.settings.read { result in
            switch result {
            case .failure(let error):
                self.finish(.failure(error), completion)
            case .success(let original):
                self.originalSleepDisabled = original
                if original {
                    self.isEnabled = true
                    self.finish(.success(()), completion)
                    return
                }
                self.settings.write(true) { writeResult in
                    // Even a failed command may have partially changed global state.
                    self.settings.read { readResult in
                        if case .success(false) = readResult { self.originalSleepDisabled = nil }
                        if case .success = writeResult, case .success(true) = readResult {
                            self.isEnabled = true
                            self.finish(.success(()), completion)
                        } else if case .failure(let error) = writeResult {
                            self.finish(.failure(error), completion)
                        } else {
                            self.finish(.failure(SleepControlError.verificationFailed), completion)
                        }
                    }
                }
            }
        }
    }

    func restore(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !self.isBusy else { completion(.failure(SleepControlError.busy)); return }
        guard self.needsRestoration else {
            // Stats did not change a pre-existing disablesleep=1, so must not reset it.
            self.clearSession()
            completion(.success(()))
            return
        }
        self.isBusy = true
        self.onChange?()
        self.settings.read { result in
            switch result {
            case .failure(let error):
                self.finish(.failure(error), completion)
            case .success(false):
                self.clearSession()
                self.finish(.success(()), completion)
            case .success(true):
                self.settings.write(false) { writeResult in
                    self.settings.read { readResult in
                        if case .success(false) = readResult {
                            self.clearSession()
                            self.finish(.success(()), completion)
                        } else if case .failure(let error) = writeResult {
                            self.finish(.failure(error), completion)
                        } else {
                            self.finish(.failure(SleepControlError.verificationFailed), completion)
                        }
                    }
                }
            }
        }
    }

    private func clearSession() {
        self.originalSleepDisabled = nil
        self.isEnabled = false
        self.onChange?()
    }

    private func finish(_ result: Result<Void, Error>, _ completion: (Result<Void, Error>) -> Void) {
        self.isBusy = false
        self.onChange?()
        completion(result)
    }
}

/// No shell/PATH fallback, no retained credentials, and no idle-sleep assertion masquerading as lid protection.
internal final class PmsetSleepSettings: SleepSettings {
    typealias Command = QuickActionCommand.Runner
    private let command: Command
    private let queue = DispatchQueue(label: "eu.exelban.Stats.QuickActions.power", qos: .userInitiated)

    init(command: @escaping Command = QuickActionCommand.run) {
        self.command = command
    }

    func read(completion: @escaping (Result<Bool, Error>) -> Void) {
        self.queue.async {
            let result: Result<Bool, Error> = Result {
                let response = try self.command("/usr/bin/pmset", ["-g"])
                guard response.status == 0, let disabled = Self.parseSleepDisabled(response.output) else {
                    throw SleepControlError.readFailed
                }
                return disabled
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func write(_ disabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        self.queue.async {
            let result: Result<Void, Error> = Result {
                let script = "do shell script \"/usr/bin/pmset disablesleep \(disabled ? 1 : 0)\" with administrator privileges"
                let response = try self.command("/usr/bin/osascript", ["-e", script])
                guard response.status == 0 else { throw SleepControlError.authorizationFailed }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func parseSleepDisabled(_ text: String) -> Bool? {
        QuickActionCommand.booleanSetting("SleepDisabled", in: text)
    }
}
