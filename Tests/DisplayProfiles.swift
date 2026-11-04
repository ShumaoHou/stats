import Cocoa

/// Standalone checks for the saved display layouts; run with Kit/scripts/run-quick-actions-tests.py.
/// A fake runner replaces displayplacer, so no display is touched.
struct DisplayProfileTests {
    private static var failures = 0
    private static var checks = 0

    private static let command = "displayplacer \"id:AAA-111 res:2560x1440 hz:60 color_depth:8 enabled:true scaling:off origin:(0,0) degree:0\" "
        + "\"id:BBB-222 res:1512x982 hz:120 color_depth:8 enabled:true scaling:on origin:(183,1440) degree:0\""

    private static let listing = """
    Persistent screen id: AAA-111
    Type: 27 inch external screen
    Resolution: 2560x1440
    Origin: (0,0) - main display

    Persistent screen id: BBB-222
    Type: MacBook built in screen
    Resolution: 1512x982

    Execute the command below to set your screens to the current arrangement.
    """ + "\n" + DisplayProfileTests.command

    static func run() -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stats-display-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        testCurrentCommand()
        testSaveAndReload(in: directory)
        testInvalidName(in: directory)
        testMatching(in: directory)
        testApply(in: directory)
        testMissingBinary(in: directory)
        print("DisplayProfiles: \(checks - failures)/\(checks) checks passed")
        return failures == 0
    }

    private static func controller(in directory: URL, binary: String? = "/usr/bin/false",
                                   run: @escaping QuickActionCommand.Runner = { _, _ in (0, "") }) -> DisplayProfileController {
        DisplayProfileController(binary: binary, directory: directory, command: run)
    }

    private static func testCurrentCommand() {
        let controller = self.controller(in: FileManager.default.temporaryDirectory)
        let command = controller.currentCommand(in: listing)
        check(command?.hasPrefix("displayplacer ") == true, "The ready-to-run command must be read from the listing")
        check(command?.contains("id:AAA-111") == true && command?.contains("id:BBB-222") == true,
              "Both screens must survive parsing")
        check(controller.connectedScreens(in: listing) == ["27 inch external screen", "MacBook built in screen"],
              "Connected screens must be reported in listing order")
        check(controller.suggestedName(in: listing) == "27-inch-external-screen",
              "The suggested name must describe the external screen; got \(controller.suggestedName(in: listing))")
        let legacy = "#!/bin/bash\nexport PATH=\"/opt/homebrew/bin:$PATH\"\n/opt/homebrew/bin/displayplacer \"id:AAA-111 res:2560x1440 hz:60\"\n"
        check(controller.currentCommand(in: legacy)?.hasPrefix("/opt/homebrew/bin/displayplacer ") == true,
              "Layouts written with an absolute displayplacer path must still be read")
        check(DisplayProfileController.screenIds(in: controller.currentCommand(in: legacy) ?? "") == ["AAA-111"],
              "Screen ids must be parsed from a legacy layout line")
    }

    private static func testSaveAndReload(in directory: URL) {
        let controller = self.controller(in: directory)
        do {
            let saved = try controller.save(name: "office", listing: listing)
            check(saved.name == "office" && saved.screenIds == ["AAA-111", "BBB-222"], "Saving must capture both screen ids")
            check(FileManager.default.isExecutableFile(atPath: saved.path), "A saved layout must stay executable for the shell")
            let text = (try? String(contentsOfFile: saved.path, encoding: .utf8)) ?? ""
            check(text.hasPrefix("#!/bin/bash") && text.contains("/opt/homebrew/bin"),
                  "Saved layouts must pin PATH so they also work from the app bundle")
            let reloaded = controller.profiles()
            check(reloaded.map { $0.name } == ["office"], "Reloading must find the saved layout; got \(reloaded.map { $0.name })")
            _ = try controller.save(name: "office", listing: listing)
            check(controller.profiles().count == 1, "Saving the same name must replace instead of duplicate")
        } catch {
            check(false, "Saving a layout must succeed: \(error.localizedDescription)")
        }
    }

    private static func testInvalidName(in directory: URL) {
        let controller = self.controller(in: directory)
        for name in ["", "   ", "a/b", "a:b"] {
            do {
                _ = try controller.save(name: name, listing: listing)
                check(false, "Invalid layout name \"\(name)\" must be rejected")
            } catch {}
        }
        check(controller.profiles().count == 1, "Rejected names must not create files")
    }

    private static func testMatching(in directory: URL) {
        let controller = self.controller(in: directory)
        do {
            _ = try controller.save(name: "home", listing: "displayplacer \"id:CCC-333 res:1920x1080 hz:75\" \"id:BBB-222 res:1512x982 hz:120\"")
        } catch {
            check(false, "Fixture layout must be writable")
        }
        check(controller.matchingProfile(in: listing)?.name == "office",
              "Only the layout whose screens are all connected may match; got \(String(describing: controller.matchingProfile(in: listing)?.name))")
        check(controller.matchingProfile(in: "displayplacer \"id:CCC-333 res:1920x1080 hz:75\" \"id:BBB-222 res:1512x982 hz:120\"")?.name == "home",
              "A layout without the external screen must match its own arrangement")
        check(controller.matchingProfile(in: "displayplacer \"id:DDD-444 res:1x1 hz:60\"") == nil,
              "An unknown arrangement must not match any saved layout")
    }

    private static func testApply(in directory: URL) {
        var calls: [[String]] = []
        let controller = self.controller(in: directory, run: { path, arguments in
            calls.append([path] + arguments)
            return (0, "")
        })
        guard let profile = controller.matchingProfile(in: listing) else {
            check(false, "The saved layout must be found before applying")
            return
        }
        do {
            try controller.apply(profile)
            check(calls.first?.first == "/bin/bash" && calls.first?.last == profile.path,
                  "Applying a layout must run its script through bash; got \(calls)")
        } catch {
            check(false, "Applying a saved layout must succeed: \(error.localizedDescription)")
        }
        let failing = self.controller(in: directory, run: { _, _ in (1, "boom") })
        do {
            try failing.apply(profile)
            check(false, "A failing script must be reported")
        } catch {
            check((error as? DisplayProfileError) == .applyFailed, "A failing script must surface as applyFailed")
        }
        let unmatched = self.controller(in: directory)
        do {
            _ = try unmatched.applyMatching(listing: "displayplacer \"id:DDD-444 res:1x1 hz:60\"")
            check(false, "Applying without a match must fail instead of guessing")
        } catch {}
    }

    private static func testMissingBinary(in directory: URL) {
        let controller = self.controller(in: directory, binary: nil)
        check(!controller.isAvailable, "A missing displayplacer must be reported as unavailable")
        do {
            _ = try controller.listing()
            check(false, "Listing without displayplacer must fail")
        } catch {
            check((error as? DisplayProfileError) == .unavailable, "A missing binary must surface as unavailable")
        }
    }

    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL: \(message)") }
    }
}

extension DisplayProfileError: Equatable {
    public static func == (lhs: DisplayProfileError, rhs: DisplayProfileError) -> Bool {
        lhs.localizedDescription == rhs.localizedDescription
    }
}
