import AVFoundation

/// A target format a recording can be converted to.
struct ConversionPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let fileExtension: String
    /// ffmpeg arguments placed between the input and output file.
    let ffmpegArgs: [String]?
    /// AVFoundation export preset used when ffmpeg isn't installed.
    let avPreset: String?
    let avFileType: AVFileType?

    static let all: [ConversionPreset] = [
        .init(id: "mp4-small", title: "MP4, smaller file (H.264)", fileExtension: "mp4",
              ffmpegArgs: ["-c:v", "libx264", "-crf", "23", "-preset", "medium", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"],
              avPreset: AVAssetExportPreset1920x1080, avFileType: .mp4),
        .init(id: "mp4-720", title: "MP4, 720p", fileExtension: "mp4",
              ffmpegArgs: ["-vf", "scale=-2:720", "-c:v", "libx264", "-crf", "23", "-preset", "medium", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"],
              avPreset: AVAssetExportPreset1280x720, avFileType: .mp4),
        .init(id: "hevc", title: "MP4, HEVC (H.265, smallest)", fileExtension: "mp4",
              ffmpegArgs: ["-c:v", "hevc_videotoolbox", "-q:v", "60", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"],
              avPreset: AVAssetExportPresetHEVCHighestQuality, avFileType: .mp4),
        .init(id: "mov", title: "MOV (QuickTime, same quality)", fileExtension: "mov",
              ffmpegArgs: ["-c", "copy"],
              avPreset: AVAssetExportPresetPassthrough, avFileType: .mov),
        .init(id: "webm", title: "WebM (VP9 + Opus)", fileExtension: "webm",
              ffmpegArgs: ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "160k"],
              avPreset: nil, avFileType: nil),
        .init(id: "mkv", title: "MKV (same quality)", fileExtension: "mkv",
              ffmpegArgs: ["-c", "copy"],
              avPreset: nil, avFileType: nil),
        .init(id: "gif", title: "GIF (no sound, 480px wide)", fileExtension: "gif",
              ffmpegArgs: ["-vf", "fps=12,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-an"],
              avPreset: nil, avFileType: nil),
        .init(id: "m4a", title: "M4A, audio only (AAC)", fileExtension: "m4a",
              ffmpegArgs: ["-vn", "-map", "0:a:0", "-c:a", "copy"],
              avPreset: AVAssetExportPresetAppleM4A, avFileType: .m4a),
        .init(id: "mp3", title: "MP3, audio only", fileExtension: "mp3",
              ffmpegArgs: ["-vn", "-map", "0:a:0", "-c:a", "libmp3lame", "-q:a", "2"],
              avPreset: nil, avFileType: nil),
        .init(id: "wav", title: "WAV, audio only (lossless)", fileExtension: "wav",
              ffmpegArgs: ["-vn", "-map", "0:a:0", "-c:a", "pcm_s16le"],
              avPreset: nil, avFileType: nil),
    ]
}

enum Converter {
    static let ffmpegPath: String? = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    static var availablePresets: [ConversionPreset] {
        ffmpegPath != nil ? ConversionPreset.all : ConversionPreset.all.filter { $0.avPreset != nil }
    }

    static func outputURL(for input: URL, preset: ConversionPreset) -> URL {
        let base = input.deletingPathExtension().lastPathComponent + " (\(preset.id))"
        var url = input.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(preset.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = input.deletingLastPathComponent()
                .appendingPathComponent("\(base) \(n)").appendingPathExtension(preset.fileExtension)
            n += 1
        }
        return url
    }

    /// Converts `input`, reporting progress from 0 to 1. Returns the new file's URL.
    static func convert(_ input: URL, preset: ConversionPreset, progress: @escaping (Double) -> Void) async throws -> URL {
        let output = outputURL(for: input, preset: preset)
        if let ffmpeg = ffmpegPath, let args = preset.ffmpegArgs {
            try await runFFmpeg(ffmpeg, input: input, args: args, output: output, progress: progress)
        } else if let avPreset = preset.avPreset, let fileType = preset.avFileType {
            try await runExport(input, avPreset: avPreset, fileType: fileType, output: output, progress: progress)
        } else {
            throw ConversionError.needsFFmpeg
        }
        return output
    }

    private static func runFFmpeg(_ ffmpeg: String, input: URL, args: [String], output: URL,
                                  progress: @escaping (Double) -> Void) async throws {
        let duration = try await AVURLAsset(url: input).load(.duration).seconds

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-nostats", "-y", "-i", input.path] + args
            + ["-progress", "pipe:1", output.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            guard let text = String(data: handle.availableData, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let us = Double(line.dropFirst("out_time_us=".count)), duration > 0 {
                    progress(min(1, us / 1_000_000 / duration))
                }
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    progress(1)
                    cont.resume()
                } else {
                    let log = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let lastLine = log.split(separator: "\n").last.map(String.init) ?? "exit code \(proc.terminationStatus)"
                    cont.resume(throwing: ConversionError.ffmpegFailed(lastLine))
                }
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    private static func runExport(_ input: URL, avPreset: String, fileType: AVFileType, output: URL,
                                  progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: asset, presetName: avPreset) else {
            throw ConversionError.exportFailed("This format isn't supported for this file.")
        }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        let poll = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { poll.cancel() }

        await session.export()
        if session.status != .completed {
            throw ConversionError.exportFailed(session.error?.localizedDescription ?? "Export failed.")
        }
        progress(1)
    }
}

enum ConversionError: LocalizedError {
    case needsFFmpeg
    case ffmpegFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .needsFFmpeg: return "This format needs ffmpeg. Install it with: brew install ffmpeg"
        case .ffmpegFailed(let line): return "ffmpeg failed: \(line)"
        case .exportFailed(let reason): return reason
        }
    }
}
