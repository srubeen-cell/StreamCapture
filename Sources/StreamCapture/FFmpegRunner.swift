import Foundation

/// Drain both pipes while the child runs. Waiting until termination to read
/// stderr can deadlock once ffmpeg fills the OS pipe buffer.
enum FFmpegRunner {
    static func run(executable: String, arguments: [String], duration: Double,
                    progress: @escaping (Double) -> Void) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let readers = DispatchGroup()
        let log = ErrorLog()
        readers.enter()
        readers.enter()

        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                // Readers must see EOF before reporting the final status so the
                // last error line and progress update cannot arrive afterwards.
                readers.notify(queue: .global()) {
                    if proc.terminationStatus == 0 {
                        progress(1)
                        cont.resume()
                    } else {
                        cont.resume(throwing: ConversionError.ffmpegFailed(
                            log.lastLine ?? "exit code \(proc.terminationStatus)"))
                    }
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
                return
            }
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()

            DispatchQueue.global().async {
                defer { readers.leave() }
                var pending = Data()
                while let chunk = try? stdout.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending.prefix(upTo: newline), as: UTF8.self)
                        pending.removeSubrange(...newline)
                        if line.hasPrefix("out_time_us="), duration.isFinite, duration > 0,
                           let us = Double(line.dropFirst("out_time_us=".count)), us.isFinite {
                            progress(min(1, max(0, us / 1_000_000 / duration)))
                        }
                    }
                    // ffmpeg progress records are small; bound malformed output.
                    if pending.count > 65_536 { pending.removeAll(keepingCapacity: true) }
                }
            }
            DispatchQueue.global().async {
                defer { readers.leave() }
                while let chunk = try? stderr.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                    log.append(chunk)
                }
            }
        }
    }

    private final class ErrorLog: @unchecked Sendable {
        private let lock = NSLock()
        private var tail = Data()
        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            tail.append(data)
            if tail.count > 65_536 { tail = Data(tail.suffix(65_536)) }
        }
        var lastLine: String? {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: tail, as: UTF8.self).split(separator: "\n").last.map(String.init)
        }
    }
}
