//
//  DisplayProfileController.swift
//  Kit
//
//  Created by didi on 2026/11/04.
//  Using Swift 5.0
//  Running on macOS 10.15+
//

import Cocoa

internal enum DisplayProfileError: LocalizedError {
    case unavailable, listingFailed, noScreens, invalidName, saveFailed, applyFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return localizedString("displayplacer is not installed. Install it with Homebrew: brew install displayplacer")
        case .listingFailed:
            return localizedString("The connected displays could not be read.")
        case .noScreens:
            return localizedString("The current display layout could not be captured.")
        case .invalidName:
            return localizedString("Enter a layout name without path separators.")
        case .saveFailed:
            return localizedString("The display layout could not be saved.")
        case .applyFailed:
            return localizedString("The display layout could not be applied.")
        }
    }
}

/// One saved display layout. `screenIds` are the persistent display ids the layout was captured with.
internal struct DisplayProfile {
    let name: String
    let path: String
    let command: String
    let screenIds: [String]
}

/// Reads and writes the displayplacer layouts shared with the command line tooling.
internal final class DisplayProfileController {
    internal static let binaryPaths = ["/opt/homebrew/bin/displayplacer", "/usr/local/bin/displayplacer"]

    private let command: QuickActionCommand.Runner
    private let directory: URL
    private let binary: String?

    internal init(binary: String? = DisplayProfileController.locateBinary(),
                  directory: URL = DisplayProfileController.defaultDirectory,
                  command: @escaping QuickActionCommand.Runner = QuickActionCommand.run) {
        self.binary = binary
        self.directory = directory
        self.command = command
    }

    internal static func locateBinary() -> String? {
        DisplayProfileController.binaryPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    internal static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/displayplacer/profiles")
    }

    internal var isAvailable: Bool { self.binary != nil }

    /// Runs `displayplacer list` and returns its raw output.
    internal func listing() throws -> String {
        guard let binary = self.binary else { throw DisplayProfileError.unavailable }
        let result = try self.command(binary, ["list"])
        guard result.status == 0 else { throw DisplayProfileError.listingFailed }
        return result.output
    }

    /// Extracts the ready-to-run command displayplacer prints for the current arrangement.
    /// Accepts both `displayplacer ...` and an absolute path such as `/opt/homebrew/bin/displayplacer ...`.
    internal func currentCommand(in listing: String) -> String? {
        let pattern = try? NSRegularExpression(pattern: "^(?:\\S*/)?displayplacer\\s", options: [])
        return listing
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { line in
                guard let pattern = pattern else { return line.hasPrefix("displayplacer ") }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                return pattern.firstMatch(in: line, options: [], range: range) != nil
            }
    }

    /// Reads every saved layout, sorted by name.
    internal func profiles() -> [DisplayProfile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: self.directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".sh") }
            .sorted()
            .compactMap { file in
                let path = self.directory.appendingPathComponent(file)
                guard let text = try? String(contentsOf: path, encoding: .utf8),
                      let command = self.currentCommand(in: text) else { return nil }
                return DisplayProfile(
                    name: String(file.dropLast(3)),
                    path: path.path,
                    command: command,
                    screenIds: DisplayProfileController.screenIds(in: command)
                )
            }
    }

    /// Finds the layout whose screens are all connected right now.
    internal func matchingProfile(in listing: String) -> DisplayProfile? {
        self.profiles().first { profile in
            !profile.screenIds.isEmpty && profile.screenIds.allSatisfy { listing.contains($0) }
        }
    }

    /// Human readable summary of the connected screens, used to name and preview a layout.
    internal func connectedScreens(in listing: String) -> [String] {
        listing
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("Type:") else { return nil }
                return text.replacingOccurrences(of: "Type: ", with: "")
            }
    }

    /// Suggests a layout name based on the first external screen, ignoring the built in display.
    internal func suggestedName(in listing: String) -> String {
        let external = self.connectedScreens(in: listing).first { !$0.contains("built in") }
        guard let screen = external else { return "layout" }
        let allowed = screen.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let collapsed = allowed.split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "layout" : collapsed
    }

    /// Saves the current arrangement under `name`, replacing an existing layout with the same name.
    @discardableResult
    internal func save(name: String, listing: String) throws -> DisplayProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":") else { throw DisplayProfileError.invalidName }
        guard let command = self.currentCommand(in: listing), !DisplayProfileController.screenIds(in: command).isEmpty else {
            throw DisplayProfileError.noScreens
        }
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let script = "#!/bin/bash\nexport PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"\n\n\(command)\n"
            let path = self.directory.appendingPathComponent("\(trimmed).sh")
            try script.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            return DisplayProfile(name: trimmed, path: path.path, command: command,
                                  screenIds: DisplayProfileController.screenIds(in: command))
        } catch {
            throw DisplayProfileError.saveFailed
        }
    }

    /// Applies a saved layout by running its script, so PATH setup inside the file still applies.
    internal func apply(_ profile: DisplayProfile) throws {
        let result = try self.command("/bin/bash", [profile.path])
        guard result.status == 0 else { throw DisplayProfileError.applyFailed }
    }

    /// Applies the layout matching the connected screens, if there is one.
    @discardableResult
    internal func applyMatching(listing: String) throws -> DisplayProfile {
        guard let profile = self.matchingProfile(in: listing) else { throw DisplayProfileError.applyFailed }
        try self.apply(profile)
        return profile
    }

    internal static func screenIds(in command: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: "id:([^\\s\"]+)", options: [])
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return (pattern?.matches(in: command, options: [], range: range) ?? []).compactMap { match in
            guard let found = Range(match.range(at: 1), in: command) else { return nil }
            return String(command[found])
        }
    }
}
