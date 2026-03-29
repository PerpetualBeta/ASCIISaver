import AppKit
import AVFoundation
import ServiceManagement

private func log(_ message: String) {
    print(message)
    fflush(stdout)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let capture = CameraCaptureService()
    private let writer = SharedFrameBufferWriter()
    private var isCapturing: Bool = false
    private var pendingStop: DispatchWorkItem?
    private let stopDebounceSeconds: Double = 3.0
    private var heartbeatWatchdog: DispatchWorkItem?
    private let heartbeatTimeoutSeconds: Double = 6.0
    private static let heartbeatName = "com.jorviksoftware.ASCIISaver.agent.heartbeat" as CFString
    private static let configChangedName = "com.jorviksoftware.ASCIISaver.configChanged" as CFString
    private var aboutWindow: NSWindow?
    private var silhouetteEnabled: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: "/tmp/ASCIISaver", withIntermediateDirectories: true)
        log("[Agent] ASCIISaverCameraAgent launched")
        reloadConfig()

        // Request camera permission on first launch so the user gets prompted immediately
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                log("[Agent] Camera permission \(granted ? "granted" : "denied")")
            }
        } else if cameraStatus == .denied || cameraStatus == .restricted {
            log("[Agent] Camera permission denied/restricted — screensaver will show placeholder")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "ASCII ⏸"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        AgentControlNotifications.observeStart { [weak self] in
            DispatchQueue.main.async {
                log("[Agent] Received START notification from screen saver")
                self?.handleStartNotification()
            }
        }
        AgentControlNotifications.observeStop { [weak self] in
            DispatchQueue.main.async {
                log("[Agent] Received STOP notification from screen saver")
                self?.handleStopNotification()
            }
        }

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(center, observer, { (_, obs, _, _, _) in
            guard let obs = obs else { return }
            let this = Unmanaged<AppDelegate>.fromOpaque(obs).takeUnretainedValue()
            DispatchQueue.main.async { this.handleHeartbeat() }
        }, AppDelegate.heartbeatName, nil, .deliverImmediately)

        CFNotificationCenterAddObserver(center, observer, { (_, obs, _, _, _) in
            guard let obs = obs else { return }
            let this = Unmanaged<AppDelegate>.fromOpaque(obs).takeUnretainedValue()
            DispatchQueue.main.async {
                log("[Agent] Received configChanged notification")
                this.handleConfigChanged()
            }
        }, AppDelegate.configChangedName, nil, .deliverImmediately)

        log("[Agent] Heartbeat + configChanged observers registered")

        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(screenDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(screenDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("[Agent] applicationWillTerminate")
        AgentControlNotifications.removeAll()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pendingStop?.cancel(); pendingStop = nil
        heartbeatWatchdog?.cancel(); heartbeatWatchdog = nil
        stopCapture()
    }

    // MARK: - Config

    private func reloadConfig() {
        var filterValue = 0
        
        let configURL = URL(fileURLWithPath: "/tmp/ASCIISaver/config.plist")
        if let dict = NSDictionary(contentsOf: configURL) {
            filterValue = (dict["colourFilter"] as? Int) ?? 0
        }
        
        let wasSilhouette = silhouetteEnabled
        silhouetteEnabled = (filterValue == 4)
        capture.silhouetteEnabled = silhouetteEnabled
        log("[Agent] Config: colourFilter=\(filterValue) silhouette=\(silhouetteEnabled)")

        if isCapturing && (wasSilhouette != silhouetteEnabled) {
            log("[Agent] Silhouette changed — writer will update on next frame")
            writer.close()
            capture.needsWriterOpen = true
        }
    }

    private func handleConfigChanged() { reloadConfig() }

    // MARK: - Screen sleep/wake

    @objc private func screenDidSleep() {
        log("[Agent] Screen sleep — stopping capture")
        pendingStop?.cancel(); pendingStop = nil
        heartbeatWatchdog?.cancel(); heartbeatWatchdog = nil
        stopCapture()
    }
    @objc private func screenDidWake() { log("[Agent] Screen wake") }

    // MARK: - Heartbeat watchdog

    private func handleHeartbeat() {
        guard isCapturing, pendingStop == nil else { return }
        heartbeatWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isCapturing else { return }
            log("[Agent] Heartbeat timeout")
            self.heartbeatWatchdog = nil
            self.triggerDebouncedStop(reason: "heartbeat timeout")
        }
        heartbeatWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + heartbeatTimeoutSeconds, execute: work)
    }

    private func startHeartbeatWatchdog() {
        heartbeatWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isCapturing else { return }
            log("[Agent] Initial heartbeat timeout")
            self.heartbeatWatchdog = nil
            self.triggerDebouncedStop(reason: "initial heartbeat timeout")
        }
        heartbeatWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + heartbeatTimeoutSeconds * 2, execute: work)
        log("[Agent] Heartbeat watchdog armed")
    }

    // MARK: - Notification handlers

    private func handleStartNotification() {
        pendingStop?.cancel(); pendingStop = nil
        heartbeatWatchdog?.cancel(); heartbeatWatchdog = nil
        reloadConfig()
        startCaptureFlow()
    }

    private func handleStopNotification() {
        heartbeatWatchdog?.cancel(); heartbeatWatchdog = nil
        triggerDebouncedStop(reason: "Darwin STOP notification")
    }

    private func triggerDebouncedStop(reason: String) {
        guard pendingStop == nil else {
            log("[Agent] Stop already pending — ignoring (\(reason))")
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            log("[Agent] Debounce expired (\(reason)) — stopping")
            self.pendingStop = nil
            self.heartbeatWatchdog?.cancel(); self.heartbeatWatchdog = nil
            self.stopCapture()
        }
        pendingStop = work
        log("[Agent] Stop debounced (\(reason)) — \(stopDebounceSeconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + stopDebounceSeconds, execute: work)
    }

    // MARK: - Dynamic menu (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Camera permission status
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let statusText: String
        switch cameraStatus {
        case .authorized:       statusText = "Camera: Authorised ✓"
        case .notDetermined:    statusText = "Camera: Not Yet Requested"
        case .denied:           statusText = "Camera: Denied ✗"
        case .restricted:       statusText = "Camera: Restricted ✗"
        @unknown default:       statusText = "Camera: Unknown"
        }
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        if cameraStatus == .denied || cameraStatus == .restricted {
            let openSettings = NSMenuItem(title: "Open Privacy Settings…", action: #selector(openCameraPrivacySettings), keyEquivalent: "")
            menu.addItem(openSettings)
        }

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Start", action: #selector(startRequestedByUser), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Stop", action: #selector(stopRequestedByUser), keyEquivalent: "t"))

        menu.addItem(NSMenuItem.separator())

        // Start at Login toggle
        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "About ASCII Saver…", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
    }

    // MARK: - Manual actions

    @objc private func startRequestedByUser() { pendingStop?.cancel(); pendingStop = nil; startCaptureFlow() }
    @objc private func stopRequestedByUser() { pendingStop?.cancel(); pendingStop = nil; heartbeatWatchdog?.cancel(); heartbeatWatchdog = nil; stopCapture() }
    @objc private func quit() { pendingStop?.cancel(); pendingStop = nil; heartbeatWatchdog?.cancel(); heartbeatWatchdog = nil; stopCapture(); NSApp.terminate(nil) }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                log("[Agent] Removed from login items")
            } else {
                try SMAppService.mainApp.register()
                log("[Agent] Added to login items")
            }
        } catch {
            log("[Agent] Failed to toggle login item: \(error)")
        }
    }

    @objc private func openCameraPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    // MARK: - About window

    @objc private func showAbout() {
        if let existing = aboutWindow, existing.isVisible {
            NSApp.activate(ignoringOtherApps: true); existing.makeKeyAndOrderFront(nil); return
        }
        NSApp.activate(ignoringOtherApps: true)
        let width: CGFloat = 420; let height: CGFloat = 380
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About ASCIISaver"; window.center(); window.isReleasedWhenClosed = false; window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let iconView = NSImageView(frame: NSRect(x: (width - 128) / 2, y: height - 158, width: 128, height: 128))
        if let p = Bundle.main.path(forResource: "AppIcon", ofType: "png") { iconView.image = NSImage(contentsOfFile: p) }
        else if let i = NSImage(named: "AppIcon") { iconView.image = i }
        else if let i = NSApp.applicationIconImage { iconView.image = i }
        iconView.imageScaling = .scaleProportionallyUpOrDown; content.addSubview(iconView)

        let title = NSTextField(labelWithString: "ASCIISaver"); title.frame = NSRect(x: 0, y: height - 190, width: width, height: 24); title.alignment = .center; title.font = .boldSystemFont(ofSize: 18); content.addSubview(title)
        let ver = NSTextField(labelWithString: "Version 1.0"); ver.frame = NSRect(x: 0, y: height - 216, width: width, height: 18); ver.alignment = .center; ver.font = .systemFont(ofSize: 13); ver.textColor = .secondaryLabelColor; content.addSubview(ver)
        let copy = NSTextField(labelWithString: "© 2026 Jonathan Hollin"); copy.frame = NSRect(x: 0, y: height - 238, width: width, height: 18); copy.alignment = .center; copy.font = .systemFont(ofSize: 13); copy.textColor = .secondaryLabelColor; content.addSubview(copy)
        let desc = NSTextField(wrappingLabelWithString: "Camera agent for the ASCIISaver screensaver. Captures video and writes frames to a shared buffer for the screensaver to render as ASCII art.")
        desc.frame = NSRect(x: 40, y: height - 300, width: width - 80, height: 48); desc.alignment = .center; desc.font = .systemFont(ofSize: 12); desc.textColor = .tertiaryLabelColor; content.addSubview(desc)
        let btn = NSButton(title: "OK", target: self, action: #selector(closeAbout)); btn.bezelStyle = .rounded; btn.keyEquivalent = "\r"; btn.frame = NSRect(x: (width - 100) / 2, y: 12, width: 100, height: 32); content.addSubview(btn)

        window.contentView = content; aboutWindow = window; window.makeKeyAndOrderFront(nil)
    }
    @objc private func closeAbout() { aboutWindow?.close(); aboutWindow = nil; NSApp.setActivationPolicy(.accessory) }

    // MARK: - Capture

    private func startCaptureFlow() {
        guard !isCapturing else { log("[Agent] Already capturing"); return }
        setStatus("ASCII …")
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard granted else { self.setStatus("ASCII 🚫"); return }
                self.startCapture()
            }
        }
    }

    private func startCapture() {
        guard !isCapturing else { return }
        do {
            let config = CameraCaptureService.Config(targetWidth: 320, targetHeight: 180, fps: 15)
            try capture.start(config: config) { [weak self] frame in
                guard let self = self else { return }
                if self.capture.needsWriterOpen {
                    do {
                        try self.writer.open(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, pixelFormat: .luma8, includeMask: self.silhouetteEnabled)
                        self.capture.needsWriterOpen = false
                        log("[Agent] Writer opened (mask=\(self.silhouetteEnabled))")
                    } catch {
                        log("[Agent] Writer open FAILED: \(error)"); self.setStatus("ASCII ☓"); return
                    }
                }
                self.writer.writeFrameLuma8(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, data: frame.data, timestampNs: frame.timestampNs, maskData: frame.maskData)
                self.setStatus("ASCII ●")
            }
            isCapturing = true; setStatus("ASCII ●"); startHeartbeatWatchdog()
            log("[Agent] Capture started (silhouette=\(silhouetteEnabled))")
        } catch {
            log("[Agent] Capture FAILED: \(error)"); setStatus("ASCII ☓"); isCapturing = false
        }
    }

    private func stopCapture() {
        guard isCapturing else {
            DispatchQueue.main.async { self.setStatus("ASCII ⏸") }
            return
        }
        capture.stop(); writer.close(); capture.needsWriterOpen = true
        let url = SharedFrameBufferPath.url(); try? FileManager.default.removeItem(at: url)
        log("[Agent] Stopped, removed \(url.path)"); isCapturing = false
        DispatchQueue.main.async { self.setStatus("ASCII ⏸") }
    }

    private func setStatus(_ title: String) {
        if Thread.isMainThread { statusItem.button?.title = title }
        else { DispatchQueue.main.async { [weak self] in self?.statusItem.button?.title = title } }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === aboutWindow { aboutWindow = nil }
    }
}
