import Foundation

// MARK: - Sync Status

enum SyncStatus: String, Codable, Equatable {
    case idle       = "Idle"
    case calculating = "Calculating..."
    case syncing    = "Syncing"
    case verifying  = "Verifying"
    case success    = "Synced"
    case failed     = "Failed"
    case aborted    = "Aborted"
}

// MARK: - Backup Task

struct BackupTask: Identifiable, Codable, Equatable {
    var id: UUID = UUID()

    /// Display name (last path component of the selected folder)
    var folderName: String

    /// Path relative to the main drive root, e.g. "Documents/Projects"
    var relativePath: String

    /// Security-scoped bookmark for the folder; nil for non-sandboxed builds
    var bookmarkData: Data?

    var status: SyncStatus = .idle
    var progress: Double = 0.0 // 0.0 to 1.0
    var lastSyncDate: Date?
    var targetBytes: Int64 = 1 // Prevent div/0 defaults
    
    // UI Metadata
    var sizeBytes: Int64?
    var isMissingOnBackup: Bool = false
}
