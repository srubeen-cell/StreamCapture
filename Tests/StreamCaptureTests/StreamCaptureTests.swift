import XCTest
@testable import StreamCapture

final class StreamCaptureTests: XCTestCase {
    func testFrameRates() {
        XCTAssertEqual(RecordingStandard.pal.frameRate(for: .standard), 25)
        XCTAssertEqual(RecordingStandard.pal.frameRate(for: .high), 50)
        XCTAssertEqual(RecordingStandard.fps30.frameRate(for: .standard), 30)
        XCTAssertEqual(RecordingStandard.fps30.frameRate(for: .high), 60)
    }

    @MainActor
    func testMissingApplicationIsRejected() {
        let model = RecorderModel()
        model.onlyOneApp = true
        model.selectedAppBundleID = nil
        XCTAssertThrowsError(try model.selectedApplication(in: []))
        model.selectedAppBundleID = "app.that.has.quit"
        XCTAssertThrowsError(try model.selectedApplication(in: []))
    }

    func testVideoPresetsKeepAllAudioTracks() {
        for preset in ConversionPreset.all where ["mp4", "mov", "webm", "mkv"].contains(preset.fileExtension) {
            XCTAssertEqual(preset.streamMappingArguments, ["-map", "0:v:0?", "-map", "0:a?"], preset.id)
        }
        XCTAssertEqual(ConversionPreset.all.first { $0.id == "gif" }?.streamMappingArguments, [])
    }

    func testLargeStderrIsDrainedBeforeReportingFailure() async {
        // No media is generated: the child emits more text than a pipe can hold.
        let completed = expectation(description: "Child exits without pipe deadlock")
        Task {
            do {
                try await FFmpegRunner.run(executable: "/bin/sh", arguments: ["-c",
                    "i=0; while [ $i -lt 6000 ]; do printf 'long diagnostic line for pipe regression test\\n' >&2; i=$((i + 1)); done; printf 'final error\\n' >&2; exit 7"],
                    duration: 1, progress: { _ in })
                XCTFail("Expected failure")
            } catch {
                XCTAssertEqual(error.localizedDescription, "ffmpeg failed: final error")
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 10)
    }

    func testMissingExecutableFailsWithoutHanging() async {
        do {
            try await FFmpegRunner.run(executable: "/nonexistent/ffmpeg", arguments: [], duration: 1, progress: { _ in })
            XCTFail("Expected launch error")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testLargeStdoutAndProgressCompleteSuccessfully() async throws {
        let halfway = expectation(description: "Parsed progress")
        let finished = expectation(description: "Final progress")
        try await FFmpegRunner.run(executable: "/bin/sh", arguments: ["-c",
            "i=0; while [ $i -lt 6000 ]; do printf 'ignored stdout diagnostic\\n'; i=$((i + 1)); done; printf 'out_time_us=500000\\n'"],
            duration: 1) { value in
                if value == 0.5 { halfway.fulfill() }
                if value == 1 { finished.fulfill() }
            }
        await fulfillment(of: [halfway, finished], timeout: 5)
    }
}
