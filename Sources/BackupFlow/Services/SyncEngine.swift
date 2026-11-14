import Foundation

/// Outcome of an rsync invocation, distinguishing a clean run from one that
/// completed but reported per-file problems (rsync exit code 23 — "partial
/// transfer due to error", e.g. permission denied or a file vanishing mid-run).
/// Exit code 23 used to be treated as a plain success, silently masking failed files.
enum SyncOutcome: Equatable, Sendable {
    case success
    case warnings
    case failure

    /// True for outcomes where the destination should be considered up to date
    /// (rsync ran to completion, even if some individual files had problems).
    var didComplete: Bool { self != .failure }
}

/// What a sync would do, from one `rsync -n -i --stats` dry run.
struct TransferPreview: Equatable, Sendable {
    /// Paths that must exist on the destination before a deletion counts as "mass" (unless
    /// the source is empty — then any deletion does).
    static let massDeletionMinimum = 100

    var transferBytes: Int64
    /// Destination paths, relative to the destination root, that `--delete` would remove.
    var deletions: [String]
    /// Files and folders in the source, not counting the source root itself.
    var sourceEntryCount: Int

    /// Deletions that look like a wrong or empty source rather than routine cleanup: anything
    /// deleted from an empty source, or at least `massDeletionMinimum` paths making up more than
    /// half of the destination (estimated as source entries plus deletions).
    var isMassDeletion: Bool {
        guard !deletions.isEmpty else { return false }
        if sourceEntryCount == 0 { return true }
        return deletions.count >= Self.massDeletionMinimum
            && deletions.count > sourceEntryCount
    }
}

/// Why rsync could not produce a usable result.
enum RsyncError: LocalizedError, Equatable {
    case launchFailed(String)
    case failed(exitCode: Int32, details: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "rsync could not be launched: \(reason)"
        case .failed(let exitCode, let details):
            return details.isEmpty ? "rsync exited with code \(exitCode)" : "rsync exited with code \(exitCode): \(details)"
        }
    }
}

/// Splits streamed rsync output into complete, decoded lines. The bytes of an unfinished
/// line — including a multi-byte character cut in half by a pipe read — are held back until
/// the rest arrives. `\r` also ends a line, because `--progress` rewrites its status line with
/// carriage returns. Empty lines are dropped.
final class RsyncLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)

        var lines: [String] = []
        var lineStart = pending.startIndex
        for index in pending.indices where pending[index] == 0x0A || pending[index] == 0x0D {
            lines.append(SyncEngine.decodeRsyncOutput(pending[lineStart..<index]))
            lineStart = pending.index(after: index)
        }
        pending = Data(pending[lineStart...])
        return lines.filter { !$0.isEmpty }
    }

    /// Returns the final unterminated line, if any, once the stream has ended.
    func finish() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let rest = SyncEngine.decodeRsyncOutput(pending)
        pending = Data()
        return rest.isEmpty ? [] : [rest]
    }
}

/// Executes rsync operations via `Process()` and streams stdout/stderr output.
actor SyncEngine {

    // MARK: - State

    private var activeProcesses: [Process] = []
    private let rsyncURL: URL

    /// - Parameter rsyncURL: The rsync binary to run. Overridable so tests can substitute a
    ///   stand-in that fails on demand.
    init(rsyncURL: URL = URL(fileURLWithPath: "/usr/bin/rsync")) {
        self.rsyncURL = rsyncURL
    }

    // MARK: - Flags

    /// Core rsync flags used for all sync operations:
    /// -a  = archive (recursive, preserve symlinks, times)
    /// -v  = verbose output
    /// --delete = delete files on destination not in source (true mirror)
    /// --exclude='.DS_Store'  = skip macOS directory metadata files
    /// --exclude='._*'        = skip AppleDouble resource-fork files
    /// --no-perms = don't attempt to sync Unix permissions (avoids EPERM on FAT/exFAT)
    /// --no-owner, --no-group = skip owner/group sync (requires elevated privileges)
    /// --progress = stream per-file transfer progress (we parse to-chk=X/Y for global progress)
    ///
    /// Deliberately NOT used (both were tried and reverted — see below):
    ///
    /// `--extended-attributes` (-E): would preserve Finder tags/xattrs, but the sandboxed
    /// rsync child cannot read restricted xattrs such as `com.apple.provenance`. It
    /// synthesises an AppleDouble `._NAME` stream per object and every one fails with
    /// `copyfile: Operation not permitted` (~1000 error pairs on a real sync). It also
    /// achieves nothing here, since `--exclude=._*` filters those streams back out.
    ///
    /// `--delete-excluded`: would clean stale excluded files off the destination, but on a
    /// full-drive sync the destination is the volume root, so rsync must descend into
    /// `.Spotlight-V100` / `.Trashes` / `.fseventsd` to delete them. Those are unreadable
    /// system directories, and walking them trips an assertion inside Apple's openrsync
    /// (`flist_gen_dels`, flist.c:2973) which aborts the transfer with SIGABRT.
    private static let baseFlags: [String] = [
        "-av",
        "--delete",
        "--exclude=.DS_Store",
        "--exclude=._*",
        "--exclude=.Spotlight-V100",
        "--exclude=.Trashes",
        "--exclude=.fseventsd",
        "--exclude=.DocumentRevisions-V100",
        "--exclude=.TemporaryItems",
        "--exclude=$RECYCLE.BIN",
        "--exclude=.localized",
        "--exclude=Thumbs.db",
        "--no-perms",
        "--no-owner",
        "--no-group",
        "--progress"
    ]

    /// Maps an rsync process exit code to a `SyncOutcome`. Pure/testable.
    static func outcome(forExitCode code: Int32) -> SyncOutcome {
        switch code {
        case 0: return .success
        case 23: return .warnings
        default: return .failure
        }
    }

    /// Parses the `Total transferred file size:` line out of `rsync --stats` output. Pure/testable.
    static func parseTotalTransferredBytes(from statsOutput: String) -> Int64 {
        for line in statsOutput.components(separatedBy: "\n") {
            if line.hasPrefix("Total transferred file size:") {
                let digits = line.filter { $0.isNumber }
                if let size = Int64(digits) { return size }
            }
        }
        return 0
    }

    /// Parses one `rsync -n -i --stats` output (decoded) into a `TransferPreview`. Pure/testable.
    static func parseTransferPreview(from output: String) -> TransferPreview {
        TransferPreview(
            transferBytes: parseTotalTransferredBytes(from: output),
            deletions: parseDeletionPaths(from: output),
            sourceEntryCount: parseSourceEntryCount(from: output)
        )
    }

    /// Reads `Number of files:` — which counts the source root itself — and returns the number
    /// of entries below the root. Takes only the leading number, so rsync 3's
    /// `1,235 (reg: 1,000, dir: 235)` breakdown is ignored. Missing line → 0, which makes any
    /// deletion look "mass": an unexpected format errs on the side of keeping files.
    private static func parseSourceEntryCount(from statsOutput: String) -> Int {
        let prefix = "Number of files:"
        guard let line = statsOutput.components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) }) else {
            return 0
        }
        let digits = line.dropFirst(prefix.count)
            .drop { $0 == " " }
            .prefix { $0.isNumber || $0 == "," }
            .filter(\.isNumber)
        return max(0, (Int(digits) ?? 0) - 1)
    }

    /// Byte-weighted completion across the tasks of one sync session. Pure/testable.
    ///
    /// `fractions` holds the 0…1 progress of tasks **touched in the current session only** —
    /// a task absent from the map contributes nothing. This is deliberate: deriving completion
    /// from `BackupTask.status` counted a `.success` restored from a *previous* sync as work
    /// already done, which pinned the ring near 100% from the first callback.
    static func weightedProgress(fractions: [UUID: Double], weights: [UUID: Int64]) -> Double {
        let totalBytes = weights.values.reduce(0) { $0 + max(1, $1) }
        guard totalBytes > 0 else { return 0 }

        var done: Double = 0
        for (id, rawFraction) in fractions {
            guard let weight = weights[id] else { continue }
            let fraction = min(1.0, max(0.0, rawFraction))
            done += (Double(max(1, weight)) / Double(totalBytes)) * fraction
        }
        return min(1.0, max(0.0, done))
    }

    /// Parses relative paths out of `*deleting` lines from `rsync -n -i` output. Pure/testable.
    /// Only lines that START with the marker count: a transfer line such as
    /// `>f+++++++ notes deleting.txt` merely contains the word. Expects `decodeRsyncOutput` text.
    static func parseDeletionPaths(from itemizedOutput: String) -> [String] {
        let marker = "*deleting "
        return itemizedOutput.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix(marker) else { return nil }
            // openrsync prints one space after the marker; rsync 3 pads it to the itemize width.
            let path = String(line.dropFirst(marker.count).drop { $0 == " " })
            guard !path.isEmpty, path != ".", path != "./" else { return nil }
            return path
        }
    }

    /// Decodes raw rsync output bytes. Pure/testable.
    ///
    /// macOS 15's openrsync escapes "unprintable" bytes as `\#NNN` (octal) — including
    /// 0x80–0x9F, which are continuation bytes of most Cyrillic letters in UTF-8 — and escapes
    /// a literal backslash as `\#134`. Undoing that restores the real UTF-8 file name. Decoding
    /// is lossy rather than failable: one bad byte must never discard the whole output.
    static func decodeRsyncOutput(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\"), i + 4 < bytes.count, bytes[i + 1] == UInt8(ascii: "#"),
               let value = octalByte(bytes[i + 2], bytes[i + 3], bytes[i + 4]) {
                decoded.append(value)
                i += 5
            } else {
                decoded.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    private static func octalByte(_ digits: UInt8...) -> UInt8? {
        var value = 0
        for digit in digits {
            guard (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { return nil }
            value = value * 8 + Int(digit - UInt8(ascii: "0"))
        }
        return value <= Int(UInt8.max) ? UInt8(value) : nil
    }

    /// `--exclude` rules that keep rsync out of the given top-level folders of the transfer
    /// root. Excluded destination folders are also protected from `--delete`. Pure/testable.
    ///
    /// rsync only treats a backslash as an escape when the pattern contains a wildcard, so
    /// plain names are passed verbatim and names with `*`, `?` or `[` are fully escaped.
    static func topLevelExcludeFlags(for folderNames: [String]) -> [String] {
        let wildcards: Set<Character> = ["*", "?", "["]
        return folderNames.map { name in
            guard name.contains(where: wildcards.contains) else { return "--exclude=/\(name)/" }
            let escaped = name.reduce(into: "") { result, character in
                if character == "\\" || wildcards.contains(character) { result.append("\\") }
                result.append(character)
            }
            return "--exclude=/\(escaped)/"
        }
    }

    // MARK: - Public API

    /// One dry run that reports what a sync would transfer and delete (`-i` itemizes changes,
    /// `--stats` adds totals), so the size estimate, the Deletion Guard and the mass-deletion
    /// check share a single scan instead of walking the source twice. Throws instead of
    /// returning an empty preview when the dry run fails, so the guard can never be silently skipped.
    func previewTransfer(
        from mainURL: URL,
        to secondaryURL: URL,
        useChecksum: Bool,
        excludingTopLevelFolders excludedFolders: [String] = []
    ) async throws -> TransferPreview {
        var args = Self.baseFlags.filter { $0 != "--progress" }
        if useChecksum { args.append("--checksum") }
        args.append(contentsOf: Self.topLevelExcludeFlags(for: excludedFolders))
        args.append(contentsOf: ["-n", "-i", "--stats", ensureTrailingSlash(mainURL.path), ensureTrailingSlash(secondaryURL.path)])

        let _keepAlive = [mainURL, secondaryURL]
        let output = try await runDryRun(arguments: args)
        _ = _keepAlive
        return Self.parseTransferPreview(from: output)
    }

    /// Mirrors the entire `mainURL` directory to `secondaryURL` using rsync --delete.
    /// `excludedFolders` (top-level names) are neither transferred nor deleted — used for
    /// folders that were already synced individually, so the sweep does not walk them again.
    func syncEntireDrive(
        from mainURL: URL,
        to secondaryURL: URL,
        useChecksum: Bool,
        excludingTopLevelFolders excludedFolders: [String] = [],
        onOutput: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async -> SyncOutcome {
        let src = ensureTrailingSlash(mainURL.path)
        let dst = ensureTrailingSlash(secondaryURL.path)
        var args = Self.baseFlags
        if useChecksum { args.append("--checksum") }
        args.append(contentsOf: Self.topLevelExcludeFlags(for: excludedFolders))
        args.append(contentsOf: [src, dst])
        
        let _keepAlive = [mainURL, secondaryURL]
        let result = await runRsync(arguments: args, sourceRoot: src, onOutput: onOutput, onProgress: onProgress)
        _ = _keepAlive
        return result
    }

    /// Syncs a single folder (identified by its relative path) from the main root to the secondary root.
    func syncFolder(
        relativePath: String,
        mainRoot: URL,
        secondaryRoot: URL,
        useChecksum: Bool,
        onOutput: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async -> SyncOutcome {
        let srcURL = mainRoot.appendingPathComponent(relativePath)
        let dstURL = secondaryRoot.appendingPathComponent(relativePath)

        do {
            try FileManager.default.createDirectory(
                at: dstURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            onOutput("⚠ Could not create destination folder \(dstURL.path): \(error.localizedDescription)\n")
        }

        let src = ensureTrailingSlash(srcURL.path)
        let dst = ensureTrailingSlash(dstURL.path)
        var args = Self.baseFlags
        if useChecksum { args.append("--checksum") }
        args.append(contentsOf: [src, dst])

        let _keepAlive = [mainRoot, secondaryRoot, srcURL]
        let result = await runRsync(arguments: args, sourceRoot: src, onOutput: onOutput, onProgress: onProgress)
        _ = _keepAlive
        return result
    }

    private static let terminationGracePeriod: Duration = .seconds(1)

    /// Terminates all running rsync processes and returns only once they are gone: SIGTERM
    /// first, then SIGKILL for anything still running after a grace period. Waiting here
    /// (instead of scheduling a detached SIGKILL) is what lets app exit actually outlast rsync.
    func forceStopAll() async {
        let running = activeProcesses.filter(\.isRunning)
        activeProcesses.removeAll()
        for process in running { process.terminate() }

        let deadline = ContinuousClock.now + Self.terminationGracePeriod
        while running.contains(where: \.isRunning), ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                break  // cancelled: go straight to SIGKILL
            }
        }
        // `isRunning` (not a bare `kill(pid, 0)`) so a recycled PID is never signalled.
        for process in running where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Aborts current sync entirely.
    func abort() async {
        await forceStopAll()
    }

    /// Safely deletes specific absolute paths. Used for partial deletion approvals before an abort.
    /// Returns a description of any deletions that failed (other than "file already gone").
    @discardableResult
    func deleteExactFiles(absolutePaths: [String]) async -> [String] {
        var failures: [String] = []
        for path in absolutePaths {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch let error as NSError {
                if error.code == NSFileNoSuchFileError { continue }
                failures.append("\(path): \(error.localizedDescription)")
            }
        }
        return failures
    }

    // MARK: - Private

    private func removeProcess(_ process: Process) {
        activeProcesses.removeAll { $0 === process }
    }

    private nonisolated func ensureTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    /// Filters raw rsync progress lines from stdout — only file names and summaries are forwarded.
    /// Hard-filters system paths and rsync internal headers to keep the Log Console clean.
    private nonisolated func shouldShow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)

        // 1. Always drop empty lines
        if t.isEmpty { return false }

        // 2. Drop system noise: root dir symbols and common macOS metadata
        let systemNoise = ["./", ".", ".DS_Store", ".localized", ".Spotlight-V100",
                           ".Trashes", ".DocumentRevisions-V100", ".fseventsd"]
        if systemNoise.contains(t) {
            return false
        }
        // Drop lines containing system file patterns (e.g. nested paths)
        let noisePatterns = [".DS_Store", ".localized", ".Spotlight-V100",
                             ".Trashes", ".DocumentRevisions-V100", ".fseventsd"]
        for pattern in noisePatterns where t.contains(pattern) {
            return false
        }
        
        // 3. Drop rsync deletion logs (we handle these manually in BackupViewModel)
        if t.hasPrefix("deleting ") || t.hasPrefix("*deleting") { return false }

        // 3. Drop rsync per-file byte-progress lines ("  1,234,567  98%  4.56MB/s  0:00:01")
        if t.first?.isNumber == true && (t.contains("%") || t.contains("xfr#")) { return false }

        // 4. Drop rsync internal headers / footers
        let rsyncHeaders = ["sending incremental file list", "building file list", "sent ", "total size is",
                            "total transferred file size", "Number of files",
                            "File list size", "File list generation time",
                            "File list transfer time", "Total bytes sent", "Total bytes received"]
        for h in rsyncHeaders where t.lowercased().hasPrefix(h.lowercased()) { return false }
        if t.hasPrefix("sent ") && t.contains("bytes") { return false }
        if t.hasPrefix("total size") { return false }

        return true
    }

    private final class ProcessProgressState: @unchecked Sendable {
        private let lock = NSLock()
        private var completedBytes: Int64 = 0
        private var currentFileBytes: Int64 = 0
        private var lastReport: Date = .distantPast
        
        var totalSoFar: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return completedBytes + currentFileBytes
        }
        
        func setCurrentFileBytes(_ bytes: Int64) {
            lock.lock()
            defer { lock.unlock() }
            currentFileBytes = bytes
        }
        
        func commitCurrentFile() {
            lock.lock()
            defer { lock.unlock() }
            completedBytes += currentFileBytes
            currentFileBytes = 0
        }

        /// Throttles progress callbacks to ~10 per second; `force` always reports.
        func shouldReport(at now: Date, force: Bool) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard force || now.timeIntervalSince(lastReport) > 0.1 else { return false }
            lastReport = now
            return true
        }
    }

    private func runRsync(
        arguments: [String],
        sourceRoot: String,
        onOutput: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async -> SyncOutcome {
        let stdoutLines = RsyncLineBuffer()
        let stderrLines = RsyncLineBuffer()
        let progressState = ProcessProgressState()

        // Stream stdout — parse per-file byte progress, filter noisy lines
        let handleStdout: @Sendable ([String]) -> Void = { [self] lines in
            self.forwardOutput(
                lines: lines,
                sourceRoot: sourceRoot,
                progressState: progressState,
                onOutput: onOutput,
                onProgress: onProgress
            )
        }
        // Stream stderr — always show (errors are important)
        let handleStderr: @Sendable ([String]) -> Void = { lines in
            let text = lines
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { "⚠ \($0)\n" }
                .joined()
            if !text.isEmpty { onOutput(text) }
        }

        let exitCode: Int32
        do {
            exitCode = try await runProcess(
                arguments: arguments,
                onStdout: { handleStdout(stdoutLines.append($0)) },
                onStderr: { handleStderr(stderrLines.append($0)) }
            )
        } catch {
            onOutput("❌ \(error.localizedDescription)\n")
            return .failure
        }
        handleStdout(stdoutLines.finish())
        handleStderr(stderrLines.finish())

        let outcome = Self.outcome(forExitCode: exitCode)
        if outcome == .warnings {
            onOutput("⚠ rsync finished with warnings (exit 23) — some files may not have transferred. Check the errors above.\n")
        }
        return outcome
    }

    /// Turns complete stdout lines into log output and byte-progress callbacks.
    private nonisolated func forwardOutput(
        lines: [String],
        sourceRoot: String,
        progressState: ProcessProgressState,
        onOutput: @Sendable (String) -> Void,
        onProgress: @Sendable (Int64) -> Void
    ) {
        var finalLines = [String]()
        for rawLine in lines {
            var line = rawLine
            if line.hasPrefix("Transfer starting:") {
                line = "Syncing changes..."
            }

            if !shouldShow(line) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.first?.isNumber == true && (t.contains("%") || t.contains("xfr#")) {
                    let parts = t.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if let first = parts.first, let currentBytes = Int64(first.replacingOccurrences(of: ",", with: "")) {
                        progressState.setCurrentFileBytes(currentBytes)

                        if parts.contains("100%") {
                            progressState.commitCurrentFile()
                        }

                        if progressState.shouldReport(at: Date(), force: parts.contains("100%")) {
                            onProgress(progressState.totalSoFar)
                        }
                    }
                }
            } else if line == "Syncing changes..." {
                finalLines.append(line)
            } else {
                let cleanPath = line.trimmingCharacters(in: .whitespaces)
                finalLines.append("✓ \(sourceRoot)\(cleanPath)")
            }
        }

        let joined = finalLines.joined(separator: "\n")
        if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onOutput(joined + "\n")
        }
    }

    /// Runs a dry run to completion and returns its decoded stdout. Fails closed: anything
    /// other than a completed run (exit 0, or 23 = partial transfer) throws, so a broken dry
    /// run can never be mistaken for "nothing to transfer" or "nothing to delete".
    private func runDryRun(arguments: [String]) async throws -> String {
        let stdout = DataAccumulator()
        let stderr = DataAccumulator()
        let exitCode = try await runProcess(
            arguments: arguments,
            onStdout: { stdout.append($0) },
            onStderr: { stderr.append($0) }
        )
        guard Self.outcome(forExitCode: exitCode).didComplete else {
            let details = Self.decodeRsyncOutput(stderr.data)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .suffix(5)
                .joined(separator: "\n")
            throw RsyncError.failed(exitCode: exitCode, details: details)
        }
        return Self.decodeRsyncOutput(stdout.data)
    }

    /// Launches rsync and streams both pipes until EOF. Returns only after the process has
    /// exited AND its output has been fully read — a `terminationHandler` can fire before the
    /// last pipe reads, which used to drop the tail of the output (where `--stats` lives).
    private func runProcess(
        arguments: [String],
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void
    ) async throws -> Int32 {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL  = rsyncURL
        process.arguments      = arguments
        process.standardOutput = outPipe
        process.standardError  = errPipe

        let completion = ProcessCompletion()
        process.terminationHandler = { completion.processExited(status: $0.terminationStatus) }

        activeProcesses.append(process)
        defer { removeProcess(process) }
        do {
            try process.run()
        } catch {
            throw RsyncError.launchFailed(error.localizedDescription)
        }

        let stdoutHandle = outPipe.fileHandleForReading
        let stderrHandle = errPipe.fileHandleForReading
        return await withCheckedContinuation { continuation in
            completion.attach(continuation)
            Self.drain(stdoutHandle, into: onStdout) { completion.streamClosed() }
            Self.drain(stderrHandle, into: onStderr) { completion.streamClosed() }
        }
    }

    /// Reads `handle` on a background thread until EOF, in order, one chunk at a time.
    private nonisolated static func drain(
        _ handle: FileHandle,
        into sink: @escaping @Sendable (Data) -> Void,
        then done: @escaping @Sendable () -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            while case let chunk = handle.availableData, !chunk.isEmpty {
                sink(chunk)
            }
            done()
        }
    }
}

/// Collects a pipe's bytes from its background reader thread.
private final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(data)
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Resumes `runProcess` once rsync has exited and both pipes reached EOF. If a pipe stays open
/// after exit (an orphaned child still holding it), a short grace period keeps that from
/// hanging the sync forever.
private final class ProcessCompletion: @unchecked Sendable {
    private static let pipeGracePeriod: TimeInterval = 2

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?
    private var exitStatus: Int32?
    private var openStreams = 2
    private var gracePeriodElapsed = false
    private var resumed = false

    func attach(_ continuation: CheckedContinuation<Int32, Never>) {
        update { $0.continuation = continuation }
    }

    func streamClosed() {
        update { $0.openStreams -= 1 }
    }

    func processExited(status: Int32) {
        update { $0.exitStatus = status }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.pipeGracePeriod) { [self] in
            update { $0.gracePeriodElapsed = true }
        }
    }

    private func update(_ change: (ProcessCompletion) -> Void) {
        lock.lock()
        change(self)
        var ready: (CheckedContinuation<Int32, Never>, Int32)?
        if !resumed, let continuation, let exitStatus, openStreams == 0 || gracePeriodElapsed {
            resumed = true
            self.continuation = nil
            ready = (continuation, exitStatus)
        }
        lock.unlock()
        if let (continuation, status) = ready {
            continuation.resume(returning: status)
        }
    }
}
