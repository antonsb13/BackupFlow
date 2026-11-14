import XCTest
@testable import BackupFlow

final class TransferPreviewParsingTests: XCTestCase {

    /// `rsync -n -i --stats` output as printed by macOS 15 openrsync.
    func testParsesDeletionsBytesAndSourceEntries() {
        let output = """
        Transfer starting: 4 files
        *deleting old
        >f+++++++ a
        cd+++++++ d/
        >f+++++++ d/b
        Number of files: 4
        Number of files transferred: 2
        Total file size: 8 B
        Total transferred file size: 8 B
        """
        XCTAssertEqual(
            SyncEngine.parseTransferPreview(from: output),
            TransferPreview(transferBytes: 8, deletions: ["old"], sourceEntryCount: 3)
        )
    }

    /// The source root itself is counted as one file: an empty source reports 1.
    func testEmptySourceHasZeroEntries() {
        XCTAssertEqual(SyncEngine.parseTransferPreview(from: "Number of files: 1").sourceEntryCount, 0)
    }

    /// rsync 3 style: thousands separators and a breakdown in parentheses.
    func testSourceEntryCountWithSeparatorsAndBreakdown() {
        let output = "Number of files: 1,235 (reg: 1,000, dir: 235)\nNumber of files transferred: 7"
        XCTAssertEqual(SyncEngine.parseTransferPreview(from: output).sourceEntryCount, 1_234)
    }
}

final class MassDeletionTests: XCTestCase {

    private func preview(deleting count: Int, sourceEntries: Int) -> TransferPreview {
        TransferPreview(transferBytes: 0, deletions: (0..<count).map { "f\($0)" }, sourceEntryCount: sourceEntries)
    }

    func testNoDeletionsIsNeverMass() {
        XCTAssertFalse(preview(deleting: 0, sourceEntries: 0).isMassDeletion)
    }

    /// The classic mirror disaster: an empty or unmounted-looking source wipes the backup.
    func testAnyDeletionFromAnEmptySourceIsMass() {
        XCTAssertTrue(preview(deleting: 1, sourceEntries: 0).isMassDeletion)
    }

    func testRoutineCleanupIsNotMass() {
        XCTAssertFalse(preview(deleting: 99, sourceEntries: 10).isMassDeletion, "below the absolute minimum")
        XCTAssertFalse(preview(deleting: 500, sourceEntries: 5_000).isMassDeletion, "a small share of the destination")
    }

    func testDeletingMostOfTheDestinationIsMass() {
        XCTAssertTrue(preview(deleting: 100, sourceEntries: 99).isMassDeletion)
        XCTAssertFalse(preview(deleting: 100, sourceEntries: 100).isMassDeletion, "exactly half is not more than half")
    }
}

final class FolderPathTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/Volumes/Data")

    func testFolderInsideRoot() {
        XCTAssertEqual(BackupViewModel.relativePath(of: URL(fileURLWithPath: "/Volumes/Data/Docs/Projects"), inside: root),
                       "Docs/Projects")
    }

    func testRootItselfIsEmptyPath() {
        XCTAssertEqual(BackupViewModel.relativePath(of: URL(fileURLWithPath: "/Volumes/Data/"), inside: root), "")
    }

    /// Used to fall back to `lastPathComponent`, silently syncing a different `main/<name>`
    /// folder with --delete.
    func testFolderOutsideRootIsRejected() {
        XCTAssertNil(BackupViewModel.relativePath(of: URL(fileURLWithPath: "/Users/me/Projects"), inside: root))
    }

    /// `hasPrefix` treated `/Volumes/Data2` as being inside `/Volumes/Data`.
    func testSiblingWithSharedPrefixIsRejected() {
        XCTAssertNil(BackupViewModel.relativePath(of: URL(fileURLWithPath: "/Volumes/Data2/Docs"), inside: root))
    }

    func testSymlinkPointingOutsideRootIsRejected() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("BackupFlowTests-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: base) }
        let disk = base.appendingPathComponent("disk")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: disk, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = disk.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertNil(BackupViewModel.relativePath(of: link, inside: disk))
    }
}

final class VolumeMatchingTests: XCTestCase {

    func testURLOnVolume() {
        let volume = URL(fileURLWithPath: "/Volumes/Backup")
        XCTAssertTrue(BackupViewModel.isURL(URL(fileURLWithPath: "/Volumes/Backup"), onVolume: volume))
        XCTAssertTrue(BackupViewModel.isURL(URL(fileURLWithPath: "/Volumes/Backup/Sub"), onVolume: volume))
    }

    /// Unmounting "Backup 2" used to clear the "Backup" drive too.
    func testVolumeWithSharedPrefixDoesNotMatch() {
        XCTAssertFalse(BackupViewModel.isURL(URL(fileURLWithPath: "/Volumes/Backup 2"),
                                             onVolume: URL(fileURLWithPath: "/Volumes/Backup")))
    }

    func testRootVolumeNeverMatches() {
        XCTAssertFalse(BackupViewModel.isURL(URL(fileURLWithPath: "/Volumes/Backup"), onVolume: URL(fileURLWithPath: "/")))
    }
}

final class VolumeIdentityTests: XCTestCase {

    func testNoBaselineYet() {
        XCTAssertEqual(BackupViewModel.volumeIdentity(stored: nil, current: "A"), .noBaseline)
    }

    func testMatchAndMismatch() {
        XCTAssertEqual(BackupViewModel.volumeIdentity(stored: "A", current: "A"), .match)
        XCTAssertEqual(BackupViewModel.volumeIdentity(stored: "A", current: "B"), .mismatch)
    }

    /// Used to pass ("fail open") when the current UUID could not be read.
    func testUnreadableUUIDIsAMismatch() {
        XCTAssertEqual(BackupViewModel.volumeIdentity(stored: "A", current: nil), .mismatch)
    }
}

final class SyncHistoryResetTests: XCTestCase {

    /// Reconnecting or re-selecting the same disk used to wipe all "last synced" dates.
    func testSameDiskKeepsHistory() {
        XCTAssertFalse(BackupViewModel.shouldClearHistory(previousUUID: "A", newUUID: "A"))
    }

    func testDifferentOrUnknownDiskClearsHistory() {
        XCTAssertTrue(BackupViewModel.shouldClearHistory(previousUUID: "A", newUUID: "B"))
        XCTAssertTrue(BackupViewModel.shouldClearHistory(previousUUID: nil, newUUID: "B"))
        XCTAssertTrue(BackupViewModel.shouldClearHistory(previousUUID: "A", newUUID: nil))
    }
}
