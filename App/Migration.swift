import Foundation

/// Carries settings across the bundle-identifier change.
///
/// The .saver was `com.jorviksoftware.ASCIISaver` and stored its options via
/// `ScreenSaverDefaults(forModuleWithName:)`, which writes to a plain
/// UserDefaults suite of that name. The app is
/// `cc.jorviksoftware.ASCIISaver`, so without this every existing user would
/// silently get factory settings on first launch.
///
/// What this cannot carry is the **camera grant**. TCC is keyed on the code
/// signature and bundle identifier, and there is no API to transfer a grant
/// between identities — macOS will prompt again on first activation. That is
/// unavoidable and is called out in the README and on the product page.
enum Migration {

    private static let oldSuite = "com.jorviksoftware.ASCIISaver"
    private static let doneKey  = "migratedFromSaverDefaults"

    /// The eleven render options the .saver's options sheet wrote. Anything
    /// outside this list is new to the app and has no old value to inherit.
    private static let carriedKeys = [
        "colourFilter", "invertColours", "fontSize", "targetFPS",
        "rotation", "mirrorX", "mirrorY",
        "scanlinesEnabled", "persistenceEnabled", "glitchEnabled",
        "interferenceEnabled",
    ]

    /// Copy any old values into the current domain. Idempotent: guarded by a
    /// one-shot marker so a user who deliberately resets a setting back to its
    /// default doesn't have the old value reinstated on the next launch.
    ///
    /// Call BEFORE `register(defaults:)` reads anything, and before the first
    /// window is built.
    static func runIfNeeded() {
        let defs = UserDefaults.standard
        guard !defs.bool(forKey: doneKey) else { return }

        defer {
            // Marked done even when nothing was found. A fresh install has no
            // old domain, and re-checking on every launch would be pointless
            // work that also risks resurrecting values if the user ever
            // installs the old .saver alongside.
            defs.set(true, forKey: doneKey)
        }

        guard let old = readOldSettings() else {
            asLog("Migration: no previous ASCII Saver settings found")
            return
        }

        var carried: [String] = []
        for key in carriedKeys {
            // Distinguishes "absent" from "present and false/zero". A typed
            // read would happily carry across a default the user never set.
            guard let value = old[key] else { continue }
            defs.set(value, forKey: key)
            carried.append(key)
        }

        if carried.isEmpty {
            asLog("Migration: previous settings found but held no known keys")
        } else {
            asLog("Migration: carried \(carried.count) setting(s): \(carried.joined(separator: ", "))")
        }
    }

    /// Find the .saver's saved options.
    ///
    /// Not where you would expect. `ScreenSaverDefaults(forModuleWithName:)`
    /// looks like it writes the plain `com.jorviksoftware.ASCIISaver` domain,
    /// and reading it back with `UserDefaults(suiteName:)` finds nothing —
    /// the domain does not exist. Because the saver ran inside
    /// legacyScreenSaver's sandbox, the file actually landed in that
    /// container, and as a **ByHost** plist with the hardware UUID in its
    /// name:
    ///
    ///   ~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/
    ///     Data/Library/Preferences/ByHost/com.jorviksoftware.ASCIISaver.<UUID>.plist
    ///
    /// So the file is globbed by prefix rather than named, and the plain
    /// domain is kept as a fallback in case some macOS version or a
    /// non-sandboxed run put it where the API implies.
    private static func readOldSettings() -> [String: Any]? {
        let fm = FileManager.default
        let byHost = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver")
            .appendingPathComponent("Data/Library/Preferences/ByHost", isDirectory: true)

        if let entries = try? fm.contentsOfDirectory(atPath: byHost.path) {
            // "<suite>.<UUID>.plist" — match on the prefix, since the UUID is
            // per-machine and unknowable here.
            let match = entries.first {
                $0.hasPrefix(oldSuite + ".") && $0.hasSuffix(".plist")
            }
            if let name = match,
               let dict = NSDictionary(contentsOf: byHost.appendingPathComponent(name)) as? [String: Any] {
                asLog("Migration: reading \(name)")
                return dict
            }
        }

        if let plain = UserDefaults(suiteName: oldSuite)?.persistentDomain(forName: oldSuite),
           !plain.isEmpty {
            asLog("Migration: reading plain domain \(oldSuite)")
            return plain
        }
        return nil
    }
}
