import Cocoa

final class AboutWindow: NSObject {
    static let shared = AboutWindow()
    private var window: NSWindow?

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.level = .floating
        window?.orderFrontRegardless()
    }

    private func build() {
        let w: CGFloat = 420
        let h: CGFloat = 320
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About Desk Bot"
        win.isReleasedWhenClosed = false
        win.center()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        win.contentView = content

        if let icon = NSImage(named: "app-icon") ?? NSImage(named: "orb-body") {
            icon.isTemplate = false
            let iv = NSImageView(frame: NSRect(x: (w - 72) / 2, y: h - 100, width: 72, height: 72))
            iv.image = icon
            iv.imageScaling = .scaleProportionallyUpOrDown
            content.addSubview(iv)
        }

        let title = NSTextField(labelWithString: "Desk Bot")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 24, y: h - 132, width: w - 48, height: 26)
        content.addSubview(title)

        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let version = NSTextField(labelWithString: "Version \(ver)")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.alignment = .center
        version.frame = NSRect(x: 24, y: h - 154, width: w - 48, height: 18)
        content.addSubview(version)

        let blurb = NSTextField(wrappingLabelWithString: "Unofficial, not affiliated with xAI, Grok, or Cursor.\n\nA free desk companion from The Wood Lab.")
        blurb.font = .systemFont(ofSize: 13)
        blurb.alignment = .center
        blurb.frame = NSRect(x: 36, y: 78, width: w - 72, height: 80)
        content.addSubview(blurb)

        let site = NSButton(title: "thewoodlabtx.com", target: self, action: #selector(openSite))
        site.bezelStyle = .rounded
        site.frame = NSRect(x: (w - 180) / 2, y: 28, width: 180, height: 28)
        content.addSubview(site)

        self.window = win
    }

    @objc private func openSite() {
        NSWorkspace.shared.open(woodLabURL)
    }
}
