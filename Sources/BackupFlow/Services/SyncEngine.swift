import Foundation

/// Executes rsync operations via `Process()` and streams stdout/stderr output.
actor SyncEngine {

    // MARK: - State

    private var activeProcesses: [Process] = []

    // MARK: - Flags

    /// Core rsync flags used for all sync operations:
    /// -a  = archive (recursive, preserve symlinks, times)
    /// -v  = verbose output
    /// --delete          = delete files on destination not in source (true mirror)
    /// --delete-excluded = also delete destination files excluded by --exclude rules
    ///                     (prevents stale macOS metadata accumulating)
    /// --exclude='.DS_Store'  = skip macOS directory metadata files
    /// --exclude='._*'        = skip AppleDouble resource-fork files
    ///                          These cannot be unlinked via rsync inside the app sandbox.
    /// --no-perms = don't attempt to sync Unix permissions (avoids EPERM on FAT/exFAT)
    /// --no-owner, --no-group = skip owner/group sync (requires elevated privileges)
    /// --progress = stream per-file transfer progress (we parse to-chk=X/Y for global progress)
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

    // MARK: - Public API

    /// Performs a dry-run to calculate exactly how many bytes will be transferred.
    func calculateTransferSize(from mainURL: URL, to secondaryURL: URL, useChecksum: Bool) async -> Int64 {
        let src = ensureTrailingSlash(mainURL.path)
        let dst = ensureTrailingSlash(secondaryURL.path)
        
        var args = Self.baseFlags.filter { $0 != "--progress" }
        if useChecksum { args.append("--checksum") }
        args.append(contentsOf: ["-n", "--stats", src, dst])
        
        let _keepAlive = [mainURL, secondaryURL]
        
        final class OutputStorage: @unchecked Sendable {
            private let lock = NSLock()
            var data = Data()
            func append(_ newData: Data) {
                lock.lock()
                defer { lock.unlock() }
                data.append(newData)
            }
            func get() -> String? {
                lock.lock()
                defer { lock.unlock() }
                return String(data: data, encoding: .utf8)
            }
        }
        
        return await withCheckedContinuation { continuation in
            let process = Process()
            let outPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
            process.arguments = args
            process.standardOutput = outPipe
            self.activeProcesses.append(process)
            
            let storage = OutputStorage()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                storage.append(handle.availableData)
            }
            
            process.terminationHandler = { _ in
                outPipe.fileHandleForReading.readabilityHandler = nil
                _ = _keepAlive
                Task { [weak process] in if let p = process { await self.removeProcess(p) } }
                
                guard let text = storage.get() else {
                    continuation.resume(returning: 0)
                    return
                }
                
                var total: Int64 = 0
                for line in text.components(separatedBy: "\n") {
                    if line.hasPrefix("Total transferred file size:") {
                        let digits = line.filter { $0.isNumber }
                        if let size = Int64(digits) {
                            total = size
                            break
                        }
                    }
                }
                continuation.resume(returning: total)
            }
            
            do { try process.run() } catch { continuation.resume(returning: 0) }
        }
    }

    /// Performs a dry-run to identify all files and folders that will be deleted.
    /// Returns an array of relative paths strictly matching `*deleting` lines from rsync output.
    func calculateDeletions(from mainURL: URL, to secondaryURL: URL, useChecksum: Bool) async -> [String] {
        let src = ensureTrailingSlash(mainURL.path)
        let dst = ensureTrailingSlash(secondaryURL.path)
        
        var args = Self.baseFlags.filter { $0 != "--progress" }
        if useChecksum { args.append("--checksum") }
        
        // Ensure --delete is explicitly present as requested (though it's in baseFlags),
        // and add the itemize-changes flag so we can parse `*deleting`
        if !args.contains("--delete") { args.append("--delete") }
        args.append(contentsOf: ["-n", "-i", src, dst])
        
        let _keepAlive = [mainURL, secondaryURL]
        
        final class OutputStorage: @unchecked Sendable {
            private let lock = NSLock()
            var data = Data()
            func append(_ newData: Data) {
                lock.lock()
                defer { lock.unlock() }
                data.append(newData)
            }
            func get() -> String? {
                lock.lock()
                defer { lock.unlock() }
                return String(data: data, encoding: .utf8)
            }
        }
        
        return await withCheckedContinuation { continuation in
            let process = Process()
            let outPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
            process.arguments = args
            process.standardOutput = outPipe
            self.activeProcesses.append(process)
            
            let storage = OutputStorage()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                storage.append(handle.availableData)
            }
            
            process.terminationHandler = { _ in
                outPipe.fileHandleForReading.readabilityHandler = nil
                _ = _keepAlive
                Task { [weak process] in if let p = process { await self.removeProcess(p) } }
                
                guard let text = storage.get() else {
                    continuation.resume(returning: [])
                    return
                }
                
                var deletions: [String] = []
                for line in text.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("deleting ") || trimmed.hasPrefix("*deleting") {
                        // For rsync -i, deletions look like "*deleting   filename"
                        // Or standard "deleting filename"
                        let path = trimmed.replacingOccurrences(of: "deleting ", with: "")
                                          .replacingOccurrences(of: "*deleting", with: "")
                                          .trimmingCharacters(in: .whitespaces)
                        if !path.isEmpty && path != "." && path != "./" {
                            deletions.append(path)
                        }
                    }
                }
                
                continuation.resume(returning: deletions)
            }
            
            do { try process.run() } catch { continuation.resume(returning: []) }
        }
    }
    /// Mirrors the entire `mainURL` directory to `secondaryURL` using rsync --delete.
    func syncEntireDrive(
        from mainURL: URL,
        to secondaryURL: URL,
        useChecksum: Bool,
        onOutput: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> Bool {
        let src = ensureTrailingSlash(mainURL.path)
        let dst = ensureTrailingSlash(secondaryURL.path)
        var args = Self.baseFlags
        if useChecksum { args.append("--checksum") }
        args.append(contentsOf: [src, dst])
        
        let _keepAlive = [mainURL, secondaryURL]
        let result = await runRsync(arguments: args, onOutput: onOutput, onProgress: onProgress)
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
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> Bool {
        let srcURL = mainRoot.appendingPathComponent(relativePath)
        let dstURL = secondaryRoot.appendingPathComponent(relativePath)

        try? FileManager.default.createDirectory(
            at: dstURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let src = ensureTrailingSlash(srcURL.path)
        let dst = ensureTrailingSlash(dstURL.path)
        var args = Self.baseFlags
        if useChecksum { args.append("--checksum") }
        args.append(contentsOf: [src, dst])

        let _keepAlive = [mainRoot, secondaryRoot, srcURL]
        let result = await runRsync(arguments: args, onOutput: onOutput, onProgress: onProgress)
        _ = _keepAlive
        return result
    }

    /// Immediately terminates all running rsync processes, with a SIGKILL fallback.
    func forceStopAll() {
        for process in activeProcesses {
            if process.isRunning {
                let pid = process.processIdentifier
                process.terminate()
                
                // Fallback: forcefully kill after 1 second if still running
                Task.detached {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    // kill(pid, 0) == 0 means process still exists
                    if kill(pid, 0) == 0 {
                        kill(pid, SIGKILL)
                    }
                }
            }
        }
        activeProcesses.removeAll()
    }

    /// Aborts current sync entirely.
    func abort() {
        forceStopAll()
    }

    /// Safely deletes specific absolute paths. Used for partial deletion approvals before an abort.
    func deleteExactFiles(absolutePaths: [String]) async {
        for path in absolutePaths {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch let error as NSError {
                if error.code == NSFileNoSuchFileError { continue }
            }
        }
    }

    // MARK: - Private

    private func removeProcess(_ process: Process) {
        activeProcesses.removeAll { $0 === process }
    }

    private nonisolated func ensureTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    /// Filters raw rsync progress lines from stdout; only file names and summaries are forwarded.
    private nonisolated func shouldShow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        // Skip per-file byte-progress lines ("  1,234,567  98%  4.56MB/s  0:00:01 (xfr#1, to-chk=3/16)")
        if t.first?.isNumber == true && (t.contains("%") || t.contains("xfr#")) { return false }
        if t.hasPrefix("sent ") && t.contains("bytes") { return false }
        if t.hasPrefix("total size") { return false }
        return true
    }

    /// Parses the `to-chk=REMAINING/TOTAL` token from a rsync --progress line.
    /// Returns fraction of queue COMPLETED = (total - remaining) / total.
    /// This is immune to --checksum false-100% emissions.
    private nonisolated func parseToCheckFraction(from line: String) -> Double? {
        // Look for pattern: to-chk=X/Y  or  ir-chk=X/Y
        guard let range = line.range(of: #"(?:to-chk|ir-chk)=([0-9]+)/([0-9]+)"#,
                                      options: .regularExpression) else { return nil }
        let token = String(line[range])
        // token = "to-chk=3/16"
        let parts = token.split(separator: "=").last?.split(separator: "/")
        guard let remainingStr = parts?.first, let totalStr = parts?.last,
              let remaining = Double(remainingStr), let total = Double(totalStr),
              total > 0 else { return nil }
        // Fraction completed (clamped to [0, 0.99] during active transfer)
        return min(0.99, max(0.0, (total - remaining) / total))
    }

    private func runRsync(
        arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()

            process.executableURL  = URL(fileURLWithPath: "/usr/bin/rsync")
            process.arguments      = arguments
            process.standardOutput = outPipe
            process.standardError  = errPipe

            self.activeProcesses.append(process)

            // Stream stdout — parse to-chk=X/Y fraction, filter noisy lines
            outPipe.fileHandleForReading.readabilityHandler = { @Sendable [self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

                let lines = text.components(separatedBy: "\n")
                var bestFraction: Double? = nil

                let filtered = lines.filter { line in
                    if !self.shouldShow(line) {
                        // Parse the to-chk=X/Y fraction from progress lines
                        if let f = self.parseToCheckFraction(from: line) {
                            // Keep the highest fraction seen in this chunk (most progressed)
                            bestFraction = max(bestFraction ?? 0, f)
                        }
                        return false
                    }
                    return true
                }
                .joined(separator: "\n")

                if let f = bestFraction {
                    onProgress(f)
                }

                if !filtered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onOutput(filtered + "\n")
                }
            }

            // Stream stderr — always show (errors are important)
            errPipe.fileHandleForReading.readabilityHandler = { @Sendable handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { onOutput("⚠ " + text) }
            }

            process.terminationHandler = { @Sendable p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                Task { await self.removeProcess(p) }
                let status = p.terminationStatus
                continuation.resume(returning: status == 0 || status == 23)
            }

            do {
                try process.run()
            } catch {
                onOutput("❌ rsync launch failed: \(error.localizedDescription)\n")
                self.removeProcess(process)
                continuation.resume(returning: false)
            }
        }
    }

}
