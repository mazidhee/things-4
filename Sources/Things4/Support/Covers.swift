import AppKit
import ImageIO

/// Notion-style page covers. A cover is stored as a spec string:
/// `gradient:<n>`, `color:<n>`, `wallpaper:<path>` or `file:<name in the Covers folder>`.
enum Covers {
    struct Gradient {
        let name: String
        let colors: [String]
        let mesh: Bool
    }

    static let gradients: [Gradient] = [
        Gradient(name: "Dusk", colors: ["#FF9A8B", "#FF6A88", "#FF99AC"], mesh: false),
        Gradient(name: "Sunrise", colors: ["#F6D365", "#FDA085"], mesh: false),
        Gradient(name: "Peach", colors: ["#FFECD2", "#FCB69F"], mesh: false),
        Gradient(name: "Mint", colors: ["#84FAB0", "#8FD3F4"], mesh: false),
        Gradient(name: "Lavender", colors: ["#A18CD1", "#FBC2EB"], mesh: false),
        Gradient(name: "Ocean", colors: ["#2E3192", "#1BFFFF"], mesh: false),
        Gradient(name: "Night", colors: ["#0F2027", "#203A43", "#2C5364"], mesh: false),
        Gradient(name: "Ember", colors: ["#F83600", "#F9D423"], mesh: false),
        Gradient(name: "Aurora", colors: ["#191654", "#43C6AC", "#7F7FD5", "#91EAE4"], mesh: true),
        Gradient(name: "Candy", colors: ["#FBC2EB", "#A6C1EE", "#FAD0C4", "#FFD1FF"], mesh: true),
        Gradient(name: "Lagoon", colors: ["#0B486B", "#3B8686", "#79BD9A", "#CFF09E"], mesh: true),
        Gradient(name: "Blaze", colors: ["#3A1C71", "#D76D77", "#FFAF7B", "#FF5F6D"], mesh: true),
    ]

    static let colors: [(name: String, hex: String)] = [
        ("Red", "#E16259"), ("Orange", "#D9730D"), ("Yellow", "#DFAB01"), ("Green", "#4D8461"),
        ("Blue", "#0B6E99"), ("Purple", "#9065B0"), ("Pink", "#C14C8A"), ("Grey", "#787774"),
    ]

    static var wallpapers: [URL] {
        let folder = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { ["heic", "jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Covers live next to the database, so test databases never touch the real folder.
    static var directory: URL {
        let override = ProcessInfo.processInfo.environment["THINGS4_DB"] ?? ""
        let base = override.isEmpty
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Things4")
            : URL(fileURLWithPath: override).deletingLastPathComponent()
        let url = base.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func randomSpec() -> String { "gradient:\(Int.random(in: 0..<gradients.count))" }

    /// Copies a picked image into the Covers folder and returns its spec.
    static func importImage(at url: URL) -> String? {
        let name = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased())
        do {
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
            return "file:" + name
        } catch { return nil }
    }

    /// Deletes an imported file once it is no longer the cover.
    static func discard(_ spec: String?) {
        guard let spec, spec.hasPrefix("file:") else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(String(spec.dropFirst(5))))
    }

    static func fileURL(for spec: String) -> URL? {
        if spec.hasPrefix("wallpaper:") { return URL(fileURLWithPath: String(spec.dropFirst(10))) }
        if spec.hasPrefix("file:") { return directory.appendingPathComponent(String(spec.dropFirst(5))) }
        return nil
    }

    // MARK: Drawing

    /// Draws a generated (gradient or colour) cover; returns false for image covers.
    @discardableResult
    static func drawGenerated(_ spec: String, in rect: NSRect) -> Bool {
        if spec.hasPrefix("color:"), let index = Int(spec.dropFirst(6)), colors.indices.contains(index) {
            NSColor(hex: colors[index].hex).setFill()
            rect.fill()
            return true
        }
        guard spec.hasPrefix("gradient:"), let index = Int(spec.dropFirst(9)), gradients.indices.contains(index) else { return false }
        let gradient = gradients[index]
        let colors = gradient.colors.map { NSColor(hex: $0) }
        if gradient.mesh {
            colors[0].setFill()
            rect.fill()
            let anchors: [(CGFloat, CGFloat)] = [(0.15, 0.2), (0.8, 0.3), (0.35, 0.95), (0.9, 0.9)]
            for (i, color) in colors.enumerated().dropFirst() {
                let (ax, ay) = anchors[i % anchors.count]
                let center = NSPoint(x: rect.minX + rect.width * ax, y: rect.minY + rect.height * ay)
                let radius = max(rect.width, rect.height) * 0.55
                NSGradient(colors: [color, color.withAlphaComponent(0)])?
                    .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
            }
        } else {
            NSGradient(colors: colors)?.draw(in: rect, angle: -18)
        }
        return true
    }

    // MARK: Images

    private static var cache: [String: NSImage] = [:]

    static func cachedImage(_ spec: String) -> NSImage? { cache[spec] }

    /// Loads (downscaled) image covers off the main thread.
    static func loadImage(_ spec: String, maxPixel: Int = 3000, completion: @escaping (NSImage?) -> Void) {
        let key = maxPixel >= 3000 ? spec : "\(spec)@\(maxPixel)"
        if let image = cache[key] { completion(image); return }
        guard let url = fileURL(for: spec) else { completion(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = thumbnail(url, maxPixel: maxPixel)
            DispatchQueue.main.async {
                if let image { cache[key] = image }
                completion(image)
            }
        }
    }

    private static func thumbnail(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
