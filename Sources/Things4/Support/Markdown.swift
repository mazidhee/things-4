import AppKit

/// Lightweight Markdown support for notes. Two modes:
/// - `applyLiveStyle` styles the raw text in place while editing (Bear / Things style:
///   markers stay visible but dimmed, headings grow, lists indent, code goes mono).
/// - `render` produces a read-only attributed string with the markers removed.
enum Markdown {
    struct Fonts {
        let base: CGFloat
        var body: NSFont { .systemFont(ofSize: base) }
        var relaxed = false
        var h1: NSFont { .systemFont(ofSize: base + (relaxed ? 14 : 9), weight: .bold) }
        var h2: NSFont { .systemFont(ofSize: base + (relaxed ? 8 : 5), weight: .bold) }
        var h3: NSFont { .systemFont(ofSize: base + (relaxed ? 4 : 2), weight: .semibold) }
        var bold: NSFont { .systemFont(ofSize: base, weight: .semibold) }
        var italic: NSFont { NSFontManager.shared.convert(.systemFont(ofSize: base), toHaveTrait: .italicFontMask) }
        var mono: NSFont { .monospacedSystemFont(ofSize: base - 0.5, weight: .regular) }
    }

    private static let heading = try! NSRegularExpression(pattern: "^(#{1,3})\\s+(.*)$", options: [.anchorsMatchLines])
    private static let bullet = try! NSRegularExpression(pattern: "^(\\s*)([-*+])\\s+(?!\\[[ xX]\\])", options: [.anchorsMatchLines])
    private static let numbered = try! NSRegularExpression(pattern: "^(\\s*)(\\d+)\\.\\s+", options: [.anchorsMatchLines])
    private static let checkbox = try! NSRegularExpression(pattern: "^(\\s*)([-*+])\\s+\\[([ xX])\\]\\s?", options: [.anchorsMatchLines])
    private static let quote = try! NSRegularExpression(pattern: "^>\\s?(.*)$", options: [.anchorsMatchLines])
    private static let fence = try! NSRegularExpression(pattern: "^```[^\\n]*\\n([\\s\\S]*?)\\n```\\s*$", options: [.anchorsMatchLines])
    private static let rule = try! NSRegularExpression(pattern: "^(-{3,}|\\*{3,}|_{3,})\\s*$", options: [.anchorsMatchLines])
    private static let boldInline = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1", options: [])
    private static let italicInline = try! NSRegularExpression(pattern: "(?<![*_\\w])([*_])(?![*_\\s])(.+?)(?<![*_\\s])\\1(?![*_\\w])", options: [])
    private static let strikeInline = try! NSRegularExpression(pattern: "~~(?=\\S)(.+?)(?<=\\S)~~", options: [])
    private static let codeInline = try! NSRegularExpression(pattern: "`([^`\\n]+)`", options: [])
    private static let highlightInline = try! NSRegularExpression(pattern: "::(?=\\S)(.+?)(?<=\\S)::", options: [])
    static let highlightColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.45, blue: 0.10, alpha: 0.55)
            : NSColor(srgbRed: 1.0, green: 0.90, blue: 0.40, alpha: 0.6)
    }
    private static let link = try! NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\s]+)\\)", options: [])
    private static let bareURL = try! NSRegularExpression(pattern: "(?<![\\(\\[])https?://[^\\s<>\\)\\]]+", options: [])

    // MARK: - Live styling

    /// `relaxed` is the document style used on the full note page: roomier
    /// line height and a clearer heading scale, like Notion or Bear.
    static func applyLiveStyle(to storage: NSTextStorage, baseSize: CGFloat, relaxed: Bool = false) {
        var fonts = Fonts(base: baseSize)
        fonts.relaxed = relaxed
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = relaxed ? 6 : 2
        paragraph.paragraphSpacing = relaxed ? 2 : 3

        storage.beginEditing()
        storage.setAttributes([
            .font: fonts.body,
            .foregroundColor: Theme.text,
            .paragraphStyle: paragraph
        ], range: full)

        // Code fences first; nothing else applies inside them.
        var fenced: [NSRange] = []
        for match in fence.matches(in: storage.string, range: full) {
            fenced.append(match.range)
            storage.addAttributes([.font: fonts.mono, .backgroundColor: Theme.card], range: match.range)
            storage.addAttribute(.foregroundColor, value: Theme.tertiary, range: NSRange(location: match.range.location, length: 3))
        }
        func inFence(_ range: NSRange) -> Bool { fenced.contains { NSIntersectionRange($0, range).length > 0 } }

        for match in heading.matches(in: storage.string, range: full) where !inFence(match.range) {
            let level = match.range(at: 1).length
            let font = level == 1 ? fonts.h1 : (level == 2 ? fonts.h2 : fonts.h3)
            storage.addAttribute(.font, value: font, range: match.range)
            storage.addAttribute(.foregroundColor, value: Theme.tertiary, range: match.range(at: 1))
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = relaxed ? (level == 1 ? 8 : 6) : (level == 1 ? 10 : 6)
            style.paragraphSpacing = relaxed ? 4 : 4
            storage.addAttribute(.paragraphStyle, value: style, range: match.range)
        }

        for match in checkbox.matches(in: storage.string, range: full) where !inFence(match.range) {
            let checked = text.substring(with: match.range(at: 3)).lowercased() == "x"
            storage.addAttribute(.foregroundColor, value: Theme.tertiary, range: match.range)
            if checked {
                let line = text.lineRange(for: match.range)
                let rest = NSRange(location: match.range.upperBound, length: max(0, line.upperBound - match.range.upperBound))
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: Theme.secondary], range: rest)
            }
            indent(storage, line: text.lineRange(for: match.range), marker: match.range.length, base: paragraph)
        }
        for match in bullet.matches(in: storage.string, range: full) where !inFence(match.range) {
            storage.addAttribute(.foregroundColor, value: Theme.tertiary, range: match.range(at: 2))
            indent(storage, line: text.lineRange(for: match.range), marker: match.range.length, base: paragraph)
        }
        for match in numbered.matches(in: storage.string, range: full) where !inFence(match.range) {
            storage.addAttribute(.foregroundColor, value: Theme.tertiary, range: match.range(at: 2))
            indent(storage, line: text.lineRange(for: match.range), marker: match.range.length, base: paragraph)
        }
        for match in quote.matches(in: storage.string, range: full) where !inFence(match.range) {
            storage.addAttributes([.font: fonts.italic, .foregroundColor: Theme.secondary], range: match.range)
            storage.addAttribute(.foregroundColor, value: Theme.accent, range: NSRange(location: match.range.location, length: 1))
        }
        for match in rule.matches(in: storage.string, range: full) where !inFence(match.range) {
            storage.addAttribute(.foregroundColor, value: Theme.tertiary, range: match.range)
        }

        for match in codeInline.matches(in: storage.string, range: full) where !inFence(match.range) {
            storage.addAttributes([.font: fonts.mono, .backgroundColor: Theme.card, .foregroundColor: Theme.text], range: match.range)
        }
        for match in boldInline.matches(in: storage.string, range: full) where !inFence(match.range) {
            storage.addAttribute(.font, value: fonts.bold, range: match.range)
            dim(storage, match.range(at: 1))
            dim(storage, NSRange(location: match.range.upperBound - match.range(at: 1).length, length: match.range(at: 1).length))
        }
        for match in italicInline.matches(in: storage.string, range: full) where !inFence(match.range) {
            storage.addAttribute(.font, value: fonts.italic, range: match.range)
            dim(storage, NSRange(location: match.range.location, length: 1))
            dim(storage, NSRange(location: match.range.upperBound - 1, length: 1))
        }
        for match in highlightInline.matches(in: storage.string, range: full) where !inFence(match.range) {
            storage.addAttribute(.backgroundColor, value: highlightColor, range: match.range(at: 1))
            dim(storage, NSRange(location: match.range.location, length: 2))
            dim(storage, NSRange(location: match.range.upperBound - 2, length: 2))
        }
        for match in strikeInline.matches(in: storage.string, range: full) where !inFence(match.range) {
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Theme.secondary], range: match.range)
        }
        for match in link.matches(in: storage.string, range: full) where !inFence(match.range) {
            let target = text.substring(with: match.range(at: 2))
            storage.addAttributes([.foregroundColor: Theme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range(at: 1))
            if let url = URL(string: target) { storage.addAttribute(.link, value: url, range: match.range(at: 1)) }
            // Like Notion and Bear, show only the link text: collapse "[" and "](url)".
            collapse(storage, NSRange(location: match.range.location, length: 1))
            collapse(storage, NSRange(location: match.range(at: 1).upperBound, length: match.range.upperBound - match.range(at: 1).upperBound))
        }
        for match in bareURL.matches(in: storage.string, range: full) where !inFence(match.range) {
            if let url = URL(string: text.substring(with: match.range)) {
                storage.addAttributes([.link: url, .foregroundColor: Theme.accent], range: match.range)
            }
        }
        storage.endEditing()
    }

    private static func collapse(_ storage: NSTextStorage, _ range: NSRange) {
        storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear,
                               .underlineStyle: 0], range: range)
        storage.removeAttribute(.link, range: range)
    }

    private static func dim(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.location >= 0, range.upperBound <= storage.length else { return }
        storage.addAttribute(.foregroundColor, value: Theme.tertiary, range: range)
    }

    private static func indent(_ storage: NSTextStorage, line: NSRange, marker: Int, base: NSParagraphStyle) {
        let style = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        let markerText = (storage.string as NSString).substring(with: NSRange(location: line.location, length: min(marker, line.length)))
        let font = storage.attribute(.font, at: line.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 14)
        let width = ceil((markerText as NSString).size(withAttributes: [.font: font]).width)
        style.headIndent = width
        style.firstLineHeadIndent = 0
        style.paragraphSpacing = 1
        storage.addAttribute(.paragraphStyle, value: style, range: line)
    }

    // MARK: - Rendering (markers removed)

    static func render(_ markdown: String, baseSize: CGFloat) -> NSAttributedString {
        let fonts = Fonts(base: baseSize)
        let output = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        var listNumber = 0

        func paragraph(spacingBefore: CGFloat = 0, spacing: CGFloat = 5, indent: CGFloat = 0) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = spacing
            style.headIndent = indent
            style.lineSpacing = 2
            return style
        }

        while index < lines.count {
            let line = lines[index]
            let nsLine = line as NSString
            let whole = NSRange(location: 0, length: nsLine.length)

            if line.hasPrefix("```") {
                var block: [String] = []
                index += 1
                while index < lines.count && !lines[index].hasPrefix("```") { block.append(lines[index]); index += 1 }
                index += 1
                output.append(NSAttributedString(string: block.joined(separator: "\n") + "\n", attributes: [
                    .font: fonts.mono, .foregroundColor: Theme.text, .backgroundColor: Theme.card, .paragraphStyle: paragraph(spacingBefore: 4, spacing: 8)]))
                listNumber = 0
                continue
            }
            if let match = heading.firstMatch(in: line, range: whole) {
                let level = match.range(at: 1).length
                let font = level == 1 ? fonts.h1 : (level == 2 ? fonts.h2 : fonts.h3)
                output.append(inline(nsLine.substring(with: match.range(at: 2)), fonts: fonts, font: font,
                                     paragraph: paragraph(spacingBefore: level == 1 ? 12 : 8, spacing: 6)))
                output.append(NSAttributedString(string: "\n"))
                index += 1; listNumber = 0
                continue
            }
            if rule.firstMatch(in: line, range: whole) != nil {
                output.append(NSAttributedString(string: "────────────\n", attributes: [.foregroundColor: Theme.separator, .font: fonts.body, .paragraphStyle: paragraph(spacing: 6)]))
                index += 1; listNumber = 0
                continue
            }
            if let match = checkbox.firstMatch(in: line, range: whole) {
                let checked = nsLine.substring(with: match.range(at: 3)).lowercased() == "x"
                let rest = nsLine.substring(from: match.range.upperBound)
                let mark = NSMutableAttributedString(string: (checked ? "☑ " : "☐ "), attributes: [
                    .font: fonts.body, .foregroundColor: checked ? Theme.success : Theme.accent, .paragraphStyle: paragraph(spacing: 2, indent: 18)])
                let body = inline(rest, fonts: fonts, font: fonts.body, paragraph: paragraph(spacing: 2, indent: 18))
                if checked {
                    let mutable = NSMutableAttributedString(attributedString: body)
                    mutable.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Theme.secondary],
                                          range: NSRange(location: 0, length: mutable.length))
                    mark.append(mutable)
                } else {
                    mark.append(body)
                }
                mark.append(NSAttributedString(string: "\n"))
                output.append(mark)
                index += 1; listNumber = 0
                continue
            }
            if let match = bullet.firstMatch(in: line, range: whole) {
                let depth = match.range(at: 1).length
                let rest = nsLine.substring(from: match.range.upperBound)
                let item = NSMutableAttributedString(string: String(repeating: "    ", count: depth / 2) + "•  ", attributes: [
                    .font: fonts.body, .foregroundColor: Theme.accent, .paragraphStyle: paragraph(spacing: 2, indent: 16 + CGFloat(depth) * 8)])
                item.append(inline(rest, fonts: fonts, font: fonts.body, paragraph: paragraph(spacing: 2, indent: 16 + CGFloat(depth) * 8)))
                item.append(NSAttributedString(string: "\n"))
                output.append(item)
                index += 1; listNumber = 0
                continue
            }
            if let match = numbered.firstMatch(in: line, range: whole) {
                listNumber += 1
                let rest = nsLine.substring(from: match.range.upperBound)
                let item = NSMutableAttributedString(string: "\(listNumber).  ", attributes: [
                    .font: fonts.body, .foregroundColor: Theme.accent, .paragraphStyle: paragraph(spacing: 2, indent: 22)])
                item.append(inline(rest, fonts: fonts, font: fonts.body, paragraph: paragraph(spacing: 2, indent: 22)))
                item.append(NSAttributedString(string: "\n"))
                output.append(item)
                index += 1
                continue
            }
            if let match = quote.firstMatch(in: line, range: whole) {
                let rest = nsLine.substring(with: match.range(at: 1))
                let item = NSMutableAttributedString(string: "▎ ", attributes: [.foregroundColor: Theme.accent, .font: fonts.body])
                item.append(inline(rest, fonts: fonts, font: fonts.italic, paragraph: paragraph(spacing: 4, indent: 14), color: Theme.secondary))
                item.append(NSAttributedString(string: "\n"))
                output.append(item)
                index += 1; listNumber = 0
                continue
            }
            listNumber = 0
            output.append(inline(line, fonts: fonts, font: fonts.body, paragraph: paragraph()))
            output.append(NSAttributedString(string: "\n"))
            index += 1
        }
        if output.length > 0 { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
        return output
    }

    private static func inline(_ text: String, fonts: Fonts, font: NSFont, paragraph: NSParagraphStyle, color: NSColor = Theme.text) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        func replace(_ regex: NSRegularExpression, keep: Int, transform: (NSMutableAttributedString, NSTextCheckingResult, NSString) -> Void) {
            var matches = regex.matches(in: result.string, range: NSRange(location: 0, length: result.length))
            matches.reverse()
            for match in matches {
                let source = result.string as NSString
                let inner = NSMutableAttributedString(attributedString: result.attributedSubstring(from: match.range(at: keep)))
                transform(inner, match, source)
                result.replaceCharacters(in: match.range, with: inner)
            }
        }
        replace(codeInline, keep: 1) { inner, _, _ in
            inner.addAttributes([.font: fonts.mono, .backgroundColor: Theme.card], range: NSRange(location: 0, length: inner.length))
        }
        replace(link, keep: 1) { inner, match, source in
            if let url = URL(string: source.substring(with: match.range(at: 2))) {
                inner.addAttributes([.link: url, .foregroundColor: Theme.accent], range: NSRange(location: 0, length: inner.length))
            }
        }
        replace(boldInline, keep: 2) { inner, _, _ in
            inner.addAttribute(.font, value: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold), range: NSRange(location: 0, length: inner.length))
        }
        replace(italicInline, keep: 2) { inner, _, _ in
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            inner.addAttribute(.font, value: italic, range: NSRange(location: 0, length: inner.length))
        }
        replace(highlightInline, keep: 1) { inner, _, _ in
            inner.addAttribute(.backgroundColor, value: highlightColor, range: NSRange(location: 0, length: inner.length))
        }
        replace(strikeInline, keep: 1) { inner, _, _ in
            inner.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Theme.secondary], range: NSRange(location: 0, length: inner.length))
        }
        for match in bareURL.matches(in: result.string, range: NSRange(location: 0, length: result.length)).reversed() {
            if let url = URL(string: (result.string as NSString).substring(with: match.range)) {
                result.addAttributes([.link: url, .foregroundColor: Theme.accent], range: match.range)
            }
        }
        return result
    }

    /// One-line preview for list rows: markers stripped, whitespace collapsed.
    static func plainPreview(_ markdown: String, limit: Int = 140) -> String {
        var text = markdown
        for pattern in ["^#{1,3}\\s+", "^\\s*[-*+]\\s+\\[[ xX]\\]\\s?", "^\\s*[-*+]\\s+", "^\\s*\\d+\\.\\s+", "^>\\s?", "```[^\\n]*", "\\*\\*|__|~~|`|::"] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        }
        if let links = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^)]+\\)") {
            text = links.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1")
        }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let joined = lines.joined(separator: "  ·  ")
        return String(joined.prefix(limit))
    }
}

/// An NSTextView that restyles its Markdown as you type.
final class MarkdownTextView: PlaceholderTextView {
    var baseSize: CGFloat = 12.5
    var relaxed = false
    var onChange: (() -> Void)?
    private var restyling = false

    /// Dropped files, web links and Mail messages become Markdown links.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.availableType(from: [.fileURL, .URL]) != nil {
            let items = Links.items(from: pasteboard)
            if !items.isEmpty {
                let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
                setSelectedRange(NSRange(location: index, length: 0))
                insertText(items.map(\.markdown).joined(separator: "\n"), replacementRange: selectedRange())
                window?.makeFirstResponder(self)
                return true
            }
        }
        return super.performDragOperation(sender)
    }

    func configure(baseSize: CGFloat) {
        self.baseSize = baseSize
        font = .systemFont(ofSize: baseSize)
        textColor = Theme.text
        insertionPointColor = Theme.text
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        usesFontPanel = false
        typingAttributes = [.font: NSFont.systemFont(ofSize: baseSize), .foregroundColor: Theme.text]
        restyle()
    }

    func setMarkdown(_ text: String) {
        string = text
        restyle()
    }

    func restyle() {
        guard let textStorage, !restyling else { return }
        restyling = true
        let selection = selectedRanges
        Markdown.applyLiveStyle(to: textStorage, baseSize: baseSize, relaxed: relaxed)
        selectedRanges = selection
        typingAttributes = [.font: NSFont.systemFont(ofSize: baseSize), .foregroundColor: Theme.text]
        restyling = false
    }

    override func didChangeText() {
        super.didChangeText()
        restyle()
        onChange?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    /// Height needed to show the whole text at the given width.
    /// Height of the styled text at a width, measured from the text itself
    /// (the layout manager over-reports for views that are not on screen yet).
    func contentHeight(for width: CGFloat) -> CGFloat {
        let available = max(10, width - textContainerInset.width * 2 - (textContainer?.lineFragmentPadding ?? 0) * 2)
        let text: NSAttributedString = (textStorage?.length ?? 0) > 0 ? textStorage! :
            NSAttributedString(string: "X", attributes: [.font: font ?? NSFont.systemFont(ofSize: baseSize)])
        var height = text.boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        if string.hasSuffix("\n") { height += (font ?? NSFont.systemFont(ofSize: baseSize)).boundingRectForFont.height }
        return ceil(height + textContainerInset.height * 2)
    }

    // Tab inserts spaces so lists can nest; Return continues a list item.
    override func insertTab(_ sender: Any?) {
        insertText("  ", replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let current = text.substring(with: line).trimmingCharacters(in: .newlines)
        let patterns: [(String, (String) -> String)] = [
            ("^(\\s*)([-*+])\\s+\\[[ xX]\\]\\s?", { "\($0)- [ ] " }),
            ("^(\\s*)([-*+])\\s+", { "\($0)- " }),
            ("^(\\s*)(\\d+)\\.\\s+", { indent in indent })
        ]
        for (pattern, make) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: current, range: NSRange(location: 0, length: (current as NSString).length)) {
                let marker = (current as NSString).substring(with: match.range)
                let content = (current as NSString).substring(from: match.range.upperBound)
                if content.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Empty item: end the list.
                    let start = line.location + match.range.location
                    insertText("", replacementRange: NSRange(location: start, length: match.range.length))
                    return
                }
                let indent = (current as NSString).substring(with: match.range(at: 1))
                var prefix = make(indent)
                if pattern.contains("\\d+"), let number = Int((current as NSString).substring(with: match.range(at: 2))) {
                    prefix = "\(indent)\(number + 1). "
                }
                _ = marker
                super.insertNewline(sender)
                insertText(prefix, replacementRange: selectedRange())
                return
            }
        }
        super.insertNewline(sender)
    }

    // Clicking a checkbox marker toggles it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let text = string as NSString
        if index < text.length {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            let lineText = text.substring(with: line)
            if let regex = try? NSRegularExpression(pattern: "^(\\s*[-*+]\\s+\\[)([ xX])(\\])"),
               let match = regex.firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)),
               index - line.location <= match.range.upperBound {
                let box = NSRange(location: line.location + match.range(at: 2).location, length: 1)
                let checked = text.substring(with: box).lowercased() == "x"
                insertText(checked ? " " : "x", replacementRange: box)
                return
            }
        }
        super.mouseDown(with: event)
    }
}
