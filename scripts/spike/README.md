# Driveway spike runbook

Goal: retire the five risks and decide GO / NO-GO for NTFS writing via ntfs-3g on macFUSE's FSKit backend.
Record everything in `docs/spike-results.md` (template provided). Logs from the scripts land in `build/spike/logs/` (gitignored).

**Safety:** use the disk images made by `make-images.sh` or a spare drive only. Never point these scripts at a drive that holds data you care about; `mkntfs`, `mkfs.ext4` and the mounts are not reversible. Several steps need `sudo` and System Settings approvals; those are yours to do.

All commands run from the repo root: `~/Projects/AI/Driveway`.

## Step 1: clean slate (owner only)

1. Uninstall Tuxera NTFS (its own uninstaller, then reboot if it asks). Check: `ls /Library/Filesystems` must **not** list `tuxera_ntfs.fs`.
2. `brew install --cask macfuse`, then approve it in System Settings → General → Login Items & Extensions → File System Extensions (enable the macFUSE module; restart if prompted). Needs macFUSE 5.4 or newer.
3. `brew install gromgit/fuse/ntfs-3g-mac gromgit/fuse/ext4fuse-mac e2fsprogs`
4. Record in the results doc: install paths and the macFUSE version.
   ```sh
   export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/e2fsprogs/bin:/opt/homebrew/opt/e2fsprogs/sbin:$PATH"
   for t in ntfs-3g ntfsfix ntfsinfo mkntfs ntfsclone ntfslabel ext4fuse e2fsck mkfs.ext4; do printf '%-12s %s\n' "$t" "$(command -v $t || echo MISSING)"; done
   defaults read /Library/Filesystems/macfuse.fs/Contents/Info.plist CFBundleVersion
   ```
   (`e2fsprogs` is keg-only, so its tools may live under `/opt/homebrew/opt/e2fsprogs/{bin,sbin}`. Record the real path.)

## Step 2: make the test images

```sh
scripts/spike/make-images.sh          # add --force to replace existing images
```
Creates `build/spike/ntfs.dmg` and `ext.dmg` (2 GB each), attaches them with `-nomount`, formats the data partitions (`mkntfs --quick --label SPIKE`, `mkfs.ext4 -F -L SPIKEEXT`) and prints the device nodes. It also saves them in `build/spike/{ntfs,ext}.dev` and `.disk`. You may get a sudo prompt if the device node isn't writable by you.
Record the two partition nodes (they change every attach).

## Step 3: risk 1, round trip

```sh
scripts/spike/ntfs-roundtrip.sh /dev/diskNsM       # NTFS partition from step 2
```
Mounts with `sudo ntfs-3g <dev> /Volumes/SPIKE -o backend=fskit,volname=SPIKE,uid=<you>,gid=<you>`, writes 1 GB random + 2,000 small files, hashes, unmounts, remounts, re-hashes and compares. Prints `PASS` or `FAIL` (exit code 0 / 1). Add `--keep-mounted` to leave it mounted at the end (needed for steps 5 and 8).
Record: the ntfs-3g exit code and stderr for each mount, PASS/FAIL, and which options were rejected or ignored (the script flags suspicious stderr lines; also check whether the files really show your uid, which tells you whether `uid=`/`gid=` were honoured). If `/Volumes/SPIKE` had to be created by hand, note that too.

## Step 4: risk 2, mount from a root LaunchDaemon

Unmount first (`umount /Volumes/SPIKE || sudo umount /Volumes/SPIKE`); keep the image attached. Then follow the commands in the comment block at the top of `scripts/spike/spike-daemon.plist` (copy to `/Library/LaunchDaemons`, `launchctl bootstrap`, later `bootout`). The daemon runs `scripts/spike/daemon-mount.sh`, which logs to `/var/log/driveway-spike.log`.
Check: `cat /var/log/driveway-spike.log`, then **wait about a minute after the script has exited and run `mount | grep SPIKE` again**: the mount must still be there (the plist sets `AbandonProcessGroup` so launchd doesn't kill ntfs-3g with the script, but verify it; a mount that vanishes is the real failure, not just the script's own log). The volume shows in Finder's sidebar, and `ls -l /Volumes/SPIKE` shows files owned by you (the console user), not root. Record the result. Remove the daemon when done.

## Step 5: risk 3, DiskArbitration approval callback

In a terminal that stays open:
```sh
swift scripts/spike/da-approval.swift         # dissents for DAVolumeKind == "ntfs"; add --log-only to only log
```
(This script is **uncompiled**; if it has a compile error, fix it and note the fix. If no callbacks fire, try `sudo swift ...`.)
1. Detach the images, then attach `build/spike/ntfs.dmg` **without** `-nomount` (`hdiutil attach build/spike/ntfs.dmg`). Confirm macOS's own read-only NTFS mount is blocked (the log shows `DISSENT`; the volume doesn't appear).
2. With the callback still running, attach with `-nomount` and run the step 3 mount. Record whether the callback fires for the FSKit mount, and whether dissenting blocks it (run once with `--log-only`, once without).
3. Copy the DA description keys/values logged for the FSKit-mounted volume, notably `DAVolumeKind` and `DAVolumePath`.
   - The script also logs `DESCRIPTION CHANGED` events, which is where `DAVolumePath` should appear once the mount completes on a disk attached with `-nomount`.
   - As a backup, capture these during and after the FSKit mount (in another terminal) and paste them into the results doc: `diskutil info -plist /dev/diskNsM` and `mount`.

## Step 6: risk 4, dirty NTFS (only if you have a Windows-used drive)

On a spare Windows-used NTFS drive: test after an unclean unplug and after a Windows Fast Startup shutdown. Mount it with the same `ntfs-3g` command and record the exit code and stderr in each case. If you have no such drive, write "untested" (the outcome classifier then keeps its default table).

## Step 7: risk 5, ext4 via ext4fuse

```sh
sudo mkdir -p /Volumes/SPIKEEXT     # only if ext4fuse complains the mountpoint is missing
sudo ext4fuse /dev/diskXsY /Volumes/SPIKEEXT -o backend=fskit,allow_other
```
Use the ext partition from step 2. Record whether it mounts and whether files are readable (the image is empty; write a file into it from Linux, or just check `ls` and `mount` output and that it reads without errors; note which).

## Step 8: speed, on a real USB 3 SSD

Use a real external SSD (not an image) formatted NTFS (disposable). Mount it with ntfs-3g as in step 3, then:
```sh
scripts/spike/speed.sh --keep --label "ntfs-3g FSKit" /Volumes/SPIKE     # prints a markdown row
```
`--purge` (needs sudo) drops the page cache before the reads. For the native read-only comparison: unmount, let macOS mount it natively read-only, then
```sh
scripts/spike/speed.sh --read-only --label "native ro" /Volumes/<name>
```
(`--read-only` skips the write test, reads the `driveway-speed` data left by `--keep`, and copies the 10,000 files off the volume.) Afterwards delete `driveway-speed` from the drive. Paste the rows into the speed table.

## Step 9: macFUSE approval detection

```sh
scripts/spike/pluginkit-check.sh enabled     # with macFUSE's File System Extension enabled
scripts/spike/pluginkit-check.sh disabled    # after turning it off in System Settings
```
Record the macFUSE identifier and its marker (`+` / `-` / none) for both states. Copy the two exact output lines (they're also saved in `build/spike/logs/pluginkit-*.txt`): `MacFUSEProbe` parses them.

## Step 10: write the results

Fill in `docs/spike-results.md`, including the final `Decision: GO / NO-GO for NTFS writing` line. On NO-GO, `Capabilities.ntfsWriteSupported = false`.

## Cleanup

```sh
umount /Volumes/SPIKE 2>/dev/null || sudo umount /Volumes/SPIKE
hdiutil detach /dev/diskN        # whole-disk node from make-images.sh (ntfs.disk / ext.disk)
```
