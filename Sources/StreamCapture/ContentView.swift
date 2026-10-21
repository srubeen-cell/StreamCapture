import AppKit
import AVFoundation
import CoreAudio
import SwiftUI

// MARK: - Theme

/// Design tokens. Semantic system colours are used for surfaces and text so light and
/// dark mode both keep 4.5:1 contrast; only the accent and record red are custom.
enum Theme {
    static let accent = Color(red: 0.388, green: 0.400, blue: 0.945)      // indigo #6366F1
    static let record = Color(red: 0.863, green: 0.149, blue: 0.149)      // #DC2626
    static let success = Color(red: 0.020, green: 0.588, blue: 0.412)     // #059669
    static let warning = Color.orange

    // Bright, white-based surfaces (the app always uses light mode).
    static let background = Color(red: 0.965, green: 0.969, blue: 0.984)   // #F6F7FB
    static let card = Color.white
    static let hairline = Color(red: 0.898, green: 0.906, blue: 0.937)     // #E5E7EF
    static let tileIdle = Color(red: 0.980, green: 0.980, blue: 0.992)     // #FAFAFD

    static let cardRadius: CGFloat = 14
    static let spacing: CGFloat = 16
}

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.primary)
            content
        }
        .padding(Theme.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.card)
                .shadow(color: Color(red: 0.2, green: 0.22, blue: 0.4).opacity(0.06), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        HStack(spacing: 0) {
            RecorderPane()
                .frame(minWidth: 440, idealWidth: 480, maxWidth: 560)
            Divider()
            LibraryPane()
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        .background(Theme.background)
        .task { await model.refreshSources() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAudioDevices()
            model.loadRecordings()
        }
        .alert("StreamCapture", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            if model.permissionMissing {
                Button("Open System Settings") { model.openPrivacySettings() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Recorder pane

struct RecorderPane: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    SourceCard()
                    SoundCard()
                }
                .padding(Theme.spacing)
            }
            Divider()
            RecordBar()
        }
    }
}

struct SourceCard: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        Card(title: "What to record", symbol: "rectangle.dashed") {
            HStack(spacing: 10) {
                SourceTile(kind: .window, symbol: "macwindow",
                           caption: "One app window and its sound")
                SourceTile(kind: .display, symbol: "display",
                           caption: "Everything on a screen")
            }

            HStack(spacing: 8) {
                if model.sourceKind == .window {
                    Picker("Window", selection: $model.selectedWindowID) {
                        if model.windows.isEmpty { Text("No windows found").tag(CGWindowID?.none) }
                        ForEach(model.windows, id: \.windowID) { window in
                            Text(model.label(for: window)).lineLimit(1).tag(Optional(window.windowID))
                        }
                    }
                    .labelsHidden()
                } else {
                    Picker("Screen", selection: $model.selectedDisplayID) {
                        ForEach(Array(model.displays.enumerated()), id: \.element.displayID) { index, display in
                            Text("Display \(index + 1) · \(display.width)×\(display.height)")
                                .tag(Optional(display.displayID))
                        }
                    }
                    .labelsHidden()
                }
                Button {
                    Task { await model.refreshSources() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh the list")
                .accessibilityLabel("Refresh windows and screens")
            }

            if model.sourceKind == .window {
                // macOS captures sound per app, not per browser tab.
                Label("Records the whole window (whichever tab is showing) and all sound from that app, including other tabs. Pause or mute other tabs, or play the video in a different browser.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.sourceKind == .display {
                Toggle("Only one app's picture and sound", isOn: $model.onlyOneApp)
                if model.onlyOneApp {
                    Picker("App", selection: $model.selectedAppBundleID) {
                        ForEach(model.apps, id: \.bundleIdentifier) { app in
                            Text(app.applicationName).tag(Optional(app.bundleIdentifier))
                        }
                    }
                }
            }

            DisclosureGroup("Options") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Quality", selection: $model.quality) {
                        ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Show mouse pointer", isOn: $model.showsCursor)
                }
                .padding(.top, 6)
            }
        }
        .disabled(model.isRecording)
    }
}

struct SourceTile: View {
    @EnvironmentObject var model: RecorderModel
    let kind: SourceKind
    let symbol: String
    let caption: String

    private var selected: Bool { model.sourceKind == kind }

    var body: some View {
        Button {
            model.sourceKind = kind
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol).font(.title2)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Theme.accent : .secondary)
                }
                Text(kind.rawValue).font(.body.weight(.semibold))
                Text(caption).font(.callout).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.08) : Theme.tileIdle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.rawValue): \(caption)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SoundCard: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        Card(title: "Sound", symbol: "speaker.wave.2.fill") {
            MeterRow(label: "System audio", symbol: "waveform", level: model.systemLevel, active: model.isRecording)

            if model.outputIsSilent {
                Banner(symbol: "exclamationmark.triangle.fill", tint: Theme.warning,
                       text: "Your Mac is playing sound into \(model.currentOutputName), so you can't hear it. StreamCapture doesn't need it.") {
                    HStack {
                        ForEach(model.speakerDevices.prefix(2)) { device in
                            Button("Play through \(device.name)") { model.switchMacOutput(to: device) }
                        }
                    }
                }
            } else if !model.currentOutputName.isEmpty {
                Label("You'll hear it through \(model.currentOutputName) while recording.", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }

            // Only offered when the Mac's output is silent; otherwise it would double the sound.
            if model.outputIsSilent {
                Divider()

                HStack {
                    Label("Monitor on", systemImage: "headphones")
                    Spacer()
                    Picker("Monitor on", selection: $model.monitorDeviceID) {
                        Text("Off").tag(AudioDeviceID?.none)
                        ForEach(model.speakerDevices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.isRecording)
                }
                if model.monitorDeviceID != nil {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $model.monitorVolume, in: 0...1)
                            .accessibilityLabel("Monitor volume")
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    Text("Sends a copy of the recording's sound here. Handy if your Mac's output stays on BlackHole.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle(isOn: $model.includeMicrophone) {
                Label("Add my microphone", systemImage: "mic.fill")
            }
            .disabled(!model.micSupported || model.isRecording)
            if !model.micSupported {
                Text("Needs macOS 15 or newer.").font(.caption).foregroundStyle(.secondary)
            } else if model.includeMicrophone {
                MeterRow(label: "Microphone", symbol: "mic", level: model.micLevel, active: model.isRecording)
            }
        }
    }
}

struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(tint, .primary)
            actions
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
    }
}

struct MeterRow: View {
    let label: String
    let symbol: String
    let level: Float
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Label(label, systemImage: symbol)
                .frame(width: 130, alignment: .leading)
            SegmentedMeter(level: active ? level : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "\(Int(level * 100)) percent" : "Not recording")
    }
}

/// LED-style meter: green to -12 dB, amber to -3 dB, red above.
struct SegmentedMeter: View {
    let level: Float
    private let segments = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                let threshold = Float(i + 1) / Float(segments)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(level >= threshold ? color(for: threshold) : Color.primary.opacity(0.1))
            }
        }
        .frame(height: 10)
        .animation(.linear(duration: 0.06), value: level)
    }

    private func color(for t: Float) -> Color {
        if t > 0.95 { return Theme.record }
        if t > 0.8 { return .yellow }
        return Theme.success
    }
}

// MARK: - Record bar

struct RecordBar: View {
    @EnvironmentObject var model: RecorderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 16) {
            Button {
                model.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 3)
                        .frame(width: 64, height: 64)
                    if model.isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.record)
                            .frame(width: 26, height: 26)
                    } else {
                        Circle()
                            .fill(Theme.record)
                            .frame(width: 50, height: 50)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .help(model.isRecording ? "Stop recording (⇧⌘R)" : "Start recording (⇧⌘R)")
            .accessibilityLabel(model.isRecording ? "Stop recording" : "Start recording")

            VStack(alignment: .leading, spacing: 4) {
                statusPill
                Text(DurationFormat.clock(model.elapsed))
                    .font(.system(size: 26, weight: .medium, design: .monospaced))
                    .foregroundStyle(model.isRecording ? .primary : .secondary)
                    .accessibilityLabel("Elapsed time \(DurationFormat.clock(model.elapsed))")
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Saving to").font(.caption).foregroundStyle(.secondary)
                Button {
                    model.chooseOutputFolder()
                } label: {
                    Label(model.outputFolder.lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                }
                .help(model.outputFolder.path)
                .disabled(model.isRecording)
            }
        }
        .padding(.horizontal, Theme.spacing)
        .padding(.vertical, 14)
        .background(Theme.card)
        .onChange(of: model.isRecording) { recording in
            pulse = recording && !reduceMotion
        }
    }

    @ViewBuilder private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isRecording ? Theme.record : Color.secondary)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.3 : 1)
                .animation(pulse ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
            Text(model.isRecording ? "REC" : (model.isBusy ? "Saving…" : "Ready"))
                .font(.caption.weight(.bold))
                .foregroundStyle(model.isRecording ? Theme.record : .secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill((model.isRecording ? Theme.record : Color.secondary).opacity(0.12)))
    }
}

enum DurationFormat {
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    static func short(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Library pane

struct LibraryPane: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Library").font(.title2.weight(.semibold))
                Text("\(model.recordings.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if Converter.ffmpegPath == nil {
                    Label("Install ffmpeg for more formats", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("brew install ffmpeg")
                }
                Button {
                    NSWorkspace.shared.open(model.outputFolder)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Open the recordings folder")
                .accessibilityLabel("Open the recordings folder")
                Button {
                    model.loadRecordings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .accessibilityLabel("Refresh library")
            }
            .padding(.horizontal, Theme.spacing)
            .padding(.top, Theme.spacing)
            .padding(.bottom, 10)

            if model.recordings.isEmpty {
                EmptyLibrary()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.recordings) { recording in
                            RecordingCard(recording: recording)
                        }
                    }
                    .padding(.horizontal, Theme.spacing)
                    .padding(.bottom, Theme.spacing)
                }
            }
        }
    }
}

struct EmptyLibrary: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No recordings yet").font(.headline)
            Text("Pick a window on the left and press the red button.\nYour recordings will show up here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordingCard: View {
    @EnvironmentObject var model: RecorderModel
    let recording: Recording
    @State private var hovering = false

    private var isAudioOnly: Bool {
        ["m4a", "mp3", "wav"].contains(recording.url.pathExtension.lowercased())
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { model.open(recording) } label: {
                Thumbnail(url: recording.url, audioOnly: isAudioOnly)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(recording.name)")

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(recording.url.pathExtension.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent.opacity(0.15)))
                        .foregroundStyle(Theme.accent)
                    Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: recording.size, countStyle: .file))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let progress = model.conversionProgress[recording.url] {
                    HStack {
                        ProgressView(value: progress)
                        Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Converting, \(Int(progress * 100)) percent")
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Menu {
                    ForEach(Converter.availablePresets) { preset in
                        Button(preset.title) { model.convert(recording, to: preset) }
                    }
                } label: {
                    Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.conversionProgress[recording.url] != nil)

                Button { model.reveal(recording) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                    .accessibilityLabel("Show \(recording.name) in Finder")
            }
            .opacity(hovering || model.conversionProgress[recording.url] != nil ? 1 : 0.75)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? Theme.accent.opacity(0.05) : Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovering ? Theme.accent.opacity(0.35) : Theme.hairline)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            Button("Play") { model.open(recording) }
            Button("Show in Finder") { model.reveal(recording) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.moveToTrash(recording) }
        }
    }
}

/// First-frame preview with the clip's length in the corner.
struct Thumbnail: View {
    let url: URL
    let audioOnly: Bool
    @State private var image: NSImage?
    @State private var duration: TimeInterval?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.85))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: audioOnly ? "waveform" : "film")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let duration {
                Text(DurationFormat.short(duration))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .padding(4)
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .center) {
            Image(systemName: "play.circle.fill")
                .font(.title)
                .foregroundStyle(.white.opacity(0.85))
                .shadow(radius: 4)
                .opacity(image == nil ? 0 : 1)
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        let asset = AVURLAsset(url: url)
        if let time = try? await asset.load(.duration), time.seconds.isFinite {
            duration = time.seconds
        }
        guard !audioOnly else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        let at = CMTime(seconds: min(1, (duration ?? 0) / 2), preferredTimescale: 600)
        if let result = try? await generator.image(at: at) {
            image = NSImage(cgImage: result.image, size: .zero)
        }
    }
}
