# Driveway

Driveway is a free, open-source utility that mounts NTFS drives read/write on Apple Silicon Macs. It is a free replacement for the parts of Tuxera NTFS for Mac that most people use. It does not contain a filesystem driver of its own. It orchestrates existing tools: macFUSE, ntfs-3g and e2fsprogs, installed through Homebrew.

- **Auto-mount.** Plug in an NTFS drive and it mounts read/write, with or without the Driveway window open.
- **Disk Manager.** A window with a sidebar of your drives and three tabs: **Info**, **Check & Repair** and **Format**.
- **Setup.** A screen that shows which features are ready, which tools are missing, and installs them for you.
- **Dirty drives are never changed silently.** A drive Windows did not shut down cleanly mounts read-only, and you get a notification and a **Fix & mount read/write** button.

## Limits, stated plainly

- **NTFS writing needs a working mount backend.** Driveway uses macFUSE's kernel backend on a Mac that already allows third-party kernel extensions (for example because Tuxera or Paragon is or was installed). Otherwise it uses macFUSE's FSKit backend. FSKit is currently broken on macOS 15.7.x: mounts fail even for simple test filesystems. On such a Mac with default settings, drives cannot be written yet, and Setup says "Not available on this Mac yet". Drives stay readable through macOS's own read-only NTFS support.
- **Driveway never asks you to lower your Mac's security.** It does not guide you through Recovery or kernel-extension settings, and it never changes them itself. Where the kernel backend is available, that is because your Mac already allows it.
- **ext drives are read-only in v1.** The Homebrew tap Driveway uses has no read/write ext driver. ext volumes mount read-only through `ext4fuse`. Check & Repair and Format for ext work through e2fsprogs.
- **`ntfsfix` is not `chkdsk`.** Check & Repair fixes common problems, such as a drive that was unplugged without ejecting. It does not repair deeper damage. For that, connect the drive to a Windows PC and run `chkdsk /f`. Back up first. Driveway offers to image the drive before a repair.
- **Speed was measured only on a disk image.** With the kernel backend, ntfs-3g wrote 1 GB to a 2 GB disk image on the internal SSD at about 206 MB/s. That is not representative of a USB drive, and no real-drive or FSKit number exists yet. FSKit is documented by macFUSE as slower than the kernel backend, and ntfs-3g is likely to be slower than Tuxera. That trade-off is accepted.
- **Unsigned build.** There is no paid Apple Developer account behind this project, so builds are ad-hoc signed and not notarized. Each user has to allow the app once (see below). Whether to trust it is your decision. The source is here, and you can build it yourself.
- **Not tested on Intel Macs.**

## Requirements

- macOS 15.4 or later
- Apple Silicon
- [Homebrew](https://brew.sh), at `/opt/homebrew`
- macFUSE 5.4.0 or later. Earlier 5.x versions can write zero-filled data for small writes on FSKit, so Driveway refuses to mount with them. Setup installs macFUSE for you, and macFUSE's licence does not allow bundling it.

## Uninstall Tuxera and Paragon first

Tuxera NTFS for Mac and Paragon NTFS install their own filesystem drivers, which claim NTFS drives before Driveway can. Driveway never fights another driver for a drive: if one of them mounts a drive, Driveway backs off and the drive's Info tab says who mounted it. Setup shows a warning when it finds one of them. Remove them with their own uninstallers before using Driveway.

## Install

1. Download `Driveway-<version>.dmg` from the [Releases](../../releases) page. Open it and drag **Driveway** onto the **Applications** shortcut.
2. Open Driveway from Applications. macOS says it cannot verify the app and blocks it. Click **Done** (or **OK**).
3. Open **System Settings > Privacy & Security** and scroll down to the Security section. You will see a message that "Driveway" was blocked. Click **Open Anyway**, then confirm with your password or Touch ID, and click **Open Anyway** once more in the dialog that follows.
4. The Setup screen opens. Click **Unlock everything**, or unlock one feature at a time:
   - Setup runs `brew install` for the tools, with live output. It installs the `gromgit/fuse` tap formulas `ntfs-3g-mac` and `ext4fuse-mac`, `e2fsprogs`, and the `macfuse` cask. The tap prints "not trusted" warnings and asks for confirmation. Setup shows the question, and nothing proceeds until you click **Continue**.
   - macFUSE asks for your password, then needs a one-time approval in System Settings. Setup shows **Needs approval** with an **Open Settings** button and re-checks when you come back. A restart may follow.
   - The Driveway helper installs with one administrator password prompt.
5. Plug in an NTFS drive. It should mount read/write within a few seconds.

Setup opens again by itself if something goes missing later, for example after a macOS update. You can also open it from **Driveway > Setup…**.

## Uninstall Driveway

Choose **Driveway > Uninstall Driveway Helper…** and confirm. This stops and removes the helper and the login agent. Then drag Driveway from Applications to the Trash.

To remove it by hand, in Terminal:

```sh
launchctl bootout "gui/$(id -u)/app.driveway.agent"
sudo launchctl bootout system/app.driveway.helper
sudo rm -f /Library/LaunchAgents/app.driveway.agent.plist \
           /Library/LaunchDaemons/app.driveway.helper.plist \
           /Library/PrivilegedHelperTools/app.driveway.helper
sudo rm -rf /Library/Logs/Driveway
```

Your settings in `/Library/Application Support/Driveway` are kept on purpose, so a reinstall remembers your choices. Delete that folder to remove them too. macFUSE, ntfs-3g and the other Homebrew tools stay installed. Remove them with `brew uninstall` if you no longer need them.

## Building from source

You need Xcode 26.3 or later (Swift 6.2) on an Apple Silicon Mac running macOS 15.4 or later. The package manifest uses `swift-tools-version: 6.0` and the code uses Swift 6 language mode, so Xcode 16.x is not what it is built and tested with.

```sh
swift test                         # unit tests
scripts/build-app.sh 0.1.0         # build/Driveway.app and build/Driveway-0.1.0.dmg
```

`build-app.sh` builds for arm64, assembles the app with its helper and agent, ad-hoc signs everything with the hardened runtime, and creates the dmg. The version must look like `1.2.3` or `1.2.3-rc1`.

CI runs on GitHub's `macos-15` (Apple Silicon) runner. That image's default Xcode is 16.4, so the workflows select the Xcode 26.3 that the image also ships (`sudo xcode-select -s /Applications/Xcode_26.3.app`), the same version used for local builds. Pushing a tag that starts with `v` runs the release workflow, which tests, builds the dmg and attaches it to a GitHub release with the notes from `.github/release-notes.md`.

## How it works

The app runs as you. A small helper runs as root, because ntfs-3g, `ntfsfix`, `mkntfs`, `e2fsck` and `mkfs.ext4` need raw disk access. The helper only accepts requests from Driveway, asks for an administrator password before anything destructive (Format, Repair, Fix), and refuses to touch the disk that holds macOS, any APFS or macOS system disk, and any disk image you did not attach for testing. Format and repair are never offered for those.

## Licence

[MIT](LICENSE). Driveway runs ntfs-3g and e2fsprogs as separate programs rather than linking them.
