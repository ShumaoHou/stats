import Cocoa

/// Production entry-point bodies are compiled by the runner, replacing only OS side effects below.
var exitTestManager: QuickActionsManager!
let exitTestApplication = ExitTestApplication()
private var exitTestAlerts: [String] = []

func recordExitAlert(_ title: String, _ message: String? = nil, _ style: NSAlert.Style = .informational) {
    exitTestAlerts.append(title)
}

final class ExitTestApplication {
    typealias TerminateReply = NSApplication.TerminateReply
    var replies: [Bool] = []
    var terminations = 0
    func reply(toApplicationShouldTerminate allow: Bool) { replies.append(allow) }
    func terminate(_ sender: Any?) { terminations += 1 }
}

final class ExitTestProcess {
    static var launches = 0
    static var shouldFail = false
    static var wasGuarded = false
    var executableURL: URL?
    var arguments: [String]?
    func run() throws {
        Self.wasGuarded = exitTestManager.isExitReady
        if Self.shouldFail { throw CocoaError(.fileNoSuchFile) }
        Self.launches += 1
    }
}

class InstallerFixture {
    var installations = 0
    var wasGuarded = false
    func installAfterSleepRestored(path: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            self.installations += 1
            self.wasGuarded = exitTestManager.isExitReady
            completion("test installer failed")
        }
    }
}

struct QuickActionsLifecycleTests {
    private static var failures = 0
    private static var checks = 0

    static func run() -> Bool {
        testQuitWaitsAndCanBeCancelled()
        testRestartWaitsAndCanBeCancelled()
        testFailedRestartReleasesGuard()
        testUpdateWaitsAndCanBeCancelled()
        print("QuickActionsLifecycle: \(checks - failures)/\(checks) checks passed")
        return failures == 0
    }

    private static func testQuitWaitsAndCanBeCancelled() {
        let settings = setupEnabledSession()
        let delegate = ExitTestDelegate()
        check(delegate.applicationShouldTerminate(exitTestApplication) == .terminateLater, "Normal quit must defer")
        check(exitTestApplication.replies.isEmpty, "No quit reply before restoration")
        check(delegate.applicationShouldTerminate(exitTestApplication) == .terminateCancel, "Duplicate quit cannot race restoration")
        failRestoration(settings)
        check(exitTestApplication.replies == [false] && exitTestAlerts.count == 1, "Restore failure cancels quit and explains why")
        check(delegate.applicationShouldTerminate(exitTestApplication) == .terminateLater, "Quit can be retried")
        completeRestoration(settings)
        check(exitTestApplication.replies == [false, true], "Quit allowed only after verified restore")
        check(delegate.applicationShouldTerminate(exitTestApplication) == .terminateNow, "Already prepared exit needs no second restore")
    }

    private static func testRestartWaitsAndCanBeCancelled() {
        let settings = setupEnabledSession()
        testRestartApp("fixture")
        check(ExitTestProcess.launches == 0 && exitTestApplication.terminations == 0, "Restart has no side effects before restore")
        failRestoration(settings)
        check(ExitTestProcess.launches == 0 && exitTestApplication.terminations == 0 && !exitTestAlerts.isEmpty,
              "Failed restore must not launch a replacement or terminate the app")
        testRestartApp("fixture")
        completeRestoration(settings)
        check(ExitTestProcess.launches == 1 && exitTestApplication.terminations == 1 && ExitTestProcess.wasGuarded,
              "Restart runs exactly once after verified restore")
    }

    private static func testFailedRestartReleasesGuard() {
        let settings = setupEnabledSession()
        ExitTestProcess.shouldFail = true
        testRestartApp("fixture")
        completeRestoration(settings)
        check(!exitTestManager.isPreparingForExit && exitTestApplication.terminations == 0 && !exitTestAlerts.isEmpty,
              "A restart launch error must release the guard and keep Stats open")
    }

    private static func testUpdateWaitsAndCanBeCancelled() {
        let settings = setupEnabledSession()
        let updater = ExitTestUpdater()
        var failures: [String] = []
        updater.install(path: "unused-test-path") { if let error = $0 { failures.append(error) } }
        check(updater.installations == 0, "Updater must not mount or launch before restore")
        failRestoration(settings)
        check(updater.installations == 0 && failures.count == 1, "Restore failure prevents installer side effects")
        updater.install(path: "unused-test-path") { if let error = $0 { failures.append(error) } }
        completeRestoration(settings)
        drainMain { failures.count == 2 }
        check(updater.installations == 1 && updater.wasGuarded, "Installer starts only with power changes blocked")
        check(!exitTestManager.isPreparingForExit, "Installer failure must release the exit guard")
    }

    private static func setupEnabledSession() -> ManualSleepSettings {
        exitTestApplication.replies = []
        exitTestApplication.terminations = 0
        exitTestAlerts = []
        ExitTestProcess.launches = 0
        ExitTestProcess.shouldFail = false
        ExitTestProcess.wasGuarded = false
        let settings = ManualSleepSettings()
        let control = ClamshellSleepController(settings: settings)
        control.toggle { _ in }
        settings.replyRead(.success(false))
        settings.replyWrite(.success(()))
        settings.replyRead(.success(true))
        exitTestManager = QuickActionsManager(clamshell: control, presentError: { recordExitAlert($0, $1) })
        return settings
    }

    private static func failRestoration(_ settings: ManualSleepSettings) {
        drainMain { !settings.readReplies.isEmpty }
        settings.replyRead(.success(true))
        settings.replyWrite(.failure(SleepControlError.authorizationFailed))
        settings.replyRead(.success(true))
    }

    private static func completeRestoration(_ settings: ManualSleepSettings) {
        drainMain { !settings.readReplies.isEmpty }
        settings.replyRead(.success(true))
        settings.replyWrite(.success(()))
        settings.replyRead(.success(false))
    }

    private static func drainMain(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !done() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        check(done(), "Exit callback must complete")
    }

    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL: \(message)") }
    }
}
