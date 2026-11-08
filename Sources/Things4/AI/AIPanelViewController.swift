import AppKit

final class AIPanelViewController: NSViewController, NSTextViewDelegate {
    var onClose: (() -> Void)?

    private let header = FlippedView()
    private let titleLabel = NSTextField.label("AI", font: Fonts.semibold(14), color: Theme.text)
    private let providerLabel = NSTextField.label("", font: Fonts.regular(10.5), color: Theme.tertiary)
    private let sparkle = NSImageView()
    private let closeButton = IconButton(symbol: "xmark", size: 11, color: Theme.tertiary, tooltip: "Close AI sidebar")
    private let settingsButton = IconButton(symbol: "gearshape", size: 12, color: Theme.tertiary, tooltip: "AI settings")

    private let tabsStack = NSStackView()
    private var tabButtons: [AIDestination: NSButton] = [:]
    private let transcriptView = AITranscriptView()

    private let composer = RoundedCard()
    private let inputScroll = NSScrollView()
    private let inputView = PlaceholderTextView()
    private let sendButton = NSButton()
    private let hintLabel = NSTextField.label("⌘↩ to send", font: Fonts.regular(9.5), color: Theme.tertiary)

    private var destination: AIDestination = .chat
    private var chatHistory: [AIMessage] = []
    private var isWorking = false
    private var typingView: NSView?

    override func loadView() {
        let root = FlippedView(fill: Theme.panel)
        view = root

        // Header
        header.fill = Theme.panel
        root.addSubview(header)
        sparkle.image = NSImage.symbol("sparkles", size: 14, weight: .semibold, color: Theme.accent)
        header.addSubview(sparkle)
        header.addSubview(titleLabel)
        header.addSubview(providerLabel)
        header.addSubview(settingsButton)
        header.addSubview(closeButton)
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        closeButton.target = self
        closeButton.action = #selector(closePanel)

        // Tabs
        tabsStack.orientation = .horizontal
        tabsStack.alignment = .centerY
        tabsStack.spacing = 2
        tabsStack.distribution = .fillEqually
        root.addSubview(tabsStack)
        for destination in AIDestination.allCases {
            let button = NSButton(title: destination.title, target: self, action: #selector(tabTapped(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(destination.rawValue)
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.font = Fonts.medium(10.5)
            button.contentTintColor = Theme.secondary
            button.setButtonType(.momentaryChange)
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            tabsStack.addArrangedSubview(button)
            tabButtons[destination] = button
        }

        // Left edge, so the panel reads as a separate surface.
        let border = FillView(fill: Theme.separator)
        border.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            border.topAnchor.constraint(equalTo: root.topAnchor),
            border.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            border.widthAnchor.constraint(equalToConstant: 1)
        ])

        // Transcript
        root.addSubview(transcriptView)

        // Composer
        root.addSubview(composer)

        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = false
        inputScroll.borderType = .noBorder
        inputView.font = Fonts.regular(12.5)
        inputView.textColor = Theme.text
        inputView.insertionPointColor = Theme.text
        inputView.drawsBackground = false
        inputView.isRichText = false
        inputView.textContainerInset = NSSize(width: 2, height: 4)
        inputView.isAutomaticQuoteSubstitutionEnabled = false
        inputView.placeholderString = ""
        inputView.delegate = self
        inputView.frame = NSRect(x: 0, y: 0, width: 320, height: 54)
        inputView.autoresizingMask = [.width]
        inputView.minSize = NSSize(width: 0, height: 54)
        inputView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        inputView.isVerticallyResizable = true
        inputView.isHorizontallyResizable = false
        inputScroll.documentView = inputView
        composer.addSubview(inputScroll)

        sendButton.title = "Send"
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .small
        sendButton.font = Fonts.medium(11)
        sendButton.contentTintColor = Theme.accent
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = .command
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        composer.addSubview(sendButton)
        composer.addSubview(hintLabel)

        // Constraints
        for subview in [header, tabsStack, transcriptView, composer,
                        sparkle, titleLabel, providerLabel, settingsButton, closeButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 54),

            sparkle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            sparkle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sparkle.widthAnchor.constraint(equalToConstant: 16),
            sparkle.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: sparkle.trailingAnchor, constant: 7),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 11),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: settingsButton.leadingAnchor, constant: -8),
            providerLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            providerLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            providerLabel.trailingAnchor.constraint(lessThanOrEqualTo: settingsButton.leadingAnchor, constant: -8),

            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
            settingsButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            settingsButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 20),
            settingsButton.heightAnchor.constraint(equalToConstant: 20),

            tabsStack.topAnchor.constraint(equalTo: header.bottomAnchor),
            tabsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            tabsStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            tabsStack.heightAnchor.constraint(equalToConstant: 32),

            transcriptView.topAnchor.constraint(equalTo: tabsStack.bottomAnchor, constant: 4),
            transcriptView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcriptView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcriptView.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),

            composer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            composer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            composer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            composer.heightAnchor.constraint(equalToConstant: 108)
        ])

        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inputScroll.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 8),
            inputScroll.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -8),
            inputScroll.topAnchor.constraint(equalTo: composer.topAnchor, constant: 8),
            inputScroll.heightAnchor.constraint(equalToConstant: 56),

            hintLabel.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 10),
            hintLabel.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -8),

            sendButton.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -6),
            sendButton.widthAnchor.constraint(equalToConstant: 58)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(enhanceNotification(_:)), name: .aiEnhanceTask, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .aiSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(demoNotification(_:)), name: .aiDemo, object: nil)

        select(destination: AppState.shared.aiDestination, clear: true)
        updateProviderLabel()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func focusComposer() {
        view.window?.makeFirstResponder(inputView)
    }

    // MARK: - Tabs

    @objc private func tabTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let destination = AIDestination(rawValue: raw) else { return }
        AppState.shared.aiDestination = destination
        select(destination: destination, clear: true)
    }

    private func select(destination: AIDestination, clear: Bool) {
        self.destination = destination
        for (candidate, button) in tabButtons {
            let selected = candidate == destination
            button.layer?.backgroundColor = selected ? Theme.accent.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
            button.layer?.cornerRadius = 5
            button.contentTintColor = selected ? Theme.accent : Theme.secondary
            button.font = selected ? Fonts.semibold(10.5) : Fonts.medium(10.5)
        }
        if clear {
            transcriptView.clear()
            chatHistory.removeAll()
            transcriptView.addAssistant(intro(for: destination))
        }
        inputView.placeholderString = placeholder(for: destination)
    }

    private func intro(for destination: AIDestination) -> String {
        switch destination {
        case .chat:
            return "Ask about “\(AIContext.selectionTitle())”, or tell me what you want to get done. I can propose to-dos, but you always press the button."
        case .capture:
            return "Describe one to-do the way you would say it. I will turn it into a title, timing, tags and a checklist."
        case .plan:
            return "Describe the outcome. I will draft a project with ordered steps. Nothing is created until you press Create."
        case .triage:
            return "I will read today's list and suggest what to keep, defer, park, or finish. Press Send to run it."
        case .search:
            return "Describe what you are looking for in plain words. I will search every open to-do by meaning."
        }
    }

    private func placeholder(for destination: AIDestination) -> String {
        switch destination {
        case .chat: return "Ask or instruct…"
        case .capture: return "e.g. call the dentist tomorrow morning"
        case .plan: return "e.g. launch the new pricing page by Friday"
        case .triage: return "Optional: add context for today"
        case .search: return "e.g. that tax document thing"
        }
    }

    private func updateProviderLabel() {
        let provider = AISettings.provider
        let model = AISettings.model(for: provider)
        providerLabel.stringValue = AISettings.hasKey(for: provider)
            ? "\(provider.title) · \(model)"
            : "\(provider.title) · no API key"
    }

    @objc private func settingsChanged() { updateProviderLabel() }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func closePanel() { onClose?() }

    // MARK: - Sending

    @objc private func sendTapped() {
        send()
    }

    private func send(overrideText: String? = nil) {
        guard !isWorking else { return }
        let text = (overrideText ?? inputView.string).trimmingCharacters(in: .whitespacesAndNewlines)
        if destination == .search && text.isEmpty { return }
        if destination != .triage && text.isEmpty { return }

        let userText = text.isEmpty ? "Triage my list." : text
        inputView.string = ""
        transcriptView.addUser(userText)
        chatHistory.append(AIMessage(role: "user", content: userText))
        if chatHistory.count > 12 { chatHistory.removeFirst(chatHistory.count - 12) }

        isWorking = true
        sendButton.isEnabled = false
        typingView = transcriptView.addTyping()

        let destination = self.destination
        let history = chatHistory
        let system: String
        switch destination {
        case .chat: system = Prompts.chatSystem()
        case .capture: system = Prompts.captureSystem()
        case .plan: system = Prompts.planSystem()
        case .triage: system = Prompts.triageSystem()
        case .search: system = Prompts.searchSystem()
        }

        Task {
            do {
                let reply = try await AIClient.complete(system: system, messages: history)
                await MainActor.run {
                    self.finish(reply: reply, destination: destination)
                }
            } catch {
                await MainActor.run {
                    self.fail(error)
                }
            }
        }
    }

    private func finish(reply: String, destination: AIDestination) {
        isWorking = false
        sendButton.isEnabled = true
        if let typingView { transcriptView.remove(typingView); self.typingView = nil }

        switch destination {
        case .chat:
            chatHistory.append(AIMessage(role: "assistant", content: reply))
            transcriptView.addAssistant(stripActionBlock(reply))
            let object = AIJSON.object(from: reply)
            let drafts = object.map { AIJSON.tasks(from: $0) } ?? []
            if !drafts.isEmpty {
                let body = drafts.map { "• " + $0.title }.joined(separator: "\n")
                let card = AICardView(title: "\(drafts.count) proposed to-do\(drafts.count == 1 ? "" : "s")",
                                      body: body,
                                      actionTitle: "Add all") {
                    for draft in drafts { _ = AIJSON.apply(draft) }
                }
                transcriptView.addCard(card)
            }

        case .capture:
            if let object = AIJSON.object(from: reply), let draft = AIJSON.taskDraft(from: object) {
                let body = summary(for: draft)
                let card = AICardView(title: draft.title, body: body, actionTitle: "Add to-do") { [weak self] in
                    _ = AIJSON.apply(draft, defaultProjectID: self?.currentProjectID())
                    self?.transcriptView.addNote("Added to your list.", color: Theme.accent)
                }
                transcriptView.addCard(card)
            } else {
                transcriptView.addNote("I could not read that as a to-do. Try one sentence with a clear action.")
                transcriptView.addAssistant(reply)
            }

        case .plan:
            if let project = AIJSON.projectDraft(from: reply) {
                let body = "\(project.tasks.count) steps\n" + project.tasks.prefix(8).map { "• " + $0.title }.joined(separator: "\n")
                let card = AICardView(title: project.title, body: body + (project.notes.isEmpty ? "" : "\n\n" + project.notes),
                                      actionTitle: "Create project") { [weak self] in
                    self?.createProject(project)
                }
                transcriptView.addCard(card)
            } else {
                transcriptView.addNote("I could not build a project from that. Try naming the outcome and a deadline.")
                transcriptView.addAssistant(reply)
            }

        case .triage:
            let suggestions = AIJSON.triage(from: reply)
            if suggestions.isEmpty {
                transcriptView.addNote("No usable ranking came back. Try once more.")
            } else {
                transcriptView.addCard(AITriageCard(suggestions: suggestions))
            }

        case .search:
            let hits = AIJSON.searchHits(from: reply)
            transcriptView.addCard(AISearchCard(hits: hits) { taskID in
                NotificationCenter.default.post(name: .openTask, object: taskID)
            })
        }
    }

    private func fail(_ error: Error) {
        isWorking = false
        sendButton.isEnabled = true
        if let typingView { transcriptView.remove(typingView); self.typingView = nil }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        transcriptView.addNote(message, color: Theme.deadline)
        if message.contains("No API key") {
            transcriptView.addNote("Open Settings (⌘,) and paste a CommandCode or OpenCode key.", color: Theme.secondary)
        }
    }

    private func summary(for draft: TaskDraft) -> String {
        var parts: [String] = []
        if !draft.notes.isEmpty { parts.append(draft.notes) }
        parts.append("When: " + draft.when)
        if let deadline = draft.deadline, !deadline.isEmpty { parts.append("Deadline: " + deadline) }
        if !draft.tags.isEmpty { parts.append("Tags: " + draft.tags.joined(separator: ", ")) }
        if !draft.checklist.isEmpty { parts.append("Checklist: " + draft.checklist.joined(separator: ", ")) }
        if let project = draft.project, !project.isEmpty { parts.append("Project: " + project) }
        return parts.joined(separator: "\n")
    }

    private func stripActionBlock(_ text: String) -> String {
        guard let range = text.range(of: "```things4-actions") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentProjectID() -> String? {
        if case .project(let id) = AppState.shared.selection { return id }
        return nil
    }

    private func createProject(_ draft: ProjectDraft) {
        var areaID: String?
        if case .area(let id) = AppState.shared.selection { areaID = id }
        let project = TaskStore.shared.createProject(title: draft.title, notes: draft.notes, areaID: areaID)
        for task in draft.tasks {
            _ = AIJSON.apply(task, defaultProjectID: project.id, defaultAreaID: areaID)
        }
        AppState.shared.selection = .project(project.id)
        transcriptView.addNote("Created “\(project.title)” with \(draft.tasks.count) to-dos.", color: Theme.accent)
    }

    // MARK: - Preview with sample data

    @objc private func demoNotification(_ notification: Notification) {
        guard let raw = notification.object as? String,
              let destination = AIDestination(rawValue: raw) else { return }
        renderDemo(destination)
    }

    /// Fills the panel with a representative conversation so the interface can
    /// be captured for the README without needing a live API key.
    func renderDemo(_ destination: AIDestination) {
        AppState.shared.aiDestination = destination
        select(destination: destination, clear: true)
        transcriptView.clear()

        let store = TaskStore.shared
        func find(_ title: String) -> TaskItem? {
            store.tasks.first { $0.title == title && !$0.isProject }
        }

        switch destination {
        case .chat:
            transcriptView.addUser("I need to get the tax papers to my accountant this week.")
            transcriptView.addAssistant("You have “Send 1099 to accountant” due in two days. Split it into two steps so the packet does not go out incomplete: gather the forms, then email them. Want me to add both?")
            let drafts = [
                TaskDraft(title: "Collect the 1099 forms", notes: "Pull the 2025 form from the bank portal.",
                          when: "today", tags: ["finance"],
                          checklist: ["Download the 1099", "Check the amount"], project: "Tax 2026"),
                TaskDraft(title: "Email the packet to the accountant", notes: "Attach the 1099 and the summary sheet.",
                          when: "tomorrow", tags: ["finance"], project: "Tax 2026")
            ]
            let card = AICardView(title: "2 proposed to-dos",
                                  body: drafts.map { "• " + $0.title }.joined(separator: "\n"),
                                  actionTitle: "Add all") {
                for draft in drafts { _ = AIJSON.apply(draft) }
            }
            transcriptView.addCard(card)

        case .capture:
            transcriptView.addUser("call the dentist tomorrow morning about the crown")
            let draft = TaskDraft(title: "Call the dentist about the crown",
                                  notes: "Ask whether the crown can be fitted before the 20th.",
                                  when: "tomorrow", tags: ["health"],
                                  checklist: ["Find the clinic number", "Ask about insurance"])
            transcriptView.addAssistant("Here is the to-do I pulled out. Check the details, then add it.")
            let card = AICardView(title: draft.title,
                                  body: "Ask whether the crown can be fitted before the 20th.\nWhen: tomorrow\nTags: health\nChecklist: Find the clinic number · Ask about insurance",
                                  actionTitle: "Add to-do") {
                _ = AIJSON.apply(draft)
            }
            transcriptView.addCard(card)

        case .plan:
            transcriptView.addUser("launch the new pricing page by Friday")
            transcriptView.addAssistant("Six steps, ordered so each one unblocks the next. Nothing is created until you press Create project.")
            let tasks = [
                TaskDraft(title: "Finalize the pricing copy", when: "today"),
                TaskDraft(title: "Build the comparison table", when: "tomorrow"),
                TaskDraft(title: "Add monthly and annual toggle", when: "tomorrow"),
                TaskDraft(title: "QA every checkout link", when: "anytime"),
                TaskDraft(title: "Update the pricing FAQ", when: "anytime"),
                TaskDraft(title: "Ship the page and announce it", when: "anytime")
            ]
            let project = ProjectDraft(title: "Launch the new pricing page",
                                       notes: "Ship by Friday. Copy, comparison table, billing toggle, QA and announcement.",
                                       tasks: tasks)
            let card = AICardView(title: project.title,
                                  body: "6 steps\n" + tasks.map { "• " + $0.title }.joined(separator: "\n"),
                                  actionTitle: "Create project") { [weak self] in
                self?.createProject(project)
            }
            transcriptView.addCard(card)

        case .triage:
            transcriptView.addUser("Triage my list for today.")
            transcriptView.addAssistant("Two things belong today. One can wait, and one is already finished.")
            let plan: [(String, String, String)] = [
                ("Send 1099 to accountant", "keep", "Due in 2 days and blocks the tax filing"),
                ("Review pricing copy", "keep", "Needed before the page ships"),
                ("Finish Q4 report", "defer", "No deadline until next week"),
                ("Send July invoice", "complete", "Already paid and overdue")
            ]
            let suggestions = plan.compactMap { title, action, reason -> TriageSuggestion? in
                guard let task = find(title) else { return nil }
                return TriageSuggestion(taskID: task.id, action: action, reason: reason)
            }
            transcriptView.addCard(AITriageCard(suggestions: suggestions))

        case .search:
            transcriptView.addUser("tax documents")
            transcriptView.addAssistant("Two to-dos match “tax documents”, even though neither one uses the exact phrase.")
            let hits = [
                ("Send 1099 to accountant", "1099 form, accountant, tax packet"),
                ("Collect 1099 forms", "Source documents for the return")
            ].compactMap { title, why -> SearchHit? in
                guard let task = find(title) else { return nil }
                return SearchHit(taskID: task.id, why: why)
            }
            transcriptView.addCard(AISearchCard(hits: hits) { taskID in
                NotificationCenter.default.post(name: .openTask, object: taskID)
            })
        }

        // Keep the preview clean: no blinking caret over the placeholder.
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(nil)
        }
    }

    // MARK: - Enhance

    @objc private func enhanceNotification(_ notification: Notification) {
        guard let id = notification.object as? String,
              let task = TaskStore.shared.task(id) else { return }
        AppState.shared.aiDestination = .chat
        select(destination: .chat, clear: true)
        let text = "Title: \(task.title)\nNotes: \(task.notes)"
        transcriptView.addUser("Improve this to-do: \(task.title)")
        isWorking = true
        sendButton.isEnabled = false
        typingView = transcriptView.addTyping()

        Task {
            do {
                let reply = try await AIClient.complete(system: Prompts.enhanceSystem(),
                                                        messages: [AIMessage(role: "user", content: text)])
                await MainActor.run {
                    self.isWorking = false
                    self.sendButton.isEnabled = true
                    if let typingView { self.transcriptView.remove(typingView); self.typingView = nil }
                    guard let polish = AIJSON.polish(from: reply) else {
                        self.transcriptView.addAssistant(reply)
                        return
                    }
                    let card = AICardView(title: "Rewrite", body: polish.title + (polish.notes.isEmpty ? "" : "\n" + polish.notes),
                                          actionTitle: "Apply") {
                        TaskStore.shared.setTitle(task.id, polish.title)
                        TaskStore.shared.setNotes(task.id, polish.notes)
                    }
                    self.transcriptView.addCard(card)
                }
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }
}
