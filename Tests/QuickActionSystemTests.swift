import Cocoa

final class ManualLowPowerSettings: LowPowerSettings {
    var isEnabled = false
    var writes = 0
    var reply: ((Result<Void, Error>) -> Void)?
    func toggle(completion: @escaping (Result<Void, Error>) -> Void) {
        writes += 1
        reply = completion
    }
}

struct QuickActionSystemTests {
    private static var failures = 0
    private static var checks = 0

    static func run() -> Bool {
        testLockRequiresPermission()
        testLockShortcut()
        testLowPowerCommands()
        testUnsupportedAndCancelledLowPower()
        testLowPowerVerification()
        testPowerOperationAndExitGuards()
        print("QuickActionSystem: \(checks - failures)/\(checks) checks passed")
        return failures == 0
    }

    private static func testLockRequiresPermission() {
        var requests = 0
        var posts = 0
        let locker = ScreenLocker(hasAccess: { false }, requestAccess: { requests += 1; return false }, post: { _ in posts += 1 })
        do { try locker.lock(); check(false, "Missing Accessibility permission must be reported") } catch {}
        check(requests == 1 && posts == 0, "A denied lock request must not post keyboard events")
        var errors = 0
        let manager = QuickActionsManager(screenLocker: locker, presentError: { _, _ in errors += 1 })
        var completed: Bool?
        if let action = manager.actions.first(where: { $0.id == "lock_screen" }) { action.action(action) { completed = $0 } }
        check(completed == false && errors == 1 && posts == 0, "Lock action must report permission errors rather than claim success")
    }

    private static func testLockShortcut() {
        var events: [CGEvent] = []
        var requests = 0
        let locker = ScreenLocker(hasAccess: { true }, requestAccess: { requests += 1; return false }, post: { events.append($0) })
        do { try locker.lock() } catch { check(false, "Granted lock request must succeed") }
        check(requests == 0 && events.count == 2, "An authorized lock sends one key-down/up pair without asking again")
        if events.count == 2 {
            check(events[0].type == .keyDown && events[1].type == .keyUp, "Release the lock shortcut key")
            check(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 12 && $0.flags == [.maskControl, .maskCommand] },
                  "Use the system Control-Command-Q lock shortcut, never just display sleep")
        }
    }

    private static func testLowPowerCommands() {
        let calls = runLowPower(responses: [(0, "lowpowermode 0"), (0, profiles(0, 1)), (0, ""), (0, profiles(1, 1)), (0, "lowpowermode 1")], succeeds: true)
        check(calls == ["/usr/bin/pmset -g", "/usr/bin/pmset -g custom",
                        "/usr/bin/osascript -e do shell script \"/usr/bin/pmset -a lowpowermode 1\" with administrator privileges",
                        "/usr/bin/pmset -g custom", "/usr/bin/pmset -g"],
              "Enable uses fixed paths, updates every power source, and reads back both profiles and active state")
        let off = runLowPower(responses: [(0, "lowpowermode 1"), (0, profiles(1, 0)), (0, ""), (0, profiles(0, 0)), (0, "lowpowermode 0")], succeeds: true)
        check(off.contains("/usr/bin/osascript -e do shell script \"/usr/bin/pmset -a lowpowermode 0\" with administrator privileges"),
              "Turn off from a fresh system read, not a cached button value")
    }

    private static func testUnsupportedAndCancelledLowPower() {
        let missing = runLowPower(responses: [(0, "sleep 1\n")], succeeds: false)
        check(missing.count == 1, "Unsupported systems must not request administrator authorization")
        let unreadable = runLowPower(responses: [(1, "error")], succeeds: false)
        check(unreadable.count == 1, "Unreadable settings must not trigger writes")
        let cancelled = runLowPower(responses: [(0, "lowpowermode 0"), (0, profiles(0, 0)), (1, "cancelled")], succeeds: false)
        check(cancelled.count == 3, "Cancelled authorization has no fallback and no claimed success")
    }

    private static func testLowPowerVerification() {
        _ = runLowPower(responses: [(0, "lowpowermode 0"), (0, profiles(0, 0)), (0, ""), (0, profiles(1, 0)), (0, "lowpowermode 1")], succeeds: false)
        _ = runLowPower(responses: [(0, "lowpowermode 0"), (0, profiles(0, 0)), (0, ""), (0, profiles(1, 1)), (0, "lowpowermode 0")], succeeds: false)
        for invalid in ["", "Battery Power:\n sleep 1", "Battery Power:\n lowpowermode 2", "Battery Power:\n lowpowermode 1\n lowpowermode 0",
                        "Battery Power:\n sleep 1\nAC Power:\n lowpowermode 1"] {
            check(PmsetLowPowerSettings.parseProfiles(invalid) == nil, "Reject missing, invalid, or duplicated profile values")
        }
        check(PmsetLowPowerSettings.parseProfiles("AC Power:\n lowpowermode 0") == [false], "A desktop needs only its AC profile")
    }

    private static func testPowerOperationAndExitGuards() {
        let settings = ManualLowPowerSettings()
        let mode = LowPowerModeController(settings: settings)
        let sleep = ManualSleepSettings()
        var errors = 0
        let manager = QuickActionsManager(clamshell: ClamshellSleepController(settings: sleep), lowPower: mode, presentError: { _, _ in errors += 1 })
        manager.toggleLowPowerMode()
        manager.toggleLowPowerMode()
        manager.toggleClamshellSleep()
        check(settings.writes == 1 && sleep.readReplies.isEmpty && mode.isBusy, "Power authorizations must not overlap")
        check(manager.actions.filter { ["low_power_mode", "clamshell_sleep"].contains($0.id) }.allSatisfy { !$0.isAvailable() },
              "Both privileged power buttons must be disabled while a write is pending")
        var exitResult: Result<Void, Error>?
        manager.prepareForExit { exitResult = $0 }
        drainMain { exitResult != nil }
        if case .failure = exitResult {} else { check(false, "Exit must not abandon pending power authorization") }
        settings.reply?(.failure(QuickActionSystemError.authorizationFailed))
        check(!mode.isEnabled && !mode.isBusy && errors == 1, "Authorization failure must release the guard, retain actual state, and explain the error")
        manager.toggleLowPowerMode()
        settings.isEnabled = true
        settings.reply?(.success(()))
        check(mode.isEnabled && !mode.isBusy, "Show live system Low Power Mode after completion")
        exitResult = nil
        manager.prepareForExit { exitResult = $0 }
        drainMain { exitResult != nil }
        check(manager.isExitReady && settings.isEnabled && settings.writes == 2, "Low Power Mode must persist on normal exit")
        manager.toggleLowPowerMode()
        check(settings.writes == 2, "Prepared exit blocks new power changes")
        manager.cancelExitPreparation()
        settings.isEnabled = false
        check(!mode.isEnabled, "External system changes must not leave a stale enabled button")
        if #available(macOS 12.0, *) {
            var refreshes = 0
            let observer = NotificationCenter.default.addObserver(forName: .quickActionsChanged, object: nil, queue: .main) { _ in refreshes += 1 }
            NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: ProcessInfo.processInfo)
            NotificationCenter.default.removeObserver(observer)
            check(refreshes > 0, "A system power change must refresh existing popup buttons")
        }
        manager.toggleClamshellSleep()
        manager.toggleLowPowerMode()
        check(settings.writes == 2, "Lid authorization also blocks a new Low Power Mode operation")
        sleep.replyRead(.failure(SleepControlError.readFailed))
    }

    private static func runLowPower(responses: [(Int32, String)], succeeds: Bool) -> [String] {
        var pending = responses
        var calls: [String] = []
        let settings = PmsetLowPowerSettings(command: { path, args in
            calls.append(([path] + args).joined(separator: " "))
            guard !pending.isEmpty else { return (1, "unexpected command") }
            let response = pending.removeFirst()
            return (response.0, response.1)
        })
        var result: Result<Void, Error>?
        settings.toggle { result = $0; check(Thread.isMainThread, "Power completion must return to the main thread") }
        drainMain { result != nil }
        if case .success = result { check(succeeds, "Unverified or failed write must not report success") }
        else { check(!succeeds, "Verified power change should succeed") }
        return calls
    }

    private static func profiles(_ battery: Int, _ ac: Int) -> String {
        "Battery Power:\n sleep 1\n lowpowermode \(battery)\nAC Power:\n sleep 0\n lowpowermode \(ac)\n"
    }

    private static func drainMain(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(done(), "Asynchronous operation must finish")
    }

    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL: \(message)") }
    }
}
