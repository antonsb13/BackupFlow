import XCTest
@testable import BackupFlow

final class LogTrimmingTests: XCTestCase {

    func testShortLogIsUnchanged() {
        XCTAssertEqual(BackupViewModel.trimmedLog("a\nb\n", maxBytes: 100, keepBytes: 50), "a\nb\n")
    }

    func testLongLogKeepsTheTailFromALineBoundary() {
        let lines = (0..<100).map { "line \($0)\n" }.joined()
        let trimmed = BackupViewModel.trimmedLog(lines, maxBytes: 200, keepBytes: 100)

        XCTAssertLessThanOrEqual(trimmed.utf8.count, 100)
        XCTAssertTrue(trimmed.hasPrefix("line "), "must start at a whole line, got: \(trimmed.prefix(12))")
        XCTAssertTrue(trimmed.hasSuffix("line 99\n"))
    }

    /// Cutting by bytes must never split a multi-byte character (Cyrillic paths in the log).
    func testMultibyteTextIsNotSplit() {
        let lines = (0..<200).map { "✓ /Volumes/Диск/Отчёт \($0).txt\n" }.joined()
        let trimmed = BackupViewModel.trimmedLog(lines, maxBytes: 1_000, keepBytes: 500)

        XCTAssertFalse(trimmed.contains("\u{FFFD}"))
        XCTAssertTrue(trimmed.hasPrefix("✓ /Volumes/Диск/"))
        XCTAssertLessThanOrEqual(trimmed.utf8.count, 500)
    }

    /// A single line longer than the budget still yields the newest bytes rather than nothing.
    func testOneHugeLineFallsBackToARawTail() {
        let huge = String(repeating: "x", count: 1_000)
        let trimmed = BackupViewModel.trimmedLog(huge, maxBytes: 200, keepBytes: 100)
        XCTAssertEqual(trimmed, String(repeating: "x", count: 100))
    }
}

final class DirectorySizeTests: XCTestCase {

    func testSumsVisibleFilesRecursivelyAndSkipsHiddenOnes() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("BackupFlowTests-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Папка/sub"), withIntermediateDirectories: true)
        try Data(count: 100).write(to: root.appendingPathComponent("a.bin"))
        try Data(count: 250).write(to: root.appendingPathComponent("Папка/sub/b.bin"))
        try Data(count: 999).write(to: root.appendingPathComponent(".hidden"))

        let size = await BackupViewModel.directorySize(of: root)

        XCTAssertEqual(size, 350)
    }

    func testMissingFolderIsZero() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("BackupFlowTests-missing-\(UUID().uuidString)")
        let size = await BackupViewModel.directorySize(of: missing)
        XCTAssertEqual(size, 0)
    }
}
