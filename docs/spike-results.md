# Spike results: ntfs-3g on macFUSE (FSKit and kernel backends)

Run on the owner's Mac by following `scripts/spike/README.md`. Raw notes: `build/spike/findings-2026-10-30.md` (gitignored), logs in `build/spike/logs/`.

- Date: 2026-10-30
- Mac: MacBookPro18,3 (Apple Silicon), macOS 15.7.7 (24G720)
- macFUSE version (`CFBundleVersion`): 5.5.0
- ntfs-3g version (`ntfs-3g --version`): ntfs-3g 2026.9.28 external FUSE 29
- Tuxera NTFS (`/Library/Filesystems/tuxera_ntfs.fs`) was **still installed** for every test below.

**Decision: GO for NTFS writing, with hybrid backends.** FSKit fails on this macOS. The kernel backend works, and the owner chose hybrid: kernel where kexts are already allowed, FSKit otherwise.

## Risks

| # | Risk | Result | Evidence |
|---|---|---|---|
| 1a | ntfs-3g mounts NTFS read/write on macFUSE's **FSKit** backend | **FAIL** | 4 runs (15:04–15:10): ntfs-3g exits 0 with empty stderr, but no mount appears. The macFUSE daemon logs `Failed to mount volume: MFDaemon.MountError Code=4`. Same for unprivileged `ext4fuse -o backend=fskit`, after a reboot, and with `backend=fskit,local`. Matches the cvmfs report (PR #4468) of an FSKit regression in later macOS 15.7 updates. |
| 1b | ntfs-3g mounts NTFS read/write on macFUSE's **kernel** backend and data survives unmount/remount | **PASS** | `BACKEND=kernel scripts/spike/ntfs-roundtrip.sh /dev/disk4s1` (17:09). Both mounts exit 0 with empty stderr; mount type `macfuse, nodev, synchronous`. 1 GB random file + 2,000 small files: all 2,001 SHA-256 hashes identical after remount. |
| 2 | The mount works from a root LaunchDaemon; volume shows in Finder; files owned by console user | UNTESTED (carried over) | `uid=`/`gid=` work (files show 501/20). A plain user `umount` of a root-started mount → `Operation not permitted`; `sudo umount` works, so unmount/eject goes through the helper. Daemon start and Finder eject are tested end to end later. |
| 3 | A DiskArbitration mount-approval callback can block macOS's read-only NTFS mount | UNTESTED (carried over) | Needs Tuxera uninstalled. `scripts/spike/da-approval.swift` compiles and is ready. Also seen: after `mkntfs`, DA still reports the image partition as **ExFAT** (stale probe), so detection must read the boot sector (`FilesystemProbe.detect(header:)`). |
| 4 | Dirty NTFS is reported with usable exit codes / stderr | untested | No Windows-used drive available. The outcome classifier keeps its default table (12 not NTFS, 13 corrupt, 14 hibernated, 15 unclean, 19 no privilege; 19 seen when ntfs-3g runs without root). |
| 5 | ext4 mounts via ext4fuse and files are readable | **PASS on kernel**, FAIL on FSKit | Kernel backend: `ext4fuse` mounts (exit 0, type `macfuse`, kext `io.macfuse.filesystems.macfuse.23` 5.5.0 loaded). FSKit: `MountError Code=4` as in 1a. |

## Tool paths

All match `ToolPaths`.

| Tool | Installed path | Version / note |
|---|---|---|
| ntfs-3g | `/opt/homebrew/bin/ntfs-3g` | 2026.9.28 (`gromgit/fuse/ntfs-3g-mac`) |
| ntfsfix | `/opt/homebrew/bin/ntfsfix` | |
| ntfsinfo | `/opt/homebrew/bin/ntfsinfo` | |
| mkntfs | `/opt/homebrew/sbin/mkntfs` | |
| ntfsclone | `/opt/homebrew/sbin/ntfsclone` | |
| ntfslabel | `/opt/homebrew/sbin/ntfslabel` | |
| ext4fuse | `/opt/homebrew/bin/ext4fuse` | `gromgit/fuse/ext4fuse-mac`, read-only |
| e2fsck | `/opt/homebrew/opt/e2fsprogs/sbin/e2fsck` | e2fsprogs 1.47.4, keg-only |
| mkfs.ext4 | `/opt/homebrew/opt/e2fsprogs/sbin/mkfs.ext4` | |
| macFUSE | `/Library/Filesystems/macfuse.fs` | `CFBundleVersion` = 5.5.0 |

The `gromgit/fuse` tap prints "not trusted" warnings on install. The formulas still install after a y/n prompt, so Setup's brew sheet must pass that prompt through or explain it.

## ntfs-3g exit code and stderr

| Case | Exit code | stderr | Notes |
|---|---|---|---|
| FSKit, clean image (4 runs) | 0 | (empty) | No mount appears. This is the silent failure that the 5-second mount check (Global Constraints) catches. |
| Kernel, clean image, first mount | 0 | (empty) | |
| Kernel, clean image, remount | 0 | (empty) | |
| No root (`ntfs-3g` as the user) | 19 | "Unprivileged user can not mount NTFS block devices using the external FUSE library" | |
| From LaunchDaemon | untested | | later |
| Unclean unplug / Fast Startup | untested | | |

## Mount options

| Option | Passed to | Outcome | Evidence |
|---|---|---|---|
| `backend=fskit` | ntfs-3g, ext4fuse | accepted, but FSKit mounts fail (1a) | |
| `local` (with fskit) | ext4fuse | accepted, no change | still `MountError Code=4` |
| `volname=SPIKE` | ntfs-3g | accepted | |
| `uid=<uid>`, `gid=<gid>` | ntfs-3g (kernel) | accepted and applied | files listed as 501/20 |

Final option list: kernel `volname=<label>,uid=<uid>,gid=<gid>[,ro]`; FSKit `backend=fskit,` + the same.

## Speed

Measured on a disk image only. The real USB 3 SSD comparison (spike Step 8) is carried over to the release check.

| Mount | Write | Note |
|---|---|---|
| ntfs-3g, kernel backend, 2 GB disk image | ~206 MB/s (1 GB `dd` from `/dev/urandom`) | Disk image on the internal SSD, so the cache helps. Not representative of USB drives. |

## DiskArbitration observations

Not run yet (risk 3). One finding so far: DA's `DAVolumeKind` was stale (ExFAT) for the image partition after `mkntfs`. Our kernel mounts show mount type `macfuse`.

## macFUSE approval detection

| Check | Command | Observation |
|---|---|---|
| FSKit module | `pluginkit -m -v -p com.apple.fskit.fsmodule` | Only `io.macfuse.app.fsmodule.macfuse-local` registers, and only after the first `backend=fskit` mount attempt. Until it's enabled in System Settings → General → Login Items & Extensions → File System Extensions, mounts fail with "Attempt to start disabled extension". While enabled, the line's first column is **blank, not `+`**, so `MacFUSEProbe.isApproved` must not require `+`. Treat a leading `-` as disabled. |
| Kernel extension loaded | `kmutil showloaded --list-only` | `io.macfuse.filesystems.macfuse.23 (5.5.0)` after the first kernel-backend mount |
| Kexts allowed by policy | `sudo bputil -d`, `KextPolicy` db | see "Kernel extension policy" below |

The macFUSE kext was blocked at 15:09 and approved by the owner at 15:10 in Privacy & Security. Tuxera's kext is also allowed, so this Mac already runs with third-party kexts enabled.

## Kernel extension policy

Captured on 2026-10-30. Device identifiers (ECID, nonce and image hashes) are left out on purpose.

`sudo bputil -d` (root only; `bputil -d` as a user prints "The tool requires running as root"). The relevant lines, verbatim:

```
Security Mode:               Reduced    (smb0): 1
3rd Party Kexts Status:      Enabled    (smb2): 1
SIP Status:                  Enabled    (sip0): absent
```

`kextsAllowed` = the `3rd Party Kexts Status:` line says `Enabled`. On a Mac with Full Security the line reads `Disabled` (or `smb2` is absent). Treat anything other than `Enabled` as not allowed.

`/var/db/SystemPolicyConfiguration/KextPolicy`, table `kext_policy` (root only). The macFUSE rows:

```
team_id|bundle_id|allowed|developer_name|flags
3T5GSNBU6W|io.macfuse.filesystems.macfuse.21|1|Benjamin Fleischer|5
3T5GSNBU6W|io.macfuse.filesystems.macfuse.23|1|Benjamin Fleischer|1
PPNVCC9Z68|com.tuxera.filesystems.tuxera_ntfs|1|Tuxera Inc.|1
```

`kextApproved` = any row with `team_id = '3T5GSNBU6W'`, a `bundle_id` starting with `io.macfuse.filesystems.macfuse`, and `allowed = 1`. The bundle id's suffix is the macOS major version, so match the prefix. `kmutil showloaded --list-only` (works as a user) listing `io.macfuse.filesystems.macfuse` is a quicker positive signal, but the kext only loads after the first kernel-backend mount.
