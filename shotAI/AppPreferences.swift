import CaptureKit
import SwiftUI

/// The app's color-theme preference (Appearance tab). `system` follows the OS.
/// Mirrors the Windows `ThemePref`.
enum ThemePref: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var blurb: String {
        switch self {
        case .system: "Match your macOS light/dark setting."
        case .light: "Always use the light theme."
        case .dark: "Always use the dark theme."
        }
    }

    /// SwiftUI color-scheme override; nil = follow the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// App-level preferences beyond capture permissions (Permissions tab) and SOP
/// settings (AI tab): the UI theme, the export byline, and capture quality /
/// window visibility. Persisted as JSON in UserDefaults, exactly like
/// `SopSettings`. The byline + capture fields mirror the Windows settings.json.
struct AppPreferences: Codable, Equatable, Sendable {
    var theme: ThemePref = .system
    /// Display name shown in exported documents' footer when opted in. Default ''.
    var userName: String = ""
    /// Opt-in to include `userName` in reports/exports. Default false.
    var includeNameInReports: Bool = false
    /// Screenshot-quality downscale (CaptureConstants.captureScaleMin…Max).
    var captureScale: Double = Double(CaptureConstants.captureScale)
    /// Keep the shotAI window visible during capture (default false = hide it so
    /// it isn't in the shot).
    var captureNoHide: Bool = false

    /// Max characters kept for the display name.
    static let userNameMax = 120

    /// The byline to hand exports, or nil when not opted in / blank.
    var exportByline: String? {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return includeNameInReports && !trimmed.isEmpty ? trimmed : nil
    }

    /// Coerce hand-edited / older-version values into range. Called after decode
    /// and after any UI mutation.
    mutating func normalize() {
        captureScale = Double(CaptureConstants.clampCaptureScale(CGFloat(captureScale)))
        if userName.count > Self.userNameMax {
            userName = String(userName.prefix(Self.userNameMax))
        }
    }

    init() {}

    /// Tolerant decode: each key falls back to its default when absent or
    /// invalid, so adding a field in a later version (or a partial/corrupt blob)
    /// never discards the user's other saved preferences. Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let d = AppPreferences()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        theme = (try? c.decodeIfPresent(ThemePref.self, forKey: .theme)) ?? d.theme
        userName = (try? c.decodeIfPresent(String.self, forKey: .userName)) ?? d.userName
        includeNameInReports = (try? c.decodeIfPresent(Bool.self, forKey: .includeNameInReports)) ?? d.includeNameInReports
        captureScale = (try? c.decodeIfPresent(Double.self, forKey: .captureScale)) ?? d.captureScale
        captureNoHide = (try? c.decodeIfPresent(Bool.self, forKey: .captureNoHide)) ?? d.captureNoHide
    }
}
