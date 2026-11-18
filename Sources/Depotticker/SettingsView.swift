#if os(macOS)
import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        Form {
            Section("iCloud") {
                LabeledContent("Sync") {
                    Text(syncStatus)
                        .foregroundStyle(.secondary)
                }
                Text("With iCloud sync your portfolios are stored in your Apple Account and appear automatically "
                     + "on your Mac, iPhone and iPad. Nothing is saved as a file in iCloud Drive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SourceSettingsSection()
            Section("Menu bar") {
                Picker("Show", selection: $store.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Privacy") {
                Toggle("Hide amounts in the menu bar during calls and screen sharing", isOn: $store.autoHideAmounts)
                Text("macOS does not tell apps when another app captures the screen. Depotticker therefore hides "
                     + "amounts while the microphone is in use (a call), while this Mac is viewed through Screen "
                     + "Sharing, or while the display is mirrored. Only the percentage stays visible."
                     + (store.sharingDetected ? " Amounts are hidden right now." : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Keep Depotticker windows out of screen sharing and recordings", isOn: $store.excludeFromCapture)
                Text("Asks macOS to leave the app's windows and menu bar item out of shared or recorded screens. "
                     + "Some capture tools ignore this request, so treat it as an extra layer, not a guarantee.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private var syncStatus: String {
        guard PortfolioRepository.usesCloudStore else { return "Not available in this build" }
        return FileManager.default.ubiquityIdentityToken == nil ? "Sign in to iCloud to sync" : "On"
    }
}
#endif
