import AppKit
import GoooeeeCore
import Observation
import SwiftUI

/// App settings, persisted as JSON in user defaults. Changes apply live in every window.
@MainActor
@Observable
final class SettingsStore {
    private static let key = "goooeee.appSettings"

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            revision += 1
        }
    }

    /// Bumped on every change; the transcript re-renders when it changes.
    private(set) var revision = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func resetToDefaults() {
        settings = AppSettings()
    }

    // MARK: Font scale (⌘+ / ⌘− / ⌘0)

    func increaseTextSize() { settings.textScale = min(2.5, (settings.textScale + 0.1).rounded(toTenths: true)) }
    func decreaseTextSize() { settings.textScale = max(0.6, (settings.textScale - 0.1).rounded(toTenths: true)) }
    func resetTextSize() { settings.textScale = 1 }

    // MARK: Fonts

    func nsFont(for role: TextRole, weight: NSFont.Weight = .regular) -> NSFont {
        Self.nsFont(settings.font(for: role), monospaced: role == .code, weight: weight)
    }

    func swiftUIFont(for role: TextRole) -> Font {
        Font(nsFont(for: role))
    }

    static func nsFont(_ spec: FontSpec, monospaced: Bool = false, weight: NSFont.Weight = .regular) -> NSFont {
        let size = CGFloat(spec.size)
        if let family = spec.family, !family.isEmpty {
            if family == "SF Mono" || family == "System Monospaced" {
                return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            }
            if let font = NSFont(name: family, size: size) {
                return weight == .regular ? font : NSFontManager.shared.convert(font, toHaveTrait: weight.rawValue >= NSFont.Weight.semibold.rawValue ? .boldFontMask : [])
            }
        }
        return monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    }

    var colorScheme: ColorScheme? {
        switch settings.colorScheme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private extension Double {
    func rounded(toTenths: Bool) -> Double { (self * 10).rounded() / 10 }
}
