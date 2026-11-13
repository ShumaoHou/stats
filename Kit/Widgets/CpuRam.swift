//
//  CpuRam.swift
//  Kit
//
//  Two-line menubar widget: CPU usage percentage on top, used RAM in GB below.
//  Data comes from CPU and RAM module broadcasts, so the widget works in both
//  combined mode (inside the shared status item) and standalone CPU icons.
//

import Cocoa

public class CpuRamWidget: WidgetWrapper {
    private var cpuLine: String? = nil
    private var ramLine: String? = nil
    private var cpuColorState: SColor = .utilization
    private var ramColorState: SColor = .pressure
    private var cpuUsage: Double = 0
    private var ramUsage: Double = 0
    private var ramPressure: RAMPressure = .normal
    internal var lastCPU: String? { self.queue.sync { self.cpuLine } }
    internal var lastRAM: String? { self.queue.sync { self.ramLine } }
    internal var lastPressure: String? { self.queue.sync { self.ramPressure.rawValue } }

    private let width: CGFloat = 40

    public init(title: String, config: NSDictionary?, preview: Bool = false) {
        if config != nil, preview,
           let previewConfig = config!["Preview"] as? NSDictionary {
            if let value = previewConfig["CPU"] as? String {
                self.cpuLine = value
            }
            if let value = previewConfig["RAM"] as? String {
                self.ramLine = value
            }
        }

        super.init(.cpuRam, title: title, frame: CGRect(
            x: Constants.Widget.margin.x,
            y: Constants.Widget.margin.y,
            width: self.width + (Constants.Widget.margin.x*2),
            height: Constants.Widget.height - (2*Constants.Widget.margin.y)
        ))

        self.canDrawConcurrently = true

        if !preview {
            self.cpuColorState = SColor.fromString(
                Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_cpuColor", defaultValue: self.cpuColorState.key),
                defaultValue: self.cpuColorState
            )
            self.ramColorState = SColor.fromString(
                Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_ramColor", defaultValue: self.ramColorState.key),
                defaultValue: self.ramColorState
            )
        }

        if !preview {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.cpuUsageHandler),
                name: .cpuUsageUpdate,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.ramUsageHandler),
                name: .ramUsageUpdate,
                object: nil
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .cpuUsageUpdate, object: nil)
        NotificationCenter.default.removeObserver(self, name: .ramUsageUpdate, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Reports whether the stored lines changed, so callers/tests can detect real updates.
    @discardableResult
    public func setStrings(_ cpu: String?, _ ram: String?) -> Bool {
        let updated = self.queue.sync { () -> Bool in
            guard self.cpuLine != cpu || self.ramLine != ram else { return false }
            self.cpuLine = cpu
            self.ramLine = ram
            return true
        }
        guard updated else { return false }
        DispatchQueue.main.async(execute: {
            self.needsDisplay = true
        })
        return true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        var cpuLine: String? = nil
        var ramLine: String? = nil
        var cpuColor: NSColor = .textColor
        var ramColor: NSColor = .textColor
        self.queue.sync {
            cpuLine = self.cpuLine
            ramLine = self.ramLine
            cpuColor = self.lineColor(self.cpuColorState, usage: self.cpuUsage, pressure: self.ramPressure)
            ramColor = self.lineColor(self.ramColorState, usage: self.ramUsage, pressure: self.ramPressure)
        }

        guard cpuLine != nil || ramLine != nil else {
            self.setWidth(0)
            return
        }

        let textSize = self.appearanceTextSize(defaultValue: 9)
        let rowHeight = self.frame.height / 2
        let style = NSMutableParagraphStyle()
        style.alignment = .right

        let cpuY = rowHeight + 1
        let ramY: CGFloat = 1
        var maxTextWidth: CGFloat = 0

        for (line, y, color) in [(cpuLine, cpuY, cpuColor), (ramLine, ramY, ramColor)] {
            guard let line else { continue }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .light),
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
            let size = line.size(withAttributes: attributes)
            maxTextWidth = max(maxTextWidth, size.width)
            line.draw(
                with: CGRect(x: 0, y: y, width: size.width, height: rowHeight),
                options: [.usesLineFragmentOrigin],
                attributes: attributes
            )
        }

        self.setWidth(maxTextWidth + (Constants.Widget.margin.x*2))
    }

    @objc private func cpuUsageHandler(_ notification: Notification) {
        guard let value = notification.userInfo?["value"] as? Double, value >= 0, value <= 1 else { return }
        self.queue.sync { self.cpuUsage = value }
        self.setStrings(Self.format(cpu: value), self.lastRAM)
    }

    @objc private func ramUsageHandler(_ notification: Notification) {
        guard let used = notification.userInfo?["used"] as? Double else { return }
        let usage = notification.userInfo?["usage"] as? Double
        let pressure = (notification.userInfo?["pressure"] as? String).flatMap(RAMPressure.init)
            ?? (notification.userInfo?["pressure"] as? RAMPressure)
        self.queue.sync {
            self.ramUsage = usage ?? self.ramUsage
            if let pressure { self.ramPressure = pressure }
        }
        self.setStrings(self.lastCPU, Self.format(ram: used))
    }

    internal func cpuColor(for usage: Double) -> NSColor {
        self.queue.sync { self.lineColor(self.cpuColorState, usage: usage, pressure: self.ramPressure) }
    }

    internal func ramColor(pressure: RAMPressure? = nil, usage: Double? = nil) -> NSColor {
        self.queue.sync {
            self.lineColor(
                self.ramColorState,
                usage: usage ?? self.ramUsage,
                pressure: pressure ?? self.ramPressure
            )
        }
    }

    internal func setCPUColor(_ key: String) {
        self.queue.sync { self.cpuColorState = SColor.fromString(key, defaultValue: self.cpuColorState) }
        self.display()
    }

    internal func setRAMColor(_ key: String) {
        self.queue.sync { self.ramColorState = SColor.fromString(key, defaultValue: self.ramColorState) }
        self.display()
    }

    /// Same palette logic as single-module widgets: utilization zones, RAM pressure, monochrome or a fixed color.
    private func lineColor(_ color: SColor, usage: Double, pressure: RAMPressure) -> NSColor {
        switch color {
        case .utilization: return usage.usageColor()
        case .pressure: return pressure.pressureColor()
        case .monochrome: return isDarkMode ? NSColor.white : NSColor.black
        case .systemAccent: return .controlAccentColor
        default:
            if color.isCustom, let custom = color.additional as? NSColor { return custom }
            return (color.additional as? NSColor) ?? .textColor
        }
    }

    public override func settings() -> NSView {
        let view = SettingsContainerView()
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("CPU color"), component: colorSelectView(
                action: #selector(self.toggleCPUColor),
                items: SColor.allCases.filter { $0 != .pressure && $0 != .cluster },
                selected: self.cpuColorState.key
            )),
            PreferencesRow(localizedString("RAM color"), component: colorSelectView(
                action: #selector(self.toggleRAMColor),
                items: SColor.allCases.filter { $0 != .cluster },
                selected: self.ramColorState.key
            ))
        ]))
        view.addArrangedSubview(self.appearanceSettings(defaultTextSize: 9, defaultSpacing: 2))
        return view
    }

    @objc private func toggleCPUColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        self.setCPUColor(key)
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_cpuColor", value: key)
    }

    @objc private func toggleRAMColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        self.setRAMColor(key)
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_ramColor", value: key)
    }

    internal static func format(cpu: Double? = nil, ram: Double? = nil) -> String {
        if let cpu {
            return "\(Int((cpu * 100).rounded()))%"
        }
        if let ram {
            return String(format: "%.1f GB", ram / 1_073_741_824)
        }
        return ""
    }
}
