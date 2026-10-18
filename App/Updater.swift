import AppKit
import Sparkle

/// Sparkle auto-update (D-027). Created at launch; Settings and the popover's gear menu read it.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    @ObservationIgnored private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// False while a check or install is already in progress.
    private(set) var canCheck = false
    var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }
    var installsAutomatically: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = installsAutomatically }
    }
    private(set) var lastChecked: Date?

    private init() {
        let updater = controller.updater
        checksAutomatically = updater.automaticallyChecksForUpdates
        installsAutomatically = updater.automaticallyDownloadsUpdates
        // SPUUpdater changes this on the main thread.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastChecked = updater.lastUpdateCheckDate }
            },
        ]
    }

    func checkNow() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
