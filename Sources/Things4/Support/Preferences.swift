import AppKit

extension Notification.Name {
    static let preferencesChanged = Notification.Name("Things4.preferencesChanged")
}

enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Non-AI preferences. AI provider settings live in `AISettings`.
enum Preferences {
    private static let defaults = UserDefaults.standard

    static var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: "pref.appearance") ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "pref.appearance")
            apply()
            changed()
        }
    }

    /// When off, every AI entry point disappears: the sidebar, the sparkles
    /// buttons, the Enhance action and the menu item.
    static var aiEnabled: Bool {
        get { defaults.object(forKey: "pref.aiEnabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "pref.aiEnabled")
            changed()
        }
    }

    /// Notion-style cover on Today (see `Covers` for the spec format). THINGS4_COVER overrides it for snapshots.
    static var todayCover: String? {
        get {
            if let override = ProcessInfo.processInfo.environment["THINGS4_COVER"] { return override.isEmpty ? nil : override }
            return defaults.string(forKey: "pref.todayCover")
        }
        set {
            let old = defaults.string(forKey: "pref.todayCover")
            if old != newValue { Covers.discard(old) }
            defaults.set(newValue, forKey: "pref.todayCover")
            defaults.set(0.5, forKey: "pref.todayCoverOffset")
            changed()
        }
    }

    /// Vertical focus of an image cover, 0 = top, 1 = bottom.
    static var todayCoverOffset: CGFloat {
        get { CGFloat(defaults.object(forKey: "pref.todayCoverOffset") as? Double ?? 0.5) }
        set { defaults.set(Double(newValue), forKey: "pref.todayCoverOffset") }
    }

    static var showDockBadge: Bool {
        get { defaults.object(forKey: "pref.dockBadge") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "pref.dockBadge")
            changed()
        }
    }

    static var quickEntryEnabled: Bool {
        get { defaults.object(forKey: "pref.quickEntry") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "pref.quickEntry")
            changed()
        }
    }

    static var calendarsEnabled: Bool {
        get { defaults.object(forKey: "pref.calendars") as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: "pref.calendars")
            CalendarService.shared.invalidate()
            changed()
        }
    }

    /// "No Thanks" on the calendar prompt card.
    static var calendarPromptDismissed: Bool {
        get { defaults.bool(forKey: "pref.calendarPromptDismissed") }
        set { defaults.set(newValue, forKey: "pref.calendarPromptDismissed"); changed() }
    }

    static var hiddenCalendarIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "pref.hiddenCalendars") ?? []) }
        set {
            defaults.set(Array(newValue), forKey: "pref.hiddenCalendars")
            CalendarService.shared.invalidate()
        }
    }

    /// Things: "Move completed items to Logbook" — immediately (after a short pause) or at the end of the day.
    static var logImmediately: Bool {
        get { defaults.object(forKey: "pref.logImmediately") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pref.logImmediately"); changed() }
    }

    /// Things' Text Size slider: 0.85 … 1.3, 1.0 = default.
    static var textScale: CGFloat {
        get { CGFloat(defaults.object(forKey: "pref.textScale") as? Double ?? 1.0) }
        set { defaults.set(Double(newValue), forKey: "pref.textScale"); changed() }
    }

    /// Things' "Group to-dos in the Today list by project or area".
    static var groupToday: Bool {
        get { defaults.object(forKey: "pref.groupToday") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "pref.groupToday"); changed() }
    }

    /// To-dos the user has already seen in Today (drives the yellow "new" dots).
    static var seenToday: Set<String> {
        get { Set(defaults.stringArray(forKey: "pref.seenToday") ?? []) }
        set { defaults.set(Array(newValue), forKey: "pref.seenToday") }
    }

    /// Mirror reminders into Apple Reminders so iPhone and Apple Watch alert too.
    static var phoneReminders: Bool {
        get { defaults.object(forKey: "pref.phoneReminders") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pref.phoneReminders"); changed() }
    }

    static var phoneReminderListID: String? {
        get { defaults.string(forKey: "pref.phoneReminderList") }
        set { defaults.set(newValue, forKey: "pref.phoneReminderList") }
    }

    /// Lets other apps and agents use the URL scheme and the local API.
    static var apiEnabled: Bool {
        get { defaults.object(forKey: "pref.apiEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pref.apiEnabled"); changed() }
    }

    static var apiPort: UInt16 {
        get { (defaults.object(forKey: "pref.apiPort") as? Int).flatMap { UInt16(exactly: $0) } ?? APIConfig.defaultPort }
        set { defaults.set(Int(newValue), forKey: "pref.apiPort") }
    }

    static var menuBarEnabled: Bool {
        get { defaults.object(forKey: "pref.menuBar") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pref.menuBar"); changed() }
    }

    static var sidebarVisible: Bool {
        get { defaults.object(forKey: "pref.sidebarVisible") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pref.sidebarVisible") }
    }

    static func apply() {
        NSApp.appearance = appearance.appearance
    }

    private static func changed() {
        NotificationCenter.default.post(name: .preferencesChanged, object: nil)
    }
}
