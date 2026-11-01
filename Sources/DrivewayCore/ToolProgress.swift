import Foundation

/// Splits a tool's output into lines as it arrives. Progress lines end in a carriage return (ntfsclone redraws one
/// line in place) or a newline. Lines are split on bytes, so a character split across two chunks stays whole.
public struct OutputLineSplitter: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    /// The lines that `chunk` completes, without their terminators. Empty lines are dropped.
    public mutating func lines(in chunk: Data) -> [String] {
        var lines: [String] = []
        for byte in chunk {
            if byte == 0x0A || byte == 0x0D {
                if !pending.isEmpty { lines.append(String(decoding: pending, as: UTF8.self)) }
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(byte)
            }
        }
        return lines
    }

    /// The unterminated last line at end of file, if any.
    public mutating func finish() -> String? {
        defer { pending = [] }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

/// Turns one tool's output, a line at a time, into how much of the work is done.
public protocol ProgressParsing: Sendable {
    /// The fraction done (0...1) after `line`, or nil when the line says nothing new about it.
    mutating func fraction(after line: String) -> Double?
}

/// `ntfsclone --save-image` prints `  4.79 percent completed` twice: once while it scans the volume, then again
/// while it saves the image. Scanning took about a twentieth of the time on the live test image, so it gets the
/// first 5% of the bar. The fraction never goes back.
public struct NtfscloneProgress: ProgressParsing {
    static let scanShare = 0.05
    private var saving = false
    private var last = -1.0

    public init() {}

    public mutating func fraction(after line: String) -> Double? {
        if line.hasPrefix("Saving NTFS to image") {
            saving = true
            return nil
        }
        guard let percent = Self.percent(line) else { return nil }
        let share = percent / 100
        let fraction = saving ? Self.scanShare + (1 - Self.scanShare) * share : Self.scanShare * share
        guard fraction >= last else { return nil }
        last = fraction
        return fraction
    }

    /// `12.34` from `" 12.34 percent completed"`. The decimal separator follows the locale, so a comma is read too.
    static func percent(_ line: String) -> Double? {
        let suffix = " percent completed"
        guard line.hasSuffix(suffix) else { return nil }
        let number = line.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
        guard let value = Double(number.replacingOccurrences(of: ",", with: ".")), (0...100).contains(value) else {
            return nil
        }
        return value
    }
}

/// `e2fsck -C 1` writes `pass current max device` lines to stdout, for passes 1 to 5. The passes are weighed as
/// e2fsck's own progress bar weighs them.
public struct E2fsckProgress: ProgressParsing {
    /// Percent done at the end of each pass, from e2fsck's `e2fsck_tbl`.
    static let passEnds: [Double] = [0, 70, 90, 92, 95, 100]

    public init() {}

    public mutating func fraction(after line: String) -> Double? {
        guard let (pass, current, max) = Self.progress(line) else { return nil }
        let start = Self.passEnds[pass - 1]
        let end = Self.passEnds[pass]
        let done = max == 0 ? 1 : Double(current) / Double(max)
        return (start + done * (end - start)) / 100
    }

    /// The pass, current and maximum counts of a progress line; nil for every other line.
    static func progress(_ line: String) -> (pass: Int, current: Int, max: Int)? {
        let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count >= 3, let pass = Int(fields[0]), let current = Int(fields[1]), let max = Int(fields[2]),
            (1...5).contains(pass), current >= 0, max >= 0, current <= max
        else { return nil }
        return (pass, current, max)
    }

    /// e2fsck's output without its progress lines, for the report.
    public static func removingProgressLines(from output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { progress(String($0)) == nil }
            .joined(separator: "\n")
    }
}

/// Lets through about one progress update per `interval`: the first, then only changed values once the interval
/// has passed, and the end (1) as soon as it comes.
public struct ProgressThrottle: Sendable {
    public let interval: Duration
    private var last: (value: Double, at: ContinuousClock.Instant)?

    public init(interval: Duration = .milliseconds(500)) {
        self.interval = interval
    }

    public mutating func admit(_ value: Double, at now: ContinuousClock.Instant = .now) -> Bool {
        if let last {
            guard value != last.value else { return false }
            guard value >= 1 || now - last.at >= interval else { return false }
        }
        last = (value, now)
        return true
    }
}
