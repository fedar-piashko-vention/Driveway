import DrivewayCore
import Foundation
import Testing

private func fractions<P: ProgressParsing>(_ parser: P, _ lines: [String]) -> [Double?] {
    var p = parser
    return lines.map { p.fraction(after: $0) }
}

@Test func lineSplitterSplitsOnCarriageReturnsAndNewlines() {
    var s = OutputLineSplitter()
    // ntfsclone redraws its progress with \r; a chunk can end half-way through a line.
    #expect(s.lines(in: Data("Scanning volume ...\n  0.00 percent comp".utf8)) == ["Scanning volume ..."])
    #expect(s.lines(in: Data("leted\r  4.79 percent completed\r".utf8)) == ["  0.00 percent completed", "  4.79 percent completed"])
    #expect(s.lines(in: Data("100.00 percent completed\r\nSyncing".utf8)) == ["100.00 percent completed"])
    #expect(s.finish() == "Syncing")
    #expect(s.finish() == nil)
}

@Test func lineSplitterKeepsMultibyteCharactersSplitAcrossChunks() {
    var s = OutputLineSplitter()
    let bytes = Array("Ünïcode\n".utf8)
    #expect(s.lines(in: Data(bytes[..<2])).isEmpty)
    #expect(s.lines(in: Data(bytes[2...])) == ["Ünïcode"])
}

@Test func ntfscloneProgressWeighsScanningAndSaving() {
    let lines = [
        "NTFS volume version: 3.1",
        "Scanning volume ...",
        "  0.00 percent completed",
        " 50.00 percent completed",
        "100.00 percent completed",
        "Accounting clusters ...",
        "Space in use       : 1101 MB (51.3%)   ",
        "Saving NTFS to image ...",
        "  0.00 percent completed",
        " 49.56 percent completed",
        "100.00 percent completed",
        "Syncing ...",
    ]
    let got = fractions(NtfscloneProgress(), lines)
    let expected: [Double?] = [nil, nil, 0, 0.025, 0.05, nil, nil, nil, 0.05, 0.05 + 0.95 * 0.4956, 1, nil]
    #expect(got.count == expected.count)
    for (g, e) in zip(got, expected) {
        if let e { #expect(abs((g ?? -1) - e) < 1e-9) } else { #expect(g == nil) }
    }
}

@Test func ntfscloneProgressReadsCommaDecimalsAndNeverGoesBack() {
    // Outside the helper's fixed locale the decimal separator can be a comma.
    #expect(fractions(NtfscloneProgress(), ["Saving NTFS to image ...", " 12,50 percent completed"]) == [nil, 0.05 + 0.95 * 0.125])
    #expect(fractions(NtfscloneProgress(), ["Saving NTFS to image ...", " 60.00 percent completed", " 40.00 percent completed"])
        == [nil, 0.05 + 0.95 * 0.6, nil])
    #expect(fractions(NtfscloneProgress(), ["abc percent completed", "percent completed", "250.00 percent completed"])
        == [nil, nil, nil])
}

@Test func e2fsckProgressFollowsTheFivePasses() {
    // `e2fsck -C 1` writes "pass current max device" lines; e2fsck weighs the passes 70/20/2/3/5.
    let got = fractions(E2fsckProgress(), [
        "e2fsck 1.47.4 (6-Mar-2025)", "Pass 1: Checking inodes, blocks, and sizes",
        "1 0 16 SPIKEEXT", "1 8 16 SPIKEEXT", "1 16 16 SPIKEEXT", "2 3 6 SPIKEEXT", "3 0 0 SPIKEEXT",
        "4 1 2 MY DRIVE", "5 32 32 SPIKEEXT",
        "SPIKEEXT: 14/131072 files (0.0% non-contiguous), 18093/523776 blocks",
    ])
    #expect(got == [nil, nil, 0, 0.35, 0.7, 0.8, 0.92, 0.935, 1, nil])
    #expect(fractions(E2fsckProgress(), ["6 1 2 X", "1 3 2 X", "0 1 2 X", "1 -1 2 X", "Pass 1 2 3"]) == [nil, nil, nil, nil, nil])
}

@Test func e2fsckProgressLinesAreRemovedFromTheReport() {
    let out = "e2fsck 1.47.4 (6-Mar-2025)\nPass 1: Checking inodes\n1 0 16 SPIKEEXT\n1 16 16 SPIKEEXT\nPass 2: Checking\n2 6 6 MY DRIVE\nSPIKEEXT: 14/131072 files\n"
    #expect(E2fsckProgress.removingProgressLines(from: out)
        == "e2fsck 1.47.4 (6-Mar-2025)\nPass 1: Checking inodes\nPass 2: Checking\nSPIKEEXT: 14/131072 files\n")
    #expect(E2fsckProgress.removingProgressLines(from: "") == "")
}

@Test func progressThrottlePassesAboutTwoUpdatesASecond() {
    let start = ContinuousClock.now
    var t = ProgressThrottle(interval: .milliseconds(500))
    // Unchanged values never pass; the end always does, once.
    let admitted = [
        (0.1, Duration.zero), (0.2, .milliseconds(100)), (0.3, .milliseconds(600)), (0.3, .seconds(5)),
        (1, .milliseconds(700)), (1, .seconds(9)),
    ].map { t.admit($0.0, at: start + $0.1) }
    #expect(admitted == [true, false, true, false, true, false])
}
