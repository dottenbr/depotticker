import Foundation

/// Joins the portfolios that arrive through iCloud with this device's own, against the copy both
/// last agreed on (`base`). A change made on only one side is kept, whichever side made it, so edits
/// made on two devices while one was offline both survive. When both sides changed the same position,
/// the copy from iCloud wins: the other device already holds it, so taking it ends the exchange
/// instead of starting a tug of war. Such conflicts are counted so the caller can keep a backup.
enum CloudMerge {
    struct Outcome: Equatable {
        var portfolios: [Portfolio]
        /// Positions that both sides had changed differently.
        var conflicts: Int
    }

    static func merge(base: [Portfolio]?, local: [Portfolio], remote: [Portfolio]) -> Outcome {
        // Without a common copy (the first sync on this device), a portfolio set up on both devices
        // is recognised by its name and a position by its symbol, so nothing is listed twice.
        let local = base == nil ? adoptIdentities(of: remote, into: local) : local
        var conflicts = 0
        let portfolios = list(base: base ?? [], local: local, remote: remote, conflicts: &conflicts) { b, l, r, conflicts in
            var merged = r
            merged.name = pick(b?.name, l.name, r.name)
            merged.positions = list(base: b?.positions ?? [], local: l.positions, remote: r.positions,
                                    conflicts: &conflicts) { _, _, r, conflicts in
                conflicts += 1
                return r
            }
            return merged
        }
        return Outcome(portfolios: portfolios, conflicts: conflicts)
    }

    /// Three-way merge of a list by identity, in the remote order; what only this device has keeps its
    /// place after the item it followed here.
    private static func list<T: Identifiable & Equatable>(
        base: [T], local: [T], remote: [T], conflicts: inout Int,
        resolve: (T?, T, T, inout Int) -> T
    ) -> [T] {
        func index(_ items: [T]) -> [T.ID: T] { Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        let b = index(base), l = index(local), r = index(remote)
        var out: [T] = []
        for theirs in remote {
            let was = b[theirs.id]
            if let mine = l[theirs.id] {
                if mine == theirs || theirs == was { out.append(mine) }
                else if mine == was { out.append(theirs) }
                else { out.append(resolve(was, mine, theirs, &conflicts)) }
            } else if was == nil || theirs != was {
                // Removed here, unless it was never here or has been changed there since.
                out.append(theirs)
            }
        }
        for (position, mine) in local.enumerated() where r[mine.id] == nil {
            // Removed there, unless it was never there or has been changed here since.
            let was = b[mine.id]
            guard was == nil || mine != was else { continue }
            let before = local[..<position].last { item in out.contains { $0.id == item.id } }
            let at = before.flatMap { item in out.firstIndex { $0.id == item.id } }.map { $0 + 1 } ?? 0
            out.insert(mine, at: at)
        }
        return out
    }

    private static func pick<V: Equatable>(_ base: V?, _ local: V, _ remote: V) -> V {
        local == remote || remote == base ? local : remote
    }

    private static func adoptIdentities(of remote: [Portfolio], into local: [Portfolio]) -> [Portfolio] {
        local.map { mine in
            guard let theirs = remote.first(where: { $0.id == mine.id })
                    ?? remote.first(where: { $0.name.caseInsensitiveCompare(mine.name) == .orderedSame })
            else { return mine }
            var adopted = mine
            adopted.id = theirs.id
            adopted.positions = mine.positions.map { position in
                guard let match = theirs.positions.first(where: { $0.symbol.caseInsensitiveCompare(position.symbol) == .orderedSame })
                else { return position }
                var same = position
                same.id = match.id
                return same
            }
            return adopted
        }
    }
}
