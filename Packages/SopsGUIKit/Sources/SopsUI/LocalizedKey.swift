import Foundation
import SwiftUI

/// Every user-facing string this module can render.
///
/// Views never take a string literal. Adding a case without adding the matching
/// entry to Localizable.xcstrings fails `everyKeyResolves`.
public enum LocalizedKey: String, CaseIterable, Sendable {
    case sidebarProjects = "sidebar.projects"
    case sidebarAbout = "sidebar.about"
    case sidebarSettings = "sidebar.settings"
    case detailNoSelection = "detail.no-selection"
    case settingsWindowPlaceholder = "settings.window-placeholder"

    /// The resolved English text. Used in views and asserted in tests.
    public var text: String {
        String(localized: String.LocalizationValue(rawValue), bundle: .module)
    }
}

public extension Text {
    init(_ key: LocalizedKey) {
        self.init(key.text)
    }
}

public extension Label where Title == Text, Icon == Image {
    init(_ key: LocalizedKey, systemImage: String) {
        self.init(key.text, systemImage: systemImage)
    }
}
