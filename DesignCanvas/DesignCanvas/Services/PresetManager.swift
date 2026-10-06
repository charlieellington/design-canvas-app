// Loads the checked-in public `StylingPresets.json`. Keep its snapshots
// consistent with Generated/StylingPresets.swift when editing presets.
// in the Mac app. The Stage 14b dev cycler and the Stage 16a "Apply default
// style" dropdown both go through this. Snapshots are immutable — applying a
// preset COPIES the StylingConfig; the preset id is metadata only.

import Foundation

@MainActor
final class PresetManager {

    static let shared = PresetManager()

    struct PresetEntry: Equatable {
        let id: String
        let displayName: String
        let intendedMood: String?
        let status: String
        let config: StylingConfig
    }

    private(set) var presets: [PresetEntry] = []
    private(set) var presetsFinalised: Bool = false

    private init() {
        loadFromBundle()
    }

    /// Look up a preset by id. Returns nil if the slug is unknown or dropped.
    func preset(id: String) -> PresetEntry? {
        presets.first { $0.id == id }
    }

    /// Stage 14b dev cycler — index into the shipped preset list. Bounded;
    /// returns nil if `index` is out of range.
    func preset(atIndex index: Int) -> PresetEntry? {
        guard index >= 0, index < presets.count else { return nil }
        return presets[index]
    }

    // MARK: - Load

    private func loadFromBundle() {
        guard let url = Bundle.main.url(forResource: "StylingPresets", withExtension: "json") else {
            print("[PresetManager] StylingPresets.json missing from bundle — Mac styling will use canonicalDefault only")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let envelope = try JSONDecoder().decode(BundledEnvelope.self, from: data)
            self.presetsFinalised = envelope.presetsFinalised
            self.presets = envelope.presets.map { p in
                PresetEntry(
                    id: p.id,
                    displayName: p.displayName,
                    intendedMood: p.intendedMood,
                    status: p.status,
                    config: p.config
                )
            }
            print("[PresetManager] Loaded \(presets.count) presets; PRESETS_FINALISED=\(presetsFinalised)")
        } catch {
            print("[PresetManager] StylingPresets.json decode failed: \(error)")
        }
    }
}

// MARK: - Bundled envelope

private struct BundledEnvelope: Decodable {
    let schemaVersion: Int
    let presetsFinalised: Bool
    let presets: [BundledPreset]
}

private struct BundledPreset: Decodable {
    let id: String
    let displayName: String
    let intendedMood: String?
    let status: String
    let config: StylingConfig
}
