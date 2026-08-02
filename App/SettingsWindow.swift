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

    let activateRecorder: HotkeyRecorderView
    let screenshotRecorder: HotkeyRecorderView

    init(activateRecorder: HotkeyRecorderView, screenshotRecorder: HotkeyRecorderView) {
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

    let activateRecorder: HotkeyRecorderView
    let screenshotRecorder: HotkeyRecorderView

    @AppStorage("idleMinutes")          private var idleMinutes: Int = 5
    @AppStorage("lockOnDismiss")        private var lockOnDismiss: Bool = false

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

    /// The camera grant can change outside the app (System Settings), and
    /// changes the instant the user answers the prompt. Re-poll on appear.
    @State private var cameraStatus: AVAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Section("Permissions") {
            HStack {
                Text("Camera")
                Spacer()
                switch cameraStatus {
                case .authorized:
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .notDetermined:
                    Button("Grant Access") {
                        AVCaptureDevice.requestAccess(for: .video) { _ in
                            DispatchQueue.main.async {
                                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                            }
                        }
                    }
                    .font(.caption)
                default:
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                }
            }
            Text("ASCII Saver renders the camera feed as ASCII art. Nothing is recorded, saved, or sent anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        MenuBarVisibilitySettings()

        Section("Activation") {
            HStack {
                Text("Idle timeout:")
                TextField("", value: $idleMinutes, formatter: Self.number(min: 1, max: 1440))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("minutes")
                Spacer()
            }
            HStack {
                Text("Activate now:")
                activateRecorder
                    .frame(width: 180, height: 24)
                Spacer()
            }
        }

        Section("On dismiss") {
            Toggle("Lock screen when dismissed", isOn: $lockOnDismiss)
        }

        Section("Capture") {
            HStack {
                Text("Screenshot:")
                screenshotRecorder
                    .frame(width: 180, height: 24)
                Spacer()
            }
            Text("Saves to ~/Pictures/ASCII Saver/")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                TextField("", value: $fontSize, formatter: Self.decimal(min: 4, max: 32))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("pt")
                Spacer()
            }
            HStack {
                Text("Frame rate:")
                TextField("", value: $targetFPS, formatter: Self.decimal(min: 5, max: 60))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("fps")
                Spacer()
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
        .onAppear {
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
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
