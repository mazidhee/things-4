import AppKit

/// Links to emails, files and web pages, as Things does them: drop one on a list
/// to make a to-do, drop one into notes to insert a link, or press ⌃⌥Space to
/// capture what is open in the frontmost app (Autofill Quick Entry).
enum Links {
    struct Item {
        let title: String
        let url: URL
        var markdown: String { "[\(title.replacingOccurrences(of: "]", with: ")"))](\(url.absoluteString))" }
    }

    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, NSPasteboard.PasteboardType("public.url"), .string]

    /// Files, web links and Mail messages on a drag pasteboard.
    static func items(from pasteboard: NSPasteboard) -> [Item] {
        var items: [Item] = []
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let names = pasteboard.pasteboardItems?.compactMap { $0.string(forType: NSPasteboard.PasteboardType("public.url-name")) } ?? []
        for (index, url) in urls.enumerated() {
            items.append(Item(title: title(for: url, suggested: index < names.count ? names[index] : nil), url: url))
        }
        if items.isEmpty, let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: text), url.scheme != nil, !text.contains(" ") {
            items.append(Item(title: title(for: url, suggested: nil), url: url))
        }
        return items
    }

    static func title(for url: URL, suggested: String?) -> String {
        if let suggested, !suggested.isEmpty { return suggested }
        if url.isFileURL { return FileManager.default.displayName(atPath: url.path) }
        if url.scheme == "message" { return "Mail message" }
        let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        let path = url.path.split(separator: "/").last.map { " › " + $0 } ?? ""
        return host + path
    }

    // MARK: Autofill

    /// What the frontmost app is showing: a browser tab, the selected Mail
    /// message or the selected Finder item. Uses Apple Events, so macOS asks once per app.
    static func captureFrontmost(_ app: NSRunningApplication?) -> Item? {
        guard let bundleID = app?.bundleIdentifier else { return nil }
        let chromium = ["com.google.Chrome": "Google Chrome", "com.brave.Browser": "Brave Browser",
                        "com.microsoft.edgemac": "Microsoft Edge", "company.thebrowser.Browser": "Arc",
                        "com.vivaldi.Vivaldi": "Vivaldi"]
        let script: String
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            script = """
            tell application id "\(bundleID)" to return {name of current tab of front window, URL of current tab of front window}
            """
        case _ where chromium[bundleID] != nil:
            script = """
            tell application id "\(bundleID)" to return {title of active tab of front window, URL of active tab of front window}
            """
        case "com.apple.mail":
            script = """
            tell application "Mail"
                set picked to selection
                if picked is {} then return {}
                set m to item 1 of picked
                return {subject of m, "message://%3c" & (message id of m) & "%3e"}
            end tell
            """
        case "com.apple.finder":
            script = """
            tell application "Finder"
                set picked to selection
                if picked is {} then return {}
                set f to item 1 of picked as alias
                return {name of (info for f), "file://" & POSIX path of f}
            end tell
            """
        default:
            return nil
        }
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error), result.numberOfItems == 2,
              let title = result.atIndex(1)?.stringValue, var link = result.atIndex(2)?.stringValue else { return nil }
        if link.hasPrefix("file://") {
            link = URL(fileURLWithPath: String(link.dropFirst(7))).absoluteString
        } else if link.hasPrefix("message://") {
            link = "message://" + (String(link.dropFirst(10)).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")
                .replacingOccurrences(of: "%253c", with: "%3c").replacingOccurrences(of: "%253e", with: "%3e")
        }
        guard let url = URL(string: link) else { return nil }
        return Item(title: title.isEmpty ? Links.title(for: url, suggested: nil) : title, url: url)
    }
}
