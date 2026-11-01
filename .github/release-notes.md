Free, open-source NTFS read/write for Apple Silicon Macs, built on macFUSE and ntfs-3g.

**Requires macFUSE 5.4.0 or later (5.5.0 or later on macOS 26 and later)**, macOS 15.4 or later, Apple Silicon and Homebrew.

## Install

1. Uninstall Tuxera NTFS or Paragon first if you have them. Driveway backs off from drives they mount.
2. Install [Homebrew](https://brew.sh) if you don't have it.
3. Paste this line into Terminal and press Return. It downloads the latest version, puts Driveway in Applications and opens it:

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/fedar-piashko-vention/Driveway/main/scripts/install.sh)"
   ```

4. Use the Setup screen to install macFUSE, ntfs-3g and the Driveway helper.

Driveway is ad-hoc signed, not notarized. If you download the DMG below in a browser instead, macOS says the app "is damaged and can't be opened". After dragging it to Applications, run `xattr -dr com.apple.quarantine /Applications/Driveway.app` in Terminal, then open it.

See the README for the limits: ext drives are read-only in this version, `ntfsfix` is not `chkdsk`, and NTFS writing needs a working mount backend on your Mac.
