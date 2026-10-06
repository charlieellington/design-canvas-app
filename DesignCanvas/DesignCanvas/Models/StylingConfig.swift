// Mirror of `web/src/lib/contracts/styling.ts` (Stage 13 Zod). Hand-written;
// MUST stay byte-compatible with the Zod schema's `{type, ...payload}`
// discriminator for the Background union, or share payloads fail validation.
// Custom Codable below decodes/encodes sibling-keyed JSON, NOT Swift's default
// associated-value shape `{"wallpaper": {...}}`.

import Foundation

struct StylingConfig: Codable, Equatable {

    var schemaVersion: Int = 1
    var preset: String? = nil
    var background: Background = .gradient(GradientBackground(
        gradientFrom: "#1a1a2e",
        gradientTo: "#16213e",
        gradientAngle: 135
    ))
    var backgroundBlur: Double = 0
    var corners: Double = 12
    var padding: Padding = Padding()
    var shadow: Shadow = Shadow()
    var frame: FrameChrome = .none

    enum FrameChrome: String, Codable, Equatable {
        case none, browser, device
    }

    enum Background: Equatable {
        case wallpaper(WallpaperBackground)
        case gradient(GradientBackground)
        case color(ColorBackground)
        case image(ImageBackground)
    }

    struct WallpaperBackground: Codable, Equatable {
        var wallpaperName: String
    }
    struct GradientBackground: Codable, Equatable {
        var gradientFrom: String
        var gradientTo: String
        var gradientAngle: Double = 180
    }
    struct ColorBackground: Codable, Equatable {
        var color: String = "#111214"
    }
    struct ImageBackground: Codable, Equatable {
        /// Public Blob URL after upload. Mac-local pending uploads live on the
        /// sibling `LocalImageBackground` struct outside the wire envelope.
        var imageUrl: String
    }

    /// Mac-only. Never serialised inside StylingConfig — Stage 16b's pre-flight
    /// uploads the bytes to Blob then sets ImageBackground.imageUrl.
    struct LocalImageBackground: Equatable {
        var fileURL: URL
        var pendingUpload: Bool
    }

    struct Padding: Codable, Equatable {
        var size: Double = 8
        var color: String = "#000000"
        var opacity: Double = 0.3
    }
    struct Shadow: Codable, Equatable {
        var enabled: Bool = true
        var intensity: Double = 0.6
        var directional: Bool = false
        var distance: Double = 8
        var angle: Double = 180
        var blur: Double = 24
    }
}

// MARK: - Background Codable (matches Zod's discriminated `type` field)

extension StylingConfig.Background: Codable {

    private enum CodingKeys: String, CodingKey { case type }
    private enum Kind: String, Codable { case wallpaper, gradient, color, image }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        let single = try decoder.singleValueContainer()
        switch kind {
        case .wallpaper: self = .wallpaper(try single.decode(StylingConfig.WallpaperBackground.self))
        case .gradient:  self = .gradient(try single.decode(StylingConfig.GradientBackground.self))
        case .color:     self = .color(try single.decode(StylingConfig.ColorBackground.self))
        case .image:     self = .image(try single.decode(StylingConfig.ImageBackground.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .wallpaper(let v):
            try container.encode(Kind.wallpaper, forKey: .type)
            try v.encode(to: encoder)
        case .gradient(let v):
            try container.encode(Kind.gradient, forKey: .type)
            try v.encode(to: encoder)
        case .color(let v):
            try container.encode(Kind.color, forKey: .type)
            try v.encode(to: encoder)
        case .image(let v):
            try container.encode(Kind.image, forKey: .type)
            try v.encode(to: encoder)
        }
    }
}

// MARK: - Canonical defaults

extension StylingConfig {
    /// Mirrors `DEFAULT_STYLING_CONFIG` from `web/src/lib/contracts/styling.ts`.
    /// Used by `PresetManager` when no per-canvas styling exists yet.
    static let canonicalDefault = StylingConfig()
}
