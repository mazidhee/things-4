import Foundation

/// Per-window state. `shared` is the state of the frontmost Things window, so
/// menus, shortcuts and Quick Entry act on the window you are looking at.
final class AppState {
    static let primary = AppState()
    static var shared: AppState { MainWindowController.active?.state ?? primary }

    init(selection: Selection = .builtin(.today)) {
        self.selection = selection
    }

    var selection: Selection = .builtin(.today) {
        didSet {
            guard selection != oldValue else { return }
            NotificationCenter.default.post(name: .selectionDidChange, object: self)
        }
    }

    var isAIPanelVisible = false
    var aiDestination: AIDestination = .chat
}

enum AIDestination: String, CaseIterable {
    case chat
    case capture
    case plan
    case triage
    case search

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .capture: return "Capture"
        case .plan: return "Plan"
        case .triage: return "Triage"
        case .search: return "Search"
        }
    }

    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right"
        case .capture: return "plus.bubble"
        case .plan: return "map"
        case .triage: return "list.number"
        case .search: return "magnifyingglass"
        }
    }
}
