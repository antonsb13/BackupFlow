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

final class WeightedProgressTests: XCTestCase {

    private let a = UUID(), b = UUID(), c = UUID()

    /// The regression this whole mechanism exists for: a task carrying `.success` from a
    /// PREVIOUS sync is simply absent from `fractions`, so it must contribute nothing.
    func testTasksNotInSessionContributeNothing() {
        let weights: [UUID: Int64] = [a: 100, b: 100, c: 100]
        // Only `a` has actually done any work this session.
        let progress = SyncEngine.weightedProgress(fractions: [a: 1.0], weights: weights)
        XCTAssertEqual(progress, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testEqualWeightsHalfDone() {
        let weights: [UUID: Int64] = [a: 50, b: 50]
        let progress = SyncEngine.weightedProgress(fractions: [a: 1.0, b: 0.0], weights: weights)
        XCTAssertEqual(progress, 0.5, accuracy: 0.0001)
    }

    func testWeightingIsProportionalToBytes() {
        // `a` is 9x larger than `b`, so finishing `b` alone barely moves the needle.
        let weights: [UUID: Int64] = [a: 900, b: 100]
        let progress = SyncEngine.weightedProgress(fractions: [b: 1.0], weights: weights)
        XCTAssertEqual(progress, 0.1, accuracy: 0.0001)
    }

    func testAllComplete() {
        let weights: [UUID: Int64] = [a: 10, b: 30]
        let progress = SyncEngine.weightedProgress(fractions: [a: 1.0, b: 1.0], weights: weights)
        XCTAssertEqual(progress, 1.0, accuracy: 0.0001)
    }

    func testOvershootAndNegativeFractionsAreClamped() {
        let weights: [UUID: Int64] = [a: 100, b: 100]
        // A task can report more bytes than estimated; it must not inflate the total.
        let progress = SyncEngine.weightedProgress(fractions: [a: 5.0, b: -2.0], weights: weights)
        XCTAssertEqual(progress, 0.5, accuracy: 0.0001)
    }

    func testUnknownIdsAreIgnored() {
        let weights: [UUID: Int64] = [a: 100]
        let progress = SyncEngine.weightedProgress(fractions: [a: 1.0, b: 1.0], weights: weights)
        XCTAssertEqual(progress, 1.0, accuracy: 0.0001)
    }

    func testEmptySessionIsZero() {
        XCTAssertEqual(SyncEngine.weightedProgress(fractions: [:], weights: [:]), 0.0)
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
