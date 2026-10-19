import Cocoa

/// Exercises production sleep policy with manual backend replies. Never invokes pmset or authorization.
struct ClamshellSleepTests {
    private static var checks = 0
    private static var failures = 0

    static func run() -> Bool {
        testEnableAndRestore()
        testCancelledAuthorization()
        testUnverifiedChangeRequiresRecovery()
        testExistingSettingIsNotOwned()
        testRestoreFailureAndRetry()
        testReadFailureAndRepeatedClicks()
        testExitGate()
        testCommandBoundary()
        print("ClamshellSleep: \(checks - failures)/\(checks) checks passed")
        return failures == 0
    }

    private static func testEnableAndRestore() {
        let settings = ManualSleepSettings()
        let control = ClamshellSleepController(settings: settings)
        var completed = false
        control.toggle { result in completed = result.isSuccess }
        check(control.isBusy && !control.isEnabled && !completed, "Enabling waits for authorization")
        settings.replyRead(.success(false))
        check(settings.writes == [true], "Enable writes disablesleep=1")
        settings.replyWrite(.success(()))
        check(!control.isEnabled && !completed, "Command success alone must not light the button")
        settings.replyRead(.success(true))
        check(control.isEnabled && control.needsRestoration && completed && !control.isBusy, "Verified enable owns restoration")
        completed = false
        control.restore { result in completed = result.isSuccess }
        settings.replyRead(.success(true))
        check(settings.writes == [true, false] && !completed, "Restore waits for setting change")
        settings.replyWrite(.success(()))
        check(control.isEnabled && !completed, "Do not claim restored before readback")
        settings.replyRead(.success(false))
        check(completed && !control.isEnabled && !control.needsRestoration, "Verified restore releases ownership")
    }

    private static func testCancelledAuthorization() {
        let settings = ManualSleepSettings()
        let control = ClamshellSleepController(settings: settings)
        var failed = false
        control.toggle { failed = !$0.isSuccess }
        settings.replyRead(.success(false))
        settings.replyWrite(.failure(SleepControlError.authorizationFailed))
        settings.replyRead(.success(false))
        check(failed && !control.isEnabled && !control.isBusy, "Cancelled/failed authorization must never activate protection")
        check(!control.needsRestoration, "Cancelled unchanged setting needs no privileged cleanup")
    }

    private static func testUnverifiedChangeRequiresRecovery() {
        for readback: Result<Bool, Error> in [.failure(SleepControlError.readFailed), .success(true)] {
            let settings = ManualSleepSettings()
            let control = ClamshellSleepController(settings: settings)
            var failed = false
            control.toggle { failed = !$0.isSuccess }
            settings.replyRead(.success(false))
            settings.replyWrite(.failure(SleepControlError.authorizationFailed))
            settings.replyRead(readback)
            check(failed && !control.isEnabled && control.needsRestoration, "Uncertain partial change remains recoverable, not enabled")
            control.toggle { _ in }
            settings.replyRead(.success(true))
            check(settings.writes == [true, false], "Next click recovers the failed attempt rather than enabling again")
            settings.replyWrite(.success(()))
            settings.replyRead(.success(false))
            check(!control.needsRestoration, "Recovery clears pending restoration")
        }
        let settings = ManualSleepSettings()
        let control = ClamshellSleepController(settings: settings)
        var failed = false
        control.toggle { failed = !$0.isSuccess }
        settings.replyRead(.success(false))
        settings.replyWrite(.success(()))
        settings.replyRead(.success(false))
        check(failed && !control.isEnabled, "Successful command with mismatched readback is not success")
    }

    private static func testExistingSettingIsNotOwned() {
        let settings = ManualSleepSettings()
        let control = ClamshellSleepController(settings: settings)
        control.toggle { _ in }
        settings.replyRead(.success(true))
        check(control.isEnabled && !control.needsRestoration && settings.writes.isEmpty, "Pre-existing disablesleep=1 is not changed")
        var restored = false
        control.restore { restored = $0.isSuccess }
        check(restored && !control.isEnabled && settings.writes.isEmpty && settings.readReplies.isEmpty,
              "Closing Stats must not reset a pre-existing system setting")
    }

    private static func testRestoreFailureAndRetry() {
        let settings = ManualSleepSettings()
        let control = enabledControl(settings)
        var restored = false
        control.restore { restored = $0.isSuccess }
        settings.replyRead(.success(true))
        settings.replyWrite(.failure(SleepControlError.authorizationFailed))
        settings.replyRead(.success(true))
        check(!restored && control.isEnabled && control.needsRestoration, "Failed restore must not clear active state or ownership")
        control.restore { restored = $0.isSuccess }
        settings.replyRead(.success(false))
        check(restored && !control.needsRestoration && settings.writes == [true, false],
              "Already-restored system needs no additional privileged command")
    }

    private static func testReadFailureAndRepeatedClicks() {
        let settings = ManualSleepSettings()
        let control = ClamshellSleepController(settings: settings)
        var rejected = false
        control.toggle { _ in }
        control.toggle { rejected = !$0.isSuccess }
        check(rejected && settings.readReplies.count == 1 && settings.writes.isEmpty, "Repeated clicks cannot overlap commands")
        settings.replyRead(.failure(SleepControlError.readFailed))
        check(!control.isBusy && !control.isEnabled && !control.needsRestoration, "Read failure fails closed without modifying settings")
    }

    private static func testExitGate() {
        let settings = ManualSleepSettings()
        let control = enabledControl(settings)
        let manager = QuickActionsManager(clamshell: control, presentError: { _, _ in })
        var reply: Bool?
        manager.prepareForExit { reply = $0.isSuccess }
        check(reply == nil && manager.isPreparingForExit, "Exit callback must be deferred until after terminateLater")
        drainMain { !settings.readReplies.isEmpty }
        check(manager.actions.allSatisfy { !$0.isAvailable() }, "All buttons disabled while preparing exit")
        settings.replyRead(.success(true))
        settings.replyWrite(.failure(SleepControlError.authorizationFailed))
        settings.replyRead(.success(true))
        check(reply == false && !manager.isExitReady && !manager.isPreparingForExit, "Failed restore cancels exit and permits retry")
        reply = nil
        manager.prepareForExit { reply = $0.isSuccess }
        drainMain { !settings.readReplies.isEmpty }
        settings.replyRead(.success(false))
        check(reply == true && manager.isExitReady && manager.isPreparingForExit, "Successful exit stays guarded against re-enabling")
        manager.toggleClamshellSleep()
        check(settings.readReplies.isEmpty, "Power cannot be re-enabled during restart/update")
        manager.cancelExitPreparation()
        check(!manager.isPreparingForExit && !manager.isExitReady, "Failed restart/update can release the exit guard")

        control.toggle { _ in }
        reply = nil
        manager.prepareForExit { reply = $0.isSuccess }
        drainMain { reply != nil }
        check(reply == false && !manager.isExitReady, "Quit during an in-flight enable must be rejected, not race it")
        settings.replyRead(.failure(SleepControlError.readFailed))
    }

    private static func testCommandBoundary() {
        for text in ["System-wide power settings:\n SleepDisabled\t\t0\n", " SleepDisabled 1\n"] {
            check(PmsetSleepSettings.parseSleepDisabled(text) != nil, "Parse exact global SleepDisabled field")
        }
        for text in ["sleep 1", "SleepDisabled 2", "SleepDisabled nonsense", "NotSleepDisabled 1", "SleepDisabled 0\nSleepDisabled 1"] {
            check(PmsetSleepSettings.parseSleepDisabled(text) == nil, "Reject missing/invalid sleep setting")
        }
        var command: (String, [String])?
        let settings = PmsetSleepSettings { path, arguments in
            command = (path, arguments)
            return (1, "User canceled. (-128)")
        }
        var result: Bool?
        settings.write(true) { result = $0.isSuccess }
        drainMain { result != nil }
        check(result == false, "Nonzero osascript exit is an authorization failure")
        check(command?.0 == "/usr/bin/osascript" && command?.1 == ["-e", "do shell script \"/usr/bin/pmset disablesleep 1\" with administrator privileges"],
              "Use fixed absolute tools and only the requested boolean, without a shell fallback")
        let readableSettings = PmsetSleepSettings { path, arguments in
            command = (path, arguments)
            return (0, "System-wide power settings:\n SleepDisabled 0\n")
        }
        var disabled: Bool?
        readableSettings.read { if case .success(let value) = $0 { disabled = value } }
        drainMain { disabled != nil }
        check(disabled == false && command?.0 == "/usr/bin/pmset" && command?.1 == ["-g"],
              "Read the actual global-setting field using a read-only command")
    }

    private static func enabledControl(_ settings: ManualSleepSettings) -> ClamshellSleepController {
        let control = ClamshellSleepController(settings: settings)
        control.toggle { _ in }
        settings.replyRead(.success(false))
        settings.replyWrite(.success(()))
        settings.replyRead(.success(true))
        return control
    }

    private static func drainMain(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !done() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        check(done(), "Asynchronous callback must complete")
    }

    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL: \(message)") }
    }
}

final class ManualSleepSettings: SleepSettings {
    var readReplies: [(Result<Bool, Error>) -> Void] = []
    var writeReplies: [(Result<Void, Error>) -> Void] = []
    var writes: [Bool] = []
    func read(completion: @escaping (Result<Bool, Error>) -> Void) { readReplies.append(completion) }
    func write(_ disabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        writes.append(disabled)
        writeReplies.append(completion)
    }
    func replyRead(_ result: Result<Bool, Error>) { readReplies.removeFirst()(result) }
    func replyWrite(_ result: Result<Void, Error>) { writeReplies.removeFirst()(result) }
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
