import Cocoa

/// Unit tests for the CPU+RAM two-line widget; run with Kit/scripts/run-quick-actions-tests.py.
/// Values are injected directly; no CPU/RAM reader runs here.
struct CpuRamWidgetTests {
    private static var failures = 0
    private static var checks = 0

    static func run() -> Bool {
        testFormatting()
        testRenderingAndWidth()
        testPartialDataAndNoData()
        testNotificationUpdates()
        testColorModes()
        print("CpuRamWidget: \(checks - failures)/\(checks) checks passed")
        return failures == 0
    }

    private static func testFormatting() {
        check(CpuRamWidget.format(cpu: 0.427) == "43%", "CPU line must round to whole percent")
        check(CpuRamWidget.format(cpu: 0.0) == "0%", "CPU zero must render as 0%")
        check(CpuRamWidget.format(cpu: 1) == "100%", "CPU full must render as 100%")
        check(CpuRamWidget.format(ram: 0) == "0.0 GB", "RAM zero must render as 0.0 GB")
        check(CpuRamWidget.format(ram: 17_179_869_184 - 3_000_000_000) == "13.2 GB", "RAM must show one decimal in GB")
        check(CpuRamWidget.format(ram: 1_073_741_824) == "1.0 GB", "One GiB must render as 1.0 GB")
        check(CpuRamWidget.format(ram: 536_870_912) == "0.5 GB", "Half GiB renders with one decimal")
    }

    private static func testRenderingAndWidth() {
        let widget = mountedWidget()
        check(widget.frame.height <= Constants.Widget.height, "Widget must fit the menu bar height")
        check(widget.setStrings("CPU: 43%", "RAM: 13.2 GB"), "First values must mark the widget dirty")
        drainMain()
        let full = widget.shadowSize.width
        check(full > 0, "Both values present must produce a usable width")
        check(!widget.setStrings("CPU: 43%", "RAM: 13.2 GB"), "Identical values must not trigger redraw")
        check(widget.setStrings("CPU: 44%", "RAM: 13.2 GB"), "Changed CPU must trigger redraw")
        check(widget.setStrings("CPU: 44%", "RAM: 13.9 GB"), "Changed RAM must trigger redraw")
    }

    private static func testPartialDataAndNoData() {
        let widget = mountedWidget()
        widget.setStrings("CPU: 12%", nil)
        drainMain()
        check(widget.shadowSize.width > 0, "A single line must still reserve width")
        let single = widget.shadowSize.width
        widget.setStrings("CPU: 12%", "RAM: 8.0 GB")
        drainMain()
        check(widget.lastRAM == "RAM: 8.0 GB", "Applied RAM line is observable")
        check(widget.shadowSize.width >= single, "Second line widens or keeps the widget width")
        widget.setStrings("CPU: 12%", "RAM: 999999999 GB")
        drainMain()
        let wide = widget.shadowSize.width
        check(wide > single, "A wider line must widen the widget; got \(wide) vs \(single)")
        widget.setStrings(nil, "RAM: 8.0 GB")
        drainMain()
        check(widget.shadowSize.width > 0, "RAM-only must keep the widget visible")
        widget.setStrings(nil, nil)
        drainMain()
        widget.setStrings(nil, nil)
        check(widget.lastCPU == nil && widget.lastRAM == nil && widget.setStrings(nil, nil) == false,
              "No data at all must collapse the widget without repeated redraws")
    }

    private static func testNotificationUpdates() {
        let widget = CpuRamWidget(title: "CPU", config: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView?.addSubview(widget)
        window.orderFrontRegardless()
        NotificationCenter.default.post(name: .cpuUsageUpdate, object: nil, userInfo: ["value": 0.55])
        drainMain()
        check(widget.lastCPU == "55%", "CPU module broadcast must update the CPU line")
        NotificationCenter.default.post(name: .ramUsageUpdate, object: nil, userInfo: [
            "used": 8 * 1_073_741_824.0, "usage": 0.5,
        ])
        drainMain()
        check(widget.lastRAM == "8.0 GB", "RAM module broadcast must update the RAM line")
        NotificationCenter.default.post(name: .cpuUsageUpdate, object: nil, userInfo: [:])
        drainMain()
        check(widget.lastCPU == "55%", "Malformed broadcast must not clear good data")
    }

    private static func testColorModes() {
        let widget = CpuRamWidget(title: "CPU", config: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView?.addSubview(widget)
        window.orderFrontRegardless()
        widget.setStrings("CPU: 43%", "RAM: 13.2 GB")
        drainMain()
        check(widget.cpuColor(for: 0.43) == 0.43.usageColor(), "CPU line must default to utilization-based color")
        check(widget.ramColor(pressure: .normal) == RAMPressure.normal.pressureColor(), "RAM line must default to pressure-based color")
        check(widget.ramColor(pressure: .critical) == RAMPressure.critical.pressureColor(), "Critical pressure must turn the RAM line red")
        check(widget.ramColor(pressure: .normal, usage: 0.99) == RAMPressure.normal.pressureColor(), "Pressure mode ignores RAM usage")

        widget.setCPUColor(SColor.monochrome.key)
        check(widget.cpuColor(for: 0.99) == (isDarkMode ? NSColor.white : NSColor.black), "CPU monochrome ignores utilization")
        widget.setRAMColor(SColor.utilization.key)
        check(widget.ramColor(pressure: .normal, usage: 0.9) == 0.9.usageColor(), "RAM utilization mode ignores pressure")
        widget.setRAMColor(SColor.custom(NSColor.purple).key)
        let customRAM = widget.ramColor(pressure: .critical, usage: 0.99)
        check(customRAM == NSColor.purple || abs(customRAM.redComponent - NSColor.purple.redComponent) < 0.02,
              "RAM custom color ignores both modes; got \(customRAM)")
        widget.setRAMColor(SColor.pressure.key)

        NotificationCenter.default.post(name: .ramUsageUpdate, object: nil, userInfo: [
            "used": 8.0 * 1_073_741_824, "usage": 0.5, "pressure": RAMPressure.warning,
        ])
        drainMain()
        check(widget.lastPressure == "warning", "RAM broadcast must carry the pressure level; got \(String(describing: widget.lastPressure))")
        check(widget.ramColor() == RAMPressure.warning.pressureColor(), "Stored pressure colors the RAM line")

        check(widget.settings().subviews.count > 0, "Widget settings must exist")
    }

    /// draw() only runs when the view has a window host; provide one like the menubar does.
    private static func mountedWidget() -> CpuRamWidget {
        let widget = CpuRamWidget(title: "CPU", config: nil, preview: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView?.addSubview(widget)
        window.orderFrontRegardless()
        return widget
    }

    private static func drainMain() {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL: \(message)") }
    }
}
