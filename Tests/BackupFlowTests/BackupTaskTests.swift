import XCTest
@testable import BackupFlow

final class BackupTaskCodableTests: XCTestCase {

    func testRoundTrip() throws {
        var task = BackupTask(folderName: "Documents", relativePath: "Documents", bookmarkData: nil)
        task.status = .success
        task.sizeBytes = 42
        task.isMissingOnBackup = true

        let data = try JSONEncoder().encode([task])
        let decoded = try JSONDecoder().decode([BackupTask].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].folderName, "Documents")
        XCTAssertEqual(decoded[0].relativePath, "Documents")
        XCTAssertEqual(decoded[0].status, .success)
        XCTAssertEqual(decoded[0].sizeBytes, 42)
        XCTAssertTrue(decoded[0].isMissingOnBackup)
    }
}

@MainActor
final class SyncHistoryManagerTests: XCTestCase {

    override func tearDown() {
        // XCTest always runs setUp/tearDown on the main thread; assumeIsolated bridges that
        // known-but-unstated fact to the statically main-actor-isolated SyncHistoryManager.
        MainActor.assumeIsolated {
            SyncHistoryManager.shared.clear()
        }
        super.tearDown()
    }

    func testRecordAndRetrieveDate() {
        SyncHistoryManager.shared.clear()
        XCTAssertNil(SyncHistoryManager.shared.date(for: "/Volumes/Test/Folder"))

        SyncHistoryManager.shared.record(absolutePath: "/Volumes/Test/Folder")
        XCTAssertNotNil(SyncHistoryManager.shared.date(for: "/Volumes/Test/Folder"))
    }

    func testClearRemovesAllHistory() {
        SyncHistoryManager.shared.record(absolutePath: "/Volumes/Test/Folder")
        SyncHistoryManager.shared.clear()
        XCTAssertNil(SyncHistoryManager.shared.date(for: "/Volumes/Test/Folder"))
    }
}
