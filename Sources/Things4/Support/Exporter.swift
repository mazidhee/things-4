import AppKit
import UniformTypeIdentifiers

/// Export a list or project as Markdown, PDF, or print it.
enum Exporter {
    // MARK: Markdown

    static func markdown(for selection: Selection) -> (title: String, text: String) {
        let store = TaskStore.shared
        var lines: [String] = []
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"

        func line(for task: TaskItem, indent: String = "") -> [String] {
            var meta: [String] = []
            if task.isEvening { meta.append("this evening") }
            else if let start = task.startDate, start >= Date().startOfDay.addingDays(1) { meta.append("starts " + f.string(from: start)) }
            if let deadline = task.deadline { meta.append("due " + f.string(from: deadline)) }
            if let reminder = task.reminder {
                let t = DateFormatter(); t.timeStyle = .short
                meta.append("⏰ " + t.string(from: reminder))
            }
            meta.append(contentsOf: task.tags.map { "#" + $0.replacingOccurrences(of: " ", with: "-") })
            var out = [indent + (task.isCompleted ? "- [x] " : "- [ ] ") + task.title + (meta.isEmpty ? "" : "  _(" + meta.joined(separator: " · ") + ")_")]
            for item in task.checklist { out.append(indent + "    " + (item.done ? "- [x] " : "- [ ] ") + item.title) }
            if !task.notes.isEmpty {
                for noteLine in task.notes.split(separator: "\n", omittingEmptySubsequences: false) {
                    out.append(noteLine.isEmpty ? "" : indent + "    " + noteLine)
                }
            }
            return out
        }

        let title: String
        switch selection {
        case .project(let id):
            let project = store.task(id)
            title = project?.title ?? "Project"
            lines.append("# " + title)
            if let notes = project?.notes, !notes.isEmpty { lines.append(""); lines.append(notes) }
            let children = store.children(of: id)
            let headings = children.filter { $0.isHeading && $0.isOpen }
            let headingIDs = Set(headings.map(\.id))
            let loose = children.filter { $0.isTodo && $0.isOpen && ($0.headingID == nil || !headingIDs.contains($0.headingID!)) }
            if !loose.isEmpty { lines.append("") }
            loose.forEach { lines.append(contentsOf: line(for: $0)) }
            for heading in headings {
                lines.append(""); lines.append("## " + heading.title); lines.append("")
                children.filter { $0.isTodo && $0.isOpen && $0.headingID == heading.id }.forEach { lines.append(contentsOf: line(for: $0)) }
            }
            let done = children.filter { $0.isTodo && $0.isCompleted }
            if !done.isEmpty {
                lines.append(""); lines.append("## Completed"); lines.append("")
                done.forEach { lines.append(contentsOf: line(for: $0)) }
            }
        case .area(let id):
            title = store.area(id)?.title ?? "Area"
            lines.append("# " + title)
            for project in store.projects(inArea: id) where project.isOpen {
                lines.append(""); lines.append("## " + project.title); lines.append("")
                store.children(of: project.id).filter { $0.isTodo && $0.isOpen }.forEach { lines.append(contentsOf: line(for: $0)) }
            }
            let tasks = store.tasks(in: selection)
            if !tasks.isEmpty { lines.append(""); lines.append("## To-Dos"); lines.append("") }
            tasks.forEach { lines.append(contentsOf: line(for: $0)) }
        case .builtin(let list):
            title = list.title
            lines.append("# " + title)
            lines.append("")
            let tasks = store.tasks(in: selection)
            if list == .upcoming {
                let grouped = Dictionary(grouping: tasks) { ($0.startDate ?? $0.deadline ?? Date()).startOfDay }
                for day in grouped.keys.sorted() {
                    lines.append("## " + f.string(from: day)); lines.append("")
                    grouped[day]!.forEach { lines.append(contentsOf: line(for: $0)) }
                    lines.append("")
                }
            } else {
                tasks.forEach { lines.append(contentsOf: line(for: $0)) }
            }
        case .tag(let tag):
            title = "#" + tag
            lines.append("# " + title); lines.append("")
            store.tasks(in: selection).forEach { lines.append(contentsOf: line(for: $0)) }
        }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        lines.append(""); lines.append("---"); lines.append("_Exported from Things 4 on \(stamp)_")
        return (title, lines.joined(separator: "\n") + "\n")
    }

    // MARK: Actions

    static func exportMarkdown(_ selection: Selection) {
        let (title, text) = markdown(for: selection)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safe(title) + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func exportPDF(_ selection: Selection) {
        let (title, text) = markdown(for: selection)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safe(title) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writePDF(selection, to: url)
    }

    static func writePDF(_ selection: Selection, to url: URL) {
        let (_, text) = markdown(for: selection)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        run(printView(for: text, info: info), info: info, showPanels: false)
    }

    static func print(_ selection: Selection) {
        let (_, text) = markdown(for: selection)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        run(printView(for: text, info: info), info: info, showPanels: true)
    }

    private static func run(_ view: NSView, info: NSPrintInfo, showPanels: Bool) {
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = showPanels
        op.showsProgressPanel = showPanels
        op.run()
    }

    /// A light-appearance text view laid out for paper, rendered from the Markdown.
    private static func printView(for markdown: String, info: NSPrintInfo) -> NSView {
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 60; info.rightMargin = 60
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let rendered = document(from: markdown)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(rendered)
        view.isVerticallyResizable = true
        view.sizeToFit()
        return view
    }

    /// Paper layout built from the exported Markdown: title, headings, checkbox rows
    /// with grey details, indented checklists and quiet grey notes.
    private static func document(from markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ink = NSColor.black, grey = NSColor(white: 0.45, alpha: 1), light = NSColor(white: 0.6, alpha: 1)
        func para(before: CGFloat = 0, after: CGFloat = 2, indent: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = before; p.paragraphSpacing = after
            p.firstLineHeadIndent = indent; p.headIndent = indent + 16; p.lineSpacing = 1.5
            return p
        }
        func add(_ text: String, _ font: NSFont, _ color: NSColor, _ style: NSParagraphStyle) {
            out.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        func row(_ body: String, indent: CGFloat, size: CGFloat) {
            let done = body.hasPrefix("- [x] ")
            var text = String(body.dropFirst(6))
            var meta = ""
            if let range = text.range(of: "  _(") { meta = String(text[range.upperBound...]).replacingOccurrences(of: ")_", with: ""); text = String(text[..<range.lowerBound]) }
            let line = NSMutableAttributedString(string: (done ? "☑︎  " : "☐  "), attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: done ? light : grey])
            line.append(NSAttributedString(string: text.isEmpty ? "Untitled" : text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: done ? light : ink,
                                                                                                    .strikethroughStyle: done ? NSUnderlineStyle.single.rawValue : 0]))
            if !meta.isEmpty { line.append(NSAttributedString(string: "   " + meta, attributes: [.font: NSFont.systemFont(ofSize: size - 2), .foregroundColor: grey])) }
            line.append(NSAttributedString(string: "\n"))
            line.addAttribute(.paragraphStyle, value: para(before: indent == 0 ? 6 : 1, after: 1, indent: indent), range: NSRange(location: 0, length: line.length))
            out.append(line)
        }
        for raw in markdown.components(separatedBy: "\n") {
            if raw.hasPrefix("# ") { add(String(raw.dropFirst(2)), .systemFont(ofSize: 22, weight: .bold), ink, para(after: 10)) }
            else if raw.hasPrefix("## ") { add(String(raw.dropFirst(3)), .systemFont(ofSize: 14, weight: .semibold), NSColor(srgbRed: 0.2, green: 0.45, blue: 0.85, alpha: 1), para(before: 16, after: 4)) }
            else if raw.hasPrefix("- [") { row(raw, indent: 0, size: 12) }
            else if raw.hasPrefix("    - [") { row(String(raw.dropFirst(4)), indent: 20, size: 10.5) }
            else if raw.hasPrefix("    ") { add(String(raw.dropFirst(4)), .systemFont(ofSize: 10), grey, para(after: 1, indent: 20)) }
            else if raw == "---" { add("", .systemFont(ofSize: 6), ink, para(before: 12)) }
            else if raw.hasPrefix("_Exported") { add(raw.trimmingCharacters(in: CharacterSet(charactersIn: "_")), .systemFont(ofSize: 9), light, para()) }
            else if raw.isEmpty { continue }
            else { add(raw, .systemFont(ofSize: 11.5), ink, para(after: 6)) }
        }
        return out
    }

    private static func safe(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
