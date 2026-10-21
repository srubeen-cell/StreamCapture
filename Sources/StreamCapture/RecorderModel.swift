import AppKit
import CoreAudio
import ScreenCaptureKit
import SwiftUI

enum SourceKind: String, CaseIterable, Identifiable {
    case window = "A window"
    case display = "Whole screen"
    var id: String { rawValue }
}

enum Quality: String, CaseIterable, Identifiable {
    case standard = "Standard (1080p, 30 fps)"
    case high = "High (native size, 60 fps)"
    var id: String { rawValue }
}

struct Recording: Identifiable, Hashable {
    let url: URL
    let date: Date
    let size: Int64
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@MainActor
final class RecorderModel: ObservableObject {
    // What to record
    @Published var sourceKind: SourceKind = .window
    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var apps: [SCRunningApplication] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?
    @Published var onlyOneApp = false
    @Published var selectedAppBundleID: String?
    @Published var quality: Quality = .standard
    @Published var showsCursor = false

    // Audio
    @Published var includeMicrophone = false
    @Published var outputDevices: [AudioOutputDevice] = []
    @Published var currentOutputName = ""
    @Published var monitorDeviceID: AudioDeviceID?   // nil = off
    @Published var monitorVolume: Float = 1 {
        didSet { engine?.monitor?.volume = monitorVolume }
    }
    @Published var systemLevel: Float = 0
    @Published var micLevel: Float = 0

    // State
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var elapsed: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var permissionMissing = false
    @Published var recordings: [Recording] = []
    @Published var previewImage: CGImage?
    @Published var conversionProgress: [URL: Double] = [:]
    @Published var outputFolder: URL {
        didSet {
            UserDefaults.standard.set(outputFolder.path, forKey: "outputFolder")
            loadRecordings()
        }
    }

    private var engine: CaptureEngine?
    private var startDate: Date?
    private var timer: Timer?
    private var followTask: Task<Void, Never>?

    var micSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// True when the Mac's sound is going into BlackHole (or similar) and nobody would hear it.
    var outputIsSilent: Bool { AudioDevices.isSilentRouting(currentOutputName) }

    var speakerDevices: [AudioOutputDevice] {
        outputDevices.filter { !AudioDevices.isSilentRouting($0.name) }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "outputFolder") {
            outputFolder = URL(fileURLWithPath: saved)
        } else {
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            outputFolder = movies.appendingPathComponent("StreamCapture")
        }
        refreshAudioDevices()
        loadRecordings()
    }

    // MARK: Sources

    func refreshSources() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let myBundleID = Bundle.main.bundleIdentifier
            permissionMissing = false
            displays = content.displays
            windows = content.windows
                .filter { w in
                    guard let app = w.owningApplication, app.bundleIdentifier != myBundleID else { return false }
                    return w.windowLayer == 0 && w.frame.width > 120 && w.frame.height > 80
                        && !(w.title ?? "").isEmpty
                }
                .sorted { label(for: $0) < label(for: $1) }
            apps = content.applications
                .filter { $0.bundleIdentifier != myBundleID && !$0.applicationName.isEmpty }
                .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }

            if selectedDisplayID == nil || !displays.contains(where: { $0.displayID == selectedDisplayID }) {
                selectedDisplayID = displays.first?.displayID
            }
            if selectedWindowID == nil || !windows.contains(where: { $0.windowID == selectedWindowID }) {
                selectedWindowID = windows.first(where: { Self.looksLikeBrowser($0.owningApplication?.bundleIdentifier) })?.windowID
                    ?? windows.first?.windowID
            }
            if selectedAppBundleID == nil {
                selectedAppBundleID = apps.first(where: { Self.looksLikeBrowser($0.bundleIdentifier) })?.bundleIdentifier
            }
        } catch {
            permissionMissing = true
            errorMessage = "StreamCapture needs permission to record the screen and system audio. Turn it on in System Settings, then quit and reopen the app."
        }
    }

    func label(for window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "Unknown"
        return "\(app) — \(window.title ?? "")"
    }

    private static func looksLikeBrowser(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return ["safari", "chrome", "firefox", "edge", "arc", "brave", "opera", "vivaldi"].contains { id.contains($0) }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Preview

    var previewSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// Grabs a small still of exactly what would be recorded right now.
    func refreshPreview() async {
        guard #available(macOS 14.0, *) else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let made = try? makeFilter(using: content) else {
            previewImage = nil
            return
        }
        let (filter, _, sourceRect) = made
        let config = SCStreamConfiguration()
        let aspect = sourceRect.map { $0.width / max($0.height, 1) } ?? (filter.contentRect.width / max(filter.contentRect.height, 1))
        config.width = 640
        config.height = max(2, Int(640 / max(aspect, 0.1)))
        if let sourceRect { config.sourceRect = sourceRect }
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.showsCursor = showsCursor
        config.capturesAudio = false
        previewImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: Audio routing

    func refreshAudioDevices() {
        outputDevices = AudioDevices.outputDevices()
        currentOutputName = AudioDevices.defaultOutputID().flatMap(AudioDevices.name(of:)) ?? ""
        if let id = monitorDeviceID, !outputDevices.contains(where: { $0.id == id }) {
            monitorDeviceID = nil
        }
        // Monitoring is only for when the Mac's own output is silent (e.g. BlackHole).
        // Otherwise you'd hear the sound twice, slightly out of sync, like an echo.
        if !outputIsSilent { monitorDeviceID = nil }
    }

    /// Points the Mac's sound back at real speakers/headphones.
    func switchMacOutput(to device: AudioOutputDevice) {
        AudioDevices.setDefaultOutput(device.id)
        refreshAudioDevices()
    }

    // MARK: Recording

    func toggleRecording() {
        Task { isRecording ? await stopRecording() : await startRecording() }
    }

    /// Where a window sits: the display showing most of it, and its rect on that display in points.
    private static func placement(of window: SCWindow, in displays: [SCDisplay]) -> (display: SCDisplay, rect: CGRect)? {
        func overlap(_ d: SCDisplay) -> CGFloat {
            let r = d.frame.intersection(window.frame)
            return r.isNull ? 0 : r.width * r.height
        }
        guard let display = displays.max(by: { overlap($0) < overlap($1) }), overlap(display) > 0 else { return nil }
        let rect = window.frame.intersection(display.frame)
            .offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        return (display, rect)
    }

    private func makeFilter(using content: SCShareableContent? = nil) throws -> (SCContentFilter, CGSize, CGRect?) {
        let myBundleID = Bundle.main.bundleIdentifier
        let windows = content?.windows ?? windows
        let displays = content?.displays ?? displays
        let apps = content?.applications ?? apps
        switch sourceKind {
        case .window:
            guard let window = windows.first(where: { $0.windowID == selectedWindowID }),
                  let placed = Self.placement(of: window, in: displays) else { throw RecorderError.noSource }
            // Record the window's area of its display, showing only that window (and its app's
            // sound). Unlike a window-only filter, this stays correct when the window goes
            // fullscreen: we just follow its new rect, see followWindow(_:from:).
            let filter = SCContentFilter(display: placed.display, including: [window])
            return (filter, window.frame.size, placed.rect)
        case .display:
            guard let display = displays.first(where: { $0.displayID == selectedDisplayID }) else { throw RecorderError.noSource }
            let size = CGSize(width: display.width, height: display.height)
            if onlyOneApp, let app = apps.first(where: { $0.bundleIdentifier == selectedAppBundleID }) {
                return (SCContentFilter(display: display, including: [app], exceptingWindows: []), size, nil)
            }
            let mine = apps.filter { $0.bundleIdentifier == myBundleID }
            return (SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: []), size, nil)
        }
    }

    private func captureSettings(for filter: SCContentFilter, pointSize: CGSize) -> CaptureSettings {
        var scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
        var size = pointSize
        if #available(macOS 14.0, *) {
            scale = CGFloat(filter.pointPixelScale)
            if sourceKind == .display { size = filter.contentRect.size }
        }
        var width = size.width * scale
        var height = size.height * scale

        let maxWidth: CGFloat = quality == .high ? 3840 : 1920
        let maxHeight: CGFloat = quality == .high ? 2160 : 1080

        if sourceKind == .window {
            // Windows can resize or go fullscreen mid-recording, so record into a fixed
            // 16:9 frame. A fullscreen video then fills it exactly; other shapes get bars.
            width = max(width, height * 16 / 9)
            height = width * 9 / 16
        }
        let fit = min(1, maxWidth / width, maxHeight / height)
        width *= fit
        height *= fit

        // H.264 needs even dimensions.
        let w = max(2, Int(width) & ~1)
        let h = max(2, Int(height) & ~1)
        let fps = quality == .high ? 60 : 30
        let bitrate = Int(Double(w * h * fps) * (quality == .high ? 0.15 : 0.12))
        return CaptureSettings(width: w, height: h, fps: fps, videoBitrate: bitrate,
                               showsCursor: showsCursor, includeMicrophone: includeMicrophone && micSupported)
    }

    func startRecording() async {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        do {
            if windows.isEmpty && displays.isEmpty { await refreshSources() }
            let (filter, pointSize, sourceRect) = try makeFilter()
            var settings = captureSettings(for: filter, pointSize: pointSize)
            settings.sourceRect = sourceRect

            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = outputFolder.appendingPathComponent("Recording \(formatter.string(from: Date())).mp4")

            let engine = CaptureEngine()
            engine.onLevel = { [weak self] source, level in
                Task { @MainActor in
                    switch source {
                    case .system: self?.systemLevel = level
                    case .microphone: self?.micLevel = level
                    }
                }
            }
            engine.onStopped = { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = "Recording stopped: \(error.localizedDescription)"
                    await self?.stopRecording()
                }
            }
            if outputIsSilent, let deviceID = monitorDeviceID {
                engine.monitor = try AudioMonitor(deviceID: deviceID, volume: monitorVolume)
            }

            try await engine.start(filter: filter, settings: settings, to: url)
            self.engine = engine
            if sourceKind == .window, let windowID = selectedWindowID {
                followTask = Task { [weak self] in await self?.followWindow(windowID, from: sourceRect) }
            }
            isRecording = true
            startDate = Date()
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.startDate else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Keeps a window recording aimed at the window as it moves, resizes or goes fullscreen.
    private func followWindow(_ windowID: CGWindowID, from initialRect: CGRect?) async {
        var lastDisplay = displays.first(where: { d in
            windows.first(where: { $0.windowID == windowID }).map { d.frame.intersects($0.frame) } ?? false
        })?.displayID
        var lastRect = initialRect
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard isRecording, let engine else { return }
            // If the window is off-screen (another Space, minimised), keep the last framing.
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let window = content.windows.first(where: { $0.windowID == windowID }),
                  let placed = Self.placement(of: window, in: content.displays) else { continue }
            if placed.display.displayID != lastDisplay {
                await engine.follow(sourceRect: placed.rect,
                                    filter: SCContentFilter(display: placed.display, including: [window]))
            } else if placed.rect != lastRect {
                await engine.follow(sourceRect: placed.rect, filter: nil)
            }
            lastDisplay = placed.display.displayID
            lastRect = placed.rect
        }
    }

    func stopRecording() async {
        guard isRecording, let engine else { return }
        isBusy = true
        defer { isBusy = false }
        isRecording = false
        timer?.invalidate()
        followTask?.cancel()
        followTask = nil
        timer = nil
        self.engine = nil
        systemLevel = 0
        micLevel = 0
        do {
            _ = try await engine.stop()
        } catch {
            errorMessage = error.localizedDescription
        }
        loadRecordings()
    }

    // MARK: Files

    private static let mediaExtensions: Set<String> = ["mp4", "mov", "m4a", "mp3", "wav", "webm", "mkv", "gif"]

    func loadRecordings() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: outputFolder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        recordings = urls
            .filter { Self.mediaExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Recording(url: url, date: values?.contentModificationDate ?? .distantPast,
                                 size: Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputFolder
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url }
    }

    func reveal(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.url])
    }

    func moveToTrash(_ recording: Recording) {
        NSWorkspace.shared.recycle([recording.url]) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.errorMessage = error.localizedDescription }
                self?.loadRecordings()
            }
        }
    }

    func open(_ recording: Recording) {
        NSWorkspace.shared.open(recording.url)
    }

    func convert(_ recording: Recording, to preset: ConversionPreset) {
        let url = recording.url
        conversionProgress[url] = 0
        Task {
            do {
                let output = try await Converter.convert(url, preset: preset) { value in
                    Task { @MainActor in self.conversionProgress[url] = value }
                }
                conversionProgress[url] = nil
                loadRecordings()
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                conversionProgress[url] = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}
