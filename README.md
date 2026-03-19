<h1 align="center">BackupFlow</h1>
<p align="center">
  <img src="Resources/screenshot.png" alt="BackupFlow Main Screen" width="600">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.0+-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 14.0+">
  <img src="https://img.shields.io/badge/Swift-5.9+-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/Version-1.7.0-brightgreen?style=for-the-badge" alt="Version 1.7.0">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License MIT">
</p>

<p align="center">
  <b>A native, menu-bar-first synchronization and backup tool for macOS.</b><br>
  Built with SwiftUI, powered by <code>rsync</code>, and designed for professional workflows.
</p>

---

## 🚀 Overview

**BackupFlow** is a lightweight, background-focused macOS utility that ensures your critical folders or entire disks are perfectly mirrored to a backup location. Designed specifically for users dealing with large files (video editors, developers, audio engineers), it leverages the proven reliability of `rsync` while wrapping it in a beautiful, unobtrusive SwiftUI interface.

Unlike bulky cloud clients, BackupFlow lives quietly in your Menu Bar, running scheduled tasks or manual syncs without interrupting your creative flow.

---

## ✨ Features (v1.7.0)

### Core Syncing
- **📁 Custom Folders** — Hand-pick specific directories to back up with per-folder progress bars.
- **💽 Full Disk Mirror** — Create a 1:1 true mirror of an entire volume (`rsync --delete`).
- **🔄 True Mirroring** — Ensures your backup is an exact replica of the source.
- **⏱ Smart Scheduling** — Background timer supports intervals from 15 minutes to a week. 

### Advanced Safety & Performance
- **🛡️ Advanced Deletion Guard** — Prevents accidental data loss with an intelligent pre-sync analysis and granular per-file confirmation modals before any removal.
- **📊 Byte-Based Progress Tracking** — Accurate 0-100% progress calculated via real-time byte stream parsing (immune to legacy rsync "100% hang" bugs).
- **🔬 System-Aware Filtering** — Automatically excludes macOS metadata (`.DS_Store`, `.Spotlight-V100`, `.Trashes`, etc.) to keep your backup clean.
- **🔍 Crystal Clear Logging** — The Log Console now displays **absolute paths** for every action, including folder-specific success/failure messages (e.g., `✅ Done: Davinci Resolve Media`).
- **⚙️ Legacy Compatibility** — Optimized engine designed to work seamlessly with macOS default `rsync (v2.6.9)`.
- **🔌 Smart Disk Detection** — Watchdog timer and `NSWorkspace` notifications automatically restore your folder list when a disk is reconnected.

### Security & Privacy
- **App Sandbox** — Uses Security-Scoped Bookmarks for persistent, secure drive access.
- **Local-Only** — Zero network requests, zero telemetry. Your data never leaves your hardware.
- **Rock-Solid Management** — Immediate termination of all background processes on app exit (no zombie tasks).

---

## 🛠 How It Works

BackupFlow utilizes a **Two-Step Sync Engine** to provide the most accurate feedback:

1. **Phase 1 — Calculation (Dry-run):** Executes `rsync -n --stats` to determine the exact total byte size of the pending transfer. The UI shows `Calculating...`.
2. **Phase 2 — Transferring:** Starts the real `rsync` process. BackupFlow parses the raw byte output in real-time, calculating progress as: `(Current Bytes) / (Total Size)`. 
3. **Phase 3 — Completion:** Only when `rsync` exits with a success code, the progress snaps to `1.0` and the status updates to `Synced`.

**Rsync Flags Used:**
`-rtv --delete --progress --no-perms --no-owner --no-group`

---

## 🖥 Installation

### Prerequisites
- macOS 14.0 (Sonoma) or newer.
- Xcode 15.0+ (for building from source).

### Steps
```bash
git clone [https://github.com/antonsb13/BackupFlow.git](https://github.com/antonsb13/BackupFlow.git)
cd BackupFlow
open BackupFlow.xcodeproj 
```
In **Xcode → Project Settings → Signing & Capabilities**:
- Select your **Apple Developer Team**.
- Ensure **App Sandbox** is enabled with **User Selected File** set to `Read/Write`.

Press `Cmd + R` to build and run.

---

## 📖 Usage

1. **Launch** — Click the BackupFlow icon in your Menu Bar.
2. **Select Drives** — Click the left card for **Main Disk** and the right card for **Backup Disk**.
3. **Choose Mode** — Toggle between **Folders** (custom) or **Full Disk** (mirror).
4. **Sync** — Press the circular Sync button. Confirm any deletions if prompted by the Deletion Guard.
5. **Monitor** — Track real-time absolute paths and weighted progress rings in the Log Console.

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.

---
*Built with ❤️ for the macOS Creative Community. v1.7.0 — March 2026.*