import Foundation

/// Reads and writes the portfolio file. Used by the app, the widget mirror and the MCP server.
struct PortfolioRepository {
    /// App Store builds keep data in the shared app-group container (set through Info.plist).
    static var appGroup: String? {
        (Bundle.main.object(forInfoDictionaryKey: "DepotAppGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// App Store builds sync through the iCloud key-value store (set through Info.plist).
    static var usesCloudStore: Bool {
        Bundle.main.object(forInfoDictionaryKey: "DepotUsesICloud") as? Bool ?? false
    }

    static let cloudKey = "portfolios"

    let directory: URL

    init() {
        let manager = FileManager.default
        // A folder given in DEPOTTICKER_DATA replaces the normal location (used for demos and tests).
        if let override = ProcessInfo.processInfo.environment["DEPOTTICKER_DATA"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else if let group = Self.appGroup, let container = manager.containerURL(forSecurityApplicationGroupIdentifier: group) {
            directory = container.appendingPathComponent("Depotticker", isDirectory: true)
        } else {
            let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = base.appendingPathComponent("Depotticker", isDirectory: true)
        }
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var localURL: URL { directory.appendingPathComponent("portfolios.json") }
    var metaURL: URL { directory.appendingPathComponent(MarketData.metaFileName) }

    static func decode(_ data: Data) -> [Portfolio]? {
        (try? JSONDecoder().decode(PortfolioFile.self, from: data))?.portfolios
    }

    static func encode(_ portfolios: [Portfolio]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(PortfolioFile(portfolios: portfolios))
    }


    /// Modification time of the file, used to notice changes made by the MCP server.
    func stamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.modificationDate] as? Date
    }

    func load() -> [Portfolio] { loadChecked().portfolios }

    /// What a load could not read, and where the untouched original was kept.
    struct LoadProblem {
        /// Positions left out; nil when the whole file was unreadable.
        var skipped: Int?
        var copy: URL

        var message: String {
            let what = skipped.map { "\($0) position\($0 == 1 ? "" : "s") could not be read and \($0 == 1 ? "was" : "were") left out." }
                ?? "The portfolio file could not be read."
            return "\(what) The original was kept as \(copy.lastPathComponent) in the data folder."
        }
    }

    /// A file that cannot be read in full (damaged, or written by a newer version) must not be lost
    /// when the next save replaces it: the original is set aside first.
    func loadChecked() -> (portfolios: [Portfolio], problem: LoadProblem?) {
        guard let data = try? Data(contentsOf: localURL), !data.isEmpty else { return ([], nil) }
        let skipped = SkippedEntries()
        let decoder = JSONDecoder()
        decoder.userInfo[SkippedEntries.key] = skipped
        let portfolios = (try? decoder.decode(PortfolioFile.self, from: data))?.portfolios
        if let portfolios, skipped.count == 0 { return (portfolios, nil) }
        let copy = directory.appendingPathComponent("portfolios.unreadable-\(Trade.dayFormatter.string(from: Date())).json")
        try? data.write(to: copy, options: .atomic)
        return (portfolios ?? [], LoadProblem(skipped: portfolios == nil ? nil : skipped.count, copy: copy))
    }

    func save(_ portfolios: [Portfolio]) {
        guard let data = Self.encode(portfolios) else { return }
        try? data.write(to: localURL, options: .atomic)
        if Self.usesCloudStore {
            NSUbiquitousKeyValueStore.default.set(data, forKey: Self.cloudKey)
        }
    }

    /// Keeps the previous state before a bulk change such as an import.
    func backup(_ portfolios: [Portfolio]) {
        try? Self.encode(portfolios)?.write(to: directory.appendingPathComponent("portfolios.backup.json"), options: .atomic)
    }

    func loadMeta() -> [String: SymbolMeta] {
        guard let data = try? Data(contentsOf: metaURL) else { return [:] }
        return (try? JSONDecoder().decode([String: SymbolMeta].self, from: data)) ?? [:]
    }

    func saveMeta(_ meta: [String: SymbolMeta]) {
        try? JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
    }
}
