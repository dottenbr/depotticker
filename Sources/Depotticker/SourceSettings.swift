import SwiftUI

/// Choice of the price source and entry of the user's own API key. Used in the Mac settings window
/// and as a sheet on iPhone and iPad.
struct SourceSettingsSection: View {
    @EnvironmentObject private var store: Store
    @State private var source: DataSource = .none
    @State private var key = ""
    /// Second source for what the exchanges' free data lacks; `.none` for no second source.
    @State private var supplement: DataSource = .none

    /// The source the key field belongs to.
    private var keyed: DataSource? {
        if source.needsKey { return source }
        if source == .boerse, supplement.needsKey { return supplement }
        return nil
    }

    private var chosenSupplement: DataSource? { source == .boerse && supplement != .none ? supplement : nil }

    private var changed: Bool {
        source != store.sourceConfig.source
            || chosenSupplement != store.sourceConfig.supplement
            || (keyed.map { key != (store.sourceConfig.key($0) ?? "") } ?? false)
    }

    var body: some View {
        Section("Price source") {
            Picker("Prices from", selection: $source) {
                ForEach(DataSource.available) { Text($0.title).tag($0) }
            }
            if source == .boerse {
                Picker("Fill gaps with", selection: $supplement) {
                    Text("Nothing").tag(DataSource.none)
                    ForEach(DataSource.supplements) { Text($0.shortTitle).tag($0) }
                }
            }
            if keyed != nil {
                SecureField("API key", text: $key)
                    .textContentType(.password)
                    .autocorrectionDisabled()
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if source == .boerse, supplement != .none {
                Text(supplementExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if keyed == .eodhd {
                Link("Get an EODHD key", destination: URL(string: "https://eodhd.com/pricing")!)
                    .font(.caption)
            }
            Button("Use This Source") { store.setSource(source, key: keyed == nil ? nil : key, supplement: chosenSupplement) }
                .disabled(!changed || (keyed != nil && key.trimmingCharacters(in: .whitespaces).isEmpty))
            if let progress = store.isinProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                    Text("Looking up ISINs: \(progress.done) of \(progress.total)")
                        .font(.caption)
                }
            } else if store.sourceConfig.source == .boerse, !changed {
                if !store.unresolvedISINs.isEmpty {
                    Text("No ISIN found for \(store.unresolvedISINs.joined(separator: ", ")). Edit these positions to enter it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Look Up Missing ISINs") { Task { await store.resolveISINs(); await store.refresh() } }
            }
            if let error = store.lastError, !changed {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear {
            source = store.sourceConfig.source
            supplement = store.sourceConfig.supplement ?? .none
            key = keyed.flatMap { store.sourceConfig.key($0) } ?? ""
        }
        .onChange(of: source) { _, _ in key = keyed.flatMap { store.sourceConfig.key($0) } ?? "" }
        .onChange(of: supplement) { _, _ in key = keyed.flatMap { store.sourceConfig.key($0) } ?? "" }
    }

    private var supplementExplanation: String {
        let what = "It supplies the price history from before the app started collecting its own, which also makes "
            + "purchase-date estimates possible, and prices the shares that are not traded on the German exchanges. "
            + "Where it quotes a share in another currency, its older prices are converted at the European Central "
            + "Bank's rate of each day, so they are close to, but not exactly, what the share cost in Germany. "
        switch supplement {
        case .yahoo:
            return what + "Yahoo's terms do not permit automated access, so this part is not licensed and can stop "
                + "working at any time."
        case .eodhd:
            return what + "EODHD is a licensed vendor; you paste your own key, which stays on this device."
        default:
            return ""
        }
    }

    private var explanation: String {
        switch source {
        case .none:
            return "Share prices are licensed data, so Depotticker has no built-in feed. Choose a source to see "
                + "prices and values. Your positions stay as they are."
        case .boerse:
            return "Free and without an account. EU law obliges exchanges to publish their prices free of charge after "
                + "15 minutes, and Deutsche Börse does so for Xetra, Frankfurt and Tradegate. The app downloads these "
                + "files to this device and keeps only your own shares; that can be up to about 50 MB on a full trading "
                + "day. Each position needs its ISIN, which the app looks up for you. Shares not traded on these "
                + "exchanges, such as US-only funds, show no price, and the files hold no history, so charts fill up "
                + "from the day you start and purchase dates cannot be estimated, unless you choose a second source "
                + "to fill these gaps. Exchange rates are the European Central "
                + "Bank's daily reference rates."
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
        .frame(width: 520, height: 520)
        #endif
    }
}
