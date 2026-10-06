// What this file does (plain English):
// Owns the list of commands shown in the toolbar's terminal-command palette. Ships
// a sensible default set (effort / fast / model / workflow) and, on first run,
// writes it to a human-editable JSON file at
//   ~/Library/Application Support/DesignCanvas/terminal-commands.json
// so Charlie can add his own. The popover calls `reload()` each time it opens, so
// edits made in an external editor show up without restarting the app. We never
// overwrite a file the user has edited unless it's missing — a broken edit falls
// back to the defaults in memory but leaves the file alone so it can be fixed.

import Foundation
import Observation
import AppKit

@Observable
@MainActor
final class TerminalCommandsStore {
    private(set) var groups: [TerminalCommandGroup] = []

    /// `~/Library/Application Support/DesignCanvas/terminal-commands.json`
    /// (same Application-Support home as SessionPersistence).
    let fileURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent("\(BuildPolicy.dataDirectoryName)/terminal-commands.json")
        loadOrSeed()
    }

    /// Re-read the file so external edits appear. Called when the popover opens.
    /// A decode failure keeps the current list rather than blanking the palette.
    func reload() {
        if let loaded = readFromDisk() { groups = loaded }
    }

    /// Open the backing JSON in the user's default editor so they can add/edit
    /// commands. Mirrors the "Open Log File" idiom in DesignCanvasApp.
    func openForEditing() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            writeToDisk(groups.isEmpty ? Self.defaults : groups)
        }
        NSWorkspace.shared.open(fileURL)
    }

    // MARK: - Load / seed / save

    private func loadOrSeed() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Use the file if it decodes; otherwise keep defaults in memory but
            // DON'T overwrite — leave the user's (broken) JSON so they can fix it.
            groups = readFromDisk() ?? Self.defaults
        } else {
            groups = Self.defaults
            writeToDisk(groups)   // first run — seed a file there's something to edit
        }
    }

    private func readFromDisk() -> [TerminalCommandGroup]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.groups
    }

    private func writeToDisk(_ groups: [TerminalCommandGroup]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: 1, groups: groups))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[TerminalCommandsStore] write failed: \(error)")
        }
    }

    /// Versioned wrapper so the file format has room to grow without breaking
    /// older builds.
    private struct Envelope: Codable {
        var schemaVersion: Int
        var groups: [TerminalCommandGroup]
    }

    // MARK: - Defaults

    static let defaults: [TerminalCommandGroup] = [
        TerminalCommandGroup(title: "Effort", commands: [
            TerminalCommand(label: "Low", command: "/effort low"),
            TerminalCommand(label: "Medium", command: "/effort medium"),
            TerminalCommand(label: "High", command: "/effort high"),
            TerminalCommand(label: "Extra high", command: "/effort xhigh"),
            TerminalCommand(label: "Max", command: "/effort max"),
            TerminalCommand(label: "Auto", command: "/effort auto"),
        ]),
        TerminalCommandGroup(title: "Fast", commands: [
            TerminalCommand(label: "Toggle fast mode", command: "/fast"),
        ]),
        TerminalCommandGroup(title: "Model", commands: [
            TerminalCommand(label: "Opus 4.8", command: "/model opus"),
            TerminalCommand(label: "Sonnet 4.6", command: "/model sonnet"),
            TerminalCommand(label: "Haiku 4.5", command: "/model haiku"),
            TerminalCommand(label: "Fable 5", command: "/model fable"),
            TerminalCommand(label: "Opus 1M", command: "/model opus[1m]"),
        ]),
        TerminalCommandGroup(title: "Workflow", commands: [
            TerminalCommand(label: "Brief", command: "/brief"),
            TerminalCommand(label: "Big plan", command: "/bigplan"),
            TerminalCommand(label: "Execute", command: "/execute"),
        ]),
    ]
}
