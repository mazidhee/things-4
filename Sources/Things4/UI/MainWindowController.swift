import AppKit
import QuartzCore

final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MainWindowController(state: .primary)
    private static var extra: [MainWindowController] = []

    /// The window the user is working in (key, else main, else the first window).
    static var active: MainWindowController? {
        if let c = NSApp.keyWindow?.windowController as? MainWindowController { return c }
        if let c = NSApp.mainWindow?.windowController as? MainWindowController { return c }
        return nil
    }

    let state: AppState
    let root: RootViewController

    /// Things' "New Window" / "Open in New Window".
    @discardableResult
    static func openNew(selection: Selection) -> MainWindowController {
        let controller = MainWindowController(state: AppState(selection: selection))
        extra.append(controller)
        if let reference = active?.window ?? shared.window {
            controller.window?.setFrame(reference.frame.offsetBy(dx: 28, dy: -28), display: false)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private convenience init(state: AppState) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "Things 4"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 760, height: 520)
        window.backgroundColor = Theme.window
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window, state: state)
        window.contentViewController = root
        window.delegate = self
        if state === AppState.primary { window.setFrameAutosaveName("Things4.MainWindow") }
    }

    func windowWillClose(_ notification: Notification) {
        MainWindowController.extra.removeAll { $0 === self }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    init(window: NSWindow?, state: AppState) {
        self.state = state
        self.root = RootViewController(state: state)
        super.init(window: window)
    }

    /// Edit > Undo and Redo drive the store's undo stack.
    /// Typing inside text fields gets its own history, so ⌘Z in a field undoes typing
    /// and ⌘Z elsewhere undoes to-do changes; the two never mix.
    let textUndoManager = UndoManager()

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        window.firstResponder is NSText ? textUndoManager : TaskStore.shared.undoManager
    }
}
