import Cocoa
import CoreGraphics
import QuartzCore
import ApplicationServices
import CoreVideo
import ServiceManagement

private enum PrefKey {
    static let frame = "buddyFrame"
    static let personality = "personality" // "lively" or "chill"
    static let hideUntil = "hideUntil"
    static let stayOnTop = "stayOnTop"
    static let clickAction = "clickAction" // "grokBot", "url", "none"
    static let clickURL = "clickURL"
    static let eyeStyle = "eyeStyle" // "overlay" or "ownLook"
    static let customPicture = "customPictureName"
}

let woodLabURL = URL(string: "https://thewoodlabtx.com")!
let supportEmail = "hello@thewoodlabtx.com"

enum Personality: String {
    case lively
    case chill
}

enum ClickAction: String {
    case grokBot
    case url
    case none
}

enum EyeStyle: String {
    case overlay
    case ownLook
}

enum Settings {
    static var personality: Personality {
        get { Personality(rawValue: UserDefaults.standard.string(forKey: PrefKey.personality) ?? "") ?? .lively }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: PrefKey.personality) }
    }
    static var stayOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: PrefKey.stayOnTop) }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.stayOnTop) }
    }
    static var clickAction: ClickAction {
        get { ClickAction(rawValue: UserDefaults.standard.string(forKey: PrefKey.clickAction) ?? "") ?? .grokBot }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: PrefKey.clickAction) }
    }
    static var clickURL: String {
        get { UserDefaults.standard.string(forKey: PrefKey.clickURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.clickURL) }
    }
    static var eyeStyle: EyeStyle {
        get { EyeStyle(rawValue: UserDefaults.standard.string(forKey: PrefKey.eyeStyle) ?? "") ?? .overlay }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: PrefKey.eyeStyle) }
    }
    static var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }
}
private let orbPointSize: CGFloat = 96
private let windowPointSize: CGFloat = 176  // room for hop, perk, and a full spin without clipping
private let logicHz: TimeInterval = 1.0 / 30.0
private let eyeBaseScale: CGFloat = 1.18
private let mouseDeadZone: CGFloat = 2
private let focusDeadZone: CGFloat = 3
private let orbRadius: CGFloat = orbPointSize / 2 - 4
/// Shift the baked highlight texture so the eyes sit in a face-like rest pose
/// (slightly above center), giving room to look in every direction.
private let eyeRestShift = CGPoint(x: 0, y: 0)
private let eyeMaxTravel: CGFloat = 22

@main
enum DeskBotMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var buddyView: BuddyView?
    private var unhideWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = BuddyView(frame: NSRect(x: 0, y: 0, width: windowPointSize, height: windowPointSize))
        view.onAction = { [weak self] action in
            self?.handle(action)
        }
        view.lively = Settings.personality == .lively
        view.stayOnTop = Settings.stayOnTop
        view.eyeStyle = Settings.eyeStyle
        buddyView = view
        view.reloadArtwork()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: windowPointSize, height: windowPointSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .utilityWindow
        panel.acceptsMouseMovedEvents = true
        self.panel = panel

        panel.setFrame(Self.restoredOrDefaultFrame(), display: true)
        applyWindowArrangement(show: true)

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyHideState(launching: false)
            self?.applyWindowArrangement()
            self?.updateLifeFromEnvironment()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.buddyView?.setLifeEnabled(false)
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.buddyView?.setLifeEnabled(false)
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyWindowArrangement()
            self?.updateLifeFromEnvironment()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyWindowArrangement()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                return
            }
            self?.applyWindowArrangement()
            self?.buddyView?.noteAppSwitch()
        })

        let notes = NotificationCenter.default
        observers.append(notes.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyWindowArrangement()
        })

        let dist = DistributedNotificationCenter.default()
        observers.append(dist.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.buddyView?.setLifeEnabled(false)
        })
        observers.append(dist.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.applyWindowArrangement()
            self?.updateLifeFromEnvironment()
        })

        applyHideState(launching: true)
        updateLifeFromEnvironment()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveFrame()
        buddyView?.setLifeEnabled(false)
        let workspace = NSWorkspace.shared.notificationCenter
        let dist = DistributedNotificationCenter.default()
        let notes = NotificationCenter.default
        for obs in observers {
            workspace.removeObserver(obs)
            dist.removeObserver(obs)
            notes.removeObserver(obs)
        }
        observers.removeAll()
    }

    private func handle(_ action: BuddyAction) {
        switch action {
        case .clicked:
            performClickAction()
        case .moved:
            saveFrame()
        case .stayOnTopChanged:
            Settings.stayOnTop = buddyView?.stayOnTop ?? false
            applyWindowArrangement()
        case .openPreferences:
            PrefsWindow.shared.show(onChange: { [weak self] in
                self?.applyAllSettings()
            })
        case .openAbout:
            AboutWindow.shared.show()
        case .hideForHour:
            let until = Date().addingTimeInterval(60 * 60)
            UserDefaults.standard.set(until, forKey: PrefKey.hideUntil)
            applyHideState(launching: false)
        case .quit:
            saveFrame()
            NSApp.terminate(nil)
        }
    }

    private func applyAllSettings() {
        buddyView?.lively = Settings.personality == .lively
        buddyView?.stayOnTop = Settings.stayOnTop
        buddyView?.eyeStyle = Settings.eyeStyle
        buddyView?.reloadArtwork()
        applyWindowArrangement()
    }

    private func performClickAction() {
        switch Settings.clickAction {
        case .none:
            return
        case .url:
            let raw = Settings.clickURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty {
                NSWorkspace.shared.open(url)
            }
        case .grokBot:
            OpenGrokBot.open()
        }
    }

    private func applyHideState(launching: Bool) {
        unhideWork?.cancel()
        unhideWork = nil

        if launching {
            UserDefaults.standard.removeObject(forKey: PrefKey.hideUntil)
            applyWindowArrangement(show: true)
            updateLifeFromEnvironment()
            return
        }

        guard let until = UserDefaults.standard.object(forKey: PrefKey.hideUntil) as? Date,
              until > Date() else {
            UserDefaults.standard.removeObject(forKey: PrefKey.hideUntil)
            applyWindowArrangement(show: true)
            updateLifeFromEnvironment()
            return
        }

        panel?.orderOut(nil)
        buddyView?.setLifeEnabled(false)
        let remaining = until.timeIntervalSinceNow
        let work = DispatchWorkItem { [weak self] in
            self?.applyHideState(launching: false)
        }
        unhideWork = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + remaining, execute: work)
    }

    /// Apply the "Stay on Top" preference immediately.
    /// When `show` is true (launch / unhide), the panel is ordered front so an
    /// accessory app actually appears. Otherwise `orderFrontRegardless` is only
    /// used when Stay on Top is on, so other apps can cover the orb when it's off.
    private func applyWindowArrangement(show: Bool = false) {
        guard let panel else { return }
        if panel.isVisible == false,
           let until = UserDefaults.standard.object(forKey: PrefKey.hideUntil) as? Date,
           until > Date() {
            return
        }
        let stayOnTop = Settings.stayOnTop
        panel.hidesOnDeactivate = false
        if stayOnTop {
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        } else {
            panel.isFloatingPanel = false
            panel.level = .normal
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
        if show || stayOnTop {
            panel.orderFrontRegardless()
        }
    }

    private func updateLifeFromEnvironment() {
        let hidden = panel?.isVisible != true
        if !hidden { applyWindowArrangement() }
        buddyView?.setLifeEnabled(!hidden)
    }

    private func saveFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: PrefKey.frame)
    }

    private static func restoredOrDefaultFrame() -> NSRect {
        let size = NSSize(width: windowPointSize, height: windowPointSize)
        if let saved = UserDefaults.standard.string(forKey: PrefKey.frame) {
            let frame = NSRectFromString(saved)
            if frame.width > 0, frame.height > 0 {
                // Keep the orb's visual center if the window size has changed.
                let mid = NSPoint(x: frame.midX, y: frame.midY)
                let sized = NSRect(
                    x: mid.x - size.width / 2,
                    y: mid.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                if let clamped = clampToVisible(sized) {
                    return clamped
                }
            }
        }
        return defaultFrame(size: size)
    }

    private static func clampToVisible(_ frame: NSRect) -> NSRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }
        if let screen = screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? screens.first(where: { $0.visibleFrame.contains(NSPoint(x: frame.midX, y: frame.midY)) }) {
            return nudged(frame, into: screen.visibleFrame)
        }
        return nil
    }

    private static func nudged(_ frame: NSRect, into visible: NSRect) -> NSRect {
        var origin = frame.origin
        let margin: CGFloat = 8
        let minX = visible.minX + margin
        let maxX = visible.maxX - frame.width - margin
        let minY = visible.minY + margin
        let maxY = visible.maxY - frame.height - margin
        origin.x = max(minX, min(origin.x, max(minX, maxX)))
        origin.y = max(minY, min(origin.y, max(minY, maxY)))
        return NSRect(origin: origin, size: frame.size)
    }

    private static func defaultFrame(size: NSSize) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let x = vis.maxX - size.width - 24
        let y = vis.minY + 24
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

enum BuddyAction {
    case clicked
    case moved
    case stayOnTopChanged
    case openPreferences
    case openAbout
    case hideForHour
    case quit
}

final class BuddyView: NSView {
    var onAction: ((BuddyAction) -> Void)?
    var lively: Bool = true
    var stayOnTop: Bool = false
    var eyeStyle: EyeStyle = .overlay

    private let perkView = NSView()
    private let hopView = NSView()
    private let bobView = NSView()
    private let spinView = NSView()
    private let bodyView = NSImageView()
    private let clipView = NSView()
    /// Dedicated layer for spin/sigh. AppKit resets a view-backed layer's
    /// anchorPoint to (0,0), which would pivot the orb around a corner.
    private let spinLayer = CALayer()
    private let bodyLayer = CALayer()
    private let eyeClipLayer = CALayer()
    private let highlightLayer = CALayer()

    private var hovering = false
    private var isDragging = false
    /// Radians and rad/s for a velocity-tied twirl while the orb is dragged.
    private var dragSpinAngle: CGFloat = 0
    private var dragSpinVel: CGFloat = 0
    private var dragSpinSettling = false
    private var trackingArea: NSTrackingArea?
    private var lifeTimer: Timer?
    private var lifeEnabled = false

    /// Normalized look direction, length 0...1. (1,0) is full right, (0,-1) full down.
    private var look = CGPoint.zero
    private var lookVel = CGPoint.zero
    private var lastMouse = NSEvent.mouseLocation
    private var heldMouse = NSEvent.mouseLocation
    private var heldGazePoint: NSPoint?
    private var lastMouseMoved = Date()
    private var lastTick = Date()
    private var nextBlink = Date().addingTimeInterval(3)
    private var blinking = false
    private var blinkStartedAt: Date?
    private var blinkDouble = false

    private var frameDriver: FrameDriver?
    private var displayRateMode: UInt8 = 255
    private var bobPhase: CGFloat = 0
    private var bobSleeping = false
    private var hopStartedAt: Date?
    private var hopHeight: CGFloat = 0
    private var hopDuration: TimeInterval = 0.38
    private var perkScale: CGFloat = 1
    private var perkVel: CGFloat = 0
    private var perkTarget: CGFloat = 1

    // Mood
    private var interest: CGFloat = 0.55
    private var dozing = false
    private var lastInput = Date()
    private var pendingClick: DispatchWorkItem?
    private var lastClickAt: Date?
    private var busyUntil = Date.distantPast
    private var lastHopAt = Date.distantPast

    // Idle / show business
    private var nextPlayfulSpin = Date().addingTimeInterval(TimeInterval.random(in: 60...180))
    private var nextBusiness = Date().addingTimeInterval(6)
    private var wanderUntil = Date.distantPast
    private var wanderTarget = CGPoint.zero
    private var eyeRollUntil = Date.distantPast
    private var eyeRollStart = Date.distantPast
    private var dizzyUntil = Date.distantPast
    private var dizzyStart = Date.distantPast
    private var clockGlanceUntil = Date.distantPast
    private var clockGlanceTarget = CGPoint.zero
    private var lastClockGlanceHour: Int = -1
    private var snapUntil = Date.distantPast
    private var lastFocusPoint = CGPoint.zero
    private var lastFocusApp: pid_t = 0
    private var knownWindowIDs = Set<Int>()
    private var windowIDsPrimed = false
    private var lastWindowPoll = Date.distantPast
    private var lastStartle = Date.distantPast
    private var lastAXPoll = Date.distantPast
    private var cachedFocusPoint: NSPoint?
    private var cachedWindowCenter: NSPoint?
    private var lastWindowCenterPoll = Date.distantPast

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.masksToBounds = false

        let orb = NSRect(
            x: (bounds.width - orbPointSize) / 2,
            y: (bounds.height - orbPointSize) / 2,
            width: orbPointSize,
            height: orbPointSize
        )

        func clearView(_ v: NSView) {
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.clear.cgColor
            v.layer?.isOpaque = false
            v.layer?.masksToBounds = false
            v.autoresizingMask = [.width, .height]
        }

        perkView.frame = bounds
        clearView(perkView)
        addSubview(perkView)

        hopView.frame = perkView.bounds
        clearView(hopView)
        perkView.addSubview(hopView)

        bobView.frame = hopView.bounds
        clearView(bobView)
        hopView.addSubview(bobView)

        spinView.frame = bobView.bounds
        clearView(spinView)
        bobView.addSubview(spinView)

        // Spin lives on a dedicated CALayer so rotation is about the orb's
        // center. bodyView/clipView stay off the hierarchy; they were view-backed
        // layers whose anchorPoint AppKit would reset to (0, 0).
        spinView.layer?.masksToBounds = false
        spinLayer.masksToBounds = false
        spinLayer.isOpaque = false
        spinLayer.backgroundColor = NSColor.clear.cgColor
        spinView.layer?.addSublayer(spinLayer)

        bodyLayer.masksToBounds = false
        bodyLayer.contentsGravity = .resizeAspect
        bodyLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        let bodyMask = CAShapeLayer()
        bodyMask.path = CGPath(ellipseIn: CGRect(origin: .zero, size: orb.size).insetBy(dx: 1, dy: 1), transform: nil)
        bodyLayer.mask = bodyMask
        spinLayer.addSublayer(bodyLayer)
        setBodyImage(Self.bundledImage("orb-body"))

        eyeClipLayer.masksToBounds = true
        eyeClipLayer.backgroundColor = NSColor.clear.cgColor
        spinLayer.addSublayer(eyeClipLayer)

        highlightLayer.contents = Self.cgImage(Self.bundledImage("orb-highlights"))
        highlightLayer.contentsGravity = .resizeAspect
        highlightLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        highlightLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        eyeClipLayer.addSublayer(highlightLayer)

        // Eyes sit on the front of the orb, facing the viewer. No y-axis or
        // perspective flip; spins are 2D (z) only.
        bodyLayer.zPosition = 0
        eyeClipLayer.zPosition = 1
        highlightLayer.zPosition = 1
        for layer in [spinLayer, bodyLayer, eyeClipLayer, highlightLayer] {
            layer.isDoubleSided = true
            var t = layer.transform
            t.m34 = 0
            layer.transform = t
        }

        layoutSpinLayer()
        updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        layoutSpinLayer()
    }

    /// Re-assert geometry AppKit must not own. Call from setup and layout.
    private func layoutSpinLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        spinLayer.bounds = CGRect(x: 0, y: 0, width: orbPointSize, height: orbPointSize)
        spinLayer.position = CGPoint(x: spinView.bounds.midX, y: spinView.bounds.midY)
        bodyLayer.frame = spinLayer.bounds
        if let mask = bodyLayer.mask as? CAShapeLayer {
            mask.path = CGPath(ellipseIn: spinLayer.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        }
        eyeClipLayer.frame = spinLayer.bounds
        eyeClipLayer.cornerRadius = (orbPointSize / 2) - 2
        highlightLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        highlightLayer.bounds = spinLayer.bounds
        highlightLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        // Look position is applied every frame; only seed it when unset.
        if highlightLayer.position == .zero {
            highlightLayer.position = CGPoint(
                x: spinLayer.bounds.midX + eyeRestShift.x,
                y: spinLayer.bounds.midY + eyeRestShift.y
            )
        }
        CATransaction.commit()
    }

    private func setBodyImage(_ image: NSImage?) {
        image?.isTemplate = false
        bodyView.image = image
        bodyLayer.contents = Self.cgImage(image)
        bodyLayer.contentsGravity = .resizeAspect
        bodyLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    private static func bundledImage(_ name: String) -> NSImage? {
        var img = NSImage(named: name)
        if img == nil, let path = Bundle.main.path(forResource: name, ofType: "png") {
            img = NSImage(contentsOfFile: path)
        }
        img?.isTemplate = false
        return img
    }

    private static func cgImage(_ image: NSImage?) -> CGImage? {
        guard let image else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func reloadArtwork() {
        if let custom = ArtworkStore.customBodyImage() {
            custom.isTemplate = false
            setBodyImage(custom)
        } else {
            setBodyImage(Self.bundledImage("orb-body"))
        }
        highlightLayer.contents = Self.cgImage(Self.bundledImage("orb-highlights"))
        highlightLayer.isHidden = (eyeStyle == .ownLook)
        highlightLayer.opacity = (eyeStyle == .ownLook) ? 0 : 1
    }

    func setLifeEnabled(_ enabled: Bool) {
        if enabled, !lifeEnabled {
            lifeEnabled = true
            lastMouse = NSEvent.mouseLocation
            heldMouse = lastMouse
            lastMouseMoved = Date()
            lastTick = Date()
            lastInput = Date()
            startBob()
            startTimer()
            startDisplayLink()
        } else if !enabled, lifeEnabled {
            lifeEnabled = false
            pendingClick?.cancel()
            pendingClick = nil
            lifeTimer?.invalidate()
            lifeTimer = nil
            stopDisplayLink()
            bobView.layer?.removeAnimation(forKey: "bob")
            hopView.layer?.removeAnimation(forKey: "hop")
            perkView.layer?.removeAnimation(forKey: "perk")
            resetMotionLayers()
        }
    }

    deinit {
        stopDisplayLink()
    }

    func noteAppSwitch() {
        guard lifeEnabled else { return }
        bumpInterest(0.22)
        snapUntil = Date().addingTimeInterval(0.35)
        cachedFocusPoint = nil
        cachedWindowCenter = nil
        heldGazePoint = nil
        lastWindowCenterPoll = .distantPast
        lastAXPoll = .distantPast
        promoteDisplayRate()
        if dozing { wake(reason: .activity) }
    }

    private func startTimer() {
        lifeTimer?.invalidate()
        let timer = Timer(timeInterval: logicHz, repeats: true) { [weak self] _ in
            self?.logicTick()
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        lifeTimer = timer
    }

    private func startBob(sleeping: Bool = false) {
        bobSleeping = sleeping
        bobView.layer?.removeAnimation(forKey: "bob")
    }

    private func startDisplayLink() {
        if frameDriver == nil { frameDriver = FrameDriver() }
        frameDriver?.start(on: self) { [weak self] dt in
            self?.displayFrame(dt: dt)
        }
        displayRateMode = 255
        promoteDisplayRate()
    }

    private func stopDisplayLink() {
        frameDriver?.stop()
        displayRateMode = 255
    }

    private func promoteDisplayRate() {
        guard lifeEnabled else { return }
        if displayRateMode != 2 {
            displayRateMode = 2
            frameDriver?.setRate(minimum: 60, maximum: 120, preferred: 120)
        }
    }

    private func resetMotionLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hopView.layer?.setAffineTransform(.identity)
        bobView.layer?.setAffineTransform(.identity)
        perkView.layer?.setAffineTransform(.identity)
        CATransaction.commit()
        hopStartedAt = nil
        perkScale = 1
        perkVel = 0
        perkTarget = 1
        lookVel = .zero
    }

    // MARK: - Tick

    private func logicTick() {
        let now = Date()
        let dt = min(0.2, now.timeIntervalSince(lastTick))
        lastTick = now

        let mouse = NSEvent.mouseLocation
        if hypot(mouse.x - heldMouse.x, mouse.y - heldMouse.y) >= mouseDeadZone {
            heldMouse = mouse
        }
        if hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 2 {
            lastMouse = mouse
            lastMouseMoved = now
            lastInput = now
            if dozing { wake(reason: .mouse) }
        }

        recordAmbientActivity(now: now, dt: dt, mouse: mouse)
        decayOrGrowInterest(dt: dt, now: now, mouse: mouse)
        maybeDozeOrWake(now: now)
        pollWindowsAndClock(now: now)

        if let window, !isDragging {
            let c = NSPoint(x: window.frame.midX, y: window.frame.midY)
            let inside = hypot(mouse.x - c.x, mouse.y - c.y) <= orbRadius
            window.ignoresMouseEvents = !inside
            if inside != hovering {
                hovering = inside
                applyHover(inside)
                if inside {
                    bumpInterest(0.12)
                    if interest > 0.6, now.timeIntervalSince(lastHopAt) > 8 {
                        hop(height: 7)
                    }
                    if dozing { wake(reason: .hover) }
                }
            }
        }

        maybeBlink(now: now)
        maybeScheduledSpin(now: now)
        maybeIdleBusiness(now: now)
    }

    // MARK: - Display-synced motion

    private func displayFrame(dt rawDT: TimeInterval) {
        guard lifeEnabled else { return }
        let dt = CGFloat(min(0.05, max(0, rawDT)))
        if dt <= 0 { return }
        let now = Date()
        let target = lookTarget(now: now, mouse: heldMouse)

        var omega: CGFloat = 12
        if now < dizzyUntil || now < eyeRollUntil {
            omega = 16
        } else if now < snapUntil || hovering {
            omega = 14
        } else if interest > 0.66 {
            omega = 12.5
        } else if interest < 0.28 {
            omega = 10
        } else {
            omega = 11
        }

        Self.springStep(&look.x, &lookVel.x, target: target.x, dt: dt, omega: omega, zeta: 1)
        Self.springStep(&look.y, &lookVel.y, target: target.y, dt: dt, omega: omega, zeta: 1)

        applyLook(now: now)
        applyMotionTransforms(dt: dt, now: now)
        refreshDisplayRate(now: now, target: target)
    }

    /// Implicit Euler, rate-independent. zeta = 1 is critically damped.
    private static func springStep(_ x: inout CGFloat, _ v: inout CGFloat, target: CGFloat, dt: CGFloat, omega: CGFloat, zeta: CGFloat) {
        let c = 2 * zeta * omega
        let k = omega * omega
        let det = 1 + c * dt + k * dt * dt
        let newV = (v - k * dt * (x - target)) / det
        x = x + dt * newV
        v = newV
    }

    private func applyMotionTransforms(dt: CGFloat, now: Date) {
        var hopY: CGFloat = 0
        var hopping = false
        if let start = hopStartedAt {
            let u = now.timeIntervalSince(start) / hopDuration
            if u >= 1 {
                hopStartedAt = nil
            } else {
                hopping = true
                hopY = Self.hopCurve(CGFloat(u), height: hopHeight)
            }
        }

        let period: CGFloat = bobSleeping ? 5.4 : 3.6
        let amp: CGFloat = bobSleeping ? 1.0 : 2.2
        bobPhase += dt * (2 * .pi) / period
        if bobPhase > 2 * .pi { bobPhase -= 2 * .pi }
        let bobY: CGFloat = hopping ? 0 : sin(bobPhase) * amp

        // Slightly underdamped so a hover impulse still gives a little perk bounce.
        Self.springStep(&perkScale, &perkVel, target: perkTarget, dt: dt, omega: 14, zeta: 0.62)

        if dragSpinSettling, !isDragging {
            stepDragSpinSettle(dt: dt)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hopView.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: hopY))
        bobView.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: bobY))
        // Scale about the view center even if AppKit has reset the layer anchor to 0,0.
        let perkMid = CGPoint(x: perkView.bounds.midX, y: perkView.bounds.midY)
        var perkT = CGAffineTransform(translationX: perkMid.x, y: perkMid.y)
        perkT = perkT.scaledBy(x: perkScale, y: perkScale)
        perkT = perkT.translatedBy(x: -perkMid.x, y: -perkMid.y)
        perkView.layer?.setAffineTransform(perkT)
        if isDragging || dragSpinSettling || abs(dragSpinAngle) > 0.0001 {
            spinLayer.transform = CATransform3DMakeRotation(dragSpinAngle, 0, 0, 1)
        }
        CATransaction.commit()
    }

    /// Two upward hops without a downward undershoot that would stack with the bob.
    private static func hopCurve(_ t: CGFloat, height: CGFloat) -> CGFloat {
        if t < 0.55 {
            return height * sin((t / 0.55) * .pi)
        }
        return height * 0.32 * sin(((t - 0.55) / 0.45) * .pi)
    }

    private func refreshDisplayRate(now: Date, target: CGPoint) {
        guard lifeEnabled else { return }
        let settled = hypot(lookVel.x, lookVel.y) < 0.12
            && hypot(look.x - target.x, look.y - target.y) < 0.03
        let hopping = hopStartedAt != nil
        let perking = abs(perkVel) > 0.02 || abs(perkScale - perkTarget) > 0.008
        let special = now < dizzyUntil || now < eyeRollUntil || blinking
        let animating = !settled || hopping || perking || special

        let mode: UInt8
        if dozing && !animating {
            mode = 0
        } else if !animating {
            mode = 1
        } else {
            mode = 2
        }
        guard mode != displayRateMode else { return }
        displayRateMode = mode
        switch mode {
        case 0:
            frameDriver?.setRate(minimum: 8, maximum: 20, preferred: 12)
        case 1:
            frameDriver?.setRate(minimum: 20, maximum: 30, preferred: 30)
        default:
            frameDriver?.setRate(minimum: 60, maximum: 120, preferred: 120)
        }
    }

    // MARK: - Interest

    private func bumpInterest(_ amount: CGFloat) {
        interest = min(1, interest + amount)
    }

    private func recordAmbientActivity(now: Date, dt: TimeInterval, mouse: NSPoint) {
        if Self.secondsSince(.keyDown) < 1.2 {
            bumpInterest(CGFloat(dt) * 0.14)
            lastInput = now
            if dozing { wake(reason: .activity) }
        }
        if let window {
            let c = NSPoint(x: window.frame.midX, y: window.frame.midY)
            let dist = hypot(mouse.x - c.x, mouse.y - c.y)
            if dist < 140, dist > orbRadius {
                bumpInterest(CGFloat(dt) * 0.05)
            }
        }
    }

    private func decayOrGrowInterest(dt: TimeInterval, now: Date, mouse: NSPoint) {
        let recentKey = Self.secondsSince(.keyDown) < 2.5
        let recentMouse = now.timeIntervalSince(lastMouseMoved) < 2.0
        if hovering || recentKey {
            return
        }
        var rate: CGFloat = 0.0035
        if !recentMouse { rate = 0.005 }
        if now.timeIntervalSince(lastInput) > 60 { rate = 0.006 }
        interest = max(0, interest - CGFloat(dt) * rate)
    }

    private var isBusy: Bool {
        Date() < busyUntil || isDragging || blinking
    }

    // MARK: - Look targets

    private func lookTarget(now: Date, mouse: NSPoint) -> CGPoint {
        if now < dizzyUntil {
            let t = now.timeIntervalSince(dizzyStart)
            let decay = CGFloat(max(0, 1 - t / 1.15))
            let angle = CGFloat(t) * 16
            return CGPoint(x: cos(angle) * decay, y: sin(angle) * decay)
        }
        if now < eyeRollUntil {
            let t = now.timeIntervalSince(eyeRollStart)
            let angle = CGFloat(t / 0.7) * .pi * 2
            return CGPoint(x: cos(angle) * 0.85, y: sin(angle) * 0.55)
        }
        if hovering {
            return lookVector(toward: heldMouse)
        }
        if now < clockGlanceUntil {
            return lookVector(toward: clockGlanceTarget)
        }
        if now < wanderUntil {
            return wanderTarget
        }
        if dozing {
            return CGPoint(x: 0.05, y: -0.7)
        }
        // Bored: sometimes ignore focus and wander (handled by wanderUntil).
        // Otherwise follow focus; high interest looks harder (full magnitude).
        return lookVector(toward: committedFocusPoint())
    }

    /// Tiny dead zone so sub-pixel / 1–2 pt jitter does not retarget the eyes.
    /// Genuine jumps (app switch, window move, snap) update immediately.
    private func committedFocusPoint() -> NSPoint {
        let raw = currentFocusPoint()
        if Date() < snapUntil {
            heldGazePoint = raw
            return raw
        }
        if let held = heldGazePoint, hypot(raw.x - held.x, raw.y - held.y) < focusDeadZone {
            return held
        }
        heldGazePoint = raw
        return raw
    }

    private func lookVector(toward point: NSPoint) -> CGPoint {
        guard let window else { return .zero }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let dist = hypot(dx, dy)
        if dist < 10 { return .zero }
        // Reach full look reasonably quickly so a window across the desktop
        // pulls the eyes all the way to the rim.
        let reach: CGFloat = 200
        let mag = min(1, dist / reach)
        return CGPoint(x: dx / dist * mag, y: dy / dist * mag)
    }

    private func currentFocusPoint() -> NSPoint {
        let now = Date()
        if AXIsProcessTrusted() {
            if now.timeIntervalSince(lastAXPoll) > 0.45 || cachedFocusPoint == nil {
                lastAXPoll = now
                cachedFocusPoint = Self.focusedElementCenter()
            }
            if let p = cachedFocusPoint { return p }
        }
        if now.timeIntervalSince(lastWindowCenterPoll) > 0.8 || cachedWindowCenter == nil {
            lastWindowCenterPoll = now
            cachedWindowCenter = frontmostWindowCenter()
        }
        return cachedWindowCenter ?? NSEvent.mouseLocation
    }

    private func applyLook(now: Date = Date()) {
        let t = min(1, hypot(look.x, look.y))
        // Foreshorten as the eyes wrap toward the rim of the sphere.
        let squash = 1.0 - 0.36 * t * t
        let shrink = 1.0 - 0.10 * t
        var sx = (1.0 - 0.30 * look.x * look.x) * squash * shrink * eyeBaseScale
        var sy = (1.0 - 0.30 * look.y * look.y) * squash * shrink * eyeBaseScale
        if dozing {
            sy *= 0.42
            sx *= 0.90
        } else if interest < 0.28, now.timeIntervalSince(lastInput) > 45 {
            // Heading toward sleep: gradually narrow. Stay full-size when just bored.
            let drowse = min(1, CGFloat((now.timeIntervalSince(lastInput) - 45) / 180))
            sy *= 1 - 0.35 * drowse
            sx *= 1 - 0.08 * drowse
        } else if interest > 0.85 {
            sx *= 1.06
            sy *= 1.06
        }
        sy *= blinkLid(now: now)
        // eyeClipLayer is the on-screen container. clipView was left off the
        // hierarchy after the spinLayer fix, so its bounds are zero and would
        // park the highlights at the bottom-left rim (back-of-the-head look).
        let midX = eyeClipLayer.bounds.midX
        let midY = eyeClipLayer.bounds.midY
        let pos = CGPoint(
            x: midX + eyeRestShift.x + look.x * eyeMaxTravel,
            y: midY + eyeRestShift.y + look.y * eyeMaxTravel
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.position = pos
        highlightLayer.transform = CATransform3DMakeScale(sx, sy, 1)
        CATransaction.commit()
    }

    // MARK: - Focus helpers

    private static func focusedElementCenter() -> NSPoint? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID(),
              AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        if size.width < 1, size.height < 1 { return nil }
        let cocoa = cocoaRect(fromQuartz: CGRect(origin: point, size: size))
        return NSPoint(x: cocoa.midX, y: cocoa.midY)
    }

    private func frontmostWindowCenter() -> NSPoint? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }

        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var best: (area: CGFloat, rect: CGRect)?
        for win in raw {
            guard let owner = win[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
            let layer = (win[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer != 0 { continue }
            guard let bounds = win[kCGWindowBounds as String] as? [String: Any],
                  let x = Self.cgf(bounds["X"]),
                  let y = Self.cgf(bounds["Y"]),
                  let w = Self.cgf(bounds["Width"]),
                  let h = Self.cgf(bounds["Height"]) else { continue }
            if w < 80 || h < 80 { continue }
            let area = w * h
            if best == nil || area > best!.area {
                best = (area, CGRect(x: x, y: y, width: w, height: h))
            }
        }
        guard let quartz = best?.rect else { return nil }
        let cocoa = Self.cocoaRect(fromQuartz: quartz)
        let point = NSPoint(x: cocoa.midX, y: cocoa.midY)
        if pid != lastFocusApp || hypot(point.x - lastFocusPoint.x, point.y - lastFocusPoint.y) > 80 {
            lastFocusApp = pid
            lastFocusPoint = point
            snapUntil = Date().addingTimeInterval(0.3)
        }
        return point
    }

    private static func cgf(_ any: Any?) -> CGFloat? {
        if let n = any as? CGFloat { return n }
        if let n = any as? Double { return CGFloat(n) }
        if let n = any as? Float { return CGFloat(n) }
        if let n = any as? Int { return CGFloat(n) }
        if let n = any as? NSNumber { return CGFloat(truncating: n) }
        return nil
    }

    /// CGWindow / AX bounds are Quartz space: origin at the top-left of the primary display, y down.
    private static func cocoaRect(fromQuartz rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func secondsSince(_ type: CGEventType) -> CFTimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
    }

    // MARK: - Windows, clock, doze

    private func pollWindowsAndClock(now: Date) {
        if now.timeIntervalSince(lastWindowPoll) >= 1.2 {
            lastWindowPoll = now
            pollNewWindows(now: now)
        }
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        if comps.minute == 0, let hour = comps.hour, let sec = comps.second, sec < 5, lastClockGlanceHour != hour {
            lastClockGlanceHour = hour
            if let screen = window?.screen ?? NSScreen.main {
                clockGlanceTarget = NSPoint(x: screen.frame.maxX - 40, y: screen.frame.maxY - 14)
                clockGlanceUntil = now.addingTimeInterval(1.8)
            }
        }
    }

    private func pollNewWindows(now: Date) {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let myPid = ProcessInfo.processInfo.processIdentifier
        var current = Set<Int>()
        var newcomers: [CGRect] = []
        for win in raw {
            guard let number = win[kCGWindowNumber as String] as? Int else { continue }
            current.insert(number)
            let layer = (win[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer != 0 { continue }
            if let owner = win[kCGWindowOwnerPID as String] as? pid_t, owner == myPid { continue }
            guard let bounds = win[kCGWindowBounds as String] as? [String: Any],
                  let x = Self.cgf(bounds["X"]),
                  let y = Self.cgf(bounds["Y"]),
                  let w = Self.cgf(bounds["Width"]),
                  let h = Self.cgf(bounds["Height"]) else { continue }
            if w < 200 || h < 140 { continue }
            if windowIDsPrimed, !knownWindowIDs.contains(number) {
                newcomers.append(CGRect(x: x, y: y, width: w, height: h))
            }
        }
        if !windowIDsPrimed {
            knownWindowIDs = current
            windowIDsPrimed = true
            return
        }
        knownWindowIDs = current
        if let fresh = newcomers.max(by: { $0.width * $0.height < $1.width * $1.height }),
           now.timeIntervalSince(lastStartle) > 4 {
            lastStartle = now
            bumpInterest(0.18)
            let cocoa = Self.cocoaRect(fromQuartz: fresh)
            wanderTarget = lookVector(toward: NSPoint(x: cocoa.midX, y: cocoa.midY))
            wanderUntil = now.addingTimeInterval(0.7)
            snapUntil = now.addingTimeInterval(0.25)
            startle()
            if dozing { wake(reason: .activity) }
        }
    }

    private func maybeDozeOrWake(now: Date) {
        let idleFor = now.timeIntervalSince(lastInput)
        let mouseIdle = Self.secondsSince(.mouseMoved)
        let keyIdle = Self.secondsSince(.keyDown)
        let inputIdle = min(idleFor, mouseIdle, keyIdle)
        if !dozing, inputIdle > 300, interest < 0.4 {
            startDoze()
        }
    }

    private enum WakeReason { case mouse, hover, activity, poke }

    private func startDoze() {
        dozing = true
        wanderUntil = .distantPast
        startBob(sleeping: true)
    }

    private func wake(reason: WakeReason) {
        guard dozing else { return }
        dozing = false
        startBob(sleeping: false)
        bumpInterest(reason == .poke ? 0.45 : 0.28)
        lastInput = Date()
        promoteDisplayRate()
        if reason != .hover {
            hop(height: 6)
        }
    }

    // MARK: - Blink, spin, business

    private func maybeBlink(now: Date) {
        guard now >= nextBlink, !dozing, !isBusy else { return }
        let gap: TimeInterval
        if interest > 0.66 {
            gap = lively ? TimeInterval.random(in: 2.0...4.5) : TimeInterval.random(in: 2.8...5.5)
        } else if interest < 0.28 {
            gap = TimeInterval.random(in: 4.5...9.0)
        } else {
            gap = lively ? TimeInterval.random(in: 2.4...5.5) : TimeInterval.random(in: 3.2...7.5)
        }
        nextBlink = now.addingTimeInterval(gap)
        blink(double: interest < 0.35 ? Bool.random() : (Int.random(in: 0...6) == 0))
    }

    private func blink(double: Bool) {
        blinking = true
        blinkDouble = double
        blinkStartedAt = Date()
        highlightLayer.removeAnimation(forKey: "blink")
        promoteDisplayRate()
    }

    private func blinkLid(now: Date) -> CGFloat {
        guard let start = blinkStartedAt else { return 1 }
        let t = now.timeIntervalSince(start)
        func lid(_ u: TimeInterval, duration: TimeInterval) -> CGFloat {
            if u < 0 || u > duration { return 1 }
            let p = CGFloat(u / duration)
            if p < 0.45 {
                let w = p / 0.45
                let s = w * w * (3 - 2 * w)
                return 1 + (0.08 - 1) * s
            }
            let w = (p - 0.45) / 0.55
            let s = w * w * (3 - 2 * w)
            return 0.08 + (1 - 0.08) * s
        }
        if blinkDouble {
            if t > 0.28 {
                blinkStartedAt = nil
                blinking = false
                return 1
            }
            return t >= 0.16 ? lid(t - 0.16, duration: 0.10) : lid(t, duration: 0.11)
        }
        if t > 0.13 {
            blinkStartedAt = nil
            blinking = false
            return 1
        }
        return lid(t, duration: 0.11)
    }

    private func maybeScheduledSpin(now: Date) {
        guard now >= nextPlayfulSpin, !dozing, !isBusy, !hovering else { return }
        scheduleNextPlayfulSpin()
        if interest < 0.2 { return }
        playfulSpin(double: Bool.random() && Bool.random())
    }

    private func scheduleNextPlayfulSpin() {
        let gap = lively ? TimeInterval.random(in: 50...150) : TimeInterval.random(in: 60...180)
        nextPlayfulSpin = Date().addingTimeInterval(gap)
    }

    private func maybeIdleBusiness(now: Date) {
        guard now >= nextBusiness, !dozing, !hovering, !isBusy, now >= clockGlanceUntil else { return }
        let gap: TimeInterval
        if interest > 0.66 {
            gap = TimeInterval.random(in: 8...16)
            nextBusiness = now.addingTimeInterval(gap)
            // High interest: mostly stay on the action; rare tiny aside glance.
            if Int.random(in: 0...3) == 0 {
                wanderTarget = CGPoint(x: look.x + CGFloat.random(in: -0.25...0.25), y: look.y + CGFloat.random(in: -0.2...0.2))
                let d = max(0.001, hypot(wanderTarget.x, wanderTarget.y))
                if d > 1 { wanderTarget = CGPoint(x: wanderTarget.x / d, y: wanderTarget.y / d) }
                wanderUntil = now.addingTimeInterval(0.5)
            }
            return
        }
        if interest < 0.28 {
            gap = TimeInterval.random(in: 5...10)
            nextBusiness = now.addingTimeInterval(gap)
            boredBit(now: now)
            return
        }
        gap = TimeInterval.random(in: 7...14)
        nextBusiness = now.addingTimeInterval(gap)
        mediumBit(now: now)
    }

    private func mediumBit(now: Date) {
        let roll = Int.random(in: 0...5)
        if roll == 0 {
            blink(double: true)
        } else if roll == 1 {
            // Slow curious scan: look one way, then sweep to the other.
            let side: CGFloat = Bool.random() ? 1 : -1
            wanderTarget = CGPoint(x: side * 0.85, y: CGFloat.random(in: -0.2...0.35))
            wanderUntil = now.addingTimeInterval(1.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in
                guard let self else { return }
                self.wanderTarget = CGPoint(x: -side * 0.8, y: CGFloat.random(in: -0.25...0.3))
                self.wanderUntil = Date().addingTimeInterval(1.3)
            }
        } else if roll == 2 {
            wanderTarget = CGPoint(x: CGFloat.random(in: -0.9...0.9), y: CGFloat.random(in: -0.7...0.7))
            wanderUntil = now.addingTimeInterval(TimeInterval.random(in: 1.4...2.4))
        }
        // else: just keep following focus
    }

    private func boredBit(now: Date) {
        let roll = Int.random(in: 0...6)
        switch roll {
        case 0:
            sigh()
        case 1:
            eyeRollStart = now
            eyeRollUntil = now.addingTimeInterval(0.7)
            busyUntil = eyeRollUntil
        case 2, 3:
            wanderTarget = CGPoint(x: CGFloat.random(in: -1...1), y: CGFloat.random(in: -0.85...0.6))
            let d = max(0.001, hypot(wanderTarget.x, wanderTarget.y))
            wanderTarget = CGPoint(x: wanderTarget.x / d, y: wanderTarget.y / d)
            wanderUntil = now.addingTimeInterval(TimeInterval.random(in: 2.0...3.5))
        case 4:
            fidget(now: now)
        default:
            if now.timeIntervalSince(lastHopAt) > 20 {
                playfulSpin(double: false, duration: 0.55)
            }
        }
    }

    private func fidget(now: Date) {
        wanderTarget = CGPoint(x: look.x + CGFloat.random(in: -0.3...0.3), y: look.y + CGFloat.random(in: -0.25...0.25))
        wanderUntil = now.addingTimeInterval(0.28)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.wanderTarget = CGPoint(x: CGFloat.random(in: -0.5...0.5), y: CGFloat.random(in: -0.4...0.4))
            self.wanderUntil = Date().addingTimeInterval(0.3)
        }
    }

    // MARK: - Reactions

    private func hop(height: CGFloat) {
        lastHopAt = Date()
        hopStartedAt = Date()
        hopHeight = height
        hopView.layer?.removeAnimation(forKey: "hop")
        promoteDisplayRate()
    }

    private func sigh() {
        busyUntil = Date().addingTimeInterval(0.95)
        let squish = CAKeyframeAnimation(keyPath: "transform.scale.y")
        squish.values = [1, 0.88, 1]
        squish.keyTimes = [0, 0.55, 1]
        squish.duration = 0.9
        squish.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        spinLayer.add(squish, forKey: "sigh")
    }

    private func startle() {
        hop(height: 5)
        blink(double: false)
    }

    private func playfulSpin(double: Bool, duration: TimeInterval? = nil) {
        guard Date() >= busyUntil else { return }
        guard !isDragging, !dragSpinSettling else { return }
        let turns: CGFloat = double ? 2 : 1
        let dur = duration ?? (double ? 1.05 : 0.8)
        busyUntil = Date().addingTimeInterval(dur + 0.05)
        spinLayer.removeAnimation(forKey: "playfulSpin")
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.spinLayer.removeAnimation(forKey: "playfulSpin")
            self?.spinLayer.transform = CATransform3DIdentity
        }
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = CGFloat.pi * 2 * turns
        anim.duration = dur
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        spinLayer.add(anim, forKey: "playfulSpin")
        CATransaction.commit()
    }

    private func delightedPoke() {
        bumpInterest(0.4)
        if dozing { wake(reason: .poke) }
        hop(height: 12)
        blink(double: true)
        snapUntil = Date().addingTimeInterval(0.4)
    }

    private func becomeDizzy(duration: TimeInterval = 1.15) {
        let dur = min(2.2, max(0.9, duration))
        dizzyStart = Date()
        dizzyUntil = Date().addingTimeInterval(dur)
        bumpInterest(0.15)
        promoteDisplayRate()
    }

    /// Map a linear drag velocity (pt/s) onto a twirl rate, as if the orb were rolling.
    private func stepDragSpin(velocityX vx: CGFloat, velocityY vy: CGFloat, dt: TimeInterval) {
        let dt = CGFloat(max(1.0 / 240.0, min(dt, 1.0 / 20.0)))
        let radius = max(36, orbRadius)
        let targetOmega = -(vx - vy) / radius
        let follow = 1 - exp(-dt * 16)
        dragSpinVel += (targetOmega - dragSpinVel) * follow
        let cap: CGFloat = 28
        dragSpinVel = max(-cap, min(cap, dragSpinVel))
        dragSpinAngle += dragSpinVel * dt
        applyDragSpinNow()
    }

    /// After a drop: coast with friction, then settle face-up.
    private func stepDragSpinSettle(dt: CGFloat) {
        let dt = max(1.0 / 240.0, min(dt, 1.0 / 20.0))
        var wrapped = atan2(sin(dragSpinAngle), cos(dragSpinAngle))
        // Stronger upright pull as it slows, so a fast fling can still twirl a few times.
        let speed = abs(dragSpinVel)
        let pull = speed < 6 ? 18.0 : 4.0
        let damp = speed < 6 ? 6.0 : 2.2
        dragSpinVel += (-wrapped * pull - dragSpinVel * damp) * dt
        dragSpinVel *= exp(-1.8 * dt)
        dragSpinAngle += dragSpinVel * dt
        wrapped = atan2(sin(dragSpinAngle), cos(dragSpinAngle))
        if abs(dragSpinVel) < 0.18, abs(wrapped) < 0.03 {
            dragSpinAngle = 0
            dragSpinVel = 0
            dragSpinSettling = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spinLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            return
        }
        applyDragSpinNow()
    }

    private func applyDragSpinNow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinLayer.transform = CATransform3DMakeRotation(dragSpinAngle, 0, 0, 1)
        CATransaction.commit()
    }

    private func beginDragSpin() {
        spinLayer.removeAnimation(forKey: "playfulSpin")
        spinLayer.removeAnimation(forKey: "sigh")
        dragSpinSettling = false
        if abs(dragSpinAngle) < 0.01 {
            dragSpinAngle = 0
            dragSpinVel = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spinLayer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    private func finishDragSpin(traveled: CGFloat) {
        dragSpinSettling = true
        promoteDisplayRate()
        let fast = abs(dragSpinVel) > 5.5 || traveled > 16
        if fast {
            let extra = TimeInterval(min(1.0, abs(dragSpinVel) / 28))
            becomeDizzy(duration: 1.05 + extra)
        }
    }

    private func applyHover(_ on: Bool) {
        perkView.layer?.removeAnimation(forKey: "perk")
        perkTarget = on ? 1.07 : 1.0
        if on {
            perkVel += 2.8
        }
        promoteDisplayRate()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        isDragging = true
        window.ignoresMouseEvents = false
        // When not pinned, a click or drag brings the orb above other normal windows.
        if !stayOnTop {
            window.level = .normal
            window.orderFrontRegardless()
        }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        defer { isDragging = false }

        beginDragSpin()
        if dozing { wake(reason: .poke) }

        var dragged = false
        var lastMouse = startMouse
        var lastTime = CACurrentMediaTime()
        while true {
            let ev = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 1.0 / 120.0),
                inMode: .eventTracking,
                dequeue: true
            )
            let now = NSEvent.mouseLocation
            let nowTime = CACurrentMediaTime()
            let dt = nowTime - lastTime
            let vx = (now.x - lastMouse.x) / CGFloat(max(dt, 1.0 / 240.0))
            let vy = (now.y - lastMouse.y) / CGFloat(max(dt, 1.0 / 240.0))
            stepDragSpin(velocityX: vx, velocityY: vy, dt: dt)
            lastMouse = now
            lastTime = nowTime

            let dx = now.x - startMouse.x
            let dy = now.y - startMouse.y
            let lifted = ev?.type == NSEvent.EventType.leftMouseUp || (ev == nil && (NSEvent.pressedMouseButtons & 1) == 0)
            if lifted {
                if hypot(dx, dy) < 4 {
                    dragSpinAngle = 0
                    dragSpinVel = 0
                    dragSpinSettling = false
                    applyDragSpinNow()
                    handleClick(at: now)
                } else {
                    dragged = true
                    window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
                    finishDragSpin(traveled: hypot(dx, dy))
                    onAction?(.moved)
                }
                break
            }
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }
        if dragged { lastInput = Date() }
    }

    /// Single click opens chat after a short delay; a second click in that
    /// window is a poke (delighted reaction) and cancels the open.
    private func handleClick(at point: NSPoint) {
        lastInput = Date()
        bumpInterest(0.18)
        if dozing { wake(reason: .poke) }
        if let last = lastClickAt, Date().timeIntervalSince(last) < 0.32 {
            lastClickAt = nil
            pendingClick?.cancel()
            pendingClick = nil
            delightedPoke()
            return
        }
        lastClickAt = Date()
        pendingClick?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingClick = nil
            self?.onAction?(.clicked)
        }
        pendingClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
    }

    override func rightMouseDown(with event: NSEvent) {
        pendingClick?.cancel()
        pendingClick = nil
        let menu = NSMenu()
        menu.autoenablesItems = false

        let prefs = menu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self

        let stay = menu.addItem(withTitle: "Stay on Top", action: #selector(toggleStayOnTop), keyEquivalent: "")
        stay.target = self
        stay.state = stayOnTop ? .on : .off

        menu.addItem(.separator())

        let hide = menu.addItem(withTitle: "Hide for 1 hour", action: #selector(hideForHour), keyEquivalent: "")
        hide.target = self

        menu.addItem(.separator())

        let about = menu.addItem(withTitle: "About Desk Bot", action: #selector(openAbout), keyEquivalent: "")
        about.target = self

        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "Quit Desk Bot", action: #selector(quitBuddy), keyEquivalent: "")
        quit.target = self

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = orbRadius
        return hypot(point.x - center.x, point.y - center.y) <= radius ? self : nil
    }

    @objc private func openPreferences() {
        onAction?(.openPreferences)
    }

    @objc private func openAbout() {
        onAction?(.openAbout)
    }

    @objc private func toggleStayOnTop() {
        stayOnTop.toggle()
        onAction?(.stayOnTopChanged)
    }

    @objc private func hideForHour() {
        pendingClick?.cancel()
        pendingClick = nil
        onAction?(.hideForHour)
    }

    @objc private func quitBuddy() {
        pendingClick?.cancel()
        pendingClick = nil
        onAction?(.quit)
    }
}

// MARK: - Display-synced clock

/// CADisplayLink on macOS 14+ (ProMotion up to 120 Hz); CVDisplayLink as a fallback.
private final class FrameDriver: NSObject {
    private var caLink: NSObject?
    private var cvLink: CVDisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var lastEmit: CFTimeInterval = 0
    private var minInterval: CFTimeInterval = 1.0 / 120.0
    private var onFrame: ((TimeInterval) -> Void)?

    func start(on view: NSView, handler: @escaping (TimeInterval) -> Void) {
        stop()
        onFrame = handler
        lastTime = 0
        lastEmit = 0
        if #available(macOS 14.0, *) {
            let link = view.displayLink(target: self, selector: #selector(caTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            caLink = link
        } else {
            startCV(for: view)
        }
    }

    func stop() {
        if #available(macOS 14.0, *) {
            (caLink as? CADisplayLink)?.invalidate()
        }
        caLink = nil
        if let cvLink {
            CVDisplayLinkStop(cvLink)
        }
        cvLink = nil
        lastTime = 0
        lastEmit = 0
        onFrame = nil
    }

    func setRate(minimum: Float, maximum: Float, preferred: Float) {
        if #available(macOS 14.0, *) {
            (caLink as? CADisplayLink)?.preferredFrameRateRange = CAFrameRateRange(
                minimum: minimum,
                maximum: maximum,
                preferred: preferred
            )
        }
        minInterval = 1.0 / CFTimeInterval(max(preferred, 1))
    }

    @available(macOS 14.0, *)
    @objc private func caTick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastTime == 0 ? link.duration : (now - lastTime)
        lastTime = now
        onFrame?(min(0.05, max(0, dt)))
    }

    private func startCV(for view: NSView) {
        var link: CVDisplayLink?
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screenID = (view.window?.screen?.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
        if screenID != 0 {
            CVDisplayLinkCreateWithCGDisplay(CGDirectDisplayID(screenID), &link)
        } else {
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
        }
        guard let link else { return }
        cvLink = link
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, context) -> CVReturn in
            guard let context else { return kCVReturnSuccess }
            let driver = Unmanaged<FrameDriver>.fromOpaque(context).takeUnretainedValue()
            let now = CACurrentMediaTime()
            DispatchQueue.main.async {
                driver.cvTick(now: now)
            }
            return kCVReturnSuccess
        }, ptr)
        CVDisplayLinkStart(link)
    }

    private func cvTick(now: CFTimeInterval) {
        if lastTime != 0, now - lastEmit < minInterval * 0.85 { return }
        let dt = lastTime == 0 ? (1.0 / 60.0) : (now - lastTime)
        lastTime = now
        lastEmit = now
        onFrame?(min(0.05, max(0, dt)))
    }
}
