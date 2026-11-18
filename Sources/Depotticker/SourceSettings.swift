import SwiftUI

/// Choice of the price source and entry of the user's own API key. Used in the Mac settings window
/// and as a sheet on iPhone and iPad.
struct SourceSettingsSection: View {
    @EnvironmentObject private var store: Store
    @State private var source: DataSource = .none
    @State private var key = ""

    private var changed: Bool {
        source != store.sourceConfig.source || (source.needsKey && key != (store.sourceConfig.key(source) ?? ""))
    }

    var body: some View {
        Section("Price source") {
            Picker("Prices from", selection: $source) {
                ForEach(DataSource.available) { Text($0.title).tag($0) }
            }
            if source.needsKey {
                SecureField("API key", text: $key)
                    .textContentType(.password)
                    .autocorrectionDisabled()
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if source == .eodhd {
                Link("Get an EODHD key", destination: URL(string: "https://eodhd.com/pricing")!)
                    .font(.caption)
            }
            Button("Use This Source") { store.setSource(source, key: source.needsKey ? key : nil) }
                .disabled(!changed || (source.needsKey && key.trimmingCharacters(in: .whitespaces).isEmpty))
            if let error = store.lastError, !changed {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear {
            source = store.sourceConfig.source
            key = store.sourceConfig.key(source) ?? ""
        }
        .onChange(of: source) { _, new in key = store.sourceConfig.key(new) ?? "" }
    }

    private var explanation: String {
        switch source {
        case .none:
            return "Share prices are licensed data, so Depotticker has no built-in feed. Choose a source to see "
                + "prices and values. Your positions stay as they are."
        case .eodhd:
            return "EODHD is a licensed data vendor covering Xetra, other European exchanges, funds and US shares. "
                + "You sign up there yourself and paste your key here; the app then asks EODHD directly from this "
                + "device. Prices are delayed by about 15 minutes. The free key allows 20 requests a day, which is "
                + "only enough to try it out; a portfolio needs a paid personal plan. The key is stored on this "
                + "device only. Exchange rates are the European Central Bank's daily reference rates."
        case .yahoo:
            return "Uses Yahoo Finance's undocumented web endpoints. Yahoo's terms do not permit automated access, "
                + "so this source is not licensed and can stop working at any time. It is offered only in the "
                + "direct download for people who already rely on it."
        }
    }
}

/// The same choice as a sheet, for iPhone and iPad (and from the toolbar menu on the Mac).
struct SourceSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { SourceSettingsSection() }
                .formStyle(.grouped)
                .navigationTitle("Price Source")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        #if os(macOS)
        .frame(width: 520, height: 380)
        #endif
    }
}
