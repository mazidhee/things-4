import AppKit

final class AITranscriptView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        addSubviewPinned(scrollView)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -14)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clear() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
    }

    func addUser(_ text: String) {
        add(bubble(text, isUser: true))
    }

    func addAssistant(_ text: String) {
        add(bubble(text, isUser: false))
    }

    func addNote(_ text: String, color: NSColor = Theme.secondary) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Fonts.regular(11.5)
        label.textColor = color
        label.isSelectable = true
        add(label)
    }

    func addCard(_ view: NSView) {
        add(view)
    }

    func addTyping() -> NSView {
        let row = FlippedView()
        let label = NSTextField.label("Thinking…", font: Fonts.regular(12), color: Theme.tertiary)
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6)
        ])
        add(row)
        return row
    }

    func remove(_ view: NSView) {
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
    }

    private func bubble(_ text: String, isUser: Bool) -> NSView {
        let container = FlippedView()
        let bubble = RoundedCard(fill: isUser ? Theme.accent.withAlphaComponent(0.13) : Theme.card, bordered: false)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bubble)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Fonts.regular(12.5)
        label.textColor = Theme.text
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: container.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
            bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 300)
        ])

        if isUser {
            bubble.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 30).isActive = true
        } else {
            bubble.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor).isActive = true
        }
        return container
    }

    func scrollToBottom() {
        let height = documentView.bounds.height
        let visible = scrollView.contentSize.height
        guard height > visible else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: height - visible))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

// MARK: - Cards

final class AICardView: RoundedCard {
    private let titleLabel = NSTextField.label("", font: Fonts.semibold(12.5), color: Theme.text)
    private let bodyLabel = NSTextField.wrappingLabel("", font: Fonts.regular(11.5), color: Theme.secondary)
    private let actionButton = NSButton()
    private let target = CardTarget()

    init(title: String, body: String, actionTitle: String, action: @escaping () -> Void) {
        super.init(fill: Theme.cardElevated, bordered: true)

        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        bodyLabel.isSelectable = true

        actionButton.title = actionTitle
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.font = Fonts.medium(11.5)
        actionButton.contentTintColor = Theme.accent
        target.handler = action
        actionButton.target = target
        actionButton.action = #selector(CardTarget.fire)

        let stack = NSStackView(views: [titleLabel, bodyLabel, actionButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class CardTarget: NSObject {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

final class AITriageCard: RoundedCard {
    init(suggestions: [TriageSuggestion]) {
        super.init(fill: Theme.cardElevated, bordered: true)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let header = NSTextField.label("Suggested plan", font: Fonts.semibold(12.5), color: Theme.text)
        stack.addArrangedSubview(header)

        for suggestion in suggestions {
            guard let task = TaskStore.shared.task(suggestion.taskID) else { continue }
            let row = TriageRowView(task: task, suggestion: suggestion)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class TriageRowView: FlippedView {
    private let task: TaskItem
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let reasonLabel = NSTextField.label("", font: Fonts.regular(10.5), color: Theme.tertiary)
    private let actionLabel: String
    private let taskLabel = NSTextField.label("", font: Fonts.regular(12), color: Theme.text)
    private let suggestionLabel = NSTextField.label("", font: Fonts.medium(10), color: Theme.accent)

    init(task: TaskItem, suggestion: TriageSuggestion) {
        self.task = task
        self.actionLabel = suggestion.action
        super.init(frame: .zero)
        taskLabel.stringValue = task.title
        taskLabel.lineBreakMode = .byTruncatingTail
        reasonLabel.stringValue = suggestion.reason
        reasonLabel.lineBreakMode = .byTruncatingTail
        suggestionLabel.stringValue = suggestion.action.capitalized
        suggestionLabel.alignment = .right

        applyButton.bezelStyle = .inline
        applyButton.isBordered = false
        applyButton.controlSize = .mini
        applyButton.font = Fonts.medium(10.5)
        applyButton.contentTintColor = Theme.accent
        applyButton.target = self
        applyButton.action = #selector(apply)
        addSubview(taskLabel)
        addSubview(reasonLabel)
        addSubview(suggestionLabel)
        addSubview(applyButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = bounds.width
        taskLabel.frame = NSRect(x: 0, y: 0, width: width - 124, height: 16)
        reasonLabel.frame = NSRect(x: 0, y: 17, width: width - 124, height: 14)
        suggestionLabel.frame = NSRect(x: width - 116, y: 9, width: 62, height: 14)
        applyButton.frame = NSRect(x: width - 50, y: 8, width: 50, height: 15)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 36) }

    @objc private func apply() {
        switch actionLabel {
        case "defer": TaskStore.shared.setBucket(task.id, bucket: .scheduled, date: Date().startOfDay.addingDays(1))
        case "someday": TaskStore.shared.setBucket(task.id, bucket: .someday)
        case "complete": TaskStore.shared.toggleCompletion(task.id)
        default: TaskStore.shared.setBucket(task.id, bucket: .scheduled, date: Date().startOfDay)
        }
        applyButton.title = "Done"
        applyButton.isEnabled = false
    }
}

final class AISearchCard: RoundedCard {
    init(hits: [SearchHit], onOpen: @escaping (String) -> Void) {
        super.init(fill: Theme.cardElevated, bordered: true)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        if hits.isEmpty {
            stack.addArrangedSubview(NSTextField.wrappingLabel("No matches. Try describing the task differently.",
                                                               font: Fonts.regular(11.5), color: Theme.secondary))
        }

        for hit in hits {
            guard let task = TaskStore.shared.task(hit.taskID) else { continue }
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            let title = NSTextField.wrappingLabel(task.title, font: Fonts.regular(12), color: Theme.text)
            let why = NSTextField.label(hit.why, font: Fonts.regular(10.5), color: Theme.tertiary)
            let button = NSButton(title: "Open", target: nil, action: nil)
            button.bezelStyle = .inline
            button.isBordered = false
            button.controlSize = .mini
            button.font = Fonts.medium(10.5)
            button.contentTintColor = Theme.accent
            let target = SearchTarget()
            target.handler = { onOpen(hit.taskID) }
            SearchTarget.retained.append(target)
            button.target = target
            button.action = #selector(SearchTarget.fire)
            let textStack = NSStackView(views: [title, why])
            textStack.orientation = .vertical
            textStack.alignment = .leading
            textStack.spacing = 1
            row.addArrangedSubview(textStack)
            row.addArrangedSubview(button)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class SearchTarget: NSObject {
    static var retained: [SearchTarget] = []
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}


/// A rounded, optionally bordered surface that follows the appearance.
class RoundedCard: NSView {
    private let fillColor: NSColor
    private let bordered: Bool

    init(fill: NSColor = Theme.cardElevated, bordered: Bool = true) {
        self.fillColor = fill
        self.bordered = bordered
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        fillColor.setFill()
        path.fill()
        if bordered {
            Theme.separator.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
