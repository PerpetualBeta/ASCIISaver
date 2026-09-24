import AppKit
import SwiftUI
import AVFoundation

/// Settings window for ASCII Saver. Hosted by the standard JorvikSettingsView
/// wrapper which provides the title, "General" section (Launch at Login), and
/// Done button. App-specific sections live in `ASCIISaverSettingsContent`.
///
/// This replaces the ScreenSaverDefaults options sheet that used to live
/// inside System Settings → Screen Saver, and with it the plist in /tmp the
/// sheet wrote so the camera agent could see the same values.
final class SettingsWindow {

    let activateRecorder: JorvikHotkeyRow
    let screenshotRecorder: JorvikHotkeyRow

    init(activateRecorder: JorvikHotkeyRow, screenshotRecorder: JorvikHotkeyRow) {
        self.activateRecorder = activateRecorder
        self.screenshotRecorder = screenshotRecorder
    }

    func show() {
        JorvikSettingsView.showWindow(appName: "ASCII Saver") {
            ASCIISaverSettingsContent(
                activateRecorder: self.activateRecorder,
                screenshotRecorder: self.screenshotRecorder
            )
        }
    }
}

// MARK: - App-specific settings sections

/// Per the Jorvik convention, sections appear top-to-bottom in the order:
/// Permissions → app-specific → General (Launch at Login, auto-injected by
/// JorvikSettingsView).
///
/// Every `@AppStorage` default here is mirrored by a `register(defaults:)`
/// call in AppDelegate. `@AppStorage`'s declared default is UI-only — it does
/// not seed UserDefaults, so native readers would otherwise see 0/false until
/// the user first touched the control.
struct ASCIISaverSettingsContent: View {

    let activateRecorder: JorvikHotkeyRow
    let screenshotRecorder: JorvikHotkeyRow

    @AppStorage("idleMinutes")          private var idleMinutes: Int = 5
    @AppStorage("lockOnDismiss")        private var lockOnDismiss: Bool = false
    @AppStorage("activationSuspended")  private var activationSuspended: Bool = false
    /// The soonest of macOS's own idle timers, re-read when Settings opens
    /// and when the app becomes active again. See `macScreenLockNote`.
    @State private var macMinimumTrigger: (seconds: TimeInterval, cause: SystemScreenLockSettings.Cause)?

    // The eleven render options carried over from the .saver's options sheet.
    @AppStorage("colourFilter")         private var colourFilter: Int = 0
    @AppStorage("invertColours")        private var invertColours: Bool = false
    @AppStorage("fontSize")             private var fontSize: Double = 9.0
    @AppStorage("targetFPS")            private var targetFPS: Double = 24.0
    @AppStorage("rotation")             private var rotation: Int = 0
    @AppStorage("mirrorX")              private var mirrorX: Bool = true
    @AppStorage("mirrorY")              private var mirrorY: Bool = false
    @AppStorage("scanlinesEnabled")     private var scanlines: Bool = true
    @AppStorage("persistenceEnabled")   private var persistence: Bool = false
    @AppStorage("glitchEnabled")        private var glitch: Bool = false
    @AppStorage("interferenceEnabled")  private var interference: Bool = false

    /// Whether the camera is ours to use, kept current by JorvikKit — see
    /// `JorvikPermissionWatcher`. There is no announcement for camera access, so it is the
    /// once-a-second re-read that catches a change made in System Settings.
    @StateObject private var camera = JorvikPermissionWatcher {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }
    /// Whether the system prompt has been through once. A one-way latch, because that is
    /// what it is: `notDetermined` never comes back, and it is the only thing that decides
    /// whether the button can still prompt or has to send the user to System Settings.
    @State private var everAsked: Bool =
        AVCaptureDevice.authorizationStatus(for: .video) != .notDetermined

    var body: some View {
        Section("Permissions") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Camera")
                    Spacer()
                    if camera.isGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else if !everAsked {
                        Button("Grant Access") {
                            AVCaptureDevice.requestAccess(for: .video) { _ in
                                DispatchQueue.main.async {
                                    everAsked = true
                                    camera.reread()
                                }
                            }
                        }
                        .font(.caption)
                    } else {
                        Button("Open System Settings") {
                            JorvikPermissionWatcher.openSettings(pane: .camera)
                        }
                        .font(.caption)
                    }
                }
                Text("ASCII Saver renders the camera feed as ASCII art. Nothing is recorded, saved, or sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        MenuBarVisibilitySettings()

        Section("Activation") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Suspended")
                    Spacer()
                    Toggle("", isOn: $activationSuspended)
                        .labelsHidden()
                        .onChange(of: activationSuspended) { _, suspended in
                            asLog(suspended ? "activation suspended from Settings" : "activation resumed from Settings")
                            // Written directly via @AppStorage, so the status
                            // item, which has no observer on the key itself,
                            // needs telling to update its icon and menu label.
                            NotificationCenter.default.post(name: .activationSuspendedChanged, object: nil)
                        }
                }
                Text("While suspended, ASCII Saver will not activate on its own when idle. Activate Now still works, from the menu or its shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Idle timeout")
                    Spacer()
                    TextField("", value: $idleMinutes, formatter: Self.number(min: 1, max: 1440))
                        .labelsHidden()
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text("minutes")
                        .foregroundStyle(.secondary)
                }
                if let note = macScreenLockNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            activateRecorder
        }
        .onAppear { refreshMacScreenLockTimers() }
        // Nothing tells this app when a System Settings timer changes. Someone
        // who has just changed one comes back to this app to look, which makes
        // it active again, so re-read them then.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshMacScreenLockTimers()
        }

        Section("On dismiss") {
            Toggle("Lock screen when dismissed", isOn: $lockOnDismiss)
        }

        Section("Capture") {
            VStack(alignment: .leading, spacing: 4) {
                screenshotRecorder
                Text("Saves to ~/Pictures/ASCII Saver/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Picture") {
            Picker("Colour filter:", selection: $colourFilter) {
                Text("Classic").tag(0)
                Text("Matrix").tag(1)
                Text("Amber").tag(2)
                Text("Raw feed").tag(3)
                Text("Silhouette").tag(4)
            }
            Toggle("Invert colours", isOn: $invertColours)
            HStack {
                Text("Character size:")
                Spacer()
                TextField("", value: $fontSize, formatter: Self.decimal(min: 4, max: 32))
                    .labelsHidden()
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("pt")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Frame rate:")
                Spacer()
                TextField("", value: $targetFPS, formatter: Self.decimal(min: 5, max: 60))
                    .labelsHidden()
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("fps")
                    .foregroundStyle(.secondary)
            }
        }

        Section("Orientation") {
            Picker("Rotation:", selection: $rotation) {
                Text("None").tag(0)
                Text("90° right").tag(1)
                Text("90° left").tag(2)
                Text("180°").tag(3)
            }
            Toggle("Mirror horizontally", isOn: $mirrorX)
            Toggle("Mirror vertically", isOn: $mirrorY)
        }

        Section("Effects") {
            Toggle("Scanlines", isOn: $scanlines)
            Toggle("Phosphor persistence", isOn: $persistence)
            Toggle("Glitch", isOn: $glitch)
            Toggle("Interference", isOn: $interference)
        }
    }

    /// Logged only when the summary changes, not on every refresh.
    private static var lastLoggedMacScreenLockSummary: String?

    private func refreshMacScreenLockTimers() {
        macMinimumTrigger = SystemScreenLockSettings.minimumTrigger
        let summary = SystemScreenLockSettings.summaryForLogging
        if summary != Self.lastLoggedMacScreenLockSummary {
            asLog("macOS screen/display timers: \(summary)")
            Self.lastLoggedMacScreenLockSummary = summary
        }
    }

    /// A warning for the idle-timeout row, shown only when macOS's own screen
    /// saver, or the display-off timer that applies to this Mac, is set at or
    /// below the idle timeout. `nil`, so no note at all, otherwise. One whole
    /// sentence per cause, each naming the row as System Settings labels it.
    private var macScreenLockNote: String? {
        guard let trigger = macMinimumTrigger,
              Double(idleMinutes) * 60 >= trigger.seconds
        else { return nil }
        let minutes = Int((trigger.seconds / 60).rounded())
        switch trigger.cause {
        case .screensaver:
            return "“Start Screen Saver when inactive” is set to \(minutes) min in System Settings, so macOS’s own screen saver starts first and ASCII Saver never does."
        case .displaySleep:
            return "“Turn display off when inactive” is set to \(minutes) min in System Settings, so the display goes dark before ASCII Saver can start."
        case .displaySleepBattery:
            return "“Turn display off on battery when inactive” is set to \(minutes) min in System Settings. On battery, the display goes dark before ASCII Saver can start."
        case .displaySleepACPower:
            return "“Turn display off on power adapter when inactive” is set to \(minutes) min in System Settings. On the power adapter, the display goes dark before ASCII Saver can start."
        }
    }

    private static func number(min lo: Int, max hi: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = NSNumber(value: lo)
        f.maximum = NSNumber(value: hi)
        f.allowsFloats = false
        return f
    }

    private static func decimal(min lo: Double, max hi: Double) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimum = NSNumber(value: lo)
        f.maximum = NSNumber(value: hi)
        f.maximumFractionDigits = 1
        return f
    }
}
