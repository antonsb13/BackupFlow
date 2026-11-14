# Privacy Policy — BackupFlow

**Version:** 1.8.5  
**Effective Date:** November 14, 2026

## Summary

BackupFlow is a **local-only** application. It does not collect, transmit, or store any user data on remote servers — ever.

## Data Collection

**None.** BackupFlow does not collect personal information, usage statistics, analytics, or crash reports.

## Data Storage

All application data is stored locally on your Mac, inside the app's sandbox container (`~/Library/Containers/com.backupflow.app/`):

| Data | Location |
|---|---|
| Drive bookmarks and volume identifiers (UUIDs) | `UserDefaults` (sandboxed) |
| Sync history (dates, keyed by folder path) | `UserDefaults` (sandboxed) |
| Task configuration (folder names and paths) | `UserDefaults` (sandboxed) |
| App settings (schedule, sound, Deletion Guard, checksum) | `UserDefaults` (sandboxed) |
| Sync log | `Data/Library/Logs/BackupFlow/backupflow.log` inside the container |

### Sync log

So that an interrupted or failed sync can still be diagnosed, BackupFlow writes its log console to a local file. The log contains **file and folder paths** (including disk names) of everything that was copied or deleted, plus any error messages from `rsync`.

- It stays on your Mac and is never sent anywhere.
- It is capped at 2 MB; when full it is renamed to `backupflow.previous.log`, so at most two files exist at any time.
- You can delete both files at any time. BackupFlow does not need them to work.

## File Access

BackupFlow uses macOS **Security-Scoped Bookmarks** to access only the folders and drives you explicitly select. All copying and mirroring is done by the system `rsync` tool.

The app itself:

- reads file **metadata** only (names and sizes), to show folder sizes and estimate transfers. It never reads file *contents*;
- deletes files on your backup drive itself only when you approve those deletions in the Deletion Guard. All other deletions are performed by `rsync --delete` as part of mirroring.

The **Deep Checksum** feature (`--checksum` flag) instructs `rsync` to hash files locally for comparison. No hash data is transmitted or stored outside of the local rsync process.

## Notifications

BackupFlow posts **local** macOS notifications (for example, when the backup drive is out of space). They are generated on your Mac; no push service or server is involved.

## Telemetry

BackupFlow contains **zero** telemetry: no analytics, no crash reporters, no tracking pixels, no network requests of any kind.

## Contact

Questions? Review the open-source code at [github.com/antonsb13/BackupFlow](https://github.com/antonsb13/BackupFlow).
