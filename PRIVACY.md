# Privacy Policy — BackupFlow

**Version:** 1.5.0  
**Effective Date:** March 15, 2026

## Summary

BackupFlow is a **local-only** application. It does not collect, transmit, or store any user data on remote servers — ever.

## Data Collection

**None.** BackupFlow does not collect personal information, usage statistics, analytics, or crash reports.

## Data Storage

All application data is stored locally on your Mac:

| Data | Location |
|---|---|
| Drive bookmarks | `UserDefaults` (sandboxed) |
| Sync history (dates) | `UserDefaults` (sandboxed) |
| Task configuration | `UserDefaults` (sandboxed) |
| App settings | `UserDefaults` (sandboxed) |

## File Access

BackupFlow uses macOS **Security-Scoped Bookmarks** to access folders and drives you explicitly authorize. Access is limited to read/write required for `rsync` mirroring. The app never reads file *contents* — `rsync` handles all I/O at the OS level.

The **Deep Checksum** feature (`--checksum` flag) instructs `rsync` to hash files locally for comparison. No hash data is transmitted or stored outside of the local rsync process.

## Telemetry

BackupFlow contains **zero** telemetry: no analytics, no crash reporters, no tracking pixels, no network requests of any kind.

## Contact

Questions? Review the open-source code at [github.com/antonsb13/BackupFlow](https://github.com/antonsb13/BackupFlow).
