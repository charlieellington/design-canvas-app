// What this file does (plain English):
// The data shapes for the toolbar's terminal-command palette — the little list of
// Big Terminal Mode commands (like "/effort high" or "/model opus") Charlie clicks
// to copy, or drags onto his terminal to prefill. A `TerminalCommand` is one row;
// a `TerminalCommandGroup` is a labelled section (Effort, Fast, Model, …). Both are
// Codable so the whole list round-trips to a human-editable JSON file.

import Foundation

struct TerminalCommand: Codable, Hashable, Identifiable {
    var label: String      // short human name, e.g. "High"
    var command: String    // the exact text copied/inserted, e.g. "/effort high"

    // Stable identity for SwiftUI lists; the command string is unique within a list.
    var id: String { command }
}

struct TerminalCommandGroup: Codable, Hashable, Identifiable {
    var title: String                  // section header, e.g. "Effort"
    var commands: [TerminalCommand]

    var id: String { title }
}
