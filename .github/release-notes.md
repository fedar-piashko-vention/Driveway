Free, open-source NTFS read/write for Apple Silicon Macs, built on macFUSE and ntfs-3g.

**Requires macFUSE 5.4.0 or later**, macOS 15.4 or later, Apple Silicon and Homebrew.

## Install

1. Download `Driveway-<version>.dmg` below and drag Driveway to Applications.
2. Open it. macOS blocks the first launch because the app is ad-hoc signed, not notarized. Open System Settings > Privacy & Security, scroll down and click **Open Anyway** next to Driveway.
3. Use the Setup screen to install macFUSE, ntfs-3g and the Driveway helper.
4. Uninstall Tuxera NTFS or Paragon first if you have them. Driveway backs off from drives they mount.

See the README for the limits: ext drives are read-only in this version, `ntfsfix` is not `chkdsk`, and NTFS writing needs a working mount backend on your Mac.
