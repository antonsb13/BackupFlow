import Foundation
import AppKit

@MainActor
enum SyncState: Equatable {
    case idle
    case calculating
    case transferring
    case completed
}

@MainActor
final class BackupViewModel: ObservableObject {

    // MARK: - Published State

    @Published var mainDriveURL: URL? {
        didSet { guard !isRestoring else { return }; handleDriveAvailabilityChange() }
    }
    @Published var secondaryDriveURL: URL? {
        didSet { guard !isRestoring else { return }; handleDriveAvailabilityChange() }
    }
    @Published var syncEntireDrive: Bool = false
    @Published var tasks: [BackupTask] = []
    @Published var selectedTaskIDs: Set<UUID> = []
    @Published var logOutput: String = ""
    @Published var isLogExpanded: Bool = false
    @Published var syncState: SyncState = .idle
    var isSyncing: Bool { syncState == .calculating || syncState == .transferring }
    @Published var showAbortConfirm: Bool = false
    @Published var isMuted: Bool = false
    @Published var alertMessage: String? = nil
    @Published var useChecksum: Bool = false
    @Published var isSyncCancelled: Bool = false
    
    // Deletion Guard State
    @Published var confirmDeletions: Bool = UserDefaults.standard.bool(forKey: "bf.confirmDeletions") {
        didSet { UserDefaults.standard.set(confirmDeletions, forKey: "bf.confirmDeletions") }
    }
    @Published var deletionQueue: [String] = []
    @Published var currentDeletionIndex: Int = 0
    @Published var isReviewingDeletions: Bool = false
    private var deletionContinuation: CheckedContinuation<Bool, Never>?
    private var applyToAllDeletions: Bool = false
    @Published var approvedPaths: [String] = []

    // Global Progress State
    @Published var globalProgress: Double = 0.0
    @Published var currentTaskIndex: Int = 0
    @Published var totalTasksCount: Int = 0

    // MARK: - Private

    private let engine = SyncEngine()
    private var scheduleTimer: Timer?
    private var diskWatchdogTimer: Timer?
    private var isRestoring = false // Prevents `didSet` from firing during `restoreState()`

    private enum SchKeys {
        static let enabled  = "bf.scheduleEnabled"
        static let interval = "bf.scheduleInterval"  // stored in hours (Int); 0 means off
    }

    private enum Keys {
        static let mainBookmark      = "bf.mainBookmark"
        static let secondaryBookmark = "bf.secondaryBookmark"
        static let syncMode          = "bf.syncEntireDrive"
        static let tasks             = "bf.tasks"
        static let isMuted           = "bf.isMuted"
        static let useChecksum       = "bf.useChecksum"
    }

    // Pre-loaded sounds — prevents audio engine overload on rapid calls
    private static let successSound: NSSound? = NSSound(named: "Glass")
    private static let failureSound: NSSound? = NSSound(named: "Basso")

    // MARK: - Init

    init() {
        isRestoring = true
        restoreState()
        isRestoring = false
        checkDiskAvailability()     // clear ghost paths that are no longer reachable
        handleDriveAvailabilityChange() // initial UI sync after state restoration
        setupScheduler()            // start background sync timer if schedule was configured
        setupVolumeMonitor()        // listen for disk eject/unmount events
        startDiskWatchdog()         // periodic FileManager check for physical ejections
    }

    // MARK: - Computed

    var statusText: String {
        switch syncState {
        case .calculating:
            return "Preparing..."
        case .transferring:
            let pct = Int(globalProgress * 100)
            let actionText = useChecksum ? "Verifying" : "Syncing"
            if totalTasksCount > 1 {
                return "\(actionText) \(currentTaskIndex) of \(totalTasksCount) (\(pct)%)"
            } else {
                return "\(actionText) (\(pct)%)"
            }
        case .completed:
            return "Synced"
        case .idle:
            break
        }
        
        if mainDriveURL == nil || secondaryDriveURL == nil { return "Not configured" }
        let failed = tasks.filter { $0.status == .failed }.count
        if failed > 0 { return "\(failed) task(s) failed" }
        let done = tasks.filter { $0.status == .success }.count
        if done > 0 { return "Last sync OK" }
        return "Idle"
    }

    // MARK: - Drive Selection

    func selectMainDrive() {
        guard let url = pickVolume(message: "Select the Main Disk") else { return }
        if let data = BookmarkManager.createBookmark(for: url) {
            UserDefaults.standard.set(data, forKey: Keys.mainBookmark)
        }
        mainDriveURL = url  // triggers didSet → handleDriveAvailabilityChange
    }

    func selectSecondaryDrive() {
        guard let url = pickVolume(message: "Select the Backup Disk") else { return }
        if let data = BookmarkManager.createBookmark(for: url) {
            UserDefaults.standard.set(data, forKey: Keys.secondaryBookmark)
        }
        secondaryDriveURL = url  // triggers didSet → handleDriveAvailabilityChange
    }

    // MARK: - Task Management

    func addFolder() {
        guard let mainURL = mainDriveURL else {
            log("⚠️ Select a Main drive first.\n"); return
        }
        guard let url = pickFolder(message: "Select a folder to back up", startingAt: mainURL) else { return }

        if url.path == mainURL.path {
            log("⚠️ Cannot add the entire disk root in Custom Folders mode. Use Full Disk Sync instead.\n")
            return
        }

        let mainPath   = mainURL.path
        let folderPath = url.path
        let relative   = folderPath.hasPrefix(mainPath)
            ? String(folderPath.dropFirst(mainPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : url.lastPathComponent

        let task = BackupTask(
            folderName:   url.lastPathComponent,
            relativePath: relative,
            bookmarkData: BookmarkManager.createBookmark(for: url)
        )
        tasks.append(task)
        saveTasks()
    }

    func removeSelectedTasks() {
        tasks.removeAll { selectedTaskIDs.contains($0.id) }
        selectedTaskIDs = []
        saveTasks()
    }

    // MARK: - Volume Check

    private func isVolumeMounted(_ url: URL) -> Bool {
        // Try with security scope first, then without (for non-sandboxed / already-scoped URLs)
        let didStart = url.startAccessingSecurityScopedResource()
        let reachable = (try? url.checkResourceIsReachable()) == true
        if didStart { url.stopAccessingSecurityScopedResource() }
        return reachable
    }

    // MARK: - Sync

    func syncAll() {
        guard let mainURL = mainDriveURL, let secondaryURL = secondaryDriveURL else {
            log("⚠️ Select both drives before syncing.\n"); return
        }
        guard !isSyncing else { return }

        if !isVolumeMounted(mainURL) || !isVolumeMounted(secondaryURL) {
            let msg = "Disk Disconnected. Ensure both disks are mounted."
            log("🛑 \(msg)\n")
            alertMessage = msg
            playSound(.failure)
            return
        }

        syncState = .calculating
        log("═══ Backup Flow  \(Date().formatted()) ═══\n")

        Task {
            await performSync(mainURL: mainURL, secondaryURL: secondaryURL)
            self.syncState = .idle
        }
    }

    private func performSync(mainURL: URL, secondaryURL: URL) async {
        if syncEntireDrive {
            await syncEntireDriveTo(main: mainURL, secondary: secondaryURL, checksum: useChecksum)
        } else {
            await syncSelectedFolders(main: mainURL, secondary: secondaryURL, checksum: useChecksum)
        }
    }

    private func syncEntireDriveTo(main mURL: URL, secondary sURL: URL, checksum: Bool) async {
        log("▶ Full drive sync: \(mURL.path) → \(sURL.path)\n")

        var anyFailure = false
        var snapshot = tasks
        
        let mStarted = mURL.startAccessingSecurityScopedResource()
        let sStarted = sURL.startAccessingSecurityScopedResource()
        defer {
            if sStarted { sURL.stopAccessingSecurityScopedResource() }
            if mStarted { mURL.stopAccessingSecurityScopedResource() }
        }
        
        isSyncCancelled = false
        applyToAllDeletions = false
        
        // 1. Calculate Target Bytes strictly before processing — mark rows as .calculating
        log("Calculating transfer sizes...\n")
        var queueTotalBytes: Int64 = 0
        for i in 0..<snapshot.count {
            if isSyncCancelled { return }
            setStatus(snapshot[i].id, .calculating)  // Row shows "Calculating..."
            let size = await engine.calculateTransferSize(
                from: mURL.appendingPathComponent(snapshot[i].relativePath),
                to: sURL.appendingPathComponent(snapshot[i].relativePath),
                useChecksum: checksum
            )
            if isSyncCancelled { return }
            snapshot[i].targetBytes = max(1, size)
            queueTotalBytes += size
            
            // Revert state to prevent "Calculating..." getting stuck on waiting rows
            if let main = mainDriveURL, SyncHistoryManager.shared.date(for: main.appendingPathComponent(snapshot[i].relativePath).path) != nil {
                setStatus(snapshot[i].id, .success)
            } else {
                setStatus(snapshot[i].id, .idle)
            }
        }
        
        if isSyncCancelled { return }
        
        // Add root sweep dry run
        let rootSweepSize = await engine.calculateTransferSize(from: mURL, to: sURL, useChecksum: checksum)
        queueTotalBytes += rootSweepSize
        
        self.tasks = snapshot
        globalProgress = 0.0 // Strict 0 at start of transfer phase
        syncState = .transferring

        var completedTasks = 0
        totalTasksCount = snapshot.count + 1

        // 2. Sync each top-level folder
        let activeStatus: SyncStatus = checksum ? .verifying : .syncing
        for (i, task) in snapshot.enumerated() {
            if isSyncCancelled { return }
            
            // --- Deletions Guard phase ---
            if confirmDeletions {
                setStatus(task.id, .reviewingDeletions)
                let deletions = await engine.calculateDeletions(
                    from: mURL.appendingPathComponent(task.relativePath),
                    to: sURL.appendingPathComponent(task.relativePath),
                    useChecksum: checksum
                )
                
                if !deletions.isEmpty && !applyToAllDeletions && !isSyncCancelled {
                    deletionQueue = deletions
                    approvedPaths.removeAll()
                    for (idx, path) in deletions.enumerated() {
                        if isSyncCancelled { break }
                        currentDeletionIndex = idx
                        let approved = await showDeletionConfirmation(for: path)
                        
                        if !approved {
                            await MainActor.run {
                                self.setStatus(task.id, .aborted)
                                for p in self.approvedPaths {
                                    let fileName = URL(fileURLWithPath: p).lastPathComponent
                                    self.log("🗑️ Deleted from backup: \(fileName)\n")
                                }
                            }
                            await engine.deleteExactFiles(absolutePaths: approvedPaths)
                            abortSync()
                            return
                        } else if !applyToAllDeletions {
                            let dstURL = sURL.appendingPathComponent(task.relativePath).appendingPathComponent(path)
                            approvedPaths.append(dstURL.path)
                        } else {
                            await MainActor.run {
                                let remaining = deletions.count - idx
                                self.log("✅ Bulk deletion complete: \(remaining) files removed.\n")
                            }
                            break
                        }
                    }
                }
                if isSyncCancelled { return }
            }
            
            currentTaskIndex = i + 1
            setStatus(task.id, activeStatus)  // Row transitions to Syncing / Verifying

            let ok = await engine.syncFolder(
                relativePath: task.relativePath,
                mainRoot:     mURL,
                secondaryRoot: sURL,
                useChecksum:  checksum
            ) { [weak self] text in
                Task { @MainActor [weak self] in self?.log(text) }
            } onProgress: { [weak self, id = task.id, queueTotalBytes] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.updateTaskProgressFraction(id: id, fraction: fraction, queueTotalBytes: queueTotalBytes)
                }
            }

            if isSyncCancelled { return }

            if ok {
                let absPath = mURL.appendingPathComponent(task.relativePath).path
                SyncHistoryManager.shared.record(absolutePath: absPath)
                completedTasks += 1
            }

            setStatus(task.id, ok ? .success : .failed, date: ok ? Date() : nil)
            log(ok ? "  ✅ Done.\n" : "  ❌ Failed.\n")
            if !ok { anyFailure = true }
        }
        
        if isSyncCancelled { return }

        // 3. Final sweep — counts as the last task
        currentTaskIndex = totalTasksCount
        log("\n▶ [\(totalTasksCount)/\(totalTasksCount)] Sweeping root files...\n")
        
        let sweepOk = await engine.syncEntireDrive(from: mURL, to: sURL, useChecksum: checksum) { [weak self] text in
            Task { @MainActor [weak self] in self?.log(text) }
        } onProgress: { [weak self, completedTasks] fraction in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let global = (Double(completedTasks) + fraction) / Double(max(1, self.totalTasksCount))
                self.globalProgress = min(0.99, max(0.0, global))
            }
        }
        
        if sweepOk { SyncHistoryManager.shared.record(absolutePath: mURL.path) }
        
        globalProgress = 1.0
        syncState = .completed
        log(sweepOk && !anyFailure ? "\n✅ Full drive sync complete.\n" : "\n❌ Sync finished with warnings.\n")
        playSound(sweepOk && !anyFailure ? .success : .failure)
    }

    private func syncSelectedFolders(main mURL: URL, secondary sURL: URL, checksum: Bool) async {
        var anyFailure = false
        var snapshot = tasks

        totalTasksCount = snapshot.count
        
        let mStarted = mURL.startAccessingSecurityScopedResource()
        let sStarted = sURL.startAccessingSecurityScopedResource()
        defer {
            if sStarted { sURL.stopAccessingSecurityScopedResource() }
            if mStarted { mURL.stopAccessingSecurityScopedResource() }
        }
        
        isSyncCancelled = false
        applyToAllDeletions = false
        
        // Begin calculating sizes — mark each row as calculating
        log("Calculating transfer sizes...\n")
        var queueTotalBytes: Int64 = 0
        for i in 0..<snapshot.count {
            if isSyncCancelled { return }
            setStatus(snapshot[i].id, .calculating)  // Row shows "Calculating..."
            let size = await engine.calculateTransferSize(
                from: mURL.appendingPathComponent(snapshot[i].relativePath),
                to: sURL.appendingPathComponent(snapshot[i].relativePath),
                useChecksum: checksum
            )
            if isSyncCancelled { return }
            snapshot[i].targetBytes = max(1, size)
            queueTotalBytes += size
            
            // Revert state to prevent cascading "Calculating..." lock
            if let main = mainDriveURL, SyncHistoryManager.shared.date(for: main.appendingPathComponent(snapshot[i].relativePath).path) != nil {
                setStatus(snapshot[i].id, .success)
            } else {
                setStatus(snapshot[i].id, .idle)
            }
        }
        
        if isSyncCancelled { return }
        
        self.tasks = snapshot
        globalProgress = 0.0  // Strict 0 at start of transfer phase
        syncState = .transferring
        
        var completedTasks = 0
        let activeStatus: SyncStatus = checksum ? .verifying : .syncing

        for (i, task) in snapshot.enumerated() {
            if isSyncCancelled { return }
            
            // --- Deletions Guard phase ---
            if confirmDeletions {
                setStatus(task.id, .reviewingDeletions)
                let deletions = await engine.calculateDeletions(
                    from: mURL.appendingPathComponent(task.relativePath),
                    to: sURL.appendingPathComponent(task.relativePath),
                    useChecksum: checksum
                )
                
                if !deletions.isEmpty && !applyToAllDeletions && !isSyncCancelled {
                    deletionQueue = deletions
                    approvedPaths.removeAll()
                    for (idx, path) in deletions.enumerated() {
                        if isSyncCancelled { break }
                        currentDeletionIndex = idx
                        let approved = await showDeletionConfirmation(for: path)
                        
                        if !approved {
                            await MainActor.run {
                                self.setStatus(task.id, .aborted)
                                for p in self.approvedPaths {
                                    let fileName = URL(fileURLWithPath: p).lastPathComponent
                                    self.log("🗑️ Deleted from backup: \(fileName)\n")
                                }
                            }
                            await engine.deleteExactFiles(absolutePaths: approvedPaths)
                            abortSync()
                            return
                        } else if !applyToAllDeletions {
                            let dstURL = sURL.appendingPathComponent(task.relativePath).appendingPathComponent(path)
                            approvedPaths.append(dstURL.path)
                        } else {
                            await MainActor.run {
                                let remaining = deletions.count - idx
                                self.log("✅ Bulk deletion complete: \(remaining) files removed.\n")
                            }
                            break
                        }
                    }
                }
                if isSyncCancelled { return }
            }
            
            currentTaskIndex = i + 1
            setStatus(task.id, activeStatus)  // Row transitions to Syncing / Verifying
            log("\n▶ [\(i + 1)/\(snapshot.count)] '\(task.folderName)' (\(task.relativePath))\n")

            // Also resolve the folder's own bookmark for maximum sandbox compatibility
            var folderScopeURL: URL? = nil
            if let bookmark = task.bookmarkData,
               let resolved = BookmarkManager.resolveBookmark(bookmark) {
                let started = resolved.startAccessingSecurityScopedResource()
                if started { folderScopeURL = resolved }
            }

            let ok = await engine.syncFolder(
                relativePath: task.relativePath,
                mainRoot:     mURL,
                secondaryRoot: sURL,
                useChecksum:  checksum
            ) { [weak self] text in
                Task { @MainActor [weak self] in self?.log(text) }
            } onProgress: { [weak self, id = task.id, queueTotalBytes] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.updateTaskProgressFraction(id: id, fraction: fraction, queueTotalBytes: queueTotalBytes)
                }
            }

            // Release in reverse order
            folderScopeURL?.stopAccessingSecurityScopedResource()

            if isSyncCancelled { return }

            // Record sync date by absolute path (cross-mode persistence)
            if ok {
                let absPath = mURL.appendingPathComponent(task.relativePath).path
                SyncHistoryManager.shared.record(absolutePath: absPath)
                completedTasks += 1
            }

            setStatus(task.id, ok ? .success : .failed, date: ok ? Date() : nil)
            log(ok ? "  ✅ Done.\n" : "  ❌ Failed.\n")
            if !ok { anyFailure = true }
        }
        
        if isSyncCancelled { return }

        globalProgress = 1.0
        saveTasks()
        playSound(anyFailure ? .failure : .success)
    }

    func abortSync() {
        Task {
            isSyncCancelled = true
            
            if let cont = deletionContinuation {
                cont.resume(returning: false)
                deletionContinuation = nil
                isReviewingDeletions = false
            }
            
            let wasCalculating = (syncState == .calculating || syncState == .idle)
            await engine.forceStopAll()
            
            if wasCalculating {
                // Return actively calculating tasks to original state
                for i in 0..<tasks.count {
                    if tasks[i].status == .calculating {
                        if let main = mainDriveURL, SyncHistoryManager.shared.date(for: main.appendingPathComponent(tasks[i].relativePath).path) != nil {
                            setStatus(tasks[i].id, .success)
                        } else {
                            setStatus(tasks[i].id, .idle)
                        }
                    }
                }
            } else {
                // Aborted mid-transfer — only mark the actively syncing tasks as aborted
                for i in 0..<tasks.count {
                    if tasks[i].status == .syncing || tasks[i].status == .verifying || tasks[i].status == .reviewingDeletions {
                        setStatus(tasks[i].id, .aborted)
                    } else if tasks[i].status == .calculating {
                        // Edge case fallback
                        setStatus(tasks[i].id, .idle)
                    }
                }
            }
            
            syncState = .idle
            globalProgress = 0.0
            log("\n🛑 Sync aborted by user.\n")
            playSound(.failure)
        }
    }

    /// Blocks safely to ensure all background `rsync` processes are killed on app exit.
    nonisolated func terminateOnExit() {
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            await self.engine.forceStopAll()
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 1.5)
    }

    // MARK: - Full Disk Task Scan

    func refreshFullDiskTasks() {
        guard syncEntireDrive, let main = mainDriveURL else { return }

        Task {
            // All work happens on @MainActor Task — no detached tasks, no makeIterator issues
            let scopeStarted = main.startAccessingSecurityScopedResource()
            defer { if scopeStarted { main.stopAccessingSecurityScopedResource() } }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: main,
                    includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )

                var collected: [BackupTask] = []
                for url in contents {
                    guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    else { continue }

                    // Check if folder exists on backup disk ONLY if the target disk is available.
                    // If the backup disk isn't mounted, we don't know if it's missing, so default to false
                    // instead of showing false-positive yellow icons.
                    var isMissing = false
                    if let sec = self.secondaryDriveURL, self.isVolumeMounted(sec) {
                        let secStarted = sec.startAccessingSecurityScopedResource()
                        let dest = sec.appendingPathComponent(url.lastPathComponent)
                        isMissing = !FileManager.default.fileExists(atPath: dest.path)
                        if secStarted { sec.stopAccessingSecurityScopedResource() }
                    }

                    // Compute size synchronously (scope is held, no detached task needed)
                    let size = computeSize(of: url)

                    var task = BackupTask(
                        folderName:  url.lastPathComponent,
                        relativePath: url.lastPathComponent,
                        bookmarkData: BookmarkManager.createBookmark(for: url)
                    )
                    task.isMissingOnBackup = isMissing
                    task.sizeBytes = size
                    
                    // Recover persistent 'Synced' status from history
                    let absPath = main.appendingPathComponent(task.relativePath).path
                    if SyncHistoryManager.shared.date(for: absPath) != nil {
                        task.status = .success
                        task.progress = 1.0
                    }
                    
                    collected.append(task)
                }

                collected.sort { $0.folderName < $1.folderName }
                self.tasks = collected

            } catch {
                self.log("⚠️ Failed to scan main disk: \(error.localizedDescription)\n")
            }
        }
    }

    /// Computes total size of a directory synchronously. Called from @MainActor context
    /// while the security scope is still held — safe to use FileManager directly.
    private func computeSize(of url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        // Iterate synchronously — no async boundary, no makeIterator issue
        while let itemURL = enumerator.nextObject() as? URL {
            if let size = (try? itemURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Sound

    private enum SoundType { case success, failure }

    private func playSound(_ type: SoundType) {
        guard !isMuted else { return }
        switch type {
        case .success: Self.successSound?.play()
        case .failure: Self.failureSound?.play()
        }
    }

    // MARK: - Log

    func log(_ text: String) {
        logOutput += text
        if logOutput.count > 100_000 {
            logOutput = String(logOutput.suffix(80_000))
        }
    }

    // MARK: - Task Status & Progress

    /// Updates task and global progress using a 0.0–1.0 file-queue fraction from `to-chk=X/Y` parser.
    /// - Parameters:
    ///   - id: The task whose row progress bar to update.
    ///   - fraction: Fraction of files processed for this specific task (0.0 – 0.99).
    ///   - queueTotalBytes: Sum of `targetBytes` across all queued tasks; used for byte-weighted global ring.
    private func updateTaskProgressFraction(id: UUID, fraction: Double, queueTotalBytes: Int64) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        // Per-folder row bar: clamp strictly to 0.99 while running
        tasks[index].progress = min(0.99, max(0.01, fraction))

        // Global ring: byte-weighted sum of all completed + current fraction
        // Weight each task by its share of total bytes so a 1 GB folder counts more than a 1 MB one.
        let totalBytes = max(1, queueTotalBytes)
        var weightedDone: Double = 0
        for t in tasks {
            let weight = Double(max(1, t.targetBytes)) / Double(totalBytes)
            if t.id == id {
                weightedDone += weight * fraction
            } else if t.status == .success || t.status == .failed {
                weightedDone += weight * 1.0
            } else if t.progress > 0 {
                weightedDone += weight * t.progress
            }
        }
        globalProgress = min(0.99, max(0.0, weightedDone))
    }

    private func setStatus(_ id: UUID, _ status: SyncStatus, date: Date? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = status
        if let d = date { tasks[index].lastSyncDate = d }
        if status == .success { 
            tasks[index].progress = 1.0 
            tasks[index].isMissingOnBackup = false
        }
        if status == .idle { tasks[index].progress = 0.0 }
    }
    
    // MARK: - Deletion Confirmation
    
    func resolveDeletion(approved: Bool, applyToAll: Bool) {
        if applyToAll { applyToAllDeletions = true }
        deletionContinuation?.resume(returning: approved)
        deletionContinuation = nil
        if applyToAllDeletions || !approved {
            isReviewingDeletions = false
        }
    }

    private func showDeletionConfirmation(for path: String) async -> Bool {
        if applyToAllDeletions { return true }
        
        isReviewingDeletions = true
        let approved: Bool = await withCheckedContinuation { continuation in
            self.deletionContinuation = continuation
        }
        return approved
    }

    // MARK: - Helpers

    private func pickFolder(message: String, startingAt dir: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.message               = message
        panel.canChooseDirectories  = true
        panel.canChooseFiles        = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories  = true
        if let dir { panel.directoryURL = dir }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func pickVolume(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message               = message
        panel.canChooseDirectories  = true
        panel.canChooseFiles        = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories  = false
        panel.directoryURL          = URL(fileURLWithPath: "/Volumes")
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let isVol = (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
        if isVol { return url }
        if url.pathComponents.count == 3 && url.path.hasPrefix("/Volumes/") { return url }
        return nil
    }

    // MARK: - Persistence

    private func restoreState() {
        syncEntireDrive = UserDefaults.standard.bool(forKey: Keys.syncMode)

        if let data = UserDefaults.standard.data(forKey: Keys.mainBookmark),
           let url  = BookmarkManager.resolveBookmark(data) { mainDriveURL = url }

        if let data = UserDefaults.standard.data(forKey: Keys.secondaryBookmark),
           let url  = BookmarkManager.resolveBookmark(data) { secondaryDriveURL = url }

        if let data    = UserDefaults.standard.data(forKey: Keys.tasks) {
            loadTasksFromDefaults(data: data)
        }

        isMuted = UserDefaults.standard.bool(forKey: Keys.isMuted)
        useChecksum = UserDefaults.standard.bool(forKey: Keys.useChecksum)
    }
    
    // Safely loads the persistent task configuration into the active UI state
    private func loadTasksFromDefaults(data: Data) {
        if let decoded = try? JSONDecoder().decode([BackupTask].self, from: data) {
            tasks = decoded.map {
                var t = $0
                // Reset UI state that shouldn't persist across launches
                t.isMissingOnBackup = false
                t.progress = 0.0

                // Recover persistent 'Synced' status from history
                if let main = mainDriveURL {
                    let absPath = main.appendingPathComponent(t.relativePath).path
                    if SyncHistoryManager.shared.date(for: absPath) != nil {
                        t.status = .success
                        t.progress = 1.0
                    } else {
                        t.status = .idle
                    }
                } else {
                    t.status = .idle
                }
                return t
            }
        }
    }
    func saveTasks() {
        if let encoded = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(encoded, forKey: Keys.tasks)
        }
        UserDefaults.standard.set(syncEntireDrive, forKey: Keys.syncMode)
        UserDefaults.standard.set(isMuted, forKey: Keys.isMuted)
        UserDefaults.standard.set(useChecksum, forKey: Keys.useChecksum)
    }

    // MARK: - Schedule Timer

    /// Call this whenever schedule settings might have changed.
    /// Tears down the old timer and starts a new one if configured.
    func setupScheduler() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil

        let enabled  = UserDefaults.standard.bool(forKey: SchKeys.enabled)
        let hours    = UserDefaults.standard.double(forKey: SchKeys.interval)  // stored as Double (hours)
        guard enabled, hours > 0 else { return }

        let interval = hours * 3600
        // Timer fires on the main run loop — safe to call syncAll() which is @MainActor
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSyncing else { return }
                self.syncAll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    // MARK: - Disk Availability

    private func handleDriveAvailabilityChange() {
        if mainDriveURL == nil || secondaryDriveURL == nil {
            // UI Cleanup: Wipe the active memory array so the UI renders the Empty State
            // Do NOT call saveTasks() here, we want to retain the UserDefaults configuration.
            tasks = []
        } else {
            // Both disks are valid, reload appropriate context
            if syncEntireDrive {
                refreshFullDiskTasks()
            } else {
                if let data = UserDefaults.standard.data(forKey: Keys.tasks) {
                    loadTasksFromDefaults(data: data)
                }
            }
        }
    }

    /// Checks on launch whether the persisted disk paths still exist.
    /// Clears URLs and task list if paths are unreachable to prevent ghost syncs.
    private func checkDiskAvailability() {
        if let url = mainDriveURL, !FileManager.default.fileExists(atPath: url.path) {
            mainDriveURL = nil
            tasks = []
            log("⚠️ Main disk not available — cleared.\n")
        }
        if let url = secondaryDriveURL, !FileManager.default.fileExists(atPath: url.path) {
            secondaryDriveURL = nil
            log("⚠️ Backup disk not available — cleared.\n")
        }
    }

    // MARK: - Volume Monitor

    private func setupVolumeMonitor() {
        let nc = NSWorkspace.shared.notificationCenter
        
        // Unmount: clear the matching drive URL
        nc.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let path = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let main = self.mainDriveURL, main.path.hasPrefix(path) {
                    self.mainDriveURL = nil
                    self.log("⚠️ Main disk unmounted. Task list cleared.\n")
                }
                if let sec = self.secondaryDriveURL, sec.path.hasPrefix(path) {
                    self.secondaryDriveURL = nil
                    self.log("⚠️ Backup disk unmounted.\n")
                }
            }
        }
        
        // Mount: attempt to restore bookmarks if a newly-mounted volume matches our saved ones
        nc.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tryRestoreBookmarksAfterMount()
            }
        }
    }
    
    // MARK: - Disk Watchdog
    
    private func startDiskWatchdog() {
        diskWatchdogTimer?.invalidate()
        let wt = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.validateDiskConnection()
            }
        }
        RunLoop.main.add(wt, forMode: .common)
        diskWatchdogTimer = wt
    }
    
    /// Uses FileManager to detect physically ejected drives that may not have triggered a notification.
    private func validateDiskConnection() {
        guard !isSyncing else { return } // Don't abort mid-sync
        var didChange = false
        if let url = mainDriveURL, !FileManager.default.fileExists(atPath: url.path) {
            log("⚠️ Watchdog: Main disk gone. Clearing.\n")
            mainDriveURL = nil   // triggers didSet → handleDriveAvailabilityChange
            didChange = true
        }
        if let url = secondaryDriveURL, !FileManager.default.fileExists(atPath: url.path) {
            log("⚠️ Watchdog: Backup disk gone. Clearing.\n")
            secondaryDriveURL = nil
            didChange = true
        }
        if didChange {
            alertMessage = "A disk was disconnected. Please reconnect to continue."
        }
    }
    
    private func tryRestoreBookmarksAfterMount() {
        var didRestore = false
        if mainDriveURL == nil,
           let data = UserDefaults.standard.data(forKey: Keys.mainBookmark),
           let url  = BookmarkManager.resolveBookmark(data),
           FileManager.default.fileExists(atPath: url.path) {
            mainDriveURL = url
            didRestore = true
        }
        if secondaryDriveURL == nil,
           let data = UserDefaults.standard.data(forKey: Keys.secondaryBookmark),
           let url  = BookmarkManager.resolveBookmark(data),
           FileManager.default.fileExists(atPath: url.path) {
            secondaryDriveURL = url
            didRestore = true
        }
        if didRestore {
            log("✅ Disk reconnected. Sessions restored.\n")
        }
    }
}
