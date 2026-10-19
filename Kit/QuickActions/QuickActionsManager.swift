//
//  QuickActionsManager.swift
//  Kit
//
//  Created by didi on 2026/10/18.
//  Using Swift 5.0
//  Running on macOS 10.15+
//

import Cocoa
import IOKit.pwr_mgt

public extension Notification.Name {
    static let quickActionsChanged = Notification.Name("quickActionsChanged")
}

public class QuickActionsManager {
    public static let shared = QuickActionsManager()
    
    // MARK: - Assertions & State
    
    private var displaySleepAssertionID: IOPMAssertionID = 0
    private let clamshell: ClamshellSleepController
    private let presentError: (String, String) -> Void

    public private(set) var isDisplaySleepPrevented: Bool = false
    public var isClamshellSleepPrevented: Bool { self.clamshell.isEnabled }
    public private(set) var isPreparingForExit = false
    public private(set) var isExitReady = false
    
    public var actions: [QuickActionItem] = []
    
    internal init(clamshell: ClamshellSleepController = ClamshellSleepController(),
                  presentError: @escaping (String, String) -> Void = { showAlert($0, $1, .warning) }) {
        self.clamshell = clamshell
        self.presentError = presentError
        self.clamshell.onChange = { NotificationCenter.default.post(name: .quickActionsChanged, object: nil) }
        self.setupDefaultActions()
    }
    
    deinit {
        self.cleanup()
    }
    
    // MARK: - Actions Setup
    
    private func setupDefaultActions() {
        self.actions = [
            QuickActionItem(
                id: "keep_awake",
                title: localizedString("Keep awake"),
                toolTip: localizedString("Prevent screen from sleeping"),
                iconName: "sun.max.fill",
                isToggle: true,
                isEnabled: { [weak self] in self?.isDisplaySleepPrevented ?? false },
                isAvailable: { [weak self] in self?.isPreparingForExit == false },
                action: { [weak self] _, completion in
                    guard let self = self else { completion(false); return }
                    self.toggleDisplaySleep(completion: completion)
                }
            ),
            QuickActionItem(
                id: "clamshell_sleep",
                title: localizedString("No sleep on lid"),
                toolTip: localizedString("Prevent sleep when lid is closed"),
                iconName: "laptopcomputer",
                isToggle: true,
                isEnabled: { [weak self] in self?.isClamshellSleepPrevented ?? false },
                isAvailable: { [weak self] in self?.isPreparingForExit == false && self?.clamshell.isBusy == false },
                action: { [weak self] _, completion in
                    guard let self = self else { completion(false); return }
                    self.toggleClamshellSleep(completion: completion)
                }
            ),
            QuickActionItem(
                id: "screensaver",
                title: localizedString("Screensaver"),
                toolTip: localizedString("Start screen saver"),
                iconName: "sparkles.tv",
                isToggle: false,
                isEnabled: { false },
                isAvailable: { [weak self] in self?.isPreparingForExit == false },
                action: { [weak self] _, completion in
                    self?.startScreenSaver()
                    completion(true)
                }
            )
        ]
    }
    
    // MARK: - 1. Prevent Screen Sleep (保持屏幕亮屏)
    
    public func toggleDisplaySleep(completion: ((Bool) -> Void)? = nil) {
        guard !self.isPreparingForExit else { completion?(self.isDisplaySleepPrevented); return }
        if self.isDisplaySleepPrevented {
            self.stopPreventingDisplaySleep()
        } else {
            self.startPreventingDisplaySleep()
        }
        completion?(self.isDisplaySleepPrevented)
        NotificationCenter.default.post(name: .quickActionsChanged, object: nil)
    }
    
    private func startPreventingDisplaySleep() {
        guard self.displaySleepAssertionID == 0 else {
            self.isDisplaySleepPrevented = true
            return
        }
        
        let reason = "Stats: Prevent User Idle Display Sleep" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &self.displaySleepAssertionID
        )
        
        if result == kIOReturnSuccess {
            self.isDisplaySleepPrevented = true
        } else {
            self.displaySleepAssertionID = 0
            self.isDisplaySleepPrevented = false
        }
    }
    
    private func stopPreventingDisplaySleep() {
        if self.displaySleepAssertionID != 0 {
            IOPMAssertionRelease(self.displaySleepAssertionID)
            self.displaySleepAssertionID = 0
        }
        self.isDisplaySleepPrevented = false
    }
    
    // MARK: - 2. Prevent Clamshell Sleep (合盖不休眠)
    
    public func toggleClamshellSleep(completion: ((Bool) -> Void)? = nil) {
        guard !self.isPreparingForExit, !self.clamshell.isBusy else {
            completion?(self.isClamshellSleepPrevented)
            return
        }
        self.clamshell.toggle { result in
            completion?(self.isClamshellSleepPrevented)
            if case .failure(let error) = result {
                var message = error.localizedDescription
                if self.clamshell.needsRestoration {
                    message += "\n" + localizedString("Click the lid button again to restore the original sleep setting.")
                }
                self.presentError(localizedString("Could not change lid sleep protection"), message)
            }
        }
    }

    /// Retain the guard through restart/install side effects. Errors release it so the user can retry.
    /// Completion is always deferred, allowing AppDelegate to return terminateLater first.
    public func prepareForExit(completion: @escaping (Result<Void, Error>) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.prepareForExit(completion: completion) }
            return
        }
        guard !self.isPreparingForExit else {
            DispatchQueue.main.async { completion(.failure(SleepControlError.busy)) }
            return
        }
        self.isPreparingForExit = true
        NotificationCenter.default.post(name: .quickActionsChanged, object: nil)
        DispatchQueue.main.async {
            self.clamshell.restore { result in
                switch result {
                case .success:
                    self.isExitReady = true
                case .failure:
                    self.cancelExitPreparation()
                }
                completion(result)
            }
        }
    }

    public func cancelExitPreparation() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.cancelExitPreparation() }
            return
        }
        self.isPreparingForExit = false
        self.isExitReady = false
        NotificationCenter.default.post(name: .quickActionsChanged, object: nil)
    }
    
    // MARK: - 3. Screen Saver (进入屏幕保护)
    
    public func startScreenSaver() {
        guard !self.isPreparingForExit else { return }
        // 关闭当前打开的 popup 窗口
        let openedWindows = NSApplication.shared.windows.filter{ $0 is NSPanel }
        openedWindows.forEach{ $0.setIsVisible(false) }
        
        let screenSaverURL = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: screenSaverURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil {
                // 回退到 open 命令
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", "ScreenSaverEngine"]
                try? process.run()
            }
        }
    }
    
    // MARK: - Cleanup
    
    /// Privileged restoration must finish in prepareForExit, never in deinit or willTerminate.
    public func cleanup() {
        self.stopPreventingDisplaySleep()
    }
}
