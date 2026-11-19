// iCloud sync of the portfolios (App Store builds).
import Foundation
import SwiftUI
import WidgetKit

extension Store {
    /// App Store builds share the portfolios between Mac, iPhone and iPad through iCloud.
    func startCloudSync() {
        guard PortfolioRepository.usesCloudStore else { return }
        let cloud = NSUbiquitousKeyValueStore.default
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            Task { @MainActor in self?.adoptCloudCopy(reason: reason) }
        }
        cloud.synchronize()
        adoptCloudCopy()
    }

    func adoptCloudCopy(reason: Int? = nil) {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: PortfolioRepository.cloudKey),
              let remote = PortfolioRepository.decode(data)
        else {
            // Nothing in iCloud yet: publish what this device has.
            if !portfolios.isEmpty {
                repository.save(portfolios)
                repository.saveSyncBase(portfolios)
            }
            return
        }
        let outcome: CloudMerge.Outcome
        if reason == NSUbiquitousKeyValueStoreAccountChange {
            // Another Apple Account: its portfolios replace this device's instead of being mixed in.
            outcome = .init(portfolios: remote, conflicts: remote == portfolios ? 0 : 1)
        } else {
            outcome = CloudMerge.merge(base: repository.loadSyncBase(), local: portfolios, remote: remote)
        }
        repository.saveSyncBase(outcome.portfolios)
        if outcome.portfolios != remote { repository.save(outcome.portfolios) }
        guard outcome.portfolios != portfolios else { return }
        if outcome.conflicts > 0 {
            repository.backup(portfolios)
            dataProblem = "\(outcome.conflicts) position\(outcome.conflicts == 1 ? " was" : "s were") changed on another device "
                + "at the same time. That version was kept; this device's is in portfolios.backup.json."
        }
        portfolios = outcome.portfolios
        if outcome.portfolios == remote { repository.save(outcome.portfolios, toCloud: false) }
        loadedStamp = repository.stamp()
        WidgetCenter.shared.reloadAllTimelines()
        invalidateHistories()
        Task { await refresh() }
    }
}
