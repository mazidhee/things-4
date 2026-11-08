import AppKit

/// Window › Tags… (⌃⌘T): every tag with its colour, rename and delete.
final class TagManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let shared = TagManagerWindowController()

    private let table = NSTableView()
    private var tags: [String] = []

    private convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Tags"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 300)
        window.center()
        self.init(window: window)
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .storeDidChange, object: nil)
        reload()
    }

    private func buildUI() {
        guard let window else { return }
        let root = FillView(fill: Theme.window)
        window.contentView = root
        let column = NSTableColumn(identifier: .init("tag"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let add = NSButton(title: "New Tag", target: self, action: #selector(newTag))
        add.bezelStyle = .rounded
        let hint = NSTextField.label("Right-click a tag on any to-do to change its colour too.", font: Fonts.regular(11), color: Theme.tertiary)
        for v in [scroll, add, hint] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -10),
            add.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            add.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            hint.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: add.centerYAnchor)
        ])
    }

    @objc private func reload() {
        tags = TaskStore.shared.knownTags
        table.reloadData()
    }

    @objc private func newTag() {
        if let name = Prompt.text(title: "New Tag", message: "", placeholder: "Tag name", button: "Add") {
            TaskStore.shared.addTagName(name)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tags.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tag = tags[row]
        let cell = FlippedView()
        let popup = NSPopUpButton()
        popup.isBordered = false
        for color in TagColor.allCases {
            popup.addItem(withTitle: "")
            popup.lastItem?.image = TagMenus.swatch(color.color)
            popup.lastItem?.toolTip = color.title
            popup.lastItem?.representedObject = color.rawValue
        }
        popup.selectItem(at: TagColor.allCases.firstIndex(of: TaskStore.shared.tagColor(tag)) ?? 0)
        popup.target = self
        popup.action = #selector(colorPicked(_:))
        popup.identifier = .init(tag)
        let name = NSTextField()
        name.stringValue = tag
        name.isBordered = false
        name.drawsBackground = false
        name.font = Fonts.regular(13.5)
        name.identifier = .init(tag)
        name.delegate = self
        let count = TaskStore.shared.tasks.filter { $0.isOpen && $0.tags.contains(tag) }.count
        let countLabel = NSTextField.label(count == 0 ? "" : "\(count)", font: Fonts.regular(12), color: Theme.tertiary)
        let delete = IconButton(symbol: "trash", size: 11, color: Theme.tertiary, tooltip: "Delete tag")
        delete.identifier = .init(tag)
        delete.target = self
        delete.action = #selector(deleteTag(_:))
        popup.frame = NSRect(x: 4, y: 5, width: 44, height: 24)
        name.frame = NSRect(x: 54, y: 8, width: 230, height: 19)
        countLabel.frame = NSRect(x: 290, y: 9, width: 40, height: 16)
        delete.frame = NSRect(x: 340, y: 7, width: 22, height: 20)
        [popup, name, countLabel, delete].forEach(cell.addSubview)
        return cell
    }

    @objc private func colorPicked(_ sender: NSPopUpButton) {
        guard let tag = sender.identifier?.rawValue, let raw = sender.selectedItem?.representedObject as? String,
              let color = TagColor(rawValue: raw) else { return }
        TaskStore.shared.setTagColor(tag, color)
    }

    @objc private func deleteTag(_ sender: NSButton) {
        guard let tag = sender.identifier?.rawValue else { return }
        let count = TaskStore.shared.tasks.filter { $0.tags.contains(tag) }.count
        guard Prompt.confirm(title: "Delete the tag “\(tag)”?", message: count == 0 ? "" : "It will be removed from \(count) to-do\(count == 1 ? "" : "s").", button: "Delete") else { return }
        TaskStore.shared.deleteTag(tag)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let old = field.identifier?.rawValue else { return }
        TaskStore.shared.renameTag(old, to: field.stringValue)
    }
}
