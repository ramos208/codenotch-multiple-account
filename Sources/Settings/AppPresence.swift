import AppKit

/// Where Codenotch shows itself, apart from the notch.
///
/// The notch is the product; this is only about how the *app* is reached — to
/// open settings, or to quit it. Three states because the two obvious ones
/// leave a gap: a Dock tile is easy to find and permanent, a menu bar item is
/// out of the way but still there, and some people want neither.
enum AppPresence: String, CaseIterable, Identifiable {
    /// A normal app with both a Dock tile and a persistent menu bar shortcut.
    case dock
    /// An icon in the menu bar, and nothing in the Dock.
    case menuBar
    /// Neither. Only the notch itself.
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dock:    return L10n.t("Dock + Menu bar")
        case .menuBar: return L10n.t("Menu bar")
        case .hidden:  return L10n.t("Neither")
        }
    }

    var explanation: String {
        switch self {
        case .dock:
            return L10n.t("Icons in both the Dock and menu bar. Closing the window leaves Codenotch and the notch running; use the menu bar icon to reopen it.")
        case .menuBar:
            return L10n.t("A small icon in the menu bar instead, and nothing in the Dock.")
        case .hidden:
            // Said here because choosing this removes every visible way back to
            // these settings, and finding that out afterwards is too late.
            return L10n.t("No icon anywhere. Open Codenotch again from Applications to bring these settings back.")
        }
    }

    /// `.regular` is the only one that gets a Dock tile. Both others are
    /// accessory apps; what separates them is whether a status item is made.
    var activationPolicy: NSApplication.ActivationPolicy {
        self == .dock ? .regular : .accessory
    }

    /// The Dock mode also keeps a menu bar shortcut. A window can be closed
    /// while the notch continues running, and this leaves an obvious way to
    /// reopen Settings without relying on the Dock window still being visible.
    var wantsStatusItem: Bool { self != .hidden }
}
