import Cocoa
import UniformTypeIdentifiers

/// Preferences window. Shown from the orb's right-click menu.
final class PrefsWindow: NSObject, NSTextFieldDelegate {
    static let shared = PrefsWindow()

    private var window: NSWindow?
    private var onChange: (() -> Void)?

    private var picturePop: NSPopUpButton!
    private var eyePop: NSPopUpButton!
    private var clickPop: NSPopUpButton!
    private var urlField: NSTextField!
    private var stayBox: NSButton!
    private var loginBox: NSButton!
    private var personalityPop: NSPopUpButton!
    private var statusLabel: NSTextField!

    func show(onChange: @escaping () -> Void) {
        self.onChange = onChange
        if window == nil { build() }
        loadValues()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.level = .floating
        window?.orderFrontRegardless()
    }

    private func build() {
        let w: CGFloat = 460
        let h: CGFloat = 470
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Desk Bot Preferences"
        win.isReleasedWhenClosed = false
        win.center()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        win.contentView = content

        var y: CGFloat = h - 44
        @discardableResult
        func label(_ text: String, atY: CGFloat) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = .systemFont(ofSize: 13, weight: .medium)
            f.frame = NSRect(x: 24, y: atY, width: 160, height: 20)
            content.addSubview(f)
            return f
        }

        label("Picture", atY: y)
        picturePop = NSPopUpButton(frame: NSRect(x: 180, y: y - 3, width: 256, height: 26), pullsDown: false)
        picturePop.addItems(withTitles: ["Default orb", "Choose a PNG…"])
        picturePop.target = self
        picturePop.action = #selector(pictureChanged)
        content.addSubview(picturePop)
        y -= 36

        let clear = NSButton(title: "Use default orb", target: self, action: #selector(clearPicture))
        clear.bezelStyle = .rounded
        clear.frame = NSRect(x: 180, y: y - 2, width: 150, height: 24)
        content.addSubview(clear)
        y -= 40

        label("Eyes", atY: y)
        eyePop = NSPopUpButton(frame: NSRect(x: 180, y: y - 3, width: 256, height: 26), pullsDown: false)
        eyePop.addItems(withTitles: ["Highlight overlay (look around)", "Use the picture as-is"])
        eyePop.target = self
        eyePop.action = #selector(valueChanged)
        content.addSubview(eyePop)
        y -= 44

        label("Click action", atY: y)
        clickPop = NSPopUpButton(frame: NSRect(x: 180, y: y - 3, width: 256, height: 26), pullsDown: false)
        clickPop.addItems(withTitles: ["Open the Grok Bot app", "Open a pasted bot link", "Do nothing"])
        clickPop.target = self
        clickPop.action = #selector(valueChanged)
        content.addSubview(clickPop)
        y -= 36

        let urlHint = NSTextField(labelWithString: "Bot link")
        urlHint.font = .systemFont(ofSize: 13, weight: .medium)
        urlHint.frame = NSRect(x: 24, y: y, width: 160, height: 20)
        content.addSubview(urlHint)
        urlField = NSTextField(frame: NSRect(x: 180, y: y - 3, width: 256, height: 24))
        urlField.placeholderString = "grokbot://app/v1/agent?id=…"
        urlField.delegate = self
        content.addSubview(urlField)
        y -= 44

        label("Stay on Top", atY: y)
        stayBox = NSButton(checkboxWithTitle: "Keep the orb above other windows", target: self, action: #selector(valueChanged))
        stayBox.frame = NSRect(x: 180, y: y - 2, width: 256, height: 24)
        content.addSubview(stayBox)
        y -= 40

        label("Launch at login", atY: y)
        loginBox = NSButton(checkboxWithTitle: "Open Desk Bot when I log in", target: self, action: #selector(loginChanged))
        loginBox.frame = NSRect(x: 180, y: y - 2, width: 256, height: 24)
        content.addSubview(loginBox)
        y -= 40

        label("Personality", atY: y)
        personalityPop = NSPopUpButton(frame: NSRect(x: 180, y: y - 3, width: 256, height: 26), pullsDown: false)
        personalityPop.addItems(withTitles: ["Lively", "Chill"])
        personalityPop.target = self
        personalityPop.action = #selector(valueChanged)
        content.addSubview(personalityPop)
        y -= 50

        let note = NSTextField(wrappingLabelWithString: "Desk Bot is unofficial and is not affiliated with xAI, Grok, or Cursor. A free app from The Wood Lab.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 24, y: 48, width: w - 48, height: 48)
        content.addSubview(note)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 24, y: 20, width: w - 48, height: 18)
        content.addSubview(statusLabel)

        self.window = win
    }

    private func loadValues() {
        picturePop.selectItem(at: ArtworkStore.hasCustomPicture ? 1 : 0)
        // If a custom picture is in use, the first item stays "Default orb" and the pop shows "Choose a PNG…"
        // which is a bit odd. Set the title of item 1 after a choice.
        if ArtworkStore.hasCustomPicture {
            picturePop.item(at: 1)?.title = "Custom picture"
            picturePop.selectItem(at: 1)
        } else {
            picturePop.item(at: 1)?.title = "Choose a PNG…"
            picturePop.selectItem(at: 0)
        }
        eyePop.selectItem(at: Settings.eyeStyle == .ownLook ? 1 : 0)
        switch Settings.clickAction {
        case .grokBot: clickPop.selectItem(at: 0)
        case .url: clickPop.selectItem(at: 1)
        case .none: clickPop.selectItem(at: 2)
        }
        urlField.stringValue = Settings.clickURL
        stayBox.state = Settings.stayOnTop ? .on : .off
        loginBox.state = LoginItem.isEnabled ? .on : .off
        personalityPop.selectItem(at: Settings.personality == .chill ? 1 : 0)
        statusLabel.stringValue = ""
    }

    @objc private func pictureChanged() {
        if picturePop.indexOfSelectedItem == 1 && !ArtworkStore.hasCustomPicture || picturePop.indexOfSelectedItem == 1 {
            // Always offer a file picker when the custom row is chosen (unless we just loaded a custom title).
            // If they already have a custom picture and re-selected that row, don't force a new pick.
            if !ArtworkStore.hasCustomPicture || picturePop.item(at: 1)?.title == "Choose a PNG…" {
                choosePicture()
            }
        } else {
            // Selected default
        }
    }

    @objc private func clearPicture() {
        ArtworkStore.clearCustomPicture()
        loadValues()
        onChange?()
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a PNG with transparency. It will be cropped to a circle."
        panel.begin { [weak self] result in
            guard let self else { return }
            if result == .OK, let url = panel.url, ArtworkStore.importPicture(from: url) {
                self.statusLabel.stringValue = "Picture saved. The orb uses a circular crop of it."
                self.loadValues()
                self.onChange?()
            } else {
                self.loadValues()
            }
        }
    }

    @objc private func valueChanged() {
        Settings.eyeStyle = eyePop.indexOfSelectedItem == 1 ? .ownLook : .overlay
        switch clickPop.indexOfSelectedItem {
        case 1: Settings.clickAction = .url
        case 2: Settings.clickAction = .none
        default: Settings.clickAction = .grokBot
        }
        Settings.clickURL = urlField.stringValue
        Settings.stayOnTop = stayBox.state == .on
        Settings.personality = personalityPop.indexOfSelectedItem == 1 ? .chill : .lively
        onChange?()
    }

    @objc private func loginChanged() {
        let want = loginBox.state == .on
        if let err = LoginItem.setEnabled(want) {
            statusLabel.stringValue = err
            loginBox.state = LoginItem.isEnabled ? .on : .off
        } else {
            statusLabel.stringValue = want ? "Desk Bot will open when you log in." : "Launch at login is off."
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        Settings.clickURL = urlField.stringValue
        if clickPop.indexOfSelectedItem == 1 {
            Settings.clickAction = .url
        }
        onChange?()
    }
}
