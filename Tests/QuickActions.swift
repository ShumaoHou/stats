import Cocoa

/// Standalone AppKit regression tests; run with Kit/scripts/run-quick-actions-tests.py.
/// Actions are replaced before any click, so tests never change power settings or start the screen saver.
@main
struct QuickActionsLayoutTests {
    private static var failures = 0
    private static var checks = 0
    private static var clickedIDs: [String] = []

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let sleepTestsPassed = ClamshellSleepTests.run()
        let lifecycleTestsPassed = QuickActionsLifecycleTests.run()
        verifyUnavailableButton()
        QuickActionsManager.shared.actions = QuickActionsManager.shared.actions.map { original in
            var item = original
            item.action = { action, completion in
                clickedIDs.append(action.id)
                completion(true)
            }
            return item
        }

        for module in [ModuleType.combined, .CPU] {
            let body = PopupWrapper(module, frame: NSRect(x: 0, y: 0, width: 264, height: 250))
            let window = PopupWindow(title: module == .combined ? "Combined modules" : "CPU", module: module, view: body) { _ in }
            defer { window.orderOut(nil) }
            guard let root = window.contentView as? PopupView,
                  let bar = root.subviews.compactMap({ $0 as? QuickActionsView }).first else {
                check(false, "Popup must contain a quick-action strip")
                continue
            }

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for height: CGFloat in [250, 400, 200] {
                    body.setFrameSize(NSSize(width: 264, height: height))
                    body.sizeCallback?(body.frame.size)
                    for _ in 0..<2 {
                        root.appear()
                        root.layoutSubtreeIfNeeded()
                        verifyLayout(root: root, bar: bar)
                        root.disappear()
                    }
                }
                if module == .combined, let directory = ProcessInfo.processInfo.environment["QUICK_ACTIONS_SCREENSHOTS"] {
                    root.layoutSubtreeIfNeeded()
                    guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                        check(false, "Unable to capture AppKit rendering")
                        continue
                    }
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    let language = Bundle.main.preferredLocalizations.first ?? "en"
                    let path = URL(fileURLWithPath: directory).appendingPathComponent("\(language)-\(appearance.rawValue).png")
                    try bitmap.representation(using: .png, properties: [:])?.write(to: path)
                }
            }
        }
        print("QuickActions: \(checks - failures)/\(checks) checks passed (\(Bundle.main.preferredLocalizations.joined(separator: ",")))")
        exit(failures == 0 && sleepTestsPassed && lifecycleTestsPassed ? 0 : 1)
    }

    private static func verifyUnavailableButton() {
        var available = false
        var clicks = 0
        let item = QuickActionItem(id: "test", title: "Test", toolTip: "Test", iconName: "laptopcomputer",
                                   isAvailable: { available }, action: { _, completion in clicks += 1; completion(true) })
        let button = QuickActionButton(item: item)
        button.performClick(nil)
        check(!button.isEnabled && clicks == 0, "Unavailable action must be disabled and not run")
        available = true
        button.updateState()
        button.performClick(nil)
        check(button.isEnabled && clicks == 1, "Button becomes available after completion")
        available = false
        button.performClick(nil)
        check(clicks == 1, "Queued clicks must recheck availability before running")
    }

    private static func verifyLayout(root: NSView, bar: QuickActionsView) {
        // A constraint-driven strip without an external size collapses to 32×0.
        check(abs(bar.frame.width - root.bounds.width) < 1 && abs(bar.frame.height - 38) < 1,
              "Strip must retain the popup's frame-based size; got \(bar.frame)")
        check(!bar.hasAmbiguousLayout, "Strip must not have ambiguous layout")
        if let header = root.subviews.first(where: { $0 is HeaderView }),
           let scroll = root.subviews.first(where: { $0 is NSScrollView }) {
            check(abs(bar.frame.maxY - header.frame.minY) < 1 && bar.frame.minY >= scroll.frame.maxY,
                  "Strip must remain between the header and original content")
        }
        let buttons = descendants(bar).compactMap { $0 as? QuickActionButton }
        check(buttons.count == 3, "Exactly three buttons must survive repeated opening")
        for (index, button) in buttons.enumerated() {
            let rect = button.convert(button.bounds, to: bar)
            check(rect.width >= 60 && rect.height >= 24 && bar.bounds.contains(rect),
                  "Button \(index) must have a visible frame inside the strip; got \(rect)")
            for label in descendants(button).compactMap({ $0 as? NSTextField }) {
                check(!label.stringValue.isEmpty && label.bounds.width > 0, "Button \(index) must have a visible label")
                if Bundle.main.preferredLocalizations.first == "zh-Hans" {
                    let textWidth = label.cell!.cellSize.width
                    check(label.bounds.width >= textWidth,
                          "Chinese button \(index) title must fit without truncation: \(label.bounds.width) < \(textWidth)")
                }
                let labelRect = label.convert(label.bounds, to: button)
                check(labelRect.minX >= -2 && labelRect.maxX <= button.bounds.maxX + 2,
                      "Button \(index) text must not overflow into adjacent buttons; got \(labelRect)")
            }
            // hitTest receives a point in the superview's coordinates, not in the button's bounds.
            for fraction: CGFloat in [0.15, 0.5, 0.85] {
                let point = button.convert(NSPoint(x: button.bounds.width * fraction, y: button.bounds.midY), to: root)
                let hit = root.hitTest(point)
                check(hit === button, "Button \(index) must own clicks across its surface; hit \(String(describing: hit.map { type(of: $0) }))")
            }
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: root)
            let count = clickedIDs.count
            (root.hitTest(point) as? QuickActionButton)?.performClick(nil)
            let expectedID = QuickActionsManager.shared.actions[index].id
            check(clickedIDs.count == count + 1 && clickedIDs.last == expectedID,
                  "Click must invoke only the intended action: \(expectedID)")
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}
