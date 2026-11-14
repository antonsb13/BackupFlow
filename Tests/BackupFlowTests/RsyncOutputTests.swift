import XCTest
@testable import BackupFlow

/// Regression tests for the Deletion Guard bypass: macOS 15's openrsync escapes the bytes
/// 0x80–0x9F as `\#NNN` (octal). In UTF-8 that splits most Cyrillic letters, so the raw output
/// was not valid UTF-8, `String(data:encoding:)` returned nil for the WHOLE output, and the guard
/// reported "no deletions" right before `rsync --delete` removed files unconfirmed.
final class RsyncOutputDecodingTests: XCTestCase {

    /// Escapes bytes the way openrsync does (verified against /usr/bin/rsync on macOS 15).
    private func openrsyncEscaped(_ text: String) -> Data {
        var data = Data()
        for byte in Data(text.utf8) {
            if (0x80...0x9F).contains(byte) || byte == UInt8(ascii: "\\") {
                data.append(contentsOf: Data(String(format: "\\#%03o", byte).utf8))
            } else {
                data.append(byte)
            }
        }
        return data
    }

    func testDecodesOpenrsyncOctalEscapesInCyrillicNames() {
        let raw = openrsyncEscaped("*deleting Привет.txt")
        XCTAssertNil(String(data: raw, encoding: .utf8), "precondition: raw openrsync output is not valid UTF-8")
        XCTAssertEqual(SyncEngine.decodeRsyncOutput(raw), "*deleting Привет.txt")
    }

    func testDecodesEscapedBackslash() {
        XCTAssertEqual(SyncEngine.decodeRsyncOutput(Data(##"a\#134#101.txt"##.utf8)), ##"a\#101.txt"##)
    }

    func testLeavesBackslashesThatAreNotEscapesAlone() {
        XCTAssertEqual(SyncEngine.decodeRsyncOutput(Data(##"a\b \#9z \#999"##.utf8)), ##"a\b \#9z \#999"##)
    }

    func testInvalidBytesDoNotDropTheRestOfTheOutput() {
        let decoded = SyncEngine.decodeRsyncOutput(Data([0x61, 0xFF, 0x0A, 0x62]))
        XCTAssertTrue(decoded.hasPrefix("a"))
        XCTAssertTrue(decoded.hasSuffix("\nb"))
    }
}

final class RsyncLineBufferTests: XCTestCase {

    func testJoinsLinesSplitAcrossChunks() {
        let buffer = RsyncLineBuffer()
        XCTAssertEqual(buffer.append(Data("Hel".utf8)), [])
        XCTAssertEqual(buffer.append(Data("lo\nWor".utf8)), ["Hello"])
        XCTAssertEqual(buffer.finish(), ["Wor"])
        XCTAssertEqual(buffer.finish(), [])
    }

    func testMultibyteCharacterSplitAcrossChunks() {
        let bytes = Array("Привет\n".utf8)
        let buffer = RsyncLineBuffer()
        XCTAssertEqual(buffer.append(Data(bytes[..<3])), [])
        XCTAssertEqual(buffer.append(Data(bytes[3...])), ["Привет"])
    }

    func testCarriageReturnSeparatesProgressUpdatesAndEmptyLinesAreDropped() {
        let buffer = RsyncLineBuffer()
        XCTAssertEqual(buffer.append(Data("  100  10%\r  200  20%\r\n\nnext\n".utf8)),
                       ["  100  10%", "  200  20%", "next"])
    }

    func testDecodesEscapesInsideLines() {
        let buffer = RsyncLineBuffer()
        XCTAssertEqual(buffer.append(Data((##"a\#134b"## + "\n").utf8)), [##"a\b"##])
    }
}

final class DeletionParsingRegressionTests: XCTestCase {

    /// `>f+++…` is a transfer, not a deletion — it used to be reported as deleting "file.txt".
    func testTransferWhoseNameContainsDeletingIsNotADeletion() {
        XCTAssertEqual(SyncEngine.parseDeletionPaths(from: ">f+++++++ new deleting file.txt"), [])
    }

    /// Names containing `*` used to be skipped by the guard while rsync still deleted them.
    func testNamesWithAsteriskAreReported() {
        XCTAssertEqual(SyncEngine.parseDeletionPaths(from: "*deleting old*.txt"), ["old*.txt"])
    }

    func testOpenrsyncSingleSpaceFormatWithDirectories() {
        let output = """
        Transfer starting: 3 files
        *deleting Old/
        *deleting Old/a.txt
        >f+++++++ kept.txt
        """
        XCTAssertEqual(SyncEngine.parseDeletionPaths(from: output), ["Old/", "Old/a.txt"])
    }
}

final class TopLevelExcludeTests: XCTestCase {

    func testPlainNamesAreAnchoredDirectoryExcludes() {
        XCTAssertEqual(SyncEngine.topLevelExcludeFlags(for: ["Projects", "My Movies"]),
                       ["--exclude=/Projects/", "--exclude=/My Movies/"])
    }

    /// rsync treats backslash as an escape only when the pattern has a wildcard (verified
    /// against openrsync), so plain names must be passed verbatim.
    func testBackslashWithoutWildcardIsVerbatim() {
        XCTAssertEqual(SyncEngine.topLevelExcludeFlags(for: [#"b\s"#]), [#"--exclude=/b\s/"#])
    }

    func testWildcardsAreEscaped() {
        XCTAssertEqual(SyncEngine.topLevelExcludeFlags(for: ["a*", "q?[1]", #"c\[x"#]),
                       [#"--exclude=/a\*/"#, #"--exclude=/q\?\[1]/"#, #"--exclude=/c\\\[x/"#])
    }
}

/// Runs the real /usr/bin/rsync (openrsync on macOS 15) against temporary directories.
final class SyncEngineDryRunIntegrationTests: XCTestCase {

    private var root: URL!
    private var src: URL!
    private var dst: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try XCTSkipUnless(fm.isExecutableFile(atPath: "/usr/bin/rsync"), "system rsync not available")
        root = fm.temporaryDirectory.appendingPathComponent("BackupFlowTests-\(UUID().uuidString)")
        src = root.appendingPathComponent("src")
        dst = root.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try fm.removeItem(at: root) }
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Writes an executable stand-in for rsync that prints fixed output and exits with `code`.
    private func fakeRsync(stdout: String, exitCode code: Int32) throws -> URL {
        let url = root.appendingPathComponent("fake-rsync")
        try Data("#!/bin/sh\nprintf '%s\\n' '\(stdout)'\necho 'simulated failure' >&2\nexit \(code)\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testPreviewReportsCyrillicAndAsteriskDeletions() async throws {
        try write("a", to: dst.appendingPathComponent("Привет.txt"))
        try write("b", to: dst.appendingPathComponent("old*.txt"))

        let preview = try await SyncEngine().previewTransfer(from: src, to: dst, useChecksum: false)

        XCTAssertEqual(Set(preview.deletions), ["Привет.txt", "old*.txt"])
        XCTAssertEqual(preview.sourceEntryCount, 0)
        XCTAssertTrue(preview.isMassDeletion, "deleting from an empty source must be flagged")
        for path in preview.deletions {
            XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent(path).path),
                          "guard path must resolve to the real file so approved deletions can be applied: \(path)")
        }
    }

    func testPreviewTransferSizeWithCyrillicNamesAndLongOutput() async throws {
        for i in 0..<400 { try write("0123456789", to: src.appendingPathComponent("Папка/Отчёт \(i).txt")) }

        let preview = try await SyncEngine().previewTransfer(from: src, to: dst, useChecksum: false)

        XCTAssertEqual(preview.transferBytes, 4_000)
        XCTAssertEqual(preview.sourceEntryCount, 401, "400 files plus their folder")
        XCTAssertEqual(preview.deletions, [])
    }

    func testPreviewHonoursTopLevelExcludes() async throws {
        try write("x", to: dst.appendingPathComponent("Keep*/file.txt"))
        try write("y", to: dst.appendingPathComponent("Gone/file.txt"))

        let preview = try await SyncEngine().previewTransfer(
            from: src, to: dst, useChecksum: false, excludingTopLevelFolders: ["Keep*"]
        )

        XCTAssertTrue(preview.deletions.contains("Gone/file.txt"))
        XCTAssertFalse(preview.deletions.contains { $0.hasPrefix("Keep") })
    }

    /// Fail closed: a failed dry run must never look like "nothing to delete".
    func testPreviewThrowsWhenRsyncFails() async throws {
        let engine = SyncEngine(rsyncURL: try fakeRsync(stdout: "*deleting x", exitCode: 12))

        do {
            _ = try await engine.previewTransfer(from: src, to: dst, useChecksum: false)
            XCTFail("expected previewTransfer to throw")
        } catch let RsyncError.failed(exitCode, details) {
            XCTAssertEqual(exitCode, 12)
            XCTAssertTrue(details.contains("simulated failure"))
        }
    }

    func testPreviewThrowsWhenRsyncCannotLaunch() async {
        let engine = SyncEngine(rsyncURL: root.appendingPathComponent("missing-rsync"))
        do {
            _ = try await engine.previewTransfer(from: src, to: dst, useChecksum: false)
            XCTFail("expected a launch failure")
        } catch RsyncError.launchFailed {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Exit 23 (partial transfer) still produced a complete deletion list — the real run
    /// would delete the same paths, so the guard must show them rather than abort.
    func testPreviewAcceptsPartialTransferExitCode() async throws {
        let engine = SyncEngine(rsyncURL: try fakeRsync(stdout: "*deleting stale.txt", exitCode: 23))
        let preview = try await engine.previewTransfer(from: src, to: dst, useChecksum: false)
        XCTAssertEqual(preview.deletions, ["stale.txt"])
    }

    func testSyncFolderLogsCyrillicNames() async throws {
        try write("data", to: src.appendingPathComponent("Проект/Отчёт.txt"))
        let lines = LockedLines()

        let outcome = await SyncEngine().syncFolder(
            relativePath: "Проект",
            mainRoot: src,
            secondaryRoot: dst,
            useChecksum: false,
            onOutput: { lines.append($0) }
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertTrue(lines.joined.contains("Отчёт.txt"), "log was: \(lines.joined)")
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("Проект/Отчёт.txt").path))
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(line)
    }

    var joined: String {
        lock.lock()
        defer { lock.unlock() }
        return storage.joined()
    }
}
