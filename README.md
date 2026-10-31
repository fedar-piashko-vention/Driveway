# Driveway

Driveway is a free, open-source utility that mounts NTFS drives read/write on Apple Silicon Macs. It is a free replacement for the parts of Tuxera NTFS for Mac that most people use. It does not contain a filesystem driver of its own. It orchestrates existing tools: macFUSE, ntfs-3g and e2fsprogs, installed through Homebrew.

- **Auto-mount.** Plug in an NTFS drive and it mounts read/write, with or without the Driveway window open. A drive plugged in before you logged in, or before Setup was finished, is mounted read/write once you log in or Setup finishes. A drive macOS holds read-only also has a **Mount read/write** button in its Info tab.
- **Disk Manager.** A window with a sidebar of your drives and three tabs: **Info**, **Check & Repair** and **Format**.
- **Setup.** A screen that shows which features are ready, which tools are missing, and installs them for you.
- **Dirty drives are never changed silently.** A drive Windows did not shut down cleanly mounts read-only, and you get a notification and a **Fix & mount read/write** button. Driveway mounts with ntfs-3g's `norecover` option, so ntfs-3g never clears the Windows journal on its own, and a drive that ntfs-3g mounts read-only anyway is reported as dirty or hibernated, not as read/write.

## Limits, stated plainly

- **NTFS writing needs a working mount backend.** Driveway uses macFUSE's kernel backend on a Mac that already allows third-party kernel extensions (for example because Tuxera or Paragon is or was installed). Otherwise it uses macFUSE's FSKit backend. FSKit is currently broken on macOS 15.7.x: mounts fail even for simple test filesystems. On such a Mac with default settings, drives cannot be written yet, and Setup says "Not available on this Mac yet". Drives stay readable through macOS's own read-only NTFS support.
- **Driveway never asks you to lower your Mac's security.** It does not guide you through Recovery or kernel-extension settings, and it never changes them itself. Where the kernel backend is available, that is because your Mac already allows it.
- **Hibernated and Fast Startup drives mount read-only, with no one-click fix.** Forcing such a drive read/write would destroy the unsaved Windows session. Shut Windows down fully, or turn off Fast Startup with `powercfg /hibernate off` in Windows.
- **ext drives are read-only in v1.** The Homebrew tap Driveway uses has no read/write ext driver. ext volumes mount read-only through `ext4fuse`. Check & Repair and Format for ext work through e2fsprogs. Mounted ext drives don't appear in Finder's sidebar yet: macOS can't recognise ext partitions, and Finder lists only drives it recognises. Open them with **Show in Finder** in Driveway, or from `/Volumes`.
- **`ntfsfix` is not `chkdsk`.** Check & Repair fixes common problems, such as a drive that was unplugged without ejecting. It does not repair deeper damage. For that, connect the drive to a Windows PC and run `chkdsk /f`. Back up first. Driveway offers to image the drive before a repair.
- **Speed was measured only on a disk image.** With the kernel backend, ntfs-3g wrote 1 GB to a 2 GB disk image on the internal SSD at about 206 MB/s. That is not representative of a USB drive, and no real-drive or FSKit number exists yet. FSKit is documented by macFUSE as slower than the kernel backend, and ntfs-3g is likely to be slower than Tuxera. That trade-off is accepted.
- **Full Disk Access may need granting again after an update.** Because the helper is ad-hoc signed, macOS may not recognise an updated helper as the program you allowed. Setup then lists Full Disk Access again. In Full Disk Access, remove the helper with **−** and add it again.
- **Unsigned build.** There is no paid Apple Developer account behind this project, so builds are ad-hoc signed and not notarized. Each user has to allow the app once (see below). Whether to trust it is your decision. The source is here, and you can build it yourself.
- **Not tested on Intel Macs.**

## Requirements

- macOS 15.4 or later
- Apple Silicon
- [Homebrew](https://brew.sh), at `/opt/homebrew`
- macFUSE 5.4.0 or later. Earlier 5.x versions can write zero-filled data for small writes on FSKit, so Driveway does not use them for writing. With an older macFUSE, Setup shows macFUSE as needing an update, and Driveway does not mount NTFS drives read/write. They stay read-only, as macOS mounts them. Setup installs macFUSE for you, and macFUSE's licence does not allow bundling it.

## Uninstall Tuxera and Paragon first

Tuxera NTFS for Mac and Paragon NTFS install their own filesystem drivers, which claim NTFS drives before Driveway can. Driveway never fights another driver for a drive: if one of them mounts a drive, Driveway backs off and the drive's Info tab says who mounted it. Setup shows a warning when it finds one of them. Remove them with their own uninstallers before using Driveway.

## Install

1. Download `Driveway-<version>.dmg` from the [Releases](../../releases) page. Open it and drag **Driveway** onto the **Applications** shortcut.
2. Open Driveway from Applications. macOS says it cannot verify the app and blocks it. Click **Done** (or **OK**).
3. Open **System Settings > Privacy & Security** and scroll down to the Security section. You will see a message that "Driveway" was blocked. Click **Open Anyway**, then confirm with your password or Touch ID, and click **Open Anyway** once more in the dialog that follows.
4. The Setup screen opens. Click **Unlock everything**, or unlock one feature at a time:
   - The Homebrew tools install inside Setup, with live output: the `gromgit/fuse` tap formulas `ntfs-3g-mac` and `ext4fuse-mac`, and `e2fsprogs`. The tap prints "not trusted" warnings and asks for confirmation. Setup shows the question, and nothing proceeds until you click **Continue**.
   - macFUSE is different. Setup opens a Terminal window that runs `brew install --cask macfuse`, and you type your password there. Afterwards Setup may show macFUSE as **Needs approval**, with an **Open Settings** button. This is macFUSE's own approval in the normal System Settings pane (Privacy & Security, or General > Login Items & Extensions), and Setup re-checks when you come back. A restart may follow. Driveway never asks you to change Recovery or any other security setting.
   - The Driveway helper installs with one administrator password prompt. Installing it makes `/Applications/Driveway.app` owned by root (the helper only trusts an app that ordinary users can't change), so replacing or deleting the app afterwards asks for an administrator password.
   - The helper then needs **Full Disk Access**. macOS lets a program open an external drive directly only with Full Disk Access, even when it runs as root. Tuxera's driver needs the same. Setup shows the step with an **Open Settings** button, which opens **System Settings > Privacy & Security > Full Disk Access**. Click **+**, press **⌘⇧G**, enter `/Library/PrivilegedHelperTools/app.driveway.helper.app` (Setup has a **Copy** button for it), click **Open** and turn the helper on. This gives one program access. It does not change a security setting. Without it, Driveway can't mount, check, repair, back up or format external drives: they stay read-only, mounted by macOS, and Driveway's notification and the drive's Info tab say that Full Disk Access is missing. A drive already plugged in is taken over within a few seconds of turning the helper on.
5. Plug in an NTFS drive. It should mount read/write within a few seconds.

Setup opens again by itself if something goes missing later, for example after a macOS update. You can also open it from **Driveway > Setup…**.

## Uninstall Driveway

Choose **Driveway > Uninstall Driveway Helper…** and confirm. This stops and removes the helper and the login agent, and gives the app back to you. Then drag Driveway from Applications to the Trash.

To remove it by hand, in Terminal:

```sh
launchctl bootout "gui/$(id -u)/app.driveway.agent"
sudo launchctl bootout system/app.driveway.helper
sudo rm -f /Library/LaunchAgents/app.driveway.agent.plist \
           /Library/LaunchDaemons/app.driveway.helper.plist
sudo rm -rf /Library/PrivilegedHelperTools/app.driveway.helper.app /Library/Logs/Driveway
sudo chown -R "$USER" /Applications/Driveway.app   # the helper's install made it root's
```

Without that last line, dragging Driveway to the Trash asks for an administrator password.

Your settings in `/Library/Application Support/Driveway` are kept on purpose, so a reinstall remembers your choices. Delete that folder to remove them too. macFUSE, ntfs-3g and the other Homebrew tools stay installed. Remove them with `brew uninstall` if you no longer need them.

## Building from source

You need Xcode 26.3 or later (Swift 6.2) on an Apple Silicon Mac running macOS 15.4 or later. The package manifest uses `swift-tools-version: 6.0` and the code uses Swift 6 language mode, so Xcode 16.x is not what it is built and tested with.

```sh
swift test                         # unit tests
scripts/build-app.sh 0.1.0         # build/Driveway.app and build/Driveway-0.1.0.dmg
```

`build-app.sh` builds for arm64, assembles the app with its helper and agent, ad-hoc signs everything with the hardened runtime, and creates the dmg. The version must look like `1.2.3` or `1.2.3-rc1`.

The app icon is `Packaging/Driveway.icns`. It is rendered from the gradient in `Packaging/Icon/gradient-source.png` by `scripts/make-icon.swift`. To change it, edit either file, then run `scripts/make-icon.sh` and commit the new `.icns`.

CI runs on GitHub's `macos-15` (Apple Silicon) runner. That image's default Xcode is 16.4, so the workflows select the Xcode 26.3 that the image also ships (`sudo xcode-select -s /Applications/Xcode_26.3.app`), the same version used for local builds. Pushing a tag that starts with `v` runs the release workflow, which tests, builds the dmg and attaches it to a GitHub release with the notes from `.github/release-notes.md`.

## How it works

The app runs as you. A small helper runs as root, because ntfs-3g, `ntfsfix`, `mkntfs`, `e2fsck` and `mkfs.ext4` need raw disk access. For external drives macOS also requires Full Disk Access for that, which you grant to the helper in Setup. The helper only accepts requests from Driveway, asks for an administrator password before Format, Repair, Fix & mount and Back up, and refuses to touch the disk that holds macOS, any APFS or macOS system disk, and any disk image you did not attach for testing. Format and repair are never offered for those.

## Licence

[MIT](LICENSE). Driveway runs ntfs-3g and e2fsprogs as separate programs rather than linking them.
