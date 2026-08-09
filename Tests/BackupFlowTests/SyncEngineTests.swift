import XCTest
@testable import BackupFlow

final class SyncEngineOutcomeTests: XCTestCase {

    func testExitCodeZeroIsSuccess() {
        XCTAssertEqual(SyncEngine.outcome(forExitCode: 0), .success)
    }

    func testExitCode23IsWarnings() {
        // rsync's "partial transfer due to error" — must not be treated as a clean success.
        XCTAssertEqual(SyncEngine.outcome(forExitCode: 23), .warnings)
    }

    func testOtherExitCodesAreFailure() {
        XCTAssertEqual(SyncEngine.outcome(forExitCode: 1), .failure)
        XCTAssertEqual(SyncEngine.outcome(forExitCode: 130), .failure)
    }

    func testDidCompleteReflectsOutcome() {
        XCTAssertTrue(SyncOutcome.success.didComplete)
        XCTAssertTrue(SyncOutcome.warnings.didComplete)
        XCTAssertFalse(SyncOutcome.failure.didComplete)
    }
}

final class SyncEngineParsingTests: XCTestCase {

    func testParseTotalTransferredBytes() {
        let stats = """
        Number of files: 10
        Total transferred file size: 123,456 bytes
        """
        XCTAssertEqual(SyncEngine.parseTotalTransferredBytes(from: stats), 123_456)
    }

    func testParseTotalTransferredBytesMissing() {
        XCTAssertEqual(SyncEngine.parseTotalTransferredBytes(from: "no stats here"), 0)
    }

    func testParseDeletionPaths() {
        let output = """
        *deleting   OldFolder/oldfile.txt
        .d..t...... OldFolder/
        *deleting   .DS_Store
        """
        XCTAssertEqual(
            SyncEngine.parseDeletionPaths(from: output),
            ["OldFolder/oldfile.txt", ".DS_Store"]
        )
    }

    func testParseDeletionPathsIgnoresRootAndEmpty() {
        let output = """
        *deleting   .
        *deleting   ./
        """
        XCTAssertTrue(SyncEngine.parseDeletionPaths(from: output).isEmpty)
    }
}
