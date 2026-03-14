import Foundation

/// Thread-safe singleton that persists folder sync dates keyed by absolute path.
/// This allows "Last Sync" dates to survive mode switches (Folders ↔ Full Disk).
final class SyncHistoryManager {

    static let shared = SyncHistoryManager()
    private init() { load() }

    private let udKey = "bf.syncHistory"
    private var history: [String: Date] = [:]

    // MARK: - Public API

    /// Record a successful sync for the given absolute folder path.
    func record(absolutePath: String) {
        history[absolutePath] = Date()
        save()
    }

    /// Retrieve the last successful sync date for a given absolute path. Returns nil if never synced.
    func date(for absolutePath: String) -> Date? {
        history[absolutePath]
    }

    // MARK: - Persistence

    private func save() {
        // Store as [String: Double] (timeIntervalSince1970) — plain-type serialization, no Codable needed
        let serialized = history.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(serialized, forKey: udKey)
    }

    private func load() {
        guard let raw = UserDefaults.standard.dictionary(forKey: udKey) as? [String: Double] else { return }
        history = raw.mapValues { Date(timeIntervalSince1970: $0) }
    }
}
