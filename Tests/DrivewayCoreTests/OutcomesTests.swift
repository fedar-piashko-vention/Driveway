import Foundation
import Testing

@testable import DrivewayCore

@Test func ntfs3gExitCodes() {
    #expect(NTFSMountOutcome.classify(exitCode: 0, stderr: "") == .mounted)
    #expect(NTFSMountOutcome.classify(exitCode: 14, stderr: "") == .hibernated)
    #expect(NTFSMountOutcome.classify(exitCode: 15, stderr: "") == .dirty)
    #expect(NTFSMountOutcome.classify(exitCode: 12, stderr: "") == .notNTFS)
    #expect(NTFSMountOutcome.classify(exitCode: 13, stderr: "") == .corrupt)
    #expect(NTFSMountOutcome.classify(exitCode: 21, stderr: "fuse: device busy") == .failed("fuse: device busy"))
}

@Test func ntfs3gStderrPatternsWinOverUnknownCodes() {
    #expect(NTFSMountOutcome.classify(exitCode: 1, stderr: "Metadata kept in Windows cache, refused to mount.") == .hibernated)
    #expect(NTFSMountOutcome.classify(exitCode: 1, stderr: "Volume is scheduled for check.") == .dirty)
}

@Test func ntfs3gStderrPatternsAreCaseInsensitive() {
    #expect(NTFSMountOutcome.classify(exitCode: 1, stderr: "METADATA KEPT IN WINDOWS CACHE") == .hibernated)
    #expect(NTFSMountOutcome.classify(exitCode: 1, stderr: "WINDOWS IS HIBERNATED, refused to mount.") == .hibernated)
    #expect(NTFSMountOutcome.classify(exitCode: 1, stderr: "Volume is UNCLEAN") == .dirty)
    #expect(NTFSMountOutcome.classify(exitCode: 1, stderr: "Scheduled For Check") == .dirty)
}

@Test func ntfs3gExitCodeBeatsStderrAndZeroMounts() {
    // Codes 12-15 map by the table even when stderr matches another pattern.
    #expect(NTFSMountOutcome.classify(exitCode: 13, stderr: "Windows cache") == .corrupt)
    #expect(NTFSMountOutcome.classify(exitCode: 12, stderr: "unclean") == .notNTFS)
    // Exit 0 is always mounted.
    #expect(NTFSMountOutcome.classify(exitCode: 0, stderr: "Windows cache") == .mounted)
}

@Test func ntfs3gFailedMessage() {
    #expect(NTFSMountOutcome.classify(exitCode: 19, stderr: "  Unprivileged user can not mount NTFS block devices\n")
        == .failed("Unprivileged user can not mount NTFS block devices"))
    #expect(NTFSMountOutcome.classify(exitCode: 7, stderr: "") == .failed("ntfs-3g exited with code 7"))
    #expect(NTFSMountOutcome.classify(exitCode: 7, stderr: " \n") == .failed("ntfs-3g exited with code 7"))
}

@Test func ntfsfixSuccess() {
    let out = "Mounting volume... OK\nProcessing of $MFT and $MFTMirr completed successfully.\nChecking the alternate boot sector... OK\nNTFS volume version is 3.1.\nNTFS partition /dev/disk4s1 was processed successfully.\n"
    let r = NTFSFixReport.parse(out)
    #expect(r.succeeded)
    #expect(r.steps == [FixStep(name: "Mounting volume", ok: true), FixStep(name: "Checking the alternate boot sector", ok: true)])
}

@Test func ntfsfixFailure() {
    let out = "Mounting volume... FAILED\nAttempting to correct errors...\n"
    let r = NTFSFixReport.parse(out)
    #expect(!r.succeeded)
    #expect(r.steps == [FixStep(name: "Mounting volume", ok: false)])
}

@Test func ntfsfixFailedStepBlocksSuccess() {
    let out = "Mounting volume... OK\nChecking the alternate boot sector... FAILED\nNTFS partition /dev/disk4s1 was processed successfully.\n"
    let r = NTFSFixReport.parse(out)
    #expect(!r.succeeded)
    #expect(r.steps.map(\.ok) == [true, false])
}

@Test func ntfsfixIgnoresNonStepLinesAndTrimsWhitespace() {
    let out = "  Mounting volume... OK  \nOK\nsomething OK\nProcessing completed successfully.\n"
    let r = NTFSFixReport.parse(out)
    #expect(r.steps == [FixStep(name: "Mounting volume", ok: true)])
    #expect(!r.succeeded)
    #expect(NTFSFixReport.parse("").steps.isEmpty)
}

@Test func e2fsckBitmask() {
    #expect(E2fsckOutcome.from(exitCode: 0) == .clean)
    #expect(E2fsckOutcome.from(exitCode: 1) == .corrected)
    #expect(E2fsckOutcome.from(exitCode: 2) == .correctedNeedsReboot)
    #expect(E2fsckOutcome.from(exitCode: 4) == .uncorrected)
    #expect(E2fsckOutcome.from(exitCode: 5) == .uncorrected)  // bit 4 wins
    #expect(E2fsckOutcome.from(exitCode: 8) == .operationalError)
    #expect(E2fsckOutcome.from(exitCode: 32) == .cancelled)
    #expect(E2fsckOutcome.from(exitCode: 12) == .operationalError)
    #expect(E2fsckOutcome.from(exitCode: 16) == .operationalError)
    #expect(E2fsckOutcome.from(exitCode: 36) == .cancelled)
    #expect(E2fsckOutcome.from(exitCode: 40) == .operationalError)
}

@Test func checkReportRoundTripsThroughCodable() throws {
    let report = CheckReport(filesystem: .ntfs, mode: .repair, succeeded: true, summary: "ok", rawOutput: "raw")
    let data = try JSONEncoder().encode(report)
    #expect(try JSONDecoder().decode(CheckReport.self, from: data) == report)
}

// MARK: - ntfs-3g exited 0 but fell back to read-only

private let hibernatedFallback = """
    Windows is hibernated, refused to mount.
    Falling back to read-only mount because the NTFS partition is in an
    unsafe state. Please resume and shutdown Windows fully (no hibernation
    or fast restarting.)
    """

@Test func successfulMountThatIsReallyReadWrite() {
    #expect(NTFSMountOutcome.afterSuccessfulMount(mountIsReadOnly: false, output: "") == .mounted)
    #expect(NTFSMountOutcome.afterSuccessfulMount(mountIsReadOnly: nil, output: "") == .mounted)
}

@Test func successfulMountThatFellBackToReadOnly() {
    #expect(NTFSMountOutcome.afterSuccessfulMount(mountIsReadOnly: true, output: hibernatedFallback) == .hibernated)
    #expect(NTFSMountOutcome.afterSuccessfulMount(mountIsReadOnly: true, output: "Metadata kept in Windows cache") == .hibernated)
    #expect(NTFSMountOutcome.afterSuccessfulMount(mountIsReadOnly: true, output: "The file system wasn't safely closed on Windows.") == .dirty)
    // A read-only mount nobody asked for, whatever the output says: not clean, so treated as unclean.
    #expect(NTFSMountOutcome.afterSuccessfulMount(mountIsReadOnly: true, output: "") == .dirty)
    // The mount table can't tell, but the output says it fell back.
    #expect(NTFSMountOutcome.afterSuccessfulMount(mountIsReadOnly: nil, output: "Falling back to read-only mount because the NTFS partition is in an unsafe state") == .dirty)
    #expect(NTFSMountOutcome.afterSuccessfulMount(mountIsReadOnly: false, output: "Volume was not unmounted properly") == .dirty)
    #expect(NTFSMountOutcome.afterSuccessfulMount(mountIsReadOnly: false, output: "Hibernated non-system partition, refused to mount.") == .hibernated)
}

/// ntfs-3g prints the same fallback sentence, with "no hibernation or fast restarting", for every read-only
/// fallback. An unclean volume must stay `.dirty` (it gets Fix & mount), not be taken for a hibernated one.
private let uncleanFallback = """
    The disk contains an unclean file system (0, 0).
    Falling back to read-only mount because the NTFS partition is in an
    unsafe state. Please resume and shutdown Windows fully (no hibernation
    or fast restarting.)
    """

@Test func uncleanFallbackWithNtfs3gsGenericSentenceIsDirty() {
    #expect(NTFSMountOutcome.afterSuccessfulMount(mountIsReadOnly: true, output: uncleanFallback) == .dirty)
    #expect(NTFSMountOutcome.afterSuccessfulMount(mountIsReadOnly: nil, output: uncleanFallback) == .dirty)
    #expect(NTFSMountOutcome.classify(exitCode: 1, stderr: uncleanFallback) == .dirty)
    #expect(NTFSMountOutcome.afterSuccessfulMount(mountIsReadOnly: true, output: "Fast Restart is on") == .dirty)
}
