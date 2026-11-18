import Cocoa
import ServiceManagement

enum ArtworkStore {
    static let fileName = "custom-orb.png"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Desk Bot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var customFileURL: URL {
        supportDirectory.appendingPathComponent(fileName)
    }

    static var hasCustomPicture: Bool {
        FileManager.default.fileExists(atPath: customFileURL.path)
    }

    static func customBodyImage() -> NSImage? {
        guard hasCustomPicture else { return nil }
        let img = NSImage(contentsOf: customFileURL)
        img?.isTemplate = false
        return img
    }

    /// Load a PNG (or any bitmap), mask it to a circle, and save it for the orb body.
    @discardableResult
    static func importPicture(from url: URL) -> Bool {
        guard let src = NSImage(contentsOf: url) else { return false }
        let side: CGFloat = 1024
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        let dest = NSImage(size: rect.size)
        dest.lockFocus()
        NSColor.clear.set()
        rect.fill()
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
        path.addClip()
        // Scale the image to fill the circle.
        let srcSize = src.size
        guard srcSize.width > 0, srcSize.height > 0 else {
            dest.unlockFocus()
            return false
        }
        let scale = max(side / srcSize.width, side / srcSize.height)
        let w = srcSize.width * scale
        let h = srcSize.height * scale
        src.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
                 from: .zero,
                 operation: .sourceOver,
                 fraction: 1)
        dest.unlockFocus()
        dest.isTemplate = false
        guard let tiff = dest.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: customFileURL)
            return true
        } catch {
            return false
        }
    }

    static func clearCustomPicture() {
        try? FileManager.default.removeItem(at: customFileURL)
    }
}

enum OpenGrokBot {
    /// Known or likely bundle IDs; we also search by app name and the grokbot: scheme.
    private static let bundleIDs = [
        "com.xai.GrokBot",
        "com.xai.grokbot",
        "ai.x.grokbot",
        "com.xai.grok",
        "com.x.grokbot"
    ]

    static func open() {
        if let url = appURL() {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
            return
        }
        if let scheme = URL(string: "grokbot://") {
            NSWorkspace.shared.open(scheme)
        }
    }

    static func appURL() -> URL? {
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "Grok Bot") {
            return url
        }
        let apps = ["/Applications/Grok Bot.app",
                    NSHomeDirectory() + "/Applications/Grok Bot.app"]
        for path in apps {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

enum LoginItem {
    @discardableResult
    static func setEnabled(_ on: Bool) -> String? {
        if #available(macOS 13.0, *) {
            do {
                if on {
                    try SMAppService.mainApp.register()
                } else if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        return "Launch at login needs macOS 13 or later."
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }
}
