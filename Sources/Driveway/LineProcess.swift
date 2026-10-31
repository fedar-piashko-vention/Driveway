import DrivewayCore
import Foundation
import os

/// What a running program printed: a complete line, or its unfinished last line (a prompt) as it changes.
enum ProcessOutput: Sendable {
    case line(String)
    case tail(String)
}

/// A program started from an argument vector, never a shell string, whose output arrives as lines in `output`.
/// The stream finishes once the program has exited and its output is drained; `exitStatus` is valid from then on.
final class LineProcess: @unchecked Sendable {
    /// How long to wait for the output to close after the program exited. A child the program left running can hold
    /// the pipe open; the stream finishes anyway after this.
    static let drainGrace: TimeInterval = 2

    let output: AsyncStream<ProcessOutput>
    // Process and FileHandle are used here only through their thread-safe calls: terminate, terminationStatus, write.
    private let process: Process
    private let input: FileHandle?

    init(
        executable: String, arguments: [String], environment: [String: String]? = nil, includeStderr: Bool = false,
        pipeStdin: Bool = false
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let out = Pipe()
        let err = includeStderr ? Pipe() : nil
        process.standardOutput = out
        process.standardError = err ?? FileHandle.nullDevice
        if pipeStdin {
            let inPipe = Pipe()
            // Writing after the program exited must fail with EPIPE, not kill the app with SIGPIPE.
            _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.standardInput = inPipe
            input = inPipe.fileHandleForWriting
        } else {
            process.standardInput = FileHandle.nullDevice
            input = nil
        }

        let (stream, continuation) = AsyncStream<ProcessOutput>.makeStream()
        let pipes = [out, err].compactMap { $0 }
        // Each pipe's end of file, plus the exit.
        let remaining = OSAllocatedUnfairLock(initialState: pipes.count + 1)
        let done: @Sendable () -> Void = {
            if remaining.withLock({ $0 -= 1; return $0 }) == 0 { continuation.finish() }
        }
        for pipe in pipes {
            let splitter = OSAllocatedUnfairLock(initialState: LineSplitter())
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let rest = splitter.withLock({ $0.finish() }) { continuation.yield(.line(rest)) }
                    done()
                    return
                }
                let (lines, tail) = splitter.withLock { s in (s.append(data), s.tail) }
                for line in lines { continuation.yield(.line(line)) }
                continuation.yield(.tail(tail))
            }
        }
        process.terminationHandler = { _ in
            done()
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainGrace) { continuation.finish() }
        }
        do {
            try process.run()
        } catch {
            for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
            continuation.finish()
            throw error
        }
        self.process = process
        self.output = stream
    }

    var exitStatus: Int32 { process.terminationStatus }

    func write(_ text: String) {
        try? input?.write(contentsOf: Data(text.utf8))
    }

    func closeInput() {
        try? input?.close()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// Runs a program to the end and returns its standard output, or nil if it couldn't start, didn't finish within
    /// `timeout`, or exited non-zero.
    static func output(of executable: String, _ arguments: [String], timeout: Duration) async -> String? {
        guard let run = try? LineProcess(executable: executable, arguments: arguments) else { return nil }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                run.terminate()
            } catch {}
        }
        var lines: [String] = []
        for await output in run.output {
            if case .line(let line) = output { lines.append(line) }
        }
        timer.cancel()
        return run.exitStatus == 0 ? lines.joined(separator: "\n") : nil
    }
}
