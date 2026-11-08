import AppKit

/// Settings › API: the switch, the token, and copy-paste setups for agents (MCP),
/// the `things4` command, HTTP and the URL scheme.
final class APISettingsView: FlippedView {
    private let toggle = NSButton(checkboxWithTitle: "Let other apps and AI agents add and change to-dos", target: nil, action: nil)
    private let status = NSTextField.wrappingLabel("", font: Fonts.regular(11.5), color: Theme.secondary)
    private let tokenField = NSTextField.label("", font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: Theme.text)
    private let cliResult = NSTextField.wrappingLabel("", font: Fonts.regular(10.5), color: Theme.tertiary)

    init() {
        super.init(frame: .zero)
        build()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: APIServer.statusDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func heading(_ text: String) -> NSTextField { NSTextField.label(text, font: Fonts.medium(12), color: Theme.secondary) }
    private func hint(_ text: String) -> NSTextField { NSTextField.wrappingLabel(text, font: Fonts.regular(10.5), color: Theme.tertiary) }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Fonts.regular(11.5)
        return button
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func build() {
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.font = Fonts.regular(12.5)
        tokenField.isSelectable = true
        tokenField.lineBreakMode = .byTruncatingMiddle
        tokenField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let agents = hint("Give an agent (Claude Code, Claude Desktop, Cursor, your own harness) tools to add to-dos, projects and reminders, and to check what you finished.")
        let cli = hint("From Terminal and scripts:  things4 add \"Read chapter 3\" --when today --tags learning   ·   things4 today   ·   things4 help")
        let http = hint("JSON at http://127.0.0.1:\(APIConfig.port)/v1 (this Mac only) with  Authorization: Bearer <token>. Links like  things4:///add?title=…&when=today  work from Shortcuts, Raycast and web pages, with Things 3's commands.")
        cliResult.isHidden = true

        let stack = NSStackView(views: [
            toggle, status,
            heading("Token"), row([tokenField, button("Copy", #selector(copyToken)), button("New Token", #selector(newToken))]),
            heading("AI agents (MCP)"), agents, row([button("Copy Claude Code Command", #selector(copyClaudeCommand)), button("Copy MCP Config", #selector(copyMCP))]),
            heading("Command line"), cli, row([button("Install “things4” Command", #selector(installCLI))]), cliResult,
            heading("HTTP API and links"), http, row([button("Copy curl Example", #selector(copyCurl)), button("Copy Example Link", #selector(copyLink))])
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for view in [agents, cli, http] { stack.setCustomSpacing(8, after: view) }
        stack.setCustomSpacing(14, after: status)
        for view in stack.arrangedSubviews where view is NSStackView { stack.setCustomSpacing(14, after: view) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16)
        ])
        for view in [agents, cli, http, status, cliResult] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc private func reload() {
        toggle.state = Preferences.apiEnabled ? .on : .off
        tokenField.stringValue = APIConfig.token
        let server = APIServer.shared
        if !Preferences.apiEnabled {
            status.stringValue = "Off. Links, the API and agents can't reach your to-dos."
            status.textColor = Theme.secondary
        } else if let port = server.listeningPort {
            status.stringValue = "● On: listening at http://127.0.0.1:\(port)/v1"
            status.textColor = NSColor.systemGreen
        } else if let error = server.lastError {
            status.stringValue = error
            status.textColor = NSColor.systemRed
        } else {
            status.stringValue = "Starting…"
            status.textColor = Theme.secondary
        }
    }

    private func copy(_ text: String, _ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let button = sender as? NSButton {
            let title = button.title
            button.title = "Copied"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { button.title = title }
        }
    }

    @objc private func toggled() {
        Preferences.apiEnabled = toggle.state == .on
        reload()
    }

    @objc private func copyToken(_ sender: NSButton) { copy(APIConfig.token, sender) }

    @objc private func newToken(_ sender: NSButton) {
        guard SettingsAlert.confirm(title: "Make a New Token?", message: "Agents, scripts and links using the old token stop working until you give them the new one. The things4 command and MCP server pick it up automatically.", button: "New Token") else { return }
        APIConfig.regenerateToken()
        reload()
    }

    @objc private func copyMCP(_ sender: NSButton) { copy(AgentBridge.mcpConfig, sender) }

    @objc private func copyClaudeCommand(_ sender: NSButton) {
        copy("claude mcp add --scope user things4 -- \"\(Bundle.main.executablePath ?? "/Applications/Things 4.app/Contents/MacOS/Things4")\" --mcp", sender)
    }

    @objc private func copyCurl(_ sender: NSButton) {
        copy("""
        curl -s http://127.0.0.1:\(APIConfig.port)/v1/tasks \\
          -H "Authorization: Bearer \(APIConfig.token)" \\
          -d '{"title": "Read chapter 3", "when": "today", "tags": ["learning"], "reminder": "tomorrow 9am"}'
        """, sender)
    }

    @objc private func copyLink(_ sender: NSButton) {
        copy("things4:///add?title=Read%20chapter%203&when=today&tags=learning", sender)
    }

    @objc private func installCLI() {
        do {
            let url = try AgentBridge.installCLI()
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            let onPath = path.split(separator: ":").contains { $0 == url.deletingLastPathComponent().path }
            cliResult.isHidden = false
            cliResult.stringValue = "Installed at \(url.path)." + (onPath ? "" : "  If your shell can't find it, add  export PATH=\"$HOME/.local/bin:$PATH\"  to ~/.zshrc.")
        } catch {
            cliResult.isHidden = false
            cliResult.stringValue = "Couldn't install: \(error.localizedDescription)"
        }
    }
}

private enum SettingsAlert {
    static func confirm(title: String, message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
