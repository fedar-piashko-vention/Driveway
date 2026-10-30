# Spike results: ntfs-3g on macFUSE FSKit

Filled in by the owner while running `scripts/spike/README.md`. Replace every `TBD`.

- Date: TBD
- Mac: TBD (model, macOS version)
- macFUSE version (`CFBundleVersion`): TBD
- ntfs-3g version (`ntfs-3g --version`): TBD

## Risks

| # | Risk | Result (PASS / FAIL / UNTESTED) | Evidence |
|---|---|---|---|
| 1 | ntfs-3g mounts NTFS read/write on macFUSE's FSKit backend and data survives unmount/remount | TBD | TBD (log file, hashes, 1 GB + 2,000 files) |
| 2 | The mount works from a root LaunchDaemon; volume shows in Finder; files owned by console user | TBD | TBD |
| 3 | A DiskArbitration mount-approval callback can block macOS's read-only NTFS mount, and what it does to our FSKit mount | TBD | TBD |
| 4 | Dirty NTFS (unclean unplug, Fast Startup) is reported with usable exit codes / stderr | TBD (or `untested`) | TBD |
| 5 | ext4 mounts via ext4fuse on FSKit and files are readable | TBD | TBD |

## Tool paths

| Tool | Installed path | Version / note |
|---|---|---|
| ntfs-3g | TBD | TBD |
| ntfsfix | TBD | |
| ntfsinfo | TBD | |
| mkntfs | TBD | |
| ntfsclone | TBD | |
| ntfslabel | TBD | |
| ext4fuse | TBD | |
| e2fsck | TBD | |
| mkfs.ext4 | TBD | |
| macFUSE | `/Library/Filesystems/macfuse.fs` | `CFBundleVersion` = TBD |

## ntfs-3g exit code and stderr

Mount command: `sudo ntfs-3g <dev> /Volumes/SPIKE -o backend=fskit,volname=SPIKE,uid=<uid>,gid=<gid>`

| Case | Exit code | stderr (verbatim) | Notes |
|---|---|---|---|
| Clean image, first mount | TBD | TBD | |
| Clean image, remount | TBD | TBD | |
| From LaunchDaemon (step 4) | TBD | TBD | |
| Unclean unplug (step 6) | TBD / untested | TBD | |
| Fast Startup shutdown (step 6) | TBD / untested | TBD | |
| Hibernated / other failure, if seen | TBD | TBD | |

## Mount options rejected or ignored

| Option | Passed to | Outcome (accepted / rejected / ignored) | Evidence |
|---|---|---|---|
| `backend=fskit` | ntfs-3g | TBD | TBD |
| `volname=SPIKE` | ntfs-3g | TBD | TBD |
| `uid=<uid>` | ntfs-3g | TBD (do files show your uid?) | TBD |
| `gid=<gid>` | ntfs-3g | TBD | TBD |
| `allow_other` | ext4fuse | TBD | TBD |
| (others) | | | |

Final option list for the mount commands: TBD

## Speed

Drive: TBD (USB 3 SSD model, size). Native read-only comparison is read-only.

| Mount | Write MB/s (4096 MB dd) | Read MB/s (4096 MB dd) | `cp -R` 10,000 files of 4-64 KB (s) |
|---|---|---|---|
| ntfs-3g on FSKit (read/write) | TBD | TBD | TBD |
| macOS native NTFS (read-only) | n/a | TBD | TBD |

## DiskArbitration callback observations

| Scenario | Callback fired? | `DAVolumeKind` | `DAVolumePath` | `DAMediaBSDName` / `DADeviceModel` | Outcome |
|---|---|---|---|---|---|
| Image attached without `-nomount`, callback dissenting on `ntfs` | TBD | TBD | TBD | TBD | TBD (read-only mount blocked?) |
| FSKit mount while callback active (log-only) | TBD | TBD | TBD | TBD | TBD |
| FSKit mount while callback dissenting on `ntfs` | TBD | TBD | TBD | TBD | TBD (blocked or not?) |

Other DA description keys worth noting: TBD

## pluginkit (macFUSE approval detection)

Command: `pluginkit -m -v -p com.apple.fskit.fsmodule`

| State | Exact macFUSE line | Identifier | Marker (`+` / `-` / none) |
|---|---|---|---|
| Enabled in System Settings | TBD | TBD | TBD |
| Disabled in System Settings | TBD | TBD | TBD |
| Not installed (for reference) | none | none | n/a |

## Other findings

TBD

Decision: GO / NO-GO for NTFS writing: TBD
