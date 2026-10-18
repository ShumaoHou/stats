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
    private var systemSleepAssertionID: IOPMAssertionID = 0
    
    public private(set) var isDisplaySleepPrevented: Bool = false
    public private(set) var isClamshellSleepPrevented: Bool = false
    
    public var actions: [QuickActionItem] = []
    
    private init() {
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
                action: { [weak self] _, completion in
                    self?.startScreenSaver()
                    completion(true)
                }
            )
        ]
    }
    
    // MARK: - 1. Prevent Screen Sleep (保持屏幕亮屏)
    
    public func toggleDisplaySleep(completion: ((Bool) -> Void)? = nil) {
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
        if self.isClamshellSleepPrevented {
            self.stopPreventingClamshellSleep()
            completion?(false)
            NotificationCenter.default.post(name: .quickActionsChanged, object: nil)
        } else {
            self.startPreventingClamshellSleep { [weak self] success in
                guard let self = self else { return }
                completion?(self.isClamshellSleepPrevented)
                NotificationCenter.default.post(name: .quickActionsChanged, object: nil)
            }
        }
    }
    
    private func startPreventingClamshellSleep(completion: @escaping (Bool) -> Void) {
        // 1. 创建 IOKit 系统休眠断言作为基础保护
        if self.systemSleepAssertionID == 0 {
            let reason = "Stats: Prevent System Sleep On Clamshell" as CFString
            let res = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &self.systemSleepAssertionID
            )
            if res != kIOReturnSuccess {
                self.systemSleepAssertionID = 0
            }
        }
        
        // 2. 尝试执行系统 pmset disablesleep 1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 先尝试无需密码执行
            let status = self.executePmset(disablesleep: true)
            
            DispatchQueue.main.async {
                if status {
                    self.isClamshellSleepPrevented = true
                    completion(true)
                } else {
                    // 如果普通执行失败（需提权），但系统断言已创建，仍标记激活（在有外接电源/显示器时生效）
                    self.isClamshellSleepPrevented = (self.systemSleepAssertionID != 0)
                    completion(self.isClamshellSleepPrevented)
                }
            }
        }
    }
    
    private func stopPreventingClamshellSleep() {
        // 1. 释放 IOKit 系统断言
        if self.systemSleepAssertionID != 0 {
            IOPMAssertionRelease(self.systemSleepAssertionID)
            self.systemSleepAssertionID = 0
        }
        
        // 2. 恢复 pmset disablesleep 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.executePmset(disablesleep: false)
        }
        
        self.isClamshellSleepPrevented = false
    }
    
    @discardableResult
    private func executePmset(disablesleep: Bool) -> Bool {
        let val = disablesleep ? "1" : "0"
        
        // 尝试直接通过 sh 调用
        let directCommand = "pmset disablesleep \(val)"
        let directProcess = Process()
        directProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        directProcess.arguments = ["-c", directCommand]
        let pipe = Pipe()
        directProcess.standardOutput = pipe
        directProcess.standardError = pipe
        
        do {
            try directProcess.run()
            directProcess.waitUntilExit()
            if directProcess.terminationStatus == 0 {
                return true
            }
        } catch {
            // Ignore and fall through to AppleScript
        }
        
        // 如果普通执行返回非 0，则尝试通过 AppleScript 请求管理员权限执行
        let scriptText = "do shell script \"pmset disablesleep \(val)\" with administrator privileges"
        var errorDict: NSDictionary? = nil
        if let script = NSAppleScript(source: scriptText) {
            script.executeAndReturnError(&errorDict)
            return errorDict == nil
        }
        
        return false
    }
    
    // MARK: - 3. Screen Saver (进入屏幕保护)
    
    public func startScreenSaver() {
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
    
    public func cleanup() {
        self.stopPreventingDisplaySleep()
        if self.isClamshellSleepPrevented {
            self.stopPreventingClamshellSleep()
        }
    }
}
