import AppKit
import UserNotifications

extension Notification.Name {
    static let focusTimerChanged = Notification.Name("Things4.focusTimerChanged")
}

/// A Pomodoro-style focus session tied to one to-do.
final class FocusTimer {
    static let shared = FocusTimer()

    private(set) var taskID: String?
    private(set) var duration: TimeInterval = 25 * 60
    private var endDate: Date?
    private var pausedRemaining: TimeInterval?
    private var ticker: Timer?
    private var startedAt: Date?

    var isRunning: Bool { taskID != nil }
    var isPaused: Bool { pausedRemaining != nil }
    var task: TaskItem? { taskID.flatMap { TaskStore.shared.task($0) } }

    var remaining: TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSinceNow)
    }

    var progress: Double { duration > 0 ? 1 - remaining / duration : 0 }

    var remainingText: String {
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func start(taskID: String, minutes: Int = 25) {
        logElapsed()
        self.taskID = taskID
        startedAt = Date()
        duration = TimeInterval(minutes * 60)
        endDate = Date().addingTimeInterval(duration)
        pausedRemaining = nil
        startTicker()
        ReminderService.shared.requestAuthorization()
        changed()
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        pausedRemaining = remaining
        endDate = nil
        ticker?.invalidate()
        changed()
    }

    func resume() {
        guard let pausedRemaining else { return }
        endDate = Date().addingTimeInterval(pausedRemaining)
        self.pausedRemaining = nil
        startTicker()
        changed()
    }

    func addMinutes(_ minutes: Int) {
        guard isRunning else { return }
        duration += TimeInterval(minutes * 60)
        if let p = pausedRemaining { pausedRemaining = p + TimeInterval(minutes * 60) }
        else { endDate = (endDate ?? Date()).addingTimeInterval(TimeInterval(minutes * 60)) }
        changed()
    }

    func stop() {
        logElapsed()
        ticker?.invalidate()
        taskID = nil
        endDate = nil
        pausedRemaining = nil
        changed()
    }

    /// Completes the to-do and ends the session.
    func completeTask() {
        logElapsed()
        if let id = taskID, TaskStore.shared.task(id)?.isOpen == true { TaskStore.shared.toggleCompletion(id) }
        stop()
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    private func tick() {
        if remaining <= 0 { finish() } else { changed() }
    }

    private func finish() {
        ticker?.invalidate()
        let title = task?.title ?? "Focus session"
        let minutes = Int(duration / 60)
        logElapsed()
        NSSound(named: "Glass")?.play()
        if Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = "Focus session complete"
            content.body = "\(minutes) minutes on “\(title)”. Take a short break."
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "focus-\(UUID().uuidString)", content: content, trigger: nil))
        }
        taskID = nil
        endDate = nil
        changed()
    }

    /// Writes the time focused so far onto the to-do. A minute or less isn't worth logging.
    private func logElapsed() {
        guard let id = taskID, let startedAt else { return }
        let seconds = Int(duration - remaining)
        self.startedAt = nil
        guard seconds >= 60 else { return }
        TaskStore.shared.logTime(id, seconds: seconds, start: startedAt, source: "Focus Timer")
    }

    private func changed() {
        NotificationCenter.default.post(name: .focusTimerChanged, object: nil)
    }
}
