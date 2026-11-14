import Foundation
import os

/// Appends sync log lines to a rotating file under ~/Library/Logs/BackupFlow so a crashed
/// or force-quit sync can still be diagnosed after the in-memory log console is gone.
enum FileLogger {
    private static let maxBytes = 2 * 1024 * 1024 // rotate at 2 MB, keep one previous file

    /// Where failures of the log file itself are reported — they can't go into the file.
    private static let diagnostics = Logger(subsystem: "com.backupflow.app", category: "FileLogger")

    private static let logsDirectory: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BackupFlow", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            diagnostics.error("Could not create the log directory: \(error.localizedDescription, privacy: .public)")
        }
        return dir
    }()

    private static var currentLogURL: URL { logsDirectory.appendingPathComponent("backupflow.log") }
    private static let queue = DispatchQueue(label: "com.backupflow.filelogger")

    static func append(_ text: String) {
        queue.async {
            rotateIfNeeded()
            let data = Data(text.utf8)
            guard FileManager.default.fileExists(atPath: currentLogURL.path) else {
                write(data)
                return
            }
            do {
                let handle = try FileHandle(forWritingTo: currentLogURL)
                defer { close(handle) }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                diagnostics.error("Could not append to the log file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func write(_ data: Data) {
        do {
            try data.write(to: currentLogURL)
        } catch {
            diagnostics.error("Could not create the log file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func close(_ handle: FileHandle) {
        do {
            try handle.close()
        } catch {
            diagnostics.error("Could not close the log file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func rotateIfNeeded() {
        let size: Int
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: currentLogURL.path)
            size = (attrs[.size] as? Int) ?? 0
        } catch {
            return  // no log file yet — nothing to rotate
        }
        guard size > maxBytes else { return }

        let backupURL = logsDirectory.appendingPathComponent("backupflow.previous.log")
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.moveItem(at: currentLogURL, to: backupURL)
        } catch {
            diagnostics.error("Could not rotate the log file: \(error.localizedDescription, privacy: .public)")
        }
    }
}
