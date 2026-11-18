import Foundation
import zlib

/// Reads the delayed trade files that Deutsche Börse publishes free of charge under MiFIR Article 13
/// (Xetra, Börse Frankfurt and Tradegate, 15 minutes delayed, one file per minute and one per day).
/// The files hold every trade of the whole market keyed by ISIN; there is no query for one share, so
/// the reader downloads them on this device and keeps only the user's own ISINs. Nothing is passed on.
/// The files carry no history: closing prices are collected from the day the source is first used.
enum DeutscheBoerse {
    enum Venue: String, CaseIterable, Codable {
        case xetra = "DETR", tradegate = "DGAT", frankfurt = "DFRA"

        var title: String {
            switch self {
            case .xetra: return "Xetra"
            case .tradegate: return "Tradegate"
            case .frankfurt: return "Frankfurt"
            }
        }

        var prefix: String { "\(rawValue)-posttrade" }
    }

    /// One trade as far as the app needs it.
    struct Trade {
        var isin: String
        var price: Double
        var currency: String
        var quantity: Double
        var time: Date
        /// False for Xetra's evening retail service, which is not part of the official session.
        var regular: Bool
    }

    struct Print: Codable, Equatable {
        var price: Double
        var time: Double
    }

    /// Everything kept between runs, for the user's own ISINs only.
    struct State: Codable {
        /// ISINs the stored values cover.
        var tracked: Set<String> = []
        /// Trading day ("yyyy-MM-dd", UTC) that `last` belongs to, per venue.
        var day: [String: String] = [:]
        /// Day the `read` minutes belong to.
        var readDay = ""
        /// Minutes of `readDay` (0…1439, UTC) whose file has been read, per venue.
        var read: [String: Set<Int>] = [:]
        /// Date of the newest daily file read, per venue.
        var daily: [String: String] = [:]
        /// Last regular trade of `day`, per venue and ISIN.
        var last: [String: [String: Print]] = [:]
        /// Later trade outside the regular session, per venue and ISIN.
        var late: [String: [String: Print]] = [:]
        /// Last close before `day`, per venue and ISIN.
        var previous: [String: [String: Double]] = [:]
        /// Five-minute prices of the latest day with trades, per venue and ISIN.
        var bars: [String: [String: [ChartPoint]]] = [:]
        /// Shares traded on that day, per venue and ISIN.
        var volume: [String: [String: Double]] = [:]
        /// Closing prices collected so far, per venue, ISIN and day.
        var history: [String: [String: [String: Double]]] = [:]
        var currency: [String: String] = [:]
    }

    // MARK: Parsing

    /// Reads one line of a post-trade file. Lines for other ISINs are rejected before any JSON work.
    static func parse(line: Substring, wanted: Set<String>, venue: Venue) -> Trade? {
        guard let marker = line.range(of: "\"instrumentIdentificationCode\":\"") else { return nil }
        let isin = String(line[marker.upperBound...].prefix(12))
        guard wanted.contains(isin),
              let data = line.data(using: .utf8),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let price = row["price"] as? Double, price > 0,
              let quantity = row["quantity"] as? Double, quantity > 0,
              (row["priceNotation"] as? String ?? "MONE") == "MONE",
              let stamp = row["tradingDateAndTime"] as? String, let time = date(stamp)
        else { return nil }
        let retail = venue == .xetra && (row["tradingSystem"] as? String) == "RETL"
        return Trade(isin: isin, price: price, currency: (row["priceCurrency"] as? String) ?? "EUR",
                     quantity: quantity, time: time, regular: !retail)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// "2026-11-18T12:00:00.017748534Z" to a date, ignoring the fraction.
    static func date(_ stamp: String) -> Date? {
        let digits = stamp.prefix(19).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard digits.count == 6 else { return nil }
        return utc.date(from: DateComponents(year: digits[0], month: digits[1], day: digits[2],
                                             hour: digits[3], minute: digits[4], second: digits[5]))
    }

    static func day(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func minuteName(_ date: Date) -> String {
        let c = utc.dateComponents([.hour, .minute], from: date)
        return "\(day(date))T" + String(format: "%02d_%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Applies one trade to the stored state. Trades may arrive in any order within a day.
    static func apply(_ trade: Trade, venue: Venue, to state: inout State) {
        let v = venue.rawValue
        let tradeDay = day(trade.time)
        let current = state.day[v] ?? ""
        if tradeDay < current { return }
        if tradeDay > current {
            // A new trading day: yesterday's last prices become the previous closes.
            for (isin, print) in state.last[v] ?? [:] {
                state.previous[v, default: [:]][isin] = print.price
                if !current.isEmpty { state.history[v, default: [:]][isin, default: [:]][current] = print.price }
            }
            state.last[v] = [:]
            state.late[v] = [:]
            state.day[v] = tradeDay
        }
        state.currency[trade.isin] = trade.currency
        let stamp = trade.time.timeIntervalSince1970
        guard trade.regular else {
            if stamp >= state.late[v]?[trade.isin]?.time ?? 0 {
                state.late[v, default: [:]][trade.isin] = Print(price: trade.price, time: stamp)
            }
            return
        }
        if stamp >= state.last[v]?[trade.isin]?.time ?? 0 {
            state.last[v, default: [:]][trade.isin] = Print(price: trade.price, time: stamp)
        }
        // Five-minute bars of the latest day with trades.
        var bars = state.bars[v]?[trade.isin] ?? []
        if let first = bars.first, day(first.date) != tradeDay {
            bars = []
            state.volume[v, default: [:]][trade.isin] = 0
        }
        state.volume[v, default: [:]][trade.isin, default: 0] += trade.quantity
        let bucket = Date(timeIntervalSince1970: (stamp / 300).rounded(.down) * 300)
        if let index = bars.firstIndex(where: { $0.date == bucket }) {
            if stamp >= bars[index].volume ?? 0 { bars[index] = ChartPoint(date: bucket, price: trade.price, volume: stamp) }
        } else {
            bars.append(ChartPoint(date: bucket, price: trade.price, volume: stamp))
            bars.sort { $0.date < $1.date }
        }
        state.bars[v, default: [:]][trade.isin] = bars
    }

    // MARK: Gzip

    /// Inflates gzip data piece by piece and hands over complete lines, so a 190 MB daily file never
    /// has to be held in memory.
    final class LineInflater {
        private var stream = z_stream()
        private var carry = Data()
        private var output = [UInt8](repeating: 0, count: 1 << 18)
        private let onLine: (Substring) -> Void
        private var ready = false

        init(onLine: @escaping (Substring) -> Void) {
            self.onLine = onLine
            // 15 + 32: detect the gzip header automatically.
            ready = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        }

        deinit { if ready { inflateEnd(&stream) } }

        /// Returns false when the data is not valid gzip.
        func feed(_ input: Data) -> Bool {
            guard ready, !input.isEmpty else { return ready }
            var ok = true
            input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = UInt32(raw.count)
                while stream.avail_in > 0, ok {
                    let status: Int32 = output.withUnsafeMutableBufferPointer { buffer in
                        stream.next_out = buffer.baseAddress
                        stream.avail_out = UInt32(buffer.count)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    let produced = output.count - Int(stream.avail_out)
                    if produced > 0 { emit(output[0..<produced]) }
                    if status == Z_STREAM_END {
                        // Several gzip members may follow each other.
                        if stream.avail_in > 0 { inflateReset(&stream) } else { break }
                    } else if status != Z_OK && status != Z_BUF_ERROR {
                        ok = false
                    } else if status == Z_BUF_ERROR && produced == 0 {
                        break
                    }
                }
            }
            return ok
        }

        func finish() {
            if !carry.isEmpty, let text = String(data: carry, encoding: .utf8) { onLine(Substring(text)) }
            carry.removeAll()
        }

        private func emit(_ bytes: ArraySlice<UInt8>) {
            carry.append(contentsOf: bytes)
            guard let lastBreak = carry.lastIndex(of: 0x0A) else { return }
            let complete = carry[carry.startIndex...lastBreak]
            if let text = String(data: complete, encoding: .utf8) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) { onLine(line) }
            }
            carry = Data(carry[carry.index(after: lastBreak)...])
        }
    }

    // MARK: Network

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["User-Agent": "Depotticker (open source; reads the MiFIR delayed data files)"]
        return URLSession(configuration: config)
    }()

    private static let base = "https://mfs.deutsche-boerse.com/api/"

    /// Names of the files currently offered for a venue.
    private static func index(_ venue: Venue) async -> [String]? {
        guard let url = URL(string: base + venue.prefix),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["CurrentFiles"] as? [String]
    }

    /// Downloads one file and returns its trades for the wanted ISINs; nil when the download failed,
    /// an empty list when the file does not exist (a minute without trades).
    private static func trades(file: String, venue: Venue, wanted: Set<String>) async -> [Trade]? {
        guard let url = URL(string: base + "download/" + file) else { return nil }
        // The server answers with a link that is valid for two seconds; a busy moment can miss it.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(3 * attempt)) }
            switch await download(url, venue: venue, wanted: wanted) {
            case .success(let found): return found
            case .failure(let reason):
                log("\(file): attempt \(attempt + 1) failed: \(reason)")
            }
        }
        return nil
    }

    private struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    private static func download(_ url: URL, venue: Venue, wanted: Set<String>) async -> Result<[Trade], Failure> {
        let location: URL, response: URLResponse
        do { (location, response) = try await session.download(from: url) } catch {
            return .failure(Failure(description: error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: location) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return .success([]) }
        guard status == 200, let handle = try? FileHandle(forReadingFrom: location) else {
            return .failure(Failure(description: "HTTP \(status)"))
        }
        defer { try? handle.close() }
        var found: [Trade] = []
        let inflater = LineInflater { line in
            if let trade = parse(line: line, wanted: wanted, venue: venue) { found.append(trade) }
        }
        while let chunk = try? handle.read(upToCount: 1 << 18), !chunk.isEmpty {
            guard inflater.feed(chunk) else { return .failure(Failure(description: "not gzip")) }
        }
        inflater.finish()
        return .success(found)
    }

    // MARK: Engine

    private actor Engine {
        private var state = State()
        private var loaded = false
        private var running: Task<Void, Never>?
        private var lastRun = Date.distantPast

        private var url: URL {
            // Demo and test data folders keep their own copy.
            if let override = ProcessInfo.processInfo.environment["DEPOTTICKER_DATA"], !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("boerse-state.json")
            }
            return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Depotticker-boerse.json")
        }

        private func load() {
            guard !loaded else { return }
            loaded = true
            if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(State.self, from: data) {
                state = saved
            }
        }

        private func save() {
            try? JSONEncoder().encode(state).write(to: url, options: .atomic)
        }

        func snapshot() -> State {
            load()
            return state
        }

        /// Brings the stored prices up to date. Concurrent callers share one run.
        func update(isins: Set<String>, venues: [Venue]) async {
            if let running {
                await running.value
                return
            }
            // New files appear once a minute; asking more often gains nothing.
            load()
            if isins.isSubset(of: state.tracked), Date().timeIntervalSince(lastRun) < 45 { return }
            defer { lastRun = Date() }
            let task = Task { await self.run(isins: isins, venues: venues) }
            running = task
            await task.value
            running = nil
        }

        /// One round of downloads. The file service blocks clients that fetch in bursts, so every round
        /// stays within a small budget, spaced out, and reads the newest minutes first: prices of
        /// actively traded shares arrive at once, the rest of the day fills in over the next rounds.
        private func run(isins: Set<String>, venues: [Venue]) async {
            load()
            guard !isins.isEmpty else { return }
            if !isins.isSubset(of: state.tracked) {
                // A new ISIN: the files already read were filtered without it, so read them again.
                state.tracked.formUnion(isins)
                state.day = [:]
                state.daily = [:]
                state.last = [:]
                state.late = [:]
                state.read = [:]
            }
            let wanted = state.tracked
            let now = Date()
            let today = DeutscheBoerse.day(now)
            if state.readDay != today {
                state.readDay = today
                state.read = [:]
            }
            var budget = DeutscheBoerse.requestsPerRound

            // Daily files of earlier days give the previous closes. One index and one file per venue.
            for venue in venues where state.daily[venue.rawValue] == nil || (state.daily[venue.rawValue] ?? "") < DeutscheBoerse.day(now.addingTimeInterval(-86_400)) {
                let v = venue.rawValue
                guard dailyChecked[v] != today else { continue }
                await DeutscheBoerse.pace.wait()
                budget -= 1
                guard let listed = await DeutscheBoerse.index(venue) else {
                    DeutscheBoerse.log("\(v): index failed")
                    continue
                }
                dailyChecked[v] = today
                for file in listed.filter({ $0.contains("-daily-") }).sorted() {
                    let date = String(file.dropFirst("\(venue.prefix)-daily-".count).prefix(10))
                    guard date < today, date > state.daily[v] ?? "" else { continue }
                    await DeutscheBoerse.pace.wait()
                    budget -= 1
                    guard let trades = await DeutscheBoerse.trades(file: file, venue: venue, wanted: wanted) else {
                        DeutscheBoerse.log("\(v): daily \(file) failed")
                        dailyChecked[v] = nil
                        continue
                    }
                    DeutscheBoerse.log("\(v): daily \(file) trades \(trades.count)")
                    if state.day[v] == date {
                        // The daily file holds the whole day; drop what the minute files gave so nothing counts twice.
                        state.last[v] = [:]
                        state.late[v] = [:]
                        state.volume[v] = [:]
                        state.bars[v] = [:]
                    }
                    for trade in trades.sorted(by: { $0.time < $1.time }) { DeutscheBoerse.apply(trade, venue: venue, to: &state) }
                    state.daily[v] = date
                }
                if state.daily[v] == nil { state.daily[v] = "" }
                save()
            }

            // Minute files of today, newest first, taking turns between the venues.
            let c = DeutscheBoerse.utc.dateComponents([.hour, .minute], from: now.addingTimeInterval(-16 * 60))
            let newest = DeutscheBoerse.day(now.addingTimeInterval(-16 * 60)) == today ? (c.hour ?? 0) * 60 + (c.minute ?? 0) : -1
            var open: [Venue: [Int]] = [:]
            for venue in venues {
                let done = state.read[venue.rawValue] ?? []
                let floor = max(DeutscheBoerse.firstMinute, newest - DeutscheBoerse.lookBack)
                guard newest >= floor else { continue }
                var minutes = stride(from: newest, through: floor, by: -1).filter { !done.contains($0) }
                if venue == .xetra {
                    // After the close, the closing auction holds the day's last price of nearly every
                    // share: read it before working back through the quiet evening minutes.
                    let auction = DeutscheBoerse.closingAuction(on: now)
                    minutes = minutes.filter { auction.contains($0) } + minutes.filter { !auction.contains($0) }
                }
                open[venue] = minutes
            }
            var failures = 0
            while budget > 0, failures < 3, open.values.contains(where: { !$0.isEmpty }) {
                for venue in venues where budget > 0 {
                    guard let minute = open[venue]?.first else { continue }
                    open[venue]?.removeFirst()
                    let name = "\(venue.prefix)-\(today)T" + String(format: "%02d_%02d", minute / 60, minute % 60) + ".json.gz"
                    await DeutscheBoerse.pace.wait()
                    budget -= 1
                    guard let trades = await DeutscheBoerse.trades(file: name, venue: venue, wanted: wanted) else {
                        failures += 1
                        continue
                    }
                    for trade in trades { DeutscheBoerse.apply(trade, venue: venue, to: &state) }
                    state.read[venue.rawValue, default: []].insert(minute)
                }
            }
            let left = open.values.reduce(0) { $0 + $1.count }
            DeutscheBoerse.log("round done: newest minute \(newest), \(left) minute files still to read, last \(state.last.mapValues(\.count))")
            backlog = left
            save()
        }

        private var dailyChecked: [String: String] = [:]
        private(set) var backlog = 0
    }

    /// Minutes of the day (UTC) in which Xetra publishes its closing auction, 17:35 to 17:38 in Frankfurt.
    static func closingAuction(on day: Date) -> Set<Int> {
        let offset = (TimeZone(identifier: "Europe/Berlin")?.secondsFromGMT(for: day) ?? 3_600) / 60
        let start = 17 * 60 + 35 - offset
        return Set(start...(start + 3))
    }

    /// Requests per round; rounds follow each other at the refresh interval of one minute.
    static let requestsPerRound = 18
    /// Trading on these venues starts no earlier than 06:00 UTC.
    static let firstMinute = 6 * 60
    /// How far back today's minutes are read: the whole day on the Mac, two hours on iPhone and iPad
    /// to keep mobile data use low (enough for the latest price of anything traded in that time).
    #if os(iOS)
    static let lookBack = 120
    #else
    static let lookBack = 24 * 60
    #endif

    /// Leaves at least 2.2 seconds between requests to the file service.
    private actor Pace {
        private var last = Date.distantPast

        func wait() async {
            let gap = Date().timeIntervalSince(last)
            if gap < 2.2 { try? await Task.sleep(for: .seconds(2.2 - gap)) }
            last = Date()
        }
    }

    private static let pace = Pace()

    /// Progress notes on standard error when DEPOTTICKER_DEBUG is set.
    static func log(_ text: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["DEPOTTICKER_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data(("boerse " + text() + "\n").utf8))
    }

    private static let engine = Engine()

    // MARK: Lookup

    /// Venues in the order they are tried for a symbol: its home venue first.
    static func venues(for symbol: String) -> [Venue] {
        if symbol.hasSuffix(".DE") { return [.xetra, .tradegate, .frankfurt] }
        if symbol.hasSuffix(".F") { return [.frankfurt, .tradegate, .xetra] }
        return [.tradegate, .xetra, .frankfurt]
    }

    private struct Found {
        var venue: Venue
        var isin: String
        var price: Double
        var previous: Double?
        var late: Double?
    }

    private static func find(_ symbol: String, in state: State) -> Found? {
        guard let isin = MarketData.isin(for: symbol) else { return nil }
        for venue in venues(for: symbol) {
            let v = venue.rawValue
            let last = state.last[v]?[isin], late = state.late[v]?[isin], previous = state.previous[v]?[isin]
            guard let price = last?.price ?? late?.price ?? previous else { continue }
            let extended = last != nil && (late?.time ?? 0) > (last?.time ?? 0) ? late?.price : nil
            return Found(venue: venue, isin: isin, price: price, previous: previous, late: extended)
        }
        return nil
    }

    /// Always works on all of the user's ISINs at once, whatever symbol was asked for: the files are
    /// filtered while they are read, so a later addition would mean reading them all again.
    private static func refreshed(_ asked: [String]) async -> State {
        let registered = MarketData.registeredISINs
        let symbols = Array(registered.keys)
        let isins = Set(registered.values)
        guard !isins.isEmpty, asked.contains(where: { registered[$0] != nil }) else { return await engine.snapshot() }
        let venues = Venue.allCases
        let known = await engine.snapshot()
        let ready = isins.isSubset(of: known.tracked) && venues.contains { !(known.daily[$0.rawValue] ?? "").isEmpty }
        if ready, !blocking {
            // Prices are already there: show them now and fetch the next files in the background.
            Task.detached(priority: .utility) { await engine.update(isins: isins, venues: venues) }
            return known
        }
        _ = symbols
        await engine.update(isins: isins, venues: venues)
        return await engine.snapshot()
    }

    /// Tests wait for every round instead of reading in the background.
    static var blocking = false

    /// Minute files of today that have not been read yet.
    static func backlog() async -> Int { await engine.backlog }

    // MARK: Source interface

    static func quotes(_ symbols: [String]) async throws -> [String: LiveQuote] {
        let state = await refreshed(symbols)
        var out: [String: LiveQuote] = [:]
        for symbol in symbols {
            guard let found = find(symbol, in: state) else { continue }
            let bars = state.bars[found.venue.rawValue]?[found.isin] ?? []
            out[symbol] = LiveQuote(price: found.price, previousClose: found.previous ?? found.price,
                                    spark: bars.map(\.price), extendedPrice: found.late)
        }
        return out
    }

    private static func points(_ symbol: String, range: ChartRange, state: State) throws -> PriceSeries {
        guard let found = find(symbol, in: state) else { throw MarketDataError.unknownSymbol }
        let v = found.venue.rawValue
        if range == .day {
            let bars = (state.bars[v]?[found.isin] ?? []).map { ChartPoint(date: $0.date, price: $0.price) }
            guard !bars.isEmpty else { throw MarketDataError.noHistory }
            return PriceSeries(points: bars, previousClose: found.previous)
        }
        var closes = (state.history[v]?[found.isin] ?? [:]).compactMap { day, price -> ChartPoint? in
            date(day + "T12:00:00").map { ChartPoint(date: $0, price: price) }
        }
        if let today = state.day[v], let stamp = date(today + "T12:00:00"), let last = state.last[v]?[found.isin] {
            closes.removeAll { $0.date == stamp }
            closes.append(ChartPoint(date: stamp, price: last.price))
        }
        closes.sort { $0.date < $1.date }
        let now = Date()
        let start: Date
        switch range {
        case .week: start = now.addingTimeInterval(-7 * 86_400)
        case .month: start = now.addingTimeInterval(-31 * 86_400)
        case .quarter: start = now.addingTimeInterval(-92 * 86_400)
        case .half: start = now.addingTimeInterval(-183 * 86_400)
        case .ytd: start = utc.date(from: DateComponents(year: utc.component(.year, from: now), month: 1, day: 1)) ?? now
        case .year: start = now.addingTimeInterval(-366 * 86_400)
        case .fiveYears: start = now.addingTimeInterval(-5 * 366 * 86_400)
        default: start = .distantPast
        }
        let slice = closes.filter { $0.date >= start }
        guard slice.count > 1 else { throw MarketDataError.noHistory }
        return PriceSeries(points: slice, previousClose: closes.last { $0.date < start }?.price)
    }

    static func series(_ symbols: [String], range: ChartRange) async -> [String: PriceSeries] {
        let state = await refreshed(symbols)
        var out: [String: PriceSeries] = [:]
        for symbol in symbols {
            if let series = try? points(symbol, range: range, state: state) { out[symbol] = series }
        }
        return out
    }

    static func chart(_ symbol: String, range: ChartRange) async throws -> ChartData {
        guard MarketData.isin(for: symbol) != nil else { throw MarketDataError.missingISIN }
        let state = await refreshed([symbol])
        guard let found = find(symbol, in: state) else { throw MarketDataError.unknownSymbol }
        let v = found.venue.rawValue
        let bars = state.bars[v]?[found.isin] ?? []
        let meta = SymbolMeta(
            symbol: symbol, name: symbol, currency: state.currency[found.isin] ?? "EUR", scale: 1,
            exchange: found.venue.title,
            open: range == .day ? bars.first?.price : nil,
            dayHigh: bars.map(\.price).max(), dayLow: bars.map(\.price).min(),
            volume: state.volume[v]?[found.isin],
            week52High: nil, week52Low: nil,
            previousClose: range == .day ? found.previous : nil)
        // The identity (currency, venue) is known even while the chart itself has no history yet.
        let series = try? points(symbol, range: range, state: state)
        if series == nil, range != .day { throw MarketDataError.noHistory }
        return ChartData(meta: meta, points: series?.points ?? [],
                         previousClose: range == .day ? found.previous : series?.previousClose, session: nil)
    }

    /// Whether the files of the previous days have been read for every venue (so a share without a
    /// price really was not traded there), and which of the symbols have a price.
    static func coverage(_ symbols: [String]) async -> (settled: Bool, found: Set<String>) {
        let state = await engine.snapshot()
        let isins = Set(MarketData.registeredISINs.values)
        let settled = isins.isSubset(of: state.tracked)
            && Venue.allCases.allSatisfy { !(state.daily[$0.rawValue] ?? "").isEmpty }
        return (settled, Set(symbols.filter { find($0, in: state) != nil }))
    }

    /// The closes collected on this device so far (possibly a single one), with their currency.
    static func collected(_ symbol: String) async -> DailyHistory? {
        let state = await engine.snapshot()
        guard let found = find(symbol, in: state) else { return nil }
        let v = found.venue.rawValue
        var closes = (state.history[v]?[found.isin] ?? [:]).compactMap { day, price -> ChartPoint? in
            date(day + "T12:00:00").map { ChartPoint(date: $0, price: price) }
        }
        if let today = state.day[v], let stamp = date(today + "T12:00:00"), let last = state.last[v]?[found.isin] {
            closes.removeAll { $0.date == stamp }
            closes.append(ChartPoint(date: stamp, price: last.price))
        }
        closes.sort { $0.date < $1.date }
        return DailyHistory(currency: state.currency[found.isin] ?? "EUR", points: closes)
    }

    /// The closing prices collected so far. Not enough for estimating purchase dates.
    static func dailyHistory(_ symbol: String) async throws -> DailyHistory {
        let state = await refreshed([symbol])
        guard let found = find(symbol, in: state) else { throw MarketDataError.unknownSymbol }
        let series = try points(symbol, range: .max, state: state)
        return DailyHistory(currency: state.currency[found.isin] ?? "EUR", points: series.points)
    }
}
