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
    var metaURL: URL { directory.appendingPathComponent("meta.json") }

    static func decode(_ data: Data) -> [Portfolio]? {
        (try? JSONDecoder().decode(PortfolioFile.self, from: data))?.portfolios
    }

    static func encode(_ portfolios: [Portfolio]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(PortfolioFile(portfolios: portfolios))
    }

    private func read(_ url: URL) -> [Portfolio]? {
        (try? Data(contentsOf: url)).flatMap(Self.decode)
    }

    /// Modification time of the file, used to notice changes made by the MCP server.
    func stamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.modificationDate] as? Date
    }

    func load() -> [Portfolio] {
        read(localURL) ?? []
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
