import AppKit

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    // General
    private let appearancePopup = NSPopUpButton()
    private let aiToggle = NSButton(checkboxWithTitle: "Enable AI features", target: nil, action: nil)
    private let badgeToggle = NSButton(checkboxWithTitle: "Show the Today count on the Dock icon", target: nil, action: nil)
    private let menuBarToggle = NSButton(checkboxWithTitle: "Show Today and the focus timer in the menu bar", target: nil, action: nil)
    private let phoneToggle = NSButton(checkboxWithTitle: "Also remind me on iPhone and Apple Watch", target: nil, action: nil)
    private let logPopup = NSPopUpButton()
    private let textSizeSlider = NSSlider(value: 1, minValue: 0.85, maxValue: 1.3, target: nil, action: nil)
    private let groupTodayToggle = NSButton(checkboxWithTitle: "Group to-dos in the Today list by project or area", target: nil, action: nil)
    private let quickEntryToggle = NSButton(checkboxWithTitle: "Quick Entry shortcut  ⌃Space", target: nil, action: nil)

    // AI
    private let providerPopup = NSPopUpButton()
    private let keyField = NSSecureTextField()
    private let baseField = NSTextField()
    private let modelCombo = NSComboBox()
    private let fetchButton = NSButton(title: "Fetch", target: nil, action: nil)
    private let testButton = NSButton(title: "Test connection", target: nil, action: nil)
    private let statusLabel = NSTextField.wrappingLabel("", font: Fonts.regular(11.5), color: Theme.secondary)
    private let hintLabel = NSTextField.wrappingLabel("", font: Fonts.regular(10.5), color: Theme.tertiary)
    private let aiDisabledLabel = NSTextField.wrappingLabel("AI features are turned off. Enable them in General to configure a provider.",
                                                            font: Fonts.regular(11.5), color: Theme.secondary)
    private var aiControls: [NSControl] = []

    private var editingProvider: AIProvider = .commandCode
    private var availableModels: [AIModel] = []

    private convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.backgroundColor = Theme.window
        self.init(window: window)
        buildUI()
        loadGeneral()
        loadProvider(AISettings.provider)
        window.delegate = self
    }

    private func buildUI() {
        guard let window else { return }
        let root = FillView(fill: Theme.window)
        window.contentView = root

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)

        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        general.view = buildGeneral()
        tabs.addTabViewItem(general)

        let calendar = NSTabViewItem(identifier: "calendar")
        calendar.label = "Calendar"
        calendar.view = buildCalendar()
        tabs.addTabViewItem(calendar)

        let api = NSTabViewItem(identifier: "api")
        api.label = "API"
        api.view = APISettingsView()
        tabs.addTabViewItem(api)

        let ai = NSTabViewItem(identifier: "ai")
        ai.label = "AI"
        ai.view = buildAI()
        tabs.addTabViewItem(ai)
        if let tab = ProcessInfo.processInfo.environment["THINGS4_SETTINGS_TAB"] { tabs.selectTabViewItem(withIdentifier: tab) }

        let closeButton = NSButton(title: "Done", target: self, action: #selector(done))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(closeButton)

        let revealButton = NSButton(title: "Reveal database", target: self, action: #selector(revealDatabase))
        revealButton.bezelStyle = .inline
        revealButton.isBordered = false
        revealButton.controlSize = .small
        revealButton.font = Fonts.regular(10.5)
        revealButton.contentTintColor = Theme.accent
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(revealButton)

        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            tabs.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -14),
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            closeButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            revealButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            revealButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor)
        ])
    }

    private func buildGeneral() -> NSView {
        let root = FlippedView()

        for mode in AppearanceMode.allCases { appearancePopup.addItem(withTitle: mode.title) }
        appearancePopup.target = self
        appearancePopup.action = #selector(appearanceChanged)
        appearancePopup.font = Fonts.regular(12)

        aiToggle.target = self
        aiToggle.action = #selector(generalChanged)
        aiToggle.font = Fonts.regular(12.5)
        badgeToggle.target = self
        badgeToggle.action = #selector(generalChanged)
        menuBarToggle.target = self
        menuBarToggle.action = #selector(generalChanged)
        menuBarToggle.font = Fonts.regular(12.5)
        phoneToggle.target = self
        phoneToggle.action = #selector(generalChanged)
        phoneToggle.font = Fonts.regular(12.5)
        badgeToggle.font = Fonts.regular(12.5)
        quickEntryToggle.target = self
        quickEntryToggle.action = #selector(generalChanged)
        quickEntryToggle.font = Fonts.regular(12.5)

        let aiHint = NSTextField.wrappingLabel("When off, the AI sidebar, the sparkles buttons and “Enhance with AI” disappear. Nothing is ever sent to a provider.",
                                              font: Fonts.regular(10.5), color: Theme.tertiary)
        let quickHint = NSTextField.wrappingLabel("Press ⌃Space in any app to capture a to-do into your Inbox. ⌃⌥Space also links the web page, Mail message or file in front.",
                                                 font: Fonts.regular(10.5), color: Theme.tertiary)
        let phoneHint = NSTextField.wrappingLabel("Reminders are copied to a “Things 4” list in Apple Reminders, which iCloud syncs to your iPhone and Watch. Ticking one off there completes the to-do here.",
                                                 font: Fonts.regular(10.5), color: Theme.tertiary)
        let dataHint = NSTextField.wrappingLabel("All tasks live in a local SQLite database. No account, no sync, no telemetry.",
                                                font: Fonts.regular(10.5), color: Theme.tertiary)

        logPopup.addItems(withTitles: ["Immediately", "Daily"])
        logPopup.target = self
        logPopup.action = #selector(logChanged)
        logPopup.font = Fonts.regular(12)
        let logRow = NSStackView(views: [NSTextField.label("Move completed items to Logbook", font: Fonts.medium(12), color: Theme.secondary), logPopup])
        logRow.orientation = .horizontal
        logRow.spacing = 12
        textSizeSlider.numberOfTickMarks = 10
        textSizeSlider.allowsTickMarkValuesOnly = true
        textSizeSlider.target = self
        textSizeSlider.action = #selector(textSizeChanged)
        textSizeSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let small = NSTextField.label("A", font: .systemFont(ofSize: 11), color: Theme.secondary)
        let large = NSTextField.label("A", font: .systemFont(ofSize: 17), color: Theme.secondary)
        let textRow = NSStackView(views: [NSTextField.label("Text Size", font: Fonts.medium(12), color: Theme.secondary), small, textSizeSlider, large])
        textRow.orientation = .horizontal
        textRow.spacing = 8
        groupTodayToggle.target = self
        groupTodayToggle.action = #selector(generalChanged)
        groupTodayToggle.font = Fonts.regular(12.5)
        let appearanceRow = NSStackView(views: [NSTextField.label("Appearance", font: Fonts.medium(12), color: Theme.secondary), appearancePopup])
        appearanceRow.orientation = .horizontal
        appearanceRow.spacing = 12

        let stack = NSStackView(views: [logRow, appearanceRow, textRow, groupTodayToggle, aiToggle, aiHint, badgeToggle, menuBarToggle, phoneToggle, phoneHint, quickEntryToggle, quickHint, dataHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: appearanceRow)
        stack.setCustomSpacing(4, after: aiToggle)
        stack.setCustomSpacing(16, after: aiHint)
        stack.setCustomSpacing(4, after: phoneToggle)
        stack.setCustomSpacing(16, after: phoneHint)
        stack.setCustomSpacing(4, after: quickEntryToggle)
        stack.setCustomSpacing(24, after: quickHint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            appearancePopup.widthAnchor.constraint(equalToConstant: 140)
        ])
        return root
    }

    private func buildAI() -> NSView {
        let root = FlippedView()

        let subheading = NSTextField.wrappingLabel("Keys stay in your macOS keychain. Tasks are sent only when you press Send in the AI sidebar.",
                                                  font: Fonts.regular(11.5), color: Theme.secondary)

        for provider in AIProvider.allCases {
            providerPopup.addItem(withTitle: provider.title)
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.font = Fonts.regular(12)

        keyField.font = Fonts.regular(12)
        keyField.placeholderString = "Paste the key"
        baseField.font = Fonts.regular(12)
        baseField.placeholderString = "https://…/v1"

        modelCombo.font = Fonts.regular(12)
        modelCombo.isEditable = true
        modelCombo.completes = false
        modelCombo.numberOfVisibleItems = 12

        fetchButton.bezelStyle = .rounded
        fetchButton.controlSize = .small
        fetchButton.font = Fonts.regular(11)
        fetchButton.target = self
        fetchButton.action = #selector(fetchModels)

        testButton.bezelStyle = .rounded
        testButton.controlSize = .regular
        testButton.font = Fonts.medium(12)
        testButton.target = self
        testButton.action = #selector(testConnection)

        let modelRow = NSStackView(views: [modelCombo, fetchButton])
        modelRow.orientation = .horizontal
        modelRow.spacing = 6
        modelRow.alignment = .centerY

        let grid = NSGridView(views: [
            [NSTextField.label("Provider", font: Fonts.medium(12), color: Theme.secondary), providerPopup],
            [NSTextField.label("API key", font: Fonts.medium(12), color: Theme.secondary), keyField],
            [NSTextField.label("Base URL", font: Fonts.medium(12), color: Theme.secondary), baseField],
            [NSTextField.label("Model", font: Fonts.medium(12), color: Theme.secondary), modelRow]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        hintLabel.stringValue = "Defaults: CommandCode uses https://api.commandcode.ai/provider/v1 and OpenCode uses https://opencode.ai/inference/openai/v1. Override the base URL only if your account uses a different gateway."
        statusLabel.stringValue = ""
        aiControls = [providerPopup, keyField, baseField, modelCombo, fetchButton, testButton]

        for view in [subheading, aiDisabledLabel, grid, testButton, statusLabel, hintLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            subheading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            subheading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            subheading.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),

            aiDisabledLabel.leadingAnchor.constraint(equalTo: subheading.leadingAnchor),
            aiDisabledLabel.trailingAnchor.constraint(equalTo: subheading.trailingAnchor),
            aiDisabledLabel.topAnchor.constraint(equalTo: subheading.bottomAnchor, constant: 8),

            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: aiDisabledLabel.bottomAnchor, constant: 14),
            modelCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),

            testButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            testButton.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: testButton.bottomAnchor, constant: 10),

            hintLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            hintLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12)
        ])
        return root
    }

    // MARK: - Calendar

    private let calendarToggle = NSButton(checkboxWithTitle: "Show calendar events in Today and Upcoming", target: nil, action: nil)
    private let calendarStatus = NSTextField.wrappingLabel("", font: Fonts.regular(11.5), color: Theme.secondary)
    private let calendarList = NSStackView()
    private let grantButton = NSButton(title: "Allow Calendar Access…", target: nil, action: nil)

    private func buildCalendar() -> NSView {
        let root = FlippedView()
        calendarToggle.target = self
        calendarToggle.action = #selector(calendarToggled)
        calendarToggle.font = Fonts.regular(12.5)
        grantButton.bezelStyle = .rounded
        grantButton.target = self
        grantButton.action = #selector(grantCalendar)
        let accountsButton = NSButton(title: "Add Outlook or Google Account…", target: self, action: #selector(openInternetAccounts))
        accountsButton.bezelStyle = .rounded
        let hint = NSTextField.wrappingLabel("Things 4 reads every calendar your Mac knows about. Add your work Outlook (Microsoft Exchange) and personal Gmail (Google) accounts in System Settings › Internet Accounts with Calendars switched on, then tick the calendars to show here.",
                                            font: Fonts.regular(10.5), color: Theme.tertiary)
        calendarList.orientation = .vertical
        calendarList.alignment = .leading
        calendarList.spacing = 4
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let doc = FlippedView()
        doc.addSubview(calendarList)
        calendarList.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [grantButton, accountsButton])
        buttons.spacing = 8
        for view in [calendarToggle, calendarStatus, buttons, hint, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            calendarToggle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            calendarToggle.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            calendarStatus.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            calendarStatus.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            calendarStatus.topAnchor.constraint(equalTo: calendarToggle.bottomAnchor, constant: 6),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttons.topAnchor.constraint(equalTo: calendarStatus.bottomAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            hint.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            calendarList.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            calendarList.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            calendarList.topAnchor.constraint(equalTo: doc.topAnchor),
            calendarList.bottomAnchor.constraint(equalTo: doc.bottomAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reloadCalendars), name: .calendarDidChange, object: nil)
        reloadCalendars()
        return root
    }

    @objc private func reloadCalendars() {
        let service = CalendarService.shared
        calendarToggle.state = Preferences.calendarsEnabled ? .on : .off
        switch service.status {
        case .denied, .restricted:
            calendarStatus.stringValue = "Calendar access is off for Things 4. Turn it on in System Settings › Privacy & Security › Calendars."
            grantButton.title = "Open Privacy Settings…"
            grantButton.isHidden = false
        default:
            if service.hasAccess {
                let count = service.calendarsBySource().reduce(0) { $0 + $1.calendars.count }
                calendarStatus.stringValue = "Access granted. \(count) calendar\(count == 1 ? "" : "s") found."
                grantButton.isHidden = true
            } else {
                calendarStatus.stringValue = "Things 4 needs permission to read your calendars."
                grantButton.title = "Allow Calendar Access…"
                grantButton.isHidden = false
            }
        }
        calendarList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hidden = Preferences.hiddenCalendarIDs
        for (source, calendars) in service.calendarsBySource() {
            calendarList.addArrangedSubview(NSTextField.label(source.uppercased(), font: Fonts.semibold(10.5), color: Theme.tertiary))
            for calendar in calendars {
                let box = NSButton(checkboxWithTitle: calendar.title, target: self, action: #selector(calendarChecked(_:)))
                box.identifier = NSUserInterfaceItemIdentifier(calendar.calendarIdentifier)
                box.state = hidden.contains(calendar.calendarIdentifier) ? .off : .on
                box.contentTintColor = NSColor(cgColor: calendar.cgColor)
                box.font = Fonts.regular(12.5)
                calendarList.addArrangedSubview(box)
            }
        }
    }

    @objc private func calendarToggled() {
        let on = calendarToggle.state == .on
        if on && !CalendarService.shared.hasAccess {
            CalendarService.shared.requestAccess { granted in
                Preferences.calendarsEnabled = granted
                self.reloadCalendars()
            }
        } else {
            Preferences.calendarsEnabled = on
        }
    }

    @objc private func grantCalendar() {
        if CalendarService.shared.status == .denied || CalendarService.shared.status == .restricted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            return
        }
        CalendarService.shared.requestAccess { granted in
            if granted { Preferences.calendarsEnabled = true }
            self.reloadCalendars()
        }
    }

    @objc private func openInternetAccounts() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    @objc private func calendarChecked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var hidden = Preferences.hiddenCalendarIDs
        if sender.state == .on { hidden.remove(id) } else { hidden.insert(id) }
        Preferences.hiddenCalendarIDs = hidden
    }

    // MARK: - General

    private func loadGeneral() {
        appearancePopup.selectItem(withTitle: Preferences.appearance.title)
        logPopup.selectItem(at: Preferences.logImmediately ? 0 : 1)
        textSizeSlider.doubleValue = Double(Preferences.textScale)
        groupTodayToggle.state = Preferences.groupToday ? .on : .off
        aiToggle.state = Preferences.aiEnabled ? .on : .off
        badgeToggle.state = Preferences.showDockBadge ? .on : .off
        menuBarToggle.state = Preferences.menuBarEnabled ? .on : .off
        phoneToggle.state = Preferences.phoneReminders && PhoneReminders.shared.status != .denied ? .on : .off
        quickEntryToggle.state = Preferences.quickEntryEnabled ? .on : .off
        updateAIAvailability()
    }

    private func updateAIAvailability() {
        let enabled = Preferences.aiEnabled
        aiDisabledLabel.isHidden = enabled
        for control in aiControls { control.isEnabled = enabled }
    }

    @objc private func textSizeChanged() {
        Preferences.textScale = CGFloat(textSizeSlider.doubleValue)
        NotificationCenter.default.post(name: .storeDidChange, object: nil)
    }

    @objc private func logChanged() {
        Preferences.logImmediately = logPopup.indexOfSelectedItem == 0
    }

    @objc private func appearanceChanged() {
        let index = max(0, appearancePopup.indexOfSelectedItem)
        Preferences.appearance = AppearanceMode.allCases[min(index, AppearanceMode.allCases.count - 1)]
    }

    @objc private func generalChanged() {
        if Preferences.groupToday != (groupTodayToggle.state == .on) { Preferences.groupToday = groupTodayToggle.state == .on }
        if Preferences.aiEnabled != (aiToggle.state == .on) { Preferences.aiEnabled = aiToggle.state == .on }
        if Preferences.menuBarEnabled != (menuBarToggle.state == .on) { Preferences.menuBarEnabled = menuBarToggle.state == .on }
        if phoneToggle.state == .on, !PhoneReminders.shared.hasAccess {
            PhoneReminders.shared.requestAccess { [weak self] granted in
                Preferences.phoneReminders = granted
                self?.phoneToggle.state = granted ? .on : .off
                if !granted {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                }
            }
        } else if Preferences.phoneReminders != (phoneToggle.state == .on) {
            Preferences.phoneReminders = phoneToggle.state == .on
            if phoneToggle.state == .on { PhoneReminders.shared.sync() } else { PhoneReminders.shared.disable() }
        }
        if Preferences.showDockBadge != (badgeToggle.state == .on) { Preferences.showDockBadge = badgeToggle.state == .on }
        if Preferences.quickEntryEnabled != (quickEntryToggle.state == .on) { Preferences.quickEntryEnabled = quickEntryToggle.state == .on }
        updateAIAvailability()
    }

    // MARK: - AI

    private func loadProvider(_ provider: AIProvider) {
        editingProvider = provider
        providerPopup.selectItem(withTitle: provider.title)
        keyField.stringValue = AISettings.key(for: provider)
        keyField.placeholderString = provider.keyHint
        baseField.stringValue = AISettings.baseURL(for: provider)
        modelCombo.removeAllItems()
        let model = AISettings.model(for: provider)
        modelCombo.stringValue = model
        modelCombo.addItem(withObjectValue: model)
        availableModels = []
        statusLabel.stringValue = ""
        statusLabel.textColor = Theme.secondary
    }

    private func saveCurrent() {
        AISettings.setKey(keyField.stringValue, for: editingProvider)
        AISettings.setBaseURL(baseField.stringValue, for: editingProvider)
        let model = modelCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            AISettings.setModel(model, for: editingProvider)
            if let match = availableModels.first(where: { $0.id == model }) {
                AISettings.setFormat(match.format, for: editingProvider)
            } else if model.lowercased().contains("claude") {
                AISettings.setFormat(.anthropic, for: editingProvider)
            } else {
                AISettings.setFormat(.openAI, for: editingProvider)
            }
        }
        AISettings.provider = editingProvider
        NotificationCenter.default.post(name: .aiSettingsChanged, object: nil)
    }

    @objc private func providerChanged() {
        saveCurrent()
        let index = max(0, providerPopup.indexOfSelectedItem)
        let provider = AIProvider.allCases[min(index, AIProvider.allCases.count - 1)]
        loadProvider(provider)
    }

    @objc private func fetchModels() {
        saveCurrent()
        statusLabel.stringValue = "Fetching models…"
        statusLabel.textColor = Theme.secondary
        fetchButton.isEnabled = false
        let provider = editingProvider
        let key = keyField.stringValue
        Task {
            do {
                let models = try await AIClient.models(provider: provider, key: key)
                await MainActor.run {
                    self.fetchButton.isEnabled = true
                    self.availableModels = models
                    self.modelCombo.removeAllItems()
                    for model in models { self.modelCombo.addItem(withObjectValue: model.id) }
                    if models.isEmpty {
                        self.statusLabel.stringValue = "The provider returned no models. Type a model name by hand."
                        self.statusLabel.textColor = Theme.secondary
                    } else {
                        let current = AISettings.model(for: provider)
                        if models.contains(where: { $0.id == current }) {
                            self.modelCombo.stringValue = current
                        } else if let first = models.first {
                            self.modelCombo.stringValue = first.id
                        }
                        self.statusLabel.stringValue = "\(models.count) models loaded."
                        self.statusLabel.textColor = Theme.accent
                    }
                }
            } catch {
                await MainActor.run {
                    self.fetchButton.isEnabled = true
                    self.statusLabel.stringValue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.statusLabel.textColor = Theme.deadline
                }
            }
        }
    }

    @objc private func testConnection() {
        saveCurrent()
        statusLabel.stringValue = "Testing…"
        statusLabel.textColor = Theme.secondary
        testButton.isEnabled = false
        Task {
            do {
                let reply = try await AIClient.testConnection()
                await MainActor.run {
                    self.testButton.isEnabled = true
                    self.statusLabel.stringValue = "Connected. The model said: \(reply.prefix(80))"
                    self.statusLabel.textColor = Theme.success
                }
            } catch {
                await MainActor.run {
                    self.testButton.isEnabled = true
                    self.statusLabel.stringValue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.statusLabel.textColor = Theme.deadline
                }
            }
        }
    }

    @objc private func revealDatabase() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: TaskStore.shared.databasePath)])
    }

    @objc private func done() {
        saveCurrent()
        window?.close()
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        saveCurrent()
    }
}
