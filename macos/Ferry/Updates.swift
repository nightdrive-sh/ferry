import AppKit
import Sparkle

/// Sparkle keeps a Ferry that was handed out up to date: it reads the appcast in Info.plist's SUFeedURL once a day,
/// and installs a newer build only when its .dmg is signed with Ferry's EdDSA key (docs/mac-releases.md).
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?

    /// Starts the updater: from here Sparkle checks on its own schedule.
    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    func checkForUpdates() {
        // A menu bar app isn't in front by itself, and Sparkle's window would open behind the frontmost app
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// A beta build follows the beta channel's items as well as the full releases; any other build only full releases.
    /// The build carries its channel (FerryUpdateChannel, set by `macos/build.sh --release --beta`), so a beta install
    /// that updates to a full release follows full releases from then on.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Bundle.main.object(forInfoDictionaryKey: "FerryUpdateChannel") as? String == "beta" ? ["beta"] : []
    }

    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        #if DEBUG
        // A debug build in DerivedData must not replace itself with a release on its own; Check for Updates… still asks
        if updateCheck == .updatesInBackground {
            throw NSError(domain: "Ferry", code: 1, userInfo: [NSLocalizedDescriptionKey: "No scheduled update checks in a debug build"])
        }
        #endif
    }

    /// Ferry lives in the menu bar: a scheduled check that finds an update doesn't take the focus from what the user
    /// is doing (Sparkle's gentle reminders).
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
