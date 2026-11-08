import AppKit

/// Tag colours (Things 3 has none; this is our addition). Tuned for both appearances.
enum TagColor: String, CaseIterable {
    case none, red, orange, yellow, green, teal, blue, purple, pink, gray

    var title: String { self == .none ? "No Color" : rawValue.capitalized }

    var color: NSColor {
        func dyn(_ l: (CGFloat, CGFloat, CGFloat), _ d: (CGFloat, CGFloat, CGFloat)) -> NSColor {
            NSColor(name: nil) { a in
                let c = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }
        switch self {
        case .none: return dyn((0.20, 0.55, 0.40), (0.24, 0.52, 0.38))   // Things' green token
        case .red: return dyn((0.86, 0.22, 0.27), (0.90, 0.30, 0.34))
        case .orange: return dyn((0.93, 0.48, 0.13), (0.96, 0.56, 0.20))
        case .yellow: return dyn((0.84, 0.64, 0.05), (0.93, 0.76, 0.18))
        case .green: return dyn((0.20, 0.62, 0.32), (0.30, 0.72, 0.42))
        case .teal: return dyn((0.10, 0.60, 0.62), (0.24, 0.70, 0.72))
        case .blue: return dyn((0.20, 0.47, 0.90), (0.36, 0.58, 0.96))
        case .purple: return dyn((0.53, 0.33, 0.85), (0.66, 0.48, 0.94))
        case .pink: return dyn((0.89, 0.30, 0.58), (0.94, 0.42, 0.66))
        case .gray: return dyn((0.50, 0.50, 0.53), (0.56, 0.56, 0.59))
        }
    }

    /// Sensible defaults for Things' built-in tags.
    static func defaultColor(for tag: String) -> TagColor {
        switch tag.lowercased() {
        case "important", "urgent": return .red
        case "errand", "errands": return .orange
        case "pending", "waiting": return .yellow
        case "home", "personal": return .green
        case "office", "work": return .blue
        default: return .none
        }
    }
}

extension TaskStore {
    func tagColor(_ tag: String) -> TagColor { tagColorMap[tag] ?? TagColor.defaultColor(for: tag) }
    /// The colour used when drawing; uncoloured tags fall back to grey on rows.
    func tagTint(_ tag: String) -> NSColor? {
        let c = tagColor(tag)
        return c == .none ? nil : c.color
    }
}
