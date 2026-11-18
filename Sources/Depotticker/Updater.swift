import SwiftUI

/// Addresses used by the app. The site also hosts the update feed for the direct-download build.
enum Links {
    static let site = URL(string: "https://depotticker.com/")!
    static let help = URL(string: "https://depotticker.com/help/")!
}

#if canImport(Sparkle)
import Sparkle

/// Automatic updates for the direct-download build. App Store builds are updated by the store.
@MainActor
final class Updater: ObservableObject {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                          userDriverDelegate: nil)

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

struct CheckForUpdatesCommand: Commands {
    @ObservedObject var updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
        }
    }
}
#endif
