import Foundation
import Synchronization

/// Decides whether an XPC peer may talk to the root helper. The app is only ad-hoc signed, so the
/// signing identifier alone proves little. It must also run from its fixed install location, inside a
/// bundle owned by root that no other user can modify.
public enum CallerPolicy {
    /// Signing identifier -> the only executable path allowed to carry it.
    static let allowed: [String: String] = [
        "app.driveway.Driveway": "/Applications/Driveway.app/Contents/MacOS/Driveway",
        "app.driveway.agent":
            "/Applications/Driveway.app/Contents/Library/LoginItems/DrivewayAgent.app/Contents/MacOS/DrivewayAgent",
    ]

    /// `bundleOwnerUID` and `bundleWritableByNonRoot` describe `/Applications/Driveway.app`.
    /// The path is compared exactly, so "..", symlink-style detours and other prefixes are refused.
    public static func accept(
        signingIdentifier: String?, executablePath: String, bundleOwnerUID: UInt32, bundleWritableByNonRoot: Bool
    ) -> Bool {
        guard let id = signingIdentifier, let expected = allowed[id] else { return false }
        return executablePath == expected && bundleOwnerUID == 0 && !bundleWritableByNonRoot
    }

    /// True if anything in the bundle, the bundle itself included, is owned by someone other than root or is
    /// group- or other-writable. Walks the whole tree (the nested agent bundle too) without following
    /// symbolic links. Anything that can't be checked counts as writable.
    public static func bundleIsWritableByNonRoot(at bundle: URL) -> Bool {
        // The bundle itself must be a real directory: a link could be pointed elsewhere.
        guard let rootStat = lstatResult(bundle.path), rootStat.mode & S_IFMT == S_IFDIR,
              !isWritableByNonRoot(owner: rootStat.uid, mode: rootStat.mode)
        else { return true }
        let failed = Mutex(false)
        guard let walker = FileManager.default.enumerator(
            at: bundle, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, _ in
                failed.withLock { $0 = true }
                return false
            })
        else { return true }
        for case let url as URL in walker {
            guard let st = lstatResult(url.path), !isWritableByNonRoot(owner: st.uid, mode: st.mode) else { return true }
        }
        return failed.withLock { $0 }
    }

    /// One item: not owned by root, or group- or other-writable.
    public static func isWritableByNonRoot(owner: UInt32, mode: UInt16) -> Bool {
        owner != 0 || mode & UInt16(S_IWGRP | S_IWOTH) != 0
    }

    /// The owner and mode of an item, from `lstat` (a link is not followed); nil if it can't be read.
    static func lstatResult(_ path: String) -> (uid: UInt32, mode: UInt16)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return (st.st_uid, st.st_mode)
    }
}
