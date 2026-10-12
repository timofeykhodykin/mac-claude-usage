import Foundation

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool

    var stderrText: String {
        String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum ProcessRunner {
    /// Runs an executable synchronously, feeding `input` to stdin, with a hard timeout.
    static func run(_ executable: String,
                    _ arguments: [String],
                    input: Data? = nil,
                    timeout: TimeInterval = 10) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Drain both pipes concurrently so a full buffer can never deadlock the child.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if let input {
            stdinPipe.fileHandleForWriting.write(input)
            try? stdinPipe.fileHandleForWriting.close()
        }

        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            group.wait()
        }
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: outData,
                             stderr: errData, timedOut: timedOut)
    }
}
