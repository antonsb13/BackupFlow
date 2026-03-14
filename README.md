<h1 align="center">BackupFlow</h1>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.0+-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 14.0+">
  <img src="https://img.shields.io/badge/Swift-5.9+-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License MIT">
</p>

<p align="center">
  <b>A native, menu-bar-first synchronization and backup tool for macOS.</b><br>
  Built with SwiftUI, powered by `rsync`, and designed for professional workflows.
</p>

---

## 🚀 Overview

**BackupFlow** is a lightweight, background-focused macOS utility that ensures your critical folders or entire disks are perfectly mirrored to a backup location. Designed specifically for users dealing with large files (like video editors, developers, or audio engineers), it leverages the proven reliability of `rsync` while wrapping it in a beautiful, unobtrusive SwiftUI interface.

Unlike bulky cloud clients or complex terminal scripts, BackupFlow lives quietly in your Menu Bar, running scheduled tasks or manual syncs without interrupting your workflow.

## ✨ Key Features

- **Dual Sync Modes:**
  - 📁 **Custom Folders:** Hand-pick specific directories to back up.
  - 💽 **Full Disk (Mirror):** Create a 1:1 true mirror of an entire volume.
- **True Mirroring (`rsync --delete`):** Automatically removes files from the backup disk if they were deleted on the main disk, preventing your backup drive from overflowing with stale data.
- **Menu Bar Agent (`LSUIElement`):** Runs purely in the background. No Dock icon to clutter your workspace. Closes to the Menu Bar, not to quit.
- **Smart Scheduling:** Built-in background timer. Set it to sync every 15 minutes, hourly, or daily. The app handles the rest silently.
- **Granular Progress:** Real-time progress bars for *each* folder, plus a global progress ring. Driven by accurate `rsync` byte-transfer parsing.
- **Intelligent Sandboxing:** Strict adherence to macOS App Sandbox. Uses Security-Scoped Bookmarks to maintain read/write access to external drives even across app restarts and background cycles.
- **Metadata Filtering:** Automatically excludes annoying macOS system metadata (`.DS_Store`, `.Spotlight-V100`, `.Trashes`) to prevent "Operation not permitted" loops and keep the backup clean.
- **Safe Drive Detection:** Never writes blindly. The app verifies that the destination UUID/Path is actually mounted before starting a scheduled sync, triggering a native UI alert if a drive is missing.

## 🛠 How It Works Under the Hood

BackupFlow acts as a smart, visual wrapper around the robust Unix utility `rsync`. 

When a sync is triggered:
1. **Security Scopes:** The app securely unlocks access to the source and destination bookmarks stored in `UserDefaults`.
2. **Process Execution:** It spawns a background `Process()` executing `/usr/bin/rsync` with a carefully curated set of flags:
   - `-av --delete` (Archive mode + exact mirroring)
   - `--progress` (For streaming live ETA and completion percentages)
   - `--no-perms --no-owner --no-group` (Avoids strict Unix permission locks when syncing to ExFAT external drives)
   - `--exclude` (Robust ignore list for system trash and metadata)
3. **Log Parsing:** The stdout stream is intercepted. Noisy byte-counts are filtered out, while percentage `to-chk` outputs are converted into smooth UI updates.
4. **History:** Successful syncs are recorded in a `SyncHistoryManager`, bringing persistent "Synced" status tags to the UI upon the next launch.

## 🖥 Installation & Building

Since BackupFlow relies on deep macOS filesystem access, it is distributed as an Xcode project.

### Prerequisites
- macOS 14.0 (Sonoma) or newer.
- Xcode 15.0+ installed.

### Steps
1. Clone the repository:
   ```bash
   git clone https://github.com/antonsb13/BackupFlow.git
   ```
2. Open `BackupFlow.xcodeproj` in Xcode.
3. In the project settings -> **Signing & Capabilities**:
   - Select your personal Apple Developer Team.
   - *Note: Ensure the App Sandbox capability is active and File Access permissions for "User Selected File" are set to "Read/Write".*
4. Select the `BackupFlow` scheme targeting your Mac.
5. Hit `Cmd + R` (Run) or `Cmd + B` (Build).

## 📖 Usage Guide

1. **Launch the App:** You will see the BackupFlow icon appear in your Menu Bar at the top right of your screen. Click it to open the main window.
2. **Select Drives:** 
   - Click the left card to choose your **Main Disk** (Source).
   - Click the right card to choose your **Backup Disk** (Destination).
3. **Choose a Mode:**
   - **Folders:** Click the `+` icon in the toolbar to add specific high-priority folders.
   - **Full Disk:** Toggle the central switch to mirror everything.
4. **Sync:** Click the circular `Sync` button in the center. The progress rings will activate, and you can monitor the real-time status.
5. **Schedule (Optional):** Click the Calendar icon in the top right to set an automatic sync interval. You can close the window; the app will wake up and sync silently in the background.

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

---
*Built with ❤️ for macOS.*
