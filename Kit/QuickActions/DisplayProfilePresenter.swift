//
//  DisplayProfilePresenter.swift
//  Kit
//
//  Created by didi on 2026/11/04.
//  Using Swift 5.0
//  Running on macOS 10.15+
//

import Cocoa

/// Shows the display layout dialog: restore the layout matching the connected screens, or save the current one.
internal final class DisplayProfilePresenter {
    private enum Choice {
        case restore(DisplayProfile)
        case save
        case cancel

        var title: String {
            switch self {
            case .restore:
                return localizedString("Restore layout")
            case .save:
                return localizedString("Save current layout")
            case .cancel:
                return localizedString("Cancel")
            }
        }
    }

    private let controller: DisplayProfileController

    internal init(controller: DisplayProfileController = DisplayProfileController()) {
        self.controller = controller
    }

    internal func present() {
        guard self.controller.isAvailable else {
            showAlert(localizedString("Display layouts"), DisplayProfileError.unavailable.errorDescription, .warning)
            return
        }
        let listing: String
        do {
            listing = try self.controller.listing()
        } catch {
            showAlert(localizedString("Display layouts"), error.localizedDescription, .warning)
            return
        }

        let profiles = self.controller.profiles()
        let matching = self.controller.matchingProfile(in: listing)
        var choices: [Choice] = []
        if let matching = matching {
            choices.append(.restore(matching))
        }
        choices.append(.save)
        choices.append(.cancel)

        let alert = NSAlert()
        alert.messageText = localizedString("Display layouts")
        alert.informativeText = self.summary(listing: listing, profiles: profiles, matching: matching)
        alert.alertStyle = .informational
        for choice in choices {
            alert.addButton(withTitle: choice.title)
        }

        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard choices.indices.contains(index) else { return }
        switch choices[index] {
        case .restore(let profile):
            self.restore(profile: profile)
        case .save:
            self.save(listing: listing, suggested: matching?.name ?? self.controller.suggestedName(in: listing))
        case .cancel:
            break
        }
    }

    private func summary(listing: String, profiles: [DisplayProfile], matching: DisplayProfile?) -> String {
        var lines = [localizedString("Current displays: %0", self.controller.connectedScreens(in: listing).joined(separator: ", "))]
        if profiles.isEmpty {
            lines.append(localizedString("No saved display layouts yet."))
        } else {
            lines.append(localizedString("Saved layouts: %0", profiles.map { $0.name }.joined(separator: ", ")))
            if let matching = matching {
                lines.append(localizedString("Matching layout: %0", matching.name))
            } else {
                lines.append(localizedString("No saved layouts match the connected displays."))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func restore(profile: DisplayProfile) {
        do {
            try self.controller.apply(profile)
            showAlert(localizedString("Display layouts"), localizedString("Restored display layout: %0", profile.name))
        } catch {
            showAlert(localizedString("Display layouts"), error.localizedDescription, .warning)
        }
    }

    private func save(listing: String, suggested: String) {
        let alert = NSAlert()
        alert.messageText = localizedString("Save display layout")
        alert.informativeText = localizedString("Enter a name for this display layout. An existing layout with the same name is replaced.")
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = suggested
        alert.accessoryView = field
        alert.addButton(withTitle: localizedString("Save"))
        alert.addButton(withTitle: localizedString("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let profile = try self.controller.save(name: field.stringValue, listing: listing)
            showAlert(localizedString("Display layouts"), localizedString("Saved display layout: %0", profile.name))
        } catch {
            showAlert(localizedString("Display layouts"), error.localizedDescription, .warning)
        }
    }
}
