import AppKit
import AVFoundation
import CoreGraphics
import ServiceManagement
import Sparkle

/// App lifecycle + idle-driven screensaver window controller. Also owns the
/// camera session, the status item, settings window, and hotkeys.
///
/// The camera is the reason this app exists in this shape. As a .saver it
/// could not hold a TCC grant, so a second process — ASCIISaverCameraAgent —
/// owned the capture session and posted frames into shared memory, driven by
/// cross-process start/stop notifications. All of that is now this class:
/// one capture session, started when the saver goes up and stopped when it
/// comes down, fanned out to one FrameSource per display.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - State

    private var idleTimer: Timer?
    private var windows: [ScreensaverWindow] = []

    /// Named once rather than spelled at each use — it is matched against a
    /// notification name as well as observed, and two spellings of the same
    /// string is how that kind of check silently stops matching.
    static let screenIsUnlockedNotification = "com.apple.screenIsUnlocked"

    /// Whether waking should LOCK the screen rather than merely dismiss the saver.
    ///
    /// Pure, because it decides a security behaviour and a security behaviour
    /// should be checkable without a machine to put to sleep. All four must hold:
    /// it is a wake and not an unlock; the user asked for lock-on-dismiss; the
    /// saver is actually up, so waking a Mac we were not covering never locks it;
    /// and the screen is not already locked.
    static func shouldLockOnWake(notification: String,
                                 lockOnDismiss: Bool,
                                 saverIsUp: Bool,
                                 screenAlreadyLocked: Bool) -> Bool {
        notification != screenIsUnlockedNotification
            && lockOnDismiss
            && saverIsUp
            && !screenAlreadyLocked
    }
    private var screenChangeObserver: NSObjectProtocol?
    /// Signature of the display layout the live windows were built for.
    /// `nil` when no windows exist. See `handleScreenChange`.
    private var builtForLayout: String?
    private var defaultsObserver: NSObjectProtocol?
    /// Earliest moment the idle-tick may dismiss after an activation.
    /// Activating via hotkey or menu is itself recent user input, so the next
    /// idle reading would be ~0 and we would dismiss the saver we just opened.
    private var dismissAllowedAfter: Date = .distantPast
    /// Earliest moment the idle-tick may ACTIVATE. Pushed forward on wake and
    /// unlock — system idle keeps accumulating during sleep, so without this
    /// the saver fires the instant you log back in.
    private var activationAllowedAfter: Date = .distantPast
    /// Wake, unlock AND sleep observers — everything the saver has to react to when the machine's
    /// visibility changes under it.
    private var powerObservers: [NSObjectProtocol] = []

    private var statusItem: StatusItem?
    private var statusItemVisibilityObserver: NSObjectProtocol?
    private var hotkeyManager = JorvikHotkeyManager(signature: JorvikHotkeyManager.asciiSaverSignature)
    private var settingsWindow: SettingsWindow?

    // MARK: - Camera

    private let capture = CameraCaptureService()
    private var isCapturing = false
    /// Mirrors the agent's behaviour: the person-segmentation mask is only
    /// produced for the silhouette filter, and toggling it needs the session
    /// restarted because it changes the shape of every delivered frame.
    private var silhouetteEnabled = false

    /// Capture geometry, carried over verbatim from the agent. The renderer
    /// downsamples to a character grid regardless, so a larger frame would
    /// cost battery for no visible gain.
    private static let captureConfig = CameraCaptureService.Config(
        targetWidth: 320, targetHeight: 180, fps: 15)

    // Sparkle update controller — created lazily so initial-launch
    // performance isn't affected. New to ASCII Saver: as a .saver it had no
    // update mechanism at all.
    let userDriverDelegate = ASCIISaverUserDriverDelegate()
    lazy var sparkleUpdater = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: userDriverDelegate
    )

    // MARK: - Defaults keys + accessors

    private let defaultIdleMinutes: Int = 5
    private let activateHotkeyKey   = "activateHotkey"
    private let screenshotHotkeyKey = "screenshotHotkey"

    private var idleThresholdSeconds: Double {
        let m = UserDefaults.standard.integer(forKey: "idleMinutes")
        return Double(m > 0 ? m : defaultIdleMinutes) * 60
    }
    private var lockOnDismiss: Bool {
        UserDefaults.standard.bool(forKey: "lockOnDismiss")
    }
    private var silhouetteSelected: Bool {
        UserDefaults.standard.integer(forKey: "colourFilter") == 4
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything reads a setting: pull the user's old values across
        // from the .saver's com.jorviksoftware.ASCIISaver domain.
        Migration.runIfNeeded()

        // Seed the registration domain so `integer(forKey:)` and friends
        // return the intended default when the user has never touched a
        // control. `@AppStorage`'s declared default is UI-only — it writes
        // nothing until changed — so without this an unset `fontSize` reads
        // as 0 and the grid tries to build with a zero-point font.
        UserDefaults.standard.register(defaults: [
            "idleMinutes":         5,
            "colourFilter":        0,
            "invertColours":       false,
            "fontSize":            9.0,
            "targetFPS":           24.0,
            "rotation":            0,
            "mirrorX":             true,
            "mirrorY":             false,
            "scanlinesEnabled":    true,
            "persistenceEnabled":  false,
            "glitchEnabled":       false,
            "interferenceEnabled": false,
        ])

        asLog("applicationDidFinishLaunching — idle threshold \(Int(idleThresholdSeconds))s")

        silhouetteEnabled = silhouetteSelected
        capture.silhouetteEnabled = silhouetteEnabled

        registerAtLoginIfNeeded()
        _ = sparkleUpdater          // touch the lazy property to start checks
        createStatusItem()
        statusItemVisibilityObserver = NotificationCenter.default.addObserver(
            forName: JorvikStatusItemVisibility.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyStatusItemVisibility()
        }
        registerStoredHotkeys()
        startIdlePolling()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyLiveSettings()
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.handleScreenChange()
        }
        observeWakeAndUnlock()
    }

    /// Relaunching from /Applications is the user's only way back to a hidden
    /// menu-bar icon, so restore visibility here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        JorvikStatusItemVisibility.handleReopen()
        return true
    }

    /// After waking or unlocking, suppress activation for 30s. System idle
    /// keeps counting through sleep and lock, so without this the user fights
    /// the saver on every wake.
    private func observeWakeAndUnlock() {
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()

        // Named in the log, because three different notifications share this
        // closure and one message for three causes is what turned a four-second
        // race into a fortnight of log-reading on the sibling saver.
        let onWake: (Notification) -> Void = { [weak self] note in
            guard let self = self else { return }
            self.activationAllowedAfter = Date().addingTimeInterval(30)
            asLog("wake/unlock event (\(note.name.rawValue)) — activation suppressed for 30s")

            // The three notifications do NOT mean the same thing. An unlock
            // means the user has just authenticated. A wake means the machine
            // came back with the saver still up — and if lock-on-dismiss is on,
            // the screen must not be handed back unlocked. macOS usually has it
            // covered, but only because the screen-lock delay happens to be
            // immediate, which is a System Settings value this app does not own.
            let mustLock = Self.shouldLockOnWake(
                notification: note.name.rawValue,
                lockOnDismiss: self.lockOnDismiss,
                saverIsUp: !self.windows.isEmpty,
                screenAlreadyLocked: LockScreen.screenIsLocked)
            if mustLock {
                asLog("woke with the saver up and the screen UNLOCKED — locking, not just dismissing")
            }
            self.dismissWindows(triggerLock: mustLock)
        }

        powerObservers.append(ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onWake))
        powerObservers.append(ws.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: onWake))
        powerObservers.append(dn.addObserver(
            forName: Notification.Name(Self.screenIsUnlockedNotification),
            object: nil, queue: .main, using: onWake))

        // ── displays asleep ──────────────────────────────────────────────
        // The lock path already reasons about this: nobody can see the frames, and leaving the camera
        // live behind a lock screen would be indefensible. Displays going into standby is exactly the
        // same situation and had no handler at all — the saver stayed up, the render kept drawing to
        // nothing, and the camera stayed on with the screens dark. That is the worse half: a camera
        // running while the machine looks switched off.
        //
        // `willSleep` covers the whole machine going down. AVFoundation would stop the session itself
        // there, but stopping first means the app's own state agrees with reality rather than finding
        // out on wake.
        let onScreensSleep: (Notification) -> Void = { [weak self] _ in
            guard let self = self, !self.windows.isEmpty else { return }
            asLog("screens slept — pausing render and stopping capture")
            self.pauseAllWindows()
            self.stopCapture()
        }
        powerObservers.append(ws.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: onScreensSleep))
        powerObservers.append(ws.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: onScreensSleep))
    }

    func applicationWillTerminate(_ notification: Notification) {
        idleTimer?.invalidate()
        if let obs = screenChangeObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = defaultsObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = statusItemVisibilityObserver { NotificationCenter.default.removeObserver(obs) }
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()
        for obs in powerObservers {
            ws.removeObserver(obs)
            dn.removeObserver(obs)
        }
        powerObservers.removeAll()
        cleanupLockObserver()
        dismissWindows(triggerLock: false)
        stopCapture()
        asLog("applicationWillTerminate")
    }

    // MARK: - Login auto-launch

    /// Register for launch-at-login on the very first run only. First-launching
    /// the app is the consent gesture; every subsequent launch leaves the
    /// system state alone, so disabling it in System Settings sticks.
    private func registerAtLoginIfNeeded() {
        let firstRunKey = "didAttemptInitialLoginRegistration"
        let alreadyAttempted = UserDefaults.standard.bool(forKey: firstRunKey)
        let service = SMAppService.mainApp
        guard !alreadyAttempted else {
            asLog("login item: status=\(service.status.rawValue), respecting user choice")
            return
        }
        UserDefaults.standard.set(true, forKey: firstRunKey)
        guard service.status == .notRegistered || service.status == .notFound else {
            asLog("login item: first run, status already \(service.status.rawValue) — no action")
            return
        }
        do {
            try service.register()
            asLog("login item: first-run registration done")
        } catch {
            asLog("login item: first-run registration failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Camera session

    /// Start capture and fan every frame out to each window's FrameSource.
    ///
    /// The camera runs only while the saver is up. That is a deliberate
    /// privacy and battery choice, and it matches what the agent did — it sat
    /// idle until the saver posted a start notification.
    private func startCapture() {
        guard !isCapturing else { return }
        silhouetteEnabled = silhouetteSelected
        capture.silhouetteEnabled = silhouetteEnabled
        do {
            try capture.start(config: Self.captureConfig) { [weak self] frame in
                // Delivered on the capture queue. FrameSource copies under a
                // lock, so handing the same frame to several windows is safe.
                guard let self = self else { return }
                for source in self.frameSinks {
                    source.submit(frame)
                }
            }
            isCapturing = true
            asLog("capture started (silhouette=\(silhouetteEnabled))")
        } catch {
            asLog("capture failed to start — \(error.localizedDescription)")
        }
    }

    private func stopCapture() {
        guard isCapturing else { return }
        capture.stop()
        capture.needsWriterOpen = true
        isCapturing = false
        asLog("capture stopped")
    }

    /// Snapshot of the frame sinks, read on the capture queue. Captured once
    /// per frame rather than reaching back into `windows` from a background
    /// queue, which would be a data race against the main thread.
    private var frameSinks: [FrameSource] = []

    private func refreshFrameSinks() {
        frameSinks = windows.map { $0.frameSource }
    }

    // MARK: - Hotkeys

    private func registerStoredHotkeys() {
        hotkeyManager.register(HotkeyStore.read(activateHotkeyKey), slot: .activate) { [weak self] in
            self?.activateNowFromHotkey()
        }
        hotkeyManager.register(HotkeyStore.read(screenshotHotkeyKey), slot: .screenshot) { [weak self] in
            self?.captureScreenshot()
        }
    }

    private func activateHotkeyChanged(_ cfg: HotkeyConfig) {
        hotkeyManager.register(cfg, slot: .activate) { [weak self] in
            self?.activateNowFromHotkey()
        }
    }
    private func screenshotHotkeyChanged(_ cfg: HotkeyConfig) {
        hotkeyManager.register(cfg, slot: .screenshot) { [weak self] in
            self?.captureScreenshot()
        }
    }

    // MARK: - Idle polling

    private func startIdlePolling() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Set while activation is being held back by a locked screen, so the
    /// reason is logged once per lock rather than on every tick.
    private var activationHeldByLock = false

    private func tick() {
        let idle = systemIdleSeconds()
        if windows.isEmpty {
            if idle >= idleThresholdSeconds && Date() >= activationAllowedAfter {
                // Never start behind a lock screen. Nothing would be visible —
                // loginwindow sits above the saver level — and starting anyway
                // means turning the CAMERA on while the machine looks shut.
                //
                // There was no guard here at all. Lock the Mac with the saver
                // not showing, walk away, and the idle threshold arrives like
                // any other: the saver activated and capture began, behind the
                // lock screen, until someone came back. The README and the
                // product page both promise there is no path by which frames
                // are captured behind a lock screen. There was one, and this
                // is it.
                //
                // Demonstrated in the sibling saver's log, which shares this
                // structure: an idle-driven activation began 15 minutes into a
                // locked span on 2026-07-07, 15 minutes being its threshold.
                if LockScreen.screenIsLocked {
                    if !activationHeldByLock {
                        asLog("idle threshold reached but the screen is locked — not activating")
                        activationHeldByLock = true
                    }
                    return
                }
                activationHeldByLock = false
                asLog("idle=\(Int(idle))s ≥ threshold — activating")
                showWindows()
            }
        } else if idle < 1.0 && Date() >= dismissAllowedAfter {
            asLog("system idle dropped — dismissing")
            dismissWindows(triggerLock: lockOnDismiss)
        }
    }

    private func systemIdleSeconds() -> Double {
        let anyEvent = CGEventType(rawValue: ~UInt32(0)) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    // MARK: - Window management

    private func showWindows() {
        // Suppress idle-driven auto-dismiss for 2 seconds. The keypress that
        // triggered a hotkey activation also resets system idle to 0, and the
        // next tick would otherwise close the saver immediately.
        dismissAllowedAfter = Date().addingTimeInterval(2.0)
        for screen in NSScreen.screens {
            let win = ScreensaverWindow(screen: screen) { [weak self] in
                self?.dismissWindows(triggerLock: self?.lockOnDismiss ?? false)
            }
            windows.append(win)
            win.activate()
        }
        refreshFrameSinks()
        startCapture()
        builtForLayout = Self.screenLayoutSignature()
        asLog("showed \(windows.count) screensaver window(s) for layout \(builtForLayout ?? "?")")
    }

    /// True between the first `dismissWindows(triggerLock: true)` and the
    /// eventual teardown. Even though each window removes its own monitor on
    /// first fire, the cursor can cross a display boundary and trip two
    /// windows almost simultaneously — without this we would lock twice.
    private var lockDismissInProgress = false

    private func dismissWindows(triggerLock: Bool) {
        guard !windows.isEmpty else { return }
        if triggerLock {
            guard !lockDismissInProgress else {
                asLog("dismiss with lock — already in progress, ignoring re-entry")
                return
            }
            lockDismissInProgress = true
            // Don't tear down on lock. Tearing down as the lock animation
            // completes flashes a frame of desktop between the saver going
            // and loginwindow covering the screen. Instead: lock, pause the
            // render loop when the lock confirms, and let the unlock observer
            // tear down. The lock screen sits above .screenSaver level, so it
            // provably covers us the moment it is up.
            asLog("dismiss with lock — pausing on screenIsLocked, teardown deferred to unlock")
            observeLockThenPause()
            LockScreen.lock()
        } else {
            tearDownWindows()
        }
    }

    private var lockObserver: NSObjectProtocol?
    private func observeLockThenPause() {
        // Nothing to wait for if the screen is already locked. macOS locks the
        // session itself when the display sleeps, so a saver dismissed after
        // that is dismissed onto an already-locked session: the lock call
        // succeeds at doing nothing, and no transition means no notification
        // will ever arrive. Waiting four seconds for it and then declaring
        // failure is what the log did for months.
        //
        // The camera still has to stop. That is the whole reason the lock path
        // reasons about this at all — frames nobody can see, captured behind a
        // lock screen.
        if LockScreen.screenIsLocked {
            asLog("screen already locked before the request — pausing, no handshake needed")
            pauseAllWindows()
            stopCapture()
            return
        }
        let center = DistributedNotificationCenter.default()
        if let prev = lockObserver { center.removeObserver(prev); lockObserver = nil }

        lockObserver = center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            asLog("screenIsLocked received — pausing render, windows stay until unlock")
            self.cleanupLockObserver()
            self.pauseAllWindows()
            // Nobody can see the frames under loginwindow, and leaving the
            // camera live behind a lock screen would be indefensible.
            self.stopCapture()
        }
        // Safety net: if no lock notification arrives within 4 seconds the
        // saver would otherwise stay up forever with no lock UI over it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self = self, self.lockObserver != nil else { return }
            self.cleanupLockObserver()
            // Ask, do not assume. The old line here read "lock likely failed",
            // which the app had no way of knowing: all it had observed was a
            // notification that did not arrive. Those are different facts.
            if LockScreen.screenIsLocked {
                asLog("no screenIsLocked in 4s, but the screen IS locked — pausing")
                self.pauseAllWindows()
                self.stopCapture()
            } else {
                asLog("no screenIsLocked in 4s and the screen is NOT locked — tearing down")
                self.tearDownWindows()
            }
        }
    }

    private func pauseAllWindows() {
        for win in windows { win.pauseAnimation() }
    }

    private func cleanupLockObserver() {
        if let obs = lockObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            lockObserver = nil
        }
    }

    private func tearDownWindows() {
        // A teardown ends the dismiss this handshake belonged to, so the
        // observer has nothing left to hear. Leaving it armed let a wake
        // arriving mid-handshake orphan it rather than cancel it.
        cleanupLockObserver()
        stopCapture()
        for win in windows { win.deactivate() }
        windows.removeAll()
        refreshFrameSinks()
        lockDismissInProgress = false
        builtForLayout = nil
        asLog("dismissed screensaver windows")
    }

    /// Fingerprint of the physical display layout — the only thing a
    /// screensaver window is actually built from.
    ///
    /// Deliberately excludes `visibleFrame`. `visibleFrame` shrinks and
    /// grows as the menu bar and Dock come and go, and a fullscreen window
    /// at `.screenSaver` level covers the menu bar — so a signature that
    /// included it would change as a *result* of showing our own window.
    ///
    /// Sorted by display ID so a reordering of `NSScreen.screens` with
    /// unchanged geometry reads as no change. Frames are rounded to whole
    /// points: display frames are integral in practice, and rounding
    /// removes floating-point jitter from the comparison.
    private static func screenLayoutSignature() -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.map { screen -> String in
            let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
            let f = screen.frame
            return String(
                format: "%u:%d,%d,%dx%d@%.1f",
                id,
                Int(f.origin.x.rounded()), Int(f.origin.y.rounded()),
                Int(f.size.width.rounded()), Int(f.size.height.rounded()),
                screen.backingScaleFactor)
        }
        .sorted()
        .joined(separator: "|")
    }

    /// `NSApplication.didChangeScreenParametersNotification` does not mean
    /// "a display was connected or disconnected". It fires for any change to
    /// the screen configuration, and on macOS 27 it fires when nothing about
    /// the display layout has changed at all.
    ///
    /// Measured on Rainy Day (26,611 show-to-rebuild samples, 2026-09-16) it
    /// has two distinct phases, and conflating them sends you looking in the
    /// wrong place:
    ///
    /// - **What starts it:** the first notification after a quiet activation
    ///   arrives a median of **15.6s** after the window is shown (610
    ///   samples). The cause is not identified. It did not reproduce in a
    ///   hotkey-triggered session with the user present, so it may need a
    ///   genuine idle activation.
    /// - **What sustains it:** rebuilding re-posts the notification within a
    ///   median of **5ms** (26,001 samples), because showing a window at
    ///   `.screenSaver` level is itself a screen-configuration change. That
    ///   runs away at ~30 rebuilds a second, 13,119 events in one day against
    ///   a 4-300 baseline.
    ///
    /// The guard below handles both, because it refuses every notification
    /// whose layout is unchanged regardless of what posted it. Here each
    /// rebuild
    /// restarts the capture session, so the camera is torn down and
    /// reopened ~30 times a second and the picture never settles.
    ///
    /// So rebuild only when the thing the windows depend on actually
    /// differs. Showing a window does not move a display, so the signature
    /// is unchanged and the loop stops at the first hop. A debounce would
    /// not fix it: the self-posted notification just arrives later.
    private func handleScreenChange() {
        guard !windows.isEmpty else { return }
        let current = Self.screenLayoutSignature()
        guard current != builtForLayout else {
            asLog("screen parameters changed but display layout is unchanged (\(current)) — not rebuilding")
            return
        }
        asLog("display layout changed: \(builtForLayout ?? "none") → \(current) — recreating screensaver windows")
        dismissWindows(triggerLock: false)
        showWindows()
    }

    // MARK: - Live settings

    /// Push changed settings onto any visible windows.
    ///
    /// Replaces the agent's config-file watcher: the .saver wrote its options
    /// to /tmp/ASCIISaver/config.plist and posted a notification so the agent
    /// could re-read them. One process, so a UserDefaults change is enough.
    private func applyLiveSettings() {
        for win in windows { win.applySettings() }

        // Switching the silhouette filter on or off changes whether frames
        // carry a segmentation mask, which the capture session decides at
        // start. Restart if it changed mid-session.
        let wanted = silhouetteSelected
        if isCapturing && wanted != silhouetteEnabled {
            asLog("silhouette toggled — restarting capture")
            stopCapture()
            startCapture()
        }
    }

    // MARK: - Status item visibility

    private func createStatusItem() {
        guard JorvikStatusItemVisibility.isVisible else { return }
        statusItem = StatusItem(appDelegate: self)
    }

    func applyStatusItemVisibility() {
        if JorvikStatusItemVisibility.isVisible {
            if statusItem == nil { createStatusItem() }
        } else if let item = statusItem {
            item.remove()
            statusItem = nil
        }
    }

    // MARK: - Status menu actions

    func activateNowFromMenu() {
        guard windows.isEmpty else { return }
        asLog("activate-now from status menu")
        showWindows()
    }

    private func activateNowFromHotkey() {
        guard windows.isEmpty else { return }
        asLog("activate-now from hotkey")
        showWindows()
    }

    func openSettings() {
        if settingsWindow == nil {
            // While the recorder is listening, the app's own hotkeys come down
            // so pressing the shortcut already set records it instead of firing.
            let suspend: (Bool) -> Void = { [weak self] recording in
                self?.hotkeyManager.setRecordingSuspended(recording)
            }
            let activate = JorvikHotkeyRow(
                label: "Activate now",
                storageKey: activateHotkeyKey,
                onChange: { [weak self] cfg in self?.activateHotkeyChanged(cfg) },
                onRecordingChanged: suspend
            )
            let screenshot = JorvikHotkeyRow(
                label: "Screenshot",
                storageKey: screenshotHotkeyKey,
                onChange: { [weak self] cfg in self?.screenshotHotkeyChanged(cfg) },
                onRecordingChanged: suspend
            )
            settingsWindow = SettingsWindow(
                activateRecorder: activate,
                screenshotRecorder: screenshot
            )
        }
        settingsWindow?.show()
    }

    // MARK: - Screenshot

    private func captureScreenshot() {
        guard let target = currentScreensaverWindow() else {
            asLog("screenshot: no active screensaver window — ignoring hotkey")
            return
        }
        // The hotkey press is itself user input, so idle drops to 0 and the
        // next tick would close the saver a second after the capture. Extend
        // the dismiss window, matching the activation grace.
        dismissAllowedAfter = Date().addingTimeInterval(2.0)
        Screenshot.capture(from: target.renderView)
    }

    private func currentScreensaverWindow() -> ScreensaverWindow? {
        let mouse = NSEvent.mouseLocation
        return windows.first(where: { NSPointInRect(mouse, $0.screen.frame) })
            ?? windows.first
    }
}
