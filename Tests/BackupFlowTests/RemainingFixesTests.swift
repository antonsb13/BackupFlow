import XCTest
@testable import BackupFlow

final class BookmarkManagerTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BackupFlowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // `try?`: a test may already have deleted the folder on purpose.
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRoundTrip() throws {
        let folder = try makeTempDirectory()
        let resolved = try BookmarkManager.resolveBookmark(try BookmarkManager.createBookmark(for: folder))
        XCTAssertEqual(resolved.url.standardizedFileURL.resolvingSymlinksInPath().path,
                       folder.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertFalse(resolved.isStale)
    }

    /// Resolution failures used to be swallowed into a bare `nil`.
    func testCorruptBookmarkThrows() {
        XCTAssertThrowsError(try BookmarkManager.resolveBookmark(Data("not a bookmark".utf8)))
    }

    func testMissingTargetIsReportedAsUnavailable() throws {
        let folder = try makeTempDirectory()
        let data = try BookmarkManager.createBookmark(for: folder)
        try FileManager.default.removeItem(at: folder)

        XCTAssertThrowsError(try BookmarkManager.resolveBookmark(data)) { error in
            XCTAssertTrue(BookmarkManager.isTargetUnavailable(error), "unexpected error: \(error)")
        }
    }
}

final class DeletionDecisionTests: XCTestCase {

    private let routine = TransferPreview(transferBytes: 0, deletions: ["old.txt"], sourceEntryCount: 50)
    private let mass = TransferPreview(transferBytes: 0, deletions: ["a"], sourceEntryCount: 0)
    private let nothing = TransferPreview(transferBytes: 0, deletions: [], sourceEntryCount: 50)

    private func decide(_ preview: TransferPreview, guardOn: Bool, unattended: Bool, applyToAll: Bool = false) -> BackupViewModel.DeletionDecision {
        BackupViewModel.deletionDecision(for: preview, confirmDeletions: guardOn, unattended: unattended, applyToAll: applyToAll)
    }

    func testNothingToDeleteAlwaysProceeds() {
        XCTAssertEqual(decide(nothing, guardOn: true, unattended: true), .proceed)
    }

    func testGuardOffProceedsUnlessMass() {
        XCTAssertEqual(decide(routine, guardOn: false, unattended: false), .proceed)
        XCTAssertEqual(decide(mass, guardOn: false, unattended: true), .blockMassDeletion)
    }

    func testGuardOnAsksTheUserInManualSyncs() {
        XCTAssertEqual(decide(routine, guardOn: true, unattended: false), .askUser)
        XCTAssertEqual(decide(routine, guardOn: true, unattended: false, applyToAll: true), .proceed)
    }

    /// A scheduled sync used to wait forever on a confirmation nobody was there to give.
    func testScheduledSyncDefersInsteadOfWaitingForAnAnswer() {
        XCTAssertEqual(decide(routine, guardOn: true, unattended: true), .deferUntilManualSync)
        XCTAssertEqual(decide(mass, guardOn: true, unattended: true), .deferUntilManualSync)
    }
}

final class ForceStopTests: XCTestCase {

    /// rsync used to get SIGTERM plus a SIGKILL "fallback" scheduled 1 s later in a detached
    /// task — but the app exits before that fires, so an rsync ignoring SIGTERM outlived it.
    func testForceStopKillsAProcessThatIgnoresSIGTERMBeforeReturning() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupFlowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: dir) }

        let pidFile = dir.appendingPathComponent("pid")
        let script = dir.appendingPathComponent("stubborn-rsync")
        try Data("""
        #!/bin/sh
        echo $$ > '\(pidFile.path)'
        trap '' TERM
        while true; do sleep 0.1; done

        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let engine = SyncEngine(rsyncURL: script)
        let run = Task {
            await engine.syncFolder(relativePath: "x", mainRoot: dir, secondaryRoot: dir, useChecksum: false, onOutput: { _ in })
        }

        var pid: pid_t?
        for _ in 0..<50 where pid == nil {
            try await Task.sleep(for: .milliseconds(50))
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let stubbornPID = try XCTUnwrap(pid, "stub never started")

        let start = ContinuousClock.now
        await engine.forceStopAll()
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))

        // The process must be gone (allowing a moment for Foundation to reap the zombie).
        var alive = true
        for _ in 0..<20 where alive {
            alive = kill(stubbornPID, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertFalse(alive, "rsync stand-in survived forceStopAll")

        let outcome = await run.value
        XCTAssertEqual(outcome, .failure)
    }
}
