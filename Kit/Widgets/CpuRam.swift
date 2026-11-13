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
    internal var lastCPU: String? { self.queue.sync { self.cpuLine } }
    internal var lastRAM: String? { self.queue.sync { self.ramLine } }

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
        self.queue.sync {
            cpuLine = self.cpuLine
            ramLine = self.ramLine
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

        for (line, y) in [(cpuLine, cpuY), (ramLine, ramY)] {
            guard let line else { continue }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .light),
                .foregroundColor: NSColor.textColor,
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
        self.setStrings(Self.format(cpu: value), self.lastRAM)
    }

    @objc private func ramUsageHandler(_ notification: Notification) {
        guard let used = notification.userInfo?["used"] as? Double else { return }
        self.setStrings(self.lastCPU, Self.format(ram: used))
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
